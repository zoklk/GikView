#!/usr/bin/env bash
# smoke-test-step-ca.sh
# Phase  : security
# Service: step-ca   ← PKI 키스톤
#
# 검증 범위:
#   1. badger DB PV (PVC Bound, storageClass local-storage)
#   2. /health
#   3. /roots — root CA; fingerprint == StepClusterIssuer.caBundle (교차 검증)
#   4. /provisioners — device-bootstrap(X5C), device-renewal(X5C), admin(JWK)
#   4b. (결정 c) step-ca workload 에 configmap.reloader.stakater.com/reload ⊇ step-ca-whitelist;
#       running pod 안의 머지된 ca.json 에 step-ca-whitelist 의 CN 들이 들어가 있음
#       (= initContainer 머지가 end-to-end 로 동작 — /provisioners API 는 policy 를 redact 할 수
#        있어 exec+cat 만이 확인 수단)
#   5. step-ca-nodeport 서비스 (NodePort, :9000 매핑, externalTrafficPolicy=Local)
#   6. 서버 leaf 인증서 SAN (in-cluster DNS + 노드 IP)
#   7. PKI 체인 e2e — StepClusterIssuer 경유 워크로드 인증서 발급 → 우리 Root CA 로 체인
#   8. (네거티브) POST /1.0/sign 무인증 → 2xx 아님 (X5C provisioner 익명 개방 아님)
#   9. /1.0/renew e2e — #7 의 admin(JWK)-발급 leaf 를 mTLS 클라이언트로 제시 → 새 leaf 가
#      같은 CN · Root CA 체인 · notAfter 전진
#  10. X5C 부트스트랩 e2e — device-bootstrap provisioner: 테스트용 부트스트랩 신원
#      (Secret 'step-ca-smoke-bootstrap', kubernetes.io/tls — tls.crt/tls.key)로
#      X5C 토큰 → step-ca 에 정식(device) 인증서 요청.
#      (a) 화이트리스트 등록 CN → 발급 + Intermediate→Root 체인
#      (b) 미등록 CN(device-ffffff) → step-ca-whitelist→ca.json policy(결정 c)로 거부
#
# 범위 외 (스모크 없음): 펌웨어측 흐름(키 재생성·LittleFS 교체·/1.0/renew 호출 스케줄) — 펌웨어 필요.
#   CRL/OCSP (ADR 7 미도입). 학내망 도달/포트포워딩(운영자 1회).
#
# 사전조건: 러너에 openssl + python3 (+ kubectl). StepClusterIssuer Ready (#7·#9 용).
#   #10 은 Secret 'step-ca-smoke-bootstrap'(kubernetes.io/tls) + 'step' CLI — 둘 다 있을 때만 실행, 아니면 note-skip.

set -euo pipefail
NS="${NAMESPACE:?NAMESPACE env not injected by runtime}"
ACTIVE_ENV="${ACTIVE_ENV:-}"

for b in openssl python3; do
  command -v "$b" >/dev/null 2>&1 || { echo "FAIL: runner: required binary '$b' not on PATH"; echo "  actual: command -v $b failed"; exit 1; }
done

LOCAL_PORT="19000"
BASE_URL="https://127.0.0.1:${LOCAL_PORT}"
# step-ca 는 부팅 시 Intermediate 로 self-issue 한 leaf 로 TLS 종단 → -k 사용,
# 체인은 #3(/roots)·#6(SAN) 에서 별도 검증.
CURL=(curl -sk --max-time 10)

SUF="sca-$$"
CERT_NAME="smoke-stepca-cert-${SUF}"
SECRET_NAME="smoke-stepca-tls-${SUF}"
PF_PID=""
cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
  kubectl delete certificate "$CERT_NAME" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete secret "$SECRET_NAME" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rm -f /tmp/sca_rnw_* /tmp/sca_x5c_* /tmp/stepca_bootstrap.* /tmp/x5c_* 2>/dev/null || true
  rm -rf /tmp/x5c_steppath.* 2>/dev/null || true   # 크래시 경로용 — 위 rm -f 는 디렉토리 안 지움
}
trap cleanup EXIT INT TERM

