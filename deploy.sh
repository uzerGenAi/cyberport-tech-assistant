#!/usr/bin/env bash
# One-command, resumable deployment of the Cyberport Tech Assistant (eu-central-1).
#
#   ./deploy.sh                  run every step (safe to re-run: finished work is skipped)
#   ./deploy.sh status           show what already exists in this AWS account
#   ./deploy.sh list             list the step names
#   ./deploy.sh from <step>      resume at a step (use after fixing a failure)
#   ./deploy.sh only <step>      run one step
#
# Options (environment variables):
#   FORCE=1      also rebuild and ship the agent code (use after changing code)
#   YES=1        do not ask to confirm the AWS account
#   SKIP_CI=1    skip the local validation step
#   SKIP_STEPS="docs kbs"   skip the named steps (used by the CI pipeline's toggles)
#
# Every step logs to .deploy-logs/<step>.log. On failure the script stops, names the step and
# the log, and a re-run continues from there: each step is idempotent.
set -eo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

REGION="eu-central-1"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" REGION AWS_PAGER=""
LOG_DIR="$ROOT/.deploy-logs"
ENV_FILE="$HOME/environment/env.sh"
mkdir -p "$LOG_DIR"

say()  { printf '\033[0;34mℹ  %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m✅ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠  %s\033[0m\n' "$*"; }
die()  { printf '\033[0;31m❌ %s\033[0m\n' "$*" >&2; exit 1; }
hdr()  { printf '\n\033[0;36m━━ %s\033[0m\n' "$*"; }

STEPS=(preflight state ci backends seed orders docs kbs role guardrail app user harness test)

# ── helpers ──────────────────────────────────────────────────────────────────
refresh_env() {
    # setup_env.sh rediscovers every resource by name and rewrites ~/environment/env.sh
    bash "$ROOT/setup_env.sh" >"$LOG_DIR/setup_env.log" 2>&1 || warn "setup_env.sh reported a problem (see $LOG_DIR/setup_env.log)"
    # shellcheck disable=SC1090
    [ -f "$ENV_FILE" ] && source "$ENV_FILE"
}
have_all_kbs() {
    local d
    for d in MENU ORDERS PAYMENTS STORES; do
        [ -n "$(eval "echo \${${d}_KNOWLEDGE_BASE_ID:-}")" ] || return 1
    done
}
account_id() { aws sts get-caller-identity --query Account --output text 2>/dev/null; }

# ── steps ────────────────────────────────────────────────────────────────────
s_preflight() {
    [ -f .venv/bin/activate ] || die "No .venv. Create it once:  python3 -m venv .venv && source .venv/bin/activate && pip install -r 6_deploy/agents/requirements-deploy.txt awscurl"
    # shellcheck disable=SC1091
    source .venv/bin/activate
    local c
    for c in aws terraform jq python3 make; do
        command -v "$c" >/dev/null 2>&1 || die "$c is not installed"
    done
    python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' \
        || die "Python 3.10 or later is needed ($(python3 --version 2>&1)). Recreate .venv with a newer python3."
    local tfv
    tfv=$(terraform version -json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || echo 0)
    python3 -c "import sys; v=[int(x) for x in '$tfv'.split('.')[:2]]; sys.exit(v < [1, 10])" 2>/dev/null \
        || die "Terraform 1.10 or later is needed (found $tfv): it uses S3 native state locking. brew install hashicorp/tap/terraform"
    python3 -c "import bedrock_agentcore_starter_toolkit, bedrock_agentcore, strands" 2>/dev/null \
        || die "Python deployment packages are missing. Run: source .venv/bin/activate && pip install -r 6_deploy/agents/requirements-deploy.txt awscurl"
    local arn acct
    arn=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null) || die "No working AWS credentials (aws sts get-caller-identity failed). Run: aws configure"
    acct=$(account_id)
    say "AWS identity : $arn"
    say "Account      : $acct   Region: $REGION"
    if [ -n "${TF_STATE_BUCKET:-}" ]; then
        say "State bucket : $TF_STATE_BUCKET (from TF_STATE_BUCKET)"
        # A name carrying another account's ID is usually a leftover export from an earlier account
        case "$TF_STATE_BUCKET" in
            *"$acct"*) ;;
            *[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*)
                say "⚠️  TF_STATE_BUCKET contains a different account ID than $acct. If you switched accounts, 'unset TF_STATE_BUCKET' (and remove it from your shell profile) before the first deploy." ;;
        esac
    fi
    if [ "${YES:-0}" != "1" ] && [ -t 0 ]; then
        read -r -p "Deploy to THIS account? [y/N] " a
        case "$a" in y|Y|yes) ;; *) die "Aborted. Switch credentials (aws configure / AWS_PROFILE) and re-run." ;; esac
    fi
    # Every model the deploy uses, checked now rather than 40 minutes in
    local missing
    missing=$(python3 - "$REGION" <<'PY'
import json, sys
import boto3
rt = boto3.client("bedrock-runtime", region_name=sys.argv[1])
missing = []
for label, model in (("Amazon Nova Pro (assistant)", "eu.amazon.nova-pro-v1:0"),
                     ("Amazon Nova 2 Lite (harness-manager)", "eu.amazon.nova-2-lite-v1:0")):
    try:
        rt.converse(modelId=model, messages=[{"role": "user", "content": [{"text": "Reply with OK"}]}],
                    inferenceConfig={"maxTokens": 10})
    except Exception as e:  # noqa: BLE001
        missing.append(f"{label}: {model} ({type(e).__name__})")
try:
    rt.invoke_model(modelId="amazon.titan-embed-text-v2:0",
                    body=json.dumps({"inputText": "ok", "dimensions": 1024}))
except Exception as e:  # noqa: BLE001
    missing.append(f"Titan Text Embeddings V2 (knowledge bases): amazon.titan-embed-text-v2:0 ({type(e).__name__})")
print("\n".join(missing))
PY
)
    [ -z "$missing" ] || die "Bedrock model access is missing in $REGION for:
