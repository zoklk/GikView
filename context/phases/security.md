# Phase: security

본 phase 는 ESP8266 디바이스 ↔ EMQX 외부 mTLS 와 EMQX ↔ 내부 워크로드 (Edge Gateway, Telegraf) mTLS 의 PKI 인프라를 구축. step-ca 가 Intermediate CA 로 동작하고 cert-manager + step-issuer 로 K8s 워크로드 인증서를 자동 발급/갱신. 부트스트랩 인증서 + MAC 화이트리스트 패턴으로 ESP8266 정식 인증서 자동 발급. `device-room-mapping` ConfigMap 을 단일 진실 공급원으로 Mapping Generator CronJob 이 EMQX ACL(`emqx-acl`), step-ca CN 화이트리스트(`step-ca-whitelist`), device→room lookup(`telegraf-lookup`, Telegraf 용) 세 ConfigMap 을 동시 자동 생성. Reloader 가 Secret/ConfigMap 변경 시 의존 워크로드 rollout 자동 트리거.

본 phase 는 messaging (EMQX 배포 완료) 의존. 본 phase 완료 후 EMQX 재배포 (mTLS listener 전환), Edge Gateway/Telegraf 배포가 가능.

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

- step-ca 단일 Pod non-HA 배포. `security` 카테고리 노드 고정 (prod 는 e-s1 = control-plane, dev 는 alpha-w1; `config/harness.yaml` 의 `node_selectors.security`).
- 데이터 영속화: local PV (badger DB, 발급 이력/revocation 데이터). `reclaimPolicy: Retain`.
- **OS 사전 작업** (사람 1 회, 운영환경): `chown 1000:1000 <pv-path>/` (badger DB hostPath).
- **네트워크 사전 작업** (사람 1 회, 운영환경): 공유기 포트포워딩 `<외부포트>` → `<security 노드>:<NodePort>` (prod `e-s1:31900`, dev `alpha-w1:<dev nodePort>`) — 디바이스가 학내망에서 step-ca 도달; messaging.md 의 EMQX 포트포워딩과 동일 운영 패턴.
- **Root CA + Intermediate CA + 부트스트랩 CA 사전 생성** (사람 1 회, 오프라인):
  - Root CA (ECDSA P-256, 10y) 오프라인 생성, 서명 후 키는 클러스터 외부 안전 보관.
  - Intermediate CA (ECDSA P-256, 5y) Root 로 서명. K8s Secret 으로 클러스터 주입.
  - 부트스트랩 CA (ECDSA P-256, 5y) Root 로 별도 서명. K8s Secret 으로 클러스터 주입.
  - 인증서/키 Secret: `step-certificates-certs`, `step-certificates-ca-key`, `step-certificates-ca-password`.
- **Provisioner 구성** (helm values inject.config.authority.provisioners — 정적 부분만; 디바이스별 CN 목록은 아래 참고):
  - `device-bootstrap` (X5C): 부트스트랩 CA 를 root 로. CN 명명 규약 `^device-[a-f0-9]{6}$` (펌웨어 + mapping-generator 검증으로 강제; `ca.json` 의 `allow.cn` 은 정규식이 아니라 등록된 CN 명시 목록 — 아래 참고). `disableRenewal: true`. 정식 인증서 발급 전용.
  - `device-renewal` (X5C): Intermediate CA 를 root 로. 동일 — `allow.cn` 명시 목록. 정식 인증서 갱신 전용.
  - `admin` (JWK): 운영자 / K8s 워크로드 발급용. step-issuer 연결.
  - **`policy.x509.allow.cn` 은 등록된 device CN 명시 목록만 (정규식 안 넣음 — 정규식만 두면 6-hex CN 아무거나 통과해 whitelist 가 무의미해짐). helm values 의 X5C 템플릿 블록엔 `allow.cn` 빈 목록(또는 생략) + `deny` + claims 등 정적 부분만; 실제 CN 목록은 initContainer 가 `step-ca-whitelist` ConfigMap 으로 채움 (결정 (c)). step-ca workload 에 `extraInitContainers`/`extraVolumes`/`extraVolumeMounts`(step-certificates 1.30.x native 훅)로 머지 initContainer + `ca-merged` emptyDir 추가; `ca-whitelist` 볼륨은 `optional: true`(whitelist 아직 없어도 부팅 OK, initContainer 는 없으면 빈 목록 취급); `bootstrap.enabled: false`. (initContainer 가 목록을 set 으로 덮을지 append 할지는 step-ca 의 빈 allowlist 동작 확인 후 차트에서 확정.) 상세: `context/knowledge/step-ca.md` Policy 절.**
  - **부트스트랩 경로 폐기/회전**: CRL/OCSP 미도입(결정 7번)이므로 부트스트랩 크리덴셜 폐기는 Bootstrap CA 회전으로 — 프로비저닝 완료 후 `device-bootstrap` provisioner 제거 또는 `roots` 비우기, 유출 시 새 Bootstrap CA 발급 + `device-bootstrap.roots` 교체 + 재플래시(운영 체인 영향 0). 결정 13번, `context/knowledge/step-ca.md`.
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
- Argo CD sync-wave: `-3` (cert-manager 와 병행). 다른 컴포넌트가 reloader annotation 을 달기 전에 떠 있어야 첫 변경 즉시 감지.
- **리소스**:
  - CPU: `10m` / `100m`
  - Memory: `32Mi` / `128Mi`

