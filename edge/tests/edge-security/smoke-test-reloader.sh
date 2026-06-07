#!/usr/bin/env bash
# smoke-test-reloader.sh
# Phase  : security
# Service: reloader
#
# 검증 범위:
#   1. Reloader Deployment available (replica >=1)
#   2. scope: gikview 네임스페이스 한정 (watchGlobally=false) — args/env 또는 namespaced Role
#   3. RBAC: ServiceAccount 가 $NS 에서 configmaps/secrets list 가능
#      (※ kubectl auth can-i --as=<sa> 는 러너 kubeconfig 에 impersonate 권한 필요 = cluster-admin)
#   4. 기능 검증: annotation 단 임시 Deployment → 참조 ConfigMap patch → rollout 트리거
#      (reloadOnCreate:true 와 헷갈리지 않게: Deployment 먼저 만들고 sleep 후 baseline 캡처,
#       그 다음 ConfigMap 을 patch — patch 가 유일한 트리거가 되도록)
#
# 설계 노트: EMQX–emqx-acl / step-ca–step-ca-whitelist 의 "실제 변경 → restart" 검증은
#   스모크에 너무 느리고 파괴적이라 여기서 일반 동작을 1회 증명하고, 실제 배선은
#   smoke-test-emqx.sh #5 / smoke-test-step-ca.sh #4b 의 annotation 존재 단정으로 분리.
#   (phase doc: 본 phase Reloader 적용 대상 = EMQX(emqx-server-tls, emqx-acl), step-ca(step-ca-whitelist))

set -euo pipefail
NS="${NAMESPACE:?NAMESPACE env not injected by runtime}"

SUF="rl-$$"
CM_NAME="reloader-smoke-cm-${SUF}"
DEP_NAME="reloader-smoke-dep-${SUF}"
cleanup() {
  kubectl delete deployment "$DEP_NAME" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete configmap "$CM_NAME" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# ── 1. Deployment available, replica >=1 ─────────────────────────────────────
RDEP=$(kubectl get deploy -n "$NS" -l app.kubernetes.io/name=reloader -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
[ -n "$RDEP" ] || RDEP=$(kubectl get deploy -n "$NS" -o name 2>/dev/null | grep -i reloader | head -1 | sed 's#deployment.apps/##' || echo "")
[ -n "$RDEP" ] || {
  echo "FAIL: deployment: reloader Deployment not found in $NS"
  echo "  actual: deployments=$(kubectl get deploy -n "$NS" -o name 2>/dev/null | tr '\n' ' ')"
  exit 1
}
AVAIL=$(kubectl get deploy "$RDEP" -n "$NS" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)
[ "${AVAIL:-0}" -ge 1 ] || {
  echo "FAIL: deployment: reloader '$RDEP' has no available replicas"
  echo "  actual: availableReplicas=${AVAIL:-0}"
  exit 1
}

# ── 2. scope: $NS 한정 (watchGlobally=false) ────────────────────────────────
# stakater chart 는 --namespaces=<ns> arg/env 로, 또는 ClusterRole 대신 namespaced Role
# 로 scope 를 좁힘 — 둘 중 하나라도 확인되면 통과.
ARGS=$(kubectl get deploy "$RDEP" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null || echo "")
ENVV=$(kubectl get deploy "$RDEP" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].env}' 2>/dev/null || echo "")
NSROLE=$(kubectl get role -n "$NS" -o name 2>/dev/null | grep -i reloader | head -1 || echo "")
if echo "$ARGS $ENVV" | grep -q "$NS" || [ -n "$NSROLE" ]; then
  :
else
  echo "FAIL: scope: cannot confirm reloader is scoped to '$NS' (no --namespaces/env ref, no namespaced Role)"
  echo "  actual: args=$ARGS ; env=$ENVV ; roles=$(kubectl get role -n "$NS" -o name 2>/dev/null | tr '\n' ' ')"
  exit 1
fi
echo "$ARGS $ENVV" | grep -oE -- "--namespaces=[^ \"]+" | grep -v "$NS" \
  && echo "note: reloader --namespaces appears to target a namespace other than $NS — verify chart values" || true

# ── 3. RBAC: SA 가 $NS 에서 configmaps/secrets list 가능 ─────────────────────
SA=$(kubectl get deploy "$RDEP" -n "$NS" -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || echo "")
[ -n "$SA" ] || SA="$RDEP"
for res in configmaps secrets; do
  ANS=$(kubectl auth can-i list "$res" -n "$NS" --as="system:serviceaccount:${NS}:${SA}" 2>/dev/null || true)  # can-i 거부 시 stdout 에 이미 "no" 출력 + exit 1 → || true (echo "no" 면 "no\nno")
  [ "$ANS" = "yes" ] || {
    echo "FAIL: rbac: serviceaccount ${SA} cannot 'list ${res}' in ${NS}"
    echo "  actual: can-i list ${res} = ${ANS} (sa=system:serviceaccount:${NS}:${SA})"
    exit 1
  }
done

# ── 4. 기능 검증: ConfigMap patch → annotation 단 Deployment rollout ────────
CM_OUT=$(kubectl create configmap "$CM_NAME" -n "$NS" --from-literal=key=v1 2>&1) || {
  echo "FAIL: setup: could not create test ConfigMap"
  echo "  actual: $CM_OUT"
  exit 1
}
DEP_MANIFEST=$(cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEP_NAME}
  namespace: ${NS}
  annotations:
    configmap.reloader.stakater.com/reload: "${CM_NAME}"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${DEP_NAME}
  template:
    metadata:
      labels:
        app: ${DEP_NAME}
    spec:
      containers:
        - name: pause
          image: busybox:1.36
          command: ["sh", "-c", "sleep 3600"]
          resources:
            requests:
              cpu: "5m"
              memory: "8Mi"
            limits:
              cpu: "50m"
              memory: "32Mi"
EOF
)
APPLY_OUT=$(printf '%s\n' "$DEP_MANIFEST" | kubectl apply -f - 2>&1) || {
  echo "FAIL: setup: could not create test Deployment"
  echo "  actual: $APPLY_OUT"
  exit 1
}
# Reloader 가 새 Deployment + 이미 존재하는 CM 의 초기 상태를 관측·정착할 시간을 준 뒤
# baseline 캡처 (reloadOnCreate 류 초기 reload 와 patch-트리거를 분리).
sleep 8
GEN_BEFORE=$(kubectl get deploy "$DEP_NAME" -n "$NS" -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "")
ANN_BEFORE=$(kubectl get deploy "$DEP_NAME" -n "$NS" -o jsonpath='{.spec.template.metadata.annotations}' 2>/dev/null || echo "")

