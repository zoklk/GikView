# iam-roles-anywhere — 운영 지식 메모

---

## 개요

AWS 관리형 서비스 — 이미지/버전 없음.

온프레미스 워크로드가 X.509 인증서로 AWS STS 임시 자격증명을 발급받는 메커니즘.
정적 access key 없이 K8s Pod 가 DynamoDB 등 AWS 리소스에 접근할 수 있게 함.

본 프로젝트 적용 대상: Edge Gateway Pod → DynamoDB 직접 upsert (쓰기 경로).
기존 step-ca Intermediate CA 를 Trust Anchor 로 등록하여 신규 PKI 인프라 불필요.

Trust Anchor(step-ca Intermediate)는 다중 클라이언트가 공유한다. edge-gateway(`gikview-edge-gateway`, rooms write) 외에 web-metrics-exporter(`gikview-web-visibility`, metrics read-only)도 동일 Anchor 로 STS 교환 — role 별 권한만 분리.

## 구성 요소

| 리소스 | 역할 |
|---|---|
| Trust Anchor | AWS 가 신뢰할 CA cert 등록. step-ca Intermediate CA cert 사용 |
| IAM Role | 실제 AWS 권한. Trust Policy 에 CN 조건으로 특정 인증서만 assume 허용 |
| Profile | Trust Anchor ↔ Role 연결. Session Policy 로 권한 이중 제한 |

## 주요 설정

### Trust Anchor

step-ca Intermediate CA cert (`intermediate_ca.crt`) 를 등록.
Root CA 가 오프라인이므로 Intermediate 를 직접 anchor 로 — 신뢰 범위를 step-ca 서명 cert 로 한정.

AWS 콘솔: IAM → Roles Anywhere → Create a trust anchor
- Trust anchor name: `gikview-step-ca-anchor`
- Certificate Authority: External certificate bundle
- 파일: `intermediate_ca.crt`

### IAM Role Trust Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "rolesanywhere.amazonaws.com" },
      "Action": [
        "sts:AssumeRole",
        "sts:TagSession",
        "sts:SetSourceIdentity"
      ],
      "Condition": {
        "StringEquals": {
          "aws:PrincipalTag/x509Subject/CN": "edge-gateway"
        }
      }
    }
  ]
}
```

CN 조건 필수 — 없으면 step-ca 가 서명한 모든 인증서(device cert 포함)가 role assume 가능.
`device-XXXXXX` CN 인증서로 요청 시 조건 불일치 → 거부.

### IAM Role Permission Policy (인라인)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:PutItem"
      ],
      "Resource": "arn:aws:dynamodb:ap-northeast-2:{ACCOUNT_ID}:table/gikview-rooms"
    }
  ]
}
```

읽기 권한 전부 제외. 쓰기 전용. PK=`room_id` only (SK 없음) 라 `PutItem` 으로 멱등 overwrite — `UpdateItem` 불필요.

### Profile Session Policy

Profile 에 session policy 를 추가하면 Role 권한을 한 번 더 교집합으로 제한.
Role 이 미래에 권한이 늘어도 session 은 여기 정의한 범위만 유효 (이중 잠금).

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["dynamodb:PutItem"],
      "Resource": "arn:aws:dynamodb:ap-northeast-2:{ACCOUNT_ID}:table/gikview-rooms"
    }
  ]
}
```

### Edge Gateway 에서의 사용 — AWS signing helper

cert-manager 가 발급한 Edge Gateway client cert (`edge-gateway-tls` Secret) 를 그대로 사용.
`aws_signing_helper` 를 `credential_process` 로 등록 → AWS SDK 가 자동으로 임시 자격증명 획득·갱신.

```ini
# ~/.aws/credentials (또는 AWS_SHARED_CREDENTIALS_FILE 환경변수 경로)
[default]
credential_process = aws_signing_helper credential-process \
  --certificate /tls/tls.crt \
  --private-key /tls/tls.key \
  --trust-anchor-arn <trustAnchorArn> \
  --profile-arn <profileArn> \
  --role-arn <roleArn>