## Service: mapping-generator

**technology**: 자체 코드 (Go CronJob)
**dependency**: []  <!-- 결정 (c) 에선 mapping-generator 가 step-ca API 를 안 씀 — ConfigMap 만 읽고 씀. 배포 순서는 sync-wave 로만 보장. -->
**artifacts**: helm, docker
**node_category**: [security]
**references**: [none]

- 자체 코드. Helm chart + Docker 이미지 빌드 — 하네스가 `conventions.build_platforms`(현재 `linux/amd64`+`linux/arm64`)로 `docker buildx build --push` 단일 명령으로 multi-arch manifest list 를 빌드/푸시. Dockerfile 은 두 arch 모두에서 깨끗이 빌드돼야 함(`TARGETARCH` 분기 없이 arch 별 바이너리 다운로드 금지 — buildx 가 `TARGETPLATFORM`/`TARGETARCH`/`TARGETOS` build arg 제공). 빌드 호스트 사전 셋업은 아래 "이미지 레지스트리 사전 작업" 참고.
- **단일 진실 공급원**: `device-room-mapping` ConfigMap (사람이 git commit 으로 관리). data 키 = `mapping.csv`, 헤더 행 없음, 한 줄 = `device_id,room_id`. room_id 규약 = `room-{건물 a|b}-{층}-{호실 idx}` (예 `room-a-3-2`; 스모크 엔트리 `room-a-9-9` 는 의도적으로 비실재 슬롯). 이 CM 은 mapping-generator helm chart 의 templates 에서 `.Values.deviceRoomMapping` 맵을 렌더 — 별도 수동 ConfigMap 이 아님. `values-dev.yaml`/`values-prod.yaml` 양쪽에 스모크 엔트리 `deviceRoomMapping: { device-aaaaaa: room-a-9-9 }` (실제 디바이스 추가 시 줄 추가). mapping-generator 는 각 `device_id` 를 `^device-[a-f0-9]{6}$` 로 검증한 항목만 출력(불일치는 skip + 로그 — 오타가 `step-ca-whitelist` 로 새는 거 방지). Edge Gateway 등은 이 SoT 를 직접 참조 — mapping-generator 가 따로 만들어주는 CM 은 없음.
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
  - `step-ca-whitelist`: 허용 device CN 목록만 (결정 (c) — `ca.json` 전체가 아니라 머지 consumer 가 먹는 모양: JSON array of CN/regex 또는 yaml list). step-ca workload 의 initContainer 가 부팅 시 `ca.json` 템플릿의 X5C provisioner `policy.x509.allow.cn` 에 머지. step-ca 의 Reloader annotation 이 이 ConfigMap 에 달림.
  - `telegraf-lookup`: Telegraf processor.starlark 또는 processor.lookup 이 참조. device_id → room_id 매핑 csv. (Telegraf 는 후속 phase 배포 — 본 phase 에선 ConfigMap 만 미리 생성됨.)
