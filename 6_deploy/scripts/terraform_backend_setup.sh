#!/usr/bin/env bash
set -euo pipefail
# terraform_backend_setup.sh
# Creates the S3 state bucket + DynamoDB lock table for the Terraform remote backend and
# writes terraform.tfvars, so eks_public_access_cidrs names specific CIDRs, never 0.0.0.0/0.
#
# Usage:
#   bash 6_deploy/scripts/terraform_backend_setup.sh                      # detect this machine's IP
#   bash 6_deploy/scripts/terraform_backend_setup.sh --cidr 203.0.113.10/32
#   EKS_PUBLIC_ACCESS_CIDRS="203.0.113.10/32,198.51.100.0/24" bash 6_deploy/scripts/terraform_backend_setup.sh
#
# Options:
#   --cidr CIDR         CIDR allowed to reach the EKS API. Repeatable. Skips IP detection.
#                       Unattended runs should always use this (or EKS_PUBLIC_ACCESS_CIDRS):
#                       a build agent's address changes between runs.
#   --extra-cidr CIDR   Additional CIDR to allow, on top of the above. Repeatable.
#   --no-detect         Never make the outbound IP lookup; fail if no CIDR was supplied.
#   --allow-open        Permit 0.0.0.0/0. Refused otherwise, including as a fallback.
#   -h, --help          Show this help
#
# Override the state bucket/table names with TF_STATE_BUCKET / TF_LOCK_TABLE.

set -euo pipefail

REGION="${AWS_REGION:-eu-central-1}"
# Bucket names are global; override when another account already owns this one (the EKS stack's
# versions.tf names this bucket, the agentcore-backends stack accepts the override)
BUCKET="${TF_STATE_BUCKET:-spbc-tfstate-eu-central-1}"
LOCK_TABLE="${TF_LOCK_TABLE:-spbc-tfstate-lock}"
ROOT_DIR="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "$0")/../.." && pwd; })"
TF_DIR="$ROOT_DIR/6_deploy/infra/terraform"
TFVARS="$TF_DIR/terraform.tfvars"

log()  { echo -e "\033[0;34mℹ️  $1\033[0m"; }
ok()   { echo -e "\033[0;32m✅ $1\033[0m"; }
warn() { echo -e "\033[1;33m⚠️  $1\033[0m"; }
err()  { echo -e "\033[0;31m❌ $1\033[0m"; exit 1; }

# ── Parse CIDR arguments ──────────────────────────────────────────────────────
CLI_CIDRS=()
EXTRA_CIDRS=()
NO_DETECT=false
ALLOW_OPEN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cidr)
      [[ -n "${2:-}" ]] || err "--cidr needs a value"
      CLI_CIDRS+=("$2")
      shift 2
      ;;
    --extra-cidr)
      [[ -n "${2:-}" ]] || err "--extra-cidr needs a value"
      EXTRA_CIDRS+=("$2")
      shift 2
      ;;
    --no-detect)
      NO_DETECT=true
      shift
      ;;
    --allow-open)
      ALLOW_OPEN=true
      shift
      ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      ;;
  esac
done

# ── Step 1: S3 bucket ─────────────────────────────────────────────────────────
log "Checking Terraform state bucket: s3://$BUCKET"
if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  ok "State bucket already exists: $BUCKET"
else
  log "Creating state bucket: $BUCKET"
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"
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

# ── Step 2: DynamoDB lock table ───────────────────────────────────────────────
log "Checking Terraform lock table: $LOCK_TABLE"
if aws dynamodb describe-table --table-name "$LOCK_TABLE" --region "$REGION" >/dev/null 2>&1; then
  ok "Lock table already exists: $LOCK_TABLE"
else
  log "Creating lock table: $LOCK_TABLE"
  aws dynamodb create-table \
    --table-name "$LOCK_TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" >/dev/null
  aws dynamodb wait table-exists --table-name "$LOCK_TABLE" --region "$REGION"
  ok "Lock table created: $LOCK_TABLE"
fi

# ── Step 3: Resolve the EKS API allowlist ─────────────────────────────────────
# Explicit CIDRs win and skip the network call entirely. Auto-detection stays as the
# convenience path for a human running this on a laptop, but it is never a silent
# fallback: if it fails, the script stops rather than opening the API to 0.0.0.0/0.

ALL_CIDRS=()

add_cidr() {
  local cidr="$1"
  if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    err "Not a valid IPv4 CIDR: '$cidr' (expected a.b.c.d/nn, e.g. 203.0.113.10/32)"
  fi
  if [[ "$cidr" == "0.0.0.0/0" && "$ALLOW_OPEN" != true ]]; then
    err "Refusing 0.0.0.0/0 for the EKS API. Pass a specific CIDR, or --allow-open to accept the risk."
  fi
  ALL_CIDRS+=("\"$cidr\"")
}

