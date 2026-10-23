#!/usr/bin/env bash
set -euo pipefail
# build_webapp_image.sh — build and push the SPBC web-app container image on AWS CodeBuild.
#
# Replaces the inline `docker login/build/push` that used to run on the CI runner,
# so the deploy pipeline needs no local Docker. It:
#   - resolves ECR_REPOSITORY_URL (honoured if exported, else from terraform output) and IMAGE_TAG,
#   - ensures a CodeBuild service role (SPBC-WebAppCodeBuild-Role) — create if missing,
#   - ensures an S3 source bucket and the CodeBuild project (spbc-webapp-image) — create or update,
#   - zips 6_deploy/web-app (INCLUDING the generated *-config.json files + the Dockerfile) and
#     uploads it as the CodeBuild S3 source,
#   - starts the build with ECR_REPOSITORY_URL + IMAGE_TAG as env overrides, waits, and exits
#     non-zero if the build fails.
#
# Runs before deploy_blue_green.sh, whose interface (reads ECR_REPOSITORY_URL + IMAGE_TAG, expects
# the image already in ECR) is unchanged.
#
# Account-agnostic: region from $AWS_REGION (default eu-central-1), account from
# `aws sts get-caller-identity`. --region is passed explicitly on every AWS call.
#
# Environment:
#   AWS_REGION          region for ECR/CodeBuild/S3 (default eu-central-1)
#   ECR_REPOSITORY_URL  optional; resolved from terraform output when unset
#   IMAGE_TAG           optional; git short SHA, else a UTC timestamp when unset

set -euo pipefail

REGION="${AWS_REGION:-eu-central-1}"
ROLE_NAME="SPBC-WebAppCodeBuild-Role"
ROLE_POLICY_NAME="SPBC-WebAppCodeBuild-Permissions"
PROJECT_NAME="spbc-webapp-image"
LOG_GROUP="/aws/codebuild/${PROJECT_NAME}"
ROOT_DIR="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "$0")/../.." && pwd; })"
WEB_APP_DIR="$ROOT_DIR/6_deploy/web-app"

log()  { echo -e "\033[0;34mℹ️  $1\033[0m"; }
ok()   { echo -e "\033[0;32m✅ $1\033[0m"; }
warn() { echo -e "\033[1;33m⚠️  $1\033[0m"; }
err()  { echo -e "\033[0;31m❌ $1\033[0m"; exit 1; }

# ── Preconditions ─────────────────────────────────────────────────────────────
command -v aws >/dev/null 2>&1 || err "aws CLI not found"
command -v zip >/dev/null 2>&1 || err "zip not found"
command -v jq  >/dev/null 2>&1 || err "jq not found"
[ -d "$WEB_APP_DIR" ] || err "web-app directory not found: $WEB_APP_DIR"

log "Building the SPBC web-app image on CodeBuild (region: $REGION)"

ACCOUNT_ID=$(aws sts get-caller-identity --region "$REGION" --query Account --output text)
[ -n "$ACCOUNT_ID" ] && [ "$ACCOUNT_ID" != "None" ] || err "Could not resolve the AWS account id"

# ── Resolve ECR_REPOSITORY_URL ──────────────────────────────────────────────────
if [ -n "${ECR_REPOSITORY_URL:-}" ]; then
  ok "Using ECR_REPOSITORY_URL from the environment: $ECR_REPOSITORY_URL"
else
  log "Resolving ECR_REPOSITORY_URL from terraform output"
  terraform -chdir="$ROOT_DIR/6_deploy/infra/terraform" init -input=false >/dev/null \
    || err "terraform init failed (is the EKS/ECR stack present?)"
  ECR_REPOSITORY_URL=$(terraform -chdir="$ROOT_DIR/6_deploy/infra/terraform" output -raw ecr_repository_url) \
    || err "Could not read ecr_repository_url from terraform output"
  [ -n "$ECR_REPOSITORY_URL" ] || err "ecr_repository_url terraform output is empty"
  ok "Resolved ECR_REPOSITORY_URL: $ECR_REPOSITORY_URL"
fi

# Repository name derived from the URL rather than hardcoded (e.g. ".../pastrycafe-prod")
ECR_REPO_NAME="${ECR_REPOSITORY_URL##*/}"
[ -n "$ECR_REPO_NAME" ] || err "Could not derive the ECR repository name from $ECR_REPOSITORY_URL"
ECR_REPO_ARN="arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${ECR_REPO_NAME}"

