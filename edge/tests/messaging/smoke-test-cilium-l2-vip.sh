#!/usr/bin/env bash
  # smoke-test-cilium-l2-vip.sh
  # Phase  : messaging
  # Sub-Goal: cilium-l2-vip

  set -euo pipefail
  NS="${NAMESPACE:?NAMESPACE env not injected by runtime}"
  VIP="192.168.0.200"

  # ── 1. Lease 존재 확인 ────────────────────────────────────────────────────────
  # Cilium이 L2 광고 노드 선출 시 생성하는 lease. 없으면 정책이 적용 안 된 것.
  echo "Checking L2 announcement lease..."
  RETRIES=6
  INTERVAL=5
  LEASE_FOUND=""
  for i in $(seq 1 $RETRIES); do
    LEASE_FOUND=$(kubectl get leases -n kube-system 2>/dev/null \
      | grep "cilium-l2announce-${NS}-emqx-lb" || true)
    [ -n "$LEASE_FOUND" ] && break
    echo "attempt $i/$RETRIES: lease not found, waiting ${INTERVAL}s..."
    sleep $INTERVAL
  done
  [ -n "$LEASE_FOUND" ] || { echo "FAIL: cilium-l2announce-${NS}-emqx-lb lease not found"; exit 1; }
  echo "Lease found: $LEASE_FOUND"

  # ── 2. Service EXTERNAL-IP 할당 확인 ─────────────────────────────────────────
  echo "Checking emqx-lb EXTERNAL-IP..."
  ASSIGNED_IP=""
  for i in $(seq 1 $RETRIES); do
    ASSIGNED_IP=$(kubectl get svc emqx-lb -n "$NS" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [ "$ASSIGNED_IP" = "$VIP" ] && break
    echo "attempt $i/$RETRIES: EXTERNAL-IP='${ASSIGNED_IP}', waiting ${INTERVAL}s..."
    sleep $INTERVAL
  done
  [ "$ASSIGNED_IP" = "$VIP" ] || {
    echo "FAIL: EXTERNAL-IP mismatch (got '${ASSIGNED_IP}', expected '${VIP}')"
    exit 1
  }
  echo "EXTERNAL-IP correctly assigned: $ASSIGNED_IP"

  # ── 3. VIP TCP 연결 테스트 ────────────────────────────────────────────────────
  # Lease·IP 할당이 되어도 ARP 광고가 실패하면 실제 패킷이 도달하지 않음.
  echo "Testing TCP connectivity to ${VIP}:1883..."
  nc -z -w 5 "$VIP" 1883 || { echo "FAIL: TCP connect to ${VIP}:1883 failed"; exit 1; }
  echo "TCP connect to ${VIP}:1883 OK"