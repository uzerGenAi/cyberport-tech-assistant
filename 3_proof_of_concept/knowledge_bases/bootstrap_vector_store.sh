#!/bin/bash
# bootstrap_vector_store.sh — the prerequisites every SPBC knowledge base needs.
#
# Creates (and re-uses on later runs):
#   • IAM role  AmazonBedrockExecutionRoleForKnowledgeBase_<region>   — assumed by Bedrock
#   • OpenSearch Serverless encryption, network and data access policies
#   • OpenSearch Serverless VECTORSEARCH collection  spbc-electronics-vectors
#
# Then writes OPENSEARCH_COLLECTION, OPENSEARCH_COLLECTION_ARN, AOSSENDPOINT and ROLE_ARN
# into ~/environment/env.sh, which is what setup_knowledge_bases.sh and the per-domain
# scripts read. Before this existed, those variables could only come from a collection
# created by hand in the console, so an unattended run had nothing to discover.
#
# Usage:
#   bash 3_proof_of_concept/knowledge_bases/bootstrap_vector_store.sh [--bucket NAME]
#
# Requires: aws CLI, jq. The S3 bucket holding the knowledge base documents is taken from
# --bucket, S3_BUCKET_NAME or CLOUDAGE_S3_BUCKET (Step 3 of the walkthrough creates it).
#
# Network access: the collection endpoint is reachable from the internet, because both the
# index creation below and `aws bedrock-agent create-knowledge-base` run outside any VPC.
# Authorization is still controlled by the data access policy, which names exactly two
# principals: the Bedrock role and the identity running this script. The Dashboards
# endpoint is left closed. To restrict the endpoint further afterwards, replace the network
# policy with AllowFromPublic=false plus SourceServices=["bedrock.amazonaws.com"] and run
# index creation from inside a VPC.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./kb_common.sh
. "${SCRIPT_DIR}/kb_common.sh"

COLLECTION_NAME="${COLLECTION_NAME:-${PROJECT_PREFIX}-electronics-vectors}"
ENCRYPTION_POLICY_NAME="${PROJECT_PREFIX}-electronics-enc"
NETWORK_POLICY_NAME="${PROJECT_PREFIX}-electronics-net"
ACCESS_POLICY_NAME="${PROJECT_PREFIX}-electronics-access"
KB_ROLE_NAME="AmazonBedrockExecutionRoleForKnowledgeBase_${REGION}"
COLLECTION_TIMEOUT_SECONDS="${COLLECTION_TIMEOUT_SECONDS:-600}"

KB_BUCKET="${S3_BUCKET_NAME:-${CLOUDAGE_S3_BUCKET:-}}"
while [ $# -gt 0 ]; do
    case "$1" in
        --bucket) KB_BUCKET="$2"; shift 2 ;;
        -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) kb_die "Unknown argument: $1" ;;
    esac
done

kb_need aws jq
aws sts get-caller-identity >/dev/null 2>&1 || kb_die "No AWS credentials (aws sts get-caller-identity failed)"
[ -n "$KB_BUCKET" ] || kb_die "No knowledge base bucket. Pass --bucket NAME or set S3_BUCKET_NAME (walkthrough Step 3)."
aws s3api head-bucket --bucket "$KB_BUCKET" >/dev/null 2>&1 \
    || kb_die "Bucket s3://${KB_BUCKET} not found or not accessible (walkthrough Step 3 creates it)"

ACCOUNT_ID=$(kb_account_id)
CALLER_PRINCIPAL=$(kb_caller_principal)
KB_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${KB_ROLE_NAME}"
COLLECTION_ARN="arn:aws:aoss:${REGION}:${ACCOUNT_ID}:collection/*"

kb_log "Account:    ${ACCOUNT_ID}"
kb_log "Region:     ${REGION}"
kb_log "Collection: ${COLLECTION_NAME}"
kb_log "Bucket:     s3://${KB_BUCKET}"
kb_log "Caller:     ${CALLER_PRINCIPAL}"
echo ""

