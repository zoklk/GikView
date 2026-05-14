#!/usr/bin/env bash
# smoke-test-emqx.sh
# Phase  : security
# Service: emqx   ← messaging phase 의 평문 스모크 테스트를 대체하는 mTLS 변형
#
# (messaging deploy 용 평문 변형은 edge/tests/messaging/smoke-test-emqx.sh 로 별도 유지.
#  본 파일은 security phase 의 EMQX 재배포 — mTLS listener 전환 — 전용.)
#
# 검증 범위:
#   1. listener: ssl:default(8883) running, verify=verify_peer, fail_if_no_peer_cert=true;
#      평문 tcp:default(1883) 부재 또는 미가동
#   2. 클라이언트 인증서 없이 mqtts 접속 → 실패해야 함 (mTLS 강제)
#   3. (StepClusterIssuer 로 발급한 인증서 2장 보유 시 — device(publish) + edge-gateway(subscribe))
#      3a. publish 인증서로 mqtts CONNECT 성공
#      3b. edge-gateway 인증서로 $share/edge-gw/sensors/+/occupancy 구독 → device 인증서로
#          sensors/<device-CN>/occupancy publish → 구독자 수신
#          = mTLS + peer_cert_as_username=cn + shared-subscription ACL allow + no_match=deny 미발동
#      3c. device 인증서로 sensors/device-ffffff/occupancy (비소유) publish → 같은 구독자 미수신
#          = publish-side ACL deny 실증
#   4. 서버 인증서 (1차 소스 = emqx-server-tls Secret 의 tls.crt — 항상 존재):
#      CN=emqx.<ns>.svc.*, SAN 에 emqx-headless / emqx-nodeport / (prod) 노드 IP,
#      체인이 ca.crt(우리 Root CA)로 검증됨. 라이브 :8883 leaf subject 일치는 note 강등.
#   5. EMQX StatefulSet: secret.reloader.stakater.com/reload=emqx-server-tls,
#      configmap.reloader.stakater.com/reload=emqx-acl
#   6. authz: file source(enable) 의 acl.conf 가 pod 안에 존재·비어있지 않음; no_match=deny;
#      listener cacertfile 가 pod 안에 존재·비어있지 않음 (클라이언트 인증서 검증용 CA)
#   7. emqx-nodeport: 8883 만 노출, 1883 없음
#   8. (note-only) 클러스터 running 노드 수
#
# 범위 외 (스모크 없음): 동일 CN 동시 접속(client_id 충돌, ADR 7) — phase doc 상 이번엔
#   default 유지·visibility 에서 alert. 디바이스 부트스트랩 EST-like 흐름 — 펌웨어 필요.
#
# 사전조건: emqx-server-tls Secret 발급, emqx-acl ConfigMap 존재, StepClusterIssuer Ready,
#   device-room-mapping 에 스모크 디바이스 device-aaaaaa 엔트리. 러너에 mosquitto_pub/sub + openssl + python3.

set -euo pipefail
NS="${NAMESPACE:?NAMESPACE env not injected by runtime}"
ACTIVE_ENV="${ACTIVE_ENV:-}"

for b in mosquitto_pub mosquitto_sub openssl python3; do
  command -v "$b" >/dev/null 2>&1 || { echo "FAIL: runner: required binary '$b' not on PATH"; echo "  actual: command -v $b failed"; exit 1; }
done

MQTTS_PORT="18883"
DASH_PORT="18083"
DASH_URL="http://127.0.0.1:${DASH_PORT}"
DASH_USER="admin"
DASH_PASS="public"
CURL=(curl -s --max-time 10)

PUB_CN="device-aaaaaa"                               # ACL: publish sensors/device-aaaaaa/occupancy (SoT 의 스모크 디바이스)
SUB_CN="edge-gateway"                                # ACL: subscribe $share/edge-gw/sensors/+/occupancy
SHARE_TOPIC='$share/edge-gw/sensors/+/occupancy'     # 단일따옴표: $share 쉘 확장 방지

