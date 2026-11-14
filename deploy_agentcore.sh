#!/usr/bin/env bash
set -euo pipefail
###############################################################################
# deploy_agentcore.sh — lower-level AgentCore steps that ./deploy.sh calls (docs bucket, runtime role, tests)
#
# Project : SPBC Tech Assistant (Amazon Bedrock AgentCore Runtime)
# Region  : eu-central-1
# Models  : Nova Pro via the EU cross-Region inference profile eu.amazon.nova-pro-v1:0
#           (no in-Region on-demand capacity in eu-central-1)
#           + amazon.titan-embed-text-v2:0 (1024 dimensions) for the knowledge bases
#
# Usage:
#   ./deploy_agentcore.sh deploy-all             # all steps (KBs must already exist, see below)
#
#   ./deploy_agentcore.sh step1-model-access     # Nova Pro (EU profile) + Titan V2 answer
#   ./deploy_agentcore.sh step2-iam-role         # execution role: trust + baseline + app policy
#   ./deploy_agentcore.sh step3-s3-bucket        # bucket + the exact object layout the code needs
#   ./deploy_agentcore.sh step5-knowledge-bases  # discover KBs by name, sync, verify
#   ./deploy_agentcore.sh step6-guardrail        # guardrail + numbered version
#   ./deploy_agentcore.sh step7-package-zip      # artifact option A: direct code deployment zip
#   ./deploy_agentcore.sh step7-ecr-build-push   # artifact option B: linux/arm64 container image
#   ./deploy_agentcore.sh step8-create-runtime   # create or update the runtime, require MMDSv2
#   ./deploy_agentcore.sh step9-test-runtime     # one prompt per domain
#   ./deploy_agentcore.sh step10-generate-config # write 6_deploy/web-app/agentcore-config.json
#
#   ./deploy_agentcore.sh status                 # runtime status, version, MMDSv2, network
#   ./deploy_agentcore.sh teardown               # delete what this script created
#
# Knowledge bases: OpenSearch Serverless needs a vector index created through its data-plane
# API before a KB can use it, so create the KBs in the console with quick-create (walkthrough
# Step 4). step5 then finds them by name (spbc-<domain>-knowledge-base), syncs and verifies them.
#
# Prerequisites:
#   - AWS CLI v2, recent enough for `bedrock-agentcore-control update-agent-runtime
#     --metadata-configuration` (MMDSv2)
#   - jq
#   - uv or pip (step7-package-zip) / Docker (step7-ecr-build-push)
#   - Backends for orders/stores/promos (walkthrough Step 2): the Terraform stack
#     6_deploy/infra/agentcore-backends (bash 6_deploy/scripts/agentcore_backends.sh apply + seed).
#     Its outputs are read automatically when STORES_DB_* / PROMOS_API_URL aren't set.
###############################################################################

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration — edit these or override via environment variables
# ─────────────────────────────────────────────────────────────────────────────

REGION="${REGION:-eu-central-1}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "UNKNOWN")}"
PROJECT_PREFIX="${PROJECT_PREFIX:-spbc}"

# Naming
ROLE_NAME="${ROLE_NAME:-SPBC-AgentCore-ExecutionRole}"
BUCKET_NAME="${BUCKET_NAME:-spbc-kb-docs-${ACCOUNT_ID}}"
ECR_REPO_NAME="${ECR_REPO_NAME:-spbc-tech-assistant}"
RUNTIME_NAME="${RUNTIME_NAME:-tech_assistant_agent}"
GUARDRAIL_NAME="${GUARDRAIL_NAME:-SPBC-Guardrail}"

# Artifact: "container" (ECR image) or "zip" (direct code deployment, no Docker).
# Default to container: it is the canonical path for both CI and manual deploys
# (post_deploy.sh / configure_runtime.py). AWS forbids changing a runtime's artifact
# type after creation, so a manual `deploy-all` defaulting to zip would create a zip
# runtime conflicting with the canonical container one. zip stays available as the
# Docker-free fallback via `ARTIFACT_TYPE=zip` or the step7-package-zip subcommand.
ARTIFACT_TYPE="${ARTIFACT_TYPE:-container}"
PYTHON_VERSION="3.11"
PYTHON_RUNTIME="PYTHON_3_11"
ENTRYPOINT_FILE="tech_assistant_agent.py"

# Network: PUBLIC unless both are set. With the Terraform backends (RDS Data API, IAM-authorized
# promotions API) PUBLIC is enough. Only the legacy MySQL store lookup needs VPC mode to reach a
# private Aurora cluster; then use private subnets whose route table sends 0.0.0.0/0 to a NAT gateway.
SUBNET_IDS="${SUBNET_IDS:-}"                 # comma-separated subnet IDs
SECURITY_GROUP_IDS="${SECURITY_GROUP_IDS:-}" # comma-separated security group IDs

# Backends (Terraform stack 6_deploy/infra/agentcore-backends). Unset values are read from its
# outputs; without them the agents fall back to legacy discovery (a cluster named
# spbc-aurora-cluster* over MySQL, an API named spbcPromotionsAPI).
STORES_DB_CLUSTER_ARN="${STORES_DB_CLUSTER_ARN:-}"
STORES_DB_SECRET_ARN="${STORES_DB_SECRET_ARN:-}"
STORES_DB_NAME="${STORES_DB_NAME:-}"
PROMOS_API_URL="${PROMOS_API_URL:-}"

# Models
LLM_MODEL_ID="eu.amazon.nova-pro-v1:0"
LLM_MODEL_ARN="arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:inference-profile/${LLM_MODEL_ID}"
EMBED_MODEL_ID="amazon.titan-embed-text-v2:0"

# Knowledge base domains. Promotions have no knowledge base: the promos agent reads them from the
# promotions API (a Lambda that reads the promotions file in S3).
KB_DOMAINS=("menu" "orders" "payments" "stores")
REQUIRED_KB_DOMAINS="menu orders payments stores"
# Removed domains: teardown still deletes their knowledge base if an earlier deployment created one
LEGACY_KB_DOMAINS=("promos")

# The agent modules the runtime imports (all are required)
AGENT_MODULES=("tech_assistant_agent.py" "menu_agents.py" "orders_agents.py" "place_order.py"
               "payments_policy_agents.py" "stores_agents.py" "promos_agents.py")

# Paths (relative to this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="${SCRIPT_DIR}/6_deploy/agents"
WEBAPP_DIR="${SCRIPT_DIR}/6_deploy/web-app"
DATA_DIR="${SCRIPT_DIR}/2_data_strategy"
BACKENDS_DIR="${BACKENDS_DIR:-${SCRIPT_DIR}/6_deploy/infra/agentcore-backends}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*" >&2; }
info()  { echo -e "${CYAN}[→]${NC} $*"; }
header(){ echo -e "\n${CYAN}═══════════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}\n"; }

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

kb_env_var() { echo "$(echo "$1" | tr '[:lower:]' '[:upper:]')_KNOWLEDGE_BASE_ID"; }

kb_id_by_domain() {
    local id
    id=$(aws bedrock-agent list-knowledge-bases --region "$REGION" \
        --query "knowledgeBaseSummaries[?name=='${PROJECT_PREFIX}-${1}-knowledge-base'].knowledgeBaseId | [0]" \
        --output text 2>/dev/null || true)
    if [ "$id" = "None" ]; then id=""; fi
    echo "$id"
}

# Fills <DOMAIN>_KNOWLEDGE_BASE_ID for any domain not already set in the environment.
discover_kb_ids() {
    local domain env_var kb_id
    for domain in "${KB_DOMAINS[@]}"; do
        env_var=$(kb_env_var "$domain")
        if [ -z "${!env_var:-}" ]; then
            kb_id=$(kb_id_by_domain "$domain")
            if [ -n "$kb_id" ]; then
                export "${env_var}=${kb_id}"
            fi
        fi
    done
}

runtime_id_by_name() {
    local id
    id=$(aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" \
        --query "agentRuntimes[?agentRuntimeName=='${RUNTIME_NAME}'].agentRuntimeId | [0]" \
        --output text 2>/dev/null || true)
    if [ "$id" = "None" ]; then id=""; fi
    echo "$id"
}

# Polls until the runtime reaches a terminal status. Returns 0 only for READY.
wait_runtime_ready() {
    local id="$1" max_wait="${2:-900}" elapsed=0 status="UNKNOWN"
    while [ "$elapsed" -lt "$max_wait" ]; do
        status=$(aws bedrock-agentcore-control get-agent-runtime --region "$REGION" \
            --agent-runtime-id "$id" --query 'status' --output text 2>/dev/null || echo "UNKNOWN")
        echo -ne "\r  Status: ${status} (${elapsed}s / ${max_wait}s)   "
        case "$status" in
            READY) echo ""; return 0 ;;
            CREATE_FAILED|UPDATE_FAILED|DELETE_FAILED)
                echo ""
                err "Runtime status ${status}: $(aws bedrock-agentcore-control get-agent-runtime \
                    --region "$REGION" --agent-runtime-id "$id" --query 'failureReason' --output text 2>/dev/null || true)"
                return 1 ;;
        esac
        sleep 15
        elapsed=$((elapsed + 15))
    done
    echo ""
    err "Timed out waiting for READY (last status: ${status})"
    return 1
}

