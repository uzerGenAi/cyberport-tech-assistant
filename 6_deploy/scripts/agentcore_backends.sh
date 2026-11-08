#!/usr/bin/env bash
set -euo pipefail
# agentcore_backends.sh — Terraform stack 6_deploy/infra/agentcore-backends
#   Aurora MySQL Serverless v2 stores database (RDS Data API) + IAM-authorized promotions API.
#
# Usage:
#   bash 6_deploy/scripts/agentcore_backends.sh plan  [terraform plan args]   # review changes
#   bash 6_deploy/scripts/agentcore_backends.sh apply [terraform plan args]   # plan, confirm, apply that plan
#   bash 6_deploy/scripts/agentcore_backends.sh seed      # create table, load stores, create read-only user
#   bash 6_deploy/scripts/agentcore_backends.sh check     # live smoke test: reader query, unsigned 403, signed 200
#   bash 6_deploy/scripts/agentcore_backends.sh env       # export lines for the runtime env vars
#   bash 6_deploy/scripts/agentcore_backends.sh policy    # execution-role inline policy JSON
#   bash 6_deploy/scripts/agentcore_backends.sh validate  # offline: fmt, validate, terraform test
#   bash 6_deploy/scripts/agentcore_backends.sh destroy   # guarded teardown
#
# Examples:
#   eval "$(bash 6_deploy/scripts/agentcore_backends.sh env)"
#   bash 6_deploy/scripts/agentcore_backends.sh apply -var aurora_deletion_protection=false -var dynamodb_deletion_protection=false  # one-off, before destroy
# Lasting settings belong in 6_deploy/infra/agentcore-backends/terraform.tfvars (see the .example):
# a -var flag is forgotten on the next apply.
#
# Remote state lives in s3://spbc-tfstate-<account-id> (override: TF_STATE_BUCKET) with S3 native
# locking; create the bucket once with: make backend-setup. AUTO_APPROVE=1 skips the apply
# confirmation (CI only). Needs Terraform 1.10+.

set -euo pipefail

ROOT_DIR="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "$0")/../.." && pwd; })"
TF_DIR="${ROOT_DIR}/6_deploy/infra/agentcore-backends"
PLAN_FILE="${TF_DIR}/.build/backends.tfplan"
LOADER="${ROOT_DIR}/2_data_strategy/stores/load_stores_data_api.py"
REGION="eu-central-1"
# State bucket: spbc-tfstate-<account-id> unless TF_STATE_BUCKET overrides it (state_bucket.sh)
CLUSTER_ID="spbc-aurora-cluster"

# Messages go to stderr so `eval "$(... env)"` only sees the export lines
log()  { echo -e "\033[0;34mℹ️  $*\033[0m" >&2; }
ok()   { echo -e "\033[0;32m✅ $*\033[0m" >&2; }
warn() { echo -e "\033[1;33m⚠️  $*\033[0m" >&2; }
die()  { echo -e "\033[0;31m❌ $*\033[0m" >&2; exit 1; }

tf() { terraform -chdir="$TF_DIR" "$@"; }

need() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required (see the walkthrough, Step 2.1)"
    done
}

# State locking uses an S3 lock file (use_lockfile), so only the bucket has to exist
check_state_backend() {
    aws s3api head-bucket --bucket "$STATE_BUCKET" --region "$REGION" >/dev/null 2>&1 \
        || die "Terraform state bucket s3://${STATE_BUCKET} not found or not yours. Run once: make backend-setup
   (the default name is spbc-tfstate-<account-id>; TF_STATE_BUCKET overrides it for both commands)"
}

init() {
    need terraform aws
    aws sts get-caller-identity >/dev/null 2>&1 || die "No AWS credentials (aws sts get-caller-identity failed)"
    # shellcheck source=state_bucket.sh
    source "$(dirname "${BASH_SOURCE[0]}")/state_bucket.sh" || die "Could not resolve the state bucket"
    check_state_backend
    log "terraform init (state: s3://${STATE_BUCKET}/prod/agentcore-backends.tfstate)"
    # Explicit: callers run inside `|| rc=$?`, where set -e is suspended
    # Provider downloads occasionally time out (first run on macOS especially): retry before failing
    local attempt
    for attempt in 1 2 3; do
        tf init -input=false -backend-config="bucket=${STATE_BUCKET}" >/dev/null 2>"${TF_DIR}/.init.err" && { rm -f "${TF_DIR}/.init.err"; return 0; }
        warn "terraform init attempt ${attempt}/3 failed: $(tail -n 2 "${TF_DIR}/.init.err" | tr '\n' ' ')"
        sleep $((attempt * 5))
    done
    rm -f "${TF_DIR}/.init.err"
    die "terraform init failed after 3 attempts"
}

