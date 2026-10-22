#!/bin/bash

# Script to discover and set up environment variables for the lab
# This script uses AWS service APIs to discover resources instead of CloudFormation outputs

echo "=== Setting up Lab Environment Variables ==="
echo

# Create environment file if it doesn't exist
mkdir -p ~/environment
ENV_FILE=~/environment/env.sh

# Clear the environment file to avoid duplicates
> $ENV_FILE

# Basic AWS environment
# Precedence: REGION, then AWS_REGION, then this project's Region. The AWS CLI's configured
# default is deliberately NOT used: it belongs to whatever the operator last worked on, and
# picking it up silently deploys this project into the wrong Region.
export REGION="${REGION:-${AWS_REGION:-eu-central-1}}"
echo "export REGION=$REGION" >> $ENV_FILE
echo "Region: $REGION"

# `aws configure get region` exits non-zero when no region is configured (the normal state
# on a fresh CI runner). The `|| true` stops that from aborting the script under `set -e`.
_cli_region=$(aws configure get region 2>/dev/null || true)
if [ -n "${_cli_region:-}" ] && [ "$_cli_region" != "$REGION" ]; then
    echo "ℹ️  Your AWS CLI default Region is $_cli_region; this run uses $REGION."
    echo "    Export REGION=$_cli_region to override, and note that every resource below is"
    echo "    discovered and created in $REGION."
fi
unset _cli_region
# Every aws call in this script and in the deploy scripts passes --region explicitly, but
# export it too so tools that read only the environment agree.
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
echo "export AWS_REGION=$REGION" >> $ENV_FILE
echo "export AWS_DEFAULT_REGION=$REGION" >> $ENV_FILE

export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "export ACCOUNT_ID=$ACCOUNT_ID" >> $ENV_FILE
echo "Account ID: $ACCOUNT_ID"

# Model configuration
# Nova Pro has no in-Region on-demand capacity in eu-central-1: use the EU cross-Region
# inference profile (routes only to EU Regions). MODEL_ARN is used by RetrieveAndGenerate.
export MODEL_ID="eu.amazon.nova-pro-v1:0"
echo "export MODEL_ID=$MODEL_ID" >> $ENV_FILE
echo "Model ID: $MODEL_ID"

export MODEL_ARN="arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:inference-profile/${MODEL_ID}"
echo "export MODEL_ARN=$MODEL_ARN" >> $ENV_FILE
echo "Model ARN: $MODEL_ARN"
if [ "$REGION" != "eu-central-1" ]; then
    echo "⚠️  REGION is $REGION, not eu-central-1: confirm $MODEL_ID is offered there"
fi

echo
echo "=== Discovering AWS Resources ==="

# Discover Aurora DB cluster by name pattern
echo "Looking for Aurora DB cluster..."
DB_CLUSTER_NAME=$(aws rds describe-db-clusters --query 'DBClusters[?starts_with(DBClusterIdentifier, `spbc-aurora-cluster`)].DBClusterIdentifier' --output text 2>/dev/null | head -1 || true)
if [ -n "$DB_CLUSTER_NAME" ]; then
    echo "export DB_CLUSTER_NAME=$DB_CLUSTER_NAME" >> $ENV_FILE
    echo "✅ Found DB Cluster: $DB_CLUSTER_NAME"
else
    echo "❌ Aurora DB cluster not found (expected prefix: spbc-aurora-cluster; create it with 6_deploy/infra/agentcore-backends)"
fi

# Discover Secrets Manager secret
echo "Looking for database credentials secret..."
DB_SECRET_NAME=$(aws secretsmanager list-secrets --query 'SecretList[?starts_with(Name, `spbc-aurora-db-credentials`)].Name' --output text 2>/dev/null | head -1 || true)
if [ -n "$DB_SECRET_NAME" ]; then
    echo "export DB_SECRET_NAME=$DB_SECRET_NAME" >> $ENV_FILE
    echo "✅ Found DB Secret: $DB_SECRET_NAME"
else
    echo "ℹ️  Legacy database secret not found (spbc-aurora-db-credentials): fine when the Data API settings below are found"
fi

# Stores database through the RDS Data API (Terraform stack 6_deploy/infra/agentcore-backends).
# With both ARNs set the stores agent uses the Data API; otherwise it uses the MySQL driver with
# the legacy cluster/secret above. Stale values from an earlier run are unset, never kept.
echo "Looking for the stores database Data API settings..."
_stores_cluster_arn=$(aws rds describe-db-clusters --region "$REGION" --db-cluster-identifier spbc-aurora-cluster \
    --query 'DBClusters[?HttpEndpointEnabled==`true`].DBClusterArn | [0]' --output text 2>/dev/null || true)
