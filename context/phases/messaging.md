# Phase: messaging

## Service: emqx

**technology**: emqx/emqx (5.8.6)
**dependency**: [none]
**artifacts**: helm
**node_category**: [none]
**references**: [context/knowledge/emqx.md]

- EMQX 5.8.6 2-Pod StatefulSet non-HA 클러스터 구축.
  - 각 Pod는 worker 노드에만 1개씩 배치 (nodeSelector: `node-role.kubernetes.io/worker`).
  - master 노드는 SPOF 방지를 위해 배치 대상에서 제외.
  - DNS 기반의 정적 클러스터 디스커버리 사용.
  - 외부 클라이언트(ESP32) 접근은 NodePort + 공유기 포트포워딩 방식 사용.
    - `externalTrafficPolicy: Local` 필수 — 각 NodePort는 해당 노드의 EMQX pod로만 라우팅.
    - 공유기에서 `<worker1-ip>:<nodeport>`, `<worker2-ip>:<nodeport>` 각각 포트포워딩.
    - ESP32는 두 주소를 순서대로 시도, 둘 다 실패 시 일정 주기 후 재연결.
  - **Port**:
    - `mqtt: 1883` — 평문, 내부망 (mTLS 설정 전 검증용)
    - `mqtts: 8883` — mTLS 설정 이후 사용 port
    - `dashboard: 18083` — EMQX Dashboard API
    - `ekka: 4370` — EMQX 클러스터 내부 RPC
  - **리소스**:
    - CPU: `200m` / `500m`
    - Memory: `384Mi` / `512Mi`