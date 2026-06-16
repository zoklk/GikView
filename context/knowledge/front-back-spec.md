# WebSocket 구현 명세

## 전제 아키텍처

```
[브라우저]
  PKCE 로그인 → access_token 인메모리
    |  wss://?token={access_token}
    v
API Gateway WebSocket API
    |
    |-- $connect    → Lambda: gikview-ws-authorizer-{stage} → JWT 검증 후 연결여부 확정
    |               → Lambda: gikview-ws-handler-{stage} → gikview-connections 저장
    |-- getState    → Lambda: gikview-ws-handler-{stage} → gikview-rooms 조회 → 초기 상태 push
    |-- $disconnect → Lambda: gikview-ws-handler-{stage} → gikview-connections 삭제
    |-- ping        → Lambda: gikview-ws-handler-{stage} → pong 응답
    |
    |  (별도 트리거)
DynamoDB Streams (gikview-rooms NEW_IMAGE)
    → Lambda: gikview-ws-broadcast-{stage} → gikview-connections 전체 scan → Management API push
```

---

## **gikview-ws-authorizer-{stage} Lambda 내부에서 직접 검증** (GIST IdP userinfo 호출)

GIST IdP access_token 은 opaque reference token 이라 오프라인 JWKS 서명검증이 불가하다. authorizer 는 userinfo endpoint 에 Bearer 호출해 유효성을 확인한다.

클라이언트가 토큰을 헤더로 전달 불가 (WebSocket 프로토콜 제약) → query string으로 전달.
token 유출 방지를 위해 API Gateway access log에 query string 저장 안 함:
```
wss://7t5yk4e8vf.execute-api.ap-northeast-2.amazonaws.com/{stage}?token={access_token}
```

access_token은 PKCE 로그인 후 프론트 인메모리에 있으므로 별도 엔드포인트 불필요.

---

## 메시지 포맷

### 클라이언트 → 서버

| action | 설명 |
|---|---|
| `ping` | Heartbeat. 서버가 `pong` 반환 |
| `getState` | 전체 방 현재 상태 요청. 서버가 `init` 반환 |

```json
{ "action": "ping" }
{ "action": "getState" }
```

### 서버 → 클라이언트

#### `state`
`getState` 및 dynamoDB 변경시 반환값.

```json
{
  "type": "state",
  "rooms": {
    "room_a_1_lounge": true,
    "room_a_2_lounge": false,
    ...
    "room_a_3_lounge1": false,
  },
  "timestamp": "2026-04-07T10:00:00Z"
}
```

- `rooms`: room_id → occupied 맵. gikview-rooms 전체 항목 포함
- `timestamp`: 서버 기준 현재 시각 (ISO 8601 UTC)

#### `pong`

```json
{ "type": "pong" }
```

---

## Frontend

### 0. 인증 (oidc-client-ts)

PKCE public client. 백엔드 관여 없이 프론트엔드가 전체 흐름 처리.
auth code grant + PKCE로 client_secret 없이 토큰 발급.

```typescript
import { UserManager, WebStorageStateStore } from 'oidc-client-ts';

const SCOPE = 'email name student_id offline_access'; // openid 미요청 → id_token 없음

const mgr = new UserManager({
  metadataUrl:  'https://api.account.gistory.me/.well-known/openid-configuration',
  authority:    'https://account.gistory.me',
  client_id:    CLIENT_ID,
  redirect_uri: REDIRECT_URI,
  scope:        SCOPE,
  response_type: 'code',
  userStore: new WebStorageStateStore({ store: window.localStorage }), // access+refresh 보관, 새로고침 생존
  // stateStore 기본값(sessionStorage) 유지 — OIDC redirect 구간 PKCE state 생존 필요
  automaticSilentRenew: true,
  includeIdTokenInSilentRenew: false,
  accessTokenExpiringNotificationTimeInSeconds: 60,
});
```

페이지 새로고침 시 흐름:
```
localStorage 에서 User 복원
→ access_token 유효: 그대로 사용
→ 만료: refresh_token 으로 signinSilent 갱신
  → 갱신 실패: 로그인 페이지
```

### 1. WebSocket 연결 수립

로그인 완료 후 메인 페이지 진입 시 connect 시도.

인증은 `authService`(oidc-client-ts `UserManager` 래퍼)로 처리. User 는 `useState` 보관,
connect 는 token 을 인자로 받아 stale closure 회피.

```typescript
const [user, setUser] = useState<User | null>(null);
// 부트스트랩: ?code= 콜백 교환 또는 localStorage User 복원(만료 시 signinSilent) → setUser

useEffect(() => {
  if (!user?.access_token) return;

  let socket: WebSocket | null = null;
  let closedByCleanup = false;

  const connect = (token: string) => {
    socket = new WebSocket(`${WS_BASE_URL}?token=${token}`);
    socket.onopen    = () => {
      startHeartbeat(socket!);
      socket!.send(JSON.stringify({ action: 'getState' })); // 연결 직후 초기 상태 요청
    };
    socket.onmessage = (e) => { handleMessage(JSON.parse(e.data)); };
    socket.onclose   = () => { stopHeartbeat(); if (!closedByCleanup) scheduleReconnect(); };
    socket.onerror   = (e) => { console.error(e); };
  };

  connect(user.access_token);

  return () => {                 // cleanup: 재실행/언마운트 전 기존 연결 닫기
    closedByCleanup = true;
    stopHeartbeat();
    socket?.close();
  };
}, [user]);
```

