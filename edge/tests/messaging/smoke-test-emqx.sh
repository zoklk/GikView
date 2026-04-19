#!/usr/bin/env bash
# smoke-test-emqx.sh
# Phase  : messaging
# Service: emqx

set -euo pipefail
NS="${HARNESS_NAMESPACE:-gikview}"

# ── 1. 클러스터 상태 확인 (Retry Loop) ───────────────────────────────────────
# EMQX는 모든 포드가 Ready여도 내부적으로 클러스터를 맺는 데 시간이 소요됨.
# 최대 대기시간: 12회 * 10초 = 120초
RETRIES=12
INTERVAL=10
COUNT=0
API_USER="admin"
API_PASS='public'

sleep 60

echo "Checking EMQX cluster status..."
for i in $(seq 1 $RETRIES); do
  # /opt/emqx/bin/emqx 전체 경로 사용 (emqx는 PATH에 없음)
  COUNT=$(kubectl exec -n "$NS" emqx-0 -- /opt/emqx/bin/emqx ctl cluster status 2>/dev/null | (grep -oE "emqx@[^']+" || true) | wc -l)

  echo "attempt $i/$RETRIES: running_nodes=$COUNT"
  if [ "$COUNT" = "3" ]; then
    echo "Cluster successfully formed with 3 nodes."
    break
  fi

  echo "$COUNT (expected 3), waiting ${INTERVAL}s..."
  sleep $INTERVAL
done

[ "$COUNT" = "3" ] || {
  echo "FAIL: Cluster not fully formed after 100s (running_nodes=$COUNT)."
  echo "Diagnostic: Check EMQX_CLUSTER__DNS__RECORD_TYPE and EMQX_NODE__NAME consistency."
  exit 1
}

# ── 2. Port-forward 설정 및 정리 ───────────────────────────────────────────
# MQTT(1883)와 Dashboard API(18083) 포트를 로컬로 포워딩
kubectl port-forward -n "$NS" svc/emqx 11883:1883 >/dev/null 2>&1 &
PF1_PID=$!
kubectl port-forward -n "$NS" svc/emqx 18083:18083 >/dev/null 2>&1 &
PF2_PID=$!

# 스크립트 종료 시(성공/실패 무관) 백그라운드 프로세스 확실히 정리
trap "kill $PF1_PID $PF2_PID 2>/dev/null || true" EXIT

# 포트 포워딩 안정화 대기
sleep 3

# ── 3. 기능 검증: MQTT Pub/Sub ──────────────────────────────────────────────
echo "Testing MQTT Pub/Sub connectivity..."
# subscriber를 먼저 백그라운드로 실행 후 publish해야 메시지를 수신할 수 있음
# (retain 없이 publish 먼저 하면 이미 지나간 메시지를 subscriber가 놓침)
mosquitto_sub -h 127.0.0.1 -p 11883 -t smoke/test -C 1 -W 10 > /tmp/mqtt_smoke_result &
SUB_PID=$!
sleep 0.5
mosquitto_pub -h 127.0.0.1 -p 11883 -t smoke/test -m "ok" -q 1 || {
  kill "$SUB_PID" 2>/dev/null
  echo "FAIL: MQTT Publish failed"
  exit 1
}
wait "$SUB_PID" || { echo "FAIL: MQTT Subscribe timeout (10s)"; exit 1; }
grep -q "ok" /tmp/mqtt_smoke_result || { echo "FAIL: MQTT message mismatch"; exit 1; }

# ── 4. 기능 검증: Dashboard API 노드 상태 ────────────────────────────────────
# EMQX 5.x REST API 인증 구조:
#   Basic Auth(-u user:pass)는 API Key:Secret 전용.
#   Dashboard 사용자(admins add)는 /api/v5/login → JWT Bearer Token으로만 API 접근 가능.
echo "Verifying node health via Dashboard API..."

# Bearer token 획득
TOKEN=$(curl -s -X POST http://127.0.0.1:18083/api/v5/login \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"${API_USER}\",\"password\":\"${API_PASS}\"}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null || echo "")

if [ -z "$TOKEN" ]; then
  echo "FAIL: /api/v5/login failed — check API_USER/API_PASS (${API_USER})"
  exit 1
fi
echo "Bearer token acquired."

SUCCESS=0
for i in $(seq 1 5); do
  HTTP_CODE=$(curl -s -o /tmp/emqx_api_resp.json -w "%{http_code}" \
    -H "Authorization: Bearer $TOKEN" \
    http://127.0.0.1:18083/api/v5/nodes 2>/dev/null || echo "000")
  RESPONSE=$(cat /tmp/emqx_api_resp.json 2>/dev/null || echo "")

  if [ "$HTTP_CODE" = "200" ] && [ -n "$RESPONSE" ]; then
    if echo "$RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    running_nodes = [n for n in data if n['node_status'] == 'running']
    if len(running_nodes) == 3:
        sys.exit(0)
    else:
        print('Only ' + str(len(running_nodes)) + ' nodes running')
        sys.exit(1)
except Exception as e:
    print('Parse error:', e)
    sys.exit(1)
"; then
      SUCCESS=1
      break
    fi
  else
    echo "Dashboard API not ready (HTTP $HTTP_CODE), waiting 5s... ($i/5)"
  fi

  sleep 5
done

if [ "$SUCCESS" -eq 0 ]; then
  echo "FAIL: Dashboard API health check failed after multiple attempts."
  exit 1
fi
