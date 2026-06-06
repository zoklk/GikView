# backend

- 작성일: 2026-06-06
- 상태: 작업 중

웹서비스 실시간 상태 전달 백엔드. AWS API Gateway WebSocket + Lambda + DynamoDB.
프론트엔드는 별도 문서. edge → DynamoDB 적재까지는 [edge/pipeline.md](../edge/pipeline.md).

## 다이어그램

<!-- TODO: images/web-backend-architecture.png 추가 -->

## 구성

| Lambda | 소스 | 트리거 | 역할 |
|---|---|---|---|
| handler | `web/backend/handler.py` | API Gateway WebSocket route (`$connect`, `$disconnect`, `ping`, `getState`) | 연결 수명주기 + 클라이언트 요청 처리 |
| broadcast | `web/backend/broadcast.py` | DynamoDB Streams (Rooms 테이블 `INSERT`/`MODIFY`) | 방 상태 변경 → 전 연결에 push |
| authorizer | `web/backend/authorizer.py` | API Gateway Lambda authorizer (`$connect`) | JWT 검증 후 Allow/Deny 정책 반환 |

DynamoDB 테이블 (환경변수로 주입):
- `CONNECTIONS_TABLE` — PK `connection_id`, `expires_at` TTL 속성(7200s)
- `ROOMS_TABLE` — PK `room_id`, `occupied` bool. edge 파이프라인이 upsert, Streams 소스

## 결정 사항

### 1. 전송 방식: HTTP polling 대신 WebSocket push (2026-06-06)

- **선택**: API Gateway WebSocket. 연결 수립 시 1회 인증 후 server-push 로 상태 전달.
  `$connect` 시 `connection_id` 를 Connections 테이블에 put, `$disconnect` 시 delete. broadcast 는
  Connections 를 scan → 각 connection 에 `post_to_connection`, `GoneException` 이면 stale 로 보고 delete
- **대안**: HTTP polling (프론트가 주기적으로 상태 조회)
- **이유**: polling 은 JWT 검증이 매 요청 필수 → CloudFront 캐싱 효율 하락(인증 헤더로 캐시 분기).
  WebSocket 은 연결 수립 시 1회만 인증(결정 5 authorizer), 이후 push 기반이라 검증 반복 없음.
  서버리스 유지 — 상시 컴퓨트 0, connection 상태는 DynamoDB 에 외부화해 Lambda 무상태성과 양립
- **트레이드오프**: 연결 수 커지면 broadcast 의 full scan + N회 post 가 선형 증가 → 대규모면
  per-room 구독 인덱스/핀포인트 fan-out 필요. 현 규모(단일 건물 방 모니터링)에선 과설계

### 2. 패키징: ECR 컨테이너 이미지 대신 zip (2026-06-06)

- **선택**: Lambda 3종을 단일 zip 으로 패키징(핸들러 attribute 만 분기). 의존성은
  `PyJWT[crypto]==2.13.0` 만 번들, boto3/botocore 는 Lambda 런타임 기본 포함
- **대안**: ECR 컨테이너 이미지 Lambda
- **이유**: 컨테이너 이미지는 cold start 시 이미지 pull 단계가 추가돼 latency 증가. 의존성이 가벼워
  (단일 패키지) 컨테이너 이미지의 이점(대용량 의존/커스텀 런타임)이 불필요
- **트레이드오프**: 향후 의존성이 zip 한계(250MB unzipped)에 근접하면 재검토 필요. 현재는 무관

### 3. 상태 push 를 DynamoDB Streams로 트리거 (2026-06-06)

- **선택**: Rooms 테이블에 Streams 활성화 → `INSERT`/`MODIFY` 이벤트만 broadcast Lambda 가 소비.
  edge 파이프라인의 DynamoDB upsert 가 그대로 push 트리거가 됨
- **대안**: edge gateway 가 직접 WebSocket/SNS 로 push, 프론트 폴링, EventBridge 경유
- **이유**: edge 와 web 간 직접 결합 0 — edge 는 DynamoDB 만 알면 됨(pipeline.md 결정 1 의 SRP 연장).
  단일 진실원천(DynamoDB) 이 변경되면 자동 전파. `REMOVE` 이벤트는 무시(방 삭제는 상태 변경 아님)
- **트레이드오프**: Streams → Lambda 전파 지연(보통 <1s) 추가. edge upsert 가 실제 값 변화 없이
  쓰면 불필요 broadcast 발생 가능 (현재 idempotent 필터 없음 — 후속 작업 후보)

### 4. 초기 상태는 client-pull (`getState`), 갱신은 server-push (2026-06-06)

- **선택**: 클라이언트 연결 직후 `getState` route 호출 → handler 가 Rooms 전체 scan 해 그 연결에만 응답.
  이후 변경분은 broadcast 가 push. `ping`/`pong` 으로 connection keepalive
- **대안**: `$connect` 시 서버가 전체 상태 자동 push, 매번 폴링
- **이유**: `$connect` 핸들러는 가볍게(연결 등록만) 유지 — authorizer 통과·연결 확립과 데이터 적재 책임
  분리. 클라이언트가 준비된 시점에 명시적으로 상태 요청 → race 회피
- **트레이드오프**: 클라이언트 왕복 1회 추가. handler 와 broadcast 가 동일 state 직렬화 로직
  중복(`type:state`, `rooms`, `timestamp` 형태) — 공유 모듈로 추출 여지

### 5. 인증: gistory OIDC JWT 를 Lambda authorizer 에서 검증 (2026-06-06)

- **선택**: `$connect` 쿼리스트링 `token` 의 JWT 를 authorizer 가 검증. gistory OIDC discovery
  (`api.account.gistory.me`) 에서 JWKS 받아 RS256 서명 검증, `iss`/`aud`(client_id)/`exp`/`sub` 필수.
  JWKS 는 1h 캐시. 성공 시 `sub`/`email` 을 context 로 전달
- **대안**: 자체 세션 토큰, API key, Cognito authorizer
- **이유**: 학내 계정(gistory) SSO 재사용 — 자체 사용자 DB 불필요. authorizer 분리로 검증 책임이
  비즈니스 핸들러에서 빠짐. JWKS 캐시로 매 연결마다 discovery 호출 회피
- **트레이드오프**: WebSocket 은 헤더 커스터마이즈가 제한적이라 토큰을 쿼리스트링으로 전달 →
  접속 URL/로그에 노출 위험(만료 짧게 유지로 완화). discovery/JWKS 엔드포인트 장애 시 신규 연결 차단
  (캐시 유효 구간은 견딤)