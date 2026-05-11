# Phase: security

본 phase 는 ESP8266 디바이스 ↔ EMQX 외부 mTLS 와 EMQX ↔ 내부 워크로드 (Edge Gateway, Telegraf) mTLS 의 PKI 인프라를 구축. step-ca 가 Intermediate CA 로 동작하고 cert-manager + step-issuer 로 K8s 워크로드 인증서를 자동 발급/갱신. 부트스트랩 인증서 + MAC 화이트리스트 패턴으로 ESP8266 정식 인증서 자동 발급. `device-room-mapping` ConfigMap 을 단일 진실 공급원으로 Mapping Generator CronJob 이 EMQX ACL, step-ca CN 화이트리스트, Telegraf lookup 세 ConfigMap 을 동시 자동 생성. Reloader 가 Secret/ConfigMap 변경 시 의존 워크로드 rollout 자동 트리거.

본 phase 는 messaging (EMQX 배포 완료) 의존. 본 phase 완료 후 EMQX 재배포 (mTLS listener 전환), Edge Gateway/Telegraf 배포가 가능.

## Service: cert-manager

**technology**: cert-manager/cert-manager (v1.20.2)
**dependency**: [none]
**artifacts**: helm
**node_category**: [security]
**references**: [context/knowledge/cert-manager.md]

- cert-manager v1.20.2 단일 replica 배포. CRD 동시 설치, uninstall 시 CRD 보존.
- ACME / Vault / DNS solver 미사용 (외부 issuer 인 step-issuer 만 연동).
- Argo CD sync-wave: `-2` (가장 먼저). 모든 후속 컴포넌트가 cert-manager CRD 의존.
- **Port**:
  - `webhook: 10250` — admission webhook (cluster 내부 전용)
- **리소스**:
  - CPU: `10m` / `100m`
  - Memory: `32Mi` / `128Mi`

## Service: step-issuer

**technology**: smallstep/step-issuer (v0.10.2)
**dependency**: [cert-manager]
**artifacts**: helm
**node_category**: [security]
**references**: [context/knowledge/step-issuer.md]

- step-issuer 1.10.2 helm chart 로 controller 배포.
- StepClusterIssuer 리소스를 본 phase 에서 함께 선언. step-ca 의 `admin` JWK provisioner 와 연결.
- JWK provisioner 비밀번호는 별도 Secret (`step-issuer-provisioner-password`) 로 사전 생성 (사람 1 회, 환경마다).
- caBundle 은 step-ca init 단계에서 생성된 root_ca.crt 를 base64 인코딩하여 helm values 로 주입 (환경별 분리).
- Argo CD sync-wave: `-1`. cert-manager CRD 의존 + step-ca 보다 먼저 (StepClusterIssuer 가 step-ca 보다 먼저 떠야 step-ca 가 첫 인증서 요청 받을 때 즉시 처리 가능).
- **리소스**:
  - CPU: `10m` / `100m`
  - Memory: `32Mi` / `128Mi`

## Service: step-ca

**technology**: smallstep/step-ca (0.30.2)
**dependency**: [cert-manager, step-issuer]
**artifacts**: helm
**node_category**: [security]
**references**: [context/knowledge/step-ca.md]

- step-ca 단일 Pod non-HA 배포. `security` 카테고리 노드 고정 (prod 는 e-s1 = control-plane, dev 는 alpha-w1; `config/harness.yaml` 의 `node_selectors.security`).
- 데이터 영속화: local PV (badger DB, 발급 이력/revocation 데이터). `reclaimPolicy: Retain`.
- **OS 사전 작업** (사람 1 회, 운영환경): `chown 1000:1000 <pv-path>/` (badger DB hostPath).
- **네트워크 사전 작업** (사람 1 회, 운영환경): 공유기 포트포워딩 `<외부포트>` → `<security 노드>:<NodePort>` (prod `e-s1:31900`, dev `alpha-w1:<dev nodePort>`) — 디바이스가 학내망에서 step-ca 도달; messaging.md 의 EMQX 포트포워딩과 동일 운영 패턴.
- **Root CA + Intermediate CA + 부트스트랩 CA 사전 생성** (사람 1 회, 오프라인):
  - Root CA (ECDSA P-256, 10y) 오프라인 생성, 서명 후 키는 클러스터 외부 안전 보관.
  - Intermediate CA (ECDSA P-256, 5y) Root 로 서명. K8s Secret 으로 클러스터 주입.
  - 부트스트랩 CA (ECDSA P-256, 5y) Root 로 별도 서명. K8s Secret 으로 클러스터 주입.
  - 인증서/키 Secret: `step-certificates-certs`, `step-certificates-ca-key`, `step-certificates-ca-password`.