# EKS_PUBLIC_ACCESS_CIDRS accepts a comma- or space-separated list (handy in a pipeline)
if [[ ${#CLI_CIDRS[@]} -eq 0 && -n "${EKS_PUBLIC_ACCESS_CIDRS:-}" ]]; then
  # shellcheck disable=SC2206  # deliberate word splitting of the operator-supplied list
  CLI_CIDRS=(${EKS_PUBLIC_ACCESS_CIDRS//,/ })
fi

if [[ ${#CLI_CIDRS[@]} -gt 0 ]]; then
  for c in "${CLI_CIDRS[@]}"; do add_cidr "$c"; done
  ok "Using the supplied EKS API CIDRs (no IP detection)"
elif [[ "$NO_DETECT" == true ]]; then
  err "No CIDR supplied and IP detection is disabled.
   Pass --cidr <a.b.c.d/nn> (repeatable) or set EKS_PUBLIC_ACCESS_CIDRS."
else
  log "No CIDR supplied; detecting this machine's outbound public IP..."
  MY_IP=""
  for endpoint in \
      "https://checkip.amazonaws.com" \
      "https://api4.my-ip.io/ip" \
      "https://ipv4.icanhazip.com"; do
    MY_IP=$(curl -fsSL --connect-timeout 5 "$endpoint" 2>/dev/null | tr -d '[:space:]') || true
    if [[ "$MY_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      ok "Detected outbound IP: $MY_IP (from $endpoint)"
      break
    fi
    MY_IP=""
  done
  if [[ -z "$MY_IP" ]]; then
    err "Could not detect this machine's outbound IP, and guessing would mean opening the
   EKS API to the internet. Supply the allowlist explicitly instead:
     bash 6_deploy/scripts/terraform_backend_setup.sh --cidr <a.b.c.d/nn>"
  fi
  add_cidr "${MY_IP}/32"
  if [[ ! -t 1 ]]; then
    warn "Detected IP used in a non-interactive run. A build agent's address usually changes"
    warn "between runs, which churns the EKS allowlist — prefer --cidr or EKS_PUBLIC_ACCESS_CIDRS."
  fi
fi

if [[ ${#EXTRA_CIDRS[@]} -gt 0 ]]; then
  for c in "${EXTRA_CIDRS[@]}"; do add_cidr "$c"; done
fi

CIDR_LIST=$(IFS=', '; echo "${ALL_CIDRS[*]}")
[[ -n "$CIDR_LIST" ]] || err "No CIDRs resolved for eks_public_access_cidrs"

# ── Step 5: Write terraform.tfvars ────────────────────────────────────────────
log "Writing $TFVARS"

# Source the example file as the base if tfvars does not yet exist
if [[ ! -f "$TFVARS" ]]; then
  # Strip comment lines and the TODO placeholder from the example
  grep -v '^#' "$TF_DIR/terraform.tfvars.example" | grep -v 'TODO' > "$TFVARS"
  log "Created terraform.tfvars from example"
fi

# Remove any existing eks_public_access_cidrs line(s) and rewrite
TMP=$(mktemp)
grep -v '^eks_public_access_cidrs' "$TFVARS" > "$TMP" || true
cat "$TMP" > "$TFVARS"
rm -f "$TMP"

# Append the resolved value
echo "" >> "$TFVARS"
echo "# Auto-generated by terraform_backend_setup.sh — do not commit to version control" >> "$TFVARS"
echo "eks_public_access_cidrs = [$CIDR_LIST]" >> "$TFVARS"

ok "eks_public_access_cidrs = [$CIDR_LIST]"
ok "Written to: $TFVARS"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "\033[0;36m══════════════════════════════════════════════════════\033[0m"
echo -e "\033[0;32m🥐 Terraform backend ready — Specialty Bakeries & Pastry Cafés\033[0m"
echo -e "\033[0;36m══════════════════════════════════════════════════════\033[0m"
echo -e "  State bucket  : s3://$BUCKET ($REGION)"
echo -e "  Lock table    : $LOCK_TABLE"
echo -e "  EKS API CIDRs : [$CIDR_LIST]"
echo ""
echo -e "\033[1;33mNext:\033[0m  make provision"
echo ""
warn "Add your CI/CD runner's outbound IP with --extra-cidr if it differs from this machine."
warn "Do NOT commit terraform.tfvars — it contains your IP address."
echo -e "\033[0;36m══════════════════════════════════════════════════════\033[0m"
