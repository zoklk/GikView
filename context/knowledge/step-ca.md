# step-ca — 운영 지식 메모

---

## 이미지 / 버전

**채택**: `smallstep/step-ca:0.30.2` (`docker.io/smallstep/step-ca:0.30.2`)

step-ca 는 Smallstep 의 오픈소스 PKI 서버. ESP8266 디바이스 발급 (부트스트랩 → 정식 인증서 갱신) 과 K8s 워크로드 인증서 (EMQX, Edge Gateway, Telegraf) 발급을 단일 Intermediate CA 로 통합 운영. 본 프로젝트는 9 대 규모이고 디바이스별 인증서를 컴파일 시점에 주입(디바이스마다 다른 NVS 이미지)하기 어려운 ESP8266 다수를 다루므로 자동 발급/갱신 메커니즘이 필수 (부트스트랩 패턴은 공통 인증서만 컴파일 시점에 굽고 정식 인증서는 첫 부팅 시 발급).

선택 근거: HashiCorp Vault PKI 대비 학습 곡선 작음, AWS Private CA 대비 외부 의존 없음, OpenSSL 자체 CA 대비 서버 API + 자동화 가능. **버전: `0.30.x` 고정** — (1) `0.30.0` 미만 전부가 CVE-2026-30836(CVSS 10, SCEP UpdateReq 통한 미인증 인증서 발급, `0.30.0` 에서 수정)에 영향, (2) helm chart `step-certificates 1.30.1` 의 `appVersion` 이 `0.30.2` 라 chart-native 버전과 일치. 0.31 출시 시 release notes 확인 후 승격.

Helm chart: `smallstep/step-certificates` `1.30.1` (repo: `https://smallstep.github.io/helm-charts/`, appVersion `0.30.2`)

