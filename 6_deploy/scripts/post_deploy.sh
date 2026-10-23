#!/usr/bin/env bash
# post_deploy.sh — Specialty Bakeries & Pastry Cafés
#
# Runs every step required after `make deploy` to make the system fully live:
#   1. Set up Cognito User Pool + Identity Pool → writes cognito-config.json
#   2. Launch AgentCore runtime → writes agentcore-config.json + AGENT_RUNTIME_ARN
#   3. Re-deploy the Amplify frontend with the freshly populated configs
#
# Usage:
#   bash 6_deploy/scripts/post_deploy.sh [options]
#   make post-deploy
#
# Options:
#   -f, --force           Re-run Cognito setup and the AgentCore launch even when the config
#                         files are already populated. Required to ship new agent code: by
#                         default a populated agentcore-config.json makes Step 2 a no-op, so
#                         an unattended re-deploy would otherwise report success and change
#                         nothing. Also set by FORCE_REDEPLOY=1.
#       --skip-user       Create no Cognito sign-in user (passed through).
#       --non-interactive Never prompt (passed through). Implied when there is no terminal.
#   -h, --help            Show this help
#
# Unattended runs: supply the sign-in user through COGNITO_ADMIN_USERNAME plus
# COGNITO_ADMIN_PASSWORD_SECRET_ID (or COGNITO_ADMIN_PASSWORD), or pass --skip-user.

set -euo pipefail

ROOT_DIR="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "$0")/../.." && pwd; })"
SCRIPTS_DIR="$ROOT_DIR/6_deploy/scripts"
AGENTS_DIR="$ROOT_DIR/6_deploy/agents"
WEB_APP_DIR="$ROOT_DIR/6_deploy/web-app"
REGION="${AWS_REGION:-eu-central-1}"

FORCE="${FORCE_REDEPLOY:-0}"
[ "$FORCE" = "true" ] && FORCE=1
COGNITO_ARGS=()
# No terminal means no prompting, whether or not the caller said so
[ -t 0 ] || COGNITO_ARGS+=(--non-interactive)

while [ $# -gt 0 ]; do
    case "$1" in
        -f|--force)        FORCE=1 ;;
        --skip-user)       COGNITO_ARGS+=(--skip-user) ;;
        --non-interactive) case " ${COGNITO_ARGS[*]} " in *" --non-interactive "*) ;; *) COGNITO_ARGS+=(--non-interactive) ;; esac ;;
        -h|--help)         sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                 echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

log()  { echo -e "\033[0;34mℹ️  [post_deploy] $1\033[0m"; }
ok()   { echo -e "\033[0;32m✅ [post_deploy] $1\033[0m"; }
warn() { echo -e "\033[1;33m⚠️  [post_deploy] $1\033[0m"; }
err()  { echo -e "\033[0;31m❌ [post_deploy] $1\033[0m"; exit 1; }

# ── Pre-flight checks ─────────────────────────────────────────────────────────
command -v aws     >/dev/null 2>&1 || err "aws CLI not found"
command -v python3 >/dev/null 2>&1 || err "python3 not found"

aws sts get-caller-identity >/dev/null 2>&1 || err "AWS credentials not configured"

# Source environment so KB IDs, MODEL_ARN, etc. are available for configure_runtime.py
ENV_FILE="${HOME}/environment/env.sh"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  log "Loaded environment from $ENV_FILE"
else
  warn "$ENV_FILE not found — run 'source setup_env.sh' first if you need KB IDs"
fi

echo ""
echo -e "\033[0;36m══════════════════════════════════════════════════════\033[0m"
echo -e "\033[0;32m🥐 Specialty Bakeries & Pastry Cafés — Post-Deploy Setup\033[0m"
echo -e "\033[0;36m══════════════════════════════════════════════════════\033[0m"
echo ""

# ────────────────────────────────────────────────────────────────────────────
# STEP 1 — Cognito: User Pool + Identity Pool + cognito-config.json
# ────────────────────────────────────────────────────────────────────────────
log "STEP 1/3 — Setting up Cognito authentication..."

COGNITO_CONFIG="$WEB_APP_DIR/cognito-config.json"

run_cognito_setup() {
  bash "$SCRIPTS_DIR/setup_cognito_auth.sh" ${COGNITO_ARGS[@]+"${COGNITO_ARGS[@]}"}
}

if [[ "$FORCE" = "1" ]]; then
  log "--force: running Cognito setup regardless of the existing config"
  run_cognito_setup
elif [[ -s "$COGNITO_CONFIG" ]]; then
  # Check if it contains real values (not just empty braces)
  if python3 -c "
import json, sys
d = json.load(open('$COGNITO_CONFIG'))
if not d.get('UserPoolId') or not d.get('ClientId'):
    sys.exit(1)
