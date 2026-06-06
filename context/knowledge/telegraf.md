# telegraf — 운영 지식 메모

---

## 이미지 / 버전

**채택**: `telegraf:1.38-alpine` (`docker.io/library/telegraf:1.38-alpine`)

InfluxData 공식, alpine 기반 최소 이미지. `1.38` 마이너 핀 — 1.39 출시 시 release notes 확인 후 업그레이드.

InfluxDB 3 Core 와의 호환: `outputs.influxdb_v2` plugin 으로 v2 HTTP API write endpoint 사용. 1.38 시리즈는 신규 `outputs.influxdb_v3` plugin 도 포함하나, v2 경로가 안정·문서화 완비라 본 프로젝트는 v2 사용. InfluxDB 3 Core 의 v2 API 가 `organization` 필드를 무시(Core 미지원)하므로 `""` 로 둠.

본 프로젝트 역할: EMQX shared subscription 구독 → 매 메시지 InfluxDB 3 write. Edge Gateway 와 share group 분리 (`$share/telegraf/...`) 로 모든 메시지를 독립 수신. InfluxDB write 책임 전담 (SRP — Edge Gateway 는 상태 감지·DynamoDB upsert 전담).

Helm chart: 자체 작성. 공식 `influxdata/telegraf` chart 는 DaemonSet 구조라 본 Deployment 패턴에 부적합.

## 주요 설정

`telegraf.conf` 를 `telegraf-config` ConfigMap 으로 마운트. Reloader 가 변경 시 rollout.

```toml
# telegraf.conf

[agent]
  interval = "5s"
  flush_interval = "5s"
  omit_hostname = true

# ── Input: EMQX shared subscription ──────────────────────────────────────────
[[inputs.mqtt_consumer]]
  servers = ["ssl://emqx.gikview.svc.cluster.local:8883"]
  topics  = ["$share/telegraf/sensors/+/occupancy"]
  qos     = 1
  client_id = "telegraf-${POD_NAME}"   # replica 간 client_id 충돌 방지 (Pod명 env 주입)
  name_override = "occupancy"          # 기본 mqtt_consumer 대신 도메인 measurement 명

  # mTLS (step-ca 발급 client cert — CN=telegraf)
  tls_ca   = "/tls/ca.crt"       # Root CA (chain 검증용)
  tls_cert = "/tls/tls.crt"      # leaf + Intermediate
  tls_key  = "/tls/tls.key"
  tls_server_name = "emqx.gikview.svc.cluster.local"

  data_format = "json"
  json_string_fields = ["bssid"]
  json_time_key      = "timestamp"
  json_time_format   = "2006-01-02T15:04:05Z"

# ── Processor 0: topic 에서 device_id 추출 ───────────────────────────────────
[[processors.regex]]
  order = 0
  [[processors.regex.tags]]
    key    = "topic"
    pattern = "^sensors/([^/]+)/occupancy$"
    replacement = "${1}"
    result_key  = "device_id"

# ── Processor 1: device_id → room_id 변환 ────────────────────────────────────
[[processors.lookup]]
  order  = 1
  # telegraf-lookup ConfigMap (mapping-generator 생성): device_id → room_id CSV
  files  = ["/lookup/mapping.csv"]
  format = "csv_key_values"
  # tag device_id 값을 lookup key 로 사용 → 매칭 행의 모든 컬럼(room_id 등)을 tag/field 로 머지
  key    = '{{.Tag "device_id"}}'

# ── Output: InfluxDB 3 Core ──────────────────────────────────────────────────
[[outputs.influxdb_v2]]
  urls         = ["http://influxdb.gikview.svc.cluster.local:8181"]
  token        = "$INFLUXDB_TOKEN"   # env 로 주입 (influxdb-admin-token Secret)
  organization = ""                  # InfluxDB 3 Core 는 org 개념 없음
  bucket       = "gikview"
```

### device_id 추출 방식

MQTT `inputs.mqtt_consumer` 가 topic 을 tag 로 자동 포함. `processors.regex` (order 0) 가 topic 에서 device_id 추출 → `processors.lookup` (order 1) 가 `telegraf-lookup` CSV 에서 room_id 매핑.

### InfluxDB 데이터 모델

- measurement: `occupancy`
- tags: `room_id`, `bssid`
- fields: `occupied` (bool), `rssi` (int), `device_id` (string)
- timestamp: 메시지 `timestamp` 필드 (RFC3339 UTC `Z`)

`device_id` 를 tag 로 두지 않는 이유: 디바이스 교체 시 `room_id` series 연속성 유지가 본질. `device_id` 는 field — 디버깅용, 쿼리 필터 기준 아님.

## 알려진 주의사항

- **client_id 중복**: replica=2 동일 `client_id` 면 EMQX 가 서로 킥아웃. `client_id = "telegraf-${POD_NAME}"`, `POD_NAME` = `fieldRef: metadata.name` env 주입.

- **$share 토픽 EMQX ACL**: `telegraf` CN 은 `sensors/+/occupancy` subscribe 권한 보유 (mapping-generator 가 `emqx-acl` 생성). EMQX 는 `$share/<group>/` prefix 제거 후 ACL 매칭 — ACL 에는 prefix 없는 `sensors/+/occupancy` 로 작성.

- **processors.lookup CSV 경로**: `telegraf-lookup` ConfigMap 을 mapping-generator (security wave `-1`) 가 생성. Telegraf 가 먼저 뜨면 lookup 파일 없어 processor 오류 — Argo CD wave 로 선행 보장.

- **InfluxDB 3 Core organization**: Core 는 organization 개념 미지원. `outputs.influxdb_v2.organization = ""` 로 둠. 비어있지 않은 값은 unknown org 오류.

- **JSON timestamp 포맷**: Go reference time `2006-01-02T15:04:05Z` 사용. ESP8266 가 `Z` suffix 고정이라 충분. offset 포함 ISO 8601 (`07:00`) 은 본 사례에 불필요.

- **mTLS cert chain**: `tls_cert` = `tls.crt` (leaf + Intermediate). EMQX 가 OTP `ssl` 의 chain 완성을 위해 Intermediate 필수 (`context/knowledge/emqx.md` 결정 12). cert-manager 발급 Secret 의 `tls.crt` 자동 충족.

- **replica HA**: share group 에 replica=2 면 메시지 분산 수신 (group 전체로 모든 메시지 처리). InfluxDB write 멱등 (같은 timestamp + tag 세트면 덮어씀). 1개 다운 시 나머지가 전체 처리 — QoS 1 + EMQX 버퍼로 무손실.

## 환경별 분리 필요 항목

| 항목 | dev (alpha cluster) | prod (edge) |
|------|-----|------|
| `servers` (EMQX 주소) | `ssl://emqx.gikview.svc.alpha.nexus.local:8883` | `ssl://emqx.gikview.svc.cluster.local:8883` |
| `tls_server_name` | `emqx.gikview.svc.alpha.nexus.local` | `emqx.gikview.svc.cluster.local` |
| `nodeSelector` | 없음 (alpha worker 분산) | hardAntiAffinity e-s2/e-s3 |
| `replicaCount` | `1` | `2` |
| `resources.requests.memory` | `64Mi` | `128Mi` |
| `resources.limits.memory` | `128Mi` | `256Mi` |
