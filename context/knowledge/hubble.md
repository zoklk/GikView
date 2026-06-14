# Hubble (Cilium 네트워크 메트릭) — 운영 지식 메모

> Cilium 은 edge/ **밖**에서 helm 설치됨(이 노드 / edge-cluster 각각 별도 release).
> 본 문서는 visibility phase 가 의존하는 **Hubble metrics 활성화 + Prometheus
> scrape 통합**만 다룬다. Cilium 자체 설치·CNI 설정은 범위 밖.

---

## 이미지 / 버전

**채택**: Cilium 1.19.2 (CNI, kubeProxyReplacement=true, L2 Announcements).
Hubble 은 cilium-agent 내장 — 별도 이미지 없음. relay/UI 이미지(차트 기본 v1.18.x)는
**본 통합에 불필요**(메트릭은 agent 가 직접 노출).

## 주요 설정

### 1. Hubble metrics 활성화 (Cilium helm values, edge/ 밖 — 양 클러스터 각각)

```yaml
hubble:
  enabled: true
  relay:
    enabled: true              # cluster-wide flow 집계 (hubble observe 디버깅용)
  ui:
    enabled: false             # UI 영구노출 안 함
  metrics:
    enabled:                   # null(기본)이면 노출 0, 9965 미개방, hubble-metrics svc 미생성
      # sourceContext/destinationContext = 서비스 단위 귀속(어느 서비스쌍이 drop인지).
      # workload-name 우선, 외부/host 트래픽은 reserved-identity(world/host) fallback.
      - flow:sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity
      - drop:sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity
      - tcp
      - icmp
      - dns:query;ignoreAAAA
    # port: 9965               # 기본
```

결과 메트릭: `hubble_drop_total{source="edge-gateway",destination="influxdb",reason="..."}` → 서비스쌍 단위 drop 보임 = 디버깅 범위 축소.

적용 → cilium rollout restart. 결과:

- headless svc `hubble-metrics` (kube-system) 자동 생성
- 어노테이션 `prometheus.io/scrape: "true"`, `prometheus.io/port: "9965"`, 평문(TLS 없음)
- relay/UI 는 안 켜도 됨. UI 필요 시 `hubble.relay.enabled` + `hubble.ui.enabled` 별도(본 phase 비범위)

### 2. Prometheus scrape (우리 prometheus.yml ConfigMap)

```yaml
- job_name: hubble
  kubernetes_sd_configs:
    - role: endpoints
      namespaces: { names: [kube-system] }
  relabel_configs:
    - source_labels: [__meta_kubernetes_service_name]
      action: keep
      regex: hubble-metrics      # headless svc 엔드포인트만 (전 노드 agent)
  # path 기본 /metrics, scheme http (평문)
```

### 3. Relay + observe (연결 단위 디버깅)

- relay = 전 노드 agent flow 를 단일 API 로 집계. `hubble observe`(CLI)/UI 가 여기 연결. 메트릭엔 불필요하나 연결 단위 디버깅엔 필수.
- `cilium hubble port-forward` → `hubble observe --to-pod <ns/pod> --verdict DROPPED` 로 "패킷이 목적지 도달? policy drop? app RST?" 판별 = 네트워크 vs app 분리.
- 영구노출 0: port-forward 운영자 로컬만. UI 비활성.

## 알려진 주의사항

- **hubble job 타겟 0개**: `hubble.enabled: true` 인데 `metrics.enabled: null`(기본). 9965 미개방·svc 미생성이 원인. `metrics.enabled` 리스트 지정 + cilium rollout 으로 해결. (smoke-test-prometheus 체크 5 가 이걸 잡음)
- **한쪽 클러스터만 결손**: 이 노드/edge-cluster 는 별도 cilium helm release. 한쪽만 켜면 그쪽 flow 메트릭만 들어옴. 양쪽 동일 적용 필수.
- **메트릭명 ≠ 토글명**: 차트 토글은 `flow`/`drop` 이지만 노출 메트릭은 `hubble_flows_processed_total`/`hubble_drop_total`. 전부 `hubble_` 접두. alert/대시보드는 메트릭명 기준.
- **scrape TLS 불일치**: `hubble.tls.enabled: true` 는 relay 용. metrics(9965)는 별도라 기본 평문 → scheme http. 단 `hubble.metrics.tls` 를 명시 활성화하면 scrape 도 TLS 필요해짐 — 본 구성은 평문 유지.
- **cardinality 폭증**: http/dns 메트릭은 per-pod/identity 라벨이 많음. 과다 활성 시 Prometheus 부하 ↑ → e-s2 microSD IOPS 압박(260420 재발 위험). 필요한 메트릭만 켤 것.
- **context 옵션 레퍼런스**:
  - `sourceContext`/`destinationContext` 허용값: `identity`, `namespace`, `pod`, `pod-name`, `dns`, `ip`, `reserved-identity`, `workload`, `workload-name`, `app`
  - `|` = fallback(첫 non-empty 사용). 옵션 구분 `;`, 메트릭은 리스트 항목.
  - cardinality: context 추가하면 series ↑. gikview workload 소수(edge-gateway/influxdb/emqx/telegraf 등)라 안전. `pod` 레벨까지 가면 replica × 늘어남 — `workload-name` 권장.

## 환경별 분리 필요 항목

| 항목 | dev (alpha) | prod (edge) |
|------|------|------|
| Cilium helm release | alpha 클러스터 | edge 클러스터 |
| `hubble.metrics.enabled` | 동일 리스트 | 동일 리스트 |

메트릭 셋 자체는 환경 차이 없음. 단 두 클러스터에 각각 적용해야 함.