```

K8s 적용 방식:
- `edge-gateway-tls` Secret → volumeMount `/tls/` (cert-manager 발급, CN=`edge-gateway`)
- ARN 3개 + region → helm `values-<env>.yaml` → Deployment env 직접 주입 (`TRUST_ANCHOR_ARN`, `PROFILE_ARN`, `ROLE_ARN`, `AWS_DEFAULT_REGION`)
- signing helper 바이너리 → Edge Gateway 이미지에 포함 (멀티스테이지 빌드, `linux/arm64` 빌드 필수)
- credentials 파일 안 만듦 — `AWS_*` env 가 SDK 직접 인식. signing helper 호출도 env (`$TRUST_ANCHOR_ARN` 등) 로 인자 전달, 또는 Go 코드의 SDK config 에서 설정

cert-manager 가 인증서 갱신 시 Reloader 가 Edge Gateway rollout 트리거 → 새 cert 로 재기동.
signing helper 는 기동 시 cert 경로에서 읽으므로 갱신 반영은 rollout 으로 해결.

### ARN 저장 위치

ARN = 식별자, 자격증명 아님 — K8s Secret 낭비. **`values-<env>.yaml` → Deployment env 직접 주입**.

```yaml
# edge/helm/edge-gateway/values-prod.yaml (예)
iamRolesAnywhere:
  trustAnchorArn: "arn:aws:rolesanywhere:ap-northeast-2:{ACCOUNT_ID}:trust-anchor/..."
  profileArn:     "arn:aws:rolesanywhere:ap-northeast-2:{ACCOUNT_ID}:profile/..."
  roleArn:        "arn:aws:iam::{ACCOUNT_ID}:role/gikview-edge-gateway"
  region:         "ap-northeast-2"
```

```yaml
# edge/helm/edge-gateway/templates/deployment.yaml (env 부분, 발췌)
env:
  - name: TRUST_ANCHOR_ARN
    value: {{ .Values.iamRolesAnywhere.trustAnchorArn | quote }}
  - name: PROFILE_ARN
    value: {{ .Values.iamRolesAnywhere.profileArn | quote }}
  - name: ROLE_ARN
    value: {{ .Values.iamRolesAnywhere.roleArn | quote }}
  - name: AWS_DEFAULT_REGION
    value: {{ .Values.iamRolesAnywhere.region | quote }}
```

ConfigMap 경유 안 함 — ARN 변경 빈도 ~0 + GitOps(ArgoCD) 하에 ConfigMap edit 도 git PR 경로 → Reloader 의 "즉시 적용" 이득 없음. ConfigMap 1개 + Reloader annotation 1줄 감소.

## 알려진 주의사항

- **signing helper linux/arm64 빌드**: RPi4(arm64) 에서 실행되므로 `GOARCH=arm64 GOENV=linux` 크로스 빌드 또는 arm64 공식 바이너리 필수. amd64 바이너리는 exec format error 로 즉시 실패.

- **임시 자격증명 TTL**: 기본 1 시간. 만료 전 signing helper 가 자동 재발급. Pod 재기동 없이 갱신됨. TTL 은 Profile 에서 `durationSeconds` 로 조정 가능 (최소 15분, 최대 12시간).

- **cert chain 제출 필수**: signing helper 가 step-ca 에 제출하는 cert 는 `tls.crt` (= leaf + Intermediate chain). Intermediate 까지 포함해야 Trust Anchor(Intermediate CA) 검증 통과. leaf 만 제출 시 chain 불완전으로 인증 실패. cert-manager 발급 `tls.crt` 는 leaf + Intermediate 자동 포함 — 별도 처리 불필요.

- **CN 조건 대소문자 구분**: `aws:PrincipalTag/x509Subject/CN` 값은 cert 의 CN 과 정확히 일치해야 함. cert-manager Certificate 의 `commonName: "edge-gateway"` 와 trust policy 의 CN 조건이 동일 문자열인지 확인.

- **Trust Anchor = Intermediate → Root 검증 생략**: IAM Roles Anywhere 는 Trust Anchor 로 등록된 CA 까지만 chain 검증. Intermediate 를 anchor 로 두면 Root CA cert 없이도 동작. Root CA 가 오프라인인 본 프로젝트 구조에 적합.

- **Device cert 탈취 시 DynamoDB 접근 불가**: device cert CN(`device-XXXXXX`)은 trust policy CN 조건(`edge-gateway`) 불일치 → role assume 거부. 단 Edge Gateway cert + private key 탈취 시에는 접근 가능 — K8s Secret 접근이 선행 조건.

- **Notification settings (콘솔)**: Trust Anchor 의 CA certificate expiry event 는 Intermediate CA cert 만료 알림 (10년짜리라 실질적 무의미). End entity certificate expiry event 는 signing helper 가 제출한 Edge Gateway cert 만료 알림 — cert-manager 가 자동 갱신하므로 이 알림이 울리면 cert-manager 또는 Reloader 이상 신호.

## 환경별 분리 필요 항목

| 항목 | dev (alpha cluster) | prod (edge) |
|------|-----|------|
| Trust Anchor | dev 전용 등록 (dev Intermediate CA cert) | prod 등록 (prod Intermediate CA cert) |
| Role ARN | dev role | prod role |
| Profile ARN | dev profile | prod profile |
| DynamoDB table ARN | dev table | `gikview-rooms` (prod) |
| signing helper 아키텍처 | `linux/amd64` (alpha-w* x86) | `linux/arm64` (RPi4) |