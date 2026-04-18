# Phase: messaging

## Sub-goal: emqx

**service_name**: emqx
**technology**: emqx (5.8.6)
**dependency**: [none]
**artifacts**: helm
**node_category**: [none]

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

## Sub-goal: cilium-l2-vip

**service_name**: emqx-lb
**technology**: cilium (1.19.2)
**dependency**: [emqx]
**artifacts**: helm
**node_category**: [none]

- **Ports**:
  - `mqtt: 1883` — 평문, 내부망 (mTLS 설정 전 검증용)
  - `mqtts: 8883`— mTLS설정 이후 사용 port