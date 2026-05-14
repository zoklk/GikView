# Phase: security

본 phase 는 PKI 인프라를 구축한다 — step-ca 가 Intermediate CA 로 동작하고, cert-manager + step-issuer 가 K8s 워크로드(EMQX·Edge Gateway·Telegraf) 인증서를 자동 발급/갱신한다. ESP8266 디바이스는 부트스트랩 인증서 + CN 화이트리스트 패턴으로 정식 인증서를 자동 발급받는다(↔ EMQX 외부 mTLS). `device-room-mapping` ConfigMap 을 단일 진실 공급원으로, Mapping Generator CronJob 이 EMQX ACL(`emqx-acl`)·step-ca CN 화이트리스트(`step-ca-whitelist`)·device→room lookup(`telegraf-lookup`) 세 ConfigMap 을 동시 생성한다. Reloader 가 Secret/ConfigMap 변경 시 의존 워크로드 rollout 을 트리거한다.

본 phase 는 messaging (EMQX 배포 완료) 에 의존. 완료 후 EMQX 재배포 (mTLS listener 전환) 와 Edge Gateway/Telegraf 배포가 가능하다.

## Service: cert-manager

**technology**: cert-manager/cert-manager (v1.20.2)
**dependency**: [none]
**artifacts**: helm
**node_category**: [security]
**references**: [context/knowledge/cert-manager.md]

- cert-manager v1.20.2 단일 replica 배포. CRD 동시 설치, uninstall 시 CRD 보존.
- ACME / Vault / DNS solver 미사용 (외부 issuer 인 step-issuer 만 연동).
- Argo CD sync-wave: `-3` (가장 먼저). 모든 후속 컴포넌트가 cert-manager CRD 의존.
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
- Argo CD sync-wave: `-2`. cert-manager CRD 의존 + step-ca 보다 먼저 (StepClusterIssuer 가 step-ca 보다 먼저 떠야 step-ca 가 첫 인증서 요청 받을 때 즉시 처리 가능).
- **리소스**:
  - CPU: `10m` / `100m`
  - Memory: `32Mi` / `128Mi`

## Service: step-ca

**technology**: smallstep/step-ca (0.30.2)
**dependency**: [cert-manager, step-issuer]
**artifacts**: helm
**node_category**: [security]
**references**: [context/knowledge/step-ca.md]

- step-ca 단일 Pod non-HA 배포. `security` 카테고리 노드 고정 (prod e-s1, dev alpha-w1 — `config/harness.yaml` 의 `node_selectors.security`).
- 데이터 영속화: local PV (badger DB, 발급 이력). `reclaimPolicy: Retain`.
- **OS 사전 작업** (사람 1 회, 환경마다): badger DB hostPath `chown 1000:1000` (경로는 아래 "환경별 분리" 표 / `context/knowledge/step-ca.md`).
- **네트워크 사전 작업** (사람 1 회, 운영환경): 공유기 포트포워딩 `<외부포트>` → `<security 노드>:31900` — 디바이스가 학내망에서 step-ca 도달 (messaging.md 의 EMQX 포트포워딩과 동일 운영 패턴).
- **CA 자료 사전 생성** (사람 1 회, 오프라인): Root CA (ECDSA P-256, 10y, 키는 클러스터 외부 안전 보관) · Intermediate CA (P-256, 5y) · 부트스트랩 CA (P-256, 5y, 정식 trust 와 분리). K8s Secret 주입: `step-ca-certs` / `step-ca-secrets` / `step-ca-ca-password` / `step-ca-admin-jwk` (`step-ca-config` = ca.json 은 운영자가 안 만듦 — 엄브렐라 차트가 렌더). 절차·Secret 키 구조·`ca.json` 조립 방식은 `context/knowledge/step-ca.md`.
- **provisioner**:
  - `device-bootstrap` (X5C, root = 부트스트랩 CA, `disableRenewal: true`, `defaultTLSCertDuration: 2160h`) — 정식 인증서 발급 전용.
  - `device-renewal` (X5C, root = Intermediate, `allowRenewalAfterExpiry: false`, `defaultTLSCertDuration: 2160h`) — 정식 인증서 갱신 전용.
  - `admin` (JWK) — step-issuer 연결, K8s 워크로드 발급용.
  - device CN 명명 규약 `^device-[a-f0-9]{6}$`. X5C provisioner 가 발급 가능한 CN 은 `step-ca-whitelist` ConfigMap (mapping-generator wave `-1` 생성) 으로 제한 + device leaf 템플릿은 **DNS 타입 SAN 만** 허용 (비-DNS SAN 요청 거부) — 강제는 cert-template `{{ fail }}` 가드, 부팅 시 `merge-ca-config` initContainer 가 ca.json 에 머지 (결정 14번; rollout 트리거는 결정 15번).
  - 부트스트랩 경로 폐기/회전은 Bootstrap CA 통째 교체로 — CRL/OCSP 미운용 (결정 7번, 결정 13번; 절차 `context/knowledge/step-ca.md`).
