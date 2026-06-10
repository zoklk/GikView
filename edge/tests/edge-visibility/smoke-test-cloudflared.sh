#!/usr/bin/env bash
# smoke-test-cloudflared.sh
# Phase  : visibility
# Service: cloudflared
#
# 진입 inbound 가 없어 HTTP origin 검증은 불가. cloudflared 자체 진단 서버
# (--metrics 0.0.0.0:2000)로 터널이 Cloudflare edge 에 실제 연결됐는지 본다.
#   1. :2000/ready 200 (등록된 터널 connection >= 1). 미연결이면 503.
#   2. readyConnections >= 1.

set -euo pipefail
NS="${NAMESPACE:?NAMESPACE env not injected by runtime}"
SVC="${SERVICE:-cloudflared}"
LOCAL_PORT="12000"
BASE="http://127.0.0.1:${LOCAL_PORT}"

# 진단 서버는 Service 로 노출 안 할 수 있어 pod 로 port-forward.
POD=$(kubectl get pod -n "$NS" --field-selector=status.phase=Running -o name 2>/dev/null \
  | grep "^pod/${SVC}-" | head -1 | sed 's#^pod/##')
[ -n "$POD" ] || {
  echo "FAIL: pod: no Running pod for '$SVC'"
  echo "  actual: kubectl returned empty"
  exit 1
}

kubectl port-forward -n "$NS" "pod/$POD" "${LOCAL_PORT}:2000" >/dev/null 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT
sleep 2

# ── /ready (retry) — 터널 edge 등록까지 시간 필요 ─────────────────────────────
RETRIES=12
INTERVAL=5
CODE="000"
BODY=""
for i in $(seq 1 $RETRIES); do
  BODY=$(curl -s -o /tmp/cf_ready -w "%{http_code}" "${BASE}/ready" 2>/dev/null || echo "000")
  CODE="$BODY"
  [ "$CODE" = "200" ] && break
  echo "attempt $i/$RETRIES: /ready=$CODE, waiting ${INTERVAL}s..."
  sleep $INTERVAL
done
READY_BODY=$(cat /tmp/cf_ready 2>/dev/null || echo "")
[ "$CODE" = "200" ] || {
  echo "FAIL: ready: /ready not 200 (터널이 Cloudflare edge 에 미연결). --metrics 0.0.0.0:2000 + TUNNEL_TOKEN 확인"
  echo "  actual: HTTP $CODE, body=$READY_BODY"
  exit 1
}

CONN=$(echo "$READY_BODY" | jq -r '.readyConnections // 0' 2>/dev/null || echo 0)
[ "${CONN:-0}" -ge 1 ] || {
  echo "FAIL: ready: readyConnections < 1"
  echo "  actual: $READY_BODY"
  exit 1
}

echo "All checks passed. (readyConnections=$CONN)"
