# Phase: backend

>gikview 의 백엔드. 다른 phase 와 달리 **k8s/helm이 아닌 AWS managed (Lambda + API Gateway WebSocket + DynamoDB)** 위에 구성됨.
>이 phase 의 작업 단위는 세 Lambda 함수(`authorizer`, `handler`, `broadcast`) 코드 작성·갱신이며, 그 외 AWS 리소스 (IAM role, DynamoDB 테이블, API GW route, S3, CloudFront, ACM, OIDC trust) 와 CI 파이프라인은 이미 완료된 상태.
>따라서 본 문서는 코드 작성 시 필요한 컨텍스트를 한 곳에 모아두기 위한 정보용 phase.


## 전제 (완료된 작업, 참고용)

- **AWS 리소스 프로비저닝 완료**: IAM role, DynamoDB 테이블 (rooms·connections, TTL/Streams 설정 포함), API GW WebSocket API (`7t5yk4e8vf`, route 4종), S3 버킷, CloudFront + ACM, GitHub OIDC trust 모두 콘솔에서 직접 생성. 세부 카탈로그는 `context/knowledge/aws-resources.md` 참조.
- **CI 파이프라인 완료**: `.github/workflows/backend.yml` 이 dev/prod 분기로 zip 빌드 → S3 PutObject → `lambda:UpdateFunctionCode` 호출. GitHub OIDC로 `gikview-backend-ci-{stage}` role 을 STS AssumeRoleWithWebIdentity. Lambda 환경변수는 콘솔에서 1회 설정 — CI 가 코드만 갱신.

## Service: gikview-ws-authorizer

**technology**: Python (AWS Lambda)
**dependency**: [none]
**artifacts**: lambda
**references**: [context/knowledge/aws-resources.md]

API Gateway WebSocket `$connect` 의 Lambda Authorizer. JWT 검증 후 IAM 정책을 반환해 연결 수립 여부를 결정한다.

- 트리거: API GW `$connect` route (Lambda Authorizer 타입)
- 입력: `event.queryStringParameters.token` (PKCE 로 발급된 access_token)
- 검증 절차:
  - token 누락 → `raise Exception("Unauthorized")` (API GW 401 응답)
  - GIST IdP discovery 로 JWKS 조회
    (`https://api.account.gistory.me/.well-known/openid-configuration` → `jwks_uri`)
  - JWT 검증 항목: 서명, `exp`, `iss`, `aud`
  - 실패 → `raise Exception("Unauthorized")`
- 출력 (Allow):
  - `principalId`: `{sub}`
  - `policyDocument.Statement[0]`: `Effect=Allow`, `Action=execute-api:Invoke`, `Resource={methodArn}`
  - `context`: `{ userId: {sub}, email: {email} }` — handler 가 `event.requestContext.authorizer` 로 접근
- **JWKS 캐싱**: Lambda 실행 컨텍스트 전역 변수에 보관. cold start 1회만 IdP 조회. 키 로테이션 대비 만료 시간 (예: 1h) 적용.
- 환경변수: 없음 (JWKS URL 은 discovery 로 동적 조회)
- IAM 권한: CloudWatch Logs 만

## Service: gikview-ws-handler

**technology**: Python (AWS Lambda)
**dependency**: [gikview-ws-authorizer]
**artifacts**: lambda
**references**: [context/knowledge/aws-resources.md, context/knowledge/front-back-spec.md]

API Gateway WebSocket 의 `$connect` / `$disconnect` / `ping` / `getState` route 통합 함수. `event.requestContext.routeKey` 기준으로 내부 분기한다.

