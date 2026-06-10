# Phase: frontend

>gikview 의 프론트엔드. Vite 로 빌드한 정적 SPA 를 S3 + CloudFront 로 서빙한다.
>이 phase 의 작업 단위는 service(기능) 부분, 즉 인증·WebSocket·state 처리이며 UI(components) 는 범위 밖이다.
>JSON 포맷·heartbeat 주기·재연결 알고리즘은 `context/knowledge/front-back-spec.md` 가 단일 진실의 원천이다.

## 전제 (완료된 작업, 참고용)

- UI 뷰(`components/`), 라우팅 진입점, 정적 호스팅 인프라(S3·CloudFront·ACM) 구성 완료.
- GIST IdP 에 PKCE public client 등록 완료. client_id 발급됨.

## Service: gikview-frontend

**technology**: React 19 + Vite 8 (TypeScript)
**dependency**: [gikview-ws-authorizer, gikview-ws-handler]
**artifacts**: static
**references**: [context/knowledge/front-back-spec.md, context/knowledge/aws-resources.md]

PKCE 로 access_token 을 발급받아 WebSocket 으로 방 상태를 구독하고 화면에 반영한다.

- **인증 (OIDC PKCE)** `services/auth.ts`:
  - `oidc-client-ts` `UserManager`, response_type `code`
  - `authority`: `https://account.gistory.me`, `metadataUrl`: `https://api.account.gistory.me/.well-known/openid-configuration`
  - `scope`: `openid email name student_id offline_access`
  - `userStore`: `InMemoryWebStorage` (access_token 인메모리 보관)
  - `stateStore`: 기본값(sessionStorage) 유지 (redirect 구간 PKCE state 생존)
  - `automaticSilentRenew: true`, `includeIdTokenInSilentRenew: false`, `accessTokenExpiringNotificationTimeInSeconds: 60`
  - `signinRedirect({ nonce: crypto.randomUUID(), prompt: 'consent' })` (openid scope → nonce 필수, offline_access → consent 필요)
  - `redirect_uri` 는 앱 루트, 진입 시 `?code=` 유무로 callback 감지 → `signinRedirectCallback()` → `history.replaceState` 로 URL 정리
  - 새로고침 시 silent re-auth (prompt=none hidden iframe), 세션 만료 시 로그인 페이지
  - scope 는 IdP client 에 등록된 mandatory scope 와 일치
- **WebSocket 연결** `App.tsx`:
  - URL `${VITE_WS_URL}?token=${access_token}`
  - access_token 을 함수 인자로 받아 연결 (stale closure 회피)
  - onopen 직후 `{ action: "getState" }` 전송
  - cleanup 에서 기존 연결 close
- **Heartbeat**:
  - 8분 주기 `{ action: "ping" }` 전송 (`ws.readyState === OPEN` 일 때만)
  - onclose 시 인터벌 해제
- **재연결**:
  - onclose 시 exponential backoff `min(1000 * 2 ** attempts, 30000)`
  - 재연결 직전 `getUser()` 확인, 만료 시 `signinSilent()` 후 갱신된 토큰으로 connect
  - 성공 시 attempts 리셋
- **state 처리**:
  - `WsMessage` 타입: `{ type: "state"; rooms: Record<string, boolean>; timestamp: string } | { type: "pong" }`
  - `state` 수신마다 rooms 전체 교체
  - room id 매핑: 프론트 `room-a-1-lounge` → 백엔드 키 `room_a_1_lounge`
  - `timestamp` 로 lastUpdated 갱신
- **환경변수 / 빌드**:
  - `VITE_WS_URL`, `VITE_CLIENT_ID`, `VITE_REDIRECT_URI`
  - dev / prod `.env` 분리
  - `npm run build` → `dist/` → S3 업로드

---

## 환경별 분리 요약

dev / prod 는 `.env` 의 `VITE_WS_URL`(WebSocket stage URL) 과 `VITE_REDIRECT_URI` 차이로 분리된다. 코드는 단일 소스.

## 범위 밖

- UI / Tailwind / `components/` 변경
- 디자인·레이아웃·다크모드
