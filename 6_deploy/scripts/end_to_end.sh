#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "$0")/../.." && pwd; })"
TERRAFORM_DIR="$ROOT_DIR/6_deploy/infra/terraform"
SCRIPTS_DIR="$ROOT_DIR/6_deploy/scripts"

usage() {
  echo "Usage: $0 [--infra-only|--deploy-only]"
}

INFRA_ONLY=false
DEPLOY_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --infra-only)
      INFRA_ONLY=true
      shift
      ;;
    --deploy-only)
      DEPLOY_ONLY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$INFRA_ONLY" == true && "$DEPLOY_ONLY" == true ]]; then
  echo "Choose either --infra-only or --deploy-only" >&2
  exit 1
fi

if [[ "$INFRA_ONLY" == false && "$DEPLOY_ONLY" == false ]]; then
  INFRA_ONLY=true
  DEPLOY_ONLY=true
fi

if [[ "$INFRA_ONLY" == true ]]; then
  echo "Provisioning Terraform infrastructure"
  cd "$TERRAFORM_DIR"

  # terraform.tfvars is the real configuration (terraform_backend_setup.sh writes it, including
  # eks_public_access_cidrs, which has no default). It is auto-loaded by Terraform, so it must
  # not be passed with -var-file: an earlier version passed terraform.tfvars.example instead,
  # which silently overrode the real values with the committed sample.
  if [[ ! -f terraform.tfvars ]]; then
    echo "terraform.tfvars not found in $TERRAFORM_DIR" >&2
    echo "Run first: bash 6_deploy/scripts/terraform_backend_setup.sh --cidr <YOUR_CIDR>" >&2
    echo "(it writes terraform.tfvars, including the required eks_public_access_cidrs)" >&2
    exit 1
  fi

  # -input=false so a missing variable fails immediately instead of waiting on stdin
  terraform init -input=false
  terraform apply -auto-approve -input=false
fi

if [[ "$DEPLOY_ONLY" == true ]]; then
  echo "Building and deploying application"
  # Fall back to the Terraform output rather than deploying to a placeholder registry
  if [[ -z "${ECR_REPOSITORY_URL:-}" ]]; then
    ECR_REPOSITORY_URL="$(terraform -chdir="$TERRAFORM_DIR" output -raw ecr_repository_url 2>/dev/null || true)"
  fi
  if [[ -z "$ECR_REPOSITORY_URL" ]]; then
    echo "ECR_REPOSITORY_URL is not set and could not be read from the Terraform state" >&2
    echo "Set it explicitly, or run 'make provision' first:" >&2
    echo "  export ECR_REPOSITORY_URL=\$(terraform -chdir=6_deploy/infra/terraform output -raw ecr_repository_url)" >&2
    exit 1
  fi
  export ECR_REPOSITORY_URL
  # IMAGE_TAG is passed through when set; otherwise deploy_blue_green.sh derives an immutable
  # one (git SHA, else a timestamp). It no longer defaults to "latest", which left nothing
  # distinct to roll back to.
  [ -n "${IMAGE_TAG:-}" ] && export IMAGE_TAG
  bash "$SCRIPTS_DIR/deploy_blue_green.sh"
  if [ -n "${SMOKE_TEST_URL:-}" ]; then
    bash "$SCRIPTS_DIR/smoke_test.sh"
  else
    echo "SMOKE_TEST_URL is not set; skipping the frontend smoke test." >&2
    echo "Run it once the load balancer has an address:" >&2
    echo "  SMOKE_TEST_URL=http://\$(kubectl -n spbc-bakery get svc spbc-bakery-web-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}') make smoke" >&2
  fi
fi