- **Provisioner 구성** (helm values inject.config.authority.provisioners):
  - `device-bootstrap` (X5C): 부트스트랩 CA 를 root 로. CN 화이트리스트 (`^device-[a-f0-9]{6}$`). `disableRenewal: true`. 정식 인증서 발급 전용.
  - `device-renewal` (X5C): Intermediate CA 를 root 로. 동일 CN 정책. 정식 인증서 갱신 전용.
  - `admin` (JWK): 운영자 / K8s 워크로드 발급용. step-issuer 연결.
- Argo CD sync-wave: `0`.
- **Port**:
  - `https: 9000` — step-ca REST API (`/1.0/sign`, `/1.0/renew`). ClusterIP (step-issuer/cert-manager 내부용) **+ NodePort 노출** (`step-ca-nodeport` 서비스, `security` 카테고리 노드 = prod e-s1 / dev alpha-w1, 고정 nodePort 예: `31900`). `externalTrafficPolicy: Local` 로 step-ca 가 디바이스 실제 IP 를 로그/정책에서 보게 함. 외부 포트 매핑은 messaging.md 패턴(공유기 포트포워딩).
- **디바이스-facing 노출**: `step-ca-nodeport` 서비스 추가 + step-ca 서버 인증서 SAN 에 노드 IP(prod `192.168.0.101` 가정, dev 환경별) 포함 (knowledge 문서의 `inject.config.dnsNames`). ESP8266 BearSSL 이 IP SAN 을 검증하지 않으므로 운영 trust 전략(DNS 명 사용 또는 `setInsecure`)은 후속 ADR. NodePort + SAN 은 본 phase 범위지만, **end-to-end 동작은 ESP8266 펌웨어 클라이언트(아래 후속 작업)가 있어야 성립** — 본 phase 완료 시점에 동작 검증 가능한 것은 K8s 워크로드 인증서 발급 경로(cert-manager + step-issuer → step-ca)이고, 디바이스 부트스트랩 흐름은 펌웨어 작업 후.
- **리소스**:
  - CPU: `20m` / `200m`
  - Memory: `64Mi` / `256Mi`
- **Persistence**:
  - storageClass: `local-storage`
  - size: `2Gi` (prod), `1Gi` (dev)
  - reclaimPolicy: `Retain`

## Service: reloader

**technology**: stakater/reloader (v1.4.16)
**dependency**: [none]
**artifacts**: helm
**node_category**: [security]
**references**: [context/knowledge/reloader.md]

- Reloader chart 2.2.11 단일 replica 배포.
- `watchGlobally: false`, `gikview` namespace 한정.
- annotation 기반 명시적 매칭 (`secret.reloader.stakater.com/reload`, `configmap.reloader.stakater.com/reload`). auto-reload 미사용.
- **본 phase 적용 대상은 EMQX + step-ca**:
  - EMQX — `secret.reloader.stakater.com/reload: emqx-server-tls` (서버 인증서 갱신), `configmap.reloader.stakater.com/reload: emqx-acl` (ACL 변경).
  - step-ca — `configmap.reloader.stakater.com/reload: step-ca-whitelist` (CN 화이트리스트/policy 변경 시 rollout. step-ca 는 ca.json policy hot-reload 안 되므로 restart 필요).
  - `telegraf-lookup` → Telegraf, Edge Gateway client cert 등의 Reloader annotation 은 해당 워크로드를 배포하는 후속 phase 에서 추가 (security 결정 8 번은 최종 상태 기준 — 본 phase 는 그 부분집합).
- Argo CD sync-wave: `-2` (cert-manager 와 병행). 다른 컴포넌트가 reloader annotation 을 달기 전에 떠 있어야 첫 변경 즉시 감지.
- **리소스**:
  - CPU: `10m` / `100m`
  - Memory: `32Mi` / `128Mi`

## Service: mapping-generator

**technology**: 자체 코드 (Go CronJob)
**dependency**: [step-ca]
**artifacts**: helm, docker
**node_category**: [security]
**references**: [none]

- 자체 코드. Helm chart + Docker 이미지 빌드 (linux/arm64 + amd64 multi-arch).
- **단일 진실 공급원**: `device-room-mapping` ConfigMap (사람이 git commit 으로 관리).
- **출력 ConfigMap 3 종 동시 자동 생성**:
  - `emqx-acl`: EMQX file authorizer 가 마운트. Erlang tuple 형식. CN (= peer_cert_as_username) 기반 publish/subscribe 권한.
