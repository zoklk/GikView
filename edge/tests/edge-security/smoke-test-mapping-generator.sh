#!/usr/bin/env bash
# smoke-test-mapping-generator.sh
# Phase  : security
# Service: mapping-generator
#
# 검증 범위:
#   1. CronJob 존재, schedule */15 * * * *
#   2. RBAC: ServiceAccount 가 $NS 에서 configmaps get/list/create/update 가능
#      (※ kubectl auth can-i --as=<sa> 는 러너 kubeconfig 에 impersonate 권한 필요 = cluster-admin)
#   3. SoT device-room-mapping ConfigMap 존재 + 비어있지 않음 (읽기 전용 — 수정 금지)
#   4. 신규 Job 실행 → complete
#   5. 출력 3종 well-formed: emqx-acl(Erlang tuple), step-ca-whitelist(CN 목록 — 아래 (c) 참고),
#      telegraf-lookup(device_id,room_id CSV) + 세 ConfigMap 의 device CN 집합 == SoT
#   6. 멱등성: Job 한 번 더 → 3종 ConfigMap content 불변
#
# step-ca-whitelist 형식 — 결정 (c) 채택 (phase doc):
#   step-ca-whitelist ConfigMap 은 "CN 목록만" (JSON array of regex / yaml list — ca.json 전체가 아님).
#   step-ca workload 의 initContainer 가 ca.json 템플릿(placeholder/regex)에 이 목록을 merge 하고,
#   step-ca 의 Reloader 가 이 ConfigMap 을 watch (변경 시 step-ca restart → initContainer 재머지).
#   → 본 테스트는 step-ca-whitelist CM 을 직접 grep. (만약 (b): ca.json CM 자체 재생성 — 그 경우
#     <ca.json CM>.data."ca.json" 를 파싱해 policy.x509.allow.cn 안의 CN 추출로 #5 를 교체할 것.)
#
# 주의: mapping-generator 는 CronJob 단독 서비스 (long-running pod 없음) → runtime 의
#   kubectl_wait 가 no-op 일 수 있음 (하네스 측 처리 — 스크립트 외 트랙). 본 테스트는 자급자족.

set -euo pipefail
NS="${NAMESPACE:?NAMESPACE env not injected by runtime}"

