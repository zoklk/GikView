# Phase: web-visibility

웹서비스(API Gateway WebSocket + Lambda + DynamoDB)의 **사용자 수요 가시화**. 유입률(`web_connect_total`)로 실사용 규모·피크·공지/광고 효과를 본다. handler 가 `$connect` 를 메모리 누적 후 주기 flush 로 전용 DynamoDB 테이블에 `ADD` → edge monitoring NS 의 Go exporter 가 IAM Roles Anywhere read role 로 read → Prometheus → 기존 Grafana 에 합류. ops 지표(throttle/concurrency/errors)는 대시보드 대신 CloudWatch 무료 알람.

web 은 AWS 관리형 서버리스라 가용성은 AWS 보장 → ops 진단 아닌 demand 분석 전용. CloudWatch `GetMetricData`(yace)는 무료티어 제외라 과금 → 무료인 DynamoDB read 평면 재사용. 비용 0. 근거 [docs/architecture/web/visibility.md](../../docs/architecture/web/visibility.md).

의존: backend phase(Lambda·DynamoDB) + edge-visibility(Prometheus·Grafana) 완료.

## 선행 작업 (배포 전, 운영자 수동)

- **전용 메트릭 테이블 (w-v1)**: `gikview-metrics-{stage}`, PK `metric`(S), 속성 `n`(N), on-demand. **rooms/connections 에 카운터 넣지 말 것** — handler 가 그 테이블을 Scan 해 메트릭 아이템이 방 목록에 섞여 깨짐.
- **IAM Roles Anywhere read 경로 (w-v2)**: Trust Anchor(step-ca Intermediate) 재사용. Role 인라인 `dynamodb:GetItem` on `gikview-metrics-{stage}` (read 전용). Trust Policy `x509Subject/CN = web-visibility` 조건 필수. Profile session policy 로 이중 제한. 상세 `context/knowledge/iam-roles-anywhere.md`.
- **handler Lambda 계측 (w-v3, web/backend 영역)**: `$connect` 를 메모리 +1 누적, "마지막 flush 후 30s 또는 50건"이면 `gikview-metrics-{stage}` 에 `UpdateItem ADD n :delta` 1회 flush 후 0 리셋. 매 connect 동기 write 금지. 코드는 web/backend phase 경로로 배포.
- **CloudWatch 알람 (w-v4)**: 핵심 실패 모드 3종만 알람 → SNS → email(자주 오면 변환 Lambda 경유 Discord). 무료티어 10개 내, `GetMetricData` 미사용, 대시보드 미생성. 전 알람 공통 `treatMissingData=notBreaching`(저트래픽 빈 주기 = OK), `Sum`/5m/1 datapoint.
  - `broadcast` `Errors` ≥ 3: 죽으면 상태 push 중단 → 사용자 화면 조용히 stale (silent failure, 최우선).
  - `authorizer` `Errors` ≥ 3: 죽으면 `$connect` 전면 차단 (IdP userinfo 의존 장애).
  - `handler` `Throttles` ≥ 1: reserved concurrency 한도 도달 = 사용자 연결 거부 (cap 직접 신호).
  - 제외: `Duration`/`Invocations`/`ConcurrentExecutions` 경고 — 결정 1(ops 범위 밖) + flap 노이즈. lead-time 필요 시 후속.

cert-manager Certificate(`CN=web-visibility` → `web-visibility-tls` Secret)는 수동 아님 — exporter chart 가 템플릿(아래 Service). 선행 조건은 step-ca ClusterIssuer 존재(security phase 산출)뿐.

## Service: web-metrics-exporter

**technology**: Go (자체 구현, alpine 베이스 — edge-gateway 와 동일, smoke exec 가능)
**dependency**: [none]
**artifacts**: helm, docker
**node_category**: [monitoring]
**references**: [context/knowledge/iam-roles-anywhere.md, context/knowledge/aws-resources.md]

- DynamoDB 카운터 → Prometheus 브릿지. edge-gateway 의 Roles Anywhere + signing helper 패턴, 방향만 read.
- **자격증명**: `aws_signing_helper` 멀티스테이지 이미지 내장(`credential_process`). sidecar 불필요(자체 코드).
  - **Certificate CR을 chart 가 템플릿** — `CN=web-visibility`, issuerRef = step-ca ClusterIssuer → `web-visibility-tls` Secret 자동 생성(ArgoCD 관리). CN 은 Trust Policy 조건과 대소문자까지 일치.
  - `web-visibility-tls` Secret → `/tls/` 마운트.
  - ARN 3개 + region → `values-<env>.yaml` → Deployment env(`TRUST_ANCHOR_ARN`/`PROFILE_ARN`/`ROLE_ARN`/`AWS_DEFAULT_REGION`).
  - signing helper **arm64 크로스빌드 필수**(amd64 면 exec format error).
- **수집**: 60s 주기 `GetItem(gikview-metrics-{stage}, metric=connect)` → `n` 캐시 → `web_connect_total{stage}` counter 노출. 폴링을 exporter 주기에 묶어 스크랩 빈도와 비용 분리.
- 카운터 0-초기화로 No-data 방지.
- **Port**: `metrics: 9102` (edge-gateway 9101 회피).
- **리소스** (dev / prod): CPU `20m`/`50m`, Memory `32Mi`/`64Mi`. 1 replica, 무상태.

## 스크랩 타겟 (edge Prometheus 추가)

| job | target | path | 비고 |
|---|---|---|---|
| web-metrics-exporter | `web-metrics-exporter.monitoring.svc:9102` | `/metrics` | 60s job interval |

## Grafana 대시보드 (기존 Grafana 추가)

- **web demand 대시보드**(신규), datasource = 기존 Prometheus.
  - 유입률 `rate(web_connect_total[5m])`, 피크 `increase(web_connect_total[1h])`.
  - edge ops 대시보드 3종과 혼재 금지(demand 전용).

## 메트릭 카탈로그

| 메트릭 | type | 의미 | 출처 |
|---|---|---|---|
| `web_connect_total{stage}` | counter | 신규 연결 누적 = 유입률/피크 (유입 이벤트율, 순방문자 아님) | handler `$connect` → DynamoDB → exporter |

ops(`Throttles`/`ConcurrentExecutions`/`Errors`)는 CloudWatch 알람 전용 — Prometheus 미수집.

## Secret

| Secret | 생성 | 소비자 | 용도 |
|---|---|---|---|
| `web-visibility-tls` | chart Certificate CR (자동) | web-metrics-exporter | client cert(CN=web-visibility), read role assume |

## 후속 작업 (범위 외)

- **broadcast 카운터 / 세션 길이 / 순방문자(distinct)**: 각각 중복·해석난해 / $disconnect 신뢰도·단명세션 모호 / counter 불가(userId 집계 필요)로 보류.
- **yace / CloudWatch native 시계열**: cold start·p99·throttle 추세는 `GetMetricData`(과금). 규모 증가로 비용 정당화 시 스케일업 경로.
