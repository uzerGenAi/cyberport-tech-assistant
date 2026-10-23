#!/usr/bin/env bash
set -euo pipefail
# deploy_blue_green.sh — blue/green rollout of the web app onto EKS.
#
# Usage:
#   ECR_REPOSITORY_URL=<acct>.dkr.ecr.eu-central-1.amazonaws.com/pastrycafe-prod \
#   IMAGE_TAG=<immutable-tag> bash 6_deploy/scripts/deploy_blue_green.sh
#
# How it works: the production Service selects one colour at a time. This deploys the image to
# whichever colour is *not* live, waits for it to be healthy, and only then moves the Service.
# The previously live colour is left running so rollback.sh can switch straight back to it.
#
# Earlier versions always deployed "blue" and always switched to "blue", so no green deployment
# ever existed — which made rollback.sh (it selects green) an outage rather than a rollback.
# They also patched a Service that nothing created, and defaulted the tag to "latest", leaving
# no distinct image to roll back to.
#
# Environment:
#   ECR_REPOSITORY_URL  required; the image repository
#   IMAGE_TAG           image tag. Defaults to the git commit, else a UTC timestamp.
#                       "latest" is refused unless ALLOW_MUTABLE_TAG=1, because a mutable tag
#                       makes rollback meaningless.
#   REPLICAS            pods per colour (default 2)
#   ROLLOUT_TIMEOUT     seconds to wait for the new colour (default 600)

set -euo pipefail

APP_NAME="spbc-bakery"
NAMESPACE="spbc-bakery"
SERVICE_NAME="spbc-bakery-web-svc"
REPLICAS="${REPLICAS:-2}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-600}"
ROOT_DIR="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "$0")/../.." && pwd; })"

log()  { echo -e "\033[0;34mℹ️  $*\033[0m"; }
ok()   { echo -e "\033[0;32m✅ $*\033[0m"; }
warn() { echo -e "\033[1;33m⚠️  $*\033[0m" >&2; }
die()  { echo -e "\033[0;31m❌ $*\033[0m" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "kubectl is required"

IMAGE_REPOSITORY="${ECR_REPOSITORY_URL:-}"
[ -n "$IMAGE_REPOSITORY" ] || die "ECR_REPOSITORY_URL is not set.
   export ECR_REPOSITORY_URL=\$(terraform -chdir=6_deploy/infra/terraform output -raw ecr_repository_url)"

# An immutable tag is what makes a rollback target exist at all
if [ -z "${IMAGE_TAG:-}" ]; then
    IMAGE_TAG="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
    [ -n "$IMAGE_TAG" ] || IMAGE_TAG="$(date -u +%Y%m%d%H%M%S)"
    log "IMAGE_TAG not set; using ${IMAGE_TAG}"
fi
if [ "$IMAGE_TAG" = "latest" ] && [ "${ALLOW_MUTABLE_TAG:-0}" != "1" ]; then
    die "IMAGE_TAG=latest cannot be rolled back to a known-good image.
   Use a per-build tag (git SHA or timestamp), or set ALLOW_MUTABLE_TAG=1 to accept it."
fi
FULL_IMAGE="${IMAGE_REPOSITORY}:${IMAGE_TAG}"

kubectl apply -f "${ROOT_DIR}/6_deploy/k8s/namespace.yaml"

# ── Which colour is live? ─────────────────────────────────────────────────────
live_colour=$(kubectl get service "$SERVICE_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.spec.selector.version}' 2>/dev/null || true)
case "$live_colour" in
    blue)  target_colour=green ;;
    green) target_colour=blue ;;
    *)     target_colour=blue
           [ -n "$live_colour" ] && warn "Unrecognised live colour '${live_colour}'; deploying blue" ;;
esac
if [ -n "$live_colour" ]; then
    log "Live colour: ${live_colour} → deploying to ${target_colour}"
else
    log "No live colour yet (first deployment) → deploying to ${target_colour}"
fi

live_image=$(kubectl get deployment "${APP_NAME}-${live_colour:-none}" -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)

# ── Deploy the idle colour ────────────────────────────────────────────────────
log "Deploying ${FULL_IMAGE} to ${target_colour}"
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}-${target_colour}
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
    version: ${target_colour}
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app: ${APP_NAME}
      version: ${target_colour}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        app: ${APP_NAME}
        version: ${target_colour}
    spec:
      containers:
        - name: web
          image: ${FULL_IMAGE}
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 15
            periodSeconds: 20
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi
EOF

if ! kubectl rollout status "deployment/${APP_NAME}-${target_colour}" -n "$NAMESPACE" \
    --timeout="${ROLLOUT_TIMEOUT}s"; then
    warn "${target_colour} did not become healthy; production traffic was NOT moved."
    warn "Inspect it with: kubectl -n ${NAMESPACE} describe deployment ${APP_NAME}-${target_colour}"
    die "Deployment aborted (the live colour is untouched)"
fi
ok "${target_colour} is healthy (${FULL_IMAGE})"

# ── Create or re-point the production Service ─────────────────────────────────
# The Service has to exist before it can be patched; deployment.yaml defines one but no script
# applied it, so the old patch always failed.
if ! kubectl get service "$SERVICE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    log "Creating service ${SERVICE_NAME}"
    kubectl apply -f "${ROOT_DIR}/6_deploy/k8s/service.yaml"
fi
log "Pointing ${SERVICE_NAME} at ${target_colour}"
kubectl patch service "$SERVICE_NAME" -n "$NAMESPACE" --type=merge \
    -p "{\"spec\":{\"selector\":{\"app\":\"${APP_NAME}\",\"version\":\"${target_colour}\"}}}"

# Record where to go back to, so rollback is deterministic instead of assuming a colour
kubectl annotate service "$SERVICE_NAME" -n "$NAMESPACE" --overwrite \
    "spbc.io/previous-colour=${live_colour:-none}" \
    "spbc.io/previous-image=${live_image:-none}" \
    "spbc.io/current-colour=${target_colour}" \
    "spbc.io/current-image=${FULL_IMAGE}" \
    "spbc.io/deployed-at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null

ok "Blue/green deployment complete — ${target_colour} is live"
echo ""
log "Image:    ${FULL_IMAGE}"
if [ -n "$live_colour" ] && [ "$live_colour" != "none" ]; then
    log "Previous: ${live_colour} (${live_image:-unknown}) still running for rollback"
    log "Roll back with: make rollback"
else
    warn "No previous colour exists yet, so there is nothing to roll back to until the next deploy."
fi
