# backend

> 이 디렉토리의 문서는 Claude(Anthropic)를 활용해 작성됨.

gikview 웹 실시간 상태전달 백엔드. AWS API Gateway WebSocket + Lambda + DynamoDB 서버리스 구조.
본 디렉토리는 Lambda 3종 소스만 담음

- backend architecture 설명: `docs/architecture/web/backend.md`
- 구현 명세: `context/phases/web-backend.md`
- 웹 세부 결정사항: `context/knowledge/front-back-spec.md`
- aws 카탈로그: `context/knowledge/aws-resources.md`

## 디렉토리 구조

```
web/backend/
├── README.md
├── authorizer.py      # $connect Lambda authorizer (userinfo 검증)
├── handler.py         # WebSocket route 통합 핸들러
├── broadcast.py       # DynamoDB Streams 기반 전체 push
├── log_util.py        # 공유 로거
└── requirements.txt   # 외부 의존성 없음
```

3종 단일 zip 패키징, 핸들러 attribute(`{authorizer,handler,broadcast}.lambda_handler`)로 분기

## authorizer.py

`$connect` Lambda Authorizer. 쿼리스트링 `token`(PKCE **access_token**) 검증 → Allow/Deny IAM 정책 반환

- access_token 은 opaque reference token → 오프라인 JWKS 서명검증 불가. gistory IdP userinfo(`GET api.account.gistory.me/oauth/userinfo`, `Authorization: Bearer {token}`) 호출로 검증
- HTTP 200 → 유효, 401·그 외 → `Unauthorized`. WS 연결은 long-lived(최대 2h)라 연결 빈도 낮아 캐싱 불필요
- 성공 → userinfo body 의 `sub`/`email`을 `context`로 전달 → handler가 `event.requestContext.authorizer` 접근
- identity source = `route.request.querystring.token` (API GW 설정값)

## handler.py

route 4종(`$connect`/`$disconnect`/`ping`/`getState`) `routeKey` 분기 통합 함수

- `$connect`: connections에 `connection_id` + `expires_at`(7200s) put
- `$disconnect`: connections delete
- `ping`: `{"type":"pong"}` (keepalive)
- `getState`: rooms full scan → 해당 연결만 `{"type":"state",...}` push (초기 상태 pull)
- Management endpoint: event `domainName`/`stage`로 분기

## broadcast.py

rooms Streams(`INSERT`/`MODIFY`) 트리거. 변경 시 rooms 전체 맵 → 전 연결 push

- `NewImage` 안 씀. 트리거 신호로만, 매번 rooms full scan으로 전체 재구성
- connections scan → 각 `connection_id`에 `post_to_connection`. `GoneException`(410) → stale delete
- endpoint: Streams 이벤트엔 `requestContext` 없음 → 환경변수 `WS_ENDPOINT`
- `REMOVE` 무시

## log_util.py

공유 로거 유틸함수. 기본 WARNING, `LOG_LEVEL` env 제어. 정상 트래픽 로깅 안함 → CloudWatch 수집량 거의 0, 실패만 기록.

## requirements.txt

- 외부 런타임 의존성 없음. authorizer 는 urllib(stdlib)로 userinfo 호출, handler/broadcast 의 boto3 는 Lambda 런타임 내장
- 네이티브 휠 없음 → CI 빌드 단순

## 배포

- `.github/workflows/backend.yml`: dev/prod 분기 zip 빌드 → S3 → `lambda:UpdateFunctionCode`
- GitHub OIDC로 `gikview-backend-ci-{stage}` role AssumeRole
- 환경변수는 콘솔 1회 설정, CI는 코드만 갱신
- 환경분리 = 단일 API GW(`7t5yk4e8vf`) 두 stage + 함수별 `-dev`/`-prod` suffix
