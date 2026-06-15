#!/usr/bin/env bash
# smoke-test-grafana.sh
# Phase  : visibility
# Service: grafana
#
# 검증:
#   1. /api/health 200 + database == ok.
#   2. admin 인증 → Prometheus datasource 존재 + url 일치.
#   2b. Hubble 대시보드 provisioned (/api/search?query=hubble).
#   3. datasource proxy 로 Prometheus 에 vector(1) 질의 성공 → grafana→prometheus 도달.
#      (Prometheus 타입은 /health 미지원이라 proxy 쿼리로 연결성 검증.)

set -euo pipefail
NS="${NAMESPACE:?NAMESPACE env not injected by runtime}"
SVC="${SERVICE:-grafana}"
SECRET_NAME="grafana-admin"
LOCAL_PORT="13000"
BASE="http://127.0.0.1:${LOCAL_PORT}"

kubectl port-forward -n "$NS" "svc/$SVC" "${LOCAL_PORT}:3000" >/dev/null 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT
sleep 2

# ── 1. /api/health (retry) ───────────────────────────────────────────────────
RETRIES=12
INTERVAL=5
HEALTH=""
for i in $(seq 1 $RETRIES); do
  HEALTH=$(curl -sf "${BASE}/api/health" 2>/dev/null || true)
  [ -n "$HEALTH" ] && break
  echo "attempt $i/$RETRIES: /api/health not ready, waiting ${INTERVAL}s..."
  sleep $INTERVAL
done
DB=$(echo "$HEALTH" | jq -r '.database // ""')
[ "$DB" = "ok" ] || {
  echo "FAIL: health: /api/health database != ok"
  echo "  actual: $(echo "$HEALTH" | head -c 300)"
  exit 1
}

# ── 2. admin 인증 + Prometheus datasource ────────────────────────────────────
ADMIN_PW=$(kubectl get secret -n "$NS" "$SECRET_NAME" \
  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true)
[ -n "$ADMIN_PW" ] || {
  echo "FAIL: secret: '$SECRET_NAME' missing or no 'admin-password' key"
  echo "  actual: kubectl returned empty (namespace=$NS)"
  exit 1
}
ADMIN_USER=$(kubectl get secret -n "$NS" "$SECRET_NAME" \
  -o jsonpath='{.data.admin-user}' 2>/dev/null | base64 -d || true)
[ -n "$ADMIN_USER" ] || ADMIN_USER="admin"   # key 없으면 기본값 fallback
AUTH="${ADMIN_USER}:${ADMIN_PW}"

DS=$(curl -sf -u "$AUTH" "${BASE}/api/datasources/name/Prometheus" 2>/dev/null || true)
DS_UID=$(echo "$DS" | jq -r '.uid // ""')
DS_URL=$(echo "$DS" | jq -r '.url // ""')
[ -n "$DS_UID" ] || {
  echo "FAIL: datasource: 'Prometheus' datasource not provisioned"
  echo "  actual: $(echo "$DS" | head -c 300)"
  exit 1
}
echo "$DS_URL" | grep -q "prometheus" || {
  echo "FAIL: datasource: Prometheus url unexpected"
  echo "  actual: url=$DS_URL"
  exit 1
}

# ── 2b. Hubble 대시보드 provisioned ──
DASH=$(curl -sf -u "$AUTH" "${BASE}/api/search?query=hubble" 2>/dev/null || true)
echo "$DASH" | jq -e 'length >= 1' >/dev/null 2>&1 || {
  echo "FAIL: dashboard: Hubble dashboard not provisioned"
  echo "  actual: $(echo "$DASH" | head -c 300)"; exit 1; }

# ── 3. proxy 로 prometheus 도달 (vector(1)) ──────────────────────────────────
PROXY=$(curl -sf -u "$AUTH" \
  "${BASE}/api/datasources/proxy/uid/${DS_UID}/api/v1/query?query=vector(1)" 2>/dev/null || true)
echo "$PROXY" | jq -e '.status == "success"' >/dev/null 2>&1 || {
  echo "FAIL: connectivity: grafana→prometheus proxy query failed"
  echo "  actual: $(echo "$PROXY" | head -c 300)"
  exit 1
}

echo "All checks passed. (datasource uid=$DS_UID)"
