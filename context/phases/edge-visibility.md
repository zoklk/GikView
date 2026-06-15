# Phase: visibility

edge K3s 클러스터 내부 상태 수집·알림. 센서 데이터 파이프라인 전 구간(ESP8266 → EMQX → Telegraf → InfluxDB / Edge Gateway → DynamoDB)의 어느 지점이 끊겨도 감지하는 것이 목표. Prometheus(스크랩·alert 평가) + Alertmanager(Discord 라우팅) + Grafana(시각화) + node-exporter(노드 메트릭) + telegraf-freshness(InfluxDB SQL → Prometheus 브릿지) + Hubble flow 메트릭(L3/L4 네트워크 가시성) + 알림 파이프 외부 watchdog(healthchecks.io). Grafana 외부 노출은 Cloudflare Tunnel + Access(GitHub IdP). operator/CRD 없는 lean 자체 chart 구성.

의존: pipeline phase 완료(EMQX·Telegraf·Edge Gateway·InfluxDB 가동) 후 배포 — 스크랩 타겟이 먼저 존재해야 함. 설계 근거는 [docs/architecture/edge/visibility.md](../../docs/architecture/edge/visibility.md).

## 선행 작업 (배포 전, 운영자 수동)

- **K3s etcd 메트릭 노출 (e-s1)**: `/etc/rancher/k3s/config.yaml` 에 `etcd-expose-metrics: true` + `etcd-arg: ["listen-metrics-urls=http://127.0.0.1:2381,http://<e-s1-내부IP>:2381"]` 추가 후 `systemctl restart k3s`. prometheus 배포보다 선행. 무인증 평문이라 내부 IP + 방화벽 한정. 상세 `context/knowledge/prometheus.md` "etcd 메트릭 선행 설정".
- **Cloudflare 대시보드 (Zero Trust)**: Tunnel 생성 → `TUNNEL_TOKEN` 발급 → 환경별 `cloudflared-token` Secret 등록. Public hostname `grafana.<domain>` → `http://grafana.gikview.svc.cluster.local:3000` route. Access application(self-hosted) + GitHub IdP 정책. 상세 `context/knowledge/cloudflare-tunnel.md`.
- **Discord webhook**: 채널 webhook URL 발급 → 환경별 `alertmanager-discord` Secret 등록.
- **Hubble metrics + relay 활성화 (양 클러스터, edge/ 밖 Cilium values)**: 현재 `hubble.enabled: true` 이나 `hubble.metrics.enabled: null` — 메트릭 미노출. 두 클러스터 각각 Cilium helm values 에 `hubble.metrics.enabled` 를 context 라벨 포함 리스트(`flow:sourceContext=workload-name|reserved-identity;destinationContext=...`, `drop:` 동일, `tcp`, `icmp`, `dns:query;ignoreAAAA`)로 설정 + `hubble.relay.enabled: true`(연결 단위 `hubble observe` 디버깅, 결정 10), `hubble.ui.enabled: false` → cilium rollout. cilium-agent 가 `:9965` 에 메트릭 노출, `hubble-metrics` svc 생성. UI 영구노출 안 함(필요 시 port-forward). 상세 `context/knowledge/hubble.md`.
- **healthchecks.io check**: check 1개 생성(period 5m=ping 주기 일치, grace 5–10m) → 알림 채널 연결 → ping URL 발급 → 환경별 `alertmanager-healthchecks` Secret 등록. 무료티어로 충분. ping URL 토큰성, git 평문 금지.

## Service: node-exporter

**technology**: prom/node-exporter (v1.11.1)
**dependency**: [none]
**artifacts**: helm
**references**: [context/knowledge/node-exporter.md]

