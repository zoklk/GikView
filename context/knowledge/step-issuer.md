# step-issuer — 운영 지식 메모

---

## 이미지 / 버전

**채택**: `smallstep/step-issuer:0.10.2` (chart `1.10.2` 의 appVersion)

step-issuer 는 cert-manager 의 External Issuer. Certificate 리소스 → CertificateRequest 가 생성되면 step-issuer controller 가 이를 받아 step-ca 에 X5C/JWK provisioner 로 서명 요청. cert-manager 와 step-ca 의 통신 다리.

선택 근거: step-ca 와 직접 통합되는 유일한 cert-manager Issuer. ACME 처럼 도메인 검증 불필요 (K8s 내부 워크로드용). 자체 구현 (custom controller) 대비 운영 부담 없음.

Helm chart: `smallstep/step-issuer` `1.10.2` (repo: `https://smallstep.github.io/helm-charts/`, appVersion `0.10.2`)

## 주요 설정

step-issuer 는 controller 만 배포 (Pod 1 개). 동작에 필요한 resource 는 `StepIssuer` 또는 `StepClusterIssuer` 커스텀 리소스로 별도 선언. 본 프로젝트는 다 namespace 에서 사용하므로 `StepClusterIssuer` 권장.

```yaml
# edge/helm/step-issuer/values.yaml — 엄브렐라. "step-issuer:" 는 서브차트(controller)로,
# "stepClusterIssuer:" 는 이 차트의 templates/stepclusterissuer.yaml 로 전달.
step-issuer:
  replicaCount: 1
  metrics:
    enabled: false               # visibility 단계에서 true
  resources:
    requests: { cpu: 10m, memory: 32Mi }
    limits:   { cpu: 100m, memory: 128Mi }
  # 서브차트는 .Values.securityContext / .podSecurityContext 를 verbatim 통과 — trivy KSV 대응 차원에서 하드닝
  # (/manager 는 controller-runtime 바이너리, on-disk state 없어 readOnlyRootFilesystem 안전).
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities: { drop: ["ALL"] }
    seccompProfile: { type: RuntimeDefault }
  podSecurityContext:
    runAsNonRoot: true
    seccompProfile: { type: RuntimeDefault }
  # cert-manager 가 gikview ns 에 있으므로(차트 기본 "cert-manager" 아님), 차트의 approver
  # ClusterRoleBinding subject 도 여기로 맞춰야 StepClusterIssuer 대상 CertificateRequest 가 approved 됨
  # (disableApprovalCheck 는 false 유지).
  certManager:
    serviceAccount:
      name: cert-manager
      namespace: gikview
```

### StepClusterIssuer 리소스

step-ca 와 어떤 provisioner 를 쓸지 정의. K8s 워크로드용 JWK provisioner 와 연결.

```yaml
apiVersion: certmanager.step.sm/v1beta1
kind: StepClusterIssuer
metadata:
  name: step-cluster-issuer
spec:
  url: "https://step-ca.gikview.svc.cluster.local:9000"
  caBundle: "<base64 of root_ca.crt>"   # step-ca 의 root cert (검증용)
  provisioner:
    name: "admin"                        # step-ca ca.json 의 JWK provisioner 이름
    kid: "<provisioner kid>"             # step ca provisioner list 로 확인
    passwordRef:
      name: "step-issuer-provisioner-password"
      namespace: "gikview"               # cluster-scoped 리소스라 CRD 가 필수로 요구 (생략 시 invalid)
      key: "password"
```

### Provisioner password Secret

step-issuer 가 JWK provisioner 비밀번호로 step-ca 에 인증.

```bash
kubectl create secret generic step-issuer-provisioner-password \
    -n gikview \
    --from-literal=password="<JWK provisioner password>"
```

step-ca 의 JWK provisioner 생성 시 사용한 비밀번호와 동일.

## 알려진 주의사항

- **kid 누락 시 `provisioner not found`**: step-ca 는 동일 이름의 provisioner 가 여러 개 가능하므로 kid (key ID) 로 정확히 식별. `step ca provisioner list --ca-url <url> --root <root.crt>` 로 확인 후 StepClusterIssuer 의 `kid` 에 명시.

- **caBundle 단일 라인 base64 필수**: 줄바꿈 포함된 PEM 을 그대로 yaml 에 넣으면 step-issuer 가 root CA 파싱 실패. `cat root_ca.crt | base64 -w 0` 로 변환.

- **CertificateRequest approval 대기**: cert-manager v1.3+ 에서 CertificateRequest 는 자동으로 approved 컨디션이 붙는데, 오래된 cert-manager (pre v1.3) 와 함께 쓰면 step-issuer 가 무한 대기. 본 프로젝트 cert-manager 1.20.x 라 해당 없음. helm values 에 `args.disableApprovalCheck: false` 유지 — 단 차트 approver 의 SA 이름/ns 를 실제 cert-manager 위치(`gikview`)에 맞췄을 때만 유효(`step-issuer.certManager.serviceAccount`).

- **StepIssuer (namespace 스코프) vs StepClusterIssuer (cluster 스코프)**: 같은 issuer 를 여러 namespace 에서 쓸 거면 ClusterIssuer 권장. 본 프로젝트는 `gikview` 단일 namespace 라 둘 다 가능하나, 확장성 위해 ClusterIssuer.

- **step-ca 다운 시 발급 대기**: step-issuer 는 step-ca 에 도달 못 하면 CertificateRequest 를 `pending` 상태로 보류 후 재시도. step-ca 복구되면 자동 처리. 단 신규 Pod 의 첫 인증서 발급은 지연.

- **CSR isCA: false 명시**: cert-manager Certificate 는 기본 isCA: false 지만, CertificateRequest 단계에서 `isCA: true` 가 전달되면 step-ca 가 거부. 본 프로젝트는 leaf 인증서만 발급하므로 영향 없음.

- **Provisioner password Secret 분실 시 복구**: step-ca 의 JWK provisioner 패스워드를 잊으면 provisioner 재생성 필요 (기존 provisioner 폐기 + 새 JWK key 생성). step-issuer Secret 도 함께 갱신.

## 환경별 분리 필요 항목

| 항목 | dev (alpha cluster) | prod (edge) |
|------|-----|------|
| `StepClusterIssuer.spec.url` | `https://step-ca.gikview.svc.alpha.nexus.local:9000` | `https://step-ca.gikview.svc.cluster.local:9000` |
| `nodeSelector` (`security` 카테고리) | `kubernetes.io/hostname: alpha-w1` | `kubernetes.io/hostname: e-s1` |

step-issuer controller 는 노드 무관하게 동작(step-ca·cert-manager 와 cross-node 통신 OK)하지만 `node_category: [security]` 로 두어 PKI 컴포넌트를 한 노드(prod e-s1, dev alpha-w1)에 응집 — `cluster-env-inject` 가 `config/harness.yaml` 의 `node_selectors.security` 를 주입.

`caBundle`, `provisioner.kid` 는 환경마다 step-ca 가 별도 root/provisioner 를 가지므로 환경별로 다름 (각 env 에서 init 후 값 주입). `StepClusterIssuer.spec.url` 은 클러스터 내부 통신이므로 ClusterIP DNS 명 사용 (NodePort 아님 — NodePort 는 디바이스 외부 접근 전용).