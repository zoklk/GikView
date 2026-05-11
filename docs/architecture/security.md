# security

- 작성일: 2026-05-06
- 상태: 진행 중

## 다이어그램

![security architecture](images/security-architecture.png) <!-- TODO: Root CA → step-ca → broker/Edge Gateway/Telegraf/디바이스 인증서 발급 경로. 부트스트랩 → EST-like(X5C provisioner, step-ca REST API) → 정식 인증서 흐름. step-ca → NodePort(e-s1) → 학내망 ESP8266 (디바이스가 노드 IP로 /1.0/sign·/1.0/renew 직접 호출). cert-manager + step-issuer → Secret 자동 생성 → Pod volume 마운트. Reloader가 Secret 변경 감지 시 Deployment rollout. Mapping Generator CronJob이 device-room-mapping에서 emqx-acl + step-ca-whitelist + telegraf-lookup 세 ConfigMap 동시 자동 생성하는 흐름 -->

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
- **트레이드오프**: 단일 Intermediate CA 구조 (다중 발급 CA 미지원). Root CA는 항상 오프라인 (단일 tier PKI 미지원). 본 프로젝트 규모에는 영향 없음. EST 표준 미지원이라 디바이스 펌웨어가 step-ca REST API 호출(NodePort 경유, 결정 11) + CSR 인코딩을 자체 구현해야 함 (phase doc 후속 작업, `context/knowledge/step-ca.md` 참조)

### 3. K8s 워크로드 인증서는 cert-manager + step-issuer로 자동화 (2026-05-06)

- **선택**: cert-manager + step-issuer (Smallstep 공식 cert-manager Issuer) 조합. broker/Edge Gateway 인증서를 Certificate 리소스로 선언, Secret은 자동 생성/갱신
- **대안**: kubectl로 수동 Secret 생성, cert-manager + ACME provisioner, Sealed Secrets, SOPS
- **이유**: K8s Secret을 git에 직접 commit하면 base64 인코딩만 된 평문이라 위험. cert-manager는 K8s 표준 인증서 자동화 도구. step-issuer는 step-ca와 직접 통합되며 ACME처럼 도메인 검증 불필요해 K8s 내부 워크로드에 적합. Certificate 리소스만 git에 commit하면 발급/갱신 자동
- **트레이드오프**: 컴포넌트 추가 (cert-manager + step-issuer 두 controller). 디버깅 시 cert-manager controller 로그까지 봐야 함. 하지만 GitOps 일관성 측면 가치 큼

### 4. 부트스트랩 인증서 + MAC 화이트리스트 패턴 (2026-05-06)

- **선택**: 모든 디바이스가 동일한 부트스트랩 인증서(만료 7일, CN=`bootstrap`)로 시작. 첫 부팅 시 EST-like 흐름(X5C provisioner + step-ca REST API `/1.0/sign`)으로 정식 인증서(CN=`device-{MAC 뒷 6자리}`, 만료 90일) 발급. step-ca provisioner 정책에 허용 device_id 화이트리스트 등록 (ConfigMap)
- **대안**: 디바이스별 인증서를 빌드 시점에 펌웨어/NVS에 주입, 일회용 등록 토큰
- **이유**: 모든 디바이스 동일 NVS 이미지로 굽기 가능 → 대량 배포 단순화. 부트스트랩 인증서 유출 시 MAC 화이트리스트로 1차 방어 → 등록되지 않은 디바이스는 정식 인증서 발급 거부. 부트스트랩 만료 7일 + EMQX ACL에서 부트스트랩 CN의 모든 publish/subscribe 거부 → 추가 방어. 정식 인증서 수신 후 NVS의 부트스트랩 즉시 삭제로 재사용 차단
- **트레이드오프**: 부트스트랩 인증서가 모든 디바이스에 동일하므로 한 번 유출되면 화이트리스트가 유일한 방어선. step-ca 다운 시 신규 디바이스 첫 부팅 + 정식 인증서 갱신 일시 중단 (기존 디바이스 운영은 영향 없음). MAC 화이트리스트 등록은 사람이 git commit으로 관리 → 운영 부담 작음

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
- **이유**: EST-like 호출(step-ca REST API)은 mTLS 채널에서만 발생 → 발급된 인증서가 네트워크상에 노출되지 않음. "유령 인증서"(서버가 발급했으나 클라이언트가 미수신)는 디바이스 외부에 대응 개인키가 없어 무력화. 갱신 시 이전 인증서의 잠재적 유효성도 짧은 만료(90일)와 데이터 레이어 이상탐지로 흡수 가능. CRL/OCSP는 운영 컴포넌트와 EMQX 측 설정 복잡도를 늘리는 데 비해 본 위협 모델(결정 6번)에서의 실효 이득이 작음
- **트레이드오프**: 인증서 dump를 통한 키 탈취 시 즉시 차단 불가. 정상 디바이스 인증서와 탈취된 인증서가 만료까지 동시 유효. 짧은 만료(90일) + 데이터 레이어 이상탐지(결정 10번) + 운영자 가시성으로 완화.

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