kubectl patch configmap "$CM_NAME" -n "$NS" --type merge -p '{"data":{"key":"v2"}}' >/dev/null 2>&1 || {
  echo "FAIL: trigger: could not patch test ConfigMap"
  echo "  actual: patch failed"
  exit 1
}

# Reloader 가 Deployment pod-template 을 갱신할 때까지 최대 8 × 5s = 40s
ROLLED=""
ANN_NOW=""
GEN_NOW=""
for i in $(seq 1 8); do
  ANN_NOW=$(kubectl get deploy "$DEP_NAME" -n "$NS" -o jsonpath='{.spec.template.metadata.annotations}' 2>/dev/null || echo "")
  GEN_NOW=$(kubectl get deploy "$DEP_NAME" -n "$NS" -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "")
  if [ "$ANN_NOW" != "$ANN_BEFORE" ] || { [ -n "$GEN_NOW" ] && [ "$GEN_NOW" != "$GEN_BEFORE" ]; }; then
    ROLLED=1; break
  fi
  echo "attempt $i/8: no rollout yet (generation $GEN_BEFORE -> $GEN_NOW), waiting 5s..."
  sleep 5
done
[ -n "$ROLLED" ] || {
  echo "FAIL: reload: Reloader did not roll the annotated Deployment after the ConfigMap patch (40s)"
  echo "  actual: template.annotations before=$ANN_BEFORE after=$ANN_NOW ; generation $GEN_BEFORE -> $GEN_NOW ; reloader log tail=$(kubectl logs -n "$NS" "deploy/$RDEP" --tail=15 2>/dev/null)"
  exit 1
}

echo "All checks passed."