# Since 30 June 2026 AgentCore rejects invocations on runtimes without requireMMDSV2=true.
# CreateAgentRuntime can't set it, and UpdateAgentRuntime replaces the whole configuration,
# so the current configuration is read back and re-sent with MMDSv2 added.
ensure_mmdsv2() {
    local id="$1" current update_file status mmds elapsed=0
    current=$(aws bedrock-agentcore-control get-agent-runtime --region "$REGION" \
        --agent-runtime-id "$id" --output json)
    if [ "$(echo "$current" | jq -r '.metadataConfiguration.requireMMDSV2 // false')" = "true" ]; then
        log "MMDSv2 is already required"
        return 0
    fi

    update_file=$(mktemp)
    echo "$current" | jq --arg id "$id" '
        {agentRuntimeId: $id}
        + with_entries(
            select(.key as $k
                | ["agentRuntimeArtifact", "roleArn", "networkConfiguration", "description",
                   "authorizerConfiguration", "requestHeaderConfiguration", "protocolConfiguration",
                   "lifecycleConfiguration", "environmentVariables", "filesystemConfigurations",
                   "capacityProviderConfiguration", "platformVersion"]
                | index($k) != null)
            | select(.value != null and .value != "" and .value != {} and .value != []))
        + {metadataConfiguration: {requireMMDSV2: true}}' > "$update_file"

    # Never send an update without the env vars: the container would crash at import.
    if ! jq -e '(.environmentVariables // {}) | length > 0' "$update_file" >/dev/null; then
        rm -f "$update_file"
        err "GetAgentRuntime returned no environment variables; not updating (it would clear them)."
        err "Enable MMDSv2 in the console instead (runtime → Edit → require MMDSv2)."
        return 1
    fi

    info "Enabling MMDSv2 (requireMMDSV2=true) — this creates a new runtime version..."
    if ! aws bedrock-agentcore-control update-agent-runtime --region "$REGION" \
        --cli-input-json "file://${update_file}" >/dev/null; then
        rm -f "$update_file"
        err "update-agent-runtime failed. If the error mentions metadataConfiguration, upgrade AWS CLI v2."
        return 1
    fi
    rm -f "$update_file"

    sleep 10
    while [ "$elapsed" -lt 900 ]; do
        current=$(aws bedrock-agentcore-control get-agent-runtime --region "$REGION" \
            --agent-runtime-id "$id" --output json)
        status=$(echo "$current" | jq -r '.status')
        mmds=$(echo "$current" | jq -r '.metadataConfiguration.requireMMDSV2 // false')
        if [ "$status" = "READY" ] && [ "$mmds" = "true" ]; then
            log "MMDSv2 required (runtime version $(echo "$current" | jq -r '.agentRuntimeVersion'))"
            return 0
        fi
        case "$status" in
            *FAILED) err "Runtime update failed: $(echo "$current" | jq -r '.failureReason // "see console"')"; return 1 ;;
        esac
        sleep 15
        elapsed=$((elapsed + 15))
    done
    err "Timed out waiting for the MMDSv2 update to apply"
    return 1
}

check_agent_sources() {
    local missing=0 f
    for f in "${AGENT_MODULES[@]}" requirements.txt; do
        if [ ! -f "${AGENTS_DIR}/${f}" ]; then
            err "Missing ${AGENTS_DIR}/${f}"
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        exit 1
    fi
}

# Same formats configure_runtime.py accepts
STORES_CLUSTER_ARN_RE='^arn:aws[a-z-]*:rds:[a-z0-9-]+:[0-9]{12}:cluster:[A-Za-z0-9-]+$'
STORES_SECRET_ARN_RE='^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@!-]+$'
PROMOS_URL_RE='^https://([a-z0-9]+)\.execute-api\.([a-z0-9-]+)\.amazonaws\.com/([A-Za-z0-9_-]+)/promotions$'

# Fills STORES_DB_* / PROMOS_API_URL from the backends stack's Terraform outputs when unset.
load_backends_env() {
    local outputs key value
    if [ -n "$STORES_DB_CLUSTER_ARN" ] && [ -n "$STORES_DB_SECRET_ARN" ] && [ -n "$PROMOS_API_URL" ]; then
        return 0
    fi
    if ! command -v terraform &>/dev/null || [ ! -d "${BACKENDS_DIR}/.terraform" ]; then
        return 0
    fi
    if ! outputs=$(terraform -chdir="$BACKENDS_DIR" output -json agentcore_runtime_env 2>/dev/null) \
        || ! echo "$outputs" | jq -e 'type == "object"' >/dev/null 2>&1; then
        return 0
    fi
    for key in STORES_DB_CLUSTER_ARN STORES_DB_SECRET_ARN STORES_DB_NAME PROMOS_API_URL; do
        if [ -z "${!key}" ]; then
            value=$(echo "$outputs" | jq -r --arg k "$key" '.[$k] // empty')
            printf -v "$key" '%s' "$value"
        fi
    done
    info "Backends: read from the Terraform outputs in ${BACKENDS_DIR}"
}

# Both stores values or neither, and every value well-formed: a half-configured runtime would
# silently fall back to legacy discovery.
check_backends_env() {
    if { [ -n "$STORES_DB_CLUSTER_ARN" ] && [ -z "$STORES_DB_SECRET_ARN" ]; } \
        || { [ -z "$STORES_DB_CLUSTER_ARN" ] && [ -n "$STORES_DB_SECRET_ARN" ]; }; then
        err "Set both STORES_DB_CLUSTER_ARN and STORES_DB_SECRET_ARN (Data API) or neither (legacy)."
        exit 1
    fi
    if [ -n "$STORES_DB_CLUSTER_ARN" ] && ! [[ "$STORES_DB_CLUSTER_ARN" =~ $STORES_CLUSTER_ARN_RE ]]; then
        err "STORES_DB_CLUSTER_ARN isn't an Aurora cluster ARN: ${STORES_DB_CLUSTER_ARN}"
        exit 1
    fi
    if [ -n "$STORES_DB_SECRET_ARN" ] && ! [[ "$STORES_DB_SECRET_ARN" =~ $STORES_SECRET_ARN_RE ]]; then
        err "STORES_DB_SECRET_ARN isn't a Secrets Manager secret ARN: ${STORES_DB_SECRET_ARN}"
        exit 1
    fi
    if [ -n "$PROMOS_API_URL" ] && ! [[ "$PROMOS_API_URL" =~ $PROMOS_URL_RE ]]; then
        err "PROMOS_API_URL must look like https://<api-id>.execute-api.<region>.amazonaws.com/<stage>/promotions"
        err "  got: ${PROMOS_API_URL}"
        exit 1
    fi
}

# Execution-role statements for the stores database and the promotions API, as a JSON array.
# Terraform backends: exactly their resources. Otherwise: what legacy discovery calls.
backend_policy_statements() {
    local stores promos
    if [ -n "$STORES_DB_CLUSTER_ARN" ]; then
        stores=$(jq -n --arg c "$STORES_DB_CLUSTER_ARN" --arg s "$STORES_DB_SECRET_ARN" '[
            {Sid: "StoresDataApi", Effect: "Allow", Action: "rds-data:ExecuteStatement", Resource: $c},
            {Sid: "StoresReaderSecret", Effect: "Allow", Action: "secretsmanager:GetSecretValue", Resource: $s}]')
    else
        stores=$(jq -n --arg r "$REGION" --arg a "$ACCOUNT_ID" '[
            {Sid: "StoresDiscovery", Effect: "Allow", Action: "rds:DescribeDBClusters",
             Resource: "arn:aws:rds:\($r):\($a):cluster:*"},
            {Sid: "StoresSecret", Effect: "Allow", Action: "secretsmanager:GetSecretValue",
             Resource: "arn:aws:secretsmanager:\($r):\($a):secret:spbc-aurora-db-credentials-*"}]')
    fi
    if [ -n "$PROMOS_API_URL" ] && [[ "$PROMOS_API_URL" =~ $PROMOS_URL_RE ]]; then
        promos=$(jq -n --arg arn "arn:aws:execute-api:${BASH_REMATCH[2]}:${ACCOUNT_ID}:${BASH_REMATCH[1]}/${BASH_REMATCH[3]}/GET/promotions" '[
            {Sid: "PromotionsApi", Effect: "Allow", Action: "execute-api:Invoke", Resource: $arn}]')
    else
        promos=$(jq -n --arg r "$REGION" --arg a "$ACCOUNT_ID" '[
            {Sid: "PromosApiLookup", Effect: "Allow", Action: "apigateway:GET",
             Resource: ["arn:aws:apigateway:\($r)::/apis", "arn:aws:apigateway:\($r)::/restapis"]},
            {Sid: "PromotionsApiInvoke", Effect: "Allow", Action: "execute-api:Invoke",
             Resource: "arn:aws:execute-api:\($r):\($a):*/prod/GET/promotions"}]')
    fi
    jq -n --argjson s "$stores" --argjson p "$promos" '$s + $p'
}