```erlang
    %% device-aabbcc 는 자기 토픽만 publish
    {allow, {user, "device-aabbcc"}, publish, ["sensors/device-aabbcc/occupancy"]}.
    %% edge-gateway 는 shared subscription 권한
    {allow, {user, "edge-gateway"}, subscribe, ["$share/edge-gw/sensors/+/occupancy"]}.
    %% telegraf 는 별도 shared group
    {allow, {user, "telegraf"}, subscribe, ["$share/telegraf/sensors/+/occupancy"]}.
    %% 그 외 거부
    {deny, all}.
```
  - `step-ca-whitelist`: step-ca provisioner policy 의 허용 CN 목록 (yaml 또는 json). step-ca `ca.json` 의 X5C provisioner `policy.x509.allow.cn` 항목에 반영됨.
  - `telegraf-lookup`: Telegraf processor.starlark 또는 processor.lookup 이 참조. device_id → room_id 매핑 csv. (Telegraf 는 후속 phase 배포 — 본 phase 에선 ConfigMap 만 미리 생성됨.)
- **(미정 — mapping-generator/step-ca 차트 작성 전 결정)**: `step-ca-whitelist` 를 step-ca `ca.json` 의 `policy.x509.allow.cn` 에 반영하는 방식 — (a) step-ca 가 이 ConfigMap 을 직접 마운트 + partial include, (b) mapping-generator 가 step-ca `ca.json` ConfigMap 전체를 재생성, (c) init container 머지 — 중 택1. 어느 ConfigMap 에 step-ca 의 Reloader annotation 을 다는지가 이 선택에 따라 달라짐 (현재 가정: `step-ca-whitelist`).
- **스케줄**: CronJob `*/15 * * * *` (15 분 주기). 디바이스 추가 빈도 낮아 충분.
- **rollout trigger**: ConfigMap 갱신 후 Reloader 가 의존 워크로드 rollout 자동 트리거 (Deployment annotation 으로). 본 phase 범위: EMQX(`emqx-acl`), step-ca(`step-ca-whitelist`). Telegraf(`telegraf-lookup`) 는 Telegraf 배포 phase 부터.
- **권한**: ConfigMap get/list/update/create 가능한 ServiceAccount.
- Argo CD sync-wave: `1` (step-ca 다음). 첫 실행으로 세 ConfigMap 초기 생성.
- **리소스**:
  - CPU: `50m` / `200m`
  - Memory: `64Mi` / `128Mi`

## Service: emqx

**technology**: emqx/emqx (5.8.6)
**dependency**: [mapping-generator, step-ca]
**artifacts**: helm
**node_category**: [none]
**references**: [context/knowledge/emqx.md]

- **재배포 — mTLS 전환**: messaging phase 에서 배포된 EMQX 의 listener 구성과 ACL backend 를 mTLS 기반으로 전환. helm release 동일 (`emqx`), values 만 변경하여 helm upgrade 흐름으로 재배포.
- **listener 전환**:
  - `mqtts: 8883` mTLS listener 활성화 (`verify = verify_peer`, `fail_if_no_peer_cert = true`).
  - `peer_cert_as_username = cn` 설정으로 클라이언트 인증서 CN 을 EMQX username 으로 매핑. ACL 규칙은 이 username 기준 매칭.
  - 기존 평문 `mqtt: 1883` listener 비활성화 (helm values 에서 enable: false). NodePort 도 mqtts 만 노출 (외부 포트 매핑은 phase 6 의 messaging.md 유지: e-s2:8883, e-s3:8884 → 노드 내부 :8883 NodePort).
- **서버 인증서**: Certificate 리소스 추가.
  - commonName: `emqx.gikview.svc.cluster.local`
  - dnsNames: `emqx`, `emqx.gikview.svc.cluster.local`, `emqx-headless.gikview.svc.cluster.local`, `*.emqx-headless.gikview.svc.cluster.local`, `emqx-nodeport.gikview.svc.cluster.local`
  - ipAddresses: `192.168.0.102`, `192.168.0.103` (prod), dev 는 환경별 분리
  - duration: `2160h`, renewBefore: `720h`
  - issuerRef: StepClusterIssuer
  - secretName: `emqx-server-tls`
- **ACL backend 전환**: file authorizer 활성화, `emqx-acl` ConfigMap 마운트.
  - `/etc/emqx/acl/acl.conf` 경로로 ConfigMap volumeMount.
  - authorization sources 의 첫 entry 로 `{type = file, path = "/etc/emqx/acl/acl.conf"}` 등록.
  - `no_match = deny` 로 미매칭 시 거부.