$missing
   Enable them in the Bedrock console (Model access), then re-run ./deploy.sh"
    ok "Credentials, tool versions and model access (Nova Pro, Nova 2 Lite, Titan Embeddings V2) are fine"
}
s_state()   { bash 6_deploy/scripts/terraform_backend_setup.sh; }
s_ci() {
    [ "${SKIP_CI:-0}" = "1" ] && { say "SKIP_CI=1: skipping local validation"; return 0; }
    make ci
}
s_backends() { bash 6_deploy/scripts/agentcore_backends.sh apply; }
s_seed() {
    bash 6_deploy/scripts/agentcore_backends.sh seed
    bash 6_deploy/scripts/agentcore_backends.sh check
}
s_orders() {
    refresh_env
    (cd 2_data_strategy/orders && python3 orders_load_helper_script.py)
}
s_docs() {
    refresh_env
    ./deploy_agentcore.sh step3-s3-bucket
    refresh_env
}
s_kbs() {
    refresh_env
    if have_all_kbs; then
        # Already created: re-sync them, so edited documents (uploaded by the docs step) are re-indexed
        ok "All four knowledge bases exist: re-syncing their documents"
        ./deploy_agentcore.sh step5-knowledge-bases
        return 0
    fi
    warn "Creating the vector store and 4 knowledge bases takes 15-20 minutes. OpenSearch Serverless bills"
    warn "about \$350/month while it exists: delete it when you are done (see DEPLOY.md, Tear down)."
    make knowledge-bases
    refresh_env
    have_all_kbs || die "Not every knowledge base exists after the run: check $LOG_DIR/kbs.log, then re-run ./deploy.sh from kbs"
}
s_role() {
    refresh_env
    ./deploy_agentcore.sh step2-iam-role
}
s_guardrail() {
    refresh_env
    if [ -n "${GUARDRAIL_ID:-}" ] && [ "${FORCE:-0}" != "1" ]; then
        ok "Guardrail already stored in Parameter Store ($GUARDRAIL_ID): skipping (FORCE=1 re-applies its policies)"
        return 0
    fi
    bash 5_security_rai/create_and_store_guardrail.sh
    refresh_env
}
s_app() {
    refresh_env
    # The sign-in user comes from the `user` step, so this never stops to ask for one
    if [ "${FORCE:-0}" = "1" ]; then
        SKIP_USER_CREATION=1 make post-deploy-force
    else
        SKIP_USER_CREATION=1 make post-deploy
    fi
}
s_user() {
    # Default web-app login (idempotent): created or repaired every run, password in Secrets Manager
    python3 6_deploy/scripts/ensure_demo_user.py
}
s_harness() {
    # harness-manager: config-defined AgentCore harness (order lookup and cancellation), idempotent
    refresh_env
    python3 6_deploy/harness/deploy_harness.py deploy
}
s_test() {
    refresh_env
    ./deploy_agentcore.sh step9-test-runtime
    local dom
    dom=$(aws amplify list-apps --region "$REGION" --query "apps[?name=='spbc-tech-assistant'].defaultDomain | [0]" --output text 2>/dev/null || true)
    echo
    ok "Deployment complete"
    if [ -n "$dom" ] && [ "$dom" != "None" ]; then
        say "Web app: https://main.${dom}"
    fi
    python3 6_deploy/scripts/ensure_demo_user.py --show || warn "Could not read the sign-in user: ./deploy.sh only user"
}