# Puts SPBC-AgentCore-Backends on the execution role so its permissions match the runtime's env.
put_backends_policy() {
    local doc
    doc=$(backend_policy_statements | jq '{Version: "2012-10-17", Statement: .}')
    info "Attaching inline policy SPBC-AgentCore-Backends ($(echo "$doc" | jq -r '[.Statement[].Sid] | join(", ")'))"
    aws iam put-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-name "SPBC-AgentCore-Backends" \
        --policy-document "$doc"
}

# ─────────────────────────────────────────────────────────────────────────────
# Preflight checks
# ─────────────────────────────────────────────────────────────────────────────

preflight() {
    header "Preflight Checks"

    if ! command -v aws &>/dev/null; then
        err "AWS CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
        exit 1
    fi
    log "AWS CLI: $(aws --version 2>&1 | head -1)"

    if ! command -v jq &>/dev/null; then
        err "jq not found. Install: brew install jq (macOS) or dnf/apt-get install jq (Linux)"
        exit 1
    fi
    log "jq: $(jq --version)"

    if ! aws sts get-caller-identity &>/dev/null || [ "$ACCOUNT_ID" = "UNKNOWN" ]; then
        err "AWS credentials not configured. Run: aws configure"
        exit 1
    fi

    local probe
    if ! probe=$(aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" \
        --query 'length(agentRuntimes)' --output text 2>&1 >/dev/null); then
        if echo "$probe" | grep -qi "invalid choice"; then
            err "This AWS CLI has no bedrock-agentcore-control commands. Upgrade AWS CLI v2."
            exit 1
        fi
        warn "list-agent-runtimes failed (check permissions): ${probe}"
    fi

    log "Account:  ${ACCOUNT_ID}"
    log "Region:   ${REGION}"
    log "Identity: $(aws sts get-caller-identity --query Arn --output text)"

    load_backends_env
    check_backends_env
    if [ -n "$STORES_DB_CLUSTER_ARN" ]; then
        log "Stores:   RDS Data API (${STORES_DB_CLUSTER_ARN##*:})"
    else
        warn "Stores:   legacy MySQL discovery (deploy 6_deploy/infra/agentcore-backends for the Data API)"
    fi
    if [ -n "$PROMOS_API_URL" ]; then
        log "Promos:   ${PROMOS_API_URL}"
    else
        warn "Promos:   legacy lookup of an API named spbcPromotionsAPI"
    fi
    echo ""
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1 — Confirm Bedrock model access
# ═════════════════════════════════════════════════════════════════════════════

step1_model_access() {
    header "Step 1 — Confirm Bedrock model access"

    info "Serverless models are enabled automatically (the console 'Model access' page is retired)."
    info "Nova Pro has no in-Region on-demand capacity in ${REGION}; it is called through ${LLM_MODEL_ID}."

    if aws bedrock get-inference-profile --region "$REGION" \
        --inference-profile-identifier "$LLM_MODEL_ID" --query 'inferenceProfileId' --output text >/dev/null 2>&1; then
        log "Inference profile exists: ${LLM_MODEL_ID}"
    else
        err "Inference profile ${LLM_MODEL_ID} not found in ${REGION}"
        exit 1
    fi

    local reply
    if reply=$(aws bedrock-runtime converse --region "$REGION" --model-id "$LLM_MODEL_ID" \
        --messages '[{"role":"user","content":[{"text":"Reply with OK"}]}]' \
        --inference-config '{"maxTokens":5}' \
        --query 'output.message.content[0].text' --output text 2>&1); then
        log "Nova Pro replied: ${reply}"
    else
        err "Nova Pro invocation failed: ${reply}"
        err "Check IAM and SCPs: the EU profile also routes to eu-north-1, eu-west-1 and eu-west-3."
        exit 1
    fi

    if aws bedrock get-foundation-model --region "$REGION" --model-identifier "$EMBED_MODEL_ID" \
        --query 'modelDetails.modelId' --output text >/dev/null 2>&1; then
        log "Embedding model available: ${EMBED_MODEL_ID}"
    else
        err "Embedding model ${EMBED_MODEL_ID} not available in ${REGION}"
        exit 1
    fi

    log "Step 1 complete."
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2 — Create the AgentCore execution role (IAM)
# ═════════════════════════════════════════════════════════════════════════════

step2_iam_role() {
    header "Step 2 — Create AgentCore Execution Role (IAM)"

    # Trust policy with confused-deputy protection (aws:SourceAccount / aws:SourceArn)
    local trust_policy
    trust_policy=$(cat <<TRUST
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "bedrock-agentcore.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "${ACCOUNT_ID}" },
        "ArnLike": { "aws:SourceArn": "arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT_ID}:*" }
      }
    }
  ]
}
TRUST
)

    if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
        log "Role '${ROLE_NAME}' already exists — updating trust policy"
        aws iam update-assume-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-document "$trust_policy"
    else
        info "Creating IAM role: ${ROLE_NAME}"
        aws iam create-role \
            --role-name "$ROLE_NAME" \
            --assume-role-policy-document "$trust_policy" \
            --description "Execution role for SPBC AgentCore runtime" \
            --tags Key=Project,Value=SPBC Key=Component,Value=AgentCore >/dev/null
        log "Role created: ${ROLE_NAME}"
    fi

    # Baseline runtime permissions (ECR pull, logs, X-Ray, metrics, workload identity) plus
    # exactly what the agent code calls (models, KBs, guardrail, S3, DynamoDB). The stores database
    # and promotions API are in a second policy, SPBC-AgentCore-Backends (put_backends_policy).
    # NOTE on the two knowledge base statements below: bedrock:Retrieve takes a knowledge-base
    # resource, but bedrock:RetrieveAndGenerate supports no resource types, so scoping it to a
    # knowledge-base ARN denies it. That denial surfaced only at runtime, as the agents
    # answering "there was an error retrieving information".
    local policy_doc
    policy_doc=$(cat <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRImagePull",
      "Effect": "Allow",
      "Action": ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"],
      "Resource": "arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/*"
    },
    {
      "Sid": "ECRToken",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "LogsGroup",
      "Effect": "Allow",
      "Action": ["logs:DescribeLogStreams", "logs:CreateLogGroup"],
      "Resource": "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/aws/bedrock-agentcore/runtimes/*"
    },
    {
      "Sid": "SpansToAgentLogGroup",
      "Effect": "Allow",
      "Action": "logs:PutResourcePolicy",
      "Resource": "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/aws/bedrock-agentcore/runtimes/${RUNTIME_NAME}-*"
    },
    {
      "Sid": "LogsDescribe",
      "Effect": "Allow",
      "Action": "logs:DescribeLogGroups",
      "Resource": "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:*"
    },
    {
      "Sid": "LogsWrite",
      "Effect": "Allow",
      "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*"
    },
    {
      "Sid": "XRay",
      "Effect": "Allow",
      "Action": ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"],
      "Resource": "*"
    },
    {
      "Sid": "Metrics",
      "Effect": "Allow",
      "Action": "cloudwatch:PutMetricData",
      "Resource": "*",
      "Condition": { "StringEquals": { "cloudwatch:namespace": "bedrock-agentcore" } }
    },
    {
      "Sid": "WorkloadIdentity",
      "Effect": "Allow",
      "Action": [
        "bedrock-agentcore:GetWorkloadAccessToken",
        "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
        "bedrock-agentcore:GetWorkloadAccessTokenForUserId"
      ],
      "Resource": [
        "arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT_ID}:workload-identity-directory/default",
        "arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT_ID}:workload-identity-directory/default/workload-identity/${RUNTIME_NAME}-*"
      ]
    },
    {
      "Sid": "NovaProProfileMetadata",
      "Effect": "Allow",
      "Action": "bedrock:GetInferenceProfile",
      "Resource": "arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:inference-profile/${LLM_MODEL_ID}"
    },
    {
      "Sid": "NovaProEuProfile",
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
      "Resource": [
        "arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:inference-profile/${LLM_MODEL_ID}",
        "arn:aws:bedrock:eu-central-1::foundation-model/amazon.nova-pro-v1:0",
        "arn:aws:bedrock:eu-north-1::foundation-model/amazon.nova-pro-v1:0",
        "arn:aws:bedrock:eu-west-1::foundation-model/amazon.nova-pro-v1:0",
        "arn:aws:bedrock:eu-west-3::foundation-model/amazon.nova-pro-v1:0"
      ]
    },
    {
      "Sid": "KnowledgeBaseRetrieve",
      "Effect": "Allow",
      "Action": "bedrock:Retrieve",
      "Resource": "arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:knowledge-base/*"
    },
    {
      "Sid": "KnowledgeBaseRetrieveAndGenerate",
      "Effect": "Allow",
      "Action": "bedrock:RetrieveAndGenerate",
      "Resource": "*"
    },
    {
      "Sid": "Guardrail",
      "Effect": "Allow",
      "Action": "bedrock:ApplyGuardrail",
      "Resource": "arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:guardrail/*"
    },
    {
      "Sid": "MenuJson",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/menu/menu_records.json"
    },
    {
      "Sid": "OrdersTable",
      "Effect": "Allow",
      "Action": ["dynamodb:Query", "dynamodb:PutItem"],
      "Resource": "arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/spbc-orders-table"
    }
  ]
}
POLICY
)
    echo "$policy_doc" | jq empty

    info "Attaching inline permissions policy: SPBC-AgentCore-Permissions"
    aws iam put-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-name "SPBC-AgentCore-Permissions" \
        --policy-document "$policy_doc"

    put_backends_policy

    ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
    log "Role ARN: ${ROLE_ARN}"
    if [ -z "$STORES_DB_CLUSTER_ARN" ]; then
        info "If the legacy Aurora secret uses a customer-managed KMS key, also allow kms:Decrypt on that key."
    fi
    log "Step 2 complete."
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3 — Create the S3 bucket and upload the exact object layout
# ═════════════════════════════════════════════════════════════════════════════