- **CA bundle 마운트**: step-ca 의 root_ca.crt 를 EMQX 가 클라이언트 인증서 검증에 사용. cert-manager 가 생성한 `emqx-server-tls` Secret 의 `ca.crt` 사용 또는 별도 `step-ca-root` Secret 마운트.
- **Reloader annotation** (StatefulSet metadata):
  - `secret.reloader.stakater.com/reload: "emqx-server-tls"` — 서버 인증서 갱신 시 rollout.
  - `configmap.reloader.stakater.com/reload: "emqx-acl"` — ACL 변경 시 rollout.
- **client_id 충돌 처리**: 같은 CN 으로 두 클라이언트가 접속 시 EMQX 가 나중 접속을 끊지 않게 `mqtt.discard_session_on_disconnect: false` 또는 `clientid_override` 검토 (security 결정 7번 의 "유령 인증서 동시 publish" 대응). 본 phase 에서는 default 유지하되 visibility 단계에서 동일 CN 접속 감지 alert 추가.
- Argo CD sync-wave: `2` (mapping-generator 다음, emqx-acl ConfigMap 존재 후).
- **리소스 / Port** 는 messaging phase 와 동일. 본 phase 에서 변경하지 않음.

## 후속 작업 (본 phase 범위 외, 디바이스/펌웨어 작업)

- **ESP8266 펌웨어 EST-like 흐름 구현** (인프라 1, 코드)
  - **하드웨어 / 라이브러리 선정 근거**: ESP8266 (NodeMCU, CP-2102). ESP8266 Arduino 코어의 표준 secure WiFi client (`WiFiClientSecure`, BearSSL 기반) 는 TLS 핸드셰이크/HTTPS 만 제공하고 키 페어 생성·CSR(PKCS#10) 인코딩·EST 같은 PKI 프리미티브는 노출하지 않음 → 그 부분을 펌웨어에서 직접 구현해야 함. 추가로 디바이스 메모리 제약 (SRAM ~80KB, 운영 mTLS 안정화 시점 free heap ~18.4KB, EST 호출 중 일시 ~12.5KB) 이라 별도 mbedTLS 풀 스택을 끼워 넣는 것도 불가. 그래서 라이브러리 조합을 다음과 같이 변경·채택 (조합 선택의 주된 이유는 "표준 client 가 CSR/EST 미제공"):
    - **BearSSL**: ESP8266 Arduino 코어 기본 TLS 라이브러리. mTLS 핸드셰이크 + HTTPS POST 담당. `WiFiClientSecure` 의 `setClientECCert()` 로 클라이언트 인증서 + ECDSA 키 주입.
    - **uECC (micro-ecc)**: ECDSA P-256 키 페어 디바이스 측 생성 (flash ~3KB). 표준 secure client 가 키 생성을 제공하지 않아 이를 보완.
    - **자체 CSR ASN.1 DER 인코딩**: PKCS#10 CSR 을 펌웨어 단 직접 구현 (~130줄). 표준 secure client 가 CSR/EST 인코딩을 제공하지 않아 직접 구현.
  - **부트스트랩 흐름**:
    - NVS (LittleFS) 에 사전 굽힌 부트스트랩 인증서/키 + step-ca root_ca.crt 로드.
    - 첫 부팅 시: uECC 로 ECDSA P-256 키페어 생성 → CSR DER 직접 인코딩 → JWT (x5c header = 부트스트랩 인증서) 구성 → step-ca `/1.0/sign` 으로 HTTPS POST → 정식 인증서 LittleFS 저장 → 부트스트랩 인증서/키 NVS 삭제.
    - 정상 운영: 정식 인증서로 EMQX mTLS 연결, 5 초 주기 publish.
    - 갱신: 만료 30 일 전 `/1.0/renew` 호출 (정식 인증서로 인증, key reuse 또는 신규 키 재생성). 갱신 성공 시 LittleFS 의 인증서 교체.
  - **검증된 트레이드오프**:
    - BearSSL 클라이언트 IP SAN 매칭 미지원 → step-ca 서버 인증서의 IP SAN 박지만 클라이언트가 검증하지 않음. 검증 환경은 `setInsecure()` 우회, 운영 환경은 별도 ADR.
    - Store-and-Forward (LittleFS 메시지 큐) 는 본 단계에서 우선순위 후순위. 운영 시 센서 끊김으로 처리.
  - 부트스트랩 인증서/키 NVS 굽기 절차: 인프라 2 가 step CLI 로 발급 → 직접 USB / 암호화 채널 전달 → 인프라 1 이 펌웨어 빌드 시 LittleFS 이미지에 포함 또는 시리얼 입력.

- **Edge Gateway / Telegraf 배포** (다음 phase): 본 phase 의 PKI 가 동작한 후 가능.