# ── status ───────────────────────────────────────────────────────────────────
cmd_status() {
    local acct
    acct=$(account_id) || die "No working AWS credentials"
    say "Account $acct, region $REGION"
    chk() { # label, command that prints a value when the resource exists
        local v; v=$(eval "$2" 2>/dev/null || true)
        if [ -n "$v" ] && [ "$v" != "None" ]; then printf '  \033[0;32m✔\033[0m %-26s %s\n' "$1" "$v"; else printf '  \033[0;31m✘\033[0m %-26s missing\n' "$1"; fi
    }
    chk "state bucket"        "aws s3api head-bucket --bucket \${TF_STATE_BUCKET:-spbc-tfstate-$acct} >/dev/null 2>&1 && echo \${TF_STATE_BUCKET:-spbc-tfstate-$acct}"
    chk "Aurora cluster"      "aws rds describe-db-clusters --db-cluster-identifier spbc-aurora-cluster --region $REGION --query 'DBClusters[0].Status' --output text"
    chk "orders table"        "aws dynamodb describe-table --table-name spbc-orders-table --region $REGION --query 'Table.TableStatus' --output text"
    chk "promotions API"      "aws apigatewayv2 get-apis --region $REGION --query \"Items[?Name=='spbcPromotionsAPI'].ApiEndpoint|[0]\" --output text"
    chk "promotions bucket"   "aws s3api head-bucket --bucket spbc-promotions-$acct >/dev/null 2>&1 && echo spbc-promotions-$acct"
    chk "docs bucket"         "aws s3api head-bucket --bucket spbc-kb-docs-$acct >/dev/null 2>&1 && echo spbc-kb-docs-$acct"
    chk "knowledge bases"     "aws bedrock-agent list-knowledge-bases --region $REGION --query \"length(knowledgeBaseSummaries[?starts_with(name,'spbc-')])\" --output text | grep -v '^0\$'"
    chk "OpenSearch collection" "aws opensearchserverless list-collections --region $REGION --query \"collectionSummaries[?name=='spbc-electronics-vectors'].status|[0]\" --output text"
    chk "execution role"      "aws iam get-role --role-name SPBC-AgentCore-ExecutionRole --query Role.RoleName --output text"
    chk "guardrail (SSM)"     "aws ssm get-parameter --name /SPBC/guardrail/id --region $REGION --query Parameter.Value --output text"
    chk "AgentCore Memory"    "aws bedrock-agentcore-control list-memories --region $REGION --query \"memories[?starts_with(id,'spbc_tech_assistant_memory-')].status|[0]\" --output text"
    chk "AgentCore runtime"   "aws bedrock-agentcore-control list-agent-runtimes --region $REGION --query \"agentRuntimes[?agentRuntimeName=='tech_assistant_agent'].status|[0]\" --output text"
    chk "default sign-in user" "aws secretsmanager describe-secret --secret-id spbc-demo-user --region $REGION --query Name --output text"
    chk "Cognito user pool"   "aws cognito-idp list-user-pools --max-results 60 --region $REGION --query \"UserPools[?Name=='spbcuserpool'].Id|[0]\" --output text"
    chk "harness-manager"     "aws bedrock-agentcore-control list-harnesses --region $REGION --query \"harnesses[?harnessName=='harness_manager'].status|[0]\" --output text"
    chk "order-admin gateway" "aws bedrock-agentcore-control list-gateways --region $REGION --query \"items[?name=='spbc-order-admin-gateway'].status|[0]\" --output text"
    chk "Amplify app"         "aws amplify list-apps --region $REGION --query \"apps[?name=='spbc-tech-assistant'].defaultDomain|[0]\" --output text"
}

# ── driver ───────────────────────────────────────────────────────────────────
run_step() {
    local name="$1" log="$LOG_DIR/$1.log" start=$SECONDS
    hdr "Step: $name"
    if ! "s_$name" 2>&1 | tee "$log"; then
        echo
        die "Step '$name' failed. Log: $log
   Fix the cause shown above, then continue with:  ./deploy.sh from $name
   (finished steps are skipped or harmless to repeat)"
    fi
    ok "$name done in $((SECONDS - start))s"
}
valid_step() { local s; for s in "${STEPS[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

# preflight activates the venv; later steps need it in this shell, so always run it first
ensure_venv() {
    [ -f .venv/bin/activate ] && source .venv/bin/activate || true
}

main() {
    local cmd="${1:-all}" arg="${2:-}" s started=0
    case "$cmd" in
        -h|--help|help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        list)   printf '%s\n' "${STEPS[@]}"; exit 0 ;;
        status) ensure_venv; cmd_status; exit 0 ;;
        all)    ;;
        from|only) valid_step "$arg" || die "Unknown step '$arg'. Steps: ${STEPS[*]}" ;;
        *) die "Unknown command '$cmd'. Use: all | status | list | from <step> | only <step>" ;;
    esac
    ensure_venv
    for s in "${STEPS[@]}"; do
        [ "$s" = "$arg" ] && started=1
        case "$cmd" in
            all)  ;;
            # preflight always runs: it checks credentials, tools and model access
            from) [ "$s" = preflight ] || [ "$started" = 1 ] || continue ;;
            only) [ "$s" = preflight ] || [ "$s" = "$arg" ] || continue ;;
        esac
        case " ${SKIP_STEPS:-} " in
            *" $s "*) [ "$s" = preflight ] || { say "SKIP_STEPS: skipping $s"; continue; } ;;
        esac
        run_step "$s"
    done
}
main "$@"
