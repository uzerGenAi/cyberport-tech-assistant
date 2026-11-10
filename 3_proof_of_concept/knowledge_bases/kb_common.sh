#!/bin/bash
# kb_common.sh — shared, idempotent helpers for the SPBC knowledge bases.
#
# Sourced by bootstrap_vector_store.sh, setup_knowledge_bases.sh and
# <domain>_knowledge_base_setup.sh. Not meant to be run directly.
#
# Every ensure_* function is safe to re-run: it reuses what already exists instead of
# failing, which is what lets an unattended pipeline retry a partial deployment.

# shellcheck shell=bash

REGION="${REGION:-eu-central-1}"
PROJECT_PREFIX="${PROJECT_PREFIX:-spbc}"
ENV_FILE="${ENV_FILE:-$HOME/environment/env.sh}"
EMBED_MODEL_ID="${EMBED_MODEL_ID:-amazon.titan-embed-text-v2:0}"
EMBED_DIMENSIONS="${EMBED_DIMENSIONS:-1024}"
# A new OpenSearch Serverless index is not immediately usable by Bedrock
INDEX_PROPAGATION_SECONDS="${INDEX_PROPAGATION_SECONDS:-60}"
INGESTION_TIMEOUT_SECONDS="${INGESTION_TIMEOUT_SECONDS:-900}"

# shellcheck disable=SC2034  # read by setup_knowledge_bases.sh, which sources this file
KB_DOMAINS_ALL="menu orders payments stores"

# All progress output goes to stderr: ensure_kb and ensure_data_source return their IDs on
# stdout, so anything logged there would be captured as part of the ID.
kb_log()  { echo "ℹ️  $*" >&2; }
kb_ok()   { echo "✅ $*" >&2; }
kb_warn() { echo "⚠️  $*" >&2; }
kb_die()  { echo "❌ $*" >&2; exit 1; }

kb_need() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || kb_die "$cmd is required but not installed"
    done
}

# "None"/"null" from the AWS CLI mean "absent"; turn them into an empty string
kb_clean() {
    case "$1" in
        None|null|"") printf '' ;;
        *) printf '%s' "$1" ;;
    esac
}

# Writes an export into ENV_FILE, replacing any previous value for that name.
# The original lab scripts appended, so re-running them left duplicate exports behind.
put_env_var() {
    local name="$1" value="$2" tmp
    mkdir -p "$(dirname "$ENV_FILE")"
    [ -f "$ENV_FILE" ] || : > "$ENV_FILE"
    tmp=$(mktemp)
    grep -v "^export ${name}=" "$ENV_FILE" > "$tmp" 2>/dev/null || true
    printf 'export %s=%s\n' "$name" "$value" >> "$tmp"
    mv "$tmp" "$ENV_FILE"
    export "${name}=${value}"
}

kb_env_var_name() {   # menu -> MENU_KNOWLEDGE_BASE_ID
    printf '%s_KNOWLEDGE_BASE_ID' "$(echo "$1" | tr '[:lower:]' '[:upper:]')"
}

kb_name_for()         { printf '%s-%s-knowledge-base' "$PROJECT_PREFIX" "$1"; }
kb_index_for()        { printf 'electronics_%s_index' "$1"; }
kb_prefix_for()       { printf 'electronics_%s/' "$1"; }
kb_data_source_for()  { printf '%s-%s-kb-data-source' "$PROJECT_PREFIX" "$1"; }