- DaemonSet, 3노드 전부. `node_category` 미지정 (nodeSelector 없음 — DaemonSet 이 전 노드 배포).
- **control-plane toleration 필수**: `tolerations: [{ operator: Exists }]`. e-s1(control-plane)에 pod 가 떠야 etcd 호스트 노드의 디스크/iowait 메트릭이 수집됨. 누락 시 e-s1 메트릭이 통째로 빔(에러 없이).
- hostNetwork + hostPID, host `/proc`·`/sys`·`/` readOnly 마운트.
- filesystem collector 에서 가상 fs(overlay/tmpfs/k3s 마운트) 제외. InfluxDB 외장 SSD 실제 마운트포인트(`/mnt/ssd` 계열)는 포함 — 용량 알림 출처.
- containerSecurityContext: `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: ["ALL"]`.
- **Port**: `metrics: 9100`.
- **리소스** (dev / prod): request CPU `100m`/`200m`, Memory `64Mi`/`64Mi`. limit CPU `200m`/`500m`, Memory `128Mi`/`128Mi`.

## Service: prometheus

**technology**: prom/prometheus (v3.12.0)
**dependency**: [node-exporter, alertmanager]
**artifacts**: helm
**node_category**: [monitoring]
**references**: [context/knowledge/prometheus.md]

- 단일 replica(non-HA). operator 없음 — `scrape_configs`/`rule_files`/`alerting` 을 ConfigMap(`prometheus.yml`)으로 직접 마운트.
- **retention 14d, scrape interval 30s**: e-s2 microSD random write IOPS 보호(storage.md 결정 2, `260420_etcd-fsync-cascading-failure`). 장기 시계열은 InfluxDB 책임(retention 무제한).
- **PVC 영속**: WAL/블록. emptyDir 면 재시작 시 메트릭 유실.
- **ServiceAccount + ClusterRole**: `kubernetes_sd_configs`(role: endpoints) 용 `get/list/watch` on `endpoints`,`services`,`pods`,`nodes`.
- **스크랩 타겟** (아래 "스크랩 타겟" 표).
- **alerting**: Alertmanager `alertmanager.monitoring.svc:9093` static.
- **rule reload**: `--web.enable-lifecycle` + Reloader annotation(`configmap.reloader.stakater.com/reload`)으로 rule/config ConfigMap 변경 시 반영.
- **Hubble 스크랩 (결정 9)**: cilium-agent `hubble-metrics` `:9965` `/metrics` 무인증 평문. kube-system DaemonSet pod SD, 전 노드. cilium-operator `:9962`(메트릭 켤 경우) 선택.
- **Port**: `http: 9090`.
- **리소스** (dev / prod): CPU `100m`/`500m`, Memory `256Mi`/`1Gi`. PVC `4Gi`/`8Gi`.

## Service: alertmanager

**technology**: prom/alertmanager (v0.32.1)
**dependency**: [none]
**artifacts**: helm
**node_category**: [monitoring]
**references**: [context/knowledge/alerting.md]

- 단일 replica. `discord_configs` receiver (v0.25+ 네이티브, v0.32.1 충족) — webhook 어댑터 불필요.
- **Discord webhook URL = Secret** (`alertmanager-discord`, `webhook_url_file` 마운트). git 평문 금지.
- 그룹화: `group_by: [alertname, room_id]`, `group_wait 30s` / `group_interval 5m` / `repeat_interval 4h` (Discord rate limit 보호).
- `inhibit_rules`: NodeDown 시 그 노드 하위 warning 억제.
- **외부 watchdog (결정 9)**: `Watchdog` alert(상시 발화) 전용 라우트를 `healthchecks` webhook receiver 로 — `group_wait 0s`/`group_interval 5m`/`repeat_interval 5m`(둘 다 맞춰야 실제 5m), `send_resolved: false`. ping URL = `alertmanager-healthchecks` Secret(`url_file`). healthchecks.io grace(5–10m) 초과 시 외부 통보 → 알림 파이프 전체 장애를 클러스터 밖에서 감지. 기존 Discord 24h watchdog 라우트는 self-referential 이라 제거.
- alert rule 본문은 prometheus 의 `rule_files` ConfigMap (아래 "alert rule" 표).
- **Port**: `http: 9093`.
- **리소스** (dev / prod): CPU `20m`/`100m`, Memory `32Mi`/`128Mi`.

## Service: telegraf-freshness

**technology**: influxdata/telegraf (1.38-alpine)
**dependency**: [influxdb, prometheus]
**artifacts**: helm
**node_category**: [monitoring]
**references**: [context/knowledge/telegraf.md, context/knowledge/influxdb.md, context/knowledge/prometheus.md]

