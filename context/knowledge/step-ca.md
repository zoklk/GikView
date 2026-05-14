# step-ca — 운영 지식 메모

---

## 이미지 / 버전

**채택**: `ghcr.io/zoklk/step-ca:edge` — 자체 빌드 (베이스 `cr.smallstep.com/smallstep/step-ca:0.30.2`, Alpine + sh/busybox/jq; `cap_net_bind_service` file-capability xattr 제거 — 빌드 근거·대안은 결정 16번). `merge-ca-config` initContainer 도 같은 이미지 (내장 jq → 추가 이미지 풀 불필요). 자체 GHCR 가 private 라 step-ca Pod(서브차트 `serviceAccount.create: false` → `default` SA) 는 `ghcr-pull` Secret(mapping-generator 환경별 사전작업이 만듦)을 `step-certificates.image.imagePullSecrets` 로 참조. 빌드 상세는 `edge/docker/step-ca/Dockerfile` 주석. (버전 추적은 베이스 기준 `0.30.2` — 아래 버전 정책 그대로 적용.)

step-ca 는 Smallstep 의 오픈소스 PKI 서버. ESP8266 디바이스 발급 (부트스트랩 → 정식 인증서 갱신) 과 K8s 워크로드 인증서 (EMQX, Edge Gateway, Telegraf) 발급을 단일 Intermediate CA 로 통합 운영. 본 프로젝트는 9 대 규모이고 디바이스별 인증서를 컴파일 시점에 주입(디바이스마다 다른 NVS 이미지)하기 어려운 ESP8266 다수를 다루므로 자동 발급/갱신 메커니즘이 필수 (부트스트랩 패턴은 공통 인증서만 컴파일 시점에 굽고 정식 인증서는 첫 부팅 시 발급).

선택 근거: HashiCorp Vault PKI 대비 학습 곡선 작음, AWS Private CA 대비 외부 의존 없음, OpenSSL 자체 CA 대비 서버 API + 자동화 가능. **버전: `0.30.x` 고정** — (1) `0.30.0` 미만 전부가 CVE-2026-30836(CVSS 10, SCEP UpdateReq 통한 미인증 인증서 발급, `0.30.0` 에서 수정)에 영향, (2) helm chart `step-certificates 1.30.1` 의 `appVersion` 이 `0.30.2` 라 chart-native 버전과 일치. 0.31 출시 시 release notes 확인 후 승격.

Helm chart: `smallstep/step-certificates` `1.30.1` (repo: `https://smallstep.github.io/helm-charts/`, appVersion `0.30.2`)