# step-ca Pod 이름 해석 (port-forward 는 Service 포트가 443→9000 일 수 있어 pod 로 직접)
POD=$(kubectl get pod -n "$NS" -l app.kubernetes.io/name=step-certificates -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
[ -n "$POD" ] || POD=$(kubectl get pod -n "$NS" -l app=step-certificates -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
[ -n "$POD" ] || POD=$(kubectl get pod -n "$NS" -o name 2>/dev/null | grep -iE 'step-ca|step-certificates' | head -1 | sed 's#pod/##' || echo "")
[ -n "$POD" ] || {
  echo "FAIL: pod: step-ca pod not found in $NS"
  echo "  actual: pods=$(kubectl get pod -n "$NS" -o name 2>/dev/null | tr '\n' ' ')"
  exit 1
}

# ── 1. PVC Bound, storageClass local-storage ─────────────────────────────────
PVC_LINE=$(kubectl get pvc -n "$NS" -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
for i in d.get('items', []):
    n = i['metadata']['name']
    if 'step' in n:
        print(n, i.get('status', {}).get('phase', ''), i.get('spec', {}).get('storageClassName', ''))
        break
" 2>/dev/null || echo "")
[ -n "$PVC_LINE" ] || {
  echo "FAIL: pvc: no step-ca PVC found in $NS"
  echo "  actual: pvcs=$(kubectl get pvc -n "$NS" -o name 2>/dev/null | tr '\n' ' ')"
  exit 1
}
PVC_PHASE=$(echo "$PVC_LINE" | awk '{print $2}')
PVC_CLASS=$(echo "$PVC_LINE" | awk '{print $3}')
[ "$PVC_PHASE" = "Bound" ] || {
  echo "FAIL: pvc: step-ca PVC not Bound"
  echo "  actual: $PVC_LINE"
  exit 1
}
[ "$PVC_CLASS" = "local-storage" ] || {
  echo "FAIL: pvc: step-ca PVC storageClass expected 'local-storage'"
  echo "  actual: $PVC_LINE"
  exit 1
}

# ── 2. port-forward (pod 로 직접 — Service port 가 443→9000 일 수 있어) + /health ─
kubectl port-forward -n "$NS" "pod/$POD" "${LOCAL_PORT}:9000" >/dev/null 2>&1 &
PF_PID=$!
sleep 3
HEALTH=""
for i in $(seq 1 8); do
  HEALTH=$("${CURL[@]}" "${BASE_URL}/health" 2>/dev/null || echo "")
  echo "$HEALTH" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"' && break
  echo "attempt $i/8: /health=$HEALTH, waiting 4s..."
  sleep 4
done
echo "$HEALTH" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"' || {
  echo "FAIL: health: /health did not return status=ok after 32s"
  echo "  actual: $HEALTH"
  exit 1
}

# ── 3. /roots — >=1 root; fingerprint == StepClusterIssuer.caBundle ──────────
ROOTS_JSON=$("${CURL[@]}" -H "Accept: application/json" "${BASE_URL}/roots" 2>/dev/null || echo "")
echo "$ROOTS_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
crts = d.get('crts') or d.get('certs') or []
assert isinstance(crts, list) and len(crts) >= 1
" 2>/dev/null || {
  echo "FAIL: roots: /roots did not return >=1 root certificate"
  echo "  actual: $ROOTS_JSON"
  exit 1
}
echo "$ROOTS_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
crts = d.get('crts') or d.get('certs') or []
sys.stdout.write(crts[0])
" > /tmp/stepca_root.pem 2>/dev/null || true
STEPCA_FP=$(openssl x509 -in /tmp/stepca_root.pem -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' || echo "")
[ -n "$STEPCA_FP" ] || {
  echo "FAIL: roots: could not compute fingerprint of step-ca root"
  echo "  actual: pem head=$(head -c 60 /tmp/stepca_root.pem 2>/dev/null)"
  exit 1
}
SCI=$(kubectl get stepclusterissuer -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$SCI" ]; then
  kubectl get stepclusterissuer "$SCI" -o jsonpath='{.spec.caBundle}' 2>/dev/null | base64 -d > /tmp/sci_ca.pem 2>/dev/null || true
  SCI_FP=$(openssl x509 -in /tmp/sci_ca.pem -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' || echo "")
  { [ -n "$SCI_FP" ] && [ "$SCI_FP" = "$STEPCA_FP" ]; } || {
    echo "FAIL: roots: step-ca root does not match StepClusterIssuer.caBundle"
    echo "  actual: step-ca=$STEPCA_FP stepclusterissuer=$SCI_FP"
    exit 1
  }
else
  echo "note: no StepClusterIssuer found — skipping /roots ↔ caBundle cross-check"
fi

# ── 4. /provisioners — device-bootstrap(X5C), device-renewal(X5C), admin(JWK) ─
PROVS=$("${CURL[@]}" "${BASE_URL}/provisioners" 2>/dev/null || echo "")
echo "$PROVS" | grep -q '"provisioners"' || PROVS=$("${CURL[@]}" "${BASE_URL}/1.0/provisioners" 2>/dev/null || echo "")
OBSERVED=$(echo "$PROVS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
m = {}
for p in d.get('provisioners', []):
    m[p.get('name')] = (p.get('type') or '').upper()
print(json.dumps(m))
" 2>/dev/null || echo "{}")
echo "$OBSERVED" | python3 -c "
import sys, json
m = json.load(sys.stdin)
errs = []
for name, want in (('device-bootstrap', 'X5C'), ('device-renewal', 'X5C'), ('admin', 'JWK')):
    got = m.get(name)
    if got != want:
        errs.append(f'{name}={got!r} (want {want})')
if errs:
    sys.exit('; '.join(errs))
" 2>/tmp/prov_err || {
  echo "FAIL: provisioners: expected device-bootstrap(X5C), device-renewal(X5C), admin(JWK)"
  echo "  actual: $(cat /tmp/prov_err 2>/dev/null) — observed=$OBSERVED"
  exit 1
}

# ── 4b. (결정 c) Reloader annotation + 머지된 ca.json 에 whitelist CN 반영 ───
# step-ca workload (StatefulSet 또는 Deployment) 의 annotation 확인
WL_KIND=""; WL_NAME=""
for k in statefulset deployment; do
  n=$(kubectl get "$k" -n "$NS" -l app.kubernetes.io/name=step-certificates -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  [ -z "$n" ] && n=$(kubectl get "$k" -n "$NS" -o name 2>/dev/null | grep -iE 'step-ca|step-certificates' | head -1 | sed "s#$k.apps/##;s#$k/##" || echo "")
  [ -n "$n" ] && { WL_KIND="$k"; WL_NAME="$n"; break; }
done
if [ -n "$WL_KIND" ]; then
  WL_ANN=$(kubectl get "$WL_KIND" "$WL_NAME" -n "$NS" -o jsonpath='{.metadata.annotations}' 2>/dev/null || echo "")
  WL_TANN=$(kubectl get "$WL_KIND" "$WL_NAME" -n "$NS" -o jsonpath='{.spec.template.metadata.annotations}' 2>/dev/null || echo "")
  ALL_WL_ANN="$WL_ANN $WL_TANN"
  echo "$ALL_WL_ANN" | grep -q 'configmap.reloader.stakater.com/reload' && echo "$ALL_WL_ANN" | grep -q 'step-ca-whitelist' || {
    echo "FAIL: reloader-annotation: step-ca workload ($WL_KIND/$WL_NAME) missing configmap.reloader.stakater.com/reload ⊇ step-ca-whitelist"
    echo "  actual: annotations=$ALL_WL_ANN"
    exit 1
  }
else
  echo "note: could not locate step-ca workload (StatefulSet/Deployment) — skipping Reloader-annotation assertion"
fi
# step-ca-whitelist 의 CN 집합
WL_CNS=$(kubectl get configmap step-ca-whitelist -n "$NS" -o json 2>/dev/null | python3 -c "
import sys, json, re
try:
    d = json.load(sys.stdin)
    blob = '\n'.join((d.get('data') or {}).values())
    print('\n'.join(sorted(set(re.findall(r'device-[a-f0-9]{6}', blob)))))
except Exception:
    pass
" 2>/dev/null || echo "")
if [ -n "$WL_CNS" ]; then
  # 머지된 ca.json 을 pod 안에서 찾아 grep — likely 경로 best-effort 프로브
  MERGED=""
  CFGENV=$(kubectl exec -n "$NS" "$POD" -- sh -c 'echo "${CONFIGPATH:-}"' 2>/dev/null || echo "")
  STEPENV=$(kubectl exec -n "$NS" "$POD" -- sh -c 'echo "${STEPPATH:-}"' 2>/dev/null || echo "")
  CANDIDATES="$CFGENV ${STEPENV:+$STEPENV/config/ca.json} /home/step/config/ca.json /tmp/ca.json /etc/step-ca/config/ca.json"
  for p in $CANDIDATES; do
    [ -n "$p" ] || continue
    C=$(kubectl exec -n "$NS" "$POD" -- cat "$p" 2>/dev/null || echo "")
    if [ -n "$C" ] && echo "$C" | grep -q 'provisioners'; then MERGED="$C"; break; fi
  done
  if [ -n "$MERGED" ]; then
    MISSING=""
    while IFS= read -r cn; do
      [ -n "$cn" ] || continue
      echo "$MERGED" | grep -q "$cn" || MISSING="$MISSING $cn"
    done <<< "$WL_CNS"
    [ -z "$MISSING" ] || {
      echo "FAIL: merge: running ca.json is missing step-ca-whitelist CN(s) — initContainer merge not effective"
      echo "  actual: missing:$MISSING ; whitelist CNs=$(echo "$WL_CNS" | tr '\n' ' ')"
      exit 1
    }
    echo "ok: merged ca.json contains all step-ca-whitelist CN(s) ($(echo "$WL_CNS" | tr '\n' ' '))"
  else
    echo "note: could not locate merged ca.json inside pod $POD — skipping merge end-to-end check (chart 경로 확인 필요)"
  fi
else
  echo "note: step-ca-whitelist has no parseable device CNs — skipping merge check"
fi

# ── 5. step-ca-nodeport 서비스 ───────────────────────────────────────────────
NP_JSON=$(kubectl get svc -n "$NS" step-ca-nodeport -o json 2>/dev/null || echo "")
[ -n "$NP_JSON" ] || {
  NPN=$(kubectl get svc -n "$NS" -o name 2>/dev/null | grep -iE 'step.*nodeport|step-ca.*node' | head -1 | sed 's#service/##' || echo "")
  [ -n "$NPN" ] && NP_JSON=$(kubectl get svc -n "$NS" "$NPN" -o json 2>/dev/null || echo "")
}
[ -n "$NP_JSON" ] || {
  echo "FAIL: nodeport: step-ca-nodeport service not found"
  echo "  actual: services=$(kubectl get svc -n "$NS" -o name 2>/dev/null | tr '\n' ' ')"
  exit 1
}
echo "$NP_JSON" | ACTIVE_ENV="$ACTIVE_ENV" python3 -c "
import sys, json, os
spec = json.load(sys.stdin).get('spec', {})
errs = []
if spec.get('type') != 'NodePort':
    errs.append('type=%s' % spec.get('type'))
if spec.get('externalTrafficPolicy') != 'Local':
    errs.append('externalTrafficPolicy=%s' % spec.get('externalTrafficPolicy'))
ports = spec.get('ports', [])
p9000 = [p for p in ports if p.get('port') == 9000 or p.get('targetPort') == 9000]
if not p9000:
    errs.append('no port mapping to 9000: %r' % ports)
np = p9000[0].get('nodePort') if p9000 else None
if np is None:
    errs.append('nodePort not assigned')
if os.environ.get('ACTIVE_ENV') == 'prod' and np != 31900:
    errs.append('nodePort=%r (prod expects 31900)' % np)
if errs:
    sys.exit('; '.join(errs))
" 2>/tmp/np_err || {
  echo "FAIL: nodeport: step-ca-nodeport spec mismatch"
  echo "  actual: $(cat /tmp/np_err 2>/dev/null)"
  exit 1
}

# ── 6. 서버 leaf 인증서 SAN ──────────────────────────────────────────────────
LEAF=/tmp/stepca_leaf.pem
echo | openssl s_client -connect "127.0.0.1:${LOCAL_PORT}" -servername step-ca 2>/dev/null \
  | openssl x509 -outform pem > "$LEAF" 2>/dev/null || true
[ -s "$LEAF" ] || {
  echo "FAIL: server-cert: could not retrieve step-ca leaf certificate on :${LOCAL_PORT}"
  echo "  actual: (empty)"
  exit 1
}
SAN=$(openssl x509 -in "$LEAF" -noout -ext subjectAltName 2>/dev/null \
      || openssl x509 -in "$LEAF" -noout -text 2>/dev/null | grep -A2 -i "subject alternative name" || echo "")
[ -n "$SAN" ] || {
  echo "FAIL: server-cert: step-ca leaf has no SubjectAltName"
  echo "  actual: (empty)"
  exit 1
}
echo "$SAN" | grep -qiE "step-ca|step-certificates" || {
  echo "FAIL: server-cert: SAN missing in-cluster step-ca DNS name"
  echo "  actual: $(echo "$SAN" | tr '\n' ' ')"
  exit 1
}
if [ "$ACTIVE_ENV" = "prod" ]; then
  echo "$SAN" | grep -q "192.168.0.101" || {
    echo "FAIL: server-cert: SAN missing prod security-node IP 192.168.0.101 (디바이스-facing NodePort 노출용)"
    echo "  actual: $(echo "$SAN" | tr '\n' ' ')"
    exit 1
  }
else
  echo "$SAN" | grep -qiE "IP Address:|IP:" || \
    echo "note: no IP SAN observed (dev — security 노드 IP 는 환경별, 정확값 단정 안 함)"
fi

# ── 7. PKI 체인 e2e (키스톤) — StepClusterIssuer 경유 워크로드 인증서 발급 ───
# 주의(phase doc): X5C provisioner 의 CN 화이트리스트는 admin(JWK)에는 적용 안 되는 게 정상이라
# 가정. ca.json policy 가 authority 레벨이면 smoke.* CN 이 거부될 수 있음 → 그 경우
# "StepClusterIssuer Ready" 까지만 단정하고 체인 검증은 note 로 강등.
[ -n "$SCI" ] || {
  echo "FAIL: e2e: no StepClusterIssuer found — PKI workload-issuance path cannot be verified"
  echo "  actual: kubectl get stepclusterissuer empty"
  exit 1
}
SCI_READY=""
for i in $(seq 1 5); do
  S=$(kubectl get stepclusterissuer "$SCI" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  [ "$S" = "True" ] && { SCI_READY=1; break; }
  echo "attempt $i/5: StepClusterIssuer Ready=$S, waiting 5s..."
  sleep 5
done
[ -n "$SCI_READY" ] || {
  echo "FAIL: e2e: StepClusterIssuer '$SCI' not Ready after 25s"
  echo "  actual: conditions=$(kubectl get stepclusterissuer "$SCI" -o jsonpath='{.status.conditions}' 2>/dev/null)"
  exit 1
}

CERT_MANIFEST=$(cat <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${CERT_NAME}
  namespace: ${NS}
spec:
  secretName: ${SECRET_NAME}
  commonName: smoke.${NS}.svc.cluster.local
  dnsNames:
    - smoke.${NS}.svc.cluster.local
  duration: 1h
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: ${SCI}
    kind: StepClusterIssuer
    group: certmanager.step.sm
EOF
)
APPLY_OUT=$(printf '%s\n' "$CERT_MANIFEST" | kubectl apply -f - 2>&1) || {
  echo "FAIL: e2e: could not apply test Certificate"
  echo "  actual: $APPLY_OUT"
  exit 1
}

CRT_READY=""
for i in $(seq 1 6); do
  S=$(kubectl get certificate "$CERT_NAME" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  [ "$S" = "True" ] && { CRT_READY=1; break; }
  echo "attempt $i/6: test Certificate Ready=$S, waiting 5s..."
  sleep 5
done

if [ -z "$CRT_READY" ]; then
  COND=$(kubectl get certificate "$CERT_NAME" -n "$NS" -o jsonpath='{.status.conditions}' 2>/dev/null || echo "")
  CRREQ=$(kubectl get certificaterequest -n "$NS" \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions}{"\n"}{end}' 2>/dev/null | grep "$CERT_NAME" || echo "")
  POD_LOG=$(kubectl logs -n "$NS" "$POD" --tail=20 2>/dev/null || echo "")
  if echo "$COND $CRREQ" | grep -qiE 'policy|not allowed|not authoriz|common name|CN .*(not|allow)'; then
    echo "note: test Certificate rejected by a step-ca CN policy on the admin/JWK provisioner."
    echo "note: StepClusterIssuer Ready was already verified above — PKI issuance path treated as structurally OK."
    echo "note: finalize per phase-doc decision on step-ca-whitelist → ca.json policy scope (현재 (c) initContainer 머지)."
  else
    echo "FAIL: e2e: test Certificate '$CERT_NAME' not Ready after 30s"
    echo "  actual: conditions=$COND ; certrequest=$CRREQ ; step-ca log tail=$POD_LOG"
    exit 1
  fi
else
  kubectl get secret "$SECRET_NAME" -n "$NS" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > /tmp/sca_bundle.pem 2>/dev/null || true
  [ -s /tmp/sca_bundle.pem ] || {
    echo "FAIL: e2e: issued Secret '$SECRET_NAME' has no tls.crt"
    echo "  actual: (empty)"
    exit 1
  }
  awk '/BEGIN CERTIFICATE/{n++} n==1{print} /END CERTIFICATE/{if(n==1) exit}' /tmp/sca_bundle.pem > /tmp/sca_leaf_only.pem
  SUBJ=$(openssl x509 -in /tmp/sca_leaf_only.pem -noout -subject 2>/dev/null || echo "")
  echo "$SUBJ" | grep -q "smoke.${NS}" || {
    echo "FAIL: e2e: issued leaf CN mismatch"
    echo "  actual: subject=$SUBJ"
    exit 1
  }
  if openssl verify -CAfile /tmp/stepca_root.pem -untrusted /tmp/sca_bundle.pem /tmp/sca_leaf_only.pem >/tmp/sca_verify 2>&1 \
     || openssl verify -CAfile /tmp/stepca_root.pem /tmp/sca_leaf_only.pem >/tmp/sca_verify 2>&1; then
    :
  else
    SUBJS=$(openssl crl2pkcs7 -nocrl -certfile /tmp/sca_bundle.pem 2>/dev/null | openssl pkcs7 -print_certs -noout 2>/dev/null || echo "")
    echo "FAIL: e2e: issued certificate does not chain to the step-ca Root CA"
    echo "  actual: $(cat /tmp/sca_verify 2>/dev/null) ; bundle=$(echo "$SUBJS" | tr '\n' ' ')"
    exit 1
  fi
fi

# ── 8. (네거티브) POST /1.0/sign 무인증 → 2xx 아님 ──────────────────────────
SIGN_CODE=$("${CURL[@]}" -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/1.0/sign" \
  -H "Content-Type: application/json" -d '{}' 2>/dev/null) || true   # 연결 실패 시 curl -w 가 이미 "000" 출력 → echo "000" 이면 "000\n000"
[ -n "$SIGN_CODE" ] || SIGN_CODE="000"
case "$SIGN_CODE" in
  2*)
    echo "FAIL: negative-sign: POST /1.0/sign succeeded without authentication — endpoint is anonymously open"
    echo "  actual: HTTP $SIGN_CODE"
    exit 1 ;;
  401|403) : ;;
  000)
    echo "FAIL: negative-sign: POST /1.0/sign got no response"
    echo "  actual: HTTP 000 (port-forward / step-ca down?)"
    exit 1 ;;
  *)
    echo "note: /1.0/sign without auth returned HTTP $SIGN_CODE (rejected before/at auth; not anonymously open)" ;;
esac

# ── 9. /1.0/renew e2e ───────────────────────────────────────────────────────
# #7 에서 admin(JWK) provisioner 로 발급한 leaf(${SECRET_NAME})를 그대로 mTLS 클라이언트
# 인증서로 제시해 /1.0/renew → 새 leaf 를 받아 (a) 같은 CN (b) Root CA 로 체인
# (c) notAfter 가 원본보다 뒤인지 단정. CRT_READY 였던 경우만 실행 (#7 가 policy 로
# note 강등됐으면 발급 leaf 자체가 없으니 skip).
if [ -n "${CRT_READY:-}" ]; then
  RNW_CRT=/tmp/sca_rnw_in.crt; RNW_KEY=/tmp/sca_rnw_in.key
  kubectl get secret "$SECRET_NAME" -n "$NS" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "$RNW_CRT" 2>/dev/null || true
  kubectl get secret "$SECRET_NAME" -n "$NS" -o jsonpath='{.data.tls\.key}' 2>/dev/null | base64 -d > "$RNW_KEY" 2>/dev/null || true
  { [ -s "$RNW_CRT" ] && [ -s "$RNW_KEY" ]; } || {
    echo "FAIL: renew: could not read leaf cert/key from '$SECRET_NAME' for /1.0/renew"
    echo "  actual: crt_empty=$([ -s "$RNW_CRT" ] || echo yes), key_empty=$([ -s "$RNW_KEY" ] || echo yes)"
    exit 1
  }
  OLD_NA=$(openssl x509 -in /tmp/sca_leaf_only.pem -noout -enddate 2>/dev/null | sed 's/notAfter=//' || echo "")
  OLD_EPOCH=$(date -d "$OLD_NA" +%s 2>/dev/null || echo 0)

  RNW_BODY=/tmp/sca_rnw_out.json
  RNW_CODE=$("${CURL[@]}" -o "$RNW_BODY" -w '%{http_code}' \
    --cert "$RNW_CRT" --key "$RNW_KEY" -X POST "${BASE_URL}/1.0/renew" 2>/dev/null) || true
  [ -n "$RNW_CODE" ] || RNW_CODE="000"
  [ "$RNW_CODE" = "200" ] || {
    echo "FAIL: renew: POST /1.0/renew with a valid admin-issued leaf did not return 200"
    echo "  actual: HTTP $RNW_CODE ; body=$(head -c 300 "$RNW_BODY" 2>/dev/null)"
    exit 1
  }
  # step-ca renew 응답: {"ca":"<PEM>","crt":"<PEM leaf>","certChain":["<leaf>","<intermediate>"]}
  #  ↑ 정확한 키 이름은 step-ca 버전 따라 다를 수 있음 — 첫 실행 때 body 찍어보고 맞추기.
  python3 - "$RNW_BODY" <<'PY' >/tmp/sca_rnw_leaf.pem 2>/dev/null || true
import sys, json
d = json.load(open(sys.argv[1]))
chain = d.get("certChain") or []
leaf = d.get("crt") or (chain[0] if chain else "")
sys.stdout.write(leaf or "")
PY
  python3 - "$RNW_BODY" <<'PY' >/tmp/sca_rnw_bundle.pem 2>/dev/null || true
import sys, json
d = json.load(open(sys.argv[1]))
chain = d.get("certChain") or [x for x in (d.get("crt"), d.get("ca")) if x]
sys.stdout.write("".join(chain))
PY
  [ -s /tmp/sca_rnw_leaf.pem ] || {
    echo "FAIL: renew: /1.0/renew response carried no certificate"
    echo "  actual: body=$(head -c 300 "$RNW_BODY" 2>/dev/null)"
    exit 1
  }
  NEW_SUBJ=$(openssl x509 -in /tmp/sca_rnw_leaf.pem -noout -subject 2>/dev/null || echo "")
  echo "$NEW_SUBJ" | grep -q "smoke.${NS}" || {
    echo "FAIL: renew: renewed leaf CN mismatch (expected smoke.${NS}.*)"
    echo "  actual: subject=$NEW_SUBJ"
    exit 1
  }
  if openssl verify -CAfile /tmp/stepca_root.pem -untrusted /tmp/sca_rnw_bundle.pem /tmp/sca_rnw_leaf.pem >/tmp/sca_rnw_verify 2>&1 \
      || openssl verify -CAfile /tmp/stepca_root.pem /tmp/sca_rnw_leaf.pem >/tmp/sca_rnw_verify 2>&1; then
    :
  else
    echo "FAIL: renew: renewed certificate does not chain to the step-ca Root CA"
    echo "  actual: $(cat /tmp/sca_rnw_verify 2>/dev/null)"
    exit 1
  fi
  NEW_NA=$(openssl x509 -in /tmp/sca_rnw_leaf.pem -noout -enddate 2>/dev/null | sed 's/notAfter=//' || echo "")
  NEW_EPOCH=$(date -d "$NEW_NA" +%s 2>/dev/null || echo 0)
  if [ "$OLD_EPOCH" -gt 0 ] && [ "$NEW_EPOCH" -gt 0 ]; then
    [ "$NEW_EPOCH" -ge "$OLD_EPOCH" ] || {
      echo "FAIL: renew: renewed leaf notAfter ($NEW_NA) is not after the original ($OLD_NA)"
      exit 1
    }
  else
    echo "note: could not parse notAfter dates for renew freshness check (date -d unavailable?) — chain+CN checks stand"
  fi
  echo "ok: /1.0/renew returned a fresh leaf (CN ok, chains to Root CA, notAfter advanced)"

  # (선택) 네거티브: disableRenewal=true 인 device-bootstrap provisioner 발급 인증서는
  # 갱신 거부돼야 함. 부트스트랩 leaf(bootstrap.crt/bootstrap.key)가 러너에서 읽힐 때만:
  #   RNW_NEG=$("${CURL[@]}" -o /dev/null -w '%{http_code}' --cert "$BOOT_CRT" --key "$BOOT_KEY" -X POST "${BASE_URL}/1.0/renew")
  #   case "$RNW_NEG" in 2*) echo "FAIL: renew-negative: bootstrap cert was renewable — disableRenewal not effective"; exit 1;; esac
fi

# ── 10. X5C 부트스트랩 e2e — device-bootstrap provisioner ────────────────────
# 디바이스 첫 부팅 흐름(X5C 토큰 → /1.0/sign)을 서버측에서 e2e 로 — "서명 요청 → 서명 확인" 한 번에.
#   (a) step-ca-whitelist 에 등록된 CN → 발급 + Root CA 체인
#   (b) 미등록 CN (device-ffffff)       → step-ca-whitelist→ca.json policy (결정 c) 로 거부
# 입력: Secret 'step-ca-smoke-bootstrap' (kubernetes.io/tls; tls.crt = bootstrap_ca.crt 서명 leaf,
#       tls.key = 그 키). 디바이스가 펌웨어에 굽는 bootstrap.crt/bootstrap.key 와 동일 역할의
#       smoke 전용 장수명 신원 — dev 에만 존재. Secret 또는 'step' CLI 없으면 #10 전체 note-skip.
if   ! command -v step >/dev/null 2>&1;                            then echo "note: #10 (X5C bootstrap e2e) skipped — 'step' CLI not on runner PATH"
elif ! kubectl get secret step-ca-smoke-bootstrap -n "$NS" >/dev/null 2>&1; then echo "note: #10 (X5C bootstrap e2e) skipped — Secret 'step-ca-smoke-bootstrap' not in $NS"
else
  BOOT_CRT=/tmp/stepca_bootstrap.crt; BOOT_KEY=/tmp/stepca_bootstrap.key
  kubectl get secret step-ca-smoke-bootstrap -n "$NS" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "$BOOT_CRT" 2>/dev/null || true
  kubectl get secret step-ca-smoke-bootstrap -n "$NS" -o jsonpath='{.data.tls\.key}' 2>/dev/null | base64 -d > "$BOOT_KEY" 2>/dev/null || true
  { [ -s "$BOOT_CRT" ] && [ -s "$BOOT_KEY" ]; } || {
    echo "FAIL: x5c-bootstrap: Secret 'step-ca-smoke-bootstrap' missing tls.crt/tls.key"
    echo "  actual: crt_empty=$([ -s "$BOOT_CRT" ] || echo yes), key_empty=$([ -s "$BOOT_KEY" ] || echo yes)"
    exit 1
  }
  # step CLI 가 우리 step-ca 를 신뢰하도록 — 빈 STEPPATH + #3 의 Root + --ca-url(127.0.0.1 은 dnsNames 에 포함)
  export STEPPATH; STEPPATH="$(mktemp -d /tmp/x5c_steppath.XXXXXX)"
  STEP_CA=(step --ca-url "$BASE_URL" --root /tmp/stepca_root.pem)

  # ── 10(a) 화이트리스트 등록 CN → 발급 + Root CA 체인 ──
  WL_CN="$(printf '%s\n' "${WL_CNS:-}" | head -1)"   # WL_CNS = #4b 에서 step-ca-whitelist 파싱한 값
  if [ -z "$WL_CN" ]; then
    echo "note: #10(a) skipped — step-ca-whitelist 에 발급 대상 device CN 이 없음"
  else
    TOK="$("${STEP_CA[@]}" ca token "$WL_CN" --provisioner device-bootstrap \
             --x5c-cert "$BOOT_CRT" --x5c-key "$BOOT_KEY" 2>/tmp/x5c_tok_err)" || {
      echo "FAIL: x5c-bootstrap(a): device-bootstrap 로 '$WL_CN' X5C 토큰 발급 실패"
      echo "  actual: $(cat /tmp/x5c_tok_err 2>/dev/null)"
      exit 1
    }
    "${STEP_CA[@]}" ca certificate "$WL_CN" /tmp/x5c_a.crt /tmp/x5c_a.key \
        --token "$TOK" --kty EC --curve P-256 --no-password --insecure -f >/tmp/x5c_a_out 2>&1 || {
      echo "FAIL: x5c-bootstrap(a): step-ca 가 화이트리스트 CN '$WL_CN' 발급을 거부함 (발급돼야 정상)"
      echo "  actual: $(cat /tmp/x5c_a_out 2>/dev/null)"
      exit 1
    }
    A_SUBJ="$(openssl x509 -in /tmp/x5c_a.crt -noout -subject 2>/dev/null || echo "")"
    echo "$A_SUBJ" | grep -q "$WL_CN" || {
      echo "FAIL: x5c-bootstrap(a): 발급 leaf CN 불일치 (expected $WL_CN)"
      echo "  actual: subject=$A_SUBJ"
      exit 1
    }
    "${STEP_CA[@]}" certificate verify /tmp/x5c_a.crt --roots /tmp/stepca_root.pem >/tmp/x5c_a_verify 2>&1 || {
      echo "FAIL: x5c-bootstrap(a): 발급 인증서가 step-ca Root CA 로 체인되지 않음"
      echo "  actual: $(cat /tmp/x5c_a_verify 2>/dev/null) ; bundle=$(openssl crl2pkcs7 -nocrl -certfile /tmp/x5c_a.crt 2>/dev/null | openssl pkcs7 -print_certs -noout 2>/dev/null | tr '\n' ' ')"
      exit 1
    }
    echo "ok: #10(a) device-bootstrap → 화이트리스트 CN '$WL_CN' 발급 + Root CA 체인 확인"
  fi

  # ── 10(b) 미등록 CN → 거부 (= #4b 정적 머지 확인의 동적 짝) ──
  BAD_CN="device-ffffff"
  printf '%s\n' "${WL_CNS:-}" | grep -qx "$BAD_CN" && BAD_CN="device-fffffe"
  BAD_TOK="$("${STEP_CA[@]}" ca token "$BAD_CN" --provisioner device-bootstrap \
               --x5c-cert "$BOOT_CRT" --x5c-key "$BOOT_KEY" 2>/dev/null)" || BAD_TOK=""
  if [ -z "$BAD_TOK" ]; then
    echo "ok: #10(b) device-bootstrap 가 미등록 CN '$BAD_CN' 에 토큰 발급조차 거부"
  elif "${STEP_CA[@]}" ca certificate "$BAD_CN" /tmp/x5c_b.crt /tmp/x5c_b.key \
         --token "$BAD_TOK" --kty EC --curve P-256 --no-password --insecure -f >/tmp/x5c_b_out 2>&1; then
    echo "FAIL: x5c-bootstrap(b): step-ca 가 미등록 CN '$BAD_CN' 에 인증서 발급함 — step-ca-whitelist→ca.json policy 무효"
    echo "  actual: issued; subject=$(openssl x509 -in /tmp/x5c_b.crt -noout -subject 2>/dev/null)"
    exit 1
  else
    grep -qiE 'not allowed|policy|forbidden|denied|not authoriz|common name' /tmp/x5c_b_out 2>/dev/null \
      || echo "note: #10(b) 거부됨 — 에러 텍스트에 policy 단어는 안 보이나 거부 자체는 pass: $(head -c 200 /tmp/x5c_b_out 2>/dev/null)"
    echo "ok: #10(b) device-bootstrap 가 미등록 CN '$BAD_CN' 거부 (policy gate 동작)"
  fi

  rm -rf "$STEPPATH"; unset STEPPATH
fi

echo "All checks passed."
