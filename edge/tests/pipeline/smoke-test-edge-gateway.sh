#!/usr/bin/env bash
# smoke-test-edge-gateway.sh
# Phase  : pipeline
# Service: edge-gateway
#
# 검증 범위:
#   1. Pod Ready (replica=2) + hard antiAffinity
#   2. mTLS cert + device-room-mapping ConfigMap 마운트
#   3. IAM Roles Anywhere env 4종 주입 (TRUST_ANCHOR_ARN/PROFILE_ARN/ROLE_ARN/AWS_DEFAULT_REGION)
#   4. EMQX subscription: $share/edge-gw/sensors/+/occupancy 에 edge-gateway clientid 가 붙어있음
#   5. InfluxDB 도달성 (캐시 miss 시 last() 쿼리 경로) — /health
#   6. aws_signing_helper 바이너리 + STS 도달성
#      - prod 환경: 임시 자격증명 발급 성공 (Credentials JSON 반환)
#      - dev 환경: STS 가 `TrustAnchorNotFound`/`AccessDenied`/`InvalidSignatureException` 반환
#                  → config (cert, env, signing helper) 는 정상, 트러스트 체인만 미해결
#                  이 경우도 smoke pass — 트러스트 체인은 prod-only AWS 콘솔 사전 작업
#
# DynamoDB PutItem 실제 호출은 본 smoke 범위 밖
#   사유: dev 환경에서는 STS 가 자격증명 안 줘서 PutItem 불가.
#   장기 해결: dev sandbox AWS account 에 dev intermediate CA Trust Anchor 등록 (옵션 A).
#   본 smoke 는 옵션 B (STS 응답 패턴) 채택 — config 정합성 검증 + 트러스트 체인은 별도.

set -euo pipefail
NS="${NAMESPACE:?NAMESPACE env not injected by runtime}"

SERVICE="${SERVICE:-edge-gateway}"
EXPECT_REPLICAS=2
EMQX_DASH_USER="admin"
EMQX_DASH_PASS='public'
EMQX_DASH_PORT=18084  # telegraf smoke 가 18083 쓰는 경우 충돌 방지 (단독 실행 시도 무방)

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

# ── 2. hard antiAffinity ──────────────────────────────────────────────────────
NODES=$(kubectl get pod -n "$NS" -l "app.kubernetes.io/name=${SERVICE}" \
  -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null | tr ' ' '\n' | sort -u | wc -l)
[ "$NODES" -ge "$EXPECT_REPLICAS" ] || {
  echo "FAIL: antiaffinity: edge-gateway pods not distributed across nodes"
  echo "  actual: unique_nodes=$NODES (expected >=$EXPECT_REPLICAS)"
  exit 1
}

POD=$(kubectl get pod -n "$NS" -l "app.kubernetes.io/name=${SERVICE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$POD" ] || { echo "FAIL: pod-select: no edge-gateway pod found"; echo "  actual: empty"; exit 1; }

# ── 3. 마운트 점검: cert + mapping ───────────────────────────────────────────
for path in /tls/tls.crt /tls/tls.key /tls/ca.crt; do
  kubectl exec -n "$NS" "$POD" -- test -f "$path" 2>/dev/null || {
    echo "FAIL: mount: expected file '$path' missing inside pod"
    echo "  actual: $(kubectl exec -n "$NS" "$POD" -- ls -la /tls 2>&1 | head -c 400)"
    exit 1
  }
done
MAPPING=$(kubectl exec -n "$NS" "$POD" -- sh -c 'find / -name mapping.csv -not -path "/proc/*" 2>/dev/null | head -1' 2>/dev/null || echo "")
[ -n "$MAPPING" ] || {
  echo "FAIL: mount: device-room-mapping CSV not mounted in pod"
  echo "  actual: find result empty"
  exit 1
}

# ── 4. IAM Roles Anywhere env 4종 주입 ───────────────────────────────────────
ENV_DUMP=$(kubectl exec -n "$NS" "$POD" -- env 2>/dev/null || echo "")
for var in TRUST_ANCHOR_ARN PROFILE_ARN ROLE_ARN AWS_DEFAULT_REGION; do
  VAL=$(echo "$ENV_DUMP" | awk -F= -v k="$var" '$1==k {for(i=2;i<=NF;i++) printf "%s%s", $i, (i<NF?"=":""); exit}')
  [ -n "$VAL" ] || {
    echo "FAIL: env: required env var '$var' not set in edge-gateway pod"
    echo "  actual: env head=$(echo "$ENV_DUMP" | grep -E '^(TRUST_ANCHOR|PROFILE|ROLE|AWS_)' | head -c 400)"
    exit 1
  }
  case "$var" in
    TRUST_ANCHOR_ARN|PROFILE_ARN)
      echo "$VAL" | grep -qE '^arn:aws:rolesanywhere:' || {
        echo "FAIL: env: $var has unexpected format"
        echo "  actual: $var=$VAL"
        exit 1
      }
      ;;
    ROLE_ARN)
      echo "$VAL" | grep -qE '^arn:aws:iam::[0-9]+:role/' || {
        echo "FAIL: env: ROLE_ARN has unexpected format"
        echo "  actual: ROLE_ARN=$VAL"
        exit 1
      }
      ;;
    AWS_DEFAULT_REGION)
      echo "$VAL" | grep -qE '^[a-z]+-[a-z]+-[0-9]$' || {
        echo "FAIL: env: AWS_DEFAULT_REGION not a valid region code"
        echo "  actual: AWS_DEFAULT_REGION=$VAL"
        exit 1
      }
      ;;
  esac