_stores_secret_arn=$(aws secretsmanager describe-secret --region "$REGION" --secret-id spbc-stores-db-reader \
    --query 'DeletedDate == null && ARN || `null`' --output text 2>/dev/null || true)
if [ -n "$_stores_cluster_arn" ] && [ "$_stores_cluster_arn" != "None" ] \
    && [ -n "$_stores_secret_arn" ] && [ "$_stores_secret_arn" != "None" ]; then
    echo "export STORES_DB_CLUSTER_ARN=$_stores_cluster_arn" >> $ENV_FILE
    echo "export STORES_DB_SECRET_ARN=$_stores_secret_arn" >> $ENV_FILE
    echo "export STORES_DB_NAME=StoresDB" >> $ENV_FILE
    echo "✅ Stores database via the RDS Data API: $_stores_cluster_arn"
else
    unset STORES_DB_CLUSTER_ARN STORES_DB_SECRET_ARN STORES_DB_NAME
    echo "ℹ️  No Data API stores database (needs cluster spbc-aurora-cluster with the Data API and secret"
    echo "    spbc-stores-db-reader): the stores agent falls back to the MySQL driver"
fi
unset _stores_cluster_arn _stores_secret_arn

# Promotions API: HTTP API spbcBakeryAPI from the same stack (IAM-authorized GET /prod/promotions)
echo "Looking for the promotions API..."
_promos_endpoint=$(aws apigatewayv2 get-apis --region "$REGION" \
    --query "Items[?Name=='spbcBakeryAPI'].ApiEndpoint | [0]" --output text 2>/dev/null || true)
if [ -n "$_promos_endpoint" ] && [ "$_promos_endpoint" != "None" ]; then
    echo "export PROMOS_API_URL=${_promos_endpoint}/prod/promotions" >> $ENV_FILE
    echo "✅ Found promotions API: ${_promos_endpoint}/prod/promotions"
else
    unset PROMOS_API_URL
    echo "⚠️  Promotions API spbcBakeryAPI not found: promotions come from the promos knowledge base only"
fi
unset _promos_endpoint

# Discover DynamoDB tables
echo "Looking for DynamoDB tables..."
ORDERS_TABLE=$(aws dynamodb list-tables --query 'TableNames[?starts_with(@, `spbc-orders-table`)]' --output text 2>/dev/null | head -1 || true)
if [ -n "$ORDERS_TABLE" ]; then
    echo "export ORDERS_TABLE=$ORDERS_TABLE" >> $ENV_FILE
    echo "✅ Found Orders Table: $ORDERS_TABLE"
else
    echo "❌ Orders table not found (expected: spbc-orders-table)"
fi

SESSIONS_TABLE=$(aws dynamodb list-tables --query 'TableNames[?starts_with(@, `spbc-sessions-table`)]' --output text 2>/dev/null | head -1 || true)
if [ -n "$SESSIONS_TABLE" ]; then
    echo "export SESSIONS_TABLE=$SESSIONS_TABLE" >> $ENV_FILE
    echo "✅ Found Sessions Table: $SESSIONS_TABLE"
else
    echo "❌ Sessions table not found (expected: spbc-sessions-table)"
fi

# Discover OpenSearch collection
echo "Looking for OpenSearch collection..."
OPENSEARCH_COLLECTION=$(aws opensearchserverless list-collections --query 'collectionSummaries[?starts_with(name, `spbc-`) || contains(name, `bakery`) || contains(name, `pastry`)].name' --output text 2>/dev/null | head -1 || true)
if [ -n "$OPENSEARCH_COLLECTION" ]; then
    # Get collection endpoint
    AOSSENDPOINT=$(aws opensearchserverless batch-get-collection --names "$OPENSEARCH_COLLECTION" --query 'collectionDetails[0].collectionEndpoint' --output text 2>/dev/null || true)
    echo "export OPENSEARCH_COLLECTION=$OPENSEARCH_COLLECTION" >> $ENV_FILE
    echo "export AOSSENDPOINT=$AOSSENDPOINT" >> $ENV_FILE
    echo "✅ Found OpenSearch Collection: $OPENSEARCH_COLLECTION"
    echo "✅ OpenSearch Endpoint: $AOSSENDPOINT"
    
    # Get collection ARN
    OPENSEARCH_COLLECTION_ARN=$(aws opensearchserverless batch-get-collection --names "$OPENSEARCH_COLLECTION" --query 'collectionDetails[0].arn' --output text 2>/dev/null || true)
    echo "export OPENSEARCH_COLLECTION_ARN=$OPENSEARCH_COLLECTION_ARN" >> $ENV_FILE
    echo "✅ OpenSearch Collection ARN: $OPENSEARCH_COLLECTION_ARN"
