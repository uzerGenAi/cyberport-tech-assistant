#!/bin/bash
# orders_knowledge_base_setup.sh — the orders knowledge base (spbc-orders-knowledge-base).
#
# The agent runtime refuses to start without ORDERS_KNOWLEDGE_BASE_ID, and
# deploy_agentcore.sh counts orders among its required domains, but this domain had no
# setup script — the only way to create it was by hand in the console.
#
# Usage:
#   bash 3_proof_of_concept/knowledge_bases/bootstrap_vector_store.sh   # once per account
#   bash 3_proof_of_concept/knowledge_bases/orders_knowledge_base_setup.sh
#
# Creates the electronics_orders_index vector index, the knowledge base, its S3 data source
# (prefix electronics_orders/, holding orders_policies_kb_faqs.txt), then syncs and verifies it.
# Safe to re-run: anything that already exists is reused.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./kb_common.sh
. "${SCRIPT_DIR}/kb_common.sh"

# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

kb_need aws jq awscurl
ensure_knowledge_base orders
