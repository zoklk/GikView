# prometheus — 운영 지식 메모

---

## 이미지 / 버전

**채택**: `prom/prometheus:v3.12.0` (`docker.io/prom/prometheus`, 2026-05-28 릴리스, 2026-06-10 기준 최신 안정)

operator 없이 단일 Prometheus 서버로 운영한다. kube-prometheus-stack(Prometheus Operator + CRD + kube-state-metrics + 기본 룰셋)은 채택하지 않았다. 이유:

- RPi 3노드 K3s에서 operator + kube-state-metrics + 기본 워크로드가 메모리/IO 부담이 크다
- kube-prometheus-stack 기본 alert rule은 full HA 컨트롤플레인(kube-apiserver 다중, etcd quorum)을 가정 → 단일 control-plane K3s에서 오탐이 쏟아져 비활성화 작업이 별도로 든다
- 스크랩 대상이 9종으로 고정되어 있어 `ServiceMonitor` 자동발견 이점이 작다. `scrape_configs`를 ConfigMap에 직접 명시하는 편이 투명하고 가볍다

태그는 `latest` 금지, 정확한 patch 핀 고정. 업그레이드 시 endoflife.date/릴리스 노트로 최신 안정 확인 후 bump.

Helm chart: 자체 작성 (`edge/helm/prometheus/`). 업스트림 공식 chart(prometheus-community)는 의존성/하위차트가 많아 lean 자체 chart가 트러블슈팅에 단순.

## 주요 설정

operator가 없으므로 `scrape_configs`·`rule_files`·`alerting`을 ConfigMap(`prometheus.yml`)으로 직접 마운트한다.

```yaml
# prometheus.yml (ConfigMap) — 핵심만
global:
  scrape_interval: 30s        # e-s2 microSD 부하 고려 (기본 15s에서 늘림). 5초 polling의 10분 freshness 알림에 충분
  evaluation_interval: 30s

rule_files:
  - /etc/prometheus/rules/*.yaml   # alert rule ConfigMap 마운트 (alerting.md)

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager.monitoring.svc:9093"]

scrape_configs:
  - job_name: node-exporter        # DaemonSet, 3노드 (node-exporter.md)
    kubernetes_sd_configs: [{ role: endpoints, namespaces: { names: [monitoring] } }]
    relabel_configs:               # node-exporter endpoints만 필터
      - source_labels: [__meta_kubernetes_service_name]
        regex: node-exporter
        action: keep

  - job_name: influxdb             # 네이티브 /metrics (influxdb.md)
    static_configs: [{ targets: ["influxdb.gikview.svc:8181"] }]
    metrics_path: /metrics
    authorization:                 # influxdb-admin-token Bearer — 무인증 시 401
      type: Bearer
      credentials_file: /etc/prometheus/secrets/influxdb/token

  - job_name: emqx                 # /api/v5/prometheus/stats (emqx.md 참조, 인증 확인)
    static_configs: [{ targets: ["emqx-dashboard.gikview.svc:18083"] }]
    metrics_path: /api/v5/prometheus/stats

  - job_name: cert-manager         # controller :9402/metrics (cert-manager.md)
    static_configs: [{ targets: ["cert-manager.gikview.svc:9402"] }]

  - job_name: telegraf-freshness   # SQL 브릿지 prometheus_client (telegraf.md, visibility.md 결정 3)
    static_configs: [{ targets: ["telegraf-freshness.monitoring.svc:9273"] }]

  - job_name: edge-gateway         # STS/PutItem 카운터 자체 노출 :9101/metrics (visibility.md 결정 6)
    static_configs: [{ targets: ["edge-gateway.gikview.svc:9101"] }]

  - job_name: etcd                 # e-s1 K3s embedded etcd, --etcd-expose-metrics 선행 필요
    scheme: http                   # :2381 metrics는 평문 HTTP·무인증 (mTLS 아님 — 아래 주의사항)
    static_configs: [{ targets: ["<e-s1-node-ip>:2381"] }]
```

```yaml
# values.yaml — 서버 기동 플래그/스토리지
args:
  - "--config.file=/etc/prometheus/prometheus.yml"
  - "--storage.tsdb.retention.time=14d"     # microSD 용량 보호. 장기 시계열은 InfluxDB 책임 (storage.md 결정 3)
  - "--storage.tsdb.path=/prometheus"
storage:
  pvc:
    size: 8Gi                                # 14d × 8종 타겟 규모. microSD라 작게
persistence: true                            # WAL/블록 영속. emptyDir면 재시작 시 메트릭 유실
```