# terraform plan into PLAN_FILE; returns 0 = no changes, 2 = changes
plan() {
    local rc=0
    init
    mkdir -p "$(dirname "$PLAN_FILE")"
    tf plan -input=false -detailed-exitcode -out="$PLAN_FILE" "$@" || rc=$?
    case "$rc" in
        0) ok "No changes." ;;
        2) log "Plan saved to ${PLAN_FILE}" ;;
        *) die "terraform plan failed" ;;
    esac
    return "$rc"
}

apply() {
    local rc=0 answer
    plan "$@" || rc=$?
    if [ "$rc" -eq 0 ]; then
        rm -f "$PLAN_FILE"
        next_steps
        return 0
    fi
    if [ "${AUTO_APPROVE:-0}" != "1" ]; then
        warn "Applying creates billable resources (Aurora Serverless v2 bills per ACU-hour; minimum"
        warn "0.5 ACU per instance, 2 instances by default)."
        read -r -p "Apply exactly this plan? Type 'apply' to continue: " answer
        [ "$answer" = "apply" ] || { rm -f "$PLAN_FILE"; die "Aborted; nothing was changed."; }
    fi
    tf apply -input=false "$PLAN_FILE"
    rm -f "$PLAN_FILE"
    ok "Backends applied."
    next_steps
}

next_steps() {
    echo "" >&2
    log "Next:"
    log "  1. Load the stores data (idempotent):  bash 6_deploy/scripts/agentcore_backends.sh seed"
    log "  2. Smoke test:                          bash 6_deploy/scripts/agentcore_backends.sh check"
    log "  3. Runtime env vars:                    bash 6_deploy/scripts/agentcore_backends.sh env"
    log "  4. Execution-role policy:               bash 6_deploy/scripts/agentcore_backends.sh policy"
}

seed() {
    need python3 terraform
    init
    python3 -c 'import boto3' 2>/dev/null || die "python3 can't import boto3 (pip install --user boto3)"
    log "Loading the stores database through the RDS Data API..."
    python3 "$LOADER" --from-terraform "$TF_DIR" --region "$REGION"
}

outputs_json() {
    local out
    init
    out=$(tf output -json agentcore_runtime_env 2>/dev/null) \
        || die "No outputs yet: run 'bash 6_deploy/scripts/agentcore_backends.sh apply' first"
    echo "$out"
}

print_env() {
    need jq
    local out key value
    out=$(outputs_json)
    for key in STORES_DB_CLUSTER_ARN STORES_DB_SECRET_ARN STORES_DB_NAME PROMOS_API_URL; do
        value=$(echo "$out" | jq -r --arg k "$key" '.[$k] // empty')
        [ -n "$value" ] || die "Output agentcore_runtime_env has no ${key}"
        printf 'export %s=%q\n' "$key" "$value"
    done
}

# Signed GET (SigV4, execute-api) with the caller's credentials; prints the number of items.
# A function, because bash 3.2 mis-parses here-documents inside $(...).
signed_get_count() {
    python3 - "$1" <<'PY'
import json, re, sys, urllib.error, urllib.request
import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
url = sys.argv[1]
match = re.search(r"\.execute-api\.([a-z0-9-]+)\.amazonaws\.com", url)
region = match.group(1) if match else "eu-central-1"
credentials = boto3.Session().get_credentials()
if credentials is None:
    sys.exit("no AWS credentials")
request = AWSRequest(method="GET", url=url, headers={"Accept": "application/json"})
SigV4Auth(credentials.get_frozen_credentials(), "execute-api", region).add_auth(request)
try:
    with urllib.request.urlopen(urllib.request.Request(url, headers=dict(request.headers.items())), timeout=10) as r:
        print(len(json.load(r)))
except urllib.error.HTTPError as e:
    sys.exit(f"HTTP {e.code}" + (" (your identity needs execute-api:Invoke on GET /promotions)" if e.code == 403 else ""))
PY
}