- **`step-ca-whitelist` 반영 방식 — (c) initContainer 머지로 결정**: `ca.json` 의 정적 부분만(`policy.x509.allow.cn` 은 빈 목록, + `deny` + claims) `inject.config` 로 렌더되는 템플릿 ConfigMap 에 담고, 디바이스별 CN 목록은 mapping-generator 가 만드는 `step-ca-whitelist` ConfigMap 으로 분리. step-ca workload 의 `extraInitContainers` 가 부팅 시 템플릿 config 디렉토리를 emptyDir(`ca-merged`)로 복사 + jq 로 whitelist CN 들을 `allow.cn` 에 채우고, `extraVolumeMounts` 로 그 emptyDir 를 `/home/step/config` 에 덮어 마운트(나중 마운트 우선 → 메인 컨테이너 command/args override 불필요). `ca-whitelist` 볼륨은 `optional: true`(whitelist 아직 없어도 부팅 OK), `bootstrap.enabled: false`. ✅ 확인 완료: step-certificates 1.30.x 가 `extraInitContainers`/`extraVolumes`/`extraVolumeMounts`/`extraContainers`/`command`/`args`(전부 default `[]`) 를 노출 → 머지 initContainer 는 순수 values 로 가능. step-ca StatefulSet 의 Reloader annotation 부착은 위 "rollout trigger" 불릿 참고(post-render strategic-merge patch). 상세: `context/knowledge/step-ca.md` Policy 절.
- **스케줄**: CronJob `*/15 * * * *` (15 분 주기). 디바이스 추가 빈도 낮아 충분.
- **rollout trigger**: ConfigMap 갱신 후 Reloader 가 의존 워크로드 rollout 자동 트리거 (workload annotation 으로). 본 phase 범위: EMQX(`emqx-acl`), step-ca(`step-ca-whitelist`). Telegraf(`telegraf-lookup`) 는 Telegraf 배포 phase 부터. — step-ca StatefulSet 의 Reloader annotation 은 업스트림 step-certificates 차트가 워크로드 metadata annotation 훅을 안 노출 → 엄브렐라 차트의 post-render(kustomize) strategic-merge patch 로 주입(`kustomization.yaml` + patch). 대안 B(mapping-generator 가 `kubectl rollout restart statefulset/step-ca` 직접 호출)는 기각 — 메커니즘 비대칭(EMQX 는 Reloader)·mapping-generator RBAC 확대(`statefulsets patch`)·whitelist 변경감지 로직 필요(없으면 15 분마다 무의미 restart)·`smoke-test-step-ca.sh #4b` 의 annotation hard-check 위반.
- **권한**: ConfigMap get/list/update/create 가능한 ServiceAccount (init Job 과 CronJob 공용).
- **Argo CD sync-wave: `-1`** (step-ca·emqx 보다 먼저). 차트가 `device-room-mapping` ConfigMap + CronJob(`*/15 * * * *`) + 일회성 init Job(배포 즉시 1 회 실행 — influxdb `post-install-database-job.yaml` 패턴; 이 Job 이 완료돼야 다음 wave 진행) + RBAC(ConfigMap get/list/create/update SA, init Job·CronJob 공용) 를 함께 선언. init Job 이 세 ConfigMap 초기 생성 → step-ca(wave 0) initContainer / emqx(wave 1) ACL 마운트 시 이미 존재.
- 이미지 레지스트리 사전 작업 (사람 1회, 환경마다): GHCR 패키지를 private 유지 → docker login ghcr.io (push: write:packages PAT) + gikview 네임스페이스에 ghcr-pull Secret
  (kubectl create secret docker-registry ghcr-pull --docker-server=ghcr.io ..., read:packages 전용 PAT) 사전 생성. 차트가 ServiceAccount 의 imagePullSecrets 로 참조.