### etcd 메트릭 선행 설정 (e-s1 K3s, 배포 전 1회)

etcd 스크랩 전에 e-s1 control-plane에서 K3s가 metrics 리스너를 열어야 한다. 운영자가 직접 적용(cluster-env-inject/배포로 자동화 안 됨).

```yaml
# e-s1: /etc/rancher/k3s/config.yaml
etcd-expose-metrics: true
etcd-arg:
  - "listen-metrics-urls=http://127.0.0.1:2381,http://<e-s1-내부IP>:2381"
  # 127.0.0.1 만 두면 e-s2의 Prometheus pod가 못 닿음 → e-s1 내부 IP 추가.
  # 무인증 평문이라 0.0.0.0/학내망에 노출하지 말고 내부 IP + 방화벽으로 한정.
```

적용 후 `sudo systemctl restart k3s` (control-plane 재기동 1회). 이 단계가 prometheus 배포보다 선행 (visibility.md 결정 5).

ServiceAccount + RBAC: `kubernetes_sd_configs`(role: endpoints)는 cluster-scoped 권한이 필요하다. ServiceAccount + ClusterRole(`get/list/watch` on `endpoints`,`services`,`pods`,`nodes`) + ClusterRoleBinding을 chart에 포함.

## 알려진 주의사항

- **microSD WAL/compaction 부하**: retention이 길거나 scrape가 촘촘하면 TSDB compaction write가 microSD random write IOPS를 압박해 클러스터 안정성에 영향 (storage.md 결정 2, `260420_etcd-fsync-cascading-failure` 이력). retention 14d + scrape 30s로 제한. 증상: Prometheus pod의 `prometheus_tsdb_compactions_failed_total` 증가, 노드 iowait 급등 → retention/scrape 추가 완화 또는 e-s2 외 노드 재배치 검토.

- **etcd 메트릭은 평문 HTTP·무인증 + localhost 바인딩**: `:2381`은 etcd의 *metrics 전용 리스너*(`listen-metrics-urls`)다. client/peer 포트(2379/2380, mTLS)와 달리 **평문 HTTP, client cert 불필요**(`scheme: http`). 다만 기본 바인딩이 `127.0.0.1`이라 e-s2의 Prometheus pod에서 도달 못 함 → e-s1 K3s에서 `listen-metrics-urls`에 노드 내부 IP를 추가해야 함 (`http://127.0.0.1:2381,http://<e-s1-IP>:2381`). 무인증이므로 `0.0.0.0`/학내망 노출 금지, 내부 IP + 방화벽으로 한정. 증상: 미설정 시 etcd job이 `connection refused`로 down.

- **etcd endpoint 미노출 시 down**: `--etcd-expose-metrics` 미적용이면 항상 down. e-s1에서 K3s config 적용 + 재기동이 prometheus 배포보다 **선행**되어야 함 (visibility.md 결정 5). 부담되면 etcd 스크랩을 보류하고 node_exporter의 디스크/iowait 메트릭으로 대체 가능.

- **EMQX prometheus endpoint 인증**: EMQX 5.8.6의 `/api/v5/prometheus/stats`가 dashboard listener 인증을 요구하면 scrape가 401. EMQX 설정에서 prometheus pull을 인증 없이 허용하거나 scrape에 basic auth 주입 (emqx.md 확인).

- **in-cluster SD 권한 부족**: ServiceAccount에 nodes/endpoints watch 권한이 없으면 `kubernetes_sd`가 조용히 빈 타겟. 증상: 타겟 0개인데 에러 없음 → RBAC ClusterRole 확인.

- **non-HA 단일 replica**: Prometheus pod 다운 시 수집 공백 + 그 구간 alert 평가 안 됨. 단기 운영 허용 (visibility.md 결정 1). 파이프 자체 감시는 watchdog 보류(결정 8).

## 환경별 분리 필요 항목

| 항목 | dev (alpha) | prod (edge) |
|------|-----|------|
| `nodeSelector` (node_category: monitoring) | `alpha-w2` | `e-s2` |
| etcd 스크랩 target | `<alpha control-plane IP>:2381` | `<e-s1 IP>:2381` |
| `storage.pvc.size` | `4Gi` | `8Gi` |

retention(14d)·scrape(30s)는 환경 공통.
