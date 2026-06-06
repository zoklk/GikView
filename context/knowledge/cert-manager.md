# cert-manager — 운영 지식 메모

---

## 이미지 / 버전

**채택**: cert-manager `v1.20.2` (OCI: `quay.io/jetstack/cert-manager-controller:v1.20.2`)

K8s 워크로드 (broker, Edge Gateway, Telegraf) 의 TLS 인증서 발급/갱신 자동화. Certificate CRD 로 선언하면 cert-manager controller 가 step-issuer 를 통해 step-ca 에 CSR 을 보내고 Secret 을 자동 생성/갱신. Reloader 가 Secret 변경을 감지하여 Pod rollout.

선택 근거: K8s 인증서 자동화의 사실상 표준 (CNCF Graduated). step-issuer 와 직접 통합 가능. Sealed Secrets/SOPS 대비 인증서 갱신까지 자동.

`v1.20.x` 마이너 고정: 2026-03 출시 안정 버전. 1.21 출시 시 release notes 확인 후 업그레이드.

Helm chart: `cert-manager` `v1.20.2` (repo: `https://charts.jetstack.io`) — 엄브렐라 차트로 vendor (`edge/helm/cert-manager/charts/cert-manager-v1.20.2.tgz`). `oci://quay.io/jetstack/charts/cert-manager` 도 동일 차트를 제공(릴리즈가 몇 시간 빠름)하나 본 프로젝트는 HTTP repo 에서 받았음.

## 주요 설정

cert-manager 는 controller, webhook, cainjector 세 컴포넌트로 구성됨. 본 프로젝트는 외부 인증서 issuer 만 쓰고 ACME/Vault 미사용이므로 최소 구성 + CRD 동시 설치.

```yaml
# edge/helm/cert-manager/values.yaml — 엄브렐라. "cert-manager:" 블록은 jetstack/cert-manager 서브차트로 전달.
cert-manager:
  crds:
    enabled: true            # CRD 함께 설치 (v1.15+ 이후 installCRDs 대신 crds.enabled)
    keep: true               # uninstall 시에도 CRD 유지 (Certificate 리소스 보존)
  global:
    leaderElection:
      namespace: gikview     # 설치 ns 와 일치해야 함 — 차트 기본값 "cert-manager" 를 두면 그 ns 가 없어
                             #   leader election lease 생성 실패 → 컨트롤러가 리더 못 잡음. 본 프로젝트는
                             #   cert-manager 를 gikview ns 에 배포(전용 ns 불필요, PKI 컴포넌트 응집)하므로 gikview.
  prometheus:
    enabled: false           # 자체 메트릭 미노출. visibility 단계에서 enabled: true
  replicaCount: 1            # controller 단일 (9 대 규모 non-HA; Argo CD self-heal)
  resources:
    requests: { cpu: 10m, memory: 32Mi }
    limits:   { cpu: 100m, memory: 128Mi }
  webhook:
    replicaCount: 1
    resources:
      requests: { cpu: 10m, memory: 32Mi }
      limits:   { cpu: 100m, memory: 128Mi }
  cainjector:
    replicaCount: 1
    resources:
      requests: { cpu: 10m, memory: 32Mi }
      limits:   { cpu: 100m, memory: 128Mi }
```

### Certificate 리소스 — 제네릭 스켈레톤

워크로드별 실제 `commonName` / `dnsNames` / `ipAddresses` 는 각 service 의 helm chart 안에서 환경별 templating 하며, 그 실제값의 정본은 해당 phase 문서다 (예: EMQX 서버 cert 의 SAN·IP 는 `context/phases/edge-security.md` 의 emqx 서비스). 여기서는 공통 형태만:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: <workload>-tls
  namespace: gikview
