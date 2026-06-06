# AWS Resources Knowledge

> web-backend phase 는 k8s/helm 이 아닌 AWS managed 서비스 (Lambda, API Gateway WebSocket, DynamoDB, S3, IAM Roles Anywhere, GitHub OIDC) 로 구성. 따라서 기존 per-technology knowledge 형식 대신 **단일 카탈로그** 형태로 작성.

## 계정 / 리전

**리전**: `ap-northeast-2` (서울)

리전 고정 이유: GIST IdP (`account.gistory.me`) 와 동일 지리 — JWKS 조회 latency 최소화. 모든 ARN·endpoint 는 이 리전 기준.

## IAM Roles

### Lambda 실행 역할

| Role | 권한 | 사용 함수 |
|---|---|---|
| `gikview-ws-authorizer-{stage}-role` | CloudWatch Logs | `gikview-ws-authorizer-{stage}` |
| `gikview-ws-handler-{stage}-role` | `gikview-connections-{stage}` CRUD · `gikview-rooms-{stage}` Scan · API GW ManageConnections · CloudWatch Logs | `gikview-ws-handler-{stage}` |
| `gikview-ws-broadcast-{stage}-role` | `gikview-rooms-{stage}` DynamoDB Streams 읽기 + Scan · `gikview-connections-{stage}` Scan/DeleteItem · API GW ManageConnections · CloudWatch Logs | `gikview-ws-broadcast-{stage}` |

`{stage}` = `prod` | `dev`. 두 stage 가 **각각 별도 role** — 권한 격리. handler 와 broadcast 모두 `gikview-rooms-{stage}` Scan 권한 필요 — 둘 다 전체 rooms 맵을 client 로 push 하기 때문 (`getState` / Streams 트리거 모두 동일하게 rooms Scan 후 전체 state 전송). broadcast 만 Streams 읽기 권한 추가 보유.

### CI/CD 역할 (GitHub OIDC trust)

| Role | 권한 |
|---|---|
| `gikview-frontend-ci-prod` | S3 sync → `gikview-frontend-prod` · CloudFront CreateInvalidation |
| `gikview-frontend-ci-dev`  | S3 sync → `gikview-frontend-dev` |
| `gikview-backend-ci-prod`  | S3 PutObject → `gikview-backend-prod` · `lambda:UpdateFunctionCode` (authorizer/handler/broadcast) |
| `gikview-backend-ci-dev`   | S3 PutObject → `gikview-backend-dev` · `lambda:UpdateFunctionCode` (authorizer/handler/broadcast) |

dev role 은 CloudFront invalidation 권한 없음 — dev 는 캐시 무효화 불필요 (origin 직접 hit 비중 큼). Lambda 코드 갱신은 S3 업로드 후 `UpdateFunctionCode --s3-bucket --s3-key` 호출.

### edge → DynamoDB (IAM Roles Anywhere)

| Role | Trust | 권한 |
|---|---|---|
| `gikview-edgegw` | step-ca Intermediate CA (IAM Roles Anywhere) | DynamoDB PutItem/UpdateItem → `gikview-rooms-prod` |

edge gateway 가 mTLS 인증서로 STS credentials 교환 후 rooms 테이블 업데이트. Streams 가 이 변경을 broadcast Lambda 로 전파.

## DynamoDB

### `gikview-rooms-{stage}`

```yaml
# Streams 설정 (필수)
StreamSpecification:
  StreamEnabled: true
  StreamViewType: NEW_IMAGE   # broadcast Lambda 가 변경 후 값만 필요
```

- broadcast Lambda 의 **유일한 트리거 소스**. Streams 비활성화 시 실시간 push 동작 안 함.
- edge gateway (`gikview-edgegw` role) 가 직접 PutItem/UpdateItem.

### `gikview-connections-{stage}`

```yaml
KeySchema:
  - AttributeName: connection_id
    KeyType: HASH
AttributeDefinitions:
  - AttributeName: connection_id
    AttributeType: S
# TTL 활성화
TimeToLiveSpecification:
  AttributeName: expires_at    # Number, Unix timestamp
  Enabled: true
```

- `connection_id` (PK, String): API GW 발급 connectionId 그대로 저장.
- `expires_at` (Number): handler 가 `$connect` 시 `now + 7200` (2h) 세팅. TTL 은 **보조 수단** — 실제 삭제까지 최대 48h 지연.
- 주 정리 수단: broadcast 가 PostToConnection 시 410 GoneException 수신 → 즉시 DeleteItem.

## API Gateway WebSocket API

