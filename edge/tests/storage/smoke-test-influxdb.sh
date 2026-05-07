#!/usr/bin/env bash
# smoke-test-influxdb.sh
# Phase  : storage
# Service: influxdb

set -euo pipefail
NS="${NAMESPACE:?NAMESPACE env not injected by runtime}"

DB_NAME="gikview"
SECRET_NAME="influxdb-admin-token"
SVC_NAME="influxdb"
LOCAL_PORT="18181"
BASE_URL="http://127.0.0.1:${LOCAL_PORT}"

# ── 1. Admin token 추출 ───────────────────────────────────────────────────────
TOKEN=$(kubectl get secret -n "$NS" "$SECRET_NAME" \
  -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
[ -n "$TOKEN" ] || {
  echo "FAIL: admin-token: secret '$SECRET_NAME' missing or has no 'token' key"
  echo "  actual: kubectl returned empty (namespace=$NS)"
  exit 1
}

# ── 2. Port-forward ──────────────────────────────────────────────────────────
kubectl port-forward -n "$NS" "svc/$SVC_NAME" "${LOCAL_PORT}:8181" >/dev/null 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT
sleep 2

# ── 3. /health (retry) ───────────────────────────────────────────────────────
# 최대 대기시간: 12 × 5s = 60s
RETRIES=12
INTERVAL=5
HEALTH=""
for i in $(seq 1 $RETRIES); do
  HEALTH=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $TOKEN" \
    "${BASE_URL}/health" 2>/dev/null || echo "000")
  [ "$HEALTH" = "200" ] && break
  echo "attempt $i/$RETRIES: /health=$HEALTH, waiting ${INTERVAL}s..."
  sleep $INTERVAL
done
[ "$HEALTH" = "200" ] || {
  echo "FAIL: health: /health did not return 200 after $((RETRIES * INTERVAL))s"
  echo "  actual: HTTP $HEALTH"
  exit 1
}

# ── 4. Database '$DB_NAME' 존재 확인 ─────────────────────────────────────────
DB_RESP=$(curl -s -w "\n%{http_code}" \
  "${BASE_URL}/api/v3/configure/database?format=json" \
  -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "")
DB_HTTP_CODE=$(echo "$DB_RESP" | tail -n 1)
DB_BODY=$(echo "$DB_RESP" | sed '$d')

[ "$DB_HTTP_CODE" = "200" ] || {
  echo "FAIL: db-list: configure/database returned non-200"
  echo "  actual: HTTP $DB_HTTP_CODE, body=$DB_BODY"
  exit 1
}

DB_NAMES=$(echo "$DB_BODY" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    names = [d.get('iox::database') for d in data if d.get('iox::database') != '_internal']
    print(','.join(n for n in names if n))
except Exception as e:
    print('PARSE_ERROR:', e, file=sys.stderr)
    sys.exit(1)
" 2>&1) || {
  echo "FAIL: db-list: failed to parse response"
  echo "  actual: $DB_NAMES (body=$DB_BODY)"
  exit 1
}
echo ",$DB_NAMES," | grep -q ",$DB_NAME," || {
  echo "FAIL: db-list: database '$DB_NAME' not in list"
  echo "  actual: $DB_NAMES"
  exit 1
}

# ── 5. Line protocol write ───────────────────────────────────────────────────
# 운영 데이터 (room_01 ~ room_09) 와 격리하기 위해 room_id=smoke-test 사용
TS_NS=$(date +%s%N)
LP="occupancy,room_id=smoke-test,bssid=00:00:00:00:00:00 occupied=true,rssi=-67i,device_id=\"device-smoke\" $TS_NS"

WRITE_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${BASE_URL}/api/v3/write_lp?db=${DB_NAME}&precision=ns" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: text/plain" \
  --data-raw "$LP" 2>/dev/null || echo "000")

[ "$WRITE_CODE" = "204" ] || [ "$WRITE_CODE" = "200" ] || {
  echo "FAIL: write_lp: line protocol POST rejected"
  echo "  actual: HTTP $WRITE_CODE, line=$LP"
  exit 1
}

# ── 6. Query 검증 ────────────────────────────────────────────────────────────
# 인덱싱 시간 약간 부여 (memtable → query path)
sleep 2

QUERY_JSON=$(python3 -c "
import json
print(json.dumps({
    'db': '$DB_NAME',
    'q': \"SELECT occupied, rssi, device_id FROM occupancy WHERE room_id = 'smoke-test' ORDER BY time DESC LIMIT 1\",
    'format': 'json'
}))
")

QUERY_RESP=$(curl -s -X POST "${BASE_URL}/api/v3/query_sql" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  --data-raw "$QUERY_JSON" 2>/dev/null || echo "")

[ -n "$QUERY_RESP" ] || {
  echo "FAIL: query: empty response from /api/v3/query_sql"
  echo "  actual: (empty body)"
  exit 1
}

QUERY_OUT=$(echo "$QUERY_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if not isinstance(data, list) or len(data) == 0:
    sys.exit('empty result set')
row = data[0]
if row.get('occupied') is not True:
    sys.exit(f'occupied mismatch: {row.get(\"occupied\")!r}')
if row.get('rssi') != -67:
    sys.exit(f'rssi mismatch: {row.get(\"rssi\")!r}')
if row.get('device_id') != 'device-smoke':
    sys.exit(f'device_id mismatch: {row.get(\"device_id\")!r}')
" 2>&1) || {
  echo "FAIL: query: result row mismatch"
  echo "  actual: $QUERY_OUT (response=$QUERY_RESP)"
  exit 1
}

echo "All checks passed."