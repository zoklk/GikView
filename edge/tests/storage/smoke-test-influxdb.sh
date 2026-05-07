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

# ── 1. Admin token 추출 ───────────────────────────────────────────────────────
TOKEN=$(kubectl get secret -n "$NS" "$SECRET_NAME" \
  -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
[ -n "$TOKEN" ] || {
  echo "FAIL: secret '$SECRET_NAME' not found or missing 'token' key in namespace $NS"
  echo "Diagnostic: bootstrap token was not registered. Re-run admin-token Secret creation."
  exit 1
}

# ── 2. Port-forward 설정 및 정리 ──────────────────────────────────────────────
kubectl port-forward -n "$NS" "svc/$SVC_NAME" "${LOCAL_PORT}:8181" >/dev/null 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT
sleep 3

BASE_URL="http://127.0.0.1:${LOCAL_PORT}"

# ── 3. Health check (retry) ──────────────────────────────────────────────────
# 최대 대기시간: 12 × 5s = 60s
echo "Checking InfluxDB /health..."
RETRIES=12
INTERVAL=5
HEALTH=""
for i in $(seq 1 $RETRIES); do
  HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/health" 2>/dev/null || echo "000")
  [ "$HEALTH" = "200" ] && break
  echo "attempt $i/$RETRIES: /health=$HEALTH, waiting ${INTERVAL}s..."
  sleep $INTERVAL
done
[ "$HEALTH" = "200" ] || {
  echo "FAIL: /health did not return 200 after $((RETRIES * INTERVAL))s (last=$HEALTH)"
  exit 1
}
echo "Health check passed."

# ── 4. Database 'gikview' 존재 확인 ──────────────────────────────────────────
echo "Verifying database '$DB_NAME' exists..."
DB_RESP=$(curl -s -w "\n%{http_code}" \
  "${BASE_URL}/api/v3/configure/database" \
  -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "")
DB_HTTP_CODE=$(echo "$DB_RESP" | tail -n 1)
DB_BODY=$(echo "$DB_RESP" | sed '$d')

[ "$DB_HTTP_CODE" = "200" ] || {
  echo "FAIL: database list query returned HTTP $DB_HTTP_CODE"
  echo "Body: $DB_BODY"
  exit 1
}

echo "$DB_BODY" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    names = [d.get('iox_namespace') or d.get('db_name') or d.get('name') for d in data]
    if '$DB_NAME' not in names:
        print('database \"$DB_NAME\" not found, got:', names)
        sys.exit(1)
except Exception as e:
    print('Parse error:', e)
    sys.exit(1)
" || { echo "FAIL: database '$DB_NAME' not found"; exit 1; }
echo "Database '$DB_NAME' exists."

# ── 5. ESP32 형식 dummy line protocol write ──────────────────────────────────
# 운영 데이터 (room_01 ~ room_09) 와 격리하기 위해 room_id=smoke-test 사용
echo "Writing dummy occupancy line..."
TS_NS=$(date +%s%N)
LP="occupancy,room_id=smoke-test,bssid=00:00:00:00:00:00 occupied=true,rssi=-67i,device_id=\"device-smoke\" $TS_NS"

WRITE_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${BASE_URL}/api/v3/write_lp?db=${DB_NAME}&precision=ns" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: text/plain" \
  --data-raw "$LP" 2>/dev/null || echo "000")

[ "$WRITE_CODE" = "204" ] || [ "$WRITE_CODE" = "200" ] || {
  echo "FAIL: line protocol write rejected (HTTP $WRITE_CODE)"
  echo "Line: $LP"
  exit 1
}
echo "Dummy write accepted."

# ── 6. Query 검증 ────────────────────────────────────────────────────────────
# 인덱싱 시간 약간 부여 (memtable → query path)
sleep 2

echo "Querying back the dummy row..."
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

[ -n "$QUERY_RESP" ] || { echo "FAIL: query returned empty response"; exit 1; }

echo "$QUERY_RESP" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if not isinstance(data, list) or len(data) == 0:
        print('Empty result set')
        sys.exit(1)
    row = data[0]
    if row.get('occupied') is not True:
        print('occupied mismatch:', row.get('occupied'))
        sys.exit(1)
    if row.get('rssi') != -67:
        print('rssi mismatch:', row.get('rssi'))
        sys.exit(1)
    if row.get('device_id') != 'device-smoke':
        print('device_id mismatch:', row.get('device_id'))
        sys.exit(1)
except Exception as e:
    print('Parse error:', e)
    sys.exit(1)
" || {
  echo "FAIL: query result mismatch"
  echo "Response: $QUERY_RESP"
  exit 1
}
echo "Query verification passed."

echo "All checks passed."