" 2>/dev/null; then
    ok "cognito-config.json already populated — skipping Cognito setup"
  else
    log "cognito-config.json exists but is missing UserPoolId/ClientId — re-running setup"
    run_cognito_setup
  fi
else
  run_cognito_setup
fi

# Validate
python3 -c "
import json, sys
try:
    d = json.load(open('$COGNITO_CONFIG'))
    assert d.get('UserPoolId'), 'UserPoolId missing'
    assert d.get('ClientId'),  'ClientId missing'
    print('  UserPoolId :', d['UserPoolId'])
    print('  ClientId   :', d['ClientId'])
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" || err "cognito-config.json validation failed — check setup_cognito_auth.sh output above"

ok "STEP 1 complete — Cognito configured"
echo ""

# ────────────────────────────────────────────────────────────────────────────
# STEP 2 — AgentCore runtime: launch + agentcore-config.json + AGENT_RUNTIME_ARN
# ────────────────────────────────────────────────────────────────────────────
log "STEP 2/3 — Launching Bedrock AgentCore runtime..."

AGENTCORE_CONFIG="$WEB_APP_DIR/agentcore-config.json"

# Launch (or update) the runtime via the zip / direct-code-deployment path in
# deploy_agentcore.sh: package the agent as an arm64 zip, create-or-update the runtime, then
# write agentcore-config.json. This is the SAME mechanism that produced the live runtime, so a
# re-deploy updates it in place. The starter-toolkit path (configure_runtime.py) builds a
# *container* artifact instead, which AWS rejects as an update to a zip runtime
# ("Agent artifact type cannot be updated"); keeping one artifact type avoids that conflict.
launch_runtime() {
  bash "$ROOT_DIR/deploy_agentcore.sh" step7-package-zip
  bash "$ROOT_DIR/deploy_agentcore.sh" step8-create-runtime
  bash "$ROOT_DIR/deploy_agentcore.sh" step10-generate-config
}

if [[ "$FORCE" = "1" ]]; then
  log "--force: launching/updating the AgentCore runtime (zip artifact) with the current agent code"
  launch_runtime
elif [[ -s "$AGENTCORE_CONFIG" ]]; then
  if python3 -c "
import json, sys
d = json.load(open('$AGENTCORE_CONFIG'))
if not d.get('agentRuntimeArn') or 'RUNTIME_NAME' in d.get('agentRuntimeArn',''):
    sys.exit(1)
" 2>/dev/null; then
    ok "agentcore-config.json already points at a runtime — skipping the AgentCore launch"
    warn "No agent code was deployed in this run. Use --force (or FORCE_REDEPLOY=1) to ship code changes."
  else
    log "agentcore-config.json has placeholder — re-launching AgentCore runtime (zip artifact)"
    launch_runtime
  fi
else
  launch_runtime
fi

# Validate
python3 -c "
import json, sys
try:
    d = json.load(open('$AGENTCORE_CONFIG'))
    arn = d.get('agentRuntimeArn', '')
    assert arn and 'RUNTIME_NAME' not in arn, 'agentRuntimeArn is missing or still a placeholder'
    print('  agentRuntimeArn :', arn)
    print('  region          :', d.get('region'))
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" || err "agentcore-config.json validation failed — check configure_runtime.py output above"

ok "STEP 2 complete — AgentCore runtime live"
echo ""

# ────────────────────────────────────────────────────────────────────────────
# STEP 3 — Re-deploy Amplify with populated configs
# ────────────────────────────────────────────────────────────────────────────
log "STEP 3/3 — Deploying updated frontend to AWS Amplify..."

AWS_REGION="$REGION" bash "$SCRIPTS_DIR/amplify-deploy.sh"

ok "STEP 3 complete — Amplify frontend deployed"

# ────────────────────────────────────────────────────────────────────────────
# Final summary
# ────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "\033[0;36m══════════════════════════════════════════════════════\033[0m"
echo -e "\033[0;32m🥐 Post-deploy complete — system is fully live!\033[0m"
echo -e "\033[0;36m══════════════════════════════════════════════════════\033[0m"
echo ""
RUNTIME_ARN=$(python3 -c "import json; print(json.load(open('$AGENTCORE_CONFIG'))['agentRuntimeArn'])" 2>/dev/null || echo "(see agentcore-config.json)")
POOL_ID=$(python3 -c "import json; print(json.load(open('$COGNITO_CONFIG'))['UserPoolId'])" 2>/dev/null || echo "(see cognito-config.json)")
echo -e "  Cognito User Pool  : $POOL_ID"
echo -e "  AgentCore Runtime  : $RUNTIME_ARN"
echo -e "  Region             : $REGION"
echo ""
echo -e "\033[1;33mNext steps:\033[0m"
echo -e "  • Open the Amplify URL printed above in a browser"
echo -e "  • Sign in with the credentials you created in Step 1"
echo -e "  • Run smoke test: make smoke"
echo -e "\033[0;36m══════════════════════════════════════════════════════\033[0m"
