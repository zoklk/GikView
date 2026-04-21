#!/bin/bash
# emqx_load_subscriber.sh
# EMQX 부하 테스트 수신측 - e-s2에서 실행
#
# 역할:
#   - mosquitto_sub으로 EMQX Service ClusterIP 구독
#   - mpstat, iostat, vmstat으로 노드 자원 측정
#   - kubectl top으로 EMQX Pod CPU 측정
#
# Usage: ./emqx_load_subscriber.sh <output_dir> <duration_sec>
# Example: ./emqx_load_subscriber.sh raw/emqx_load_5s 330

set -euo pipefail

OUTPUT_DIR=${1:?"Usage: $0 <output_dir> <duration_sec>"}
DURATION=${2:?"Usage: $0 <output_dir> <duration_sec>"}
TS=$(date +%H%M%S)

mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

# EMQX Service ClusterIP 조회
EMQX_CLUSTERIP=$(kubectl -n gikview get svc emqx -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
if [ -z "$EMQX_CLUSTERIP" ]; then
    echo "ERROR: EMQX Service not found in gikview namespace" >&2
    exit 1
fi

EMQX_PORT=$(kubectl -n gikview get svc emqx -o jsonpath='{.spec.ports[?(@.name=="mqtt")].port}' 2>/dev/null)
EMQX_PORT=${EMQX_PORT:-1883}

echo "=== EMQX Load Test Receiver ==="
echo "Timestamp : $TS"
echo "Output    : $OUTPUT_DIR"
echo "Duration  : ${DURATION}s"
echo "Broker    : ${EMQX_CLUSTERIP}:${EMQX_PORT}"
echo ""

# 측정 백그라운드 시작
mpstat -P ALL 1 ${DURATION} > emqx_load_${TS}_mpstat.log 2>&1 &
MPID=$!

iostat -xz 1 ${DURATION} > emqx_load_${TS}_iostat.log 2>&1 &
IPID=$!

vmstat 1 ${DURATION} > emqx_load_${TS}_vmstat.log 2>&1 &
VPID=$!

# EMQX Pod CPU (DURATION 후 종료)
(
    end=$(( $(date +%s) + DURATION ))
    while [ $(date +%s) -lt $end ]; do
        ts=$(date +%H:%M:%S)
        kubectl -n gikview top pod --no-headers 2>/dev/null | \
            awk -v t="$ts" '$1 != "NAME" {print t, $0}'
        sleep 1
    done
) > emqx_load_${TS}_emqx_pods.log 2>&1 &
EMQX_PID=$!

# Subscribe 시작 (ClusterIP)
mosquitto_sub -h "$EMQX_CLUSTERIP" -p "$EMQX_PORT" \
    -t 'gikview/rooms/+/occupancy' -v \
    > emqx_load_${TS}_subscribe.log 2>&1 &
SUB_PID=$!

echo "Started:"
echo "  mpstat    PID=$MPID"
echo "  iostat    PID=$IPID"
echo "  vmstat    PID=$VPID"
echo "  emqx top  PID=$EMQX_PID"
echo "  subscribe PID=$SUB_PID"
echo ""
echo "Waiting ${DURATION}s..."

# mpstat/iostat/vmstat는 DURATION 후 자동 종료
wait $MPID $IPID $VPID

# Subscribe와 EMQX pod top 종료
kill $SUB_PID $EMQX_PID 2>/dev/null || true
sleep 1

echo ""
echo "=== Done ==="
echo ""
echo "Messages received: $(wc -l < emqx_load_${TS}_subscribe.log)"
echo ""
echo "Per-sensor count:"
grep -oE 'sensor-[0-9]+' emqx_load_${TS}_subscribe.log 2>/dev/null | sort | uniq -c || echo "  (no messages)"
echo ""
echo "Output files:"
ls -la emqx_load_${TS}_*