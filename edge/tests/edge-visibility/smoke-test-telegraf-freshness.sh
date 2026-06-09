#!/usr/bin/env bash
# smoke-test-telegraf-freshness.sh
# Phase  : visibility
# Service: telegraf-freshness
#
# 옵션 B (config-correctness 중심): 데이터 끝단(센서별 gauge 값)은 dev InfluxDB 가
# 비어있을 수 있어 검증 안 함. 브릿지가 "동작"하는지만 본다.
#   1. :9273/metrics 200 (prometheus_client output 살아있음).
#   2. internal_ 메트릭 노출 ([[inputs.internal]] 활성 — 자체 계측 가동).
#   3. internal_gather_errors 값이 모두 0 (http 입력=InfluxDB 질의가 에러 없이 수행됨).

set -euo pipefail
NS="${NAMESPACE:?NAMESPACE env not injected by runtime}"
SVC="${SERVICE:-telegraf-freshness}"
LOCAL_PORT="19273"
BASE="http://127.0.0.1:${LOCAL_PORT}"

kubectl port-forward -n "$NS" "svc/$SVC" "${LOCAL_PORT}:9273" >/dev/null 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT
sleep 2

# ── 1. /metrics 200 + 본문 확보 (retry) ──────────────────────────────────────
RETRIES=12
INTERVAL=5
BODY=""
for i in $(seq 1 $RETRIES); do
  BODY=$(curl -sf "${BASE}/metrics" 2>/dev/null || true)
  [ -n "$BODY" ] && break
  echo "attempt $i/$RETRIES: /metrics not ready, waiting ${INTERVAL}s..."
  sleep $INTERVAL
done
[ -n "$BODY" ] || {
  echo "FAIL: metrics: /metrics no response after $((RETRIES * INTERVAL))s"
  echo "  actual: (empty body)"
  exit 1
}

# ── 2. internal_ 메트릭 노출 ([[inputs.internal]] 활성) ───────────────────────
echo "$BODY" | grep -q "^internal_" || {
  echo "FAIL: internal: no internal_* metric ([[inputs.internal]] 비활성 의심)"
  echo "  actual: $(echo "$BODY" | grep -oE '^[a-z_]+' | sort -u | head -c 300)"
  exit 1
}

# ── 3. internal_gather_errors 전부 0 (InfluxDB 질의 성공) ─────────────────────
# prometheus 노출 형식: internal_gather_errors{input="...",...} <value>
BAD=$(echo "$BODY" | grep "^internal_gather_errors" | awk '{ if ($NF+0 > 0) print }' || true)
[ -z "$BAD" ] || {
  echo "FAIL: gather: internal_gather_errors > 0 (http 입력/InfluxDB 질의 실패)"
  echo "  actual: $BAD"
  exit 1
}

echo "All checks passed."