**API ID**: `7t5yk4e8vf`

| Stage | Endpoint |
|---|---|
| prod | `wss://7t5yk4e8vf.execute-api.ap-northeast-2.amazonaws.com/prod/` |
| dev  | `wss://7t5yk4e8vf.execute-api.ap-northeast-2.amazonaws.com/dev/` |

단일 API 에 두 stage. Lambda 함수는 stage 별 분리 (`-prod` / `-dev`).

### Routes

| Route | 통합 Lambda | Authorizer |
|---|---|---|
| `$connect`    | `gikview-ws-handler-{stage}` | `gikview-ws-authorizer-{stage}` |
| `$disconnect` | `gikview-ws-handler-{stage}` | 없음 |
| `ping`        | `gikview-ws-handler-{stage}` | 없음 |
| `getState`    | `gikview-ws-handler-{stage}` | 없음 |

- Authorizer 는 `$connect` 만 — 연결 수립 시 1회 JWT 검증, 이후 메시지는 connection 단위로 신뢰.
- routeKey 분기는 handler 내부 (`event.requestContext.routeKey`) 에서 처리.

### Management API endpoint (server → client push)

event 에서 파생 — 하드코딩 금지:

```python
endpoint = f"https://{event['requestContext']['domainName']}/{event['requestContext']['stage']}"
```

dev/prod 동일 코드로 동작.

### Access log 제약 (보안)

`$connect` 의 query string 에 JWT 가 들어옴 (`?token=...`). API GW access log 포맷에서 **query string 필드 제거** — 평문 토큰이 CloudWatch Logs 에 적재되지 않도록.

## Lambda

### 함수 목록

| 함수 | 트리거 | 역할 |
|---|---|---|
| `gikview-ws-authorizer-{stage}` | API GW `$connect` (Lambda Authorizer) | JWT 검증 → Allow/Deny IAM 정책 반환 |
| `gikview-ws-handler-{stage}`    | API GW `$connect` / `$disconnect` / `ping` / `getState` | connection CRUD · 초기 state push · pong |
| `gikview-ws-broadcast-{stage}`  | DynamoDB Streams (`gikview-rooms-{stage}`) | 전체 connection Scan → Management API push · 410 처리 |

### 환경변수 (콘솔 설정, 배포 시 변경 없음)

| 함수 | 변수 | prod | dev |
|---|---|---|---|
| handler   | `CONNECTIONS_TABLE` | `gikview-connections-prod` | `gikview-connections-dev` |
| handler   | `ROOMS_TABLE`       | `gikview-rooms-prod`       | `gikview-rooms-dev` |
| broadcast | `CONNECTIONS_TABLE` | `gikview-connections-prod` | `gikview-connections-dev` |
| broadcast | `ROOMS_TABLE`       | `gikview-rooms-prod`       | `gikview-rooms-dev` |
| broadcast | `WS_ENDPOINT`       | `https://7t5yk4e8vf.execute-api.ap-northeast-2.amazonaws.com/prod` | `https://7t5yk4e8vf.execute-api.ap-northeast-2.amazonaws.com/dev` |

broadcast 가 Streams 의 `NewImage` payload 만 사용하지 않고, 트리거 시점마다 rooms 전체를 Scan 해 full state 를 push — 따라서 handler 와 동일하게 `ROOMS_TABLE` 필요. broadcast 의 `WS_ENDPOINT` 는 Streams 이벤트에 `requestContext` 가 없어 event 파생 불가 → 환경변수 필수 (handler 는 event 에서 파생). authorizer 는 환경변수 없음 — JWKS URL은 OIDC discovery 로 조회.

## S3

| 버킷 | 용도 |
|---|---|
| `gikview-frontend-prod` | CloudFront origin (prod web) |
| `gikview-frontend-dev`  | CloudFront origin (dev web) |
| `gikview-backend-prod`  | Lambda zip artifact 저장 (prod) |
| `gikview-backend-dev`   | Lambda zip artifact 저장 (dev) |

CI 가 zip 을 backend 버킷에 업로드 후 `lambda:UpdateFunctionCode --s3-bucket --s3-key` 로 함수 코드 갱신.

## CloudFront / ACM

| 리소스 | 도메인 |
|---|---|
| ACM 인증서 | `gikview.org`, `*.gikview.org` |
| `gikview-frontend-prod-dist` | `gikview.org`, `www.gikview.org` |
| `gikview-frontend-dev-dist`  | `dev.gikview.org` |

