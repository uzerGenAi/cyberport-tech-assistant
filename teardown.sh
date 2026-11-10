#!/usr/bin/env bash
# Delete every AWS resource the Cyberport Tech Assistant deployment created, so you can redeploy
# from a clean account.
#
#   ./teardown.sh               DRY RUN: list what exists and would be deleted (changes nothing)
#   ./teardown.sh --execute     delete it (asks you to type the AWS account id first)
#
# Options (environment variables):
#   KEEP_STATE_BUCKET=1   keep the Terraform state bucket (default: deleted last)
#   CONFIRM_ACCOUNT=<id>  skip the typed prompt in non-interactive use
#
# Scope: only this project's resources, matched by exact name (spbc-*, tech_assistant_agent,
# SPBC-*). Anything else in the account, and account-wide settings such as the CloudWatch
# Transaction Search / X-Ray configuration and the shared aws/spans log group, is left alone.
# Each item is skipped when it is already gone, so after a partial failure just re-run it.
# DATA IS NOT KEPT: the stores database, the orders table, the knowledge-base
# vectors and the AgentCore Memory are deleted with no snapshot.
set -eo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
[ -f .venv/bin/activate ] && source .venv/bin/activate || true

REGION="eu-central-1"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" REGION AWS_PAGER=""
EXECUTE=0
case "${1:-}" in
    "") ;;
    --execute) EXECUTE=1 ;;
    -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (use --execute or no argument)" >&2; exit 1 ;;
esac

say()  { printf '\033[0;34mℹ  %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m✅ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠  %s\033[0m\n' "$*"; }
die()  { printf '\033[0;31m❌ %s\033[0m\n' "$*" >&2; exit 1; }
hdr()  { printf '\n\033[0;36m━━ %s\033[0m\n' "$*"; }

command -v aws >/dev/null || die "aws CLI not found"
ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null) || die "No working AWS credentials"
ACCT=$(aws sts get-caller-identity --query Account --output text)
STATE_BUCKET="${TF_STATE_BUCKET:-spbc-tfstate-${ACCT}}"
DOCS_BUCKET="spbc-kb-docs-${ACCT}"
CB_SRC_BUCKET="bedrock-agentcore-codebuild-sources-${ACCT}-${REGION}"
FAILED=()
FOUND=0

# wait_gone "<label>" "<command that prints something while the resource exists>" [max_seconds]
wait_gone() {
    local label="$1" cmd="$2" max="${3:-600}" t=0 v
    while [ "$t" -lt "$max" ]; do
        v=$(eval "$cmd" 2>/dev/null || true)
        [ -z "$v" ] || [ "$v" = "None" ] && return 0
        sleep 10; t=$((t + 10))
    done
    warn "$label still present after ${max}s"; return 1
}

# item "<label>" "<command printing the id when the resource exists>" <delete_function>
item() {
    local label="$1" exists="$2" del="$3" v
    v=$(eval "$exists" 2>/dev/null || true)
    if [ -z "$v" ] || [ "$v" = "None" ]; then
        printf '  \033[0;90m-\033[0m %-36s not present\n' "$label"; return 0
    fi
    FOUND=$((FOUND + 1))
    if [ "$EXECUTE" != 1 ]; then
        printf '  \033[1;33m•\033[0m %-36s would delete  %s\n' "$label" "$(echo "$v" | tr '\n\t' '  ' | cut -c1-70)"; return 0
    fi
    printf '  \033[0;31m✗\033[0m %-36s deleting...\n' "$label"
    if "$del" "$v"; then ok "$label deleted"; else warn "$label FAILED"; FAILED+=("$label"); fi
}

del_role() { # role name: remove inline + managed policies and instance profiles first
    local r="$1" p
    for p in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames[]' --output text 2>/dev/null); do
        aws iam delete-role-policy --role-name "$r" --policy-name "$p"
    done
    for p in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
        aws iam detach-role-policy --role-name "$r" --policy-arn "$p"
    done
    for p in $(aws iam list-instance-profiles-for-role --role-name "$r" --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null); do
        aws iam remove-role-from-instance-profile --instance-profile-name "$p" --role-name "$r"
    done
    aws iam delete-role --role-name "$r"
}

