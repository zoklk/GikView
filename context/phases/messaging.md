# Phase: messaging

## Service: emqx

**technology**: emqx/emqx (5.8.6)
**dependency**: [none]
**artifacts**: helm
**node_category**: [none]
**references**: [context/knowledge/emqx.md]

- EMQX 5.8.6 3-Pod StatefulSet HA 클러스터 구축.
- 각 Pod는 하드웨어 장애 대비를 위해 서로 다른 노드에 배치(Anti-affinity).
- DNS 기반의 정적 클러스터 디스커버리 사용.
- **Port**:
  - `mqtt: 1883` — 평문, 내부망 (mTLS 설정 전 검증용)
  - `mqtts: 8883`— mTLS설정 이후 사용 port
  - `dashboard: 18083` — EMQX Dashboard API
  - `ekka: 4370` — EMQX 클러스터 내부 RPC
- **리소스**:
  - CPU: `200m` / `500m`
  - Memory: `384Mi` / `512Mi` (개발 alpha 클러스터)

## Service: emqx-lb

**technology**: cilium (1.19.2)
**dependency**: [emqx]
**artifacts**: helm
**node_category**: [none]
**references**: [context/knowledge/cilium-l2.md]

- Cilium L2 Announcement를 이용해 EMQX에 고정 외부 IP(192.168.0.200)를 부여.
- `CiliumLoadBalancerIPPool` 리소스로 VIP 대역(192.168.0.200/32)을 선언하고,
  `serviceSelector`로 `app.kubernetes.io/name: emqx-lb` 레이블을 가진 서비스에만 할당 범위를 제한.
- `CiliumL2AnnouncementPolicy` 리소스로 해당 IP를 L2(ARP) 방식으로 광고.
  `nodeSelector`는 제외해야한다. 이유는 edgeserver의 경우 모든 노드가 control plane이기 때문.
- EMQX Pod를 직접 가리키는 `LoadBalancer` 타입 Service(`emqx-lb`)를 별도 생성.
  - 내부 ClusterIP 서비스(`emqx`)와 역할 분리: `emqx-lb`는 외부 클라이언트 전용.
- **Port**:
  - `mqtt: 1883` — 평문, 내부망 (mTLS 설정 전 검증용)
  - `mqtts: 8883` — mTLS 설정 이후 사용 port