# ── Resolve IMAGE_TAG (match deploy_blue_green.sh's fallback) ────────────────────
if [ -z "${IMAGE_TAG:-}" ]; then
  IMAGE_TAG="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
  [ -n "$IMAGE_TAG" ] || IMAGE_TAG="$(date -u +%Y%m%d%H%M%S)"
  log "IMAGE_TAG not set; using ${IMAGE_TAG}"
fi
ok "Image tag: $IMAGE_TAG"

SRC_BUCKET="spbc-webapp-codebuild-src-${ACCOUNT_ID}-${REGION}"

# ── Ensure the CodeBuild service role (create if missing) ────────────────────────
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
if aws iam get-role --role-name "$ROLE_NAME" --region "$REGION" >/dev/null 2>&1; then
  ok "Using existing CodeBuild service role: $ROLE_NAME"
  ROLE_CREATED=0
else
  log "Creating CodeBuild service role: $ROLE_NAME"
  TRUST_DOC=$(cat <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "codebuild.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON
)
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_DOC" \
    --description "Service role for the spbc-webapp-image CodeBuild project (web-app container build)" \
    --region "$REGION" >/dev/null
  ok "Created CodeBuild service role: $ROLE_NAME"
  ROLE_CREATED=1
fi

# Inline permissions (refreshed on every run via put-role-policy): ECR auth/push to the app repo,
# CloudWatch Logs for the build's log group, and S3 read on the source bucket.
PERMS_DOC=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EcrAuth",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "EcrPush",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer"
      ],
      "Resource": "${ECR_REPO_ARN}"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": [
        "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP}",
        "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP}:*"
      ]
    },
    {
      "Sid": "S3SourceRead",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion"
      ],
      "Resource": "arn:aws:s3:::${SRC_BUCKET}/*"
    }
  ]
}
JSON
)
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$ROLE_POLICY_NAME" \
  --policy-document "$PERMS_DOC" \
  --region "$REGION" >/dev/null
ok "CodeBuild service-role permissions in place"

if [ "$ROLE_CREATED" = "1" ]; then
  log "Waiting for IAM role propagation"
  sleep 15
fi

# ── Ensure the S3 source bucket (create if missing; SSE + versioning on) ─────────
if aws s3api head-bucket --bucket "$SRC_BUCKET" --region "$REGION" >/dev/null 2>&1; then
  ok "Using existing source bucket: $SRC_BUCKET"
else
  log "Creating source bucket: $SRC_BUCKET"
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$SRC_BUCKET" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$SRC_BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
  fi
  aws s3api put-bucket-encryption --bucket "$SRC_BUCKET" --region "$REGION" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null
  aws s3api put-bucket-versioning --bucket "$SRC_BUCKET" --region "$REGION" \
    --versioning-configuration Status=Enabled >/dev/null
  ok "Created source bucket: $SRC_BUCKET"
fi

# Bound growth: expire source zips (and noncurrent versions) under sources/ after a short
# retention window. Applied idempotently so pre-existing buckets also get the rule.
log "Ensuring the source-bucket lifecycle rule (expire sources/ after 14 days)"
aws s3api put-bucket-lifecycle-configuration --bucket "$SRC_BUCKET" --region "$REGION" \
  --lifecycle-configuration '{
    "Rules": [
      {
        "ID": "expire-codebuild-sources",
        "Status": "Enabled",
        "Filter": { "Prefix": "sources/" },
        "Expiration": { "Days": 14 },
        "NoncurrentVersionExpiration": { "NoncurrentDays": 7 },
        "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 1 }
      }
    ]
  }' >/dev/null
ok "Source-bucket lifecycle rule in place"

# ── Package the build context ────────────────────────────────────────────────────
# Keep html/css/js, image.jpg, the Dockerfile and the three *-config.json files; drop local
# backup folders, python/build tooling and helper shell scripts (not needed by the Dockerfile).
TS="$(date -u +%Y%m%d%H%M%S)"
SRC_ZIP="/tmp/spbc-webapp-src-${TS}.zip"
log "Packaging build context from $WEB_APP_DIR"
(cd "$WEB_APP_DIR" && zip -qr "$SRC_ZIP" . \
  -x '__pycache__/*' \
  -x '*.pyc' \
  -x '.DS_Store' \
  -x 'backup_*/*' \
  -x '*.sh' \
  -x '*.py')
ok "Package created: $SRC_ZIP"

# Fail fast if the generated config files or the Dockerfile are missing from the zip
ZIP_LIST="$(unzip -Z1 "$SRC_ZIP")"
for required in Dockerfile buildspec.yml cognito-config.json agentcore-config.json observability-config.json; do
  echo "$ZIP_LIST" | grep -qx "$required" \
    || err "Required file '$required' is missing from the build context zip"
