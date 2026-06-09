#!/usr/bin/env bash
# smoke-test-node-exporter.sh
# Phase  : visibility
# Service: node-exporter
#
# 검증:
#   1. DaemonSet 가 전 노드에 스케줄됨 (desired == 노드 수, ready == desired)
#      → control-plane(e-s1) 포함. toleration 누락 시 여기서 실패.
#   2. 한 pod 의 :9100/metrics 가 200 + node_cpu_seconds_total 노출.

set -euo pipefail
NS="${NAMESPACE:?NAMESPACE env not injected by runtime}"
SVC="${SERVICE:-node-exporter}"
LOCAL_PORT="19100"

# ── 1. DaemonSet 스케줄 == 노드 수 ────────────────────────────────────────────
DS_JSON=$(kubectl get ds -n "$NS" "$SVC" -o json 2>/dev/null || true)
[ -n "$DS_JSON" ] || {
  echo "FAIL: daemonset: DaemonSet '$SVC' not found in namespace $NS"
  echo "  actual: kubectl returned empty"
  exit 1
}
DESIRED=$(echo "$DS_JSON" | jq '.status.desiredNumberScheduled // 0')
READY=$(echo "$DS_JSON"   | jq '.status.numberReady // 0')
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')

[ "$DESIRED" = "$NODE_COUNT" ] || {
  echo "FAIL: daemonset: desiredNumberScheduled != node count (control-plane toleration 누락 의심)"
  echo "  actual: desired=$DESIRED, nodes=$NODE_COUNT, ready=$READY"
  exit 1
}
[ "$READY" = "$DESIRED" ] && [ "$READY" -ge 1 ] || {
  echo "FAIL: daemonset: numberReady != desired"
  echo "  actual: ready=$READY, desired=$DESIRED"
  exit 1
}

# ── 2. pod 하나의 /metrics ────────────────────────────────────────────────────
POD=$(kubectl get pod -n "$NS" --field-selector=status.phase=Running -o name 2>/dev/null \
  | grep "^pod/${SVC}-" | head -1 | sed 's#^pod/##')
[ -n "$POD" ] || {
  echo "FAIL: pod: no Running pod for '$SVC'"
  echo "  actual: kubectl returned empty (ds ready=$READY)"
  exit 1
}

kubectl port-forward -n "$NS" "pod/$POD" "${LOCAL_PORT}:9100" >/dev/null 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT
sleep 2

RETRIES=6
INTERVAL=5
BODY=""
for i in $(seq 1 $RETRIES); do
  BODY=$(curl -sf "http://127.0.0.1:${LOCAL_PORT}/metrics" 2>/dev/null || true)
  [ -n "$BODY" ] && break
  echo "attempt $i/$RETRIES: /metrics not ready, waiting ${INTERVAL}s..."
  sleep $INTERVAL
done
echo "$BODY" | grep -q "node_cpu_seconds_total" || {
  echo "FAIL: metrics: /metrics missing node_cpu_seconds_total"
  echo "  actual: $(echo "$BODY" | head -c 300)"
  exit 1
}

echo "All checks passed. (nodes=$NODE_COUNT, ready=$READY)"