- Argo CD sync-wave: `0`.
- **디바이스-facing 노출**: step-ca 서버 인증서 SAN (= `ca.json` 의 `dnsNames`, `values-<env>.yaml` 에서 주입) 은 운영 trust 명 (ClusterIP svc DNS) + loopback (`127.0.0.1`) 만. 노드 IP·외부 IP 는 안 넣음 — ESP8266 BearSSL 이 IP SAN 을 검증하지 않아 의미 없음. `127.0.0.1` 은 스모크/디버깅 경로 (`kubectl port-forward → 127.0.0.1:19000`) 의 step CLI TLS 검증을 위해 필요. 운영 trust 전략은 후속 ADR. end-to-end 동작은 ESP8266 펌웨어 클라이언트 (아래 후속 작업) 후 성립 — 본 phase 검증 범위는 K8s 워크로드 발급 경로 (cert-manager + step-issuer → step-ca).
- **Port**:
  - `https: 9000` — step-ca REST API (`/1.0/sign`, `/1.0/renew`). ClusterIP (step-issuer/cert-manager 내부용) + NodePort `step-ca-nodeport` (고정 `nodePort: 31900`, `externalTrafficPolicy: Local`, `security` 노드). 외부 포트 매핑은 messaging.md 패턴 (공유기 포트포워딩).
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
  - step-ca — `configmap.reloader.stakater.com/reload: step-ca-whitelist` (CN 화이트리스트 변경 시 rollout — step-ca 는 ca.json template/templateData hot-reload 안 됨; 메커니즘은 결정 14번·15번).
  - `telegraf-lookup` → Telegraf, Edge Gateway client cert 등의 Reloader annotation 은 해당 워크로드를 배포하는 후속 phase 에서 추가 (security 결정 8 번은 최종 상태 기준 — 본 phase 는 그 부분집합).
- Argo CD sync-wave: `-3` (cert-manager 와 병행). 다른 컴포넌트가 reloader annotation 을 달기 전에 떠 있어야 첫 변경 즉시 감지.
- **리소스**:
  - CPU: `10m` / `100m`
  - Memory: `32Mi` / `128Mi`

## Service: mapping-generator

**technology**: 자체 코드 (Go CronJob)
**dependency**: [none]
**artifacts**: helm, docker
**node_category**: [security]
**references**: [none]

