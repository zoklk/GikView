#!/usr/bin/env bash
# smoke-test-telegraf.sh
# Phase  : pipeline
# Service: telegraf
#
# 검증 범위:
#   1. Pod Ready (replica=2) + hard antiAffinity (서로 다른 노드에 분산)
#   2. mTLS cert + ConfigMap 마운트 (/tls/, /etc/telegraf/telegraf.conf, /lookup/mapping.csv)
#   3. telegraf.conf 내용: 기대 share group / topic / output 선언
#   4. EMQX subscription: $share/telegraf/sensors/+/occupancy 에 telegraf-* clientid 가 붙어있음
#   5. InfluxDB write 가능성 (token + endpoint 도달) — telegraf pod 내부에서 /health 확인
#
# 디바이스 발행 메시지 end-to-end (publish → InfluxDB measurement) 는 본 smoke 범위 밖
#   — 디바이스 mTLS cert 발급이 ESP8266 bootstrap 흐름 의존이라 smoke 비용 과다.
#   integration test (별도 트랙) 에서 다룬다.

set -euo pipefail
NS="${NAMESPACE:?NAMESPACE env not injected by runtime}"

SERVICE="${SERVICE:-telegraf}"
EXPECT_REPLICAS=2
EMQX_DASH_USER="admin"
EMQX_DASH_PASS='public'
EMQX_DASH_PORT=18083

