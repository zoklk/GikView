# cert-manager — 운영 지식 메모

---

## 이미지 / 버전

**채택**: cert-manager `v1.20.2` (OCI: `quay.io/jetstack/cert-manager-controller:v1.20.2`)

K8s 워크로드 (broker, Edge Gateway, Telegraf) 의 TLS 인증서 발급/갱신 자동화. Certificate CRD 로 선언하면 cert-manager controller 가 step-issuer 를 통해 step-ca 에 CSR 을 보내고 Secret 을 자동 생성/갱신. Reloader 가 Secret 변경을 감지하여 Pod rollout.

선택 근거: K8s 인증서 자동화의 사실상 표준 (CNCF Graduated). step-issuer 와 직접 통합 가능. Sealed Secrets/SOPS 대비 인증서 갱신까지 자동.

`v1.20.x` 마이너 고정: 2026-03 출시 안정 버전. 1.21 출시 시 release notes 확인 후 업그레이드.

Helm chart: `cert-manager` `v1.20.2` (repo: `oci://quay.io/jetstack/charts/cert-manager`)

> 레거시 HTTP repo `https://charts.jetstack.io` 도 동작하나 OCI 가 권장 경로 (몇 시간 빠른 릴리즈).

## 주요 설정

cert-manager 는 controller, webhook, cainjector 세 컴포넌트로 구성됨. 본 프로젝트는 외부 인증서 issuer 만 쓰고 ACME/Vault 미사용이므로 최소 구성 + CRD 동시 설치.

```yaml
# values.yaml (공통)
crds:
  enabled: true            # CRD 함께 설치 (v1.15+ 이후 installCRDs 대신 crds.enabled)
  keep: true               # uninstall 시에도 CRD 유지 (Certificate 리소스 보존)

global:
  leaderElection:
    namespace: "cert-manager"

# 외부 issuer (step-issuer) 만 쓰므로 ACME solver 불필요
prometheus:
  enabled: false           # 자체 메트릭 노출. visibility 단계에서 enabled: true 로 전환

webhook:
  replicaCount: 1          # 9 대 규모 + non-HA 정책
cainjector:
  replicaCount: 1
replicaCount: 1            # controller 도 단일 (Argo CD 가 self-healing)

resources:
  requests:
    cpu: "10m"
    memory: "32Mi"
  limits:
    memory: "128Mi"
```

### Certificate 리소스 예시 — Edge Gateway 클라이언트 인증서

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: edge-gateway-tls
  namespace: gikview
spec:
  secretName: edge-gateway-tls
  commonName: "edge-gateway"          # EMQX ACL 의 CN
  duration: 2160h                     # 90d
  renewBefore: 720h                   # 만료 30d 전 갱신
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  issuerRef:
    group: certmanager.step.sm
    kind: StepClusterIssuer
    name: step-cluster-issuer
```

### Certificate 리소스 예시 — EMQX broker 서버 인증서

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: emqx-server-tls
  namespace: gikview
spec:
  secretName: emqx-server-tls
  commonName: "emqx.gikview.svc.cluster.local"
  dnsNames:
    - "emqx.gikview.svc.cluster.local"
    - "emqx-nodeport.gikview.svc.cluster.local"
    - "*.emqx-headless.gikview.svc.cluster.local"
  ipAddresses:
    - "192.168.0.102"
    - "192.168.0.103"
  duration: 2160h
  renewBefore: 720h
  issuerRef:
    group: certmanager.step.sm
    kind: StepClusterIssuer
    name: step-cluster-issuer
```

## 알려진 주의사항

- **CRD 설치 누락**: `crds.enabled: false` (default) 인 경우 별도로 `kubectl apply -f cert-manager.crds.yaml` 필요. helm 으로 함께 설치하는 게 누락 위험 적음. 단 `crds.keep: true` 설정 안 하면 uninstall 시 CRD 와 함께 Certificate 리소스 전체 삭제.

- **무한 재발급 루프**: cert-manager 1.19.0 에 알려진 버그로, issuer 가 CSR 과 다른 공개키를 반환하면 재발급이 반복됨. 1.19.1+ 또는 1.20.x 에서 수정됨. 본 프로젝트 1.20.2 사용으로 영향 없음.

- **Secret 갱신 후 Pod 자동 reload 안 됨**: cert-manager 가 Secret 을 갱신해도 TLS handshake 가 이미 끝난 MQTT 클라이언트는 새 인증서를 인식 안 함. Reloader (별도 컴포넌트, 본 phase 에 포함) 가 annotation 기반으로 Pod rollout 트리거.

- **External issuer 시간차 의존성**: step-issuer 가 cert-manager 보다 먼저 배포되면 CRD 미존재 오류. Argo CD `sync-wave` 로 cert-manager / reloader (-2) → step-issuer (-1) → step-ca (0) → mapping-generator (1) → emqx + `emqx-server-tls` Certificate (2) 순서 강제 (워크로드별 Certificate 리소스는 해당 워크로드 sync-wave 와 함께 배포).

- **leader election 충돌**: 동일 namespace 에 cert-manager 두 인스턴스 배포 시 leader election lease 충돌. 단일 인스턴스 유지.

- **default 알고리즘 RSA 2048**: 본 프로젝트는 ECDSA P-256 명시 (step-ca Intermediate 와 일치). `privateKey.algorithm: ECDSA` 누락 시 RSA 로 발급되어 step-ca policy 와 충돌 가능.

- **renewBefore vs duration 비율**: renewBefore 가 duration 의 1/3 미만이면 cert-manager 가 경고. 본 프로젝트 90d / 30d = 1/3 으로 경계값.

## 환경별 분리 필요 항목

| 항목 | dev (alpha cluster) | prod (edge) |
|------|-----|------|
| `nodeSelector` (`security` 카테고리) | `kubernetes.io/hostname: alpha-w1` | `kubernetes.io/hostname: e-s1` |

cert-manager controller / webhook / cainjector 는 노드 무관하게 동작하지만(웹훅·watch·step-ca 통신 모두 cross-node OK), `node_category: [security]` 로 두어 PKI 컴포넌트를 한 노드(prod e-s1, dev alpha-w1)에 응집 — `cluster-env-inject` 가 `config/harness.yaml` 의 `node_selectors.security` 를 `values-<env>.yaml` 에 주입. 리소스가 작아(10m/32Mi) 응집 부담은 무시 가능.

이 외 cert-manager 컴포넌트 자체는 환경별 차이 없음. Certificate 리소스의 `dnsNames` / `ipAddresses` 는 환경별 다름 (위 EMQX 예시처럼 prod IP vs dev IP) — 각 service 의 helm chart 안에서 환경별 templating.