> **RFC 7030 EST 미지원 명시**: step-ca 오픈소스는 EST 프로토콜을 직접 지원하지 않음 (이슈 #2366, 2026-05 기준 미구현). SCEP/ACME/X5C/JWK/OIDC/K8SSA provisioner 만 제공. 본 프로젝트는 X5C provisioner 로 EST-like("기존 인증서로 새 인증서 발급") 흐름을 구현하되 ESP8266 은 표준 EST 클라이언트가 아닌 step-ca REST API (`/1.0/sign`, `/1.0/renew`) 를 호출. architecture 문서의 "EST" 용어는 "X5C 기반 EST-like 흐름" 으로 해석. **SCEP provisioner 미사용** — CVE-2026-30836 의 직접 익스플로잇 경로(SCEP)에는 해당 없으나 코드 노출 회피 차원에서 `0.30.0+` 사용.
>
> 펌웨어 측 PKI 라이브러리 조합(BearSSL + uECC + 자체 ASN.1 CSR 인코딩)의 근거·대안은 결정 17번. 펌웨어 흐름 상세는 phase doc 의 "후속 작업".

## 주요 설정

step-ca 는 `ca.json` 으로 거의 모든 동작을 제어. 업스트림 `step-certificates` 차트는
config + CA 자료를 공급하는 모드가 **`inject` / `existingSecrets` / `bootstrap` 중 택일**이다
(`configmaps.yaml` 이 `existingSecrets.enabled` 와 `inject.enabled`(또는 `bootstrap.enabled`)
동시 사용 시 `required` 로 hard-error). 본 프로젝트는 Root 를 오프라인 생성하므로:

- **CA 인증서/키/패스워드 → `existingSecrets`** (운영자가 `kubectl create secret` 으로 사전 생성 —
  prod 가 private 키·패스워드를 git 에 못 올리므로). `existingSecrets` 모드에선 차트가 `ca.json`
  ConfigMap 을 안 만들어 주므로,
- **`ca.json` (정적 부분) → 엄브렐라 차트 `step-ca` 가 직접 렌더** (`templates/configmap-config.yaml`
  이 git-추적되는 values 에서 ca.json 을 조립해 `step-ca-config` ConfigMap 으로 출력). 서브차트는
  그 이름으로 `/home/step/config` 에 마운트. → ca.json 은 선언적·git-tracked 로 유지.
- `inject.enabled: false`, `bootstrap.{enabled,configmaps,secrets}: false`.

> `nameOverride: step-ca` 필수 — 하네스 `conventions.label_selector` 가 `app.kubernetes.io/name={service}`
> = `…=step-ca` 라서. 이걸 주면 서브차트 산출물의 `app.kubernetes.io/name` 라벨, StatefulSet/Service/Pod
> 이름, PVC(`database-step-ca-0`), 그리고 차트가 마운트하는 secret/configmap 이름이 전부 `step-ca-*` 로
> 정렬됨. (그래서 사전 생성 Secret 이름이 `step-ca-certs` / `step-ca-secrets` / `step-ca-ca-password`.)

```yaml
# edge/helm/step-ca/values.yaml — 엄브렐라. "step-certificates:" 블록은 업스트림 서브차트로 전달.
# ⚠ 이 블록은 요지 발췌다 — initContainer args / caJson.x5cLeafTemplate 등의 *정확한* 내용은
#   edge/helm/step-ca/values.yaml 이 정본. 둘이 어긋나면 values.yaml 을 믿을 것.
step-certificates:
  nameOverride: step-ca           # 위 주석 참조
  kind: StatefulSet
  replicaCount: 1
  image:
    repository: "ghcr.io/zoklk/step-ca"   # 자체 빌드 (de-capped — § 이미지/버전 참조), 차트 기본 smallstep/step-ca 대신
    tag: "edge"                   # 베이스 0.30.2 추적 (chart 1.30.1 appVersion 과 동일 베이스)

  service:                        # 서브차트 자체 Service 가 곧 step-ca:9000 (StepClusterIssuer URL 과 일치)
    type: ClusterIP               # 디바이스용 외부 노출은 엄브렐라 templates/service-nodeport.yaml 별도
    port: 9000
    targetPort: 9000

  # 모드 선택 — existingSecrets 만 켠다
  inject:
    enabled: false
  bootstrap:
    enabled: false
    configmaps: false             # 빈 *-config / *-certs / *-bootstrap ConfigMap 생성 억제
    secrets: false
  existingSecrets:
    enabled: true
    ca: true                      # step-ca-ca-password Secret(key: password) 마운트 + --password-file 추가
    certsAsSecret: true           # step-ca-certs Secret(root_ca.crt, intermediate_ca.crt) 마운트
    configAsSecret: false         # step-ca-config 는 ConfigMap (엄브렐라가 렌더)
    issuer: false                 # certificate-issuer 미사용 (X5C 는 roots 인라인)
    sshHostCa: false
    sshUserCa: false
    sshTemplates: false

  ca:
    db:
      enabled: true
      persistent: true
      storageClass: "local-storage"
      size: "1Gi"                 # prod 는 values-prod.yaml 에서 2Gi (엄브렐라 pv.yaml 의 capacity 와 일치해야)
      accessModes: ["ReadWriteOnce"]
    ssh:
      enabled: false
    # ⚠️  ca.password 는 안 쓴다 — existingSecrets.ca: true 가 step-ca-ca-password Secret 을 마운트하고
    #    --password-file 을 붙인다. (구 문서의 ca.password.secretKeyRef 는 실제 차트 value 가 아님 —
    #     ca.password 는 평범한 string 필드.)

  podSecurityContext:
    runAsUser: 1000
    runAsGroup: 1000
    runAsNonRoot: true
    fsGroup: 1000                 # badger DB PVC group
    seccompProfile:
      type: RuntimeDefault

  # ca.containerSecurityContext 는 차트 기본(readOnlyRootFilesystem: true)을 유지 — step-ca 의 쓰기는
  # PVC(/home/step/db) 와 머지-config emptyDir(/home/step/config)로 가므로 안전. root-FS 쓰기로
  # crashloop 나면 그때 false 로.

  resources:
    requests: { cpu: 20m, memory: 64Mi }
    limits:   { cpu: 200m, memory: 256Mi }

  # ── ca.json 머지 (device CN 화이트리스트 → templateData.allowedCNs + admin JWK encryptedKey) — 전부 step-certificates 1.30.x native 훅 ──
  extraVolumes:
    - { name: ca-merged,     emptyDir: {} }
    - { name: ca-whitelist,  configMap: { name: step-ca-whitelist,  optional: true } }   # 아직 없어도 부팅 OK
    - { name: ca-admin-jwk,  secret:    { secretName: step-ca-admin-jwk, optional: true } }   # prod 필수; dev 은 values 인라인이면 생략 (optional 이라 없어도 부팅)
  extraInitContainers:
    - name: merge-ca-config
      # main 컨테이너와 같은 이미지 — 자체 빌드 ghcr.io/zoklk/step-ca:edge (Alpine 기반, sh + busybox coreutils + jq 내장).
      # mikefarah/yq:4 대신 이걸 쓰면 추가 이미지 풀 불필요 + jq 가 step-ca 의 ca.json(JSON)을 그대로 다룰 수 있다.
      image: ghcr.io/zoklk/step-ca:edge
      imagePullPolicy: Always
      command: ["/bin/sh", "-c"]
      args:
        - |
          set -e
          cp /template/ca.json /merged/ca.json
          # step-ca-whitelist 가 있으면 각 X5C provisioner 의 cert-template templateData.allowedCNs 를 화이트리스트로 덮어씀.
          #   (OSS step-ca 는 provisioner-단위 policy 미지원 → options.x509.template 의 {{ fail }} 가드로 동등 효과;
          #    가드 로직(template 문자열)은 정적, 화이트리스트(데이터)만 여기서 주입.)
          if [ -s /whitelist/whitelist.json ]; then
            jq --slurpfile wl /whitelist/whitelist.json \
              '(.authority.provisioners[] | select(.type == "X5C") | .options.x509.templateData.allowedCNs) = ($wl[0] // [])' \
              /merged/ca.json > /merged/ca.json.new && mv /merged/ca.json.new /merged/ca.json
          fi
          # admin(JWK) provisioner 의 암호화 private key 를 Secret 에서 주입 (없으면 values 인라인 값 그대로)
          if [ -s /admin-jwk/encrypted-key ]; then
            jq --arg ek "$(cat /admin-jwk/encrypted-key)" \
              '(.authority.provisioners[] | select(.name == "admin") | .encryptedKey) = $ek' \
              /merged/ca.json > /merged/ca.json.new
            mv /merged/ca.json.new /merged/ca.json
          fi
      resources:
        requests: { cpu: 10m, memory: 32Mi }
        limits:   { cpu: 100m, memory: 64Mi }
      securityContext:
        runAsUser: 1000
        runAsNonRoot: true
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
        seccompProfile: { type: RuntimeDefault }
      volumeMounts:
        - { name: config,       mountPath: /template,  readOnly: true }   # 서브차트가 마운트하는 step-ca-config ConfigMap 볼륨
        - { name: ca-whitelist, mountPath: /whitelist, readOnly: true }   # step-ca-whitelist ConfigMap (key: whitelist.json)
        - { name: ca-admin-jwk, mountPath: /admin-jwk, readOnly: true }   # step-ca-admin-jwk Secret (key: encrypted-key)
        - { name: ca-merged,    mountPath: /merged }
  extraVolumeMounts:
    - { name: ca-merged, mountPath: /home/step/config }   # 메인 컨테이너에 덮어 마운트(나중 마운트 우선) → command/args override 불필요

  # nodeSelector / dnsNames(노드별)·persistence(hostPath) 등 환경별 값은 values-<env>.yaml 및 아래
  # "환경별 분리 필요 항목" 표 참조.
```

**누가 무엇을 만드나:**

| 리소스 | 누가 | 내용 |
|---|---|---|
| `step-ca-config` ConfigMap | 엄브렐라 차트 (`templates/configmap-config.yaml`) | `ca.json` (정적 — X5C `options.x509.template` `{{ fail }}` 가드 + `templateData.allowedCNs: []`; provisioner roots / admin JWK pub key(`caJson.adminJwk.key`) / dnsNames 는 values-<env>.yaml 에서 주입. `caJson.adminJwk.encryptedKey` 는 빈 `""` — merge initContainer 가 `step-ca-admin-jwk` 에서 채움) |
| `step-ca-certs` Secret | **운영자 사전 생성** | `root_ca.crt`, `intermediate_ca.crt` (→ `/home/step/certs`) |
| `step-ca-secrets` Secret | **운영자 사전 생성** | `intermediate_ca_key` (→ `/home/step/secrets`; ca.json `key: /home/step/secrets/intermediate_ca_key`) |
| `step-ca-ca-password` Secret | **운영자 사전 생성** | `password` (→ `/home/step/secrets/passwords/password`, `--password-file`) |
| `step-ca-admin-jwk` Secret | **운영자 사전 생성** (optional — dev 은 values 인라인 대안) | `encrypted-key` (= `admin_jwk.priv.json`; merge initContainer → `ca.json` `provisioners[admin].encryptedKey`. prod 필수 — `values-prod.yaml` 의 `caJson.adminJwk.encryptedKey: ""`) |
| `step-ca-whitelist` ConfigMap | mapping-generator (sync-wave -1) | `whitelist.json` = 허용 device CN JSON 배열 |
| StatefulSet / Service(`step-ca:9000`) / PVC(`database-step-ca-0`) | step-certificates 서브차트 | |
| `step-ca-nodeport` Service / 호스트 local PV / Reloader annotation(post-render) | 엄브렐라 차트 | |

`ca.json` 정적 부분 예시 (엄브렐라가 values 에서 조립):

```json
{
  "root": "/home/step/certs/root_ca.crt",
  "crt": "/home/step/certs/intermediate_ca.crt",
  "key": "/home/step/secrets/intermediate_ca_key",
  "address": ":9000",
  "dnsNames": ["step-ca", "step-ca.gikview.svc.cluster.local", "127.0.0.1"],
  "logger": { "format": "json" },
  "db": { "type": "badgerv2", "dataSource": "/home/step/db" },
  "authority": {
    "claims": {
      "minTLSCertDuration": "5m",
      "maxTLSCertDuration": "8760h",
      "defaultTLSCertDuration": "2160h",
      "disableRenewal": false
    },
    "provisioners": [
      { "type": "X5C", "name": "device-bootstrap",
        "roots": "<base64 -w0 of bootstrap_ca.crt>",
        "claims": { "defaultTLSCertDuration": "2160h", "disableRenewal": true },
        "options": { "x509": {
          "templateData": { "allowedCNs": [] },
          "template": "{{- $wl := .allowedCNs -}}{{- if .Subject.CommonName }}{{- if not (has .Subject.CommonName $wl) }}{{ fail (printf \"common name %q is not allowed (not in device whitelist)\" .Subject.CommonName) }}{{- end }}{{- end -}}{{- range .SANs }}{{- if ne .Type \"dns\" }}{{ fail (printf \"SAN type %q is not allowed (devices get DNS SANs only)\" .Type) }}{{- end }}{{- if not (has .Value $wl) }}{{ fail (printf \"SAN %q is not allowed (not in device whitelist)\" .Value) }}{{- end }}{{- end -}}{ \"subject\": {{ toJson .Subject }}, \"sans\": {{ toJson .SANs }}, \"keyUsage\": [\"digitalSignature\"], \"extKeyUsage\": [\"serverAuth\",\"clientAuth\"] }"
        } } },
      { "type": "X5C", "name": "device-renewal",
        "roots": "<base64 -w0 of intermediate_ca.crt>",
        "claims": { "defaultTLSCertDuration": "2160h", "allowRenewalAfterExpiry": false },
        "options": { "x509": { "templateData": { "allowedCNs": [] }, "template": "<device-bootstrap 와 동일 — {{ fail }} 가드 + DefaultLeafTemplate 필드>" } } },
      { "type": "JWK", "name": "admin",
        "key": { "<admin_jwk.pub.json 내용 — caJson.adminJwk.key>": "..." },
        "encryptedKey": "" }
    ]
  }
}
```
(부팅 시 merge initContainer 가 `allowedCNs: []` → `step-ca-whitelist`, `admin.encryptedKey: ""` → `step-ca-admin-jwk` 로 overwrite — 위 `## 주요 설정` 의 initContainer 참조. `template` 문자열(`{{ fail }}` 가드)은 정적; `device-bootstrap.roots`/`device-renewal.roots`/`admin.key`/`dnsNames` 는 환경별 → `values-<env>.yaml`. `admin`(JWK)엔 template 이 없어 화이트리스트 영향 없음. 가독성 위해 `template` 을 base64 / `options.x509.templateFile` 로 빼도 되고, `tls` ciphersuite 블록은 옵션.)

### Service 노출 — ClusterIP + NodePort

업스트림 차트 `service` 는 `type: ClusterIP`, `port: 9000`(차트 기본 443 을 override), `targetPort: 9000` 으로 둔다 → 서브차트 자체 Service 가 곧 `step-ca:9000`(StepClusterIssuer URL 과 일치, step-issuer/cert-manager 내부 발급용). 디바이스용 외부 노출은 엄브렐라 차트의 자체 `templates/service-nodeport.yaml`(EMQX `service-nodeport.yaml` 패턴)로 별도 NodePort Service `step-ca-nodeport` 추가 — `type: NodePort`, `port: 9000`, 고정 `nodePort: 31900`, `externalTrafficPolicy: Local`(디바이스 실제 IP 보존). 도달지점이 `security` 카테고리 노드(prod e-s1 / dev alpha-w1) 하나뿐이라 ingress 추상화는 이득 없음 (EMQX NodePort 와 동일 토폴로지 — 결정 11번).

step-ca 가 부팅 시 Intermediate 로 자체 발급하는 서버 인증서는 `ca.json` 의 `dnsNames`(엄브렐라가 `values-<env>.yaml` 에서 주입)에 든 이름만 SAN 으로 갖는다. 클러스터 내부 발급에는 `step-ca` + `step-ca.gikview.svc.<suffix>`(+`127.0.0.1`)면 충분. 디바이스-facing 노출은 NodePort 경유 노드 IP 인데 ESP8266 BearSSL 이 IP SAN 을 검증하지 않으므로(아래 주의사항) **노드 IP 를 `dnsNames` 에 넣어도 디바이스 검증엔 도움 안 됨** → dev/prod 모두 DNS-only(노드 IP 미포함). 디바이스 측 trust 전략(검증 환경 `setInsecure()`, 운영 환경은 펌웨어에 하드코딩한 DNS 명을 노드 IP 로 매핑 + 그 명을 `dnsNames` 에 추가)은 별도 ADR. 공유기 포트포워딩 `<외부포트> → <노드>:31900` 는 운영자 1 회 작업.

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
# admin_jwk.pub.json  → caJson.adminJwk.key (helm values 인라인 — public JWK, kid 포함)
# admin_jwk.priv.json → step-ca-admin-jwk Secret(key: encrypted-key); merge initContainer 가 부팅 시
#                       ca.json provisioners[admin].encryptedKey 에 주입.
#                       (prod 필수 — values-prod.yaml 의 caJson.adminJwk.encryptedKey: ""; dev 은 values-dev.yaml
#                        에 인라인으로 둬도 OK — 그 경우 이 Secret 생략 가능)
# X5C provisioner roots: device-bootstrap ← base64 -w0 bootstrap_ca.crt
#                        device-renewal   ← base64 -w0 intermediate_ca.crt

# ── 3) K8s Secret 등록 ───────────────────────────────────────────────────────
# Secret 이름은 step-certificates 차트가 {fullname}-* 로 하드 참조하며, nameOverride: step-ca 라
# {fullname} = step-ca. (rename 만 하면 됨 — 인증서/키 재발급 불필요.)
kubectl create namespace gikview --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic step-ca-certs -n gikview \
    --from-file=root_ca.crt=root_ca.crt --from-file=intermediate_ca.crt=intermediate_ca.crt
kubectl create secret generic step-ca-secrets -n gikview \
    --from-file=intermediate_ca_key=intermediate_ca_key
kubectl create secret generic step-ca-ca-password -n gikview \
    --from-literal=password="<intermediate-key-password>"
kubectl create secret generic step-issuer-provisioner-password -n gikview \
    --from-literal=password="${JWK_PW}"
# step-ca-admin-jwk: admin JWK provisioner 의 암호화 private key. prod 필수(values-prod.yaml 의 caJson.adminJwk.encryptedKey: "");
#                    dev 은 values-dev.yaml 인라인 대안이면 생략. merge initContainer 가 부팅 시 ca.json 에 주입.
kubectl create secret generic step-ca-admin-jwk -n gikview \
    --from-file=encrypted-key=admin_jwk.priv.json
# 참고: step-ca-config(ca.json)은 운영자가 안 만든다 — 엄브렐라 차트가 렌더.

# ── 4) 정리 ─────────────────────────────────────────────────────────────────
# 클러스터로 들어감: root_ca.crt, intermediate_ca.crt, intermediate_ca_key, admin_jwk.priv.json(→ step-ca-admin-jwk), 패스워드들.
# 클러스터로 안 들어감: root_ca_key, bootstrap_ca_key (오프라인 보관).
shred -u root_ca_key intermediate_ca_key bootstrap_ca_key admin_jwk.priv.json   # admin_jwk.priv.json 은 위 step-ca-admin-jwk Secret 만든 뒤에
# *.crt 는 공개 자료 — root_ca.crt 는 step-issuer caBundle / 디바이스 trust 에 재사용하니 보관
```

step-ca 의 `device-bootstrap` provisioner 가 `bootstrap_ca.crt` 를 X5C root 로 등록 → 디바이스가
부트스트랩 인증서로 서명한 JWT 를 보내면 step-ca 가 검증 후 정식 인증서 발급.

> `step-issuer-provisioner-password` Secret 의 1차 소유 문서는 `step-issuer.md` 지만, 값이 step-ca 의
> `admin` provisioner 비번과 동일해야 하므로 생성 시점이 여기와 묶임 — 양쪽 문서에서 상호 참조.

### Bootstrap CA 회전 / 부트스트랩 경로 폐쇄 (사람, 필요 시 — 결정 13번)

CRL/OCSP 미운용(결정 7번)이라 개별 부트스트랩 인증서는 폐기 불가 → 폐기·회전은 **Bootstrap CA
통째 교체**로. Bootstrap CA 가 Intermediate 와 분리돼 있어 운영 체인(운영 디바이스 인증서·EMQX 서버
인증서·cert-manager 발급 워크로드 인증서)에는 영향 0.

**프로비저닝 완료 후 부트스트랩 경로 폐쇄** (선택): helm values 의 `device-bootstrap` provisioner 를
제거하거나 `roots` 를 비우고 redeploy(또는 `step-ca-whitelist` 를 빈 배열로 — 그러면 `templateData.allowedCNs: []`
→ device-bootstrap 발급 0, 단 device-renewal 도 같이 막힘). `device-renewal`(roots=intermediate_ca)·`admin`(JWK)
만 남음. `ca.json`/`step-ca-whitelist` 변경이라 rollout — 약 5~10 초 발급 거부 윈도우.

**부트스트랩 인증서 유출 시 회전** (오프라인, Root 키 있는 곳에서):

```bash
# 새 Bootstrap CA (이름에 버전 표기 권장 — 옛것과 구분)
step certificate create --profile intermediate-ca "GikView Bootstrap CA v2" \
    bootstrap_ca.crt bootstrap_ca_key --ca root_ca.crt --ca-key root_ca_key \
    --kty EC --curve P-256 --not-after 43800h
# 새 공통 부트스트랩 인증서 (CN=bootstrap, 7d, 키는 펌웨어에 굽히니 평문)
step certificate create --not-after 168h "bootstrap" bootstrap.crt bootstrap.key \
    --ca bootstrap_ca.crt --ca-key bootstrap_ca_key --kty EC --curve P-256 --no-password --insecure
base64 -w0 bootstrap_ca.crt   # → helm values 의 device-bootstrap.roots 교체 → step-ca redeploy(ca.json 변경 → rollout)
# → 디바이스 펌웨어에 새 bootstrap.crt/bootstrap.key 굽고 재플래시
# 새 bootstrap_ca_key → root_ca_key 와 함께 오프라인 보관 (위 "정리" 절과 동일); 랩톱 작업 사본은 shred -u.
# 옛 Bootstrap CA 키는 device-bootstrap.roots 에서 빠진 뒤 폐기 가능.
```

옛 Bootstrap CA 는 `device-bootstrap.roots` 에서 빠지는 순간 무효(그 CA 가 서명한 부트스트랩 인증서는
더 이상 X5C 검증 통과 안 함). 점진 전환이 필요하면 한동안 `roots` 에 옛것+새것 둘 다 두었다가 재플래시
완료 후 옛것 제거.

### 스모크 테스트용 부트스트랩 신원 (dev만, 선택 — `smoke-test-step-ca.sh #10` 용)

`#10` 은 디바이스 첫 부팅(X5C 토큰 → `/1.0/sign`)을 서버측 e2e 로 본다 — (a) `step-ca-whitelist`
등록 CN 발급 성공 + Root CA 체인, (b) 미등록 `device-ffffff` 거부. `device-bootstrap` provisioner 가
신뢰하는 root(`bootstrap_ca.crt`)로 서명된 **장수명 부트스트랩 leaf** 1개가 필요 (디바이스 7d
부트스트랩 cert 와 별개 — 스모크가 매주 깨지지 않게). cert·key 둘 다 dev 클러스터 Secret 에만 두고
git 에는 안 올린다.

```bash
# bootstrap_ca.crt / bootstrap_ca_key 있는 곳에서 (오프라인):
step certificate create --not-after 8760h "smoke-bootstrap" \
    smoke-bootstrap.crt smoke-bootstrap.key \
    --ca bootstrap_ca.crt --ca-key bootstrap_ca_key --kty EC --curve P-256 --no-password --insecure

# dev 클러스터에만 (kubernetes.io/tls → tls.crt / tls.key; 스모크가 둘 다 여기서 읽음):
kubectl create secret tls step-ca-smoke-bootstrap -n gikview --cert=smoke-bootstrap.crt --key=smoke-bootstrap.key
shred -u smoke-bootstrap.crt smoke-bootstrap.key
```

- dev 전용 — prod 엔 안 만든다(ArgoCD 배포, 스모크 미실행). Secret/`step` CLI 둘 중 하나라도 없으면
  #10 은 `note:` self-skip. 8760h 만료 시 같은 명령으로 재발급 + Secret 갱신 (trust 앵커가 아니라 내부
  테스트 크리덴셜이라 로테이션 영향 범위는 스모크 한정).