- multi-arch buildx 빌드 호스트 사전 작업 (사람 1회, `/deploy` 를 돌리는 머신마다): `docker buildx create --name multiarch --driver docker-container --bootstrap --use` + `docker run --privileged --rm tonistiigi/binfmt --install all` (기본 `docker` 드라이버 buildx 로는 multi-platform 빌드 불가; Docker Desktop 이면 둘 다 번들). `docker login ghcr.io` 는 buildx `--push` 가 빌드 *전* 에 인증이 필요하므로 이 시점에 돼 있어야 함. 상세: Kubeharness README "사전 준비 > multi-arch 이미지 빌드".
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
- **CA bundle 마운트 (= listener `ssl_options.cacertfile`)**: step-ca **Root CA** 를 클라이언트 인증서 검증 trust anchor 로 — cert-manager 가 생성한 `emqx-server-tls` Secret 의 `ca.crt`(= StepClusterIssuer `caBundle` = Root) 를 그대로 마운트. **Intermediate-only 는 EMQX 5.8.6 의 `partial_chain` 부재로 미채택**(security 결정 12번) — 부트스트랩 인증서 차단은 TLS 단이 아니라 ACL `no_match = deny` 가 담당. EMQX 가 *서버로서* 제시하는 체인(`certfile`)은 `emqx-server-tls` 의 `tls.crt`(= leaf + Intermediate) 그대로.
- **클라이언트 측 체인 제시**: 디바이스/워크로드는 mTLS 핸드셰이크에 `leaf + Intermediate` 번들 제시 필요(EMQX 가 Root 를 앵커로 가지므로 OTP `ssl` 이 `leaf → Intermediate → Root` 경로를 구성하려면 Intermediate 가 핸드셰이크에 와 있어야 함; leaf 만 보내면 검증 실패). cert-manager 발급 Secret 의 `tls.crt` 는 자동 충족. ESP8266 펌웨어는 `/1.0/sign`·`/1.0/renew` 응답의 `certChain`(=[leaf, intermediate])을 둘 다 저장하고 BearSSL `setClientECCert()` 에 둘 다 제시(펌웨어 후속 작업).
- **Reloader annotation** (StatefulSet metadata):
  - `secret.reloader.stakater.com/reload: "emqx-server-tls"` — 서버 인증서 갱신 시 rollout.
  - `configmap.reloader.stakater.com/reload: "emqx-acl"` — ACL 변경 시 rollout.
- **client_id 충돌 처리**: 같은 CN 으로 두 클라이언트가 접속 시 EMQX 가 나중 접속을 끊지 않게 `mqtt.discard_session_on_disconnect: false` 또는 `clientid_override` 검토 (security 결정 7번 의 "유령 인증서 동시 publish" 대응). 본 phase 에서는 default 유지하되 visibility 단계에서 동일 CN 접속 감지 alert 추가.
- Argo CD sync-wave: `1` (step-ca 다음; `emqx-acl` 은 mapping-generator wave `-1` 의 init Job 이 이미 생성).
- **리소스 / Port** 는 messaging phase 와 동일. 본 phase 에서 변경하지 않음.

## Argo CD sync-wave 요약

| wave | 서비스 | 비고 |
|---|---|---|
| `-3` | cert-manager | CRD 먼저 (모든 후속 컴포넌트 의존) |
| `-3` | reloader | cert-manager 와 병행 — 누가 reloader annotation 달기 전에 떠 있어야 |
| `-2` | step-issuer | cert-manager CRD 의존; StepClusterIssuer 함께 선언 |
| `-1` | mapping-generator | `device-room-mapping` CM + CronJob + 일회성 init Job(완료돼야 다음 wave) → `emqx-acl`/`step-ca-whitelist`/`telegraf-lookup` 이 step-ca·emqx 보다 먼저 존재. dependency 없음 |
| `0` | step-ca | initContainer 가 `step-ca-whitelist`(wave `-1` 생성) 를 `ca.json` 에 머지; `ca-whitelist` 볼륨 `optional: true` |
| `1` | emqx | `emqx-acl` 마운트 (messaging phase 배포본의 mTLS 재전환); step-ca 다음 |

후속 phase 의 Edge Gateway / Telegraf 는 본 phase 완료 후 별도 phase.

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