> **RFC 7030 EST 미지원 명시**: step-ca 오픈소스는 EST 프로토콜을 직접 지원하지 않음 (이슈 #2366, 2026-05 기준 미구현). SCEP/ACME/X5C/JWK/OIDC/K8SSA provisioner 만 제공. 본 프로젝트는 X5C provisioner 로 EST-like("기존 인증서로 새 인증서 발급") 흐름을 구현하되 ESP8266 은 표준 EST 클라이언트가 아닌 step-ca REST API (`/1.0/sign`, `/1.0/renew`) 를 호출. architecture 문서의 "EST" 용어는 "X5C 기반 EST-like 흐름" 으로 해석. **SCEP provisioner 미사용** — CVE-2026-30836 의 직접 익스플로잇 경로(SCEP)에는 해당 없으나 코드 노출 회피 차원에서 `0.30.0+` 사용.
>
> ESP8266 펌웨어 측 EST-like 클라이언트: ESP8266 Arduino 코어의 표준 secure WiFi client (`WiFiClientSecure`, BearSSL 기반) 는 TLS 핸드셰이크/HTTPS 만 제공하고 키 페어 생성·CSR(PKCS#10) 인코딩·EST 같은 PKI 프리미티브는 노출하지 않음 → 그 부분을 펌웨어에서 직접 구현해야 함. 추가로 디바이스 메모리 제약(SRAM ~80KB, 운영 mTLS 안정화 시점 free heap ~18.4KB, EST 호출 중 일시 ~12.5KB)이라 별도 mbedTLS 풀 스택을 끼워 넣는 것도 불가. → 채택 조합: **BearSSL**(mTLS 핸드셰이크 + HTTPS POST, `WiFiClientSecure.setClientECCert()` 로 클라이언트 인증서/키 주입) + **uECC(micro-ecc)**(ECDSA P-256 키 페어 생성, flash ~3KB) + **자체 ASN.1 DER CSR(PKCS#10) 인코딩**(펌웨어 단 직접 구현, ~130줄). 이 조합 선택은 "표준 client 가 CSR/EST 미제공" 이 주된 이유. 펌웨어 흐름 상세는 phase doc 의 "후속 작업".

## 주요 설정

step-ca 는 `ca.json` 으로 거의 모든 동작을 제어. Helm chart 는 ConfigMap 으로 ca.json 을 주입하거나 chart values 로 inline 선언. 본 프로젝트는 `inject.config` 패턴으로 git 추적 가능하게 선언.

```yaml
# values.yaml (공통)
# image.tag 는 chart 1.30.1 의 appVersion(0.30.2)과 동일 — override 생략해도 됨.
# 명시 override 시:
# image:
#   repository: "smallstep/step-ca"
#   tag: "0.30.2"
inject:
  enabled: true
  config:
    address: ":9000"
    dnsNames:
      - "step-ca"
      - "step-ca.gikview.svc.cluster.local"
      - "127.0.0.1"
      # + 환경별 노드 IP (NodePort 노출용 SAN) — "환경별 분리 필요 항목" 표 참조. 노드 IP 는 env 값이라 공통 블록엔 안 둠.
    db:
      type: "badgerv2"
      dataSource: "/home/step/db"
    authority:
      claims:
        defaultTLSCertDuration: "2160h"   # 90d (정식 인증서 기본)
        maxTLSCertDuration: "8760h"       # 365d
        minTLSCertDuration: "5m"
        disableRenewal: false
      provisioners:
        # 부트스트랩 인증서로 디바이스 정식 인증서 발급
        - type: "X5C"
          name: "device-bootstrap"
          roots: "<base64 of bootstrap-ca.pem>"  # 부트스트랩 발급한 CA
          claims:
            defaultTLSCertDuration: "2160h"
            disableRenewal: true            # 부트스트랩 자체는 갱신 불가
        # 정식 인증서로 갱신
        - type: "X5C"
          name: "device-renewal"
          roots: "<base64 of intermediate-ca.pem>"
          claims:
            defaultTLSCertDuration: "2160h"
            allowRenewalAfterExpiry: false
        # K8s 워크로드 / 운영자 직접 발급용
        - type: "JWK"
          name: "admin"
          key: "<JWK public key JSON>"
          encryptedKey: "<encrypted JWK private key>"

# Root + Intermediate 인증서/키 주입
existingSecrets:
  enabled: true
  ca: true              # step-certificates-ca-key 시크릿 (root_ca_key, intermediate_ca_key)
  certsAsSecret: true   # step-certificates-certs 시크릿 (root_ca.crt, intermediate_ca.crt)

# Root/Intermediate 를 오프라인 사전 생성해 주입하므로 `step ca init` 부트스트랩 Job 불필요
bootstrap:
  enabled: false

ca:
  password:
    secretKeyRef:
      name: "step-certificates-ca-password"
      key: "password"   # Intermediate 키 복호화 패스워드

# persistence: badger DB 영속화
persistence:
  enabled: true
  storageClass: "local-storage"
  size: "1Gi"

# securityContext
podSecurityContext:
  fsGroup: 1000
containerSecurityContext:
  runAsUser: 1000
  runAsGroup: 1000
  readOnlyRootFilesystem: false  # badger DB write 필요

# nodeSelector / 외부 노출(NodePort) 관련 값은 "환경별 분리 필요 항목" 표 + "### Service 노출" 절 참조.
```

### Service 노출 — ClusterIP + NodePort

업스트림 차트의 `service.type` 은 `ClusterIP` 유지(step-issuer/cert-manager → step-ca 내부 발급용). 디바이스용 외부 노출은 엄브렐라 차트의 자체 `templates/service-nodeport.yaml`(EMQX `service-nodeport.yaml` 패턴)로 별도 NodePort Service 추가 — `type: NodePort`, `port: 9000`, 고정 `nodePort`(예 `31900`, EMQX 의 nodePort 와 다른 번호 — NodePort 번호는 cluster 전역 할당이라 노드가 달라도 같은 번호면 충돌), `externalTrafficPolicy: Local`(디바이스 실제 IP 보존). 도달지점이 `security` 카테고리 노드(prod e-s1 / dev alpha-w1) 하나뿐이라 ingress 추상화는 이득 없음 (messaging.md 결정 3 = EMQX NodePort 와 동일 토폴로지, security.md 결정 11).

step-ca 가 부팅 시 Intermediate 로 자체 발급하는 서버 인증서는 `inject.config.dnsNames` 의 항목만 SAN 으로 가지므로 **노드 IP 를 `dnsNames` 에 반드시 추가**해야 디바이스가 TLS 검증 가능 (단 ESP8266 BearSSL 은 IP SAN 미검증 — 아래 주의사항). 공유기 포트포워딩 `<외부포트> → <노드>:<nodePort>` 는 운영자 1 회 작업.

### Policy — CN 화이트리스트 (결정 c: initContainer 머지)

정책은 provisioner 단위로 선언. 본 프로젝트는 X5C provisioner (`device-bootstrap`, `device-renewal`) 의
`policy.x509.allow.cn` 을 **등록된 device CN 명시 목록**으로 둔다 (정규식 안 넣음 — 정규식만 두면
`^device-[a-f0-9]{6}$` 패턴인 6-hex CN 아무거나 통과해 whitelist 가 무의미해짐; 그 명명 규약은
펌웨어 + mapping-generator 검증으로 강제하는 별개 레이어).

`ca.json` 의 **정적 부분만**(`allow.cn` 은 빈 목록 또는 생략, + `deny` + claims) `inject.config` 로
렌더되는 ConfigMap(= 템플릿; 차트가 메인 컨테이너의 `/home/step/config` 에 RO 마운트)에 담고,
**디바이스별 CN 목록**은 Mapping Generator CronJob 이 만드는 별도 ConfigMap `step-ca-whitelist`
로 분리한다. step-ca workload 의 **initContainer(`extraInitContainers`)가 부팅 시 템플릿 config
디렉토리 전체를 emptyDir(`ca-merged`)로 복사한 뒤 jq 로 whitelist CN 들을 `ca-merged/ca.json` 의
`allow.cn` 에 채워넣고**(set/overwrite — 빈 allowlist 동작 확인 후 차트에서 set vs append 확정),
그리고
`extraVolumeMounts` 로 그 emptyDir 를 메인 컨테이너의 `/home/step/config` 에 **덮어 마운트**(나중
마운트 우선 → 메인 컨테이너의 `command`/`args` override 불필요). `step-ca-whitelist` 변경 시
step-ca 의 Reloader 가 rollout 트리거 → initContainer 재실행 → 재머지 (step-ca 는 `ca.json`
policy hot-reload 불가).

```yaml
# 템플릿 ConfigMap (inject.config 로 렌더) 안의 X5C provisioner — 정적 부분만 (CN 목록은 비움)
- type: "X5C"
  name: "device-bootstrap"
  roots: "<base64>"
  policy:
    x509:
      allow:
        cn: []   # 빈 목록 — initContainer 가 step-ca-whitelist 의 CN 들로 채움.
                 # 정규식 안 넣음: 정규식만 두면 6-hex CN 아무거나 통과 → whitelist 무의미.
                 # ^device-[a-f0-9]{6}$ 는 펌웨어 + mapping-generator 검증으로 강제하는 명명 규약일 뿐.
      deny:
        cn: ["*"]   # allow 가 명시 목록이라 사실상 잉여 — 명시성 위해 유지.
  claims: { ... }
```

```yaml
# step-ca workload values — 전부 step-certificates 1.30.x native 훅 (default [])
extraVolumes:
  - { name: ca-merged,    emptyDir: {} }
  - { name: ca-whitelist, configMap: { name: step-ca-whitelist, optional: true } }   # whitelist 아직 없어도 부팅 OK
extraInitContainers:
  - name: merge-ca-config
    image: <jq 가 든 경량 이미지>
    command: ["sh", "-c"]
    args:
      - |
        cp -a /template/. /merged/        # defaults.json·인증서 등 config 디렉토리 전체 복사 (overmount 대상이므로)
        wl="$( [ -f /whitelist/step-ca-whitelist.json ] && jq -c '.cn // .' /whitelist/step-ca-whitelist.json || echo '[]' )"
        jq --argjson wl "$wl" '
          (.authority.provisioners[] | select(.type=="X5C") | .policy.x509.allow.cn) = $wl   # += (append) 인지 = (overwrite) 인지는
        ' /merged/ca.json > /merged/ca.json.tmp && mv /merged/ca.json.tmp /merged/ca.json     #   step-ca 의 빈 allowlist 동작 확인 후 차트에서 확정
    volumeMounts:
      - { name: <config-cm-volume>, mountPath: /template,  readOnly: true }   # 차트가 마운트하는 config ConfigMap (이름은 차트 산출물 확인)
      - { name: ca-whitelist,       mountPath: /whitelist, readOnly: true }
      - { name: ca-merged,          mountPath: /merged }
extraVolumeMounts:
  - { name: ca-merged, mountPath: /home/step/config }   # 메인 컨테이너에 덮어 마운트 → command/args override 불필요
# 메인 컨테이너: command/args 그대로 (.../step-ca ... /home/step/config/ca.json), PVC 는 /home/step/db, bootstrap.enabled: false
```

✅ **확인 완료** (step-certificates 1.30.x): `extraInitContainers` / `extraVolumes` /
`extraVolumeMounts` / `extraContainers` / `command` / `args`(전부 default `[]`) 노출 → 위 머지
initContainer 는 순수 values 로 가능. 메인 컨테이너는 `command: ["/usr/local/bin/step-ca"]`,
`args` 끝이 `/home/step/config/ca.json`; config ConfigMap 을 RO 로 `/home/step/config` 에, PVC 를
`/home/step/db` 에 마운트. 배선 요약: `inject.config` = 정적 템플릿 `ca.json` → `extraVolumes` 에
`ca-merged` emptyDir + `step-ca-whitelist` configMap → `extraInitContainers` 의 `merge-ca-config`
가 `cp -a /template/. /merged/` + jq append → `extraVolumeMounts` 로 `ca-merged` 를
`/home/step/config` 에 덮어 마운트(나중 마운트 우선 → `command`/`args` override 불필요) →
`bootstrap.enabled: false`. **남은 비용은 딱 하나**: 차트가 StatefulSet metadata annotation 훅이
없어 `step-ca-whitelist` 용 Reloader annotation 은 엄브렐라 차트의 post-render(kustomize)
strategic-merge patch 로 확정 (`kustomization.yaml` + patch, step-ca StatefulSet `metadata` 에
`configmap.reloader.stakater.com/reload: step-ca-whitelist` 주입). 대안 B(mapping-generator 가
`kubectl rollout restart statefulset/step-ca`)는 기각 — 메커니즘 비대칭(EMQX 는 Reloader)·
mapping-generator RBAC 확대(`statefulsets patch`)·whitelist 변경감지 로직 필요(없으면 15 분마다
무의미 restart)·`smoke-test-step-ca.sh #4b` 의 annotation hard-check 위반. 자동화 가치는 동일:
`step-ca-whitelist` 만 mapping-generator 가 갱신하면 `emqx-acl` / `telegraf-lookup` 과 단일
진실 공급원에서 동기화됨.

### 호스트 디렉토리 준비 — local PV (사람 1회, 환경마다)

step-ca 의 badger DB 는 influxdb 와 동일하게 노드 고정 local PV 에 영속화 (엄브렐라 차트의 `templates/pv.yaml` 가 `hostPath` 기반 local PV 를 선언, 업스트림 step-certificates 차트의 PVC 가 여기 바인딩). PV 가 붙을 호스트 디렉토리를 컨테이너 user (uid/gid 1000) 에 맞춰 미리 생성.

```bash
# prod: e-s1 에서
sudo mkdir -p /mnt/ssd/step-ca
sudo chown 1000:1000 /mnt/ssd/step-ca
sudo chmod 700 /mnt/ssd/step-ca

# dev: alpha-w1 에서 (security 카테고리 노드)
sudo mkdir -p /var/lib/step-ca
sudo chown 1000:1000 /var/lib/step-ca
sudo chmod 700 /var/lib/step-ca
```

소유자/권한 불일치 시 badger DB open 실패로 crashloop. reclaimPolicy: Retain 이라 helm
uninstall/재배포 후에도 디렉토리·DB 유지 → 발급 이력/시리얼 충돌 방지. influxdb (uid 1500)
와 같은 노드 (prod e-s1 / dev alpha-w1 — storage·security 카테고리가 같은 노드) 에 올릴 때 uid 가 달라 각자 별도 디렉토리를 써야 함.

### 오프라인 CA + provisioner 키 생성, Secret 등록 (사람 1회, 환경마다)

step-ca 는 자체 init container 로 Root + Intermediate 를 만들 수 있으나 **Root 키는 절대 클러스터
안에 두지 않음**. 아래는 운영자 노트북 또는 에어갭 환경에서 1 회 실행. step CLI 필요 (`step-ca`
서버와 별개 패키지인 `smallstep/cli` — 서버는 클러스터 컨테이너, 이 CLI 는 사람 머신에만).

```bash
# ── 1) Root / Intermediate / Bootstrap CA (오프라인) ──────────────────────────
step certificate create --profile root-ca \
    "GikView Root CA" root_ca.crt root_ca_key \
    --kty EC --curve P-256 --not-after 87600h          # 10y, 키는 암호화 PKCS#8 (패스워드 prompt)

step certificate create --profile intermediate-ca \
    "GikView Intermediate CA" intermediate_ca.crt intermediate_ca_key \
    --ca root_ca.crt --ca-key root_ca_key --kty EC --curve P-256 --not-after 43800h   # 5y

step certificate create --profile intermediate-ca \
    "GikView Bootstrap CA" bootstrap_ca.crt bootstrap_ca_key \
    --ca root_ca.crt --ca-key root_ca_key --kty EC --curve P-256 --not-after 43800h   # 5y, 정식 trust 와 분리

# 디바이스 부트스트랩 인증서 (CN=bootstrap, 7d, 모든 디바이스 공통) — Bootstrap CA 로 서명
step certificate create --not-after 168h "bootstrap" bootstrap.crt bootstrap.key \
    --ca bootstrap_ca.crt --ca-key bootstrap_ca_key --kty EC --curve P-256

# ── 2) admin JWK provisioner 키쌍 (K8s 워크로드/운영자 발급용) ─────────────────
JWK_PW="<admin JWK provisioner password>"   # = step-issuer-provisioner-password Secret 값
step crypto jwk create admin_jwk.pub.json admin_jwk.priv.json \
    --password-file <(printf '%s' "$JWK_PW")
# admin_jwk.pub.json  → ca.json provisioners[admin].key          (helm values 인라인)
# admin_jwk.priv.json → ca.json provisioners[admin].encryptedKey (helm values 인라인)
# X5C provisioner roots: device-bootstrap ← base64 -w0 bootstrap_ca.crt
#                        device-renewal   ← base64 -w0 intermediate_ca.crt

# ── 3) K8s Secret 등록 ───────────────────────────────────────────────────────
kubectl create namespace gikview --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic step-certificates-certs -n gikview \
    --from-file=root_ca.crt=root_ca.crt --from-file=intermediate_ca.crt=intermediate_ca.crt
kubectl create secret generic step-certificates-ca-key -n gikview \
    --from-file=intermediate_ca_key=intermediate_ca_key
kubectl create secret generic step-certificates-ca-password -n gikview \
    --from-literal=password="<intermediate-key-password>"
kubectl create secret generic step-issuer-provisioner-password -n gikview \
    --from-literal=password="${JWK_PW}"

# ── 4) 정리 ─────────────────────────────────────────────────────────────────
# 클러스터로 들어감: root_ca.crt, intermediate_ca.crt, intermediate_ca_key, 패스워드들.
# 클러스터로 안 들어감: root_ca_key, bootstrap_ca_key (오프라인 보관).
shred -u root_ca_key intermediate_ca_key bootstrap_ca_key admin_jwk.priv.json
# *.crt 는 공개 자료 — root_ca.crt 는 step-issuer caBundle / 디바이스 trust 에 재사용하니 보관
```

step-ca 의 `device-bootstrap` provisioner 가 `bootstrap_ca.crt` 를 X5C root 로 등록 → 디바이스가
부트스트랩 인증서로 서명한 JWT 를 보내면 step-ca 가 검증 후 정식 인증서 발급.

> `step-issuer-provisioner-password` Secret 의 1차 소유 문서는 `step-issuer.md` 지만, 값이 step-ca 의
> `admin` provisioner 비번과 동일해야 하므로 생성 시점이 여기와 묶임 — 양쪽 문서에서 상호 참조.

## 알려진 주의사항

- **CVE-2026-30836 (CVSS 10) — `0.30.0` 미만 금지**: SCEP UpdateReq(MessageType=18) 통한 미인증 인증서 발급. `0.30.0` 에서 수정. 본 프로젝트는 SCEP provisioner 미사용이라 직접 익스플로잇은 어렵지만 CA 를 취약 코드 위에서 돌리지 않기 위해 `0.30.x` 사용. 관련: GHSA-h8cp-697h-8c8p(ACME/SCEP authz bypass), CVE-2025-66406(SSH cert 임의 폐기 — SSH cert 미사용).

- **DB 영속화 필수**: badger 또는 boltdb 같은 임베디드 DB 사용 시 Pod 재시작 후에도 발급 이력/revocation 데이터가 유지되어야 함. PVC 미사용 시 helm 재배포로 이력 손실 → 같은 디바이스가 재발급 시 시리얼 충돌 가능. 단일 노드 step-ca 는 local PV 권장.

- **Intermediate 키 노출 = Intermediate 침해**: K8s Secret 으로 저장된 intermediate key 가 노출되면 해당 step-ca 정지 + Root CA 로 새 Intermediate 발급 + 기존 폐기. Root CA 가 오프라인이라 침해되지 않는 것이 PKI 계층화의 본질.

- **X5C root 검증 실패 시 `provisioner not found`**: X5C provisioner 의 `roots` 가 base64 인코딩된 PEM 이어야 함. 줄바꿈 그대로 인코딩 시 yaml 파싱 오류. `cat ca.crt | base64 -w 0` 로 single-line 변환.

- **Policy 변경 시 rollout restart 필수**: ca.json 의 policy 또는 provisioner 변경은 hot reload 안 됨. `step-ca-whitelist` ConfigMap 갱신 → Reloader 가 deployment rollout 트리거 → initContainer 가 템플릿+whitelist 재머지 (결정 c, 위 Policy 절). rollout 중 약 5~10 초 발급 거부 윈도우 발생.

- **`disableRenewal: true` 인 provisioner 로 발급된 인증서**: `/1.0/renew` 호출 시 403. 부트스트랩 인증서는 갱신 불가가 의도된 동작. 디바이스는 정식 인증서 받은 후 `device-renewal` provisioner 로 갱신해야 함.

- **`allowRenewalAfterExpiry: true` 는 보안 위험**: 만료된 인증서로 갱신 시도가 통과되면 탈취 후 장기간 방치된 인증서가 부활. 본 프로젝트는 false 유지. 만료 시 부트스트랩 → 재발급 흐름.

- **ECDSA Intermediate + SCEP 비호환**: SCEP provisioner 는 RSA Intermediate 필수. 본 프로젝트는 SCEP 미사용 (X5C 사용) 이라 ECDSA 유지 가능.

- **CRL/OCSP responder 비활성**: 본 단계에서는 ADR (security.md 결정 7번) 에 따라 비활성. 폐기 메커니즘 미적용 결정의 ADR 참조.

- **BearSSL 클라이언트 IP SAN 미지원**: ESP8266 BearSSL 클라이언트는 서버 인증서의 IP SAN 매칭을 안 함 (DNS SAN 만 지원). 본 phase 는 step-ca 를 NodePort 로 외부 노출(security.md 결정 11)하므로 step-ca 서버 인증서 SAN 에 노드 IP 를 포함하되, ESP8266 측은 그 IP SAN 을 검증하지 않음 — 검증 환경은 `WiFiClientSecure.setInsecure()` 로 우회, 운영 환경 trust 전략(step-ca DNS 명을 디바이스에 push 후 그것만 사용 등)은 별도 ADR.

- **NodePort 외부 노출 시 attack surface**: NodePort 로 `:9000` 이 학내망에 노출됨. 익명 접근은 X5C provisioner 가 차단(유효한 부트스트랩/정식 인증서로 서명한 JWT 필수)하지만, 미인증 요청도 step-ca Pod 까지는 도달함(서명 검증 단계에서 거부). 노드 방화벽 / 공유기 포트포워딩 범위(학내 서브넷 한정 등)로 도달 범위를 추가 제한 권장. step-ca rollout 윈도우(정책 변경 시 5~10초) 동안에는 외부 요청도 거부됨.

- **호스트 디렉토리 권한**: local PV 사용 시 호스트 측 디렉토리 (`spec.local.path`) 소유자가 컨테이너 user (uid/gid 1000) 와 일치해야 함. 불일치 시 badger DB open 권한 거부로 crashloop. 호스트에서 `chown 1000:1000` 사전 실행 (위 "호스트 디렉토리 준비" 절). 같은 노드(prod e-s1 / dev alpha-w1)에 influxdb(uid 1500) 와 공존 시 uid 가 달라 디렉토리를 분리해야 함.

## 환경별 분리 필요 항목

| 항목 | dev (alpha cluster) | prod (edge) |
|------|-----|------|
| `inject.config.dnsNames` | `["step-ca", "step-ca.gikview.svc.alpha.nexus.local", "127.0.0.1", "<dev 노드 IP>"]` | `["step-ca", "step-ca.gikview.svc.cluster.local", "127.0.0.1", "192.168.0.101"]` (e-s1 IP — 노출 IP 가정) |
| `nodeSelector` (`security` 카테고리) | `kubernetes.io/hostname: alpha-w1` | `kubernetes.io/hostname: e-s1` |
| NodePort 서비스 (`step-ca-nodeport`) | `type: NodePort`, `nodePort: <dev 고정 포트>`, `externalTrafficPolicy: Local` | `type: NodePort`, `nodePort: 31900` (예), `externalTrafficPolicy: Local` |
| 공유기 포트포워딩 (운영자 1회) | `<dev 외부포트> → alpha-w1:<nodePort>` | `<외부포트> → e-s1:31900` |
| `local PV spec.local.path (호스트 디렉토리)` | `/var/lib/step-ca` (alpha-w1) | `/mnt/ssd/step-ca` (e-s1) |
| `persistence.size` | `1Gi` | `2Gi` |
| `resources.requests.memory` | `64Mi` | `64Mi` |
| `resources.limits.memory` | `256Mi` | `256Mi` |