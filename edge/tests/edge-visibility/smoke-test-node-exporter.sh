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

# ── 2. pod 내부 loopback 으로 /metrics 스크레이프 ─────────────────────────────
# 호스트 IP 직접 curl 은 클러스터 밖(harness 호스트) 경로 → 큰 응답이 MTU 절단되어
# go_* 까지만 도착하고 끊김(broken pipe). node-exporter 는 hostNetwork 라 pod 내부
# 127.0.0.1:9100 이 곧 노드 :9100 이며, loopback(MTU 65536)은 전체 본문을 받는다.
RETRIES=18
INTERVAL=5
OK=0
for i in $(seq 1 $RETRIES); do
  # pod 내부에서 바로 grep: 큰 본문을 셸로 안 가져옴(파이프 첫 매치서 닫힘) → 안정적.
  if kubectl exec -n "$NS" "$POD" -- /bin/sh -c \
       'wget -qO- http://127.0.0.1:9100/metrics | grep -q node_cpu_seconds_total' 2>/dev/null; then
    OK=1
    break
  fi
  echo "attempt $i/$RETRIES: node_* metrics not ready, waiting ${INTERVAL}s..."
  sleep $INTERVAL
done
[ "$OK" = 1 ] || {
  echo "FAIL: metrics: /metrics missing node_cpu_seconds_total"
  echo "  actual: $(kubectl exec -n "$NS" "$POD" -- /bin/sh -c 'wget -qO- http://127.0.0.1:9100/metrics 2>/dev/null | head -c 300' 2>/dev/null)"
  exit 1
}

echo "All checks passed. (nodes=$NODE_COUNT, ready=$READY)"