ACM 인증서는 `us-east-1` 리전 (CloudFront 요구사항) — 다른 리소스와 다른 리전임에 주의.

## 알려진 주의사항

- **`GoneException` (HTTP 410) at PostToConnection**: 클라이언트가 이미 연결 종료 (브라우저 닫음, 네트워크 끊김). broadcast/handler 코드에서 410 만 catch 해 `gikview-connections` 에서 즉시 DeleteItem. 다른 4xx/5xx 는 raise (TTL fallback 도 있지만 stale 누적 방지).

- **DynamoDB TTL 삭제 지연 최대 48h**: TTL 은 보조 수단으로만 신뢰. 주 정리는 broadcast 의 410 처리. broadcast 가 한동안 트리거 안되면 stale connection 이 connections 테이블에 누적 → Scan 비용 증가.

- **API GW idle timeout 10분 / max connection 2h**: client 가 8분 주기 ping 안 보내면 `$disconnect` 트리거. 2h 가 차도 강제 종료. 두 경우 모두 client 가 `onclose` → 재연결 + 토큰 만료 확인 + silent renew.

- **JWT query string 평문 노출**: WebSocket 프로토콜이 헤더 인증 불가 → `?token=` 으로 전달. access log 의 query string 필드 제거 필수. 토큰은 인메모리 보관 (XSS 방어), localStorage 금지.

- **JWKS 매 요청마다 IdP 호출하면 latency 폭증**: authorizer 가 Lambda 실행 컨텍스트 (전역 변수) 에 JWKS 캐싱. cold start 1회만 IdP 조회, warm container 는 재사용. 키 로테이션 대비해 캐시 만료 (예: 1h) 두기.

- **Streams `NEW_IMAGE` 활성화 (트리거 용도)**: broadcast 의 payload 계산엔 `NewImage` 자체를 안 쓰지만 (트리거 시점마다 rooms 전체 Scan해 full state 를 push), Streams 트리거 등록에는 view type 이 필요 → `NEW_IMAGE` 유지. `OLD_IMAGE` 추가 시 비용·페이로드만 증가, 효용 없음. `REMOVE` eventName 은 skip (room 삭제는 broadcast 대상 아님).

- **connections Scan 페이지네이션 미구현**: 현재 규모 (GIST 내부) 에서 단순 Scan 충분. 1MB / 1000 item 초과 시 `LastEvaluatedKey` 루프 필요. 연결 수가 수천 단위로 늘면 Scan 비용도 함께 검토.

- **$connect 가 HTTP 200 반환 안 하면 API GW 연결 거부**: handler 의 `$connect` 분기에서 PutItem 후 반드시 `{"statusCode": 200}` return. authorizer Allow 와 별개로 handler 응답도 200 이어야 연결 수립.

- **dev/prod Lambda 함수 분리, 단일 API GW**: 함수 ARN 이 stage 별 다르므로 Lambda 통합 설정도 stage variable (`${stageVariables.handlerArn}` 형태) 또는 stage 별 deployment 로 라우팅. dev 변경이 prod 함수에 영향 주지 않도록 환경 격리.

## 환경별 분리 필요 항목

| 항목 | dev | prod |
|---|---|---|
| API GW stage          | `dev`  | `prod` |
| `CONNECTIONS_TABLE`   | `gikview-connections-dev` | `gikview-connections-prod` |
| `ROOMS_TABLE`         | `gikview-rooms-dev`       | `gikview-rooms-prod` |
| `WS_ENDPOINT` (broadcast) | `https://7t5yk4e8vf.execute-api.ap-northeast-2.amazonaws.com/dev` | `https://7t5yk4e8vf.execute-api.ap-northeast-2.amazonaws.com/prod` |
| handler 함수 ARN      | `gikview-ws-handler-dev`    | `gikview-ws-handler-prod` |
| broadcast 함수 ARN    | `gikview-ws-broadcast-dev`  | `gikview-ws-broadcast-prod` |
| authorizer 함수 ARN   | `gikview-ws-authorizer-dev` | `gikview-ws-authorizer-prod` |
| frontend S3 bucket    | `gikview-frontend-dev` | `gikview-frontend-prod` |
| backend S3 bucket     | `gikview-backend-dev`  | `gikview-backend-prod` |
| CloudFront 도메인     | `dev.gikview.org` | `gikview.org`, `www.gikview.org` |
| CI role ARN (frontend)| `gikview-frontend-ci-dev` | `gikview-frontend-ci-prod` |
| CI role ARN (backend) | `gikview-backend-ci-dev`  | `gikview-backend-ci-prod` |