step3_s3_bucket() {
    header "Step 3 — Create S3 Bucket and Upload Data"

    if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
        log "Bucket '${BUCKET_NAME}' already exists"
    else
        info "Creating S3 bucket: ${BUCKET_NAME}"
        aws s3api create-bucket \
            --bucket "$BUCKET_NAME" \
            --region "$REGION" \
            --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
        log "Bucket created: ${BUCKET_NAME}"
    fi

    aws s3api put-public-access-block \
        --bucket "$BUCKET_NAME" \
        --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    log "Public access blocked"

    # source (relative to 2_data_strategy) | S3 key
    # menu/menu_records.json is the product catalog, read by the catalog agent's get_menu tool
    # (menu_agents.py keeps the original domain key); the rest are KB documents.
    local uploads=(
        "menu/menu_records.json|menu/menu_records.json"
        "menu/menu_items_kb_faqs.txt|electronics_menu/menu_items_kb_faqs.txt"
        "orders/orders_policies_kb_faqs.txt|electronics_orders/orders_policies_kb_faqs.txt"
        "payments/payments_policies_kb_faqs.txt|electronics_payments/payments_policies_kb_faqs.txt"
        "stores/store_kb_faqs.txt|electronics_stores/store_kb_faqs.txt"
    )
    local pair src key
    for pair in "${uploads[@]}"; do
        src="${DATA_DIR}/${pair%%|*}"
        key="${pair##*|}"
        if [ ! -f "$src" ]; then
            err "Missing source file: ${src}"
            exit 1
        fi
        aws s3 cp "$src" "s3://${BUCKET_NAME}/${key}" --region "$REGION" --only-show-errors
        log "Uploaded s3://${BUCKET_NAME}/${key}"
    done

    for pair in "${uploads[@]}"; do
        key="${pair##*|}"
        if ! aws s3api head-object --bucket "$BUCKET_NAME" --key "$key" >/dev/null 2>&1; then
            err "Verification failed: s3://${BUCKET_NAME}/${key} not found"
            exit 1
        fi
    done
    log "Verified ${#uploads[@]} objects at their exact keys."
    log "Step 3 complete."
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4 — (no CLI step) Vector store is created by the console KB quick-create
# STEP 5 — Knowledge bases: discover, sync, verify
# ═════════════════════════════════════════════════════════════════════════════

step5_knowledge_bases() {
    header "Step 5 — Knowledge Bases: discover, sync, verify"

    info "This step syncs and verifies knowledge bases that already exist. To create them:"
    info "  bash 3_proof_of_concept/knowledge_bases/bootstrap_vector_store.sh   (collection + role)"
    info "  bash 3_proof_of_concept/knowledge_bases/setup_knowledge_bases.sh    (all four domains)"
    info "Or in the console (walkthrough Step 4B): quick-create an Amazon OpenSearch Serverless vector"
    info "store, Titan Text Embeddings V2 (1024), S3 URI s3://${BUCKET_NAME}/electronics_<domain>/."
    echo ""

    local problems="" domain kb_name kb_id env_var ds_id job_id status stats scanned failed indexed elapsed
    for domain in "${KB_DOMAINS[@]}"; do
        kb_name="${PROJECT_PREFIX}-${domain}-knowledge-base"
        env_var=$(kb_env_var "$domain")
        kb_id=$(kb_id_by_domain "$domain")

        if [ -z "$kb_id" ]; then
            err "${kb_name} not found"
            problems="${problems} ${kb_name}"
            continue
        fi
        export "${env_var}=${kb_id}"

        ds_id=$(aws bedrock-agent list-data-sources --region "$REGION" --knowledge-base-id "$kb_id" \
            --query 'dataSourceSummaries[0].dataSourceId' --output text 2>/dev/null || true)
        if [ -z "$ds_id" ] || [ "$ds_id" = "None" ]; then
            err "${kb_name} (${kb_id}) has no data source"
            problems="${problems} ${kb_name}"
            continue
        fi

        info "Syncing ${kb_name} (${kb_id})..."
        if ! job_id=$(aws bedrock-agent start-ingestion-job --region "$REGION" \
            --knowledge-base-id "$kb_id" --data-source-id "$ds_id" \
            --query 'ingestionJob.ingestionJobId' --output text 2>&1); then
            err "Could not start a sync for ${kb_name}: ${job_id}"
            problems="${problems} ${kb_name}"
            continue
        fi

        status="STARTING"
        elapsed=0
        while [ "$elapsed" -lt 900 ]; do
            status=$(aws bedrock-agent get-ingestion-job --region "$REGION" \
                --knowledge-base-id "$kb_id" --data-source-id "$ds_id" --ingestion-job-id "$job_id" \
                --query 'ingestionJob.status' --output text)
            case "$status" in COMPLETE|FAILED|STOPPED) break ;; esac
            sleep 10
            elapsed=$((elapsed + 10))
        done

        stats=$(aws bedrock-agent get-ingestion-job --region "$REGION" \
            --knowledge-base-id "$kb_id" --data-source-id "$ds_id" --ingestion-job-id "$job_id" \
            --query 'ingestionJob.statistics' --output json)
        scanned=$(echo "$stats" | jq '.numberOfDocumentsScanned // 0')
        failed=$(echo "$stats" | jq '.numberOfDocumentsFailed // 0')
        indexed=$(echo "$stats" | jq '(.numberOfNewDocumentsIndexed // 0) + (.numberOfModifiedDocumentsIndexed // 0)')

        if [ "$status" != "COMPLETE" ] || [ "$scanned" -eq 0 ] || [ "$failed" -gt 0 ]; then
            err "${kb_name}: sync ${status} (scanned ${scanned}, indexed ${indexed}, failed ${failed})"
            err "  Check the data source S3 URI is s3://${BUCKET_NAME}/electronics_${domain}/ and the file is there."
            problems="${problems} ${kb_name}"
        else
            log "${kb_name}: sync COMPLETE (scanned ${scanned}, indexed ${indexed}, failed 0)"
        fi
    done

    echo ""
    header "Knowledge Base IDs — record these"
    for domain in "${KB_DOMAINS[@]}"; do
        env_var=$(kb_env_var "$domain")
        echo "  export ${env_var}=${!env_var:-<not found>}"
    done
    echo ""

    if [ -n "$problems" ]; then
        err "Required knowledge bases missing or not synced:${problems}"
        err "Create them with: bash 3_proof_of_concept/knowledge_bases/setup_knowledge_bases.sh"
        err "(run bootstrap_vector_store.sh first on a clean account), then re-run: $0 step5-knowledge-bases"
        exit 1
    fi
    log "Step 5 complete."
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 6 — Create the Bedrock Guardrail
# ═════════════════════════════════════════════════════════════════════════════

step6_guardrail() {
    header "Step 6 — Create Bedrock Guardrail"

    local existing_gr gr_result description topic_policy content_policy pii_policy

    description="Content guardrail for SPBC Tech Assistant — blocks out-of-scope and unsafe topics and payment data"

    # Each denied topic must describe what to BLOCK, in concrete terms. An earlier version
    # defined scope by negation ("anything other than ..."), which listed every in-scope subject
    # inside the deny definition and so blocked the very questions the agent exists to answer.
    # Keep these positive and specific, and never deny "software" or "IT help" in general:
    # laptop and smartphone questions are full of both.
    # Bedrock caps a topic definition at 200 characters, so the detail lives in the examples.
    # Keep this policy in step with 5_security_rai/create_and_store_guardrail.sh.
    topic_policy='{
        "topicsConfig": [
            {
                "name": "OutOfScopeRequests",
                "definition": "Subjects unrelated to buying or using consumer electronics: crypto or investment advice, medical, legal or tax advice, politics, travel booking, or homework and essay writing.",
                "examples": [
                    "Tell me about cryptocurrency",
                    "What is your opinion on the election",
                    "Write my history essay for me",
                    "What stocks should I buy?"
                ],
                "type": "DENY"
            },
            {
                "name": "UnsafeDeviceModification",
                "definition": "Instructions to open, puncture, modify or self-repair lithium batteries, chargers or mains-powered devices, or to disable a device'"'"'s safety features.",
                "examples": [
                    "How do I open my phone battery myself?",
                    "How can I fix my swollen laptop battery at home?"
                ],
                "type": "DENY"
            },
            {
                "name": "PiracyAndDRMCircumvention",
                "definition": "Help with pirated software, cracked licences, illegal IPTV streaming, or removing copy protection, carrier locks or region locks without authorisation.",
                "examples": [
                    "Where can I get a cracked copy of Windows?",
                    "How do I set up an illegal IPTV box?"
                ],
                "type": "DENY"
            },
            {
                "name": "PersonalCreditAdvice",
                "definition": "Personal advice on whether the customer should take out credit or a loan, or predictions of whether a credit application will be approved.",
                "examples": [
                    "Should I take a loan to buy this laptop?",
                    "Will my financing application be approved?"
                ],
                "type": "DENY"
            }
        ]
    }'

    content_policy='{
        "filtersConfig": [
            { "type": "SEXUAL",     "inputStrength": "HIGH", "outputStrength": "HIGH" },
            { "type": "VIOLENCE",   "inputStrength": "HIGH", "outputStrength": "HIGH" },
            { "type": "HATE",       "inputStrength": "HIGH", "outputStrength": "HIGH" },
            { "type": "INSULTS",    "inputStrength": "MEDIUM", "outputStrength": "MEDIUM" },
            { "type": "MISCONDUCT", "inputStrength": "MEDIUM", "outputStrength": "MEDIUM" },
            { "type": "PROMPT_ATTACK", "inputStrength": "HIGH", "outputStrength": "NONE" }
        ]
    }'

    # NAME is deliberately not a PII filter: the order flow asks for the customer's name.
    # Payment data a customer might paste into the chat, and passwords, are blocked.
    pii_policy='{
        "piiEntitiesConfig": [
            { "type": "EMAIL",         "action": "ANONYMIZE" },
            { "type": "PHONE",         "action": "ANONYMIZE" },
            { "type": "CREDIT_DEBIT_CARD_NUMBER", "action": "BLOCK" },
            { "type": "CREDIT_DEBIT_CARD_CVV",    "action": "BLOCK" },
            { "type": "PIN",                      "action": "BLOCK" },
            { "type": "INTERNATIONAL_BANK_ACCOUNT_NUMBER", "action": "BLOCK" },
            { "type": "PASSWORD",                 "action": "BLOCK" }
        ]
    }'

    existing_gr=$(aws bedrock list-guardrails \
        --region "$REGION" \
        --query "guardrails[?name=='${GUARDRAIL_NAME}'].id | [0]" \
        --output text 2>/dev/null || true)

    if [ -n "$existing_gr" ] && [ "$existing_gr" != "None" ]; then
        # Update, don't just adopt: reusing the guardrail without re-applying the policies meant
        # an edited definition here never reached the deployed guardrail.
        log "Guardrail '${GUARDRAIL_NAME}' already exists (${existing_gr}) — updating its configuration"
        aws bedrock update-guardrail \
            --region "$REGION" \
            --guardrail-identifier "$existing_gr" \
            --name "$GUARDRAIL_NAME" \
            --description "$description" \
            --blocked-input-messaging "I'm sorry, I can only help with questions about our smartphones and laptops, orders, payments, stores and promotions. For battery or device problems, please visit a store repair desk." \
            --blocked-outputs-messaging "I'm sorry, I cannot provide that information." \
            --topic-policy-config "$topic_policy" \
            --content-policy-config "$content_policy" \
            --sensitive-information-policy-config "$pii_policy" >/dev/null
        GUARDRAIL_ID="$existing_gr"
        log "Configuration updated"
    else
        info "Creating guardrail: ${GUARDRAIL_NAME}"
        gr_result=$(aws bedrock create-guardrail \
            --region "$REGION" \
            --name "$GUARDRAIL_NAME" \
            --description "$description" \
            --blocked-input-messaging "I'm sorry, I can only help with questions about our smartphones and laptops, orders, payments, stores and promotions. For battery or device problems, please visit a store repair desk." \
            --blocked-outputs-messaging "I'm sorry, I cannot provide that information." \
            --topic-policy-config "$topic_policy" \
            --content-policy-config "$content_policy" \
            --sensitive-information-policy-config "$pii_policy")

        # CreateGuardrail's response calls it guardrailId; ListGuardrails calls it id
        GUARDRAIL_ID=$(echo "$gr_result" | jq -r '.guardrailId')
        log "Guardrail created: ${GUARDRAIL_ID}"
    fi

    # Numbered versions are immutable; DRAFT changes whenever the guardrail is edited.
    info "Creating guardrail version..."
    GUARDRAIL_VERSION=$(aws bedrock create-guardrail-version \
        --region "$REGION" \
        --guardrail-identifier "$GUARDRAIL_ID" \
        --description "Published by deploy_agentcore.sh" \
        --query 'version' --output text)

    log "Guardrail ID:      ${GUARDRAIL_ID}"
    log "Guardrail Version: ${GUARDRAIL_VERSION}"
    export GUARDRAIL_ID GUARDRAIL_VERSION
    info "Test the order flow after attaching it (name capture, order IDs must pass through)."
    log "Step 6 complete."
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 7 (option A) — Package the agent as a direct code deployment zip (no Docker)
# ═════════════════════════════════════════════════════════════════════════════

