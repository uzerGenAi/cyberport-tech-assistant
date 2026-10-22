#!/usr/bin/env bash
# amplify-deploy.sh — Deploy Specialty Bakeries & Pastry Cafés web app to AWS Amplify Hosting
set -euo pipefail

REGION="${AWS_REGION:-eu-central-1}"
APP_NAME="spbc-pastry-cafe"
BRANCH="main"
ROOT_DIR="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "$0")/../.." && pwd; })"
WEB_APP_DIR="$ROOT_DIR/6_deploy/web-app"

log()  { echo -e "\033[0;34mℹ️  $1\033[0m"; }
ok()   { echo -e "\033[0;32m✅ $1\033[0m"; }
warn() { echo -e "\033[1;33m⚠️  $1\033[0m"; }
err()  { echo -e "\033[0;31m❌ $1\033[0m"; exit 1; }

log "Deploying Specialty Bakeries & Pastry Cafés frontend to AWS Amplify (region: $REGION)"

# Check for required tools
command -v aws  >/dev/null 2>&1 || err "aws CLI not found"
command -v zip  >/dev/null 2>&1 || err "zip not found"
command -v jq   >/dev/null 2>&1 || err "jq not found"

# Check cognito-config.json is populated
COGNITO_CONFIG="$WEB_APP_DIR/cognito-config.json"
if [ ! -s "$COGNITO_CONFIG" ]; then
  warn "cognito-config.json is empty — update with real Cognito UserPoolId and ClientId before use"
fi

# Resolve or create the Amplify app
log "Checking for existing Amplify app: $APP_NAME"
EXISTING_APP_ID=$(aws amplify list-apps \
  --region "$REGION" \
  --query "apps[?name=='$APP_NAME'].appId" \
  --output text 2>/dev/null || true)

if [ -z "$EXISTING_APP_ID" ] || [ "$EXISTING_APP_ID" = "None" ]; then
  log "Creating new Amplify app: $APP_NAME"
  APP_ID=$(aws amplify create-app \
    --name "$APP_NAME" \
    --region "$REGION" \
    --description "Specialty Bakeries & Pastry Cafés AI Concierge Web App" \
    --query 'app.appId' \
    --output text)
  ok "Created Amplify app: $APP_ID"
else
  APP_ID="$EXISTING_APP_ID"
  ok "Using existing Amplify app: $APP_ID"
fi

# Ensure the branch exists
BRANCH_EXISTS=$(aws amplify list-branches \
  --app-id "$APP_ID" \
  --region "$REGION" \
  --query "branches[?branchName=='$BRANCH'].branchName" \
  --output text 2>/dev/null || true)

if [ -z "$BRANCH_EXISTS" ] || [ "$BRANCH_EXISTS" = "None" ]; then
  log "Creating branch: $BRANCH"
  aws amplify create-branch \
    --app-id "$APP_ID" \
    --branch-name "$BRANCH" \
    --region "$REGION" \
    --stage PRODUCTION \
    > /dev/null
  ok "Branch '$BRANCH' created"
fi

# Package the web app
DEPLOY_ZIP="/tmp/spbc-webapp-$(date +%s).zip"
log "Packaging web app from $WEB_APP_DIR"
(cd "$WEB_APP_DIR" && zip -qr "$DEPLOY_ZIP" . --exclude '__pycache__/*' '*.pyc' '.DS_Store')
ok "Package created: $DEPLOY_ZIP"

# Create a deployment
log "Creating Amplify deployment"
DEPLOYMENT=$(aws amplify create-deployment \
  --app-id "$APP_ID" \
  --branch-name "$BRANCH" \
  --region "$REGION")

JOB_ID=$(echo "$DEPLOYMENT" | jq -r '.jobId')
UPLOAD_URL=$(echo "$DEPLOYMENT" | jq -r '.zipUploadUrl')

# Upload the zip
log "Uploading deployment package"
curl -s -X PUT \
  --header "Content-Type: application/zip" \
  --upload-file "$DEPLOY_ZIP" \
  "$UPLOAD_URL"
ok "Package uploaded"

# Start the deployment
log "Starting Amplify deployment (job: $JOB_ID)"
aws amplify start-deployment \
  --app-id "$APP_ID" \
  --branch-name "$BRANCH" \
  --job-id "$JOB_ID" \
  --region "$REGION" \
  > /dev/null

# Wait for deployment to complete
log "Waiting for deployment to complete..."
for i in $(seq 1 30); do
  STATUS=$(aws amplify get-job \
    --app-id "$APP_ID" \
    --branch-name "$BRANCH" \
    --job-id "$JOB_ID" \
    --region "$REGION" \
    --query 'job.summary.status' \
    --output text 2>/dev/null || echo "UNKNOWN")

  case "$STATUS" in
    SUCCEED)
      ok "Deployment succeeded!"
      break
      ;;
    FAILED|CANCELLED)
      err "Deployment failed with status: $STATUS"
      ;;
    *)
      log "Status: $STATUS (attempt $i/30) — waiting 15s..."
      sleep 15
      ;;
  esac

  if [ "$i" -eq 30 ]; then
    warn "Deployment still in progress after 7.5 minutes. Check the Amplify console."
  fi
done

# Get the domain
DOMAIN=$(aws amplify get-branch \
  --app-id "$APP_ID" \
  --branch-name "$BRANCH" \
  --region "$REGION" \
  --query 'branch.displayName' \
  --output text 2>/dev/null || echo "unknown")

APP_DOMAIN=$(aws amplify get-app \
  --app-id "$APP_ID" \
  --region "$REGION" \
  --query 'app.defaultDomain' \
  --output text 2>/dev/null || echo "")

rm -f "$DEPLOY_ZIP"

echo ""
echo -e "\033[0;36m============================================================\033[0m"
echo -e "\033[0;32m🥐 Specialty Bakeries & Pastry Cafés — Amplify Deployment\033[0m"
echo -e "\033[0;36m============================================================\033[0m"
echo -e "  Amplify App ID : $APP_ID"
echo -e "  Branch         : $BRANCH"
echo -e "  Region         : $REGION"
if [ -n "$APP_DOMAIN" ]; then
  echo -e "  \033[0;36m🌐 URL: https://${BRANCH}.${APP_DOMAIN}\033[0m"
fi
echo ""
echo -e "\033[1;33mNext steps:\033[0m"
echo -e "  1. Update cognito-config.json with your Cognito UserPoolId + ClientId"
echo -e "  2. Update agentcore-config.json with your Bedrock AgentCore endpoint"
echo -e "  3. Re-run this script to push the updated config"
echo -e "  4. Set a custom domain in the Amplify console if needed"
echo -e "\033[0;36m============================================================\033[0m"
