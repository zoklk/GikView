#!/usr/bin/env bash
# smoke-test-prometheus.sh
# Phase  : visibility
# Service: prometheus
#
# 검증:
#   1. /-/healthy + /-/ready 200.
#   2. /api/v1/status/flags 의 storage.tsdb.retention.time == 2w.
#   3. /api/v1/targets 에 node-exporter job 의 up 타겟 존재.
#   4. /api/v1/rules 에 alert rule(SensorNoData) 로드됨.
#   5. /api/v1/targets 에 hubble job 의 up 타겟 존재 (선행: cilium hubble.metrics.enabled).

set -euo pipefail
NS="${NAMESPACE:?NAMESPACE env not injected by runtime}"
SVC="${SERVICE:-prometheus}"
LOCAL_PORT="19090"
BASE="http://127.0.0.1:${LOCAL_PORT}"

kubectl port-forward -n "$NS" "svc/$SVC" "${LOCAL_PORT}:9090" >/dev/null 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT
sleep 2

# ── 1. /-/healthy, /-/ready (retry) ──────────────────────────────────────────
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

# ── 2. retention flag == 14d ─────────────────────────────────────────────────
FLAGS=$(curl -sf "${BASE}/api/v1/status/flags" 2>/dev/null || true)
RETENTION=$(echo "$FLAGS" | jq -r '.data["storage.tsdb.retention.time"] // ""')
[ "$RETENTION" = "2w" ] || {
  echo "FAIL: retention: storage.tsdb.retention.time != 2w"
  echo "  actual: '$RETENTION' (flags=$(echo "$FLAGS" | head -c 300))"
  exit 1
}

# ── 3. node-exporter job up 타겟 존재 (fresh prometheus 는 첫 scrape 까지 시간 필요) ──
RETRIES=12
INTERVAL=5
NE_UP=0
for i in $(seq 1 $RETRIES); do
  TARGETS=$(curl -sf "${BASE}/api/v1/targets" 2>/dev/null || true)
  NE_UP=$(echo "$TARGETS" | jq '[.data.activeTargets[]? | select(.labels.job=="node-exporter" and .health=="up")] | length')
  [ "${NE_UP:-0}" -ge 1 ] && break
  echo "attempt $i/$RETRIES: node-exporter targets up=$NE_UP, waiting ${INTERVAL}s..."
  sleep $INTERVAL
done
[ "${NE_UP:-0}" -ge 1 ] || {
  echo "FAIL: targets: no up target for job 'node-exporter' after $((RETRIES*INTERVAL))s"
  echo "  actual: node-exporter up count=${NE_UP:-0}, jobs=$(echo "$TARGETS" | jq -r '[.data.activeTargets[]?.labels.job] | unique | join(",")')"
  exit 1
}

# ── 4. alert rule 로드됨 ──────────────────────────────────────────────────────
RULES=$(curl -sf "${BASE}/api/v1/rules" 2>/dev/null || true)
echo "$RULES" | jq -e '[.data.groups[]?.rules[]? | select(.name=="SensorNoData")] | length >= 1' >/dev/null 2>&1 || {
  echo "FAIL: rules: alert rule 'SensorNoData' not loaded"
  echo "  actual: rules=$(echo "$RULES" | jq -r '[.data.groups[]?.rules[]?.name] | join(",")' 2>/dev/null | head -c 300)"
  exit 1
}

# ── 5. hubble job up 타겟 존재 (선행: cilium hubble.metrics.enabled) ──
RETRIES=12; INTERVAL=5; HB_UP=0
for i in $(seq 1 $RETRIES); do
  TARGETS=$(curl -sf "${BASE}/api/v1/targets" 2>/dev/null || true)
  HB_UP=$(echo "$TARGETS" | jq '[.data.activeTargets[]? | select(.labels.job=="hubble" and .health=="up")] | length')
  [ "${HB_UP:-0}" -ge 1 ] && break
  echo "attempt $i/$RETRIES: hubble targets up=$HB_UP, waiting ${INTERVAL}s..."
  sleep $INTERVAL
done
[ "${HB_UP:-0}" -ge 1 ] || { echo "FAIL: targets: no up target for job 'hubble' (cilium hubble.metrics 활성 확인)"; exit 1; }

echo "All checks passed. (retention=$RETENTION, node-exporter up=$NE_UP, hubble up=$HB_UP)"