### 2. 메시지 처리

서버→클라이언트 포맷은 [메시지 포맷](#메시지-포맷) 참고.

```typescript
type WsMessage =
  | { type: 'state'; rooms: Record<string, boolean>; timestamp: string }
  | { type: 'pong' };

const handleMessage = (data: WsMessage) => {
  switch (data.type) {
    case 'state':
      setRooms(data.rooms);
      break;
    case 'pong':
      break;
  }
};
```

서버는 `getState` 응답과 broadcast 모두 동일한 `state` 메시지 (rooms 전체 맵) 를 보낸다. 클라이언트는 매 수신마다 rooms 상태를 전체 교체.

### 3. Heartbeat

API GW idle timeout 10분. 8분 주기로 ping 전송.

```typescript
let heartbeatTimer: ReturnType<typeof setInterval>;

const startHeartbeat = (ws: WebSocket) => {
  heartbeatTimer = setInterval(() => {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ action: 'ping' }));
    }
  }, 8 * 60 * 1000);
};

const stopHeartbeat = () => clearInterval(heartbeatTimer);
```

### 4. 재연결

`onclose` 시 자동 재연결. API GW max connection duration 2시간 강제 종료도 동일하게 처리.

재연결 시 토큰 만료 가능성 → `mgr.getUser()`로 최신 상태 확인 후 connect.
`automaticSilentRenew`가 정상 동작하면 이미 갱신된 토큰 반환.

```typescript
let reconnectAttempts = 0;

const scheduleReconnect = () => {
  const delay = Math.min(1000 * 2 ** reconnectAttempts, 30000); // 최대 30초
  reconnectAttempts++;

  setTimeout(async () => {
    let freshUser = await mgr.getUser();
    if (!freshUser || freshUser.expired) {
      await mgr.signinSilent();
      freshUser = await mgr.getUser();
    }
    if (freshUser?.access_token) connect(freshUser.access_token);
    reconnectAttempts = 0;
  }, delay);
};
```

---

## Backend

### DynamoDB

#### `gikview-connections-{stage}`

| 키 | 타입 | 설명 |
|---|---|---|
| `connection_id` | String (PK) | API GW 발급 |
| `expires_at` | Number | Unix timestamp, now + 7200 (2h) |

- DynamoDB TTL 활성화 (`expires_at`) → 보조 수단 (실제 삭제까지 최대 48시간 지연)
- 주 수단: gikview-ws-broadcast-{stage}에서 410 수신 시 즉시 DeleteItem

#### `gikview-rooms-{stage}`

- **DynamoDB Streams 활성화** (`NEW_IMAGE`)
- gikview-ws-broadcast-{stage} Lambda 트리거 소스

#### `gikview-metrics-{stage}`

| 키 | 타입 | 설명 |
|---|---|---|
| `metric` | String (PK) | 카운터 키 (현재 `connect`) |
| `n` | Number | 단조 증가 카운터. handler `ADD n :d` 로 누적 |

- 웹 demand 계측용. handler 가 `$connect` 시 best-effort 로 누적, edge 의 web-metrics-exporter 가 read 해 Prometheus 로 노출.
- TTL/Streams 없음.

### Lambda 환경변수

handler, broadcast 함수에 콘솔에서 직접 설정. 배포 시 변경 없음.

| 함수 | 환경변수 | prod 값 | dev 값 |
|---|---|---|---|
| handler | `CONNECTIONS_TABLE` | `gikview-connections-prod` | `gikview-connections-dev` |
| handler | `ROOMS_TABLE` | `gikview-rooms-prod` | `gikview-rooms-dev` |
| handler | `METRICS_TABLE` (옵션) | `gikview-metrics-prod` | `gikview-metrics-dev` |
| broadcast | `CONNECTIONS_TABLE` | `gikview-connections-prod` | `gikview-connections-dev` |
| broadcast | `ROOMS_TABLE` | `gikview-rooms-prod` | `gikview-rooms-dev` |
| broadcast | `WS_ENDPOINT` | `https://7t5yk4e8vf.execute-api.ap-northeast-2.amazonaws.com/prod` | `https://7t5yk4e8vf.execute-api.ap-northeast-2.amazonaws.com/dev` |

▎ METRICS_TABLE 미설정 시 계측 no-op — 코드 선배포 안전.

handler 의 Management API endpoint 는 event 에서 파생:
```python
endpoint = f"https://{event['requestContext']['domainName']}/{event['requestContext']['stage']}"
```

broadcast 는 Streams 이벤트에 `requestContext` 가 없으므로 환경변수 `WS_ENDPOINT` 로 구성. broadcast 도 트리거마다 rooms 전체를 Scan 해 full state 를 push → handler 와 동일하게 `ROOMS_TABLE` 필요.

---

### API Gateway WebSocket API

| Route | 통합 Lambda | Authorizer |
|---|---|---|
| `$connect` | `gikview-ws-handler-{stage}` | `gikview-ws-authorizer-{stage}` |
| `$disconnect` | `gikview-ws-handler-{stage}` | 없음 |
| `ping` | `gikview-ws-handler-{stage}` | 없음 |
| `getState` | `gikview-ws-handler-{stage}` | 없음 |

- prod endpoint: `wss://7t5yk4e8vf.execute-api.ap-northeast-2.amazonaws.com/prod/`
- dev endpoint: `wss://7t5yk4e8vf.execute-api.ap-northeast-2.amazonaws.com/dev/`

---

### Lambda

#### `gikview-ws-authorizer-{stage}` (`$connect` authorizer)

```
트리거: $connect route (API Gateway Lambda Authorizer)
입력: event.queryStringParameters.token (PKCE access_token, opaque)
처리:

token 없음 → "Unauthorized" 예외 (API GW 401, 연결 거부)
GIST IdP userinfo 호출: GET https://api.account.gistory.me/oauth/userinfo
  Authorization: Bearer {token}
HTTP 200 → 유효, IAM Allow 정책 + context 반환
401 또는 그 외 → "Unauthorized" 예외

출력 (Allow 시):
{
"principalId": "{sub}",
"policyDocument": {
"Statement": [{"Effect": "Allow", "Action": "execute-api:Invoke", "Resource": "{methodArn}"}]
},
"context": { "userId": "{sub}", "email": "{email}" }
}
sub/email 등 신원은 userinfo 응답 body 에서 추출. 권한 유무(200/401)만 쓰고 신원은 현 흐름에서 미사용.
주의: access_token 이 opaque 라 매 $connect 마다 userinfo 1회 호출. 연결 빈도 낮아(long-lived) 캐싱 불필요.
```

#### `gikview-ws-handler-{stage}` (`$connect` / `$disconnect` / `ping` / `getState`)

```
트리거: $connect / $disconnect / ping / getState route
분기: event.requestContext.routeKey

─── $connect ───
  1. connection_id = event.requestContext.connectionId
  2. DynamoDB PutItem → gikview-connections
       { connection_id, expires_at: now + 7200 }
  3. (METRICS_TABLE 설정 시) demand 카운터 누적 — 메모리 누적 후 30s/50건마다
     gikview-metrics 에 `ADD n` 1회 flush. best-effort: flush 실패해도 connect 응답 안 막음.
  4. return HTTP 200 (필수, 누락 시 API GW 연결 거부)

  authorizer context 접근:
    user_id = event['requestContext']['authorizer']['userId']

─── $disconnect ───
  1. connection_id = event.requestContext.connectionId
  2. DynamoDB DeleteItem → gikview-connections(connection_id)
  3. return HTTP 200

─── ping ───
  1. connection_id = event.requestContext.connectionId
  2. Management API PostToConnection(connection_id)
       → { type: "pong" }
  3. return HTTP 200

─── getState ───
  1. connection_id = event.requestContext.connectionId
  2. DynamoDB Scan → gikview-rooms → { room_id: occupied } 맵 구성
  3. Management API PostToConnection(connection_id)
       → { type: "state", rooms: { room_01: true, ... }, timestamp: now_iso8601 }
  4. return HTTP 200

Management API endpoint:
  https://{event.requestContext.domainName}/{event.requestContext.stage}
```

#### `gikview-ws-broadcast-{stage}` (`gikview-rooms-{stage}` Streams 트리거)

```
트리거: DynamoDB Streams (gikview-rooms NEW_IMAGE)

처리:
  event.Records 순회
  각 record:
    1. eventName이 INSERT 또는 MODIFY가 아니면 skip (REMOVE 무시)
    2. NewImage payload 는 사용하지 않음 — 트리거 신호로만 사용
    3. DynamoDB Scan → gikview-rooms → { room_id: occupied } 맵 구성
    4. DynamoDB Scan → gikview-connections → 전체 connection_id 목록
    5. 각 connection_id에 Management API PostToConnection
         → { type: "state", rooms: { ... }, timestamp: now_iso8601 }
       (getState 와 동일 페이로드 — 단일 room 변경분이 아니라 rooms 전체 맵을 매번 push)
    6. GoneException(410) 수신 시:
         → gikview-connections에서 즉시 DeleteItem (stale connection 정리)
         → TTL은 보조 수단 (실제 삭제 최대 48시간 지연)

Management API endpoint:
  Streams 이벤트엔 requestContext 없음 → 환경변수 WS_ENDPOINT
  (https://7t5yk4e8vf.execute-api.ap-northeast-2.amazonaws.com/{stage})

주의: connections Scan 전체 조회. 연결 수 증가 시 페이지네이션 필요.
현재 규모(GIST 내부 서비스)에서는 단순 Scan으로 충분.
```