step7_package_zip() {
    header "Step 7 (option A) — Package Agent as a Direct Code Deployment Zip"
    check_agent_sources

    local uv_bin build_dir zip_file size_mb key f
    if command -v uv &>/dev/null; then
        uv_bin="uv"
    elif [ -x "${HOME}/.local/bin/uv" ]; then
        uv_bin="${HOME}/.local/bin/uv"
    else
        info "Installing uv into the user site (python3 -m pip install --user uv)..."
        python3 -m pip install --user --quiet uv
        uv_bin="${HOME}/.local/bin/uv"
    fi

    build_dir=$(mktemp -d)
    zip_file="${build_dir}.zip"

    info "Installing pinned dependencies as linux/arm64 wheels for Python ${PYTHON_VERSION}..."
    "$uv_bin" pip install --quiet \
        --python "$(command -v python3)" \
        --python-version "$PYTHON_VERSION" \
        --python-platform aarch64-manylinux2014 \
        --only-binary :all: \
        --target "$build_dir" \
        -r "${AGENTS_DIR}/requirements.txt"

    for f in "${AGENT_MODULES[@]}"; do
        cp "${AGENTS_DIR}/${f}" "${build_dir}/"
    done
    (cd "$build_dir" && zip -qr "$zip_file" . -x '*__pycache__*')

    size_mb=$(( $(wc -c < "$zip_file") / 1024 / 1024 ))
    if [ "$size_mb" -ge 250 ]; then
        err "Zip is ${size_mb} MB; direct code deployment allows 250 MB compressed"
        exit 1
    fi
    log "Built agent zip: ${size_mb} MB"

    key="agentcore/agent-$(date +%Y%m%d%H%M%S).zip"
    aws s3 cp "$zip_file" "s3://${BUCKET_NAME}/${key}" --region "$REGION" --only-show-errors
    rm -rf "$build_dir" "$zip_file"

    export CODE_S3_KEY="$key"
    export ARTIFACT_TYPE="zip"
    log "Uploaded s3://${BUCKET_NAME}/${key}"
    log "Step 7 (zip) complete."
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 7 (option B) — Build and push the linux/arm64 container image to ECR
# ═════════════════════════════════════════════════════════════════════════════

step7_ecr_build_push() {
    header "Step 7 (option B) — Build & Push Agent Container to ECR"
    check_agent_sources

    if ! command -v docker &>/dev/null; then
        err "Docker not found. Install Docker, or use: $0 step7-package-zip"
        exit 1
    fi
    log "Docker: $(docker --version)"

    local ecr_uri tag image_uri host_arch img_arch
    ecr_uri="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
    tag="v$(date +%Y%m%d%H%M%S)"
    image_uri="${ecr_uri}/${ECR_REPO_NAME}:${tag}"

    if aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$REGION" >/dev/null 2>&1; then
        log "ECR repository exists: ${ECR_REPO_NAME}"
    else
        info "Creating ECR repository: ${ECR_REPO_NAME}"
        aws ecr create-repository \
            --repository-name "$ECR_REPO_NAME" \
            --region "$REGION" \
            --image-scanning-configuration scanOnPush=true \
            --encryption-configuration encryptionType=AES256 >/dev/null
        log "ECR repository created"
    fi

    aws ecr get-login-password --region "$REGION" | \
        docker login --username AWS --password-stdin "$ecr_uri"
    log "Docker authenticated to ECR"

    if [ ! -f "${AGENTS_DIR}/Dockerfile" ]; then
        warn "No Dockerfile found — creating the standard one"
        cat > "${AGENTS_DIR}/Dockerfile" <<'DOCKERFILE_CONTENT'
# AgentCore Runtime container for the SPBC Tech Assistant (AgentCore requires linux/arm64).
FROM --platform=linux/arm64 public.ecr.aws/docker/library/python:3.11-slim
ARG AWS_REGION=eu-central-1
ENV DOCKER_CONTAINER=1 \
    PYTHONUNBUFFERED=1 \
    AWS_REGION=${AWS_REGION} \
    AWS_DEFAULT_REGION=${AWS_REGION}
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY tech_assistant_agent.py menu_agents.py orders_agents.py place_order.py \
     payments_policy_agents.py stores_agents.py promos_agents.py ./
EXPOSE 8080
CMD ["python", "tech_assistant_agent.py"]
DOCKERFILE_CONTENT
    fi

    host_arch=$(uname -m)
    if [ "$host_arch" != "aarch64" ] && [ "$host_arch" != "arm64" ]; then
        info "Host is ${host_arch}: registering QEMU arm64 emulation for the build..."
        if ! docker run --privileged --rm tonistiigi/binfmt --install arm64 >/dev/null; then
            err "Could not register arm64 emulation (privileged containers may be blocked here)."
            err "Use the zip path instead: $0 step7-package-zip"
            exit 1
        fi
    fi

    info "Building ${image_uri} (linux/arm64)..."
    if docker buildx version >/dev/null 2>&1; then
        docker buildx build --platform linux/arm64 --provenance=false --load -t "$image_uri" "$AGENTS_DIR"
    else
        docker build --platform linux/arm64 -t "$image_uri" "$AGENTS_DIR"
    fi

    img_arch=$(docker image inspect --format '{{.Architecture}}' "$image_uri")
    if [ "$img_arch" != "arm64" ]; then
        err "Built image architecture is '${img_arch}'; AgentCore requires arm64"
        exit 1
    fi
    log "Image architecture: ${img_arch}"

    docker push "$image_uri"
    docker tag "$image_uri" "${ecr_uri}/${ECR_REPO_NAME}:latest"
    docker push "${ecr_uri}/${ECR_REPO_NAME}:latest" >/dev/null

    export IMAGE_URI="$image_uri"
    export ARTIFACT_TYPE="container"
    log "Image pushed: ${IMAGE_URI} (unique tag = rollback target)"
    log "Step 7 (container) complete."
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 8 — Create (or update) the AgentCore Runtime and require MMDSv2
# ═════════════════════════════════════════════════════════════════════════════

step8_create_runtime() {
    header "Step 8 — Create AgentCore Runtime"

    local role_arn artifact network_config env_vars runtime_id result latest_tag d v missing=0
    role_arn=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

    # ── Artifact ──
    if [ "$ARTIFACT_TYPE" = "zip" ]; then
        if [ -z "${CODE_S3_KEY:-}" ]; then
            CODE_S3_KEY=$(aws s3api list-objects-v2 --bucket "$BUCKET_NAME" --prefix "agentcore/agent-" \
                --query 'sort_by(Contents,&LastModified)[-1].Key' --output text 2>/dev/null || true)
            if [ -z "$CODE_S3_KEY" ] || [ "$CODE_S3_KEY" = "None" ]; then
                err "No agent zip found under s3://${BUCKET_NAME}/agentcore/. Run: $0 step7-package-zip"
                exit 1
            fi
        fi
        artifact=$(jq -n --arg b "$BUCKET_NAME" --arg k "$CODE_S3_KEY" --arg rt "$PYTHON_RUNTIME" \
            --arg ep "$ENTRYPOINT_FILE" \
            '{codeConfiguration: {code: {s3: {bucket: $b, prefix: $k}}, runtime: $rt, entryPoint: [$ep]}}')
        info "Artifact: s3://${BUCKET_NAME}/${CODE_S3_KEY} (${PYTHON_RUNTIME}, ${ENTRYPOINT_FILE})"
    else
        if [ -z "${IMAGE_URI:-}" ]; then
            latest_tag=$(aws ecr describe-images --repository-name "$ECR_REPO_NAME" --region "$REGION" \
                --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags' --output json 2>/dev/null \
                | jq -r 'map(select(. != "latest"))[0] // empty' 2>/dev/null || true)
            if [ -z "$latest_tag" ]; then
                err "No pushed image found in ${ECR_REPO_NAME}. Run: $0 step7-ecr-build-push"
                exit 1
            fi
            IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO_NAME}:${latest_tag}"
        fi
        artifact=$(jq -n --arg u "$IMAGE_URI" '{containerConfiguration: {containerUri: $u}}')
        info "Artifact: ${IMAGE_URI}"
    fi

    # ── Network ──
    if [ -n "$SUBNET_IDS" ] && [ -n "$SECURITY_GROUP_IDS" ]; then
        network_config=$(jq -n --arg s "$SUBNET_IDS" --arg g "$SECURITY_GROUP_IDS" \
            '{networkMode: "VPC", networkModeConfig: {subnets: ($s | split(",")), securityGroups: ($g | split(","))}}')
        info "Network: VPC (subnets ${SUBNET_IDS}; security groups ${SECURITY_GROUP_IDS})"
    else
        network_config='{"networkMode": "PUBLIC"}'
        if [ -n "$STORES_DB_CLUSTER_ARN" ]; then
            info "Network: PUBLIC (stores use the RDS Data API over HTTPS; no VPC needed)"
        else
            warn "Network: PUBLIC — legacy store lookups (MySQL) can't reach a private Aurora cluster."
            warn "  Deploy 6_deploy/infra/agentcore-backends (Data API), or set SUBNET_IDS and"
            warn "  SECURITY_GROUP_IDS (private subnets with a NAT route) for VPC mode."
        fi
    fi

    # ── Knowledge bases (required ones must exist; the runtime crashes at import otherwise) ──
    discover_kb_ids
    for d in $REQUIRED_KB_DOMAINS; do
        v=$(kb_env_var "$d")
        if [ -z "${!v:-}" ]; then
            err "${v} is not set and ${PROJECT_PREFIX}-${d}-knowledge-base was not found"
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        err "Create the knowledge bases first:"
        err "  bash 3_proof_of_concept/knowledge_bases/setup_knowledge_bases.sh"
        exit 1
    fi

    # ── Guardrail (optional): use the highest numbered version ──
    # NOTE: ListGuardrails returns the identifier as "id"; only CreateGuardrail's response
    # calls it "guardrailId". Querying .guardrailId here returns None, which silently left
    # the runtime with no guardrail attached.
    if [ -z "${GUARDRAIL_ID:-}" ]; then
        GUARDRAIL_ID=$(aws bedrock list-guardrails --region "$REGION" \
            --query "guardrails[?name=='${GUARDRAIL_NAME}'].id | [0]" --output text 2>/dev/null || true)
        if [ "$GUARDRAIL_ID" = "None" ]; then GUARDRAIL_ID=""; fi
    fi
    if [ -n "${GUARDRAIL_ID:-}" ] && [ -z "${GUARDRAIL_VERSION:-}" ]; then
        GUARDRAIL_VERSION=$(aws bedrock list-guardrails --region "$REGION" --guardrail-identifier "$GUARDRAIL_ID" \
            --query 'guardrails[].version' --output json 2>/dev/null \
            | jq -r 'map(select(. != "DRAFT") | tonumber) | max // empty' 2>/dev/null || true)
        if [ -z "$GUARDRAIL_VERSION" ]; then
            warn "Guardrail ${GUARDRAIL_ID} has no numbered version; running without a guardrail."
            GUARDRAIL_ID=""
        fi
    fi
    if [ -n "${GUARDRAIL_ID:-}" ]; then
        log "Guardrail: ${GUARDRAIL_ID} v${GUARDRAIL_VERSION}"
    fi

    # ── Environment variables (empty values are dropped) ──
    env_vars=$(jq -n \
        --arg REGION "$REGION" \
        --arg MODEL_ID "$LLM_MODEL_ID" \
        --arg MODEL_ARN "$LLM_MODEL_ARN" \
        --arg MENU "${MENU_KNOWLEDGE_BASE_ID:-}" \
        --arg ORDERS "${ORDERS_KNOWLEDGE_BASE_ID:-}" \
        --arg PAYMENTS "${PAYMENTS_KNOWLEDGE_BASE_ID:-}" \
        --arg STORES "${STORES_KNOWLEDGE_BASE_ID:-}" \
        --arg BUCKET "$BUCKET_NAME" \
        --arg GID "${GUARDRAIL_ID:-}" \
        --arg GVER "${GUARDRAIL_VERSION:-}" \
        --arg LOG "${LOG_LEVEL:-INFO}" \
        --arg DB_CLUSTER "$STORES_DB_CLUSTER_ARN" \
        --arg DB_SECRET "$STORES_DB_SECRET_ARN" \
        --arg DB_NAME "$STORES_DB_NAME" \
        --arg PROMOS_URL "$PROMOS_API_URL" \
        '{REGION: $REGION, MODEL_ID: $MODEL_ID, MODEL_ARN: $MODEL_ARN,
          MENU_KNOWLEDGE_BASE_ID: $MENU, ORDERS_KNOWLEDGE_BASE_ID: $ORDERS,
          PAYMENTS_KNOWLEDGE_BASE_ID: $PAYMENTS, STORES_KNOWLEDGE_BASE_ID: $STORES,
          S3_BUCKET_NAME: $BUCKET,
          GUARDRAIL_ID: $GID, GUARDRAIL_VERSION: $GVER, GUARDRAIL_TRACE: "enabled",
          STORES_DB_CLUSTER_ARN: $DB_CLUSTER, STORES_DB_SECRET_ARN: $DB_SECRET,
          STORES_DB_NAME: $DB_NAME, PROMOS_API_URL: $PROMOS_URL,
          DOCKER_CONTAINER: "1", LOG_LEVEL: $LOG}
         | with_entries(select(.value != ""))')
    info "Environment variables: $(echo "$env_vars" | jq -r 'keys | join(", ")')"

    # The role must allow exactly the backends this env points at (idempotent)
    put_backends_policy

    # ── Create or update ──
    runtime_id=$(runtime_id_by_name)
    if [ -z "$runtime_id" ]; then
        info "Creating AgentCore runtime: ${RUNTIME_NAME}"
        result=$(aws bedrock-agentcore-control create-agent-runtime \
            --region "$REGION" \
            --agent-runtime-name "$RUNTIME_NAME" \
            --agent-runtime-artifact "$artifact" \
            --role-arn "$role_arn" \
            --network-configuration "$network_config" \
            --protocol-configuration '{"serverProtocol": "HTTP"}' \
            --environment-variables "$env_vars" \
            --output json)
        runtime_id=$(echo "$result" | jq -r '.agentRuntimeId')
        log "Runtime created: ${runtime_id}"
    else
        warn "Runtime '${RUNTIME_NAME}' already exists (${runtime_id}) — updating it (new version)."
        aws bedrock-agentcore-control update-agent-runtime \
            --region "$REGION" \
            --agent-runtime-id "$runtime_id" \
            --agent-runtime-artifact "$artifact" \
            --role-arn "$role_arn" \
            --network-configuration "$network_config" \
            --protocol-configuration '{"serverProtocol": "HTTP"}' \
            --environment-variables "$env_vars" \
            --metadata-configuration '{"requireMMDSV2": true}' \
            --output json >/dev/null
        sleep 10
    fi

    info "Waiting for READY (several minutes on first create)..."
    if ! wait_runtime_ready "$runtime_id" 900; then
        err "Check: CloudWatch → Log groups → /aws/bedrock-agentcore/runtimes/${runtime_id}-DEFAULT"
        exit 1
    fi

    ensure_mmdsv2 "$runtime_id"

    RUNTIME_ARN=$(aws bedrock-agentcore-control get-agent-runtime --region "$REGION" \
        --agent-runtime-id "$runtime_id" --query 'agentRuntimeArn' --output text)
    export RUNTIME_ARN
    log "Runtime ARN: ${RUNTIME_ARN}"
    info "READY only means the configuration is valid. Step 9 proves the container starts and answers."
    log "Step 8 complete."
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 9 — Test the runtime (one prompt per domain)
# ═════════════════════════════════════════════════════════════════════════════

step9_test_runtime() {
    header "Step 9 — Test AgentCore Runtime"

    local runtime_id status session_id out_file err_file payload prompt failures=0
    runtime_id=$(runtime_id_by_name)
    if [ -z "$runtime_id" ]; then
        err "Runtime not found. Run step8 first."
        exit 1
    fi
    RUNTIME_ARN=$(aws bedrock-agentcore-control get-agent-runtime --region "$REGION" \
        --agent-runtime-id "$runtime_id" --query 'agentRuntimeArn' --output text)
    status=$(aws bedrock-agentcore-control get-agent-runtime --region "$REGION" \
        --agent-runtime-id "$runtime_id" --query 'status' --output text)
    if [ "$status" != "READY" ]; then
        err "Runtime is not READY (current: ${status})."
        exit 1
    fi

    # Session IDs must be at least 33 characters; a fresh one avoids stale code in old sessions.
    session_id="spbc-smoke-$(date +%s)-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    out_file=$(mktemp)
    err_file=$(mktemp)

    # One prompt per domain, each with a pattern its answer must contain. Checking content is
    # what makes this usable unattended: a runtime that answers "Sorry, I encountered an
    # error" to everything returns HTTP 200 and would otherwise be reported as a pass.
    local domain prompt expect requirement response warnings=0
    for domain in menu orders payments promos stores; do
        case "$domain" in
            menu)
                prompt="Do you have the Apple iPhone 14 with 128GB, and what does it cost?"
                # A price, not just the product name: naming the phone while failing to price it
                # is what a broken catalog/price tool looks like
                expect="[0-9]+[.,][0-9]{2}|€ ?[0-9]|[0-9] ?(EUR|euro)"
                requirement="required" ;;
            orders)
                prompt="What is the status of order ord_2055_023 for customer_2055?"
                # A real status from the seed data (SHIPPED), or an explicit "nothing found" when
                # the table has not been seeded, is a working path
                expect="shipped|order|status|no order|not found|couldn't find|could not find"
                requirement="required" ;;
            payments)
                prompt="Can I pay with PayPal when I order online?"
                # Must actually answer: "payment" alone matches the apology for a failed lookup
                expect="(yes|accept|can pay|do take|welcome).{0,60}(paypal|card)|paypal.{0,40}(accepted|welcome|fine|available)"
                requirement="required" ;;
            promos)
                prompt="Is there a student discount on laptops?"
                expect="student|10 ?%|STUDENT10|discount"
                # Answered from the promotions API; optional when the API is not configured
                requirement="optional"
                if [ -n "$PROMOS_API_URL" ]; then
                    requirement="required"
                fi ;;
            stores)
                prompt="What are the opening hours of your store in Dresden?"
                expect="[0-9]{1,2}:[0-9]{2}"
                # Needs the stores database; without it the store FAQ may still answer
                requirement="optional"
                if [ -n "$STORES_DB_CLUSTER_ARN" ]; then
                    requirement="required"
                fi ;;
        esac

        echo ""
        info "[${domain}] \"${prompt}\""
        # The --payload blob must be base64. AWS CLI v2 accepts raw JSON only with
        # --cli-binary-format raw-in-base64-out, a flag CLI v1 doesn't know (it prints "usage:"
        # and exits non-zero). Base64-encoding the JSON ourselves works on both: v1 requires it,
        # and v2 treats base64 as the default blob format. No --cli-binary-format, so the call is
        # portable across CLI versions.
        # Pass the payload as a raw-bytes file via fileb://. This avoids the --payload
        # base64 ambiguity that differs by CLI version: some builds base64-decode a --payload
        # string, others send it verbatim, and an inline base64 string was decoded to an empty
        # body by the CI CLI (runtime logged "Invalid JSON ... char 0"). fileb:// reads the JSON
        # bytes as-is on every version. Capture stdout+stderr so a runtime error is visible.
        payload_file=$(mktemp)
        jq -cn --arg p "$prompt" '{prompt: $p}' > "$payload_file"
        if ! aws bedrock-agentcore invoke-agent-runtime \
            --region "$REGION" \
            --agent-runtime-arn "$RUNTIME_ARN" \
            --runtime-session-id "$session_id" \
            --content-type application/json \
            --payload "fileb://$payload_file" \
            "$out_file" >"$err_file" 2>&1; then
            failures=$((failures + 1))
            err "[${domain}] invocation failed: $(tr -d '\r' < "$err_file" | tail -3)"
            rm -f "$payload_file"
            continue
        fi
        rm -f "$payload_file"

        response=$(cat "$out_file")
        echo "  Response: $(printf '%s' "$response" | head -c 400)"

        # Phrases that mean a tool or the model failed. The runtime still returns 200 for
        # these, so they have to be matched explicitly. A well-prompted agent reports a broken
        # tool *politely* ("I'm unable to retrieve...", "please contact support"), and those
        # phrasings sailed past an earlier, narrower version of this list.
        if printf '%s' "$response" | grep -qiE "sorry, i encountered|failed to retrieve|error fetching|could not connect|failed to connect|accessdenied|traceback|error (in |when )?retriev|unable to (retrieve|determine|provide)|try again later|contact (our |a )?(support|team member)|check (our website|with a team member)"; then
            failures=$((failures + 1))
            err "[${domain}] the answer reports a failure — check the runtime logs"
            continue
        fi

        if printf '%s' "$response" | grep -qiE "$expect"; then
            log "[${domain}] answer contains domain facts"
        elif [ "$requirement" = "required" ]; then
            failures=$((failures + 1))
            err "[${domain}] answer does not match /${expect}/i — the tool path is probably broken"
        else
            warnings=$((warnings + 1))
            warn "[${domain}] answer does not match /${expect}/i (backend not configured; treated as a warning)"
        fi
    done
    rm -f "$out_file" "$err_file"

    echo ""
    info "Logs: CloudWatch → /aws/bedrock-agentcore/runtimes/${runtime_id}-DEFAULT (search Traceback, AccessDenied)"
    if [ "$warnings" -gt 0 ]; then
        warn "${warnings} optional domain check(s) did not match; deploy their backends to cover them."
    fi
    if [ "$failures" -gt 0 ]; then
        err "${failures} domain check(s) failed."
        exit 1
    fi
    log "Step 9 complete."
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 10 — Generate agentcore-config.json
# ═════════════════════════════════════════════════════════════════════════════

