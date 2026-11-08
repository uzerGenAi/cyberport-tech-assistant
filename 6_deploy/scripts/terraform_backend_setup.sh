#!/usr/bin/env bash
# terraform_backend_setup.sh
# Creates the S3 bucket that holds the Terraform state of the agentcore-backends and
# codepipeline stacks. Run it once, before the first `terraform init`.
#
# Both stacks lock their state with an S3 lock file (use_lockfile), so the bucket is all that
# has to exist: there is no DynamoDB lock table.
#
# Usage:
#   bash 6_deploy/scripts/terraform_backend_setup.sh
#
# Override the bucket name with TF_STATE_BUCKET (bucket names are global, so use this when
# another account already owns the default). agentcore_backends.sh passes the override to
# `terraform init`; for the codepipeline stack pass -backend-config="bucket=<name>".
#
# The script is idempotent and never prompts, so it is safe to run from a pipeline.

set -euo pipefail

REGION="${AWS_REGION:-eu-central-1}"
# shellcheck source=state_bucket.sh
source "$(dirname "${BASH_SOURCE[0]}")/state_bucket.sh" || exit 1
BUCKET="$STATE_BUCKET"

log()  { echo -e "\033[0;34mℹ️  $1\033[0m"; }
ok()   { echo -e "\033[0;32m✅ $1\033[0m"; }
err()  { echo -e "\033[0;31m❌ $1\033[0m"; exit 1; }

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) err "Unknown argument: $1 (this script takes none; see --help)" ;;
esac

log "Checking Terraform state bucket: s3://$BUCKET"
if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  ok "State bucket already exists: $BUCKET"
else
  log "Creating state bucket: $BUCKET"
  create_err=$(aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" 2>&1) \
    || err "Could not create s3://$BUCKET: ${create_err}
   Bucket names are global. If the name is taken, choose another: export TF_STATE_BUCKET=<unique-name>"
  aws s3api put-bucket-versioning \
    --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  ok "State bucket created: $BUCKET"
fi

echo ""
echo -e "\033[0;36m══════════════════════════════════════════════════════\033[0m"
echo -e "\033[0;32m📱 Terraform backend ready — Cyberport Tech Assistant\033[0m"
echo -e "\033[0;36m══════════════════════════════════════════════════════\033[0m"
echo -e "  State bucket : s3://$BUCKET ($REGION)"
echo ""
echo -e "\033[1;33mNext:\033[0m  make backends"
echo -e "\033[0;36m══════════════════════════════════════════════════════\033[0m"
