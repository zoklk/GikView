# Phase: pipeline

센서 데이터 수집·적재·상태 변경 감지 파이프라인 구축. EMQX shared subscription 의 두 워크로드(Telegraf·Edge Gateway)가 **share group 분리** 로 모든 메시지 독립 수신 — Telegraf=raw timeseries → InfluxDB 적재, Edge Gateway=상태 변경 감지 → DynamoDB upsert (SRP 분리). Edge Gateway 의 DynamoDB 접근은 IAM Roles Anywhere + step-ca Intermediate CA 기반 임시 자격증명, 정적 access key 없음.

의존: security phase (EMQX mTLS·step-ca·cert-manager) + storage phase (InfluxDB) 완료 후 배포.

## 디바이스 페이로드 (sensor publish)

`end/arduino/sensor.cpp` 의 `build_sensor_payload()` 출력. topic = `sensors/<device_id>/occupancy`.

```json
{"occupied":true,"timestamp":"2026-06-02T03:04:05Z","bssid":"aa:bb:cc:dd:ee:ff","rssi":-58}
```

- `occupied`: bool — passthrough (InfluxDB field `occupied`, DynamoDB attribute `occupied`).
- `timestamp`: RFC3339 UTC `Z` suffix 고정 (`%Y-%m-%dT%H:%M:%SZ`). InfluxDB timestamp + DynamoDB `timestamp` attribute 로 passthrough.
- `bssid`, `rssi`: AP 정보, InfluxDB only (DynamoDB 미저장).

## Service: telegraf

**technology**: influxdata/telegraf (1.38-alpine)
**dependency**: [emqx, influxdb, mapping-generator]
**artifacts**: helm, docker (자체 ConfigMap)
**node_category**: [pipeline]
**references**: [context/knowledge/telegraf.md, context/knowledge/emqx.md, context/knowledge/influxdb.md]

- Telegraf 1.38 Deployment, replica=2, hard podAntiAffinity (e-s2/e-s3 분산). 1.38 시리즈는 InfluxDB 3 Core 호환 `outputs.influxdb_v2` (v2 HTTP API write) 사용 — `outputs.influxdb_v3` 신플러그인도 동일 시리즈 존재하나 v2 경로가 안정·문서화 완비.
- **Share group**: `$share/telegraf/sensors/+/occupancy`. Edge Gateway `$share/edge-gw/...` 와 반드시 별도 group — 같은 group 이면 분산 라우팅으로 각자 일부만 수신.
- **EMQX mTLS**: client cert CN=`telegraf`. cert-manager Certificate → step-issuer → step-ca. Secret `telegraf-tls`.
  - commonName: `telegraf`
  - duration: `2160h`, renewBefore: `720h`
  - privateKey: ECDSA P-256
  - issuerRef: StepClusterIssuer
- **InfluxDB write**: admin token = `influxdb-admin-token` Secret 의 `token` 키 → env `INFLUXDB_TOKEN`. bucket=`gikview`, org=`""` (InfluxDB 3 Core 미지원).
- **device_id → room_id 변환**: `telegraf-lookup` ConfigMap (mapping-generator wave `-1` 생성). `processors.lookup` 참조 경로 `/lookup/mapping.csv`.
- **tag 추출**: `processors.regex` 로 topic → tag `device_id` 추출.
- **데이터 모델** (InfluxDB):
  - measurement: `occupancy`
  - tags: `room_id`, `bssid`
  - fields: `occupied` (bool), `rssi` (int), `device_id` (string)
  - timestamp: payload `timestamp` 필드 (RFC3339 UTC)
- **ConfigMap 변경 시 rollout** — Reloader annotation:
  - `secret.reloader.stakater.com/reload: "telegraf-tls"` — cert 갱신
  - `configmap.reloader.stakater.com/reload: "telegraf-config,telegraf-lookup"` — 설정·매핑 변경
- **Port**: 없음 (outbound only).
- **리소스**: CPU `50m`/`200m`, Memory `128Mi`/`256Mi`.

## Service: edge-gateway

**technology**: 자체 코드 (Go Deployment)
**dependency**: [emqx, influxdb, mapping-generator]
**artifacts**: helm, docker
**node_category**: [pipeline]
**references**: [context/knowledge/iam-roles-anywhere.md, context/knowledge/emqx.md, context/knowledge/influxdb.md]

- Go Deployment. multi-arch Docker (`linux/amd64`+`linux/arm64`). `aws_signing_helper` 바이너리 멀티스테이지 빌드로 이미지 포함 (`linux/arm64` 필수 — RPi4).
- replica=2, hard podAntiAffinity (e-s2/e-s3 분산).
- **Share group**: `$share/edge-gw/sensors/+/occupancy`, sticky 전략 — publisher connection 단위로 같은 pod 라우팅 → 인메모리 캐시 분산 안전.
- **처리 흐름**:
  1. 메시지 수신 → topic 에서 `device_id` 파싱 → `device-room-mapping` ConfigMap 에서 `room_id` 조회
  2. 인메모리 캐시에서 `room_id` 현재 상태 확인
  3. 캐시 miss → InfluxDB `last()` 쿼리로 복원 (pod 재시작·takeover)
  4. 상태 변경 감지 → DynamoDB `PutItem` (IAM Roles Anywhere 임시 자격증명)
  5. 캐시 갱신
- **EMQX mTLS**: client cert CN=`edge-gateway`. cert-manager Certificate → step-issuer → step-ca. Secret `edge-gateway-tls`.
  - commonName: `edge-gateway`
  - duration: `2160h`, renewBefore: `720h`
  - privateKey: ECDSA P-256
  - issuerRef: StepClusterIssuer
  - 이 cert 를 EMQX mTLS + IAM Roles Anywhere 양쪽 동일 사용.