JOB1="mapping-generator-smoke-$$-a"
JOB2="mapping-generator-smoke-$$-b"
cleanup() {
  kubectl delete job "$JOB1" "$JOB2" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

wait_job_complete() {  # $1=job-name $2=timeout-seconds  → 0 on Complete, exits 1 on Failed/timeout
  local job="$1" t="$2"
  if kubectl wait --for=condition=complete --timeout="${t}s" "job/$job" -n "$NS" >/dev/null 2>&1; then
    return 0
  fi
  # 빨리 빠지기: 이미 Failed 면 굳이 더 안 기다림
  if kubectl wait --for=condition=failed --timeout=2s "job/$job" -n "$NS" >/dev/null 2>&1; then
    echo "FAIL: job: mapping-generator Job '$job' reported Failed"
    echo "  actual: status=$(kubectl get job "$job" -n "$NS" -o jsonpath='{.status}' 2>/dev/null) ; pod log tail=$(kubectl logs -n "$NS" "job/$job" --tail=20 2>/dev/null)"
    exit 1
  fi
  echo "FAIL: job: mapping-generator Job '$job' did not complete within ${t}s"
  echo "  actual: status=$(kubectl get job "$job" -n "$NS" -o jsonpath='{.status}' 2>/dev/null) ; pod log tail=$(kubectl logs -n "$NS" "job/$job" --tail=20 2>/dev/null)"
  exit 1
}

# ── 1. CronJob 존재, schedule */15 ──────────────────────────────────────────
CRON="mapping-generator"
kubectl get cronjob "$CRON" -n "$NS" >/dev/null 2>&1 || {
  ALT=$(kubectl get cronjob -n "$NS" -o name 2>/dev/null | grep -i mapping | head -1 | sed 's#cronjob.batch/##' || echo "")
  [ -n "$ALT" ] && CRON="$ALT"
}
SCHED=$(kubectl get cronjob "$CRON" -n "$NS" -o jsonpath='{.spec.schedule}' 2>/dev/null || echo "")
[ -n "$SCHED" ] || {
  echo "FAIL: cronjob: mapping-generator CronJob not found in $NS"
  echo "  actual: cronjobs=$(kubectl get cronjob -n "$NS" -o name 2>/dev/null | tr '\n' ' ')"
  exit 1
}
echo "$SCHED" | grep -qE '^\*/15[[:space:]]' || {
  echo "FAIL: cronjob: schedule expected '*/15 * * * *'"
  echo "  actual: schedule=$SCHED"
  exit 1
}

# ── 2. RBAC: SA configmaps get/list/create/update ───────────────────────────
SA=$(kubectl get cronjob "$CRON" -n "$NS" -o jsonpath='{.spec.jobTemplate.spec.template.spec.serviceAccountName}' 2>/dev/null || echo "")
[ -n "$SA" ] || SA="$CRON"
for verb in get list create update; do
  ANS=$(kubectl auth can-i "$verb" configmaps -n "$NS" --as="system:serviceaccount:${NS}:${SA}" 2>/dev/null || true)  # can-i 거부 시 stdout 에 이미 "no" 출력 + exit 1 → || true (echo "no" 면 "no\nno")
  [ "$ANS" = "yes" ] || {
    echo "FAIL: rbac: serviceaccount ${SA} cannot '${verb} configmaps' in ${NS}"
    echo "  actual: can-i ${verb} configmaps = ${ANS}"
    exit 1
  }
done

# ── 3. SoT device-room-mapping (읽기 전용) ──────────────────────────────────
SOT_JSON=$(kubectl get configmap device-room-mapping -n "$NS" -o json 2>/dev/null || echo "")
[ -n "$SOT_JSON" ] || {
  echo "FAIL: sot: device-room-mapping ConfigMap missing in $NS (단일 진실 공급원)"
  echo "  actual: not found"
  exit 1
}
SOT_KEYS=$(echo "$SOT_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join((d.get('data') or {}).keys()))" 2>/dev/null || echo "")
[ -n "$SOT_KEYS" ] || {
  echo "FAIL: sot: device-room-mapping has no data"
  echo "  actual: data keys=(empty)"
  exit 1
}
SOT_DEVICES=$(echo "$SOT_JSON" | python3 -c "
import sys, json, re
d = json.load(sys.stdin)
blob = '\n'.join((d.get('data') or {}).values())
print(','.join(sorted(set(re.findall(r'device-[a-f0-9]{6}', blob)))))
" 2>/dev/null || echo "")
echo "SoT keys=[$SOT_KEYS] devices=[${SOT_DEVICES:-<none parsed>}]"

# ── 4. 신규 Job 실행 → complete (최대 45s) ──────────────────────────────────
JOB1_OUT=$(kubectl create job "$JOB1" --from=cronjob/"$CRON" -n "$NS" 2>&1) || {
  echo "FAIL: trigger: could not create Job from cronjob/${CRON}"
  echo "  actual: $JOB1_OUT"
  exit 1
}
wait_job_complete "$JOB1" 45

# ── 5. 출력 3종 well-formed ─────────────────────────────────────────────────
get_cm_blob() {  # $1=name → 모든 data 값을 개행으로 이은 평문
  kubectl get configmap "$1" -n "$NS" -o json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('\n'.join((d.get('data') or {}).values()))" 2>/dev/null || echo ""
}
devset() { grep -oE 'device-[a-f0-9]{6}' | sort -u; }

for cm in emqx-acl step-ca-whitelist telegraf-lookup; do
  kubectl get configmap "$cm" -n "$NS" >/dev/null 2>&1 || {
    echo "FAIL: output: expected ConfigMap '$cm' not created"
    echo "  actual: configmaps=$(kubectl get configmap -n "$NS" -o name 2>/dev/null | tr '\n' ' ')"
    exit 1
  }
done

# emqx-acl: acl.conf 키 + 기대 라인
ACL_BODY=$(kubectl get configmap emqx-acl -n "$NS" -o jsonpath='{.data.acl\.conf}' 2>/dev/null || echo "")
[ -n "$ACL_BODY" ] || {
  echo "FAIL: output: emqx-acl has no 'acl.conf' key"
  echo "  actual: data=$(kubectl get configmap emqx-acl -n "$NS" -o jsonpath='{.data}' 2>/dev/null | head -c 200)"
  exit 1
}
echo "$ACL_BODY" | grep -qE '\{allow,[[:space:]]*\{user,[[:space:]]*"device-[a-f0-9]{6}"' || {
  echo "FAIL: output: emqx-acl missing a per-device publish rule"
  echo "  actual: acl.conf head=$(echo "$ACL_BODY" | head -c 300)"
  exit 1
}
echo "$ACL_BODY" | grep -q 'edge-gateway' || {
  echo "FAIL: output: emqx-acl missing edge-gateway shared-subscription rule"
  echo "  actual: $(echo "$ACL_BODY" | head -c 300)"
  exit 1
}
echo "$ACL_BODY" | grep -q 'telegraf' || {
  echo "FAIL: output: emqx-acl missing telegraf shared-subscription rule"
  echo "  actual: $(echo "$ACL_BODY" | head -c 300)"
  exit 1
}
echo "$ACL_BODY" | grep -qE '\{deny,[[:space:]]*all\}' || {
  echo "FAIL: output: emqx-acl missing final {deny, all}."
  echo "  actual: acl.conf tail=$(echo "$ACL_BODY" | tail -c 200)"
  exit 1
}

# step-ca-whitelist sanity (결정 c): CN 목록이어야 함 — ca.json 최상위 키가 보이면 (b) 로 새는 중 의심
WL_BLOB=$(get_cm_blob step-ca-whitelist)
echo "$WL_BLOB" | grep -qE '"(db|provisioners|address|authority|federatedRoots)"[[:space:]]*:' \
  && echo "note: step-ca-whitelist appears to contain ca.json top-level keys — expected a bare CN list under decision (c); is mapping-generator emitting the whole ca.json (decision b)?" || true

# 세 ConfigMap 의 device CN 집합
ACL_SET=$(echo "$ACL_BODY" | devset || true)
WL_SET=$(echo "$WL_BLOB" | devset || true)
LK_BLOB=$(get_cm_blob telegraf-lookup)
LK_SET=$(echo "$LK_BLOB" | devset || true)

[ -n "$LK_SET" ] || {
  echo "FAIL: output: telegraf-lookup has no 'device-XXXXXX,<room>' rows"
  echo "  actual: telegraf-lookup head=$(echo "$LK_BLOB" | head -c 200)"
  exit 1
}

# 일관성: emqx-acl == step-ca-whitelist == telegraf-lookup (device CN 집합)
if [ "$ACL_SET" != "$WL_SET" ] || [ "$ACL_SET" != "$LK_SET" ]; then
  echo "FAIL: consistency: device CN set differs across emqx-acl / step-ca-whitelist / telegraf-lookup"
  echo "  actual: acl=[$(echo "$ACL_SET" | tr '\n' ' ')] whitelist=[$(echo "$WL_SET" | tr '\n' ' ')] lookup=[$(echo "$LK_SET" | tr '\n' ' ')]"
  exit 1
fi
# SoT 와 일치 (SoT 에서 device 토큰을 파싱할 수 있었던 경우만 강제)
if [ -n "$SOT_DEVICES" ]; then
  SOT_SET=$(echo "$SOT_DEVICES" | tr ',' '\n' | sort -u | grep . || true)
  [ "$ACL_SET" = "$SOT_SET" ] || {
    echo "FAIL: consistency: generated device CN set does not match SoT device-room-mapping"
    echo "  actual: generated=[$(echo "$ACL_SET" | tr '\n' ' ')] sot=[$(echo "$SOT_SET" | tr '\n' ' ')]"
    exit 1
  }
else
  echo "note: could not parse device-XXXXXX tokens from device-room-mapping (format) — skipping generated-vs-SoT equality"
fi

# ── 6. 멱등성: Job 한 번 더 → 3종 ConfigMap content 불변 ────────────────────
SNAP1=$(kubectl get configmap emqx-acl step-ca-whitelist telegraf-lookup -n "$NS" \
  -o jsonpath='{range .items[*]}{.metadata.name}={.data}{"\n"}{end}' 2>/dev/null | sort || true)
JOB2_OUT=$(kubectl create job "$JOB2" --from=cronjob/"$CRON" -n "$NS" 2>&1) || {
  echo "FAIL: idempotency: could not create 2nd Job"
  echo "  actual: $JOB2_OUT"
  exit 1
}
wait_job_complete "$JOB2" 35
SNAP2=$(kubectl get configmap emqx-acl step-ca-whitelist telegraf-lookup -n "$NS" \
  -o jsonpath='{range .items[*]}{.metadata.name}={.data}{"\n"}{end}' 2>/dev/null | sort || true)
[ "$SNAP1" = "$SNAP2" ] || {
  echo "FAIL: idempotency: output ConfigMaps changed after a no-op re-run"
  echo "  actual: diff=$(diff <(printf '%s' "$SNAP1") <(printf '%s' "$SNAP2") | head -c 600)"
  exit 1
}

echo "All checks passed."