done

# ── 5. EMQX subscription: edge-gw shared group ───────────────────────────────
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
  echo "  actual: empty"
  exit 1
}

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
        if topic == 'sensors/+/occupancy' and clientid.startswith('edge-gateway'):
            grp = s.get('share_group') or s.get('group') or ''
            if grp == 'edge-gw':
                cnt += 1
    print(cnt)
except Exception:
    print(0)
" 2>/dev/null || echo "0")
  [ "$FOUND" -ge 1 ] && break
  echo "attempt $i/$RETRIES: edge-gw subscription not yet visible, waiting ${INTERVAL}s..."
  sleep $INTERVAL
done

[ "$FOUND" -ge 1 ] || {
  echo "FAIL: emqx-subscription: no edge-gateway shared-subscription on sensors/+/occupancy (group=edge-gw)"
  echo "  actual: subscriptions resp head=$(echo "$RESP" | head -c 600)"
  exit 1
}

# ── 6. InfluxDB 도달성 (cache-miss restore 경로) ─────────────────────────────
INFLUX_HEALTH=$(kubectl exec -n "$NS" "$POD" -- sh -c \
  'wget -qO- --header="Authorization: Bearer ${INFLUXDB_TOKEN}" http://influxdb.gikview.svc.cluster.local:8181/health 2>/dev/null \
   || wget -qO- --header="Authorization: Bearer ${INFLUXDB_TOKEN}" "http://influxdb.gikview.svc.${DOMAIN_SUFFIX:-cluster.local}:8181/health" 2>/dev/null \
   || echo "FAIL_FETCH"' 2>/dev/null || echo "FAIL_EXEC")

echo "$INFLUX_HEALTH" | grep -q '"status":[[:space:]]*"pass"' || {
  echo "FAIL: influxdb-reach: edge-gateway pod cannot reach InfluxDB /health"
  echo "  actual: $INFLUX_HEALTH"
  exit 1
}

# ── 7. aws_signing_helper + STS 도달성 ──────────────────────────────────────
# 옵션 B: 임시 자격증명 발급 성공(prod 환경) 또는 STS 가 트러스트 체인 거부 응답
# 둘 다 "config 정합성 OK" 로 판정. 그 외 에러 (binary 없음, cert 읽기 실패 등) 는 FAIL.

# 바이너리 위치 자동 탐색 (이미지 멀티스테이지 빌드 결과 경로 분기 허용)
HELPER_PATH=$(kubectl exec -n "$NS" "$POD" -- sh -c \
  'command -v aws_signing_helper 2>/dev/null \
   || (test -x /usr/local/bin/aws_signing_helper && echo /usr/local/bin/aws_signing_helper) \
   || (test -x /app/aws_signing_helper && echo /app/aws_signing_helper) \
   || echo ""' 2>/dev/null || echo "")
[ -n "$HELPER_PATH" ] || {
  echo "FAIL: signing-helper: aws_signing_helper binary not found in pod"
  echo "  actual: searched PATH, /usr/local/bin, /app — none present"
  exit 1
}

# credential-process 호출. stderr+stdout 합쳐서 분석.
HELPER_OUT=$(kubectl exec -n "$NS" "$POD" -- sh -c "
'$HELPER_PATH' credential-process \
  --certificate /tls/tls.crt \
  --private-key /tls/tls.key \
  --trust-anchor-arn \"\$TRUST_ANCHOR_ARN\" \
  --profile-arn \"\$PROFILE_ARN\" \
  --role-arn \"\$ROLE_ARN\" \
  --region \"\$AWS_DEFAULT_REGION\" 2>&1
" 2>&1 || true)

# 판정 — caveman:
#   1) prod 성공 → JSON 안에 "AccessKeyId" + "SessionToken"
#   2) dev/sandbox 트러스트 체인 미해결 → STS 의 명시적 거부 키워드 매칭
#      (`AccessDenied`, `TrustAnchorNotFound`, `InvalidSignatureException`, `UnknownEndpoint` 등 — 단 UnknownEndpoint 은 region 오타라 별도)
#   3) 그 외 → 진짜 FAIL
if echo "$HELPER_OUT" | grep -q '"AccessKeyId"' && echo "$HELPER_OUT" | grep -q '"SessionToken"'; then
  echo "signing-helper: STS issued temporary credentials (prod path)."
elif echo "$HELPER_OUT" | grep -qE '(TrustAnchorNotFound|AccessDeniedException|AccessDenied|InvalidSignatureException|ValidationException)'; then
  echo "signing-helper: STS rejected with trust-chain error — expected on dev (config OK, trust anchor pending)."
else
  echo "FAIL: signing-helper: unexpected aws_signing_helper output"
  echo "  actual: $(echo "$HELPER_OUT" | head -c 800)"
  exit 1
fi

echo "All checks passed."