# ── 1. IAM role assumed by Bedrock for knowledge base operations ──────────────

trust_policy() {
    cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "bedrock.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "${ACCOUNT_ID}" },
        "ArnLike": { "aws:SourceArn": "arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:knowledge-base/*" }
      }
    }
  ]
}
JSON
}

role_policy() {
    cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "VectorStoreAccess",
      "Effect": "Allow",
      "Action": "aoss:APIAccessAll",
      "Resource": "${COLLECTION_ARN}"
    },
    {
      "Sid": "EmbeddingModel",
      "Effect": "Allow",
      "Action": "bedrock:InvokeModel",
      "Resource": "arn:aws:bedrock:${REGION}::foundation-model/${EMBED_MODEL_ID}"
    },
    {
      "Sid": "KnowledgeBaseDocuments",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": ["arn:aws:s3:::${KB_BUCKET}", "arn:aws:s3:::${KB_BUCKET}/*"],
      "Condition": { "StringEquals": { "aws:ResourceAccount": "${ACCOUNT_ID}" } }
    }
  ]
}
JSON
}

if aws iam get-role --role-name "$KB_ROLE_NAME" >/dev/null 2>&1; then
    kb_ok "IAM role ${KB_ROLE_NAME} already exists — refreshing its policies"
    aws iam update-assume-role-policy --role-name "$KB_ROLE_NAME" --policy-document "$(trust_policy)"
else
    kb_log "Creating IAM role ${KB_ROLE_NAME}..."
    aws iam create-role \
        --role-name "$KB_ROLE_NAME" \
        --assume-role-policy-document "$(trust_policy)" \
        --description "Bedrock knowledge base execution role for SPBC" \
        --tags Key=Project,Value=SPBC Key=Component,Value=KnowledgeBase >/dev/null
    kb_ok "IAM role created"
fi

aws iam put-role-policy \
    --role-name "$KB_ROLE_NAME" \
    --policy-name "SPBC-KnowledgeBase-Access" \
    --policy-document "$(role_policy)"
kb_ok "Role policy SPBC-KnowledgeBase-Access attached"

# ── 2. OpenSearch Serverless policies (must exist before the collection) ──────

# Creates a security/access policy, or updates it in place when it already exists.
ensure_aoss_policy() {   # ensure_aoss_policy <security|access> <type> <name> <policy-json>
    local kind="$1" type="$2" name="$3" policy="$4" version
    if version=$(aws opensearchserverless "get-${kind}-policy" --name "$name" --type "$type" \
        --query 'securityPolicyDetail.policyVersion || accessPolicyDetail.policyVersion' \
        --output text 2>/dev/null) && [ -n "$(kb_clean "$version")" ]; then
        aws opensearchserverless "update-${kind}-policy" \
            --name "$name" --type "$type" --policy-version "$version" --policy "$policy" >/dev/null
        kb_ok "${type} policy ${name} updated"
    else
        aws opensearchserverless "create-${kind}-policy" \
            --name "$name" --type "$type" --policy "$policy" >/dev/null
        kb_ok "${type} policy ${name} created"
    fi
}

ensure_aoss_policy security encryption "$ENCRYPTION_POLICY_NAME" "$(cat <<JSON
{
  "Rules": [ { "ResourceType": "collection", "Resource": ["collection/${COLLECTION_NAME}"] } ],
  "AWSOwnedKey": true
}
JSON
)"

# A list, per the network policy syntax. Collection endpoint only; no Dashboards access.
ensure_aoss_policy security network "$NETWORK_POLICY_NAME" "$(cat <<JSON
[
  {
    "Description": "SPBC knowledge base collection endpoint",
    "Rules": [ { "ResourceType": "collection", "Resource": ["collection/${COLLECTION_NAME}"] } ],
    "AllowFromPublic": true
  }
]
JSON
)"

# Data access is where authorization actually happens: only these two principals.
ensure_aoss_policy access data "$ACCESS_POLICY_NAME" "$(cat <<JSON
[
  {
    "Description": "SPBC knowledge base data access",
    "Rules": [
      {
        "ResourceType": "collection",
        "Resource": ["collection/${COLLECTION_NAME}"],
        "Permission": ["aoss:CreateCollectionItems", "aoss:DescribeCollectionItems", "aoss:UpdateCollectionItems"]
      },
      {
        "ResourceType": "index",
        "Resource": ["index/${COLLECTION_NAME}/*"],
        "Permission": ["aoss:CreateIndex", "aoss:DescribeIndex", "aoss:UpdateIndex", "aoss:ReadDocument", "aoss:WriteDocument"]
      }
    ],
    "Principal": ["${KB_ROLE_ARN}", "${CALLER_PRINCIPAL}"]
  }
]
JSON
)"

# ── 3. The collection itself ──────────────────────────────────────────────────

collection_status() {
    local status
    status=$(aws opensearchserverless batch-get-collection --names "$COLLECTION_NAME" \
        --query 'collectionDetails[0].status' --output text 2>/dev/null) || return 1
    kb_clean "$status"
}

status=$(collection_status || true)
if [ -z "$status" ]; then
    kb_log "Creating collection ${COLLECTION_NAME} (this takes a few minutes)..."
    aws opensearchserverless create-collection \
        --name "$COLLECTION_NAME" \
        --type VECTORSEARCH \
        --description "Vector store for the SPBC Tech Assistant knowledge bases" \
        --tags key=Project,value=SPBC >/dev/null
else
    kb_ok "Collection ${COLLECTION_NAME} already exists (status ${status})"
fi

elapsed=0
while [ "$elapsed" -lt "$COLLECTION_TIMEOUT_SECONDS" ]; do
    status=$(collection_status || true)
    case "$status" in
        ACTIVE) break ;;
        FAILED) kb_die "Collection ${COLLECTION_NAME} is FAILED; check the OpenSearch Serverless console" ;;
    esac
    printf '\r  status: %s (%ss)   ' "${status:-CREATING}" "$elapsed"
    sleep 15
    elapsed=$((elapsed + 15))
done
echo ""
[ "$status" = "ACTIVE" ] || kb_die "Collection ${COLLECTION_NAME} did not become ACTIVE within ${COLLECTION_TIMEOUT_SECONDS}s (last status: ${status:-unknown})"
kb_ok "Collection ACTIVE"

details=$(aws opensearchserverless batch-get-collection --names "$COLLECTION_NAME" --output json)
collection_arn=$(printf '%s' "$details" | jq -r '.collectionDetails[0].arn')
collection_endpoint=$(printf '%s' "$details" | jq -r '.collectionDetails[0].collectionEndpoint')

# ── 4. Hand the values to the rest of the pipeline ────────────────────────────

put_env_var OPENSEARCH_COLLECTION "$COLLECTION_NAME"
put_env_var OPENSEARCH_COLLECTION_ARN "$collection_arn"
put_env_var AOSSENDPOINT "$collection_endpoint"
put_env_var ROLE_ARN "$KB_ROLE_ARN"
put_env_var OPENSEARCH_S3_BUCKET_ARN "arn:aws:s3:::${KB_BUCKET}"

echo ""
kb_ok "Vector store ready"
echo "  OPENSEARCH_COLLECTION_ARN = ${collection_arn}"
echo "  AOSSENDPOINT              = ${collection_endpoint}"
echo "  ROLE_ARN                  = ${KB_ROLE_ARN}"
echo "  written to                  ${ENV_FILE}"
echo ""
kb_log "Next: bash ${SCRIPT_DIR#"$PWD/"}/setup_knowledge_bases.sh"