- 신원 CN(`smoke-bootstrap`)은 화이트리스트에 없어도 됨 — `{{ fail }}` 가드는 X5C 토큰 서명자 CN 이 아니라
  *요청된 device cert* 의 CN/SAN(#10(a) 가 `step-ca-whitelist` 첫 항목 사용)만 검사. #10(a) 가 그 CN 으로
  진짜 인증서를 발급하지만 `disableRenewal: true` + 새 serial 이라 무해 (발급 로그 노이즈 싫으면 dev
  whitelist 에 전용 테스트 CN).

## 알려진 주의사항

- **CVE-2026-30836 (CVSS 10) — `0.30.0` 미만 금지**: SCEP UpdateReq(MessageType=18) 통한 미인증 인증서 발급. `0.30.0` 에서 수정. 본 프로젝트는 SCEP provisioner 미사용이라 직접 익스플로잇은 어렵지만 CA 를 취약 코드 위에서 돌리지 않기 위해 `0.30.x` 사용. 관련: GHSA-h8cp-697h-8c8p(ACME/SCEP authz bypass), CVE-2025-66406(SSH cert 임의 폐기 — SSH cert 미사용).

- **DB 영속화 필수**: badger 또는 boltdb 같은 임베디드 DB 사용 시 Pod 재시작 후에도 발급 이력/revocation 데이터가 유지되어야 함. PVC 미사용 시 helm 재배포로 이력 손실 → 같은 디바이스가 재발급 시 시리얼 충돌 가능. 단일 노드 step-ca 는 local PV 권장.

- **Intermediate 키 노출 = Intermediate 침해**: K8s Secret 으로 저장된 intermediate key 가 노출되면 해당 step-ca 정지 + Root CA 로 새 Intermediate 발급 + 기존 폐기. Root CA 가 오프라인이라 침해되지 않는 것이 PKI 계층화의 본질.

- **X5C root 검증 실패 시 `provisioner not found`**: X5C provisioner 의 `roots` 가 base64 인코딩된 PEM 이어야 함. 줄바꿈 그대로 인코딩 시 yaml 파싱 오류. `cat ca.crt | base64 -w 0` 로 single-line 변환.

- **`provisioners[].policy.…` 가 조용히 무시됨 (OSS step-ca)**: 증상 — provisioner-단위 policy 블록이 적용 안 됨. 원인 — OSS(자체 호스팅) step-ca 는 authority-레벨 policy 만 지원(provisioner policy 는 hosted Smallstep Certificate Manager 전용), authority-레벨 policy 는 admin(JWK)까지 묶여 부적합. 해결 — provisioner별 발급 제한은 cert-template `{{ fail }}` 가드 + `options.x509.templateData` 로 구현 (메커니즘은 결정 14번); `provisioners[].policy.…` 는 쓰지 말 것.

- **`step-ca-whitelist` 갱신해도 발급 정책이 안 바뀜**: 증상 — ConfigMap 만 바꿔도 step-ca 가 옛 화이트리스트로 발급. 원인 — `ca.json` 의 `options.x509.template`/`templateData`(및 provisioner) 는 hot-reload 안 됨. 해결 — Reloader annotation 이 rollout 트리거 → `merge-ca-config` initContainer 가 정적 ca.json + whitelist 재머지(결정 15번); rollout 중 약 5~10 초 발급 거부 윈도우.

- **ArgoCD `helm` 소스는 post-renderer 미실행**: step-certificates 1.30.x 가 워크로드 metadata annotation 훅을 안 노출해 Reloader annotation 을 post-render kustomize patch 로 부착하는데, ArgoCD `helm` 소스는 post-renderer 건너뜀 → ArgoCD sync 시 그 annotation 누락. 회피: ArgoCD 환경에선 ConfigMap 변경 후 ArgoCD app refresh 또는 수동 rollout (상세는 결정 15번).

- **`disableRenewal: true` 인 provisioner 로 발급된 인증서**: `/1.0/renew` 호출 시 403. 부트스트랩 인증서는 갱신 불가가 의도된 동작. 디바이스는 정식 인증서 받은 후 `device-renewal` provisioner 로 갱신해야 함.

- **`allowRenewalAfterExpiry: true` 는 보안 위험**: 만료된 인증서로 갱신 시도가 통과되면 탈취 후 장기간 방치된 인증서가 부활. 본 프로젝트는 false 유지. 만료 시 부트스트랩 → 재발급 흐름.

- **ECDSA Intermediate + SCEP 비호환**: SCEP provisioner 는 RSA Intermediate 필수. 본 프로젝트는 SCEP 미사용 (X5C 사용) 이라 ECDSA 유지 가능.

- **CRL/OCSP responder 비활성**: 결정 7번 — 만료 → 부트스트랩 재발급, 회전은 Bootstrap CA 통째 교체 (위 "Bootstrap CA 회전" 절).

- **EMQX 클라이언트 검증 trust anchor = Root (Intermediate 아님)**: 부트스트랩 인증서 격리는 EMQX TLS 핸드셰이크가 아니라 ACL `no_match = deny` 가 담당 — EMQX 5.8.6(Erlang/OTP)이 `ssl_options.partial_chain` 을 노출 안 해 Intermediate 를 단독 trust anchor 로 못 씀. 디바이스/워크로드는 핸드셰이크에 `leaf + Intermediate` 제시 필수. 상세: 결정 12번, `context/knowledge/emqx.md`.

- **BearSSL 클라이언트 IP SAN 미지원**: ESP8266 BearSSL 클라이언트는 서버 인증서의 IP SAN 매칭을 안 함 (DNS SAN 만 지원). 본 phase 는 step-ca 를 NodePort 로 외부 노출(결정 11번)하지만, IP SAN 을 박아도 디바이스가 검증 안 하므로 step-ca 서버 인증서 `dnsNames` 는 DNS-only(노드 IP 미포함)로 둔다. 디바이스는 노드 IP 로 접속하되 IP SAN 검증은 생략 — 검증 환경은 `WiFiClientSecure.setInsecure()` 로 우회, 운영 trust 전략(펌웨어에 하드코딩한 DNS 명을 노드 IP 로 매핑(또는 학내 DNS) + 그 명을 `dnsNames` 에 추가)은 별도 ADR.

- **NodePort 외부 노출 시 attack surface**: NodePort 로 `:9000` 이 학내망에 노출됨. 익명 접근은 X5C provisioner 가 차단(유효한 부트스트랩/정식 인증서로 서명한 JWT 필수)하지만, 미인증 요청도 step-ca Pod 까지는 도달함(서명 검증 단계에서 거부). 노드 방화벽 / 공유기 포트포워딩 범위(학내 서브넷 한정 등)로 도달 범위를 추가 제한 권장. step-ca rollout 윈도우(정책 변경 시 5~10초) 동안에는 외부 요청도 거부됨.

- **호스트 디렉토리 권한**: local PV 사용 시 호스트 측 디렉토리 (`spec.local.path`) 소유자가 컨테이너 user (uid/gid 1000) 와 일치해야 함. 불일치 시 badger DB open 권한 거부로 crashloop. 호스트에서 `chown 1000:1000` 사전 실행 (위 "호스트 디렉토리 준비" 절). 같은 노드(prod e-s1 / dev alpha-w1)에 influxdb(uid 1500) 와 공존 시 uid 가 달라 디렉토리를 분리해야 함.

## 환경별 분리 필요 항목

| 항목 | dev (alpha cluster) | prod (edge) |
|------|-----|------|
| `ca.json` 의 `dnsNames` (`values-<env>.yaml` 에서 주입) | `["step-ca", "step-ca.gikview.svc.alpha.nexus.local", "127.0.0.1"]` | `["step-ca", "step-ca.gikview.svc.cluster.local", "127.0.0.1"]` (디바이스-facing DNS 명이 ADR 로 정해지면 그 줄 추가) |
| `nodeSelector` (`security` 카테고리) | `kubernetes.io/hostname: alpha-w1` | `kubernetes.io/hostname: e-s1` |
| NodePort 서비스 (`step-ca-nodeport`) | `type: NodePort`, `nodePort: 31900`, `externalTrafficPolicy: Local` | `type: NodePort`, `nodePort: 31900`, `externalTrafficPolicy: Local` |
| 공유기 포트포워딩 (운영자 1회) | `<dev 외부포트> → alpha-w1:31900` | `<외부포트> → e-s1:31900` |
| `local PV spec.local.path (호스트 디렉토리)` | `/var/lib/step-ca` (alpha-w1) | `/mnt/ssd/step-ca` (e-s1) |
| `persistence.size` | `1Gi` | `2Gi` |
| `resources.requests.memory` | `64Mi` | `64Mi` |
| `resources.limits.memory` | `256Mi` | `256Mi` |