# The IAM role ARN of the current identity, in the form data access policies accept
# (an assumed-role session ARN is not valid there).
kb_caller_principal() {
    local arn
    arn=$(aws sts get-caller-identity --query Arn --output text) || return 1
    case "$arn" in
        *:assumed-role/*)
            # arn:aws:sts::acct:assumed-role/RoleName/session -> arn:aws:iam::acct:role/RoleName
            printf 'arn:aws:iam::%s:role/%s' \
                "$(printf '%s' "$arn" | cut -d: -f5)" \
                "$(printf '%s' "$arn" | cut -d/ -f2)" ;;
        *) printf '%s' "$arn" ;;
    esac
}

kb_account_id() { aws sts get-caller-identity --query Account --output text; }

# ── Knowledge base resources ─────────────────────────────────────────────────

kb_id_by_name() {
    local name="$1" id
    id=$(aws bedrock-agent list-knowledge-bases --region "$REGION" \
        --query "knowledgeBaseSummaries[?name=='${name}'].knowledgeBaseId | [0]" \
        --output text 2>/dev/null) || return 1
    kb_clean "$id"
}

kb_data_source_id_by_name() {
    local kb_id="$1" ds_name="$2" id
    id=$(aws bedrock-agent list-data-sources --region "$REGION" --knowledge-base-id "$kb_id" \
        --query "dataSourceSummaries[?name=='${ds_name}'].dataSourceId | [0]" \
        --output text 2>/dev/null) || return 1
    kb_clean "$id"
}

# The vector index every domain uses. Only the name differs between domains.
kb_index_body() {
    cat <<JSON
{
  "settings": { "index": { "knn": true, "knn.algo_param.ef_search": 512 } },
  "mappings": {
    "properties": {
      "documentid": {
        "type": "knn_vector",
        "dimension": ${EMBED_DIMENSIONS},
        "method": { "name": "hnsw", "engine": "faiss", "space_type": "l2" }
      },
      "spbc-data": { "type": "text", "index": "true" },
      "spbc-metadata": { "type": "text", "index": "false" }
    }
  }
}
JSON
}

# Creates the domain's vector index, or confirms it already exists.
ensure_index() {
    local domain="$1" index response
    index=$(kb_index_for "$domain")
    [ -n "${AOSSENDPOINT:-}" ] || kb_die "AOSSENDPOINT is not set — run bootstrap_vector_store.sh first"

    # awscurl prints the HTTP body and usually exits 0 even for 4xx, so inspect the body
    response=$(awscurl --service aoss --region "$REGION" \
        -H "Content-Type: application/json" -X PUT "${AOSSENDPOINT}/${index}" \
        -d "$(kb_index_body)" 2>&1) || true

    if printf '%s' "$response" | grep -q "resource_already_exists_exception"; then
        kb_ok "Index ${index} already exists"
        return 0
    fi
    if printf '%s' "$response" | grep -q '"acknowledged"[[:space:]]*:[[:space:]]*true'; then
        kb_ok "Index ${index} created"
        kb_log "Waiting ${INDEX_PROPAGATION_SECONDS}s for index propagation..."
        sleep "$INDEX_PROPAGATION_SECONDS"
        return 0
    fi
    kb_warn "Unexpected response creating index ${index}:"
    kb_warn "$response"
    kb_die "Could not create index ${index} (check the data access policy covers $(kb_caller_principal))"
}

# Creates the knowledge base, or returns the existing one's ID. Retries while IAM and the
# data access policy settle, which otherwise surfaces as a ValidationException.
ensure_kb() {
    local domain="$1" name kb_id attempt=1 max_attempts=5 delay=15 output
    name=$(kb_name_for "$domain")

    kb_id=$(kb_id_by_name "$name") || kb_die "Could not list knowledge bases in ${REGION}"
    if [ -n "$kb_id" ]; then
        kb_ok "Knowledge base ${name} already exists (${kb_id})"
        printf '%s' "$kb_id"
        return 0
    fi

    [ -n "${ROLE_ARN:-}" ] || kb_die "ROLE_ARN is not set — run bootstrap_vector_store.sh first"
    [ -n "${OPENSEARCH_COLLECTION_ARN:-}" ] || kb_die "OPENSEARCH_COLLECTION_ARN is not set — run bootstrap_vector_store.sh first"

    while [ "$attempt" -le "$max_attempts" ]; do
        if output=$(aws bedrock-agent create-knowledge-base \
            --region "$REGION" \
            --name "$name" \
            --role-arn "$ROLE_ARN" \
            --knowledge-base-configuration "type=VECTOR,vectorKnowledgeBaseConfiguration={embeddingModelArn=arn:aws:bedrock:${REGION}::foundation-model/${EMBED_MODEL_ID},embeddingModelConfiguration={bedrockEmbeddingModelConfiguration={dimensions=${EMBED_DIMENSIONS}}}}" \
            --storage-configuration "type=OPENSEARCH_SERVERLESS,opensearchServerlessConfiguration={collectionArn=${OPENSEARCH_COLLECTION_ARN},vectorIndexName=$(kb_index_for "$domain"),fieldMapping={vectorField=documentid,textField=spbc-data,metadataField=spbc-metadata}}" \
            --output json 2>&1); then
            kb_id=$(printf '%s' "$output" | jq -r '.knowledgeBase.knowledgeBaseId')
            kb_ok "Knowledge base ${name} created (${kb_id})"
            printf '%s' "$kb_id"
            return 0
        fi

        # A racing create (parallel run) is fine: adopt the existing one
        if printf '%s' "$output" | grep -q "ConflictException"; then
            kb_id=$(kb_id_by_name "$name")
            if [ -n "$kb_id" ]; then
                kb_ok "Knowledge base ${name} already exists (${kb_id})"
                printf '%s' "$kb_id"
                return 0
            fi
        fi

        if printf '%s' "$output" | grep -qE "ValidationException|AccessDenied|not authorized|could not be assumed"; then
            kb_warn "create-knowledge-base attempt ${attempt}/${max_attempts} failed while permissions settle; retrying in ${delay}s"
            sleep "$delay"
            attempt=$((attempt + 1))
            continue
        fi

        kb_warn "$output"
        kb_die "create-knowledge-base failed for ${name}"
    done
    kb_die "create-knowledge-base kept failing for ${name}; the last error is above"
}

ensure_data_source() {
    local kb_id="$1" domain="$2" ds_name ds_id output
    ds_name=$(kb_data_source_for "$domain")

    ds_id=$(kb_data_source_id_by_name "$kb_id" "$ds_name") || kb_die "Could not list data sources for ${kb_id}"
    if [ -n "$ds_id" ]; then
        kb_ok "Data source ${ds_name} already exists (${ds_id})"
        printf '%s' "$ds_id"
        return 0
    fi

    [ -n "${OPENSEARCH_S3_BUCKET_ARN:-}" ] || kb_die "OPENSEARCH_S3_BUCKET_ARN is not set — run 'source setup_env.sh'"
    if ! output=$(aws bedrock-agent create-data-source \
        --region "$REGION" \
        --knowledge-base-id "$kb_id" \
        --name "$ds_name" \
        --data-source-configuration "type=S3,s3Configuration={bucketArn=${OPENSEARCH_S3_BUCKET_ARN},inclusionPrefixes=[$(kb_prefix_for "$domain")]}" \
        --output json 2>&1); then
        kb_warn "$output"
        kb_die "create-data-source failed for ${ds_name}"
    fi
    ds_id=$(printf '%s' "$output" | jq -r '.dataSource.dataSourceId')
    kb_ok "Data source ${ds_name} created (${ds_id})"
    printf '%s' "$ds_id"
}

# Syncs the data source and waits for the result. Fails when nothing was indexed, so an
# unattended run cannot mistake an empty knowledge base for a working one.
sync_kb() {
    local kb_id="$1" ds_id="$2" job_id status elapsed=0 stats scanned failed indexed
    job_id=$(aws bedrock-agent start-ingestion-job --region "$REGION" \
        --knowledge-base-id "$kb_id" --data-source-id "$ds_id" \
        --query 'ingestionJob.ingestionJobId' --output text) \
        || kb_die "Could not start an ingestion job for ${kb_id}"
    kb_log "Ingestion job ${job_id} started; waiting for it to finish..."

    while [ "$elapsed" -lt "$INGESTION_TIMEOUT_SECONDS" ]; do
        status=$(aws bedrock-agent get-ingestion-job --region "$REGION" \
            --knowledge-base-id "$kb_id" --data-source-id "$ds_id" --ingestion-job-id "$job_id" \
            --query 'ingestionJob.status' --output text)
        case "$status" in
            COMPLETE|FAILED|STOPPED) break ;;
        esac
        sleep 10
        elapsed=$((elapsed + 10))
    done

    stats=$(aws bedrock-agent get-ingestion-job --region "$REGION" \
        --knowledge-base-id "$kb_id" --data-source-id "$ds_id" --ingestion-job-id "$job_id" \
        --query 'ingestionJob.statistics' --output json)
    scanned=$(printf '%s' "$stats" | jq '.numberOfDocumentsScanned // 0')
    failed=$(printf '%s' "$stats" | jq '.numberOfDocumentsFailed // 0')
    indexed=$(printf '%s' "$stats" | jq '(.numberOfNewDocumentsIndexed // 0) + (.numberOfModifiedDocumentsIndexed // 0)')

    if [ "$status" != "COMPLETE" ]; then
        kb_die "Ingestion job ${job_id} ended with status ${status} (scanned ${scanned}, failed ${failed})"
    fi
    if [ "$scanned" -eq 0 ]; then
        kb_die "Ingestion job ${job_id} scanned 0 documents — check the S3 prefix holds the expected file"
    fi
    if [ "$failed" -gt 0 ]; then
        kb_die "Ingestion job ${job_id} failed on ${failed} document(s)"
    fi
    kb_ok "Sync COMPLETE (scanned ${scanned}, indexed ${indexed}, failed 0)"
}

# Full idempotent path for one domain: index -> KB -> data source -> sync -> env.sh
ensure_knowledge_base() {
    local domain="$1" kb_id ds_id var_name
    kb_log "=== ${domain} knowledge base ==="
    ensure_index "$domain"
    kb_id=$(ensure_kb "$domain")
    ds_id=$(ensure_data_source "$kb_id" "$domain")
    sync_kb "$kb_id" "$ds_id"
    var_name=$(kb_env_var_name "$domain")
    put_env_var "$var_name" "$kb_id"
    put_env_var "$(echo "$domain" | tr '[:lower:]' '[:upper:]')_DATA_SOURCE_ID" "$ds_id"
    kb_ok "${var_name}=${kb_id}"
}
