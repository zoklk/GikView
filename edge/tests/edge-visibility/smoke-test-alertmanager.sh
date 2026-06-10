#!/usr/bin/env bash
# smoke-test-alertmanager.sh
# Phase  : visibility
# Service: alertmanager
#
# 검증:
#   1. /-/ready 200.
#   2. /api/v2/status 의 config.original 에 discord receiver 포함 (Discord 라우팅 구성).

set -euo pipefail
NS="${NAMESPACE:?NAMESPACE env not injected by runtime}"
SVC="${SERVICE:-alertmanager}"
LOCAL_PORT="19093"
BASE="http://127.0.0.1:${LOCAL_PORT}"

kubectl port-forward -n "$NS" "svc/$SVC" "${LOCAL_PORT}:9093" >/dev/null 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT
sleep 2

# ── 1. /-/ready (retry) ──────────────────────────────────────────────────────
RETRIES=12
INTERVAL=5
READY=""
for i in $(seq 1 $RETRIES); do
  READY=$(curl -s -o /dev/null -w "%{http_code}" "${BASE}/-/ready" 2>/dev/null || echo "000")
  [ "$READY" = "200" ] && break
  echo "attempt $i/$RETRIES: /-/ready=$READY, waiting ${INTERVAL}s..."
  sleep $INTERVAL
done
[ "$READY" = "200" ] || {
  echo "FAIL: ready: /-/ready not 200 after $((RETRIES * INTERVAL))s"
  echo "  actual: HTTP $READY"
  exit 1
}

# ── 2. config 에 discord receiver ────────────────────────────────────────────
STATUS=$(curl -sf "${BASE}/api/v2/status" 2>/dev/null || true)
[ -n "$STATUS" ] || {
  echo "FAIL: status: empty response from /api/v2/status"
  echo "  actual: (empty body)"
  exit 1
}
CONFIG=$(echo "$STATUS" | jq -r '.config.original // ""')
echo "$CONFIG" | grep -q "discord_configs" || {
  echo "FAIL: config: discord_configs receiver not present in loaded config"
  echo "  actual: $(echo "$CONFIG" | head -c 400)"
  exit 1
}

echo "All checks passed."
