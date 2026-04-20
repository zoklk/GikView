#!/bin/bash
# emqx-lb 재배포 시 CPU 부하 측정
# 사용법: ./run_testE.sh

TS=$(date +%H%M%S)
DURATION=180   # 3분

echo "[$(date +%H:%M:%S)] === Test E 시작 (${DURATION}초) ==="
echo "[$(date +%H:%M:%S)] Timestamp suffix: ${TS}"

# === 백그라운드 측정 ===
mpstat -P ALL 1 ${DURATION} > testE_mpstat_${TS}.log 2>&1 &
MPID=$!
iostat -xz 1 ${DURATION} > testE_iostat_${TS}.log 2>&1 &
IPID=$!
vmstat 1 ${DURATION} > testE_vmstat_${TS}.log 2>&1 &
VPID=$!

# Cilium Pod CPU (1초 간격)
(for i in $(seq 1 ${DURATION}); do
  ts=$(date +%H:%M:%S)
  kubectl -n kube-system top pod -l k8s-app=cilium --no-headers 2>/dev/null | awk -v t="$ts" '{print t, $0}'
  sleep 1
done) > testE_cilium_${TS}.log 2>&1 &
CPID=$!

# EMQX Pod CPU도 함께
(for i in $(seq 1 ${DURATION}); do
  ts=$(date +%H:%M:%S)
  kubectl -n gikview top pod --no-headers 2>/dev/null | awk -v t="$ts" '{print t, $0}'
  sleep 1
done) > testE_emqx_${TS}.log 2>&1 &
EPID=$!

echo "[$(date +%H:%M:%S)] 측정 시작됨 (mpstat=$MPID, cilium=$CPID)"
echo "[$(date +%H:%M:%S)] 10초 안정화 대기..."
sleep 10

# === 이벤트 1: uninstall ===
echo "[$(date +%H:%M:%S)] EVENT uninstall_start" | tee -a testE_events_${TS}.log
helm uninstall emqx-lb -n gikview 2>&1 | tee -a testE_events_${TS}.log
echo "[$(date +%H:%M:%S)] EVENT uninstall_done" | tee -a testE_events_${TS}.log

# 30초 대기
echo "[$(date +%H:%M:%S)] 30초 대기 (IPPool/L2Policy finalizer 정리)..."
sleep 30

# === 이벤트 2: install ===
echo "[$(date +%H:%M:%S)] EVENT install_start" | tee -a testE_events_${TS}.log
helm install emqx-lb ~/GikView/edge/helm/emqx-lb -n gikview \
  -f ~/GikView/edge/helm/emqx-lb/values.yaml \
  -f ~/GikView/edge/helm/emqx-lb/values-prod.yaml 2>&1 | tee -a testE_events_${TS}.log
echo "[$(date +%H:%M:%S)] EVENT install_done" | tee -a testE_events_${TS}.log

# External IP 할당 확인
for i in {1..20}; do
  EXT_IP=$(kubectl -n gikview get svc emqx-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  if [ -n "$EXT_IP" ]; then
    echo "[$(date +%H:%M:%S)] EVENT external_ip_assigned: $EXT_IP" | tee -a testE_events_${TS}.log
    break
  fi
  sleep 2
done

# === 측정 완료 대기 ===
echo "[$(date +%H:%M:%S)] 측정 완료 대기..."
wait $MPID $IPID $VPID $CPID $EPID
echo "[$(date +%H:%M:%S)] === Test E 완료 ==="
echo ""
echo "생성된 파일:"
ls -la testE_*_${TS}.*