# ── deleters (each receives the value printed by its existence check) ────────
d_demo_secret() { aws secretsmanager delete-secret --secret-id spbc-demo-user --force-delete-without-recovery --region "$REGION" >/dev/null; }
d_harness()   { python3 6_deploy/harness/deploy_harness.py teardown; }
d_amplify()   { aws amplify delete-app --app-id "$1" --region "$REGION" >/dev/null; }
d_runtime() {
    local id="$1" ep
    for ep in $(aws bedrock-agentcore-control list-agent-runtime-endpoints --agent-runtime-id "$id" --region "$REGION" \
                --query "runtimeEndpoints[?name!='DEFAULT'].name" --output text 2>/dev/null); do
        aws bedrock-agentcore-control delete-agent-runtime-endpoint --agent-runtime-id "$id" --endpoint-name "$ep" --region "$REGION" >/dev/null || true
    done
    aws bedrock-agentcore-control delete-agent-runtime --agent-runtime-id "$id" --region "$REGION" >/dev/null
    wait_gone runtime "aws bedrock-agentcore-control get-agent-runtime --agent-runtime-id $id --region $REGION --query status --output text" 600
}
d_memory() {
    aws bedrock-agentcore-control delete-memory --memory-id "$1" --region "$REGION" >/dev/null
    wait_gone memory "aws bedrock-agentcore-control get-memory --memory-id $1 --region $REGION --query memory.status --output text" 600
}
d_kbs() { # value: "<kbId>|<name>" lines
    local line kb ds
    for line in $1; do
        kb="${line%%|*}"
        for ds in $(aws bedrock-agent list-data-sources --knowledge-base-id "$kb" --region "$REGION" --query 'dataSourceSummaries[].dataSourceId' --output text); do
            aws bedrock-agent delete-data-source --knowledge-base-id "$kb" --data-source-id "$ds" --region "$REGION" >/dev/null
        done
        wait_gone "data sources of $kb" "aws bedrock-agent list-data-sources --knowledge-base-id $kb --region $REGION --query 'dataSourceSummaries[].dataSourceId' --output text" 300 || true
        aws bedrock-agent delete-knowledge-base --knowledge-base-id "$kb" --region "$REGION" >/dev/null
        wait_gone "knowledge base $kb" "aws bedrock-agent get-knowledge-base --knowledge-base-id $kb --region $REGION --query knowledgeBase.status --output text" 300 || true
    done
}
d_collection() {
    aws opensearchserverless delete-collection --id "$1" --region "$REGION" >/dev/null
    wait_gone collection "aws opensearchserverless batch-get-collection --ids $1 --region $REGION --query 'collectionDetails[0].status' --output text" 900
}
d_aoss_policies() {
    aws opensearchserverless delete-security-policy --name spbc-electronics-enc --type encryption --region "$REGION" >/dev/null 2>&1 || true
    aws opensearchserverless delete-security-policy --name spbc-electronics-net --type network --region "$REGION" >/dev/null 2>&1 || true
    aws opensearchserverless delete-access-policy --name spbc-electronics-access --type data --region "$REGION" >/dev/null 2>&1 || true
}
d_guardrail() {
    aws bedrock delete-guardrail --guardrail-identifier "$1" --region "$REGION" >/dev/null
}
d_ssm() { aws ssm delete-parameters --names $1 --region "$REGION" >/dev/null; }
d_identity_pool() { aws cognito-identity delete-identity-pool --identity-pool-id "$1" --region "$REGION"; }
d_user_pool()     { aws cognito-idp delete-user-pool --user-pool-id "$1" --region "$REGION"; }
d_role()          { del_role "$1"; }
d_codebuild() {
    local role
    role=$(aws codebuild batch-get-projects --names "$1" --region "$REGION" --query 'projects[0].serviceRole' --output text 2>/dev/null | sed 's#.*/##')
    aws codebuild delete-project --name "$1" --region "$REGION" >/dev/null
    # The toolkit's CodeBuild role is only removed when it belongs to this project
    if [ -n "$role" ] && [ "$role" != "None" ]; then del_role "$role" || true; fi
}
d_ecr()           { aws ecr delete-repository --repository-name "$1" --force --region "$REGION" >/dev/null; }
d_cb_source() {
    aws s3 rm "s3://${CB_SRC_BUCKET}/tech_assistant_agent/" --recursive >/dev/null
    # The bucket is shared by every toolkit agent in the account: delete it only when empty
    if [ -z "$(aws s3api list-objects-v2 --bucket "$CB_SRC_BUCKET" --max-items 1 --query 'Contents[0].Key' --output text 2>/dev/null | grep -v '^None$')" ]; then
        aws s3 rb "s3://${CB_SRC_BUCKET}" >/dev/null || true
    fi
}
d_docs_bucket()   { aws s3 rb "s3://$1" --force >/dev/null; }
d_loggroup() { local g; for g in $1; do aws logs delete-log-group --log-group-name "$g" --region "$REGION"; done; }
d_backends() {
    export AUTO_APPROVE=1
    say "Turning off deletion protection..."
    # A full teardown keeps no data (the database never takes a final snapshot): switch protection off first
    local tf_vars=(-var aurora_deletion_protection=false -var dynamodb_deletion_protection=false)
    bash 6_deploy/scripts/agentcore_backends.sh apply "${tf_vars[@]}"
    say "terraform destroy (Aurora takes about 10 minutes)..."
    bash 6_deploy/scripts/agentcore_backends.sh destroy "${tf_vars[@]}"
}
d_secret() { aws secretsmanager delete-secret --secret-id spbc-stores-db-reader --force-delete-without-recovery --region "$REGION" >/dev/null; }
d_state_bucket() {
    python3 - "$1" <<'PY'
import sys, boto3
b = boto3.resource("s3", region_name="eu-central-1").Bucket(sys.argv[1])
b.object_versions.delete()      # versioned bucket: remove every version and delete marker
b.delete()
PY
}

