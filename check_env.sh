#!/bin/bash
set -euo pipefail

# Script to check if required environment variables are set for
# Specialty Bakeries & Pastry Cafés production deployment

echo "=== SPBC Environment Variables Check ==="
echo

# Check required environment variables
required_vars=(
    "REGION"
    "ACCOUNT_ID"
    "MODEL_ID"
    "MODEL_ARN"
    "CLOUDAGE_S3_BUCKET"
    "S3_BUCKET_NAME"
    "MENU_KNOWLEDGE_BASE_ID"
    "ORDERS_KNOWLEDGE_BASE_ID"
    "PAYMENTS_KNOWLEDGE_BASE_ID"
    "STORES_KNOWLEDGE_BASE_ID"
)

all_set=true

for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "❌ $var: NOT SET"
        all_set=false
    else
        echo "✅ $var: ${!var}"
    fi
done

# Stores database: the RDS Data API (Terraform backends) or the legacy MySQL cluster + secret
if [ -n "${STORES_DB_CLUSTER_ARN:-}" ] && [ -n "${STORES_DB_SECRET_ARN:-}" ]; then
    echo "✅ Stores DB (Data API): ${STORES_DB_CLUSTER_ARN}"
    echo "✅ STORES_DB_SECRET_ARN: ${STORES_DB_SECRET_ARN}"
elif [ -n "${STORES_DB_CLUSTER_ARN:-}" ] || [ -n "${STORES_DB_SECRET_ARN:-}" ]; then
    echo "❌ Stores DB: set both STORES_DB_CLUSTER_ARN and STORES_DB_SECRET_ARN, or neither"
    all_set=false
elif [ -n "${DB_CLUSTER_NAME:-}" ] && [ -n "${DB_SECRET_NAME:-}" ]; then
    echo "✅ Stores DB (legacy MySQL): ${DB_CLUSTER_NAME} / ${DB_SECRET_NAME}"
else
    echo "❌ Stores DB: NOT SET (deploy 6_deploy/infra/agentcore-backends, then source setup_env.sh)"
    all_set=false
fi

# Optional
for var in PROMOS_API_URL PROMOS_KNOWLEDGE_BASE_ID; do
    if [ -n "${!var:-}" ]; then
        echo "✅ $var: ${!var}"
    else
        echo "ℹ️  $var: not set (optional)"
    fi
done
if [ -z "${PROMOS_API_URL:-}" ] && [ -z "${PROMOS_KNOWLEDGE_BASE_ID:-}" ]; then
    echo "⚠️  Neither PROMOS_API_URL nor PROMOS_KNOWLEDGE_BASE_ID is set: promotions questions can't be answered"
fi

echo
if [ "$all_set" = true ]; then
    echo "🎉 All required environment variables are set!"
else
    echo "⚠️  Some environment variables are missing."
    echo "   Run: source setup_env.sh"
fi

echo
echo "=== AWS Resource Verification ==="

# Test AWS connectivity
if aws sts get-caller-identity >/dev/null 2>&1; then
    echo "✅ AWS CLI: Connected"
else
    echo "❌ AWS CLI: Not connected or configured"
    exit 1
fi

# Stores database through the Data API: run the agent's query with the reader credentials
if [ -n "${STORES_DB_CLUSTER_ARN:-}" ] && [ -n "${STORES_DB_SECRET_ARN:-}" ]; then
    if stores_out=$(aws rds-data execute-statement --region "${REGION:-eu-central-1}" \
        --resource-arn "$STORES_DB_CLUSTER_ARN" --secret-arn "$STORES_DB_SECRET_ARN" \
        --database "${STORES_DB_NAME:-StoresDB}" --sql "SELECT COUNT(*) FROM stores" \
        --query 'records[0][0].longValue' --output text 2>&1); then
        echo "✅ Stores DB (Data API): ${stores_out} stores readable with the reader secret"
    elif echo "$stores_out" | grep -q "DatabaseResumingException"; then
        echo "⚠️  Stores DB (Data API): the cluster is resuming from auto-pause; re-run in ~30 s"
    else
        echo "❌ Stores DB (Data API): ${stores_out}"
        echo "   (AccessDenied: allow rds-data:ExecuteStatement + secretsmanager:GetSecretValue;"
        echo "    table missing: python3 2_data_strategy/stores/load_stores_data_api.py --from-terraform 6_deploy/infra/agentcore-backends)"
    fi
