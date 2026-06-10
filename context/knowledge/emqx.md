# emqx — 운영 지식 메모

---
## 이미지 / 버전

**채택**: `emqx:5.8.6` (`docker.io/emqx/emqx:5.8.6`)

v5.9.0부터 BSL 1.1로 라이선스가 변경되어 1노드 초과 클러스터 구성 시 라이선스 키가 필수임. 5.8.6 버전은 Apache 2.0 라이선스로 제한 없는 클러스터 구성이 가능한 마지막 버전임.

Helm chart: `emqx/emqx` `5.8.6` (repo: `https://repos.emqx.io/charts`)

## 주요 설정

K3s 내부 DNS를 통한 정적 클러스터 디스커버리를 사용함. `RECORD_TYPE`과 `NODE__NAME`의 형식이 일치하지 않으면 `integrity_validation_failure`로 인해 포드가 기동되지 않음.

```yaml
# values.yaml (공통)
emqxConfig:
  EMQX_CLUSTER__DISCOVERY_STRATEGY: "dns"
  EMQX_CLUSTER__DNS__RECORD_TYPE: "srv"  # FQDN 기반 디스커버리 필수

# securityContext 및 볼륨 설정 (Trivy 보안 가이드 준수)
containerSecurityContext:
  readOnlyRootFilesystem: true

extraVolumeMounts:
  - name: emqx-data
    mountPath: /opt/emqx/data
  - name: emqx-log
    mountPath: /opt/emqx/log
  - name: tmp
    mountPath: /tmp
```

## 알려진 주의사항

- **노드 네이밍 규칙**: `EMQX_CLUSTER__DNS__RECORD_TYPE`이 `"srv"`일 경우, `EMQX_NODE__NAME`은 반드시 FQDN 형식(`emqx@<pod>.<svc>.<ns>.svc.<domain>`)이어야 함.
- **데이터 일관성**: IP 기반 노드 네이밍은 포드 재시작 시 Mnesia 데이터 불일치를 유발함. 반드시 고정된 FQDN 형식을 사용하여 노드 식별자를 유지해야 함.
- **Headless Service 필수 구성**: SRV 레코드 생성을 위해 서비스의 `ports` 섹션에 `ekka` 포트(4370)의 `name`이 반드시 명시되어야 함.
- **권한 제약**: `readOnlyRootFilesystem` 적용 시 데이터 및 로그 경로에 쓰기 가능한 볼륨(EmptyDir 등) 할당이 누락되면 기동에 실패함.
- **`ssl_options.partial_chain` 미노출 (EMQX 5.8.6)**: EMQX 는 Erlang/OTP 위에서 동작하고 TLS 는 OTP `ssl` 모듈이 담당. OTP `ssl` 은 신뢰 체인이 self-signed Root 까지 닿아야 검증 통과 — 중간 CA 를 단독 trust anchor 로 인정하려면 `partial_chain` fun 옵션이 필요한데, EMQX 5.8.6 의 `emqx_schema.erl`(`common_ssl_opts_schema`/`server_ssl_opts_schema`)이 이를 노출하지 않음. → `ssl_options.cacertfile` 은 Root CA 여야 정상 디바이스/워크로드 인증서가 검증됨(`cacertfile = Intermediate` 면 정상 인증서마저 거부될 수 있고 5.8.6 엔 교정 손잡이 없음). 부작용: 부트스트랩 인증서도 TLS 핸드셰이크는 통과(데이터 평면은 ACL `no_match = deny` 가 막음 — 결정 12번).
- **클라이언트는 `leaf + Intermediate` 제시 필수**: EMQX 가 Root 를 trust anchor 로 가지므로, 클라이언트가 leaf 만 보내면 OTP `ssl` 이 중간(Intermediate)을 못 찾아 핸드셰이크 실패. cert-manager 발급 Secret 의 `tls.crt`(= leaf + Intermediate)는 자동 충족. ESP8266 은 `/1.0/sign` 응답의 `certChain`(=[leaf, intermediate])을 둘 다 저장하고 `WiFiClientSecure.setClientECCert()` 에 둘 다 넣어야 함(펌웨어 후속 작업; `context/knowledge/step-ca.md`).
- **`peer_cert_as_username` 은 broker-wide schema only (EMQX 5.8.6)**: `emqx_schema.erl` 가 이 필드를 `mqtt.peer_cert_as_username` 에만 두고 listener-scoped 위치(`listeners.ssl.<name>.peer_cert_as_username`, `..._SSL_OPTIONS__PEER_CERT_AS_USERNAME` 등) 엔 노출 안 함. 차트 env 로 주입하려면 `EMQX_MQTT__PEER_CERT_AS_USERNAME` 만 인식 — listener-scoped 변형은 `unknown_env_vars` 로 떨어져 적용 안 됨. 증상: AUTHZ 로그의 username 이 ACL 매칭에 안 잡힘.

## 서비스 구성

EMQX는 용도별로 3개의 Service 리소스로 구성됨.

| 서비스 | 타입 | 용도 |
|---|---|---|
| `emqx-headless` | ClusterIP (None) | EMQX pod 간 DNS SRV 클러스터 디스커버리 전용 |
| `emqx` | ClusterIP | 클러스터 내부 pod(센서 데이터 수신 후 외부 서버 전달 서비스 등)의 EMQX 접근 전용 |
| `emqx-nodeport` | NodePort (`externalTrafficPolicy: Local`) | ESP32 등 외부 클라이언트 접근 전용. 공유기 포트포워딩 대상. |

`emqx-nodeport`에 `externalTrafficPolicy: Local` 설정이 필수임. 미설정 시 kube-proxy가 임의 pod로 DNAT하여, 공유기 포트포워딩 기반
failover(worker1 장애 시 worker2로 전환)가 무의미해짐.

`emqx` ClusterIP를 별도로 유지하는 이유: NodePort 서비스만 두면 내부 pod가 외부 경유 경로를 타게 되므로 내부 접근용 서비스를 분리함.

## 환경별 분리 필요 항목

| 항목 | dev (alpha cluster) | prod (edge) |
|------|-----|------|
| `EMQX_CLUSTER__DNS__NAME` | `emqx-headless.gikview.svc.alpha.nexus.local` | `emqx-headless.gikview.svc.cluster.local` |
| `EMQX_NODE__NAME` | `emqx@$(POD_NAME).emqx-headless.gikview.svc.alpha.nexus.local` | `emqx@$(POD_NAME).emqx-headless.gikview.svc.cluster.local` |
| `resources.requests.memory` | `384Mi` | `384Mi` |
| `resources.limits.memory` | `512Mi` | `512Mi` |
| `nodePortService.nodePorts.mqtt` | `31883` | `31883` |
| `nodePortService.nodePorts.mqtts` | `31884` | `31884` (NodePort 번호. 공유기는 외부포트 8883 → e-s2:31884, 8884 → e-s3:31884 로 포워딩 — `context/phases/edge-security.md` 참조) |
| `emqx-server-tls` Certificate `ipAddresses` (mTLS 서버 cert SAN) | dev EMQX 노드 IP들 | prod e-s2/e-s3 IP — 실제값의 정본은 `context/phases/edge-security.md` 의 emqx 서비스 (여기서 다시 적으면 stale 위험) |
