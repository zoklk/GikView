#!/usr/bin/env bash
# smoke-test-step-issuer.sh
# Phase  : security
# Service: step-issuer
#
# 검증 범위: step-issuer controller 가동 + StepClusterIssuer 리소스가 구조적으로 올바름
#            (url=step-ca ClusterIP, provisioner=admin, caBundle=파싱 가능한 PEM).
# 주의:      per-service 배포 시점엔 step-ca 가 아직 안 떠 있을 수 있음
#            → step-ca svc 가 존재할 때만 status Ready 단정. PKI 체인 e2e 는
#            smoke-test-step-ca.sh #7 (체인 마지막 링크) 에서.

set -euo pipefail
NS="${NAMESPACE:?NAMESPACE env not injected by runtime}"

# ── 1. CRD 존재 ──────────────────────────────────────────────────────────────
kubectl get crd stepclusterissuers.certmanager.step.sm >/dev/null 2>&1 || {
  echo "FAIL: crd: stepclusterissuers.certmanager.step.sm not installed"
  echo "  actual: kubectl get crd returned not found"
  exit 1
}

# ── 2. controller Deployment available, replica >=1 ──────────────────────────
DEP=$(kubectl get deploy -n "$NS" -l app.kubernetes.io/name=step-issuer \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
[ -n "$DEP" ] || DEP=$(kubectl get deploy -n "$NS" -o name 2>/dev/null \
        | grep -i step-issuer | head -1 | sed 's#deployment.apps/##' || echo "")
[ -n "$DEP" ] || {
  echo "FAIL: deployment: step-issuer controller Deployment not found in $NS"
  echo "  actual: deployments=$(kubectl get deploy -n "$NS" -o name 2>/dev/null | tr '\n' ' ')"
  exit 1
}
AVAIL=$(kubectl get deploy "$DEP" -n "$NS" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)
[ "${AVAIL:-0}" -ge 1 ] || {
  echo "FAIL: deployment: step-issuer '$DEP' has no available replicas"
  echo "  actual: availableReplicas=${AVAIL:-0}"
  exit 1
}

# ── 3. StepClusterIssuer 리소스 ─────────────────────────────────────────────
SCI=$(kubectl get stepclusterissuer -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
[ -n "$SCI" ] || {
  echo "FAIL: stepclusterissuer: no StepClusterIssuer resource declared"
  echo "  actual: kubectl get stepclusterissuer returned empty"
  exit 1
}
SCI_JSON=$(kubectl get stepclusterissuer "$SCI" -o json 2>/dev/null || echo '{}')

# 빈 필드는 '-' 로 출력해 read 의 필드 밀림을 막음
read -r URL PROV CABUNDLE_LEN <<EOF
$(printf '%s' "$SCI_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin).get('spec', {})
url = d.get('url', '') or '-'
prov = d.get('provisioner', {}).get('name', '') or '-'
cab = d.get('caBundle', '') or ''
print(url, prov, len(cab))
" 2>/dev/null || echo "- - 0")
EOF

printf '%s' "$URL" | grep -q "step-ca\|step-certificates" || {
  echo "FAIL: stepclusterissuer: spec.url does not point at the step-ca service"
  echo "  actual: url=$URL"
  exit 1
}
[ "$PROV" = "admin" ] || {
  echo "FAIL: stepclusterissuer: spec.provisioner.name expected 'admin'"
  echo "  actual: provisioner.name=$PROV"
  exit 1
}
[ "${CABUNDLE_LEN:-0}" -gt 0 ] || {
  echo "FAIL: stepclusterissuer: spec.caBundle is empty"
  echo "  actual: caBundle length=${CABUNDLE_LEN:-0}"
  exit 1
}

# ── 4. caBundle 가 파싱 가능한 PEM 인증서인지 (placeholder/오타 방지) ────────
CA_PEM=$(printf '%s' "$SCI_JSON" | python3 -c "
import sys, json, base64
cab = json.load(sys.stdin).get('spec', {}).get('caBundle', '')
sys.stdout.write(base64.b64decode(cab).decode('utf-8', 'replace'))
" 2>/dev/null || echo "")
printf '%s' "$CA_PEM" | grep -q "BEGIN CERTIFICATE" || {
  echo "FAIL: stepclusterissuer: caBundle does not base64-decode to a PEM certificate"
  echo "  actual: head=$(printf '%s' "$CA_PEM" | head -c 60)"
  exit 1
}
printf '%s' "$CA_PEM" | openssl x509 -noout -subject >/dev/null 2>/tmp/sci_x509_err || {
  echo "FAIL: stepclusterissuer: caBundle PEM is not a parseable X.509 certificate"
  echo "  actual: openssl: $(cat /tmp/sci_x509_err 2>/dev/null)"
  exit 1
}

# ── 5. (조건부) step-ca svc 가 이미 있으면 status Ready 확인 ─────────────────
if kubectl get svc -n "$NS" step-ca >/dev/null 2>&1 \
   || kubectl get svc -n "$NS" -l app.kubernetes.io/name=step-certificates -o name 2>/dev/null | grep -q . \
   || kubectl get svc -n "$NS" -l app=step-certificates -o name 2>/dev/null | grep -q . \
   || kubectl get svc -n "$NS" -o name 2>/dev/null | grep -qiE 'step-ca|step-certificates'; then
  STATUS=""
  for i in $(seq 1 6); do
    STATUS=$(kubectl get stepclusterissuer "$SCI" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    [ "$STATUS" = "True" ] && break
    echo "attempt $i/6: StepClusterIssuer Ready=$STATUS, waiting 5s..."
    sleep 5
  done
  [ "$STATUS" = "True" ] || {
    echo "FAIL: stepclusterissuer: step-ca is deployed but StepClusterIssuer is not Ready"
    echo "  actual: Ready=$STATUS, conditions=$(kubectl get stepclusterissuer "$SCI" -o jsonpath='{.status.conditions}' 2>/dev/null)"
    exit 1
  }
else
  echo "note: step-ca service not yet deployed in $NS — skipping StepClusterIssuer readiness assertion (verified by smoke-test-step-ca.sh)"
fi

echo "All checks passed."