# Live smoke test of the backends, called the way the runtime calls them
check() {
    need jq python3 curl
    local out cluster secret db url count code
    out=$(outputs_json)
    cluster=$(echo "$out" | jq -r '.STORES_DB_CLUSTER_ARN')
    secret=$(echo "$out" | jq -r '.STORES_DB_SECRET_ARN')
    db=$(echo "$out" | jq -r '.STORES_DB_NAME')
    url=$(echo "$out" | jq -r '.PROMOS_API_URL')
    python3 -c 'import boto3' 2>/dev/null || die "python3 can't import boto3 (pip install --user boto3)"

    log "Stores: SELECT COUNT(*) FROM stores with the reader secret (Data API)..."
    count=$(aws rds-data execute-statement --region "$REGION" --resource-arn "$cluster" \
        --secret-arn "$secret" --database "$db" --sql "SELECT COUNT(*) FROM stores" \
        --query 'records[0][0].longValue' --output text) \
        || die "Data API query failed. DatabaseResumingException: retry in 30 s. Table or user missing: run seed."
    ok "Stores: ${count} rows readable by the reader user"

    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" || true)
    [ "$code" = "403" ] || die "Unsigned GET ${url} returned HTTP ${code}; expected 403 (IAM authorization)"
    ok "Promotions: unsigned GET rejected (403)"

    count=$(signed_get_count "$url") || die "Signed GET ${url} failed"
    ok "Promotions: signed GET returned ${count} active promotions"
}

print_policy() {
    init
    tf output -raw agentcore_runtime_backends_policy_json 2>/dev/null \
        || die "No outputs yet: run 'bash 6_deploy/scripts/agentcore_backends.sh apply' first"
    echo ""
}

validate() {
    need terraform
    log "terraform fmt -check"
    tf fmt -recursive -check
    log "terraform init -backend=false"
    tf init -backend=false -input=false >/dev/null
    log "terraform validate"
    tf validate
    log "terraform test (mocked providers; no AWS calls)"
    tf test
    ok "agentcore-backends is valid."
}

destroy() {
    local protected table_protected answer
    init
    protected=$(aws rds describe-db-clusters --region "$REGION" --db-cluster-identifier "$CLUSTER_ID" \
        --query 'DBClusters[0].DeletionProtection' --output text 2>/dev/null || echo "absent")
    table_protected=$(aws dynamodb describe-table --region "$REGION" --table-name "spbc-orders-table" \
        --query 'Table.DeletionProtectionEnabled' --output text 2>/dev/null || echo "absent")
    if [ "$protected" = "True" ] || [ "$table_protected" = "True" ]; then
        warn "Deletion protection is on (database: ${protected}, orders table: ${table_protected}). Turn it off first (this changes nothing else):"
        warn "  bash 6_deploy/scripts/agentcore_backends.sh apply -var aurora_deletion_protection=false -var dynamodb_deletion_protection=false"
        die "Not destroying."
    fi
    if aws rds describe-db-cluster-snapshots --region "$REGION" \
        --db-cluster-snapshot-identifier "${CLUSTER_ID}-final" >/dev/null 2>&1; then
        warn "Snapshot ${CLUSTER_ID}-final exists from an earlier teardown; the cluster can't be deleted"
        warn "until it is gone (copy it under another name first if you need it):"
        warn "  aws rds delete-db-cluster-snapshot --region ${REGION} --db-cluster-snapshot-identifier ${CLUSTER_ID}-final"
        die "Not destroying."
    fi
    warn "This deletes the stores database, the promotions API, the network created for them and the"
    warn "orders and sessions tables. Table data is NOT kept (no final snapshot, and point-in-time"
    warn "recovery ends with the table); export any orders you need first."
    warn "Kept: final snapshot ${CLUSTER_ID}-final (delete it in RDS → Snapshots when no longer needed)."
    warn "The reader secret enters a 7-day recovery window; re-creating the stack within 7 days needs:"
    warn "  aws secretsmanager delete-secret --secret-id spbc-stores-db-reader --force-delete-without-recovery"
    warn "  (or restore it with: aws secretsmanager restore-secret --secret-id spbc-stores-db-reader)"
    read -r -p "Type the cluster name (${CLUSTER_ID}) to continue: " answer
    [ "$answer" = "$CLUSTER_ID" ] || die "Aborted; nothing was changed."
    # terraform shows the destroy plan and asks for its own confirmation
    tf destroy -input=true "$@"
}

usage() {
    # The header comment, up to the first blank line
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

cmd="${1:-help}"
[ $# -gt 0 ] && shift
case "$cmd" in
    plan)     plan "$@" || [ $? -eq 2 ] ;;
    apply)    apply "$@" ;;
    seed)     seed ;;
    check)    check ;;
    env)      print_env ;;
    policy)   print_policy ;;
    validate) validate ;;
    destroy)  destroy "$@" ;;
    help|-h|--help) usage ;;
    *) usage; die "Unknown command: ${cmd}" ;;
esac