- **IAM Roles Anywhere**: 정적 access key 없음. signing helper `credential_process`.
  - `edge-gateway-tls` Secret → volumeMount `/tls/`
  - ARN 3개 + region → `values-<env>.yaml` → Deployment env 직접 주입 (`TRUST_ANCHOR_ARN`, `PROFILE_ARN`, `ROLE_ARN`, `AWS_DEFAULT_REGION=ap-northeast-2`). ConfigMap 경유 안 함 — ARN 변경 빈도 ~0 + GitOps(ArgoCD) 하에 `kubectl edit` 즉시 적용 이득 없음. ARN 은 식별자 평문이라 Secret 강제 안 됨.
  - TTL 1h, signing helper 자동 갱신
  - 상세: `context/knowledge/iam-roles-anywhere.md`
- **InfluxDB 조회**: 캐시 miss 시 admin token 으로 `last()` 쿼리. token = `influxdb-admin-token` Secret → env `INFLUXDB_TOKEN`.
- **DynamoDB 쓰기 — `gikview-rooms`**:
  - PK = `room_id` (String). SK 없음 — 같은 room 의 최신 상태만 유지 (overwrite).
  - attributes:
    - `occupied` (Boolean) — payload passthrough
    - `timestamp` (String) — payload RFC3339 passthrough
  - 작업 = `PutItem` (멱등 overwrite). 시계열 히스토리는 InfluxDB 가 담당.
  - `bssid`/`rssi`/`device_id` 미저장.
- **device-room-mapping**: `device-room-mapping` ConfigMap volumeMount.
- **ConfigMap 변경 시 rollout** — Reloader annotation:
  - `secret.reloader.stakater.com/reload: "edge-gateway-tls"`
  - `configmap.reloader.stakater.com/reload: "device-room-mapping"`
- **Port**: 없음 (outbound only).
- **리소스**: CPU `50m`/`200m`, Memory `64Mi`/`128Mi`.

## ConfigMap

| ConfigMap | 생성 주체 | wave | 소비자 | 키 / 용도 |
|---|---|---|---|---|
| `device-room-mapping` | mapping-generator helm chart (SoT, 사람이 git commit) | `-1` (security) | Edge Gateway volumeMount | `mapping.csv` — `device_id,room_id`. SoT — 다른 CM 도 이걸로 derive |
| `telegraf-lookup` | mapping-generator init Job (`device-room-mapping` derive) | `-1` (security) | Telegraf `processors.lookup` | `mapping.csv` — `device_id,room_id`. Telegraf 1.38 `processors.lookup` CSV 형식 |
| `telegraf-config` | telegraf helm chart (자체 templates) | `2` | Telegraf `/etc/telegraf/telegraf.conf` | `telegraf.conf` — input/processor/output 선언. 환경별 EMQX endpoint·resource limits 분리 (values-<env>.yaml) |

Edge Gateway 의 IAM Roles Anywhere ARN 3개 + region 은 ConfigMap 안 만듦 — `values-<env>.yaml` → Deployment env 직접 주입. 사유는 `## Service: edge-gateway > IAM Roles Anywhere`.

## AWS 구성 (K8s 외부, 웹서비스팀 담당)

쓰기 경로 = Edge Gateway → DynamoDB 직접 (Lambda 없음). 읽기 경로 = API Gateway + Lambda (JWT 검증).

| 구성 요소 | 담당 | 역할 |
|---|---|---|
| DynamoDB `gikview-rooms` | 인프라팀 | 방별 재실 상태 (PK=`room_id`, attrs=`occupied`/`timestamp`) |
| IAM Roles Anywhere | 인프라팀 | Edge Gateway → DynamoDB 쓰기 신뢰 경계 |
| API Gateway (JWT Authorizer) | 인프라팀 / 웹서비스팀 | GIST IdP JWT 검증, 프론트엔드 읽기 경로 |
| Lambda(auth) | 웹서비스팀 | 로그인 |
| Lambda(read) | 웹서비스팀 | DynamoDB 조회 |

## 배포 순서 / 의존 검증

ArgoCD sync-wave 정본은 [edge/argocd/README.md](../../edge/argocd/README.md). 본 phase 는 security phase 완료 (emqx mTLS 전환) + storage phase 완료 (InfluxDB) 후 진입.

의존 검증 (security.md ↔ storage.md ↔ pipeline.md):
- cert-manager + step-issuer + step-ca → telegraf/edge-gateway cert 발급 가능 ✓
- mapping-generator init Job → `device-room-mapping` + `telegraf-lookup` + `emqx-acl` + `step-ca-whitelist` 사전 생성 ✓
- emqx mTLS 전환 → mTLS listener 활성 후 telegraf/edge-gateway 연결 ✓
- InfluxDB → `gikview` database = post-install Job 으로 자동 생성 ✓
- DynamoDB `gikview-rooms` + IAM Roles Anywhere ARN 3개 = K8s 외부 사전 작업 (인프라팀, 사람 1 회)

## 후속 작업 (본 phase 범위 외)

- **Lambda(auth) / Lambda(read)**: 웹서비스팀 구현. 인프라팀은 API Gateway JWT Authorizer + DynamoDB 테이블 + IAM 권한 사전 제공.
- **Heartbeat DaemonSet**: 각 노드 10분 주기 Lambda POST. visibility phase 와 함께 배포.
- **NetworkPolicy**: InfluxDB Pod 접근 = Edge Gateway + Telegraf 만 허용, step-ca NodePort = 학내 IP 대역 한정. Hubble dependency map 기반 (visibility phase).
