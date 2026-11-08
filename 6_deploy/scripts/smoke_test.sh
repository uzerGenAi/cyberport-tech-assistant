#!/usr/bin/env bash
set -euo pipefail
# smoke_test.sh — proves the deployed frontend is actually serving the app.
#
# Usage:
#   SMOKE_TEST_URL=https://main.d123.amplifyapp.com bash 6_deploy/scripts/smoke_test.sh
#
# A bare `curl -fsS` only proves something answered with a 2xx: an Amplify holding page, a
# load balancer default page or an error page all pass that. So this also checks the body
# looks like the SPBC app and carries no error marker.
#
# Options (environment):
#   SMOKE_TEST_URL      required; the URL to check
#   SMOKE_EXPECT        substring that must appear in the body (default: the app's title)
#   SMOKE_TIMEOUT       per-attempt timeout in seconds (default 10)
#   SMOKE_RETRIES       attempts before giving up (default 5, 5s apart) — a fresh
#                       deployment often needs a moment to start serving

set -euo pipefail

URL="${SMOKE_TEST_URL:-}"
EXPECT="${SMOKE_EXPECT:-Cyberport Tech Assistant}"
TIMEOUT="${SMOKE_TIMEOUT:-10}"
RETRIES="${SMOKE_RETRIES:-5}"

# No localhost default: in a pipeline that silently passed against nothing at all
if [ -z "$URL" ]; then
    echo "❌ SMOKE_TEST_URL is not set." >&2
    echo "   Set it to the deployed URL, for example:" >&2
    echo "     SMOKE_TEST_URL=\$(bash 6_deploy/scripts/amplify-deploy.sh --print-url) make smoke" >&2
    exit 1
fi

echo "Running smoke test against ${URL}"

attempt=1
while :; do
    status=$(curl -sS -o /tmp/smoke_body.$$ -w '%{http_code}' --max-time "$TIMEOUT" "$URL" 2>/tmp/smoke_err.$$) \
        && rc=0 || rc=$?

    if [ "$rc" -eq 0 ] && [ "$status" = "200" ]; then
        body=$(cat /tmp/smoke_body.$$)
        rm -f /tmp/smoke_body.$$ /tmp/smoke_err.$$

        if ! printf '%s' "$body" | grep -qi -- "$EXPECT"; then
            echo "❌ HTTP 200 but the body does not contain '${EXPECT}'." >&2
            echo "   The URL is serving something, just not this app (holding page? wrong target?)." >&2
            echo "   First 200 characters:" >&2
            printf '%s\n' "$body" | head -c 200 >&2
            echo "" >&2
            exit 1
        fi

        # A page that renders but shouts an error is not a passing deployment
        for marker in "Application error" "502 Bad Gateway" "503 Service" "Internal Server Error"; do
            if printf '%s' "$body" | grep -qi -- "$marker"; then
                echo "❌ The page contains '${marker}'." >&2
                exit 1
            fi
        done

        echo "✅ Smoke test passed (HTTP 200, body contains '${EXPECT}')"
        exit 0
    fi

    if [ "$attempt" -ge "$RETRIES" ]; then
        echo "❌ Smoke test failed after ${attempt} attempt(s): HTTP ${status:-no response}" >&2
        [ -s /tmp/smoke_err.$$ ] && cat /tmp/smoke_err.$$ >&2
        rm -f /tmp/smoke_body.$$ /tmp/smoke_err.$$
        exit 1
    fi

    echo "  attempt ${attempt}/${RETRIES}: HTTP ${status:-error}; retrying in 5s..."
    attempt=$((attempt + 1))
    sleep 5
done