- 센서별 freshness 브릿지. pipeline 의 telegraf(적재용)와 **별도 인스턴스** — 책임 분리.
- `inputs.http` 가 InfluxDB 3 Core `/api/v3/query_sql` 에 `SELECT room_id, max(time) ... GROUP BY room_id` 주기 질의(30~60s).
- `outputs.prometheus_client` 로 `gikview_sensor_last_seen_seconds{room_id}` gauge 노출. Prometheus 가 스크랩.
- InfluxDB admin token = `influxdb-admin-token` Secret → env. ClusterIP 내부 호출.
- **`[[inputs.internal]]` 활성**: telegraf 자체 메트릭(`internal_gather_errors` 등) 노출 → http 입력(InfluxDB 질의) 성공/실패를 smoke 가 검증.
- **Port**: `metrics: 9273` (prometheus_client 기본).
- **리소스** (dev / prod): CPU `20m`/`100m`, Memory `64Mi`/`128Mi`.

## Service: grafana

**technology**: grafana/grafana (13.0.2)
**dependency**: [prometheus]
**artifacts**: helm
**node_category**: [monitoring]
**references**: [context/knowledge/grafana.md]

- datasource(Prometheus) + 대시보드를 provisioning ConfigMap 으로 선언 — 무상태에 가깝게.
- **`GF_SERVER_ROOT_URL`** = Cloudflare Tunnel 호스트명(`https://grafana.<domain>/`)과 일치. 불일치 시 redirect/asset 깨짐.
- admin password = Secret(`__FILE` 주입), signup/anonymous off.
- **ClusterIP 내부 전용** — NodePort/Ingress 직접 노출 금지(Cloudflare Access 우회·헤더 위조 방지). 진입점은 터널뿐.
- **Hubble 대시보드 (결정 9)**: provisioning dashboards ConfigMap 에 Cilium/Hubble 공식 대시보드(grafana.com: Cilium Metrics, Hubble) JSON 추가, datasource = 기존 Prometheus. Hubble UI 는 영구 노출 안 함(서비스 단순 + Cloudflare 서브도메인 회피) — 필요 시 port-forward ad-hoc.
- **Port**: `http: 3000`.
- **리소스** (dev / prod): CPU `50m`/`300m`, Memory `128Mi`/`512Mi`. PVC `1Gi`/`2Gi` (provisioning 이 전부면 emptyDir 도 가능).

## Service: cloudflared

**technology**: cloudflare/cloudflared (2026.5.2)
**dependency**: [grafana]
**artifacts**: helm
**node_category**: [monitoring]
**references**: [context/knowledge/cloudflare-tunnel.md]

- outbound-only 터널. inbound 포트 0. 원격관리형(`TUNNEL_TOKEN`) — 라우팅·Access 정책은 Cloudflare 대시보드(선행 작업).
- `TUNNEL_TOKEN` = Secret(`cloudflared-token`). git 평문 금지.
- egress QUIC UDP 7844. 학내망이 UDP 막으면 `--protocol http2`(TCP 443) 폴백.
- replicaCount 2(무중단) 또는 RPi 부하 보고 1.
- 원격관리형이므로 로컬 `config.yaml` ingress 규칙 두지 말 것(충돌).
- **진단 metrics 노출**: args 에 `--metrics 0.0.0.0:2000` 추가 + `containerPort: 2000`. cloudflared 자체 진단 HTTP 서버 — `/ready`(터널 connection ≥1 시 200), `/metrics`(터널 통계). 클러스터 내부 진단용이며 터널로 외부 노출되는 게 아님(인터넷 inbound 0 유지). smoke 가 `/ready` 로 터널 연결을 검증.
- containerSecurityContext: `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: ["ALL"]`.
- **Port**: `metrics: 2000` — cloudflared 진단(`/ready`,`/metrics`), 클러스터 내부 전용. 데이터 경로는 outbound only.
- **리소스** (dev / prod): CPU `20m`/`100m`, Memory `32Mi`/`128Mi`.

## 스크랩 타겟