fi

# Check if DB cluster exists (if DB_CLUSTER_NAME is set)
if [ -n "${DB_CLUSTER_NAME:-}" ]; then
    if aws rds describe-db-clusters --db-cluster-identifier "$DB_CLUSTER_NAME" >/dev/null 2>&1; then
        echo "✅ DB Cluster: $DB_CLUSTER_NAME exists"
    else
        echo "❌ DB Cluster: $DB_CLUSTER_NAME not found"
    fi
fi

# Check if secret exists (if DB_SECRET_NAME is set)
if [ -n "${DB_SECRET_NAME:-}" ]; then
    if aws secretsmanager describe-secret --secret-id "$DB_SECRET_NAME" >/dev/null 2>&1; then
        echo "✅ Secret: $DB_SECRET_NAME exists"
    else
        echo "❌ Secret: $DB_SECRET_NAME not found"
    fi
fi

# Promotions API: one SigV4-signed GET, the same call the promos agent makes
# (a function, because bash 3.2 mis-parses here-documents inside $(...))
promos_probe() {
    python3 - "$1" <<'PY'
import json, re, sys, urllib.error, urllib.request
import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
url = sys.argv[1]
match = re.search(r"\.execute-api\.([a-z0-9-]+)\.amazonaws\.com", url)
creds = boto3.Session().get_credentials()
if creds is None:
    sys.exit("no AWS credentials")
request = AWSRequest(method="GET", url=url, headers={"Accept": "application/json"})
SigV4Auth(creds.get_frozen_credentials(), "execute-api", match.group(1) if match else "eu-central-1").add_auth(request)
try:
    with urllib.request.urlopen(urllib.request.Request(url, headers=dict(request.headers.items())), timeout=10) as r:
        print(len(json.load(r)))
except urllib.error.HTTPError as e:
    sys.exit(f"HTTP {e.code}" + (" (allow execute-api:Invoke on GET /promotions)" if e.code == 403 else ""))
PY
}
if [ -n "${PROMOS_API_URL:-}" ]; then
    if promos_out=$(promos_probe "$PROMOS_API_URL" 2>&1); then
        echo "✅ Promotions API: ${promos_out} active promotions"
    else
        echo "❌ Promotions API: $(echo "$promos_out" | tail -1)"
    fi
fi

# Check DynamoDB orders table
ORDERS_TABLE="${ORDERS_TABLE:-spbc-orders-table}"
if aws dynamodb describe-table --table-name "$ORDERS_TABLE" >/dev/null 2>&1; then
    echo "✅ DynamoDB Orders Table: $ORDERS_TABLE exists"
else
    echo "❌ DynamoDB Orders Table: $ORDERS_TABLE not found"
fi

# Check the Bedrock model can actually be invoked. Listing foundation models isn't enough:
# Nova Pro is listed in eu-central-1 but only works through the EU inference profile.
if [ -n "${MODEL_ID:-}" ] && [ -n "${REGION:-}" ]; then
    if aws bedrock-runtime converse --region "$REGION" --model-id "$MODEL_ID" \
        --messages '[{"role":"user","content":[{"text":"Reply with OK"}]}]' \
        --inference-config '{"maxTokens":5}' >/dev/null 2>&1; then
        echo "✅ Bedrock Model: $MODEL_ID invocable in $REGION"
    else
        echo "❌ Bedrock Model: $MODEL_ID can't be invoked in $REGION (in eu-central-1 use eu.amazon.nova-pro-v1:0; check IAM and SCPs)"
    fi
fi

echo
echo "=== Environment Check Complete ==="