# ── header and confirmation ──────────────────────────────────────────────────
printf '\033[0;36m━━ Cyberport Tech Assistant teardown (%s)\033[0m\n' "$([ "$EXECUTE" = 1 ] && echo EXECUTE || echo 'DRY RUN: nothing is changed')"
say "AWS identity: $ARN"
say "Account: $ACCT   Region: $REGION"

# ── the list, in dependency order ────────────────────────────────────────────
run_all() {
    hdr "harness-manager (AgentCore harness, gateway and their roles)"
    item "harness-manager harness + gateway" "echo \$(aws bedrock-agentcore-control list-harnesses --region $REGION --query \"harnesses[?harnessName=='harness_manager'].harnessId|[0]\" --output text 2>/dev/null | grep -v None)\$(aws bedrock-agentcore-control list-gateways --region $REGION --query \"items[?name=='spbc-order-admin-gateway'].gatewayId|[0]\" --output text 2>/dev/null | grep -v None)\$(aws iam get-role --role-name SPBC-HarnessManager-ExecutionRole --query Role.RoleName --output text 2>/dev/null)\$(aws iam get-role --role-name SPBC-OrderAdminGateway-Role --query Role.RoleName --output text 2>/dev/null)" d_harness

    hdr "Web app and runtime"
    item "Amplify app spbc-tech-assistant" "aws amplify list-apps --region $REGION --query \"apps[?name=='spbc-tech-assistant'].appId|[0]\" --output text" d_amplify
    item "AgentCore runtime" "aws bedrock-agentcore-control list-agent-runtimes --region $REGION --query \"agentRuntimes[?agentRuntimeName=='tech_assistant_agent'].agentRuntimeId|[0]\" --output text" d_runtime
    item "AgentCore Memory" "aws bedrock-agentcore-control list-memories --region $REGION --query \"memories[?starts_with(id,'spbc_tech_assistant_memory-')].id|[0]\" --output text" d_memory

    hdr "Knowledge bases and vector store"
    item "Knowledge bases (5)" "aws bedrock-agent list-knowledge-bases --region $REGION --query \"knowledgeBaseSummaries[?starts_with(name,'spbc-') && ends_with(name,'-knowledge-base')].[knowledgeBaseId,name]\" --output text | awk '{print \$1\"|\"\$2}'" d_kbs
    item "OpenSearch collection" "aws opensearchserverless list-collections --region $REGION --query \"collectionSummaries[?name=='spbc-electronics-vectors'].id|[0]\" --output text" d_collection
    # Policies can only go once the collection is gone (in a dry run the collection still exists)
    item "OpenSearch policies (3)" "aws opensearchserverless list-security-policies --type encryption --region $REGION --query \"securityPolicySummaries[?name=='spbc-electronics-enc'].name|[0]\" --output text" d_aoss_policies

    hdr "Guardrail and sign-in"
    item "Guardrail" "aws ssm get-parameter --name /SPBC/guardrail/id --region $REGION --query Parameter.Value --output text" d_guardrail
    item "SSM parameters /SPBC/guardrail/*" "aws ssm get-parameters-by-path --path /SPBC/guardrail --region $REGION --query 'Parameters[].Name' --output text" d_ssm
    item "Cognito identity pool" "aws cognito-identity list-identity-pools --max-results 60 --region $REGION --query \"IdentityPools[?IdentityPoolName=='SPBCIdentityPool'].IdentityPoolId|[0]\" --output text" d_identity_pool
    item "Cognito user pool spbcuserpool" "aws cognito-idp list-user-pools --max-results 60 --region $REGION --query \"UserPools[?Name=='spbcuserpool'].Id|[0]\" --output text" d_user_pool
    item "Secret spbc-demo-user (default login)" "aws secretsmanager describe-secret --secret-id spbc-demo-user --region $REGION --query Name --output text" d_demo_secret
    item "IAM role SPBC_Cognito_AuthRole" "aws iam get-role --role-name SPBC_Cognito_AuthRole --query Role.RoleName --output text" d_role

    hdr "Build artifacts"
    item "CodeBuild project (+ its role)" "aws codebuild batch-get-projects --names bedrock-agentcore-tech_assistant_agent-builder --region $REGION --query 'projects[0].name' --output text" d_codebuild
    item "ECR repository" "aws ecr describe-repositories --repository-names bedrock-agentcore-tech_assistant_agent --region $REGION --query 'repositories[0].repositoryName' --output text" d_ecr
    item "CodeBuild source uploads" "aws s3api list-objects-v2 --bucket $CB_SRC_BUCKET --prefix tech_assistant_agent/ --max-items 1 --query 'Contents[0].Key' --output text" d_cb_source
    item "Runtime and build log groups" "aws logs describe-log-groups --region $REGION --query \"logGroups[?starts_with(logGroupName,'/aws/bedrock-agentcore/runtimes/tech_assistant_agent-')||logGroupName=='/aws/codebuild/bedrock-agentcore-tech_assistant_agent-builder'].logGroupName\" --output text" d_loggroup

    hdr "IAM roles and documents"
    item "IAM role SPBC-AgentCore-ExecutionRole" "aws iam get-role --role-name SPBC-AgentCore-ExecutionRole --query Role.RoleName --output text" d_role
    item "IAM role (knowledge bases)" "aws iam get-role --role-name AmazonBedrockExecutionRoleForKnowledgeBase_${REGION} --query Role.RoleName --output text" d_role
    item "Documents bucket" "aws s3api head-bucket --bucket $DOCS_BUCKET >/dev/null 2>&1 && echo $DOCS_BUCKET" d_docs_bucket

    hdr "Data backends (Terraform): Aurora, orders table, promotions API, order-admin Lambda"
    item "Terraform backends stack" "echo \$(aws rds describe-db-clusters --db-cluster-identifier spbc-aurora-cluster --region $REGION --query 'DBClusters[0].Status' --output text 2>/dev/null)\$(aws dynamodb describe-table --table-name spbc-orders-table --region $REGION --query 'Table.TableStatus' --output text 2>/dev/null)" d_backends
    item "Secret spbc-stores-db-reader" "aws secretsmanager describe-secret --secret-id spbc-stores-db-reader --region $REGION --query 'ARN' --output text" d_secret

    hdr "Terraform state bucket"
    if [ "${KEEP_STATE_BUCKET:-0}" = "1" ]; then
        say "KEEP_STATE_BUCKET=1: keeping s3://$STATE_BUCKET"
    else
        item "State bucket $STATE_BUCKET" "aws s3api head-bucket --bucket $STATE_BUCKET >/dev/null 2>&1 && echo $STATE_BUCKET" d_state_bucket
    fi
}