- 자체 코드 — Helm chart + multi-arch Docker 이미지 (하네스가 `conventions.build_platforms` = `linux/amd64`+`linux/arm64` 로 `docker buildx build --push` 단일 명령으로 manifest list 빌드/푸시). 빌드 호스트 사전 셋업은 Kubeharness README "사전 준비 > multi-arch 이미지 빌드".
- **단일 진실 공급원**: `device-room-mapping` ConfigMap (사람이 git commit 으로 관리).
  - data 키 = `mapping.csv`, 헤더 행 없음, 한 줄 = `device_id,room_id`.
  - room_id 규약 = `room-{건물 a|b}-{층}-{호실 idx}` (예 `room-a-3-2`; 스모크 엔트리 `room-a-9-9` 는 의도적으로 비실재 슬롯).
  - 별도 수동 ConfigMap 이 아니라 mapping-generator helm chart 의 templates 가 `.Values.deviceRoomMapping` 맵을 렌더 — `values-dev.yaml`/`values-prod.yaml` 양쪽에 스모크 엔트리 `deviceRoomMapping: { device-aaaaaa: room-a-9-9 }` (실제 디바이스 추가 시 줄 추가).
  - mapping-generator 는 각 `device_id` 를 `^device-[a-f0-9]{6}$` 로 검증한 항목만 출력 (불일치는 skip + 로그 — 오타가 `step-ca-whitelist` 로 새는 거 방지).
  - Edge Gateway 등은 이 SoT 를 직접 참조 — mapping-generator 가 따로 만들어주는 CM 은 없음.
- **출력 ConfigMap 3 종 동시 자동 생성**:
  - `emqx-acl`: EMQX file authorizer 가 마운트. Erlang tuple 형식. CN (= peer_cert_as_username) 기반 publish/subscribe 권한.
```erlang
    %% device-aabbcc 는 자기 토픽만 publish
    {allow, {user, "device-aabbcc"}, publish, ["sensors/device-aabbcc/occupancy"]}.
    %% edge-gateway / telegraf 는 shared subscription. ACL 매칭 시 EMQX 가
    %% $share/<group>/ prefix 를 제거한 후 비교하므로 규칙엔 prefix 없이 쓴다
    %% (클라이언트는 SUBSCRIBE 시 $share/edge-gw/... 그대로 보내고 EMQX 가 떼고 매칭).
    {allow, {user, "edge-gateway"}, subscribe, ["sensors/+/occupancy"]}.
    %% telegraf 는 별도 shared group (그룹명만 다름, ACL 입장에선 동일 토픽)
    {allow, {user, "telegraf"}, subscribe, ["sensors/+/occupancy"]}.
    %% 그 외 거부
    {deny, all}.
```
  - `step-ca-whitelist` (key `whitelist.json` = 허용 device CN JSON 배열): step-ca 가 부팅 시 `merge-ca-config` initContainer 가 ca.json 의 각 X5C provisioner `options.x509.templateData.allowedCNs` 에 머지. 가드 로직(`template` 문자열)은 `step-ca-config` ConfigMap 의 정적 부분, 화이트리스트 데이터만 mapping-generator 가 주입 — `step-ca-whitelist` 가 비면 `allowedCNs: []` → 모든 device cert 발급 0 (fail-closed). 강제 메커니즘 근거는 결정 14번.
  - `telegraf-lookup`: Telegraf processor.starlark 또는 processor.lookup 이 참조. device_id → room_id 매핑 csv. (Telegraf 는 후속 phase 배포 — 본 phase 에선 ConfigMap 만 미리 생성됨.)