# ── 1. Pod Ready (replica=2) ──────────────────────────────────────────────────
READY=$(kubectl get pod -n "$NS" -l "app.kubernetes.io/name=${SERVICE}" -o json 2>/dev/null \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
ready = 0
for p in data.get('items', []):
    conds = {c['type']: c['status'] for c in p['status'].get('conditions', [])}
    if conds.get('Ready') == 'True':
        ready += 1
print(ready)
" 2>/dev/null || echo "0")

[ "$READY" = "$EXPECT_REPLICAS" ] || {
  echo "FAIL: pod-ready: expected $EXPECT_REPLICAS Ready pods"
  echo "  actual: ready=$READY ; pods=$(kubectl get pod -n "$NS" -l app.kubernetes.io/name=${SERVICE} -o name 2>/dev/null | tr '\n' ' ')"
  exit 1
}

# ── 2. hard antiAffinity: pod 분산 ───────────────────────────────────────────
NODES=$(kubectl get pod -n "$NS" -l "app.kubernetes.io/name=${SERVICE}" \
  -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null | tr ' ' '\n' | sort -u | wc -l)
[ "$NODES" -ge "$EXPECT_REPLICAS" ] || {
  echo "FAIL: antiaffinity: telegraf pods not distributed across nodes"
  echo "  actual: unique_nodes=$NODES (expected >=$EXPECT_REPLICAS) ; placement=$(kubectl get pod -n "$NS" -l app.kubernetes.io/name=${SERVICE} -o jsonpath='{range .items[*]}{.metadata.name}={.spec.nodeName} {end}')"
  exit 1
}

# ── 3. 마운트 점검: cert + config + lookup ───────────────────────────────────
POD=$(kubectl get pod -n "$NS" -l "app.kubernetes.io/name=${SERVICE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$POD" ] || { echo "FAIL: pod-select: no telegraf pod found"; echo "  actual: empty"; exit 1; }

for path in /tls/tls.crt /tls/tls.key /tls/ca.crt /etc/telegraf/telegraf.conf /lookup/mapping.csv; do
  kubectl exec -n "$NS" "$POD" -- test -f "$path" 2>/dev/null || {
    echo "FAIL: mount: expected file '$path' missing inside pod"
    echo "  actual: kubectl exec ls=$(kubectl exec -n "$NS" "$POD" -- ls -la "$(dirname "$path")" 2>&1 | head -c 400)"
    exit 1
  }
done

# ── 4. telegraf.conf 내용 검증 ───────────────────────────────────────────────
CONF=$(kubectl exec -n "$NS" "$POD" -- cat /etc/telegraf/telegraf.conf 2>/dev/null || echo "")
[ -n "$CONF" ] || { echo "FAIL: conf-read: empty telegraf.conf"; echo "  actual: (empty)"; exit 1; }

for pattern in 'inputs\.mqtt_consumer' '\$share/telegraf/sensors/\+/occupancy' 'outputs\.influxdb_v2' 'processors\.regex' 'processors\.converter' 'processors\.lookup'; do
  echo "$CONF" | grep -qE "$pattern" || {
    echo "FAIL: conf-content: telegraf.conf missing '$pattern'"
    echo "  actual: telegraf.conf head=$(echo "$CONF" | head -c 400)"
    exit 1
  }
done

# ── 5. EMQX subscription: telegraf shared-subscribed ─────────────────────────
kubectl port-forward -n "$NS" svc/emqx "${EMQX_DASH_PORT}:18083" >/dev/null 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT
sleep 2

TOKEN=$(curl -s -X POST "http://127.0.0.1:${EMQX_DASH_PORT}/api/v5/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"${EMQX_DASH_USER}\",\"password\":\"${EMQX_DASH_PASS}\"}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null || echo "")
[ -n "$TOKEN" ] || {
  echo "FAIL: emqx-login: could not obtain bearer token"
  echo "  actual: empty token from /api/v5/login"
  exit 1
}

# subscriptions API 는 페이지네이션 — limit 충분히 크게
RETRIES=6
INTERVAL=5
FOUND=0
for i in $(seq 1 $RETRIES); do
  RESP=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "http://127.0.0.1:${EMQX_DASH_PORT}/api/v5/subscriptions?limit=200" 2>/dev/null || echo "")
  FOUND=$(echo "$RESP" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    data = d.get('data', d) if isinstance(d, dict) else d
    cnt = 0
    for s in data:
        topic = s.get('topic', '')
        clientid = s.get('clientid', '')
        if not clientid.startswith('telegraf-'):
            continue
        if topic == '\$share/telegraf/sensors/+/occupancy':
            cnt += 1
    print(cnt)
except Exception:
    print(0)
" 2>/dev/null || echo "0")
  [ "$FOUND" -ge 1 ] && break
  echo "attempt $i/$RETRIES: telegraf subscription not yet visible, waiting ${INTERVAL}s..."
  sleep $INTERVAL
done

[ "$FOUND" -ge 1 ] || {
  echo "FAIL: emqx-subscription: no telegraf shared-subscription on sensors/+/occupancy"
  echo "  actual: subscriptions resp head=$(echo "$RESP" | head -c 600)"
  exit 1
}

# ── 6. InfluxDB 도달성 (pod 내부에서 /health) ────────────────────────────────
INFLUX_HEALTH=$(kubectl exec -n "$NS" "$POD" -- sh -c \
  'wget -qO- --header="Authorization: Bearer ${INFLUXDB_TOKEN}" http://influxdb.gikview.svc.cluster.local:8181/health 2>/dev/null || echo "FAIL_FETCH"' 2>/dev/null || echo "FAIL_EXEC")

case "$INFLUX_HEALTH" in
  *'"status":"pass"'*|*'"status": "pass"'*|OK|OK*)
    : # InfluxDB 3 Core: plain "OK"; 1.x/2.x: JSON {"status":"pass"}
    ;;
  *)
    # alpha cluster: svc.alpha.nexus.local 또는 wget 미설치 가능. busybox env 차이 허용
    INFLUX_HEALTH2=$(kubectl exec -n "$NS" "$POD" -- sh -c \
      'wget -qO- --header="Authorization: Bearer ${INFLUXDB_TOKEN}" http://influxdb.gikview.svc.${DOMAIN_SUFFIX:-cluster.local}:8181/health 2>/dev/null || echo "FAIL_FETCH"' 2>/dev/null || echo "FAIL_EXEC")
    case "$INFLUX_HEALTH2" in
      *'"status":"pass"'*|*'"status": "pass"'*|OK|OK*)
        : # OK
        ;;
      *)
        echo "FAIL: influxdb-reach: telegraf pod cannot reach InfluxDB /health"
        echo "  actual: first=$INFLUX_HEALTH ; second=$INFLUX_HEALTH2"
        exit 1
        ;;
    esac
    ;;
esac

echo "All checks passed."