if [ "$EXECUTE" = 1 ]; then
    warn "This permanently deletes the resources below, including all data (no snapshots)."
    if [ -n "${CONFIRM_ACCOUNT:-}" ]; then
        ans="$CONFIRM_ACCOUNT"
    elif [ -t 0 ]; then
        read -r -p "Type the AWS account id ($ACCT) to continue: " ans
    else
        die "Non-interactive run: set CONFIRM_ACCOUNT=$ACCT to confirm."
    fi
    [ "$ans" = "$ACCT" ] || die "Confirmation did not match the account id. Nothing was changed."
fi

run_all

# ── local state, so the next deploy starts clean ─────────────────────────────
hdr "Local generated files"
LOCAL=(6_deploy/web-app/cognito-config.json 6_deploy/web-app/agentcore-config.json 6_deploy/agents/.bedrock_agentcore.yaml \
       "$HOME/environment/env.sh" .deploy-logs 6_deploy/infra/agentcore-backends/.build)
for f in "${LOCAL[@]}"; do
    if [ -e "$f" ]; then
        if [ "$EXECUTE" = 1 ]; then rm -rf "$f"; printf '  \033[0;31m✗\033[0m removed %s\n' "$f"
        else printf '  \033[1;33m•\033[0m would remove %s\n' "$f"; fi
    fi
done

echo
if [ "$EXECUTE" != 1 ]; then
    say "$FOUND resource group(s) found. Dry run only: nothing was deleted."
    say "To delete them:  ./teardown.sh --execute"
    exit 0
fi
if [ "${#FAILED[@]}" -gt 0 ]; then
    warn "These items failed: ${FAILED[*]}"
    die "Teardown incomplete. Read the messages above, then re-run ./teardown.sh --execute (finished items are skipped)."
fi
ok "Teardown complete. Check with ./deploy.sh status, then redeploy with ./deploy.sh"