step10_generate_config() {
    header "Step 10 — Generate agentcore-config.json"

    local runtime_id config_file
    runtime_id=$(runtime_id_by_name)
    if [ -z "$runtime_id" ]; then
        err "Runtime not found. Run step8 first."
        exit 1
    fi
    RUNTIME_ARN=$(aws bedrock-agentcore-control get-agent-runtime --region "$REGION" \
        --agent-runtime-id "$runtime_id" --query 'agentRuntimeArn' --output text)

    config_file="${WEBAPP_DIR}/agentcore-config.json"
    mkdir -p "$(dirname "$config_file")"

    jq -n --arg arn "$RUNTIME_ARN" --arg region "$REGION" --arg acct "$ACCOUNT_ID" \
        '{agentRuntimeArn: $arn, region: $region, apiVersion: "2023-07-26", accountId: $acct}' > "$config_file"

    log "Config written to: ${config_file}"
    jq . "$config_file"
    echo ""
    info "The web app signs requests with SigV4: keep the runtime's inbound auth on IAM."
    info "Grant the Cognito authenticated role bedrock-agentcore:InvokeAgentRuntime on:"
    info "  ${RUNTIME_ARN}"
    info "  ${RUNTIME_ARN}/runtime-endpoint/*"
    log "Step 10 complete."
}

