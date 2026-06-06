# security

- 작성일: 2026-05-19
- 상태: 작업 완료

## 다이어그램

![security architecture](../images/security-architecture.png)

## 결정 사항

### 1. 디바이스 인증으로 mTLS 채택 (2026-05-06)

- **선택**: ESP8266 ↔ EMQX 통신에 mTLS (양방향 인증서 검증)
- **대안**: 단방향 TLS + username/password, JWT
- **이유**: 학내망에 누구나 접근 가능 → 클라이언트 인증 필수. 단방향 TLS는 위조 ESP8266 디바이스가 false occupancy 주입 가능. 사용자명/비밀번호는 펌웨어 추출 시 평문 노출. mTLS는 디바이스별 인증서로 침해 격리 가능
- **트레이드오프**: PKI 운영 부담 추가 (CA 운영, 인증서 갱신 메커니즘). 학습 가치 + 보안 이득으로 정당화. 물리적 디바이스 탈취는 mTLS만으로 막지 못함. (디바이스 칩셋은 초기 ESP32 가정에서 ESP8266/NodeMCU로 변경 — 메모리 검증 결과, phase doc 후속 작업 참조)

### 2. PKI 서버로 step-ca 채택 (2026-05-06)

- **선택**: step-ca를 Intermediate CA로 운영. Helm chart, e-s1 K3s Pod
- **대안**: HashiCorp Vault PKI, OpenSSL 자체 CA, AWS Private CA, Let's Encrypt(ACME)
- **이유**: X5C provisioner로 EST-like 흐름(기존 인증서로 새 인증서 발급)을 구현 가능 — 단 step-ca 오픈소스는 RFC 7030 EST **표준 자체는 미지원**(이슈 #2366, 2026-05 기준 미구현)이라, 디바이스는 표준 EST 클라이언트(`simpleenroll`/`simplereenroll`)가 아닌 step-ca REST API(`/1.0/sign`, `/1.0/renew`)를 직접 호출. ACME는 도메인 검증 필요해 학내망 디바이스 부적합. HashiCorp Vault는 기능 풍부(EST provisioner 포함)하나 학습 곡선 큼, 본 규모에 over-engineering. OpenSSL은 서버 기능 없어 자동화 어려움. AWS Private CA는 비용 발생 + 외부 의존. step-ca는 가벼우면서 X5C/ACME/JWK 등 다양한 provisioner 지원해 본 use case에 직접 부합
- **트레이드오프**: 단일 Intermediate CA 구조 (다중 발급 CA 미지원). 단, 부트스트랩 신뢰체인 격리용 별도 Bootstrap CA(Root가 서명, end-entity 인증서는 발급 안 함)는 예외 — 결정 13번. Root CA는 항상 오프라인 (단일 tier PKI 미지원). 본 프로젝트 규모에는 영향 없음. EST 표준 미지원이라 디바이스 펌웨어가 step-ca REST API 호출(NodePort 경유, 결정 11) + CSR 인코딩을 자체 구현해야 함 (phase doc 후속 작업, `context/knowledge/step-ca.md` 참조)

### 3. K8s 워크로드 인증서는 cert-manager + step-issuer로 자동화 (2026-05-06)

- **선택**: cert-manager + step-issuer (Smallstep 공식 cert-manager Issuer) 조합. broker/Edge Gateway 인증서를 Certificate 리소스로 선언, Secret은 자동 생성/갱신
- **대안**: kubectl로 수동 Secret 생성, cert-manager + ACME provisioner, Sealed Secrets, SOPS
- **이유**: K8s Secret을 git에 직접 commit하면 base64 인코딩만 된 평문이라 위험. cert-manager는 K8s 표준 인증서 자동화 도구. step-issuer는 step-ca와 직접 통합되며 ACME처럼 도메인 검증 불필요해 K8s 내부 워크로드에 적합. Certificate 리소스만 git에 commit하면 발급/갱신 자동
- **트레이드오프**: 컴포넌트 추가 (cert-manager + step-issuer 두 controller). 디버깅 시 cert-manager controller 로그까지 봐야 함. 하지만 GitOps 일관성 측면 가치 큼

### 4. 부트스트랩 인증서 + MAC 화이트리스트 패턴 (2026-05-06)

- **선택**: 모든 디바이스가 동일한 부트스트랩 인증서(만료 30일, CN=`bootstrap`)로 시작 (이 부트스트랩 인증서는 별도 Bootstrap CA가 서명 — 운영 체인과 분리, 결정 13번). 첫 부팅 시 EST-like 흐름(X5C provisioner + step-ca REST API `/1.0/sign`)으로 정식 인증서(CN=`device-{MAC 뒷 6자리}`, 만료 ≤ 30일 — 2단계 X5C 발급의 `forbiddenAfter` 정책으로 signer(=부트스트랩) 잔여 lifetime 을 초과 못 해 자동 클램프, end.md 결정 2 참조) 발급. step-ca provisioner 정책에 허용 device_id 화이트리스트 등록 (ConfigMap)
- **대안**: 디바이스별 인증서를 빌드 시점에 펌웨어/NVS에 주입, 일회용 등록 토큰
- **이유**: 모든 디바이스 동일 NVS 이미지로 굽기 가능 → 대량 배포 단순화. 부트스트랩 인증서 유출 시 MAC 화이트리스트로 1차 방어 → 등록되지 않은 디바이스는 정식 인증서 발급 거부. 부트스트랩 만료 30일 + EMQX ACL에서 부트스트랩 CN의 모든 publish/subscribe 거부 → 추가 방어. 정식 인증서 수신 후 NVS의 부트스트랩 즉시 삭제로 재사용 차단
- **트레이드오프**: 부트스트랩 인증서가 모든 디바이스에 동일 → 유출 시 방어층 = (1) MAC 화이트리스트(발급 거부) (2) EMQX ACL no_match=deny(연결돼도 publish/subscribe 권한 0, 결정 12번) (3) 만료 30일 + disableRenewal (4) Bootstrap CA 회전 + 재플래시(결정 13번). EMQX TLS 핸드셰이크 단계 차단은 EMQX 5.8.6의 partial_chain 부재로 불가(결정 12번). step-ca 다운 시 신규 디바이스 첫 부팅 + 정식 인증서 갱신 일시 중단 (기존 디바이스 운영은 영향 없음). MAC 화이트리스트 등록은 사람이 git commit으로 관리 → 운영 부담 작음

### 5. EMQX ACL과 step-ca 화이트리스트는 단일 ConfigMap에서 자동 생성 (2026-05-11)

- **선택**: `device-room-mapping` ConfigMap을 단일 진실 공급원으로 사용. 사람이 직접 관리(git commit). Mapping Generator CronJob이 이 매핑에서 세 ConfigMap을 동시 자동 생성
  - `emqx-acl` ConfigMap: EMQX ACL file backend가 마운트해서 사용. CN별 publish/subscribe 권한 (peer_cert_as_username=cn으로 인증서 CN을 username으로 매핑)
  - `step-ca-whitelist` ConfigMap: step-ca provisioner 정책의 허용 CN 목록. CSR의 Subject CN과 매칭 검증
  - `telegraf-lookup` ConfigMap: Telegraf processor가 device_id → room_id 변환에 사용 (Telegraf 도입 후 추가됨)
- **대안**: EMQX built-in database (Mnesia) backend, HTTP backend (외부 인증 서버), 세 정책을 사람이 별도 ConfigMap으로 직접 관리
- **이유**: 디바이스 9대 규모에서 file backend가 가장 단순. built-in database는 K8s 외부 상태가 생겨 GitOps와 충돌. HTTP backend는 외부 인증 서버 의존성 추가. EMQX ACL, step-ca 화이트리스트, Telegraf lookup은 본질적으로 같은 정보(device_id 목록 + room_id 매핑)를 다른 형식으로 표현하는 것이라 단일 진실 공급원에서 자동 생성하는 것이 동기화 누락 방지. 디바이스 추가 빈도가 낮아 CronJob 주기적 실행으로 충분
- **트레이드오프**: ConfigMap 갱신 후 세 컴포넌트 모두 reload/restart 필요 — EMQX, step-ca, Telegraf 각각 Reloader가 변경 감지 후 rollout 트리거. CronJob 실행 주기에 따라 디바이스 추가 후 정책 반영까지 대기 시간 발생 (약 5~15분)

### 6. 위협 모델을 네트워크 계층 공격으로 한정 (2026-05-11)

- **선택**: 본 security 단계의 방어 목표를 네트워크 계층 공격으로 명시적으로 한정. 물리적 디바이스 탈취 + Flash dump + 인증서 dump 공격은 의도적 미방어
- **대안**: Zero Trust 전체 구현 (Flash Encryption + Secure Boot + HSM + CRL/OCSP + 갱신 시 자동 폐기까지)
- **이유**: 9대 규모 + 학내 설치 환경에서 풀 스택 보안 도입의 ROI 낮음. 네트워크 계층 방어(MITM, 가짜 디바이스 연결, 원격 익스플로잇)는 mTLS + 화이트리스트로 충실히 보장 가능. 위협 모델을 명시적으로 한정하지 않으면 이후 결정들(CRL 미도입, Flash Encryption 미적용 등)의 정합성이 흐려짐
- **트레이드오프**: 물리적 탈취 시나리오 대응 부재. 데이터 레이어 이상탐지(결정 10번)로 사후 탐지는 가능하지만 실시간 차단은 불가.

### 7. CRL/OCSP 및 갱신 시 이전 인증서 자동 폐기 미도입 (2026-05-11)

- **선택**: 본 단계에서는 인증서 폐기 메커니즘(CRL/OCSP responder, 갱신 시 이전 인증서 자동 revoke) 미구현. 활성 CN 목록을 visibility 스택에서 표시하는 운영자 가시성으로 임시 대응
- **대안**: step-ca OCSP responder 활성화 + EMQX OCSP stapling 설정, 갱신 시 step-ca 후크로 이전 시리얼 자동 CRL 등록
- **이유**: EST-like 호출(step-ca REST API)은 mTLS 채널에서만 발생 → 발급된 인증서가 네트워크상에 노출되지 않음. "유령 인증서"(서버가 발급했으나 클라이언트가 미수신)는 디바이스 외부에 대응 개인키가 없어 무력화. 갱신 시 이전 인증서의 잠재적 유효성도 짧은 만료(30일)와 데이터 레이어 이상탐지로 흡수 가능. CRL/OCSP는 운영 컴포넌트와 EMQX 측 설정 복잡도를 늘리는 데 비해 본 위협 모델(결정 6번)에서의 실효 이득이 작음. 또한 폐기 확인은 인증서를 받는 모든 relying party가 수행해야 하는데(mTLS는 양측 모두), ESP8266은 서버(EMQX·step-ca) 인증서의 CRL 다운로드·파싱이나 OCSP 왕복을 할 메모리 여유가 없고 BearSSL도 미구현 → CRL/OCSP를 켜도 절반만 동작하는 비대칭 구성이 됨. 폐기가 꼭 필요한 경우(특히 부트스트랩 크리덴셜)는 발급 CA 회전으로 갈음(결정 13번)
- **트레이드오프**: 인증서 dump를 통한 키 탈취 시 즉시 차단 불가. 정상 디바이스 인증서와 탈취된 인증서가 만료까지 동시 유효. 짧은 만료(30일) + 데이터 레이어 이상탐지(결정 10번) + 운영자 가시성으로 완화.

### 8. 인증서 갱신 시 Pod 자동 rollout을 위해 Reloader 도입 (2026-05-11)

- **선택**: stakater/Reloader Helm chart 배포. EMQX, Edge Gateway, Telegraf Deployment에 annotation 추가하여 Secret(인증서) 변경 시 자동 rollout trigger
- **대안**: 자체 CronJob으로 Secret resource version 추적 후 patch, 컨테이너 내부에서 파일 변경 감지 후 자체 reconnect 로직, Argo CD sync hook
- **이유**: cert-manager가 Secret을 갱신해도 마운트된 파일은 반영되지만 TLS 핸드셰이크가 이미 완료된 MQTT 클라이언트는 새 인증서를 인식하지 않음. 자체 구현은 race condition, multi-Deployment 처리 등 엣지 케이스 복잡. Reloader는 K8s watch 기반 push 방식으로 표준에 가까운 도구. Argo CD sync hook은 git 변경 시에만 동작하므로 cert-manager 자동 갱신 트리거 안 됨
- **트레이드오프**: 클러스터 전역 권한(Secret/ConfigMap watch)을 가진 controller 컴포넌트 추가. 단일 컨테이너에 단일 책임으로 침해 면적 제한적. 갱신 시점에 Pod restart 발생 → MQTT 연결 일시 끊김(수 초). ESP8266 Store-and-Forward + EMQX 재연결로 메시지 손실 없음

### 9. visibility 구간 보안 결정 보류 (2026-05-11)

- **선택**: Prometheus, Grafana, InfluxDB 등 visibility 스택 내부 통신의 보안 정책(mTLS vs NetworkPolicy)은 본 단계에서 결정 보류. visibility 구축 시점에 비교 후 결정
- **대안**: 지금 즉시 결정 (전체 mTLS 또는 NetworkPolicy 일괄 적용)
- **이유**: 위협 모델(결정 6번)이 네트워크 계층 공격에 한정되므로 내부 통신 보안은 핵심 경로(외부 진입 + pipeline)보다 우선순위 낮음. 본 단계에서 mTLS 일관 적용은 cert-manager Certificate 리소스가 다수 추가되고 Reloader 적용 범위도 확장됨. NetworkPolicy 적용은 Cilium Hubble dependency map 기반 작성이 효율적인데 visibility 스택 자체가 아직 배포되지 않음. 결정을 미루는 것 자체를 명시적으로 ADR로 남겨 누락이 아님을 분명히 함
- **트레이드오프**: 본 단계 완료 시점부터 visibility 배포 시점까지 내부 통신 평문. 클러스터 외부에서는 도달 불가능하므로 현실적 위협 낮음. 내부 침해(Pod 권한 탈취) 시 시계열 데이터 노출 가능 → visibility 결정 시 재평가

### 10. 키 탈취 대응으로 데이터 레이어 이상탐지 도입 (visibility) (2026-05-11)

- **선택**: InfluxDB에 적재되는 시계열 데이터 기반 이상탐지를 visibility에서 구축. 인증서/키 탈취 시 즉시 차단(CRL/OCSP)을 포기하는 대신, 데이터에 남는 이상 패턴을 통한 사후 탐지로 대응
- **탐지 시그널 후보**:
  - BSSID 급변 (동일 device_id가 갑자기 다른 AP에 붙음 → 물리적 위치 이동 또는 위조 디바이스)
  - reconnect 빈도 비정상 (정상 디바이스 + 탈취 디바이스가 같은 client_id로 경합)
  - 메시지 주기 이탈 (5초 주기 벗어남)
  - 동일 timestamp 인근 중복 (정상 + 탈취 디바이스 동시 publish)
- **구현 옵션 후보**:
  - 규칙 기반: Prometheus alert rule + InfluxDB 쿼리 기반 임계값 알림
  - sLLM 기반: 주기적 데이터 dump를 Gemma 등 경량 LLM에 전달하여 패턴 분류. 학습/추론 자원은 별도 노드 또는 외부 GPU 인스턴스
- **대안**: CRL/OCSP responder (결정 7번에서 제외), Flash Encryption (위협 모델상 미적용), HSM/Secure Element 도입
- **이유**: 본 위협 모델(결정 6번)이 네트워크 계층 공격에 한정되어 있어 키 탈취 자체는 방어 범위 밖. 그러나 탈취 발생 시 완전 무방어 상태가 되는 것은 잔여 위험으로 명시 필요. 데이터 레이어 이상탐지는 이미 적재되는 InfluxDB 시계열을 추가 인프라 없이 활용 가능.
- **트레이드오프**: 즉시 차단 불가, 사후 탐지만 가능. 패턴 기반 탐지는 false positive 존재. visibility 시점에 우선순위 재평가 (탐지 가치 vs 구현 비용)

### 11. step-ca 외부 노출을 NodePort 직접 노출로 (별도 ingress 없음) (2026-05-11)

- **선택**: step-ca `:9000`을 e-s1 NodePort로 직접 노출 (`step-ca-nodeport` 서비스, 고정 nodePort). 학내망(클러스터 밖) ESP8266이 노드 IP로 `/1.0/sign`·`/1.0/renew`를 직접 호출. ingress controller 미도입. ClusterIP는 step-issuer/cert-manager 내부 통신용으로 유지
- **대안**: ingress(Nginx/Traefik) + TLS passthrough, Cilium L2 Announcement, ClusterIP 유지 후 디바이스 흐름 보류
- **이유**: step-ca가 e-s1 단일 Pod라 도달지점이 하나 → ingress 추상화 이득 없음. messaging.md 결정 3(EMQX NodePort)과 동일 토폴로지·동일 근거(단일 control-plane에서 L2 Announcement는 apiserver SPOF). 노드 IP가 정적이라 펌웨어 하드코딩 무리 없음. step-ca API는 X5C provisioner라 익명 접근 불가(유효한 부트스트랩/정식 인증서로 서명한 JWT 필요) + MAC 화이트리스트로 노출 면적 제한
- **트레이드오프**: 노드 교체 시 펌웨어 재배포 필요. step-ca 서버 인증서 SAN에 노드 IP 추가 필요(부팅 시 Intermediate로 self-issue되는 leaf). ESP8266 BearSSL이 IP SAN을 검증하지 않음(`context/knowledge/step-ca.md` 주의사항) → 운영 환경 trust 전략(DNS 명 사용 또는 `setInsecure`)은 별도 ADR. 공유기 포트포워딩 설정(운영자 1회 작업) 필요. `:9000`이 학내망에 노출되므로 미인증 요청도 step-ca까지 도달(서명 검증에서 거부) → 노드 방화벽/포트포워딩 범위로 추가 제한 권장
- **관련**: messaging.md 결정 3

### 12. EMQX 클라이언트 인증서 검증 trust anchor를 Root CA로 (2026-05-12)

- **선택**: EMQX mqtts listener의 `ssl_options.cacertfile`을 step-ca **Root CA**(cert-manager 발급 `emqx-server-tls` Secret의 `ca.crt`)로. 부트스트랩 인증서(`leaf → Bootstrap CA → Root`)는 TLS 검증을 통과하며, 차단은 ACL 계층(`peer_cert_as_username=cn` → CN=`bootstrap`이 어떤 룰에도 매칭 안 됨 → `no_match=deny`)이 담당 — ACL이 부트스트랩 격리의 *의도된 최종 방어선*.
- **대안**: `cacertfile`을 Intermediate CA로만 설정해 부트스트랩 인증서를 TLS 핸드셰이크 단계에서 거부 (`ssl_options.partial_chain` 옵션 필요).
- **이유**: EMQX는 Erlang/OTP 위에서 동작하고 TLS는 OTP `ssl`이 담당 — OTP `ssl`은 신뢰 체인이 self-signed Root까지 닿아야 통과하고, 중간 CA를 단독 trust anchor로 인정하려면 `partial_chain` fun이 필수다. EMQX 5.8.6의 listener `ssl_options` schema는 `partial_chain`을 노출하지 않아(`emqx_schema.erl` `common_ssl_opts_schema`/`server_ssl_opts_schema` 확인) `cacertfile=Intermediate`면 정상 디바이스/워크로드 인증서마저 검증 실패할 위험이 있고 5.8.6엔 교정 손잡이가 없다. EMQX 5.9+는 BSL 1.1 라이선스라 업그레이드 비용 큼(`context/knowledge/emqx.md`), 앞단 TLS 프록시도 OpenSSL `PARTIAL_CHAIN`을 노출 안 함. → 본 위협 모델(결정 6번)에서 부트스트랩 인증서에 대한 충분한 방어는 MAC 화이트리스트(발급 거부) + ACL `no_match=deny`(연결돼도 권한 0) + 짧은 만료(30일, `disableRenewal: true`) + 유출 시 Bootstrap CA 회전(결정 13번)의 조합.
- **트레이드오프**: 부트스트랩 인증서가 EMQX와 TLS 핸드셰이크는 수립 가능(데이터 평면은 ACL이 막음). ACL은 mapping-generator가 주기 재생성하는 `emqx-acl` ConfigMap에 의존하는 런타임 가변 통제 — `no_match=deny` 종료 + 비-`device-XXXXXX` CN 매칭 룰 부재 보장 필요(스모크가 `{deny, all}.` 종료 검증). 클라이언트는 핸드셰이크에 `leaf + Intermediate` 번들 제시 필요(OTP가 `leaf → Intermediate → Root` 경로 구성 가능하도록) — cert-manager 발급 Secret의 `tls.crt`는 자동 충족, ESP8266 펌웨어는 `/1.0/sign` 응답 `certChain`(=[leaf, intermediate])을 둘 다 저장·제시해야 함.
- **관련**: 결정 4번, 결정 13번, `context/knowledge/emqx.md`

### 13. 부트스트랩 신뢰체인 격리 및 폐기는 CA 회전으로 (2026-05-12)

- **선택**: 부트스트랩 인증서를 운영 발급 CA(Intermediate)가 아닌 별도 **Bootstrap CA**(Root가 직접 서명)로 서명하고, step-ca X5C provisioner를 `device-bootstrap`(roots=Bootstrap CA, `disableRenewal: true`)·`device-renewal`(roots=Intermediate)로 분리한다(이 구성 자체는 결정 4번·phase doc에 기재). CRL/OCSP 미도입(결정 7번)으로 개별 인증서 폐기가 불가능하므로 부트스트랩 크리덴셜의 폐기/회전은 **Bootstrap CA 자체의 회전**으로 한다 — 프로비저닝 완료 시 `device-bootstrap` provisioner 제거 또는 `roots` 비우기로 경로 폐쇄; 유출 시 새 Bootstrap CA + 새 공통 부트스트랩 인증서 발급 → `device-bootstrap.roots` 교체 → 디바이스 재플래시(운영 인증서 체인·EMQX 서버 인증서·워크로드 인증서 영향 0). 절차 상세는 `context/knowledge/step-ca.md`.
- **대안**: 부트스트랩 인증서도 Intermediate가 서명(단일 발급 CA) + CN(`bootstrap`)으로만 첫 발급/갱신 구분; CRL/OCSP responder 도입(결정 7번에서 기각).
- **이유**: 부트스트랩 인증서는 모든 디바이스 펌웨어에 동일하게 굽히고 ESP8266은 Flash Encryption/Secure Boot 미적용이라 추출 가능 → *유출 전제* 저신뢰 크리덴셜. 이를 운영/워크로드 인증서를 보증하는 Intermediate가 서명하면 "Intermediate 서명 = 신뢰된 운영 신원" 의미가 희석되고, Root를 클라이언트 인증에 쓰는 다른 mTLS 표면이 생기면 그곳의 유효 클라이언트가 됨. 별도 CA면 부트스트랩 크리덴셜이 구조적으로 "step-ca `device-bootstrap`에 말 거는 것" 한 가지로 스코프되고 폐기/회전 폭발 반경이 부트스트랩 경로에 국한됨.
- **트레이드오프**: 사전 준비에 CA 1개 + 키 오프라인 보관 추가. 유출 시 9대 재플래시 필요(`disableRenewal: true`라 30일 내 미온라인 배치는 어차피 재플래시 대상이므로 운영 절차와 겹침). EMQX TLS 단 차단은 본 결정으로 달성 안 됨(결정 12번) — ACL 몫.
- **관련**: 결정 2번(단일 Intermediate CA 구조 — Bootstrap CA는 end-entity 인증서를 발급하지 않는 별도 Root-서명 CA), 결정 4번, 결정 7번, 결정 12번

### 14. CN 화이트리스트 강제는 cert-template `{{ fail }}` 가드로 (2026-05-14)

- **선택**: `device-bootstrap`·`device-renewal` X5C provisioner 의 인증서 템플릿(`options.x509.template`) 안에서 `{{ fail }}` 가드 + `templateData.allowedCNs` 패턴으로 화이트리스트 강제. 가드 로직(template 문자열)은 `step-ca-config` ConfigMap 의 정적 부분, 화이트리스트 데이터만 mapping-generator 가 `step-ca-whitelist` ConfigMap 으로 주입 → 부팅 시 `merge-ca-config` initContainer 가 `ca.json` 의 `templateData.allowedCNs` 에 머지. 가드는 요청 CN 과 모든 SAN 을 `allowedCNs` 와 대조, 또한 모든 SAN 타입이 `dns` 인지도 검사 (비-DNS SAN 요청 거부)
- **대안**: `provisioners[].policy` 블록 (CRD-shape policy), authority-level policy 활성화, K8s admission webhook 으로 외부 강제
- **이유**: `provisioners[].policy` 는 OSS step-ca 가 silently ignore — hosted Smallstep Certificate Manager 전용 (구조체에 필드 없음, `authority/provisioner/options.go` 의 `X509Options.AllowedNames`/`DeniedNames` 가 `json:"-"`). authority-level policy 는 admin(JWK) provisioner 에도 적용돼 step-issuer 가 K8s 워크로드(EMQX·Edge Gateway·Telegraf) cert 발급을 못 함. cert-template `{{ fail }}` 가드는 step-ca 가 정식 지원하는 메커니즘(template 함수 라이브러리) + 본 use case(특정 CN 만 발급, DNS-only SAN) 에 정확히 부합. 외부 webhook 은 RBAC 확대 + 새 컴포넌트 추가 — 결정 4번의 PKI 단순성 원칙과 어긋남
- **트레이드오프**: `template`/`templateData` 는 hot-reload 불가 — `step-ca-whitelist` 변경 시 step-ca StatefulSet rollout 필요(결정 15번), rollout 중 약 5~10초 발급 거부 윈도우. 가드가 비면(`allowedCNs: []`) 모든 device cert 발급 0 — fail-closed (실제로는 mapping-generator 가 sync-wave -1 에 항상 먼저 생성). 펌웨어 CSR 제약: CN = `device-XXXXXX`, SAN 없거나 같은 값의 DNS SAN 만 — IP SAN 넣으면 발급 실패
- **관련**: 결정 2번, 결정 4번, 결정 5번, `context/knowledge/step-ca.md`

### 15. step-ca rollout 트리거는 Reloader + post-render annotation 으로 (2026-05-14)

- **선택**: `step-ca-whitelist` ConfigMap 변경 → Reloader (결정 8번) 가 step-ca StatefulSet 의 annotation (`configmap.reloader.stakater.com/reload: step-ca-whitelist`) 을 보고 rollout 트리거. step-certificates 1.30.x 차트가 워크로드 metadata annotation 훅을 노출 안 해, 이 annotation 부착은 엄브렐라 차트의 post-render(kustomize strategic-merge patch) 으로 수행
- **대안**: mapping-generator 가 직접 `kubectl rollout restart statefulset/step-ca` 호출, helm post-hook 으로 매번 rollout 강제, step-ca 가 ConfigMap 을 직접 watch
- **이유**: 직접 `kubectl rollout` 호출은 (1) mapping-generator 가 `statefulsets/patch` RBAC 필요 → 보안 면적 확장, (2) EMQX(Reloader 패턴) 와 메커니즘 비대칭 → 운영 일관성 깨짐, (3) mapping-generator 가 whitelist 변경 감지 로직 자체 구현 필요 (현재는 Reloader 의 resourceVersion 기반 자동), (4) 스모크 `smoke-test-step-ca.sh #4b` 가 annotation hard-check 로 검증 → 즉시 스모크 실패. step-ca 직접 watch 는 `ca.json` `template`/`templateData` 가 hot-reload 미지원이라 watch 해도 의미 없음 (rollout 까지 필요). helm post-hook 은 매 sync 마다 rollout → 인증서 발급 빈도가 sync 빈도에 종속됨
- **트레이드오프**: ArgoCD 의 `helm` source 는 post-renderer 를 실행 안 함 → prod 가 ArgoCD 로 sync 될 땐 Reloader annotation 부착이 누락 (하네스 `/deploy` 에선 부착됨). prod 에서 whitelist 변경 후 step-ca 재적용은 ArgoCD app refresh 또는 수동 rollout. step-certificates 차트가 metadata annotation 훅을 노출하기 전까지의 임시 갭 — upstream 차트 업데이트 시 post-render 제거 가능
- **관련**: 결정 5번, 결정 8번, 결정 14번, `context/knowledge/step-ca.md`, `context/knowledge/reloader.md`

### 16. step-ca 컨테이너 이미지를 자체 빌드 (cap_net_bind_service 제거) (2026-05-14)

- **선택**: 업스트림 `cr.smallstep.com/smallstep/step-ca:0.30.2` 베이스로 자체 빌드 이미지 `ghcr.io/zoklk/step-ca:edge`. 빌드 단계에서 step-ca 바이너리의 `cap_net_bind_service` file-capability xattr 를 `setcap -r` 로 제거 + Alpine sh/busybox/jq 그대로 (`merge-ca-config` initContainer 가 같은 이미지 사용 — 추가 이미지 풀 불필요)
- **대안**: 업스트림 이미지 그대로 + `securityContext.allowPrivilegeEscalation: true`(= `no_new_privs=0`), `securityContext.capabilities.add: ["NET_BIND_SERVICE"]` 로 ambient capability 부여, capability 가 필요한 다른 우회 (chroot 등)
- **이유**: step-ca 가 비특권 포트 `:9000` 만 바인딩 — `cap_net_bind_service`(특권 포트 <1024 바인딩 권한) 자체가 불필요. 그러나 file capability xattr 가 남으면 `no_new_privs=1`(= `allowPrivilegeEscalation: false`, trivy KSV-0001 강제값) 아래서 바이너리 execve 가 EPERM 으로 실패(exit 255, crashloop). `allowPrivilegeEscalation: true` 는 다른 컴포넌트(cert-manager/step-issuer/reloader)의 KSV-0001 준수와 비대칭 → 보안 baseline 회귀. ambient capability 추가는 file cap=0 일 때 OS 가 무시 + step-ca 가 `:9000` 만 쓰니 무용지물
- **트레이드오프**: 자체 GHCR 가 private — `ghcr-pull` Secret 사전 생성 (mapping-generator 환경별 사전 작업과 동일). step-ca Pod 이 `default` ServiceAccount 로 이 Secret 을 `imagePullSecrets` 로 참조. 업스트림 0.30.x 패치 추적 시 빌드 워크플로 한 단계 추가 — `edge/docker/step-ca/Dockerfile` 의 base tag 변경 + `docker buildx build --push`. 빌드 호스트의 multi-arch buildx 셋업은 mapping-generator 와 공유 → 추가 비용 0
- **관련**: 결정 2번, `context/knowledge/step-ca.md`, `edge/docker/step-ca/Dockerfile`

### 17. ESP8266 펌웨어 PKI 라이브러리 조합 (2026-05-14)

- **선택**: ESP8266 펌웨어의 mTLS + 부트스트랩/갱신 흐름을 세 라이브러리 조합으로:
  - **BearSSL** (ESP8266 Arduino 코어 표준 `WiFiClientSecure` 의 백엔드) — mTLS 핸드셰이크 + HTTPS POST. `setClientECCert(cert, key)` 로 디바이스 클라이언트 인증서/키 주입, `setTrustAnchors(rootCA)` 로 서버(EMQX·step-ca) trust anchor 주입
  - **uECC** (micro-ecc, MIT) — ECDSA P-256 키 페어 생성 (flash ~3KB). BearSSL 의 ECDSA 와 독립적, signing 은 BearSSL 이 담당
  - **자체 ASN.1 DER CSR(PKCS#10) 인코딩** — 펌웨어 단 직접 구현(~130줄), Subject CN + ECDSA P-256 public key + (옵션) DNS SAN extension 만 다룸
- **대안**: mbedTLS 풀스택, Mongoose OS, 표준 EST 클라이언트(`simpleenroll`/`simplereenroll`), ESP8266 표준 `WiFiClientSecure` 만 사용
- **이유**: 표준 `WiFiClientSecure`(BearSSL 기반) 는 TLS 핸드셰이크와 HTTPS 만 제공, 키 페어 생성·CSR 인코딩·EST 같은 PKI 프리미티브를 노출 안 함 — CSR 부분을 펌웨어가 직접 책임. mbedTLS 풀스택은 ESP8266 메모리 제약상 추가 불가 (SRAM ~80KB, 운영 mTLS 안정화 시점 free heap ~18.4KB, EST 호출 중 일시 ~12.5KB — mbedTLS 가 추가 30~50KB heap 잡으면 OOM). 표준 EST(RFC 7030)는 step-ca 미지원(결정 2번) → EST 클라이언트 라이브러리 무의미, step-ca REST API(`/1.0/sign`, `/1.0/renew`) 를 BearSSL HTTPS POST 로 직접 호출. uECC 는 P-256 키 생성만 위한 최소 라이브러리 — BearSSL 과 충돌 없음, signing 은 BearSSL 의 `setClientECCert()` 가 자체 처리. 자체 CSR 인코딩은 ASN.1 DER 의 좁은 부분집합만 다루므로 검증 가능한 규모(디버깅: `openssl asn1parse -inform DER`)
- **트레이드오프**: CSR 인코딩 코드를 펌웨어가 직접 maintain — mbedTLS 가 제공할 일을 자체 구현. ASN.1 DER 인코딩 버그 시 step-ca 에러 메시지가 모호(`"x509: malformed certificate"`) → `openssl asn1parse` 디버깅 절차 필요. uECC 의 P-256 외 곡선 사용 시 추가 작업 — 현재 본 프로젝트는 ECDSA P-256 통일(step-ca Intermediate, cert-manager Certificate, K8s 워크로드, 디바이스 모두). BearSSL 의 IP SAN 미검증(결정 11번) — 펌웨어 trust 전략(`setInsecure` 또는 DNS 명 매핑)은 별도 ADR 또는 펌웨어 README
- **관련**: 결정 2번, 결정 4번, 결정 11번, `context/knowledge/step-ca.md`