CA_FILE="/tmp/emqx_ca_$$.crt"
PUB_CRT="/tmp/emqx_pub_$$.crt"; PUB_KEY="/tmp/emqx_pub_$$.key"
SUB_CRT="/tmp/emqx_sub_$$.crt"; SUB_KEY="/tmp/emqx_sub_$$.key"
SUF="emqx-$$"
PUB_RES="smoke-emqx-pub-${SUF}";  PUB_SEC="smoke-emqx-pub-tls-${SUF}"
SUB_RES="smoke-emqx-sub-${SUF}";  SUB_SEC="smoke-emqx-sub-tls-${SUF}"

PF_MQTTS_PID=""; PF_DASH_PID=""; SUB_PID=""
cleanup() {
  [ -n "$SUB_PID" ] && kill "$SUB_PID" 2>/dev/null || true
  [ -n "$PF_MQTTS_PID" ] && kill "$PF_MQTTS_PID" 2>/dev/null || true
  [ -n "$PF_DASH_PID" ] && kill "$PF_DASH_PID" 2>/dev/null || true
  kubectl delete certificate "$PUB_RES" "$SUB_RES" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete secret "$PUB_SEC" "$SUB_SEC" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rm -f "$CA_FILE" "$PUB_CRT" "$PUB_KEY" "$SUB_CRT" "$SUB_KEY" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# 이름 해석
EMQX_SVC=$(kubectl get svc -n "$NS" -l app.kubernetes.io/name=emqx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
[ -n "$EMQX_SVC" ] || EMQX_SVC="emqx"
EMQX_STS=$(kubectl get statefulset -n "$NS" -l app.kubernetes.io/name=emqx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
[ -n "$EMQX_STS" ] || EMQX_STS="emqx"
EMQX_POD=$(kubectl get pod -n "$NS" -l app.kubernetes.io/name=emqx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
[ -n "$EMQX_POD" ] || EMQX_POD="emqx-0"

# ── 사전조건: emqx-server-tls Secret → CA(ca.crt), emqx-acl ConfigMap ──────
kubectl get secret emqx-server-tls -n "$NS" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > "$CA_FILE" 2>/dev/null || true
[ -s "$CA_FILE" ] || {
  echo "FAIL: precondition: secret 'emqx-server-tls' missing or has no ca.crt (cert-manager → StepClusterIssuer 발급 전?)"
  echo "  actual: kubectl get secret emqx-server-tls returned no ca.crt"
  exit 1
}
kubectl get configmap emqx-acl -n "$NS" >/dev/null 2>&1 || {
  echo "FAIL: precondition: ConfigMap 'emqx-acl' not present (mapping-generator 미실행?)"
  echo "  actual: not found in $NS"
  exit 1
}

# ── 클라이언트 인증서 2장 발급 (StepClusterIssuer / admin JWK provisioner) ──
issue_client_cert() {  # $1=res-name $2=secret-name $3=CN  → echo "ok" if Ready in time
  local res="$1" sec="$2" cn="$3" sci="$4"
  printf '%s\n' "apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${res}
  namespace: ${NS}
spec:
  secretName: ${sec}
  commonName: ${cn}
  duration: 1h
  privateKey:
    algorithm: ECDSA
    size: 256
  usages:
    - client auth
    - digital signature
  issuerRef:
    name: ${sci}
    kind: StepClusterIssuer
    group: certmanager.step.sm" | kubectl apply -f - >/dev/null 2>&1 || { echo ""; return; }
  echo ""
}
SCI=$(kubectl get stepclusterissuer -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
PUB_READY=""; SUB_READY=""
if [ -n "$SCI" ]; then
  issue_client_cert "$PUB_RES" "$PUB_SEC" "$PUB_CN" "$SCI"
  issue_client_cert "$SUB_RES" "$SUB_SEC" "$SUB_CN" "$SCI"
  for i in $(seq 1 7); do
    [ -z "$PUB_READY" ] && [ "$(kubectl get certificate "$PUB_RES" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")" = "True" ] && PUB_READY=1
    [ -z "$SUB_READY" ] && [ "$(kubectl get certificate "$SUB_RES" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")" = "True" ] && SUB_READY=1
    { [ -n "$PUB_READY" ] && [ -n "$SUB_READY" ]; } && break
    echo "attempt $i/7: client certs Ready pub=$([ -n "$PUB_READY" ] && echo y || echo n) sub=$([ -n "$SUB_READY" ] && echo y || echo n), waiting 5s..."
    sleep 5
  done
  if [ -n "$PUB_READY" ]; then
    kubectl get secret "$PUB_SEC" -n "$NS" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "$PUB_CRT" 2>/dev/null || true
    kubectl get secret "$PUB_SEC" -n "$NS" -o jsonpath='{.data.tls\.key}' 2>/dev/null | base64 -d > "$PUB_KEY" 2>/dev/null || true
    { [ -s "$PUB_CRT" ] && [ -s "$PUB_KEY" ]; } || PUB_READY=""
  fi
  if [ -n "$SUB_READY" ]; then
    kubectl get secret "$SUB_SEC" -n "$NS" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "$SUB_CRT" 2>/dev/null || true
    kubectl get secret "$SUB_SEC" -n "$NS" -o jsonpath='{.data.tls\.key}' 2>/dev/null | base64 -d > "$SUB_KEY" 2>/dev/null || true
    { [ -s "$SUB_CRT" ] && [ -s "$SUB_KEY" ]; } || SUB_READY=""
  fi
fi
[ -n "$PUB_READY" ] || echo "note: could not obtain StepClusterIssuer-issued device(publish) cert — skipping client-cert mTLS/ACL assertions (#3); negative-mTLS (#2) and config checks still run"
[ -n "$PUB_READY" ] && [ -z "$SUB_READY" ] && echo "note: could not obtain edge-gateway(subscribe) cert — only the mTLS handshake (#3a) will be asserted, not the pub/sub round-trip (#3b/#3c)"

# ── port-forward (mqtts + dashboard) ────────────────────────────────────────
kubectl port-forward -n "$NS" "svc/$EMQX_SVC" "${MQTTS_PORT}:8883" >/dev/null 2>&1 &
PF_MQTTS_PID=$!
kubectl port-forward -n "$NS" "svc/$EMQX_SVC" "${DASH_PORT}:18083" >/dev/null 2>&1 &
PF_DASH_PID=$!
sleep 3

# ── Dashboard API Bearer token ──────────────────────────────────────────────
TOKEN=""
for i in $(seq 1 6); do
  TOKEN=$("${CURL[@]}" -X POST "${DASH_URL}/api/v5/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"${DASH_USER}\",\"password\":\"${DASH_PASS}\"}" 2>/dev/null \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")
  [ -n "$TOKEN" ] && break
  sleep 3
done
[ -n "$TOKEN" ] || {
  echo "FAIL: dashboard: /api/v5/login failed — Dashboard creds (${DASH_USER}/****) wrong or API down (mTLS redeploy 가 creds 를 바꿨는지 확인)"
  echo "  actual: no token from POST /api/v5/login"
  exit 1
}
AUTH=(-H "Authorization: Bearer $TOKEN")

# ── 1. listener 구성 ────────────────────────────────────────────────────────
# 5.8.x: list endpoint 은 summary 만 (running 이 status.running 아래, ssl_options 비포함).
# 전체 ssl_options 는 detail endpoint(/api/v5/listeners/<id>) 에만 inline 으로 옴.
SSL_DETAIL=$("${CURL[@]}" "${AUTH[@]}" "${DASH_URL}/api/v5/listeners/ssl:default" 2>/dev/null || echo "")
LISTENERS=$("${CURL[@]}" "${AUTH[@]}"  "${DASH_URL}/api/v5/listeners"             2>/dev/null || echo "")
CACERTFILE=$(python3 - "$SSL_DETAIL" "$LISTENERS" <<'PY' 2>/tmp/emqx_listener_err
import sys, json
ssl_raw, ls_raw = sys.argv[1], sys.argv[2]
try:
    ssl = json.loads(ssl_raw) if ssl_raw else {}
except Exception:
    ssl = {}
try:
    ls = json.loads(ls_raw) if ls_raw else []
    if not isinstance(ls, list):
        ls = ls.get('data', [])
except Exception:
    ls = []
errs = []
if not ssl or ssl.get('type') != 'ssl':
    errs.append('no ssl:default detail (%r)' % (ssl.get('code') if isinstance(ssl, dict) else type(ssl).__name__))
else:
    if not ssl.get('running'):
        errs.append('ssl listener not running: %r' % ssl.get('running'))
    so = ssl.get('ssl_options', {}) or {}
    if so.get('verify') != 'verify_peer':
        errs.append('ssl verify=%r (want verify_peer)' % so.get('verify'))
    if so.get('fail_if_no_peer_cert') is not True:
        errs.append('fail_if_no_peer_cert=%r (want true)' % so.get('fail_if_no_peer_cert'))
tcp = next((x for x in ls if x.get('type') == 'tcp' or str(x.get('id','')).startswith('tcp:')), None)
if tcp:
    tcp_running = (tcp.get('status') or {}).get('running')
    if tcp_running is True or tcp.get('enable') is True:
        errs.append('plaintext tcp listener still active: status.running=%r enable=%r' % (tcp_running, tcp.get('enable')))
if errs:
    sys.exit('; '.join(errs))
print(((ssl.get('ssl_options', {}) or {}).get('cacertfile', '')))
PY
) || {
  echo "FAIL: listener: mqtts/plaintext listener config mismatch"
  echo "  actual: $(cat /tmp/emqx_listener_err 2>/dev/null) — ssl_detail=$(echo "$SSL_DETAIL" | head -c 400) — listeners=$(echo "$LISTENERS" | head -c 300)"
  exit 1
}
# peer_cert_as_username 검사: 5.8.x 부터 broker-wide config (mqtt.peer_cert_as_username)
# 로 옮겨갔음 — listener 응답엔 안 나옴. /api/v5/configs/mqtt 로 확인.
MQTT_CONF=$("${CURL[@]}" "${AUTH[@]}" "${DASH_URL}/api/v5/configs/mqtt" 2>/dev/null || echo "")
echo "$MQTT_CONF" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception as e:
    sys.exit('cannot parse mqtt cfg: %s' % e)
v = d.get('peer_cert_as_username', '')
sys.exit(0 if v == 'cn' else ('peer_cert_as_username=%r (want cn) — mqtt cfg=%s' % (v, str(d)[:200])))
" 2>/tmp/emqx_pcau_err || {
  echo "note: $(cat /tmp/emqx_pcau_err 2>/dev/null) — relying on ACL round-trip (#3b) to validate cn-as-username"
}

# ── 2. 클라이언트 인증서 없이 mqtts 접속 → 실패해야 함 ──────────────────────
NOCERT_OUT=$(mosquitto_pub -h 127.0.0.1 -p "$MQTTS_PORT" --cafile "$CA_FILE" --insecure \
  -t "smoke/nocert/$$" -m x -q 1 -i "smoke-nocert-$$" 2>&1) && {
  echo "FAIL: mtls-enforce: mqtts CONNECT succeeded WITHOUT a client certificate — mTLS not enforced"
  echo "  actual: mosquitto_pub exit 0 (output: ${NOCERT_OUT:-<none>})"
  exit 1
}
echo "ok: mqtts rejected client without cert (mosquitto: ${NOCERT_OUT:-<no output>})"

# ── 3. 클라이언트 인증서 보유 시 mTLS + ACL ─────────────────────────────────
if [ -n "$PUB_READY" ]; then
  PUB_TLS=(--cafile "$CA_FILE" --cert "$PUB_CRT" --key "$PUB_KEY" --insecure)

  # 3a. publish 인증서로 CONNECT 성공
  mosquitto_pub -h 127.0.0.1 -p "$MQTTS_PORT" "${PUB_TLS[@]}" \
    -t "sensors/${PUB_CN}/occupancy" -m '{"smoke":"connect"}' -q 1 -i "smoke-cli-$$" >/tmp/emqx_pub3a 2>&1 || {
    echo "FAIL: mtls-connect: mqtts CONNECT with StepClusterIssuer client cert failed"
    echo "  actual: $(cat /tmp/emqx_pub3a 2>/dev/null)"
    exit 1
  }

  if [ -n "$SUB_READY" ]; then
    SUB_TLS=(--cafile "$CA_FILE" --cert "$SUB_CRT" --key "$SUB_KEY" --insecure)

    # 3b. shared-subscription 왕복 (peer_cert_as_username=cn + ACL allow)
    OUT_B="/tmp/emqx_sub3b_$$"; : > "$OUT_B"
    mosquitto_sub -h 127.0.0.1 -p "$MQTTS_PORT" "${SUB_TLS[@]}" \
      -t "$SHARE_TOPIC" -C 1 -W 8 -i "smoke-egw-$$" > "$OUT_B" 2>/dev/null &
    SUB_PID=$!
    sleep 2     # port-forward 너머 mTLS 핸드셰이크 안정화
    mosquitto_pub -h 127.0.0.1 -p "$MQTTS_PORT" "${PUB_TLS[@]}" \
      -t "sensors/${PUB_CN}/occupancy" -m 'OCCUPIED' -q 1 -i "smoke-dev-$$" >/tmp/emqx_pub3b 2>&1 || {
      kill "$SUB_PID" 2>/dev/null || true; SUB_PID=""
      echo "FAIL: acl-allow: publish to own topic sensors/${PUB_CN}/occupancy failed"
      echo "  actual: $(cat /tmp/emqx_pub3b 2>/dev/null)"
      rm -f "$OUT_B"; exit 1
    }
    wait "$SUB_PID" 2>/dev/null || true; SUB_PID=""
    grep -q 'OCCUPIED' "$OUT_B" || {
      echo "FAIL: acl-allow: own-topic publish did not round-trip to the edge-gateway shared subscriber within 8s (mTLS / cn-as-username / shared-sub ACL / no_match broken?)"
      echo "  actual: subscriber received: $(cat "$OUT_B" 2>/dev/null || echo '<nothing>')"
      rm -f "$OUT_B"; exit 1
    }
    rm -f "$OUT_B"

    # 3c. 비소유 topic publish → 같은 구독자가 못 받아야 함 (publish-side ACL deny)
    OUT_C="/tmp/emqx_sub3c_$$"; : > "$OUT_C"
    mosquitto_sub -h 127.0.0.1 -p "$MQTTS_PORT" "${SUB_TLS[@]}" \
      -t "$SHARE_TOPIC" -C 1 -W 4 -i "smoke-egw2-$$" > "$OUT_C" 2>/dev/null &
    SUB_PID=$!
    sleep 2
    mosquitto_pub -h 127.0.0.1 -p "$MQTTS_PORT" "${PUB_TLS[@]}" \
      -t "sensors/device-ffffff/occupancy" -m 'LEAKED' -q 1 -i "smoke-dev2-$$" >/dev/null 2>&1 || true
    wait "$SUB_PID" 2>/dev/null || true; SUB_PID=""
    if grep -q 'LEAKED' "$OUT_C"; then
      echo "FAIL: acl-deny: publish to a foreign topic (sensors/device-ffffff/occupancy) by ${PUB_CN} was delivered — publish-side ACL leaked"
      echo "  actual: subscriber received: $(cat "$OUT_C" 2>/dev/null)"
      rm -f "$OUT_C"; exit 1
    fi
    rm -f "$OUT_C"
    echo "ok: foreign-topic publish by ${PUB_CN} was denied (subscriber received nothing in 4s)"
  else
    echo "note: edge-gateway cert unavailable — verified mTLS handshake only (#3a); pub/sub round-trip not asserted"
  fi
fi

# ── 4. 서버 인증서 (1차: emqx-server-tls Secret; live :8883 은 보조) ───────
SRV_BUNDLE="/tmp/emqx_srvbundle_$$.pem"
kubectl get secret emqx-server-tls -n "$NS" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "$SRV_BUNDLE" 2>/dev/null || true
[ -s "$SRV_BUNDLE" ] || {
  echo "FAIL: server-cert: secret 'emqx-server-tls' has no tls.crt"
  echo "  actual: (empty)"
  exit 1
}
SRV_LEAF="/tmp/emqx_srvleaf_$$.pem"
awk '/BEGIN CERTIFICATE/{n++} n==1{print} /END CERTIFICATE/{if(n==1) exit}' "$SRV_BUNDLE" > "$SRV_LEAF"
SRV_SUBJ=$(openssl x509 -in "$SRV_LEAF" -noout -subject 2>/dev/null || echo "")
SRV_SAN=$(openssl x509 -in "$SRV_LEAF" -noout -ext subjectAltName 2>/dev/null \
          || openssl x509 -in "$SRV_LEAF" -noout -text 2>/dev/null | grep -A2 -i "subject alternative name" || echo "")
echo "$SRV_SUBJ" | grep -q "emqx.${NS}.svc" || {
  echo "FAIL: server-cert: subject CN expected emqx.${NS}.svc.<cluster-domain>"
  echo "  actual: subject=$SRV_SUBJ"
  rm -f "$SRV_BUNDLE" "$SRV_LEAF"; exit 1
}
echo "$SRV_SAN" | grep -qE 'DNS:emqx([,[:space:]]|$)' || {
  echo "FAIL: server-cert: SAN missing short 'emqx' DNS name"
  echo "  actual: SAN=$(echo "$SRV_SAN" | tr '\n' ' ')"
  rm -f "$SRV_BUNDLE" "$SRV_LEAF"; exit 1
}
if [ "$ACTIVE_ENV" = "prod" ]; then
  echo "$SRV_SAN" | grep -qE '192\.168\.0\.10[23]' || {
    echo "FAIL: server-cert: SAN missing prod EMQX node IP (192.168.0.102/103)"
    echo "  actual: SAN=$(echo "$SRV_SAN" | tr '\n' ' ')"
    rm -f "$SRV_BUNDLE" "$SRV_LEAF"; exit 1
  }
else
  echo "$SRV_SAN" | grep -qiE 'IP Address:|IP:' || \
    echo "note: no IP SAN observed (dev — EMQX 노드 IP 는 환경별, 정확값 단정 안 함)"
fi
# 체인: tls.crt(leaf+chain) 가 ca.crt 로 검증
if ! openssl verify -CAfile "$CA_FILE" -untrusted "$SRV_BUNDLE" "$SRV_LEAF" >/tmp/emqx_verify 2>&1 \
   && ! openssl verify -CAfile "$CA_FILE" "$SRV_LEAF" >/tmp/emqx_verify 2>&1; then
  echo "FAIL: server-cert: emqx-server-tls certificate does not chain to its ca.crt (our Root CA)"
  echo "  actual: $(cat /tmp/emqx_verify 2>/dev/null)"
  rm -f "$SRV_BUNDLE" "$SRV_LEAF"; exit 1
fi
# 라이브 :8883 leaf subject 가 secret 의 leaf 와 일치하는지 (불일치는 note — Reloader rollout 중일 수 있음)
if [ -n "$PUB_READY" ]; then
  LIVE_PEM="/tmp/emqx_live_$$.pem"
  echo | openssl s_client -connect "127.0.0.1:${MQTTS_PORT}" -servername emqx -cert "$PUB_CRT" -key "$PUB_KEY" 2>/dev/null \
    | openssl x509 -outform pem > "$LIVE_PEM" 2>/dev/null || true
  if [ -s "$LIVE_PEM" ]; then
    LIVE_SUBJ=$(openssl x509 -in "$LIVE_PEM" -noout -subject 2>/dev/null || echo "")
    [ "$LIVE_SUBJ" = "$SRV_SUBJ" ] || echo "note: live :${MQTTS_PORT} leaf subject ($LIVE_SUBJ) differs from emqx-server-tls leaf ($SRV_SUBJ) — Reloader rollout in flight?"
  else
    echo "note: could not read live :${MQTTS_PORT} server cert — skipped (secret-based checks above stand)"
  fi
  rm -f "$LIVE_PEM"
fi
rm -f "$SRV_BUNDLE" "$SRV_LEAF"

# ── 5. EMQX StatefulSet Reloader annotations ────────────────────────────────
STS_ANN=$(kubectl get statefulset "$EMQX_STS" -n "$NS" -o jsonpath='{.metadata.annotations}' 2>/dev/null || echo "")
STS_TANN=$(kubectl get statefulset "$EMQX_STS" -n "$NS" -o jsonpath='{.spec.template.metadata.annotations}' 2>/dev/null || echo "")
ALL_ANN="$STS_ANN $STS_TANN"
echo "$ALL_ANN" | grep -q 'secret.reloader.stakater.com/reload' && echo "$ALL_ANN" | grep -q 'emqx-server-tls' || {
  echo "FAIL: reloader-annotation: missing secret.reloader.stakater.com/reload ⊇ emqx-server-tls on StatefulSet $EMQX_STS"
  echo "  actual: annotations=$ALL_ANN"
  exit 1
}
echo "$ALL_ANN" | grep -q 'configmap.reloader.stakater.com/reload' && echo "$ALL_ANN" | grep -q 'emqx-acl' || {
  echo "FAIL: reloader-annotation: missing configmap.reloader.stakater.com/reload ⊇ emqx-acl on StatefulSet $EMQX_STS"
  echo "  actual: annotations=$ALL_ANN"
  exit 1
}

# ── 6. authz: file source(acl.conf) + no_match=deny + listener cacertfile ──
AZ_SOURCES=$("${CURL[@]}" "${AUTH[@]}" "${DASH_URL}/api/v5/authorization/sources" 2>/dev/null || echo "")
ACL_PATH=$(echo "$AZ_SOURCES" | python3 -c "
import sys, json
data = json.load(sys.stdin)
ls = data if isinstance(data, list) else data.get('sources', data.get('data', []))
f = next((x for x in ls if x.get('type') == 'file'), None)
if not f or f.get('enable') is False:
    sys.exit('no enabled file authorizer: %r' % ls)
print(f.get('path', ''))
" 2>/tmp/emqx_az_err) || {
  echo "FAIL: authz: EMQX file authorizer not configured/enabled"
  echo "  actual: $(cat /tmp/emqx_az_err 2>/dev/null) — sources=$(echo "$AZ_SOURCES" | head -c 400)"
  exit 1
}
AZ_SETTINGS=$("${CURL[@]}" "${AUTH[@]}" "${DASH_URL}/api/v5/authorization/settings" 2>/dev/null || echo "")
echo "$AZ_SETTINGS" | grep -q '"no_match"[[:space:]]*:[[:space:]]*"deny"' || {
  echo "FAIL: authz: authorization.no_match expected 'deny'"
  echo "  actual: settings=$(echo "$AZ_SETTINGS" | head -c 300)"
  exit 1
}
podfile_size() {  # $1=path-in-pod → 바이트 수 (0 또는 빈 문자열이면 부재/빈 파일). /bin/sh 가정 X — cat | wc.
  kubectl exec -n "$NS" "$EMQX_POD" -- cat "$1" 2>/dev/null | wc -c | tr -dc '0-9' || echo ""
}
if [ -n "$ACL_PATH" ]; then
  ACL_SZ=$(podfile_size "$ACL_PATH")
  { [ -n "$ACL_SZ" ] && [ "$ACL_SZ" -gt 0 ]; } || {
    echo "FAIL: authz: acl.conf not present or empty inside pod $EMQX_POD"
    echo "  actual: path=$ACL_PATH size=${ACL_SZ:-<missing>}"
    exit 1
  }
fi
if [ -n "$CACERTFILE" ]; then
  CA_SZ=$(podfile_size "$CACERTFILE")
  { [ -n "$CA_SZ" ] && [ "$CA_SZ" -gt 0 ]; } || {
    echo "FAIL: ca-bundle: listener cacertfile not present or empty inside pod $EMQX_POD"
    echo "  actual: cacertfile=$CACERTFILE size=${CA_SZ:-<missing>}"
    exit 1
  }
else
  echo "FAIL: ca-bundle: ssl listener has no cacertfile — cannot verify client certs"
  echo "  actual: ssl_options.cacertfile empty"
  exit 1
fi

# ── 7. emqx-nodeport: 8883 만, 1883 없음 ───────────────────────────────────
NP_JSON=$(kubectl get svc -n "$NS" emqx-nodeport -o json 2>/dev/null || echo "")
[ -n "$NP_JSON" ] || {
  NPN=$(kubectl get svc -n "$NS" -o name 2>/dev/null | grep -iE 'emqx.*nodeport' | head -1 | sed 's#service/##' || echo "")
  [ -n "$NPN" ] && NP_JSON=$(kubectl get svc -n "$NS" "$NPN" -o json 2>/dev/null || echo "")
}
[ -n "$NP_JSON" ] || {
  echo "FAIL: nodeport: emqx-nodeport service not found"
  echo "  actual: services=$(kubectl get svc -n "$NS" -o name 2>/dev/null | tr '\n' ' ')"
  exit 1
}
echo "$NP_JSON" | python3 -c "
import sys, json
ports = json.load(sys.stdin).get('spec', {}).get('ports', [])
vals = set()
for p in ports:
    for k in ('port', 'targetPort'):
        if isinstance(p.get(k), int):
            vals.add(p[k])
errs = []
if 8883 not in vals:
    errs.append('8883 not exposed')
if 1883 in vals:
    errs.append('plaintext 1883 still exposed')
if errs:
    sys.exit('; '.join(errs) + ' (ports=%r)' % ports)
" 2>/tmp/emqx_np_err || {
  echo "FAIL: nodeport: emqx-nodeport port set mismatch"
  echo "  actual: $(cat /tmp/emqx_np_err 2>/dev/null)"
  exit 1
}

# ── 8. (note-only) 클러스터 running 노드 수 ────────────────────────────────
NODES_JSON=$("${CURL[@]}" "${AUTH[@]}" "${DASH_URL}/api/v5/nodes" 2>/dev/null || echo "")
RUNNING=$(echo "$NODES_JSON" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(len([n for n in d if n.get('node_status') == 'running']))
except Exception:
    print(-1)
" 2>/dev/null || echo "-1")
[ "$RUNNING" = "2" ] || echo "note: EMQX running-node count = $RUNNING (messaging phase 기준 2 기대 — 본 테스트는 mTLS 전환 검증이 주목적이라 단정 안 함)"

echo "All checks passed."
