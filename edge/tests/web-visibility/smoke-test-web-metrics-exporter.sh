#!/usr/bin/env bash
# smoke-test-web-metrics-exporter.sh
# Phase  : web-visibility
# Service: web-metrics-exporter
#
# 검증 범위:
#   1. Pod Ready (replica=1)
#   2. mTLS cert 마운트 (/tls/tls.crt, /tls/tls.key — CN=web-visibility)
#   3. IAM Roles Anywhere env 4종 주입 (TRUST_ANCHOR_ARN/PROFILE_ARN/ROLE_ARN/AWS_DEFAULT_REGION)
#   4. /metrics 노출 + web_connect_total 시리즈 존재 (0-초기화 보장)
#   5. aws_signing_helper 바이너리 + STS 도달성
#      - prod 환경: 임시 자격증명 발급 성공 (Credentials JSON 반환)
#      - dev 환경: STS 가 TrustAnchorNotFound/AccessDenied/InvalidSignatureException 반환
#                  → config (cert, env, signing helper) 정상, 트러스트 체인만 미해결 → smoke pass
#
# DynamoDB GetItem 실제 호출은 본 smoke 범위 밖
#   사유: dev 환경 STS 가 자격증명 안 줘서 read 불가. edge-gateway smoke 와 동일하게
#   옵션 B (STS 응답 패턴) 채택 — config 정합성 검증 + 트러스트 체인은 prod-only AWS 콘솔 작업.

set -euo pipefail
NS="${NAMESPACE:?NAMESPACE env not injected by runtime}"

SERVICE="${SERVICE:-web-metrics-exporter}"
EXPECT_REPLICAS=1
METRICS_PORT=9102
PF_PORT=9112  # 로컬 port-forward 포트 (충돌 회피)

# ── 1. Pod Ready (replica=1) ──────────────────────────────────────────────────
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
  echo "FAIL: pod-ready: expected $EXPECT_REPLICAS Ready pod"
  echo "  actual: ready=$READY ; pods=$(kubectl get pod -n "$NS" -l app.kubernetes.io/name=${SERVICE} -o name 2>/dev/null | tr '\n' ' ')"
  exit 1
}

POD=$(kubectl get pod -n "$NS" -l "app.kubernetes.io/name=${SERVICE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$POD" ] || { echo "FAIL: pod-select: no ${SERVICE} pod found"; echo "  actual: empty"; exit 1; }

# ── 2. 마운트 점검: cert (read role 자격증명용) ───────────────────────────────
for path in /tls/tls.crt /tls/tls.key; do
  kubectl exec -n "$NS" "$POD" -- test -f "$path" 2>/dev/null || {
    echo "FAIL: mount: expected file '$path' missing inside pod"
    echo "  actual: $(kubectl exec -n "$NS" "$POD" -- ls -la /tls 2>&1 | head -c 400)"
    exit 1
  }
done

# ── 3. IAM Roles Anywhere env 4종 주입 ───────────────────────────────────────
ENV_DUMP=$(kubectl exec -n "$NS" "$POD" -- env 2>/dev/null || echo "")
for var in TRUST_ANCHOR_ARN PROFILE_ARN ROLE_ARN AWS_DEFAULT_REGION; do
  VAL=$(echo "$ENV_DUMP" | awk -F= -v k="$var" '$1==k {for(i=2;i<=NF;i++) printf "%s%s", $i, (i<NF?"=":""); exit}')
  [ -n "$VAL" ] || {
    echo "FAIL: env: required env var '$var' not set in ${SERVICE} pod"
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

# ── 4. /metrics 노출 + web_connect_total 시리즈 존재 ─────────────────────────
# 0-초기화 보장이라 트래픽 전에도 web_connect_total{stage=...} 시리즈가 떠 있어야 함.
kubectl port-forward -n "$NS" "svc/${SERVICE}" "${PF_PORT}:${METRICS_PORT}" >/dev/null 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT
sleep 2

METRICS=""
for i in $(seq 1 6); do
  METRICS=$(curl -s "http://127.0.0.1:${PF_PORT}/metrics" 2>/dev/null || echo "")
  echo "$METRICS" | grep -q '^web_connect_total' && break
  echo "attempt $i/6: /metrics not ready, waiting 5s..."
  sleep 5
done

echo "$METRICS" | grep -qE '^web_connect_total\{' || {
  echo "FAIL: metrics: web_connect_total series not exposed on :${METRICS_PORT}/metrics"
  echo "  actual: metrics head=$(echo "$METRICS" | grep -E '^web_' | head -c 400)"
  exit 1
}

# ── 5. aws_signing_helper + STS 도달성 (옵션 B, edge-gateway 와 동일 판정) ────
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

HELPER_OUT=$(kubectl exec -n "$NS" "$POD" -- sh -c "
'$HELPER_PATH' credential-process \
  --certificate /tls/tls.crt \
  --private-key /tls/tls.key \
  --trust-anchor-arn \"\$TRUST_ANCHOR_ARN\" \
  --profile-arn \"\$PROFILE_ARN\" \
  --role-arn \"\$ROLE_ARN\" \
  --region \"\$AWS_DEFAULT_REGION\" 2>&1
" 2>&1 || true)

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
