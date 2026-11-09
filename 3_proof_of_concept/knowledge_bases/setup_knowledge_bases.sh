#!/bin/bash
# setup_knowledge_bases.sh — create, sync and verify every SPBC knowledge base.
#
# Usage:
#   bash 3_proof_of_concept/knowledge_bases/setup_knowledge_bases.sh            # all five domains
#   bash 3_proof_of_concept/knowledge_bases/setup_knowledge_bases.sh orders     # one domain
#
# Prerequisites:
#   1. bash 3_proof_of_concept/knowledge_bases/bootstrap_vector_store.sh   (collection + role)
#   2. The documents are in S3 under electronics_<domain>/   (walkthrough Step 3)
#
# Idempotent: existing indexes, knowledge bases and data sources are reused, and each sync
# is verified (a job that scans zero documents or fails any document stops the run). This
# is the unattended entry point; the four single-domain *_knowledge_base_setup.sh scripts
# remain for following the lab by hand.
#
# Requires: aws CLI, jq, awscurl  (pip install awscurl — the venv setup in DEPLOY.md installs it)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./kb_common.sh
. "${SCRIPT_DIR}/kb_common.sh"

# Pick up what bootstrap_vector_store.sh and setup_env.sh recorded
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

kb_need aws jq awscurl

DOMAINS="${*:-$KB_DOMAINS_ALL}"
for domain in $DOMAINS; do
    case " $KB_DOMAINS_ALL " in
        *" $domain "*) ;;
        *) kb_die "Unknown domain '${domain}'. Valid domains: ${KB_DOMAINS_ALL}" ;;
    esac
done

missing=""
for var in AOSSENDPOINT OPENSEARCH_COLLECTION_ARN ROLE_ARN OPENSEARCH_S3_BUCKET_ARN; do
    eval "value=\${$var:-}"
    [ -n "$value" ] || missing="${missing} ${var}"
done
if [ -n "$missing" ]; then
    kb_die "Missing:${missing}
   Run first: bash ${SCRIPT_DIR}/bootstrap_vector_store.sh
   (then 'source setup_env.sh' if the bucket was created afterwards)"
fi

kb_log "Region:     ${REGION}"
kb_log "Collection: ${OPENSEARCH_COLLECTION_ARN##*/}"
kb_log "Documents:  ${OPENSEARCH_S3_BUCKET_ARN#arn:aws:s3:::}"
kb_log "Domains:    ${DOMAINS}"
echo ""

for domain in $DOMAINS; do
    ensure_knowledge_base "$domain"
    echo ""
done

echo "=========================================="
kb_ok "Knowledge bases ready"
for domain in $DOMAINS; do
    var_name=$(kb_env_var_name "$domain")
    eval "value=\${$var_name:-}"
    printf '  %-32s %s\n' "$var_name" "$value"
done
echo "=========================================="
kb_log "Recorded in ${ENV_FILE}; load them with: source ${ENV_FILE}"
