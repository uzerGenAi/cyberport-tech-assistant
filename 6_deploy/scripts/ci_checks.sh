#!/usr/bin/env bash
set -euo pipefail

# Works from a git checkout or a plain copy of the repo
ROOT_DIR="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "$0")/../.." && pwd; })"
cd "${ROOT_DIR}"

echo "Running CI validations"
# Bytecode goes to a temp dir (removed on exit) so the checks leave no __pycache__ in the repo
PYCACHE_DIR="$(mktemp -d)"
trap 'rm -rf "$PYCACHE_DIR"' EXIT
PYTHONPYCACHEPREFIX="$PYCACHE_DIR" python3 -m compileall -q \
    3_proof_of_concept 4_monitor_and_evaluate 2_data_strategy 6_deploy

echo "Validating Terraform files (EKS stack)"
(
    cd 6_deploy/infra/terraform
    terraform fmt -check -recursive
    terraform init -backend=false >/dev/null
    terraform validate >/dev/null
)

echo "Validating and testing Terraform files (AgentCore backends; mocked providers)"
(
    cd 6_deploy/infra/agentcore-backends
    terraform fmt -check -recursive
    terraform init -backend=false >/dev/null
    terraform validate >/dev/null
    terraform test >/dev/null
)

echo "CI checks passed"