- **스케줄**: CronJob `*/15 * * * *` (15 분 주기). 디바이스 추가 빈도 낮아 충분.
- **rollout trigger**: ConfigMap 갱신 → Reloader 가 의존 워크로드 rollout 트리거 (본 phase: EMQX `emqx-acl`, step-ca `step-ca-whitelist`; Telegraf `telegraf-lookup` 은 후속 phase 부터). step-ca StatefulSet 의 Reloader annotation 은 엄브렐라 차트의 post-render strategic-merge patch 로 부착 (메커니즘 근거·기각 대안은 결정 15번). step-ca 는 ca.json `template`/`templateData` hot-reload 가 안 되어 `step-ca-whitelist` 변경 시 rollout 필요, rollout 중 약 5~10초 발급 거부 윈도우. **prod ArgoCD 환경**: ArgoCD `helm` 소스 post-renderer 미실행 → annotation 누락 → whitelist 변경 후 step-ca 재적용은 ArgoCD app refresh 또는 수동 rollout.
- **권한**: ConfigMap get/list/update/create 가능한 ServiceAccount (init Job 과 CronJob 공용).
- **Argo CD sync-wave: `-1`** (step-ca·emqx 보다 먼저). 차트가 `device-room-mapping` ConfigMap + CronJob (`*/15 * * * *`) + 일회성 init Job (배포 즉시 1 회 실행 — influxdb `post-install-database-job.yaml` 패턴; 이 Job 이 완료돼야 다음 wave 진행) + RBAC 를 함께 선언. init Job 이 세 ConfigMap 초기 생성 → step-ca (wave 0) initContainer / emqx (wave 1) ACL 마운트 시 이미 존재.
- **이미지 레지스트리 사전 작업** (사람 1 회, 환경마다): GHCR 패키지 private 유지 → `docker login ghcr.io` (push: `write:packages` PAT) + gikview 네임스페이스에 `ghcr-pull` Secret (`kubectl create secret docker-registry ghcr-pull --docker-server=ghcr.io …`, `read:packages` 전용 PAT) 사전 생성. 차트가 ServiceAccount 의 imagePullSecrets 로 참조.
- **multi-arch buildx 빌드 호스트 사전 작업** (사람 1 회, `/deploy` 머신마다): `docker buildx create --name multiarch --driver docker-container --bootstrap --use` + `docker run --privileged --rm tonistiigi/binfmt --install all`. `docker login ghcr.io` 도 이 시점에 돼 있어야 함 (`buildx --push` 가 빌드 전 인증 필요). 상세: Kubeharness README "사전 준비 > multi-arch 이미지 빌드".
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
  - 기존 평문 `mqtt: 1883` listener 비활성화 (helm values 에서 enable: false). NodePort 도 mqtts 만 노출 — NodePort 번호는 `31884` (messaging.md / `context/knowledge/emqx.md`). 공유기: 외부포트 8883 → e-s2:31884, 8884 → e-s3:31884.
- **서버 인증서**: Certificate 리소스 추가.
  - commonName: `emqx.gikview.svc.<cluster-domain>` (dnsNames 와 동일하게 `.Values.certificate.clusterDomain` 으로 환경별 분리)
  - dnsNames: `emqx`, `emqx.gikview.svc.<cluster-domain>`. cluster-domain 만 환경별 (dev = `alpha.nexus.local`, prod = `cluster.local`) — 차트가 `.Values.certificate.clusterDomain` 으로 주입. ClusterIP svc DNS 만 cert SAN 에 두는 이유는 실제 도달 트래픽이 svc 경유 (Telegraf/Edge-GW) 이고 headless/wildcard 는 dead SAN (노드간 통신 평문, pod-stable DNS 직접 접속 클라이언트 없음).
  - ipAddresses: `192.168.0.102`, `192.168.0.103` (prod) — dev 는 환경별 분리. 이 항목이 mTLS 서버 cert SAN IP 의 정본 (knowledge/emqx.md·cert-manager.md 는 이 값을 참조).
  - duration: `2160h`, renewBefore: `720h`
  - issuerRef: StepClusterIssuer
  - secretName: `emqx-server-tls`
- **ACL backend 전환**: file authorizer 활성화, `emqx-acl` ConfigMap 마운트.
  - `/etc/emqx/acl/acl.conf` 경로로 ConfigMap volumeMount.
  - authorization sources 의 첫 entry 로 `{type = file, path = "/etc/emqx/acl/acl.conf"}` 등록.
  - `no_match = deny` 로 미매칭 시 거부.