spec:
  secretName: <workload>-tls
  commonName: "<EMQX ACL 의 CN(클라이언트) 또는 서버 FQDN(서버)>"
  # dnsNames: [ ... ]      # 서버 cert 만 — SAN
  # ipAddresses: [ ... ]   # 서버 cert 만 — NodePort 노드 IP 등 (값은 phase 문서가 정본)
  duration: 2160h          # 90d
  renewBefore: 720h        # 만료 30d 전 갱신 (duration 의 1/3 — 경계값, 그 이하면 cert-manager 경고)
  privateKey:
    algorithm: ECDSA       # 누락 시 RSA 2048 로 발급 → step-ca Intermediate(ECDSA P-256)와 불일치
    size: 256
    rotationPolicy: Always
  issuerRef:
    group: certmanager.step.sm
    kind: StepClusterIssuer
    name: step-cluster-issuer
```

## 알려진 주의사항

- **CRD 설치 누락**: `crds.enabled: false` (default) 인 경우 별도로 `kubectl apply -f cert-manager.crds.yaml` 필요. helm 으로 함께 설치하는 게 누락 위험 적음. 단 `crds.keep: true` 설정 안 하면 uninstall 시 CRD 와 함께 Certificate 리소스 전체 삭제.

- **무한 재발급 루프**: cert-manager 1.19.0 에 알려진 버그로, issuer 가 CSR 과 다른 공개키를 반환하면 재발급이 반복됨. 1.19.1+ 또는 1.20.x 에서 수정됨. 본 프로젝트 1.20.2 사용으로 영향 없음.

- **Secret 갱신 후 Pod 자동 reload 안 됨**: cert-manager 가 Secret 을 갱신해도 TLS handshake 가 이미 끝난 MQTT 클라이언트는 새 인증서를 인식 안 함. Reloader (별도 컴포넌트, 본 phase 에 포함) 가 annotation 기반으로 Pod rollout 트리거.

- **External issuer 순서 의존성**: step-issuer 가 cert-manager CRD 보다 먼저 뜨면 "CRD 없음" 오류로 기동 실패. Argo CD sync-wave 로 cert-manager → step-issuer → step-ca → mapping-generator → emqx 순서를 강제 (실제 wave 번호의 정본은 `context/phases/edge-security.md` 의 "Argo CD sync-wave 요약" 표 — 여기서 번호를 다시 적으면 stale 위험; 워크로드별 Certificate 리소스는 해당 워크로드 sync-wave 와 함께 배포).

- **leader election lease 의 namespace = `global.leaderElection.namespace`**: 차트 기본값은 `cert-manager`. cert-manager 를 다른 ns(여기선 `gikview`)에 설치하면 이 값을 그 ns 로 맞춰야 lease 를 만들 수 있음. 안 맞추면 컨트롤러가 리더를 못 잡아 reconcile 정지. 또 동일 ns 에 두 인스턴스면 lease 충돌 — 단일 인스턴스 유지.

- **default 알고리즘 RSA 2048**: 본 프로젝트는 ECDSA P-256 명시 (step-ca Intermediate 와 일치). `privateKey.algorithm: ECDSA` 누락 시 RSA 로 발급되어 step-ca policy 와 충돌 가능.

- **renewBefore vs duration 비율**: renewBefore 가 duration 의 1/3 미만이면 cert-manager 가 경고. 본 프로젝트 90d / 30d = 1/3 으로 경계값.

## 환경별 분리 필요 항목

| 항목 | dev (alpha cluster) | prod (edge) |
|------|-----|------|
| `nodeSelector` (`security` 카테고리) | `kubernetes.io/hostname: alpha-w1` | `kubernetes.io/hostname: e-s1` |

cert-manager controller / webhook / cainjector 는 노드 무관하게 동작하지만(웹훅·watch·step-ca 통신 모두 cross-node OK), `node_category: [security]` 로 두어 PKI 컴포넌트를 한 노드(prod e-s1, dev alpha-w1)에 응집 — `cluster-env-inject` 가 `config/harness.yaml` 의 `node_selectors.security` 를 `values-<env>.yaml` 에 주입. 리소스가 작아(10m/32Mi) 응집 부담은 무시 가능.

이 외 cert-manager 컴포넌트 자체는 환경별 차이 없음. Certificate 리소스의 `dnsNames` / `ipAddresses` 는 환경별로 다르며 (prod IP vs dev IP), 각 service 의 helm chart 안에서 환경별 templating — 실제값의 정본은 해당 phase 문서 (예: `context/phases/edge-security.md` 의 emqx 서비스).