done
ok "Build context includes the Dockerfile, buildspec and the three *-config.json files"

SRC_KEY="sources/spbc-webapp-${IMAGE_TAG}-${TS}.zip"
log "Uploading build context to s3://${SRC_BUCKET}/${SRC_KEY}"
aws s3 cp "$SRC_ZIP" "s3://${SRC_BUCKET}/${SRC_KEY}" --region "$REGION" >/dev/null
ok "Build context uploaded"
rm -f "$SRC_ZIP"

# ── Ensure the CodeBuild project (create or update) ──────────────────────────────
SOURCE_JSON=$(jq -n \
  --arg loc "${SRC_BUCKET}/${SRC_KEY}" \
  '{type:"S3", location:$loc, buildspec:"buildspec.yml"}')
ENV_JSON=$(jq -n \
  '{type:"LINUX_CONTAINER", image:"aws/codebuild/amazonlinux2-x86_64-standard:5.0", computeType:"BUILD_GENERAL1_SMALL", privilegedMode:true}')
ARTIFACTS_JSON='{"type":"NO_ARTIFACTS"}'
LOGS_JSON=$(jq -n \
  --arg grp "$LOG_GROUP" \
  '{cloudWatchLogs:{status:"ENABLED", groupName:$grp}}')

if aws codebuild batch-get-projects --names "$PROJECT_NAME" --region "$REGION" \
    --query 'projects[0].name' --output text 2>/dev/null | grep -qx "$PROJECT_NAME"; then
  log "Updating CodeBuild project: $PROJECT_NAME"
  aws codebuild update-project \
    --name "$PROJECT_NAME" \
    --source "$SOURCE_JSON" \
    --artifacts "$ARTIFACTS_JSON" \
    --environment "$ENV_JSON" \
    --service-role "$ROLE_ARN" \
    --logs-config "$LOGS_JSON" \
    --region "$REGION" >/dev/null
  ok "Updated CodeBuild project: $PROJECT_NAME"
else
  log "Creating CodeBuild project: $PROJECT_NAME"
  aws codebuild create-project \
    --name "$PROJECT_NAME" \
    --description "Builds and pushes the SPBC web-app container image to ECR (Docker-free CI)" \
    --source "$SOURCE_JSON" \
    --artifacts "$ARTIFACTS_JSON" \
    --environment "$ENV_JSON" \
    --service-role "$ROLE_ARN" \
    --logs-config "$LOGS_JSON" \
    --region "$REGION" >/dev/null
  ok "Created CodeBuild project: $PROJECT_NAME"
fi

# ── Start the build and wait ─────────────────────────────────────────────────────
log "Starting the CodeBuild build"
BUILD_ID=$(aws codebuild start-build \
  --project-name "$PROJECT_NAME" \
  --source-location-override "${SRC_BUCKET}/${SRC_KEY}" \
  --source-type-override S3 \
  --environment-variables-override \
    "name=AWS_REGION,value=${REGION},type=PLAINTEXT" \
    "name=ECR_REPOSITORY_URL,value=${ECR_REPOSITORY_URL},type=PLAINTEXT" \
    "name=IMAGE_TAG,value=${IMAGE_TAG},type=PLAINTEXT" \
  --region "$REGION" \
  --query 'build.id' --output text)
[ -n "$BUILD_ID" ] && [ "$BUILD_ID" != "None" ] || err "Could not start the CodeBuild build"
ok "Started build: $BUILD_ID"

log "Waiting for the build to finish (polling every 10s)"
while true; do
  STATUS=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region "$REGION" \
    --query 'builds[0].buildStatus' --output text 2>/dev/null || echo "UNKNOWN")
  case "$STATUS" in
    SUCCEEDED)
      ok "CodeBuild build succeeded: ${ECR_REPOSITORY_URL}:${IMAGE_TAG}"
      break
      ;;
    FAILED|FAULT|STOPPED|TIMED_OUT)
      PHASE=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region "$REGION" \
        --query 'builds[0].currentPhase' --output text 2>/dev/null || echo "UNKNOWN")
      warn "Build $BUILD_ID ended in $STATUS during phase $PHASE"
      warn "Logs: CloudWatch group ${LOG_GROUP} (build id ${BUILD_ID##*:})"
      err "CodeBuild build failed"
      ;;
    *)
      log "Build status: $STATUS — waiting 10s..."
      sleep 10
      ;;
  esac
done

ok "Web-app image is in ECR: ${ECR_REPOSITORY_URL}:${IMAGE_TAG}"