# ═════════════════════════════════════════════════════════════════════════════
# STATUS — Check runtime status
# ═════════════════════════════════════════════════════════════════════════════

check_status() {
    header "Runtime Status"

    local runtime_id
    runtime_id=$(runtime_id_by_name)
    if [ -z "$runtime_id" ]; then
        err "Runtime '${RUNTIME_NAME}' not found in ${REGION}"
        return 1
    fi

    aws bedrock-agentcore-control get-agent-runtime --region "$REGION" --agent-runtime-id "$runtime_id" \
        --output json | jq '{
            name: .agentRuntimeName,
            arn: .agentRuntimeArn,
            version: .agentRuntimeVersion,
            status: .status,
            requireMMDSV2: (.metadataConfiguration.requireMMDSV2 // false),
            networkMode: .networkConfiguration.networkMode,
            artifact: .agentRuntimeArtifact,
            envVarKeys: ((.environmentVariables // {}) | keys),
            lastUpdatedAt: .lastUpdatedAt
        }'
}

# ═════════════════════════════════════════════════════════════════════════════
# TEARDOWN — Delete all created resources
# ═════════════════════════════════════════════════════════════════════════════

teardown() {
    header "Teardown — Deleting All Resources"
    warn "This will DELETE the SPBC AgentCore runtime, guardrail, knowledge bases, ECR repo and IAM role!"
    read -r -p "Are you sure? (type 'yes' to confirm): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        info "Aborted."
        return
    fi

    local runtime_id gr_id domain kb_name kb_id role policy policies
    runtime_id=$(runtime_id_by_name)
    if [ -n "$runtime_id" ]; then
        info "Deleting AgentCore runtime ${RUNTIME_NAME} (${runtime_id})..."
        aws bedrock-agentcore-control delete-agent-runtime --region "$REGION" \
            --agent-runtime-id "$runtime_id" >/dev/null && log "Runtime deletion started"
    else
        warn "Runtime not found"
    fi

    info "Deleting guardrail..."
    gr_id=$(aws bedrock list-guardrails --region "$REGION" \
        --query "guardrails[?name=='${GUARDRAIL_NAME}'].id | [0]" --output text 2>/dev/null || true)
    if [ -n "$gr_id" ] && [ "$gr_id" != "None" ]; then
        aws bedrock delete-guardrail --region "$REGION" --guardrail-identifier "$gr_id" && log "Guardrail deleted"
    fi

    for domain in "${KB_DOMAINS[@]}" "${LEGACY_KB_DOMAINS[@]}"; do
        kb_name="${PROJECT_PREFIX}-${domain}-knowledge-base"
        kb_id=$(kb_id_by_domain "$domain")
        if [ -n "$kb_id" ]; then
            info "Deleting KB: ${kb_name} (${kb_id})"
            aws bedrock-agent delete-knowledge-base --region "$REGION" --knowledge-base-id "$kb_id" >/dev/null \
                && log "Deleted ${kb_name}"
        fi
    done

    info "Deleting ECR repository..."
    aws ecr delete-repository \
        --repository-name "$ECR_REPO_NAME" \
        --region "$REGION" \
        --force >/dev/null 2>&1 && log "ECR repo deleted" || warn "ECR repo not found"

    # SPBC-BedrockKB-ServiceRole was created by older versions of this script
    for role in "$ROLE_NAME" "SPBC-BedrockKB-ServiceRole"; do
        if aws iam get-role --role-name "$role" &>/dev/null; then
            info "Deleting IAM role: ${role}"
            policies=$(aws iam list-role-policies --role-name "$role" --query 'PolicyNames' --output json)
            for policy in $(echo "$policies" | jq -r '.[]'); do
                aws iam delete-role-policy --role-name "$role" --policy-name "$policy"
            done
            aws iam delete-role --role-name "$role" && log "Deleted role: ${role}"
        fi
    done

    warn "Not deleted (check and remove manually to stop charges):"
    echo "    • OpenSearch Serverless collections created by KB quick-create (billed hourly while they exist):"
    echo "        aws opensearchserverless list-collections --region ${REGION}"
    echo "    • KB service roles created by the console (AmazonBedrockExecutionRoleForKnowledgeBase_*)"
    echo "    • S3 bucket (kept for safety): aws s3 rb s3://${BUCKET_NAME} --force"
    echo "    • Terraform backends (Aurora stores DB, promotions API; Aurora bills per ACU-hour):"
    echo "        bash 6_deploy/scripts/agentcore_backends.sh destroy   (guarded; explains each prerequisite)"
    log "Teardown complete."
}

# ═════════════════════════════════════════════════════════════════════════════
# DEPLOY ALL — Run all steps sequentially
# ═════════════════════════════════════════════════════════════════════════════

deploy_all() {
    header "Full Deployment — All Steps"
    preflight
    step1_model_access
    step2_iam_role
    step3_s3_bucket
    step5_knowledge_bases
    step6_guardrail
    if [ "$ARTIFACT_TYPE" = "container" ]; then
        step7_ecr_build_push
    else
        step7_package_zip
    fi
    step8_create_runtime
    step9_test_runtime
    step10_generate_config

    echo ""
    header "🎉 Deployment Complete!"
    info "Runtime ARN: ${RUNTIME_ARN:-check: $0 status}"
    info "Next: Deploy the Amplify frontend with the generated agentcore-config.json"
}

# ═════════════════════════════════════════════════════════════════════════════
# CLI Entrypoint
# ═════════════════════════════════════════════════════════════════════════════

usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  deploy-all             Run all steps (KBs must exist — create them in the console first)"
    echo "  step1-model-access     Confirm Nova Pro (EU profile) and Titan V2 answer"
    echo "  step2-iam-role         Create/refresh the AgentCore execution role"
    echo "  step3-s3-bucket        Create the S3 bucket and upload the exact object layout"
    echo "  step5-knowledge-bases  Discover the KBs by name, sync and verify them"
    echo "  step6-guardrail        Create the guardrail and a numbered version"
    echo "  step7-package-zip      Artifact option A: direct code deployment zip (no Docker)"
    echo "  step7-ecr-build-push   Artifact option B: linux/arm64 image in ECR"
    echo "  step8-create-runtime   Create or update the runtime, then require MMDSv2"
    echo "  step9-test-runtime     Send one prompt per domain"
    echo "  step10-generate-config Generate agentcore-config.json"
    echo "  status                 Show runtime status, version, MMDSv2 and network"
    echo "  teardown               Delete created resources"
    echo "  help                   Show this help"
    echo ""
    echo "Environment overrides:"
    echo "  REGION              (default: eu-central-1)"
    echo "  ACCOUNT_ID          (default: auto-detected)"
    echo "  ROLE_NAME           (default: SPBC-AgentCore-ExecutionRole)"
    echo "  BUCKET_NAME         (default: spbc-kb-docs-<account-id>)"
    echo "  ECR_REPO_NAME       (default: spbc-tech-assistant)"
    echo "  RUNTIME_NAME        (default: tech_assistant_agent)"
    echo "  ARTIFACT_TYPE       container | zip (default: container)"
    echo "  CODE_S3_KEY / IMAGE_URI   artifact to deploy (default: latest uploaded/pushed)"
    echo "  SUBNET_IDS, SECURITY_GROUP_IDS   comma-separated; enables VPC mode"
    echo "  LOG_LEVEL           runtime log level (default: INFO)"
    echo "  STORES_DB_CLUSTER_ARN, STORES_DB_SECRET_ARN, STORES_DB_NAME, PROMOS_API_URL"
    echo "                      backends (default: Terraform outputs of 6_deploy/infra/agentcore-backends)"
    echo "  BACKENDS_DIR        Terraform directory to read them from"
    echo ""
}

case "${1:-help}" in
    deploy-all)             deploy_all ;;
    step1-model-access)     preflight && step1_model_access ;;
    step2-iam-role)         preflight && step2_iam_role ;;
    step3-s3-bucket)        preflight && step3_s3_bucket ;;
    step5-knowledge-bases)  preflight && step5_knowledge_bases ;;
    step6-guardrail)        preflight && step6_guardrail ;;
    step7-package-zip)      preflight && step7_package_zip ;;
    step7-ecr-build-push)   preflight && step7_ecr_build_push ;;
    step8-create-runtime)   preflight && step8_create_runtime ;;
    step9-test-runtime)     preflight && step9_test_runtime ;;
    step10-generate-config) preflight && step10_generate_config ;;
    status)                 check_status ;;
    teardown)               preflight && teardown ;;
    help|--help|-h)         usage ;;
    *)                      err "Unknown command: $1"; usage; exit 1 ;;
esac
