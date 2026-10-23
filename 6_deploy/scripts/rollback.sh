#!/usr/bin/env bash
set -euo pipefail
# rollback.sh — send production traffic back to the previously live colour.
#
# Usage:
#   bash 6_deploy/scripts/rollback.sh            # back to the recorded previous colour
#   bash 6_deploy/scripts/rollback.sh --to blue  # back to a specific colour
#   bash 6_deploy/scripts/rollback.sh --status   # show what is live and what it would roll back to
#
# The previous colour and image are recorded as annotations on the Service by
# deploy_blue_green.sh. This reads them, confirms the target deployment actually has healthy
# pods, and only then moves the Service.
#
# The earlier version unconditionally patched the selector to "version: green". Nothing ever
# created a green deployment, so that selected zero pods: it caused an outage instead of
# undoing a bad release. It also failed outright when the Service did not exist.

set -euo pipefail

APP_NAME="spbc-bakery"
NAMESPACE="spbc-bakery"
SERVICE_NAME="spbc-bakery-web-svc"

log()  { echo -e "\033[0;34mℹ️  $*\033[0m"; }
ok()   { echo -e "\033[0;32m✅ $*\033[0m"; }
warn() { echo -e "\033[1;33m⚠️  $*\033[0m" >&2; }
die()  { echo -e "\033[0;31m❌ $*\033[0m" >&2; exit 1; }

TARGET=""
STATUS_ONLY=false
while [ $# -gt 0 ]; do
    case "$1" in
        --to)     TARGET="${2:-}"; [ -n "$TARGET" ] || die "--to needs blue or green"; shift 2 ;;
        --status) STATUS_ONLY=true; shift ;;
        -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)        die "Unknown argument: $1" ;;
    esac
done

command -v kubectl >/dev/null 2>&1 || die "kubectl is required"

kubectl get service "$SERVICE_NAME" -n "$NAMESPACE" >/dev/null 2>&1 \
    || die "Service ${SERVICE_NAME} not found in namespace ${NAMESPACE}.
   Nothing is deployed, so there is nothing to roll back. Deploy first: make deploy"

annotation() {
    kubectl get service "$SERVICE_NAME" -n "$NAMESPACE" \
        -o "jsonpath={.metadata.annotations.spbc\\.io/$1}" 2>/dev/null || true
}

live_colour=$(kubectl get service "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.selector.version}' 2>/dev/null || true)
previous_colour=$(annotation previous-colour)
previous_image=$(annotation previous-image)
current_image=$(annotation current-image)

ready_replicas() {   # ready_replicas <colour>
    local count
    count=$(kubectl get deployment "${APP_NAME}-$1" -n "$NAMESPACE" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    echo "${count:-0}"
}

if [ "$STATUS_ONLY" = true ]; then
    echo "Live colour      : ${live_colour:-unknown}  (${current_image:-unknown})"
    echo "Rollback target  : ${previous_colour:-none}  (${previous_image:-none})"
    for colour in blue green; do
        echo "  ${APP_NAME}-${colour}: $(ready_replicas "$colour") ready replica(s)"
    done
    exit 0
fi

# Resolve the target
if [ -z "$TARGET" ]; then
    TARGET="$previous_colour"
    if [ -z "$TARGET" ] || [ "$TARGET" = "none" ]; then
        die "No previous colour recorded on ${SERVICE_NAME}.
   This is the first deployment, so there is no earlier version to return to.
   Check what exists with: bash 6_deploy/scripts/rollback.sh --status
   Or name a colour explicitly: bash 6_deploy/scripts/rollback.sh --to blue"
    fi
fi
case "$TARGET" in
    blue|green) ;;
    *) die "Rollback target must be blue or green (got '${TARGET}')" ;;
esac

if [ "$TARGET" = "$live_colour" ]; then
    warn "${TARGET} is already live; nothing to do."
    exit 0
fi

# The crucial check the old script lacked: never point the Service at a colour with no pods
ready=$(ready_replicas "$TARGET")
if [ "$ready" -lt 1 ]; then
    die "Deployment ${APP_NAME}-${TARGET} has ${ready} ready replicas — switching to it would
   take production down rather than roll it back.
   Current state: bash 6_deploy/scripts/rollback.sh --status
   To restore that colour, re-deploy the known-good image:
     ECR_REPOSITORY_URL=<repo> IMAGE_TAG=<previous-tag> make deploy"
fi

log "Rolling back: ${live_colour:-unknown} → ${TARGET} (${ready} ready replica(s))"
kubectl patch service "$SERVICE_NAME" -n "$NAMESPACE" --type=merge \
    -p "{\"spec\":{\"selector\":{\"app\":\"${APP_NAME}\",\"version\":\"${TARGET}\"}}}"

rolled_back_image=$(kubectl get deployment "${APP_NAME}-${TARGET}" -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)

# Swap the record so a second rollback returns to where we came from
kubectl annotate service "$SERVICE_NAME" -n "$NAMESPACE" --overwrite \
    "spbc.io/previous-colour=${live_colour:-none}" \
    "spbc.io/previous-image=${current_image:-none}" \
    "spbc.io/current-colour=${TARGET}" \
    "spbc.io/current-image=${rolled_back_image:-unknown}" \
    "spbc.io/rolled-back-at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null

ok "Rollback complete — ${TARGET} is live (${rolled_back_image:-unknown})"
log "Verify with: SMOKE_TEST_URL=<url> make smoke"