- **CA bundle / 체인 (값)**: listener `ssl_options.cacertfile` = `emqx-server-tls` Secret 의 `ca.crt` (= StepClusterIssuer `caBundle` = step-ca **Root CA**); EMQX 가 서버로서 제시하는 체인 (`certfile`) = `emqx-server-tls` 의 `tls.crt` (= leaf + Intermediate). Root 를 trust anchor 로 쓰는 이유·EMQX 5.8.6 `partial_chain` 부재·클라이언트의 `leaf + Intermediate` 제시 요구는 결정 12번, `context/knowledge/emqx.md`, `context/knowledge/step-ca.md`. 부트스트랩 인증서 차단은 TLS 단이 아니라 ACL `no_match = deny`.
- **Reloader annotation** (StatefulSet metadata):
  - `secret.reloader.stakater.com/reload: "emqx-server-tls"` — 서버 인증서 갱신 시 rollout.
  - `configmap.reloader.stakater.com/reload: "emqx-acl"` — ACL 변경 시 rollout.
- **client_id 충돌**: 같은 CN 으로 두 클라이언트 접속 시 (결정 7번 "유령 인증서 동시 publish") 본 phase 에서는 default 동작 유지, visibility 단계에서 동일 CN 접속 감지 alert 추가.
- Argo CD sync-wave: `1` (step-ca 다음; `emqx-acl` 은 mapping-generator wave `-1` 의 init Job 이 이미 생성).
- **리소스 / Port** 는 messaging phase 와 동일. 본 phase 에서 변경하지 않음.

## Argo CD sync-wave 요약

| wave | 서비스 | 비고 |
|---|---|---|
| `-3` | cert-manager | CRD 먼저 (모든 후속 컴포넌트 의존) |
| `-3` | reloader | cert-manager 와 병행 — 누가 reloader annotation 달기 전에 떠 있어야 |
| `-2` | step-issuer | cert-manager CRD 의존; StepClusterIssuer 함께 선언 |
| `-1` | mapping-generator | `device-room-mapping` CM + CronJob + 일회성 init Job (완료돼야 다음 wave) → `emqx-acl`/`step-ca-whitelist`/`telegraf-lookup` 이 step-ca·emqx 보다 먼저 존재. dependency 없음 |
| `0` | step-ca | initContainer 가 `step-ca-whitelist` (wave `-1` 생성) 를 `ca.json` 에 머지; `ca-whitelist` 볼륨 `optional: true` |
| `1` | emqx | `emqx-acl` 마운트 (messaging phase 배포본의 mTLS 재전환); step-ca 다음 |

후속 phase 의 Edge Gateway / Telegraf 는 본 phase 완료 후 별도 phase.

## 후속 작업 (본 phase 범위 외, 디바이스/펌웨어 작업)

- **ESP8266 펌웨어 EST-like 흐름** (인프라 1, 코드 — 본 phase 범위 외)
  - 표준 BearSSL secure client 가 키 생성/CSR(PKCS#10)/EST 를 안 줘서 BearSSL(mTLS+HTTPS) + uECC(P-256 키생성) + 자체 ASN.1 DER CSR 인코딩 조합 채택. 조합 근거·디바이스 메모리 제약·검증된 트레이드오프는 `context/knowledge/step-ca.md`.
  - 부트스트랩 흐름: 첫 부팅 시 키페어 생성 → CSR(CN = `device-XXXXXX`, SAN 은 없거나 같은 값의 **DNS SAN 만** — IP SAN 넣으면 step-ca 가 발급 거부) → JWT(x5c=부트스트랩 cert) → step-ca `/1.0/sign` → 정식 cert LittleFS 저장 → 부트스트랩 cert/키 삭제. 운영 중 만료 30d 전 `/1.0/renew`. EMQX 핸드셰이크엔 `[leaf, intermediate]` 둘 다 제시.
  - 부트스트랩 cert/키 NVS 굽기: 인프라 2 가 step CLI 발급 → 안전 채널 전달 → 인프라 1 이 LittleFS 이미지에 포함.
- **Edge Gateway / Telegraf 배포** (다음 phase): 본 phase 의 PKI 가 동작한 후 가능.
