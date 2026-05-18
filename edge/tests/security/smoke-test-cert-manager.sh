#!/usr/bin/env bash
# smoke-test-cert-manager.sh
# Phase  : security
# Service: cert-manager
#
# 검증 범위: cert-manager CRD 설치 + webhook/controller 가 실제로 인증서를 발급하는지
#            (SelfSigned ClusterIssuer 로 cert-manager 자체만 end-to-end).
# 범위 외:   step-issuer / step-ca 연동 (→ smoke-test-step-ca.sh #7 키스톤).

set -euo pipefail
NS="${NAMESPACE:?NAMESPACE env not injected by runtime}"

SUF="cm-$$"
CI_NAME="smoke-selfsigned-${SUF}"
CERT_NAME="smoke-cm-cert-${SUF}"
SECRET_NAME="smoke-cm-tls-${SUF}"

cleanup() {
  kubectl delete certificate "$CERT_NAME" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete clusterissuer "$CI_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete secret "$SECRET_NAME" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM   # 120s 타임아웃 SIGTERM 시에도 잔존 리소스(특히 cluster-scoped ClusterIssuer) 정리

# ── 1. CRD 존재 ──────────────────────────────────────────────────────────────
MISSING=""
for crd in certificates.cert-manager.io issuers.cert-manager.io \
           clusterissuers.cert-manager.io certificaterequests.cert-manager.io; do
  kubectl get crd "$crd" >/dev/null 2>&1 || MISSING="$MISSING $crd"
done
[ -z "$MISSING" ] || {
  echo "FAIL: crd: required cert-manager CRDs not installed"
  echo "  actual: missing:$MISSING"
  exit 1
}

# ── 2. 기능 검증: SelfSigned ClusterIssuer + Certificate → Ready → Secret ────
# pod Ready 직후에도 cainjector 가 webhook caBundle 를 막 주입한 상태라
# apply 가 webhook 에 거부될 수 있음 → 짧게 retry.
MANIFEST=$(cat <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${CI_NAME}
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${CERT_NAME}
  namespace: ${NS}
spec:
  secretName: ${SECRET_NAME}
  duration: 1h
  commonName: smoke-cm.${NS}.svc.cluster.local
  dnsNames:
    - smoke-cm.${NS}.svc.cluster.local
  issuerRef:
    name: ${CI_NAME}
    kind: ClusterIssuer
EOF
)

APPLIED=""
APPLY_OUT=""
for i in $(seq 1 6); do
  APPLY_OUT=$(printf '%s\n' "$MANIFEST" | kubectl apply -f - 2>&1) && { APPLIED=1; break; }
  echo "attempt $i/6: apply rejected (webhook not ready?), waiting 5s..."
  sleep 5
done
[ -n "$APPLIED" ] || {
  echo "FAIL: apply: could not apply SelfSigned ClusterIssuer + Certificate after 30s"
  echo "  actual: $APPLY_OUT"
  exit 1
}

# Certificate Ready 대기: 최대 12 × 5s = 60s
READY=""
for i in $(seq 1 12); do
  S=$(kubectl get certificate "$CERT_NAME" -n "$NS" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  [ "$S" = "True" ] && { READY=1; break; }
  echo "attempt $i/12: Certificate Ready=$S, waiting 5s..."
  sleep 5
done
[ -n "$READY" ] || {
  COND=$(kubectl get certificate "$CERT_NAME" -n "$NS" -o jsonpath='{.status.conditions}' 2>/dev/null || echo "")
  EV=$(kubectl get events -n "$NS" --field-selector involvedObject.name="$CERT_NAME" \
        -o jsonpath='{range .items[*]}{.reason}: {.message}{"\n"}{end}' 2>/dev/null | tail -5 || echo "")
  echo "FAIL: certificate: Certificate '$CERT_NAME' not Ready after 60s"
  echo "  actual: conditions=$COND ; events=$EV"
  exit 1
}

# Secret 에 tls.crt / tls.key 존재
CRT=$(kubectl get secret "$SECRET_NAME" -n "$NS" -o jsonpath='{.data.tls\.crt}' 2>/dev/null || echo "")
KEY=$(kubectl get secret "$SECRET_NAME" -n "$NS" -o jsonpath='{.data.tls\.key}' 2>/dev/null || echo "")
{ [ -n "$CRT" ] && [ -n "$KEY" ]; } || {
  echo "FAIL: secret: '$SECRET_NAME' missing tls.crt or tls.key"
  echo "  actual: tls.crt_empty=$([ -z "$CRT" ] && echo yes || echo no), tls.key_empty=$([ -z "$KEY" ] && echo yes || echo no)"
  exit 1
}

echo "All checks passed."