else
    echo "❌ OpenSearch collection not found"
fi

# Discover S3 buckets
echo "Looking for CloudAge S3 bucket..."
CLOUDAGE_S3_BUCKET=$(aws s3api list-buckets --query 'Buckets[?starts_with(Name, `spbc-input-docs-bucket-`) || starts_with(Name, `spbc-kb-`)].Name' --output text 2>/dev/null | head -1 || true)
if [ -n "$CLOUDAGE_S3_BUCKET" ]; then
    echo "export CLOUDAGE_S3_BUCKET=$CLOUDAGE_S3_BUCKET" >> $ENV_FILE
    echo "✅ Found CloudAge S3 Bucket: $CLOUDAGE_S3_BUCKET"
    
    # Get the bucket ARN for OpenSearch knowledge base data sources
    OPENSEARCH_S3_BUCKET_ARN="arn:aws:s3:::$CLOUDAGE_S3_BUCKET"
    echo "export OPENSEARCH_S3_BUCKET_ARN=$OPENSEARCH_S3_BUCKET_ARN" >> $ENV_FILE
    echo "✅ OpenSearch S3 Bucket ARN: $OPENSEARCH_S3_BUCKET_ARN"
    
    # Also set the bucket name for compatibility
    echo "export OpenSearch_BUCKET_NAME=$CLOUDAGE_S3_BUCKET" >> $ENV_FILE
    # The runtime's get_menu tool reads s3://$S3_BUCKET_NAME/menu/menu_records.json
    echo "export S3_BUCKET_NAME=$CLOUDAGE_S3_BUCKET" >> $ENV_FILE
else
    echo "❌ CloudAge S3 bucket not found"
fi

# Discover knowledge base IDs by name. This file is truncated on every run, so IDs appended
# by the KB setup scripts would otherwise be lost when setup_env.sh is re-sourced.
echo "Looking for knowledge bases..."
for domain in menu orders payments stores promos; do
    var_name="$(echo "$domain" | tr '[:lower:]' '[:upper:]')_KNOWLEDGE_BASE_ID"
    kb_id=$(aws bedrock-agent list-knowledge-bases --region "$REGION" \
        --query "knowledgeBaseSummaries[?name=='spbc-${domain}-knowledge-base'].knowledgeBaseId | [0]" \
        --output text 2>/dev/null || true)
    if [ -n "$kb_id" ] && [ "$kb_id" != "None" ]; then
        echo "export ${var_name}=${kb_id}" >> $ENV_FILE
        echo "✅ Found ${var_name}: ${kb_id}"
    elif [ "$domain" = "promos" ]; then
        echo "⚠️  spbc-promos-knowledge-base not found (optional: promos then relies on the promotions API only)"
    else
        echo "❌ spbc-${domain}-knowledge-base not found (required by the agent runtime)"
    fi
done

# Guardrail (optional) — stored in SSM by 5_security_rai/create_and_store_guardrail.sh
# The guardrail is optional and may not be in SSM. The `|| true` keeps a missing parameter
# from aborting the script when it is sourced under `set -e` (as the CI deploy job does): a
# failed command substitution is itself a failed command, which `set -e` treats as fatal even
# though the `if` below is written to handle an empty value.
GR_ID=$(aws ssm get-parameter --name "/SPBC/guardrail/id" --region "$REGION" --query "Parameter.Value" --output text 2>/dev/null || true)
GR_VERSION=$(aws ssm get-parameter --name "/SPBC/guardrail/version" --region "$REGION" --query "Parameter.Value" --output text 2>/dev/null || true)
if [ -n "$GR_ID" ] && [ -n "$GR_VERSION" ]; then
    echo "export GUARDRAIL_ID=$GR_ID" >> $ENV_FILE
    echo "export GUARDRAIL_VERSION=$GR_VERSION" >> $ENV_FILE
    echo "✅ Found guardrail: $GR_ID (version $GR_VERSION)"
else
    echo "ℹ️  No guardrail in SSM (/SPBC/guardrail/*) — the runtime runs without one"
fi

# Derive Bedrock execution role ARN directly (avoids IAM API call which has no VPC endpoint)
echo "Looking for Bedrock execution role..."
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/AmazonBedrockExecutionRoleForKnowledgeBase_${REGION}"
echo "export ROLE_ARN=$ROLE_ARN" >> $ENV_FILE
echo "✅ Found Bedrock Role: $ROLE_ARN"

echo
echo "=== Loading Environment Variables ==="
source $ENV_FILE
echo "✅ Environment variables loaded from $ENV_FILE"



echo
echo "=== Environment Setup Complete ==="
echo "Run 'source ~/environment/env.sh' to load these variables in new terminal sessions"