- 트리거: API GW WebSocket route 4종 (단일 함수가 모두 처리)
- 분기 (`event.requestContext.routeKey`):
  - **`$connect`**:
    - `connection_id = event.requestContext.connectionId`
    - DynamoDB PutItem → `gikview-connections-{stage}`: `{ connection_id, expires_at: now + 7200 }`
    - return `{"statusCode": 200}` — 누락 시 API GW 가 연결 거부
    - authorizer context 접근 예: `user_id = event["requestContext"]["authorizer"]["userId"]`
  - **`$disconnect`**:
    - DeleteItem → `gikview-connections-{stage}(connection_id)`
    - return 200
  - **`ping`**:
    - Management API PostToConnection(connection_id) → `{"type": "pong"}`
    - return 200
  - **`getState`**:
    - DynamoDB Scan → `gikview-rooms-{stage}` → `{ room_id: occupied }` 맵 구성
    - PostToConnection → `{"type": "state", "rooms": {...}, "timestamp": now_iso8601}`
    - return 200
- **Management API endpoint** (코드 내부에서 event 로 파생):
  ```python
  endpoint = f"https://{event['requestContext']['domainName']}/{event['requestContext']['stage']}"
  ```
- 환경변수:
  - `CONNECTIONS_TABLE` — `gikview-connections-{stage}`
  - `ROOMS_TABLE` — `gikview-rooms-{stage}`
- IAM 권한: connections CRUD · rooms Scan · API GW ManageConnections · CloudWatch Logs

## Service: gikview-ws-broadcast

**technology**: Python (AWS Lambda)
**dependency**: [gikview-ws-handler]
**artifacts**: lambda
**references**: [context/knowledge/aws-resources.md, context/knowledge/front-back-spec.md]

`gikview-rooms-{stage}` 의 DynamoDB Streams 변경 이벤트를 받아, 전체
connection 에 `state` 메시지를 push 한다.

- 트리거: DynamoDB Streams (`gikview-rooms-{stage}`, `NEW_IMAGE`)
- 처리 (각 `event.Records` 순회 — Streams 가 트리거 신호로만 사용됨):
  - `eventName` 이 `INSERT` / `MODIFY` 가 아니면 skip (`REMOVE` 무시)
  - **`NewImage` payload 는 안 쓴다** — 단일 room 변경분이 아니라 rooms 전체 맵을 매번 push 한다 (getState 와 동일 페이로드, `context/knowledge/front-back-spec.md` 의 `state` 메시지 포맷)
  - DynamoDB Scan → `gikview-rooms-{stage}` → `{ room_id: occupied }` 맵 구성
  - DynamoDB Scan → `gikview-connections-{stage}` → 전체 `connection_id` 목록
  - 각 connection_id 에 Management API PostToConnection → `{"type": "state", "rooms": {...}, "timestamp": now_iso8601}`
  - **`GoneException` (410) 수신 시**: 즉시 `gikview-connections` 에서 DeleteItem (stale 정리). 다른 예외는 raise.
- Management API endpoint: Streams 이벤트엔 `requestContext` 없음 → 환경변수
  `WS_ENDPOINT` 로 구성. handler 와 달리 event 파생 불가.
- 환경변수:
  - `CONNECTIONS_TABLE` — `gikview-connections-{stage}`
  - `ROOMS_TABLE` — `gikview-rooms-{stage}` (트리거마다 full Scan 필요)
  - `WS_ENDPOINT` — `https://7t5yk4e8vf.execute-api.ap-northeast-2.amazonaws.com/{stage}`
- IAM 권한: rooms Streams 읽기 + rooms Scan · connections Scan/DeleteItem · API GW ManageConnections · CloudWatch Logs
- **페이지네이션 미구현**: 현재 규모 충분. 연결 수 1000+ 도달 시 `LastEvaluatedKey` 루프 필요.

---

## 환경별 분리 요약

dev/prod 분리는 단일 API GW (`7t5yk4e8vf`) 내부의 두 stage 와, 각 Lambda함수의 `-dev` / `-prod` suffix 로 이뤄진다. 코드는 단일 소스, env var 와 stage 만 다름. 상세 매핑은 `context/knowledge/aws-resources.md` 의 "환경별 분리 필요 항목" 표 참조.

## 메시지 포맷

세부 JSON 포맷·heartbeat 주기·재연결 알고리즘은 `context/knowledge/front-back-spec.md` 가 단일 진실의 원천이다. 본 phase 는 spec 을 구현하는 Lambda 코드 작성만을 다룬다.