| job | target | path | 비고 |
|---|---|---|---|
| node-exporter | endpoints SD (monitoring) | `/metrics` | `:9100`, 3노드 |
| influxdb | `influxdb.gikview.svc:8181` | `/metrics` | 네이티브. Bearer 토큰(`influxdb-admin-token`) 인증 — 401 회피. 디스크/write/query 헬스 (결정 4) |
| emqx | `emqx-dashboard.gikview.svc:18083` | `/api/v5/prometheus/stats` | conn/msg/dropped/ACL deny. 인증 여부 emqx.md 확인 |
| cert-manager | `cert-manager.gikview.svc:9402` | `/metrics` | cert 만료 timestamp (결정 6) |
| telegraf-freshness | `telegraf-freshness.monitoring.svc:9273` | `/metrics` | 센서 last-seen (결정 3) |
| edge-gateway | `edge-gateway.gikview.svc:9101` | `/metrics` | STS/PutItem (결정 6, pipeline 산출물 계측) |
| etcd | `<e-s1-IP>:2381` | `/metrics` | `scheme: http`, 무인증. 선행 설정 필요 |
| hubble | cilium-agent pod SD (kube-system) | `/metrics` | `:9965`, DaemonSet 전 노드, 무인증 평문 (결정 9). 선행: metrics 활성화 |

## alert rule (prometheus rule_files → Discord)

| alert | 조건 | severity | 근거 |
|---|---|---|---|
| SensorNoData | `time() - gikview_sensor_last_seen_seconds > 600` | critical | 결정 3, 방별 10분 무데이터 |
| CertExpirySoon | `(certmanager_certificate_expiration_timestamp_seconds - time())/86400 < 7` | warning | 결정 6 |
| EdgeGatewayAWSFailure | `increase(edge_gateway_dynamodb_putitem_total{result="error"}[10m]) > 0` 또는 STS 실패 | critical | 결정 6, DynamoDB stale 조용한 실패 |
| InfluxDiskHigh | SSD 사용률 > 85% | warning | 결정 4 |
| EtcdFsyncSlow | `histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])) > 0.5` | critical | 결정 5, 260420 재발 |
| NodeDown | `up{job="node-exporter"} == 0` | critical | 결정 4 |
| EMQXACLDenySpike | `increase(emqx_authorization_deny[10m]) > 0` | warning | 결정 6, 위조/부트스트랩 시도 |
| HubbleDropSpike | `increase(hubble_drop_total[10m]) > <임계>` | warning | 결정 9, 네트워크 drop 급증 (선택) |
| Watchdog | `vector(1)` (상시 발화) | none | 알림 파이프 하트비트. alertmanager 24h 라우트로 Prometheus→AM→Discord 생존 감시 (내부 dead-man's-switch). 외부 수신처는 결정 9 healthchecks.io 로 구현됨 |

## Secret (K8s, 환경별 사전 생성)

| Secret | 소비자 | 용도 |
|---|---|---|
| `alertmanager-discord` | alertmanager | Discord webhook URL (`webhook_url_file`) |
| `cloudflared-token` | cloudflared | Cloudflare Tunnel 토큰 |
| `grafana-admin` | grafana | admin password (`__FILE`) |
| `influxdb-admin-token` | telegraf-freshness, prometheus | InfluxDB 쿼리/스크랩 토큰 (storage phase 토큰 재사용, monitoring NS에 복제 필요). prometheus 는 influxdb 스크랩 Bearer 인증에 사용 |
| `alertmanager-healthchecks` | alertmanager | healthchecks.io ping URL (`url_file`). git 평문 금지 |

배포 순서·sync-wave·의존 검증은 [edge/argocd/README.md](../../edge/argocd/README.md) sync-wave 정본 참조.

## 후속 작업 (본 phase 범위 외, 추후 합류)

- **eBPF 기반 관측 (syscall 레벨)**: Tetragon 등. 본 phase 의 Hubble(네트워크 flow)와 별개.
- **NetworkPolicy**: visibility 스택 내부 통신 정책. Hubble dependency map 기반 (security.md 결정 9 보류분 재평가).
