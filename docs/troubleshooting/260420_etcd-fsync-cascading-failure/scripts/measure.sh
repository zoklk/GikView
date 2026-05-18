#!/bin/bash
# Usage: ./measure.sh <label> <duration_seconds>
LABEL=$1
DURATION=$2
TS=$(date +%H%M%S)

mpstat -P ALL 1 $DURATION > ${LABEL}_${TS}_mpstat.log &
iostat -xz 1 $DURATION > ${LABEL}_${TS}_iostat.log &
vmstat 1 $DURATION > ${LABEL}_${TS}_vmstat.log &

wait
echo "Measurement done: $LABEL"
