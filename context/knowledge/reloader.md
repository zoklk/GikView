# reloader — 운영 지식 메모

---

## 이미지 / 버전

**채택**: `stakater/reloader:v1.4.16` (`ghcr.io/stakater/reloader:v1.4.16`)

cert-manager 가 Secret (TLS 인증서) 을 갱신할 때 마운트된 Pod 은 자동으로 reload 되지 않음 (TLS handshake 가 이미 완료된 MQTT/HTTP 연결은 새 인증서 인식 안 함). Reloader 는 Secret / ConfigMap 변경을 watch 하여 의존 Deployment/StatefulSet 의 rollout 을 자동 트리거.

본 프로젝트 적용 대상: EMQX (server cert), Edge Gateway (client cert), Telegraf (client cert) — 그리고 Mapping Generator 가 생성하는 `emqx-acl` / `step-ca-whitelist` / `telegraf-lookup` ConfigMap 변경 시 EMQX / step-ca / Telegraf rollout.

선택 근거: 자체 구현 대비 race condition / multi-Deployment 처리 검증된 K8s controller. 9 천+ GitHub star 의 운영 표준. 최신 안정 버전(`v1.4.16`, 2026-04, Go 1.26.2) 채택; chart(`2.2.11`)와 app(`v1.4.16`)이 별도 버전 체계라 둘 다 명시 — patch 라인(`v1.4.x`)이라 annotation 의미 · `watchGlobally` · `reloadStrategy` 동작 불변.

Helm chart: `stakater/reloader` chart `2.2.11` (repo: `https://stakater.github.io/stakater-charts`)

> chart version (`2.2.11`) 과 app version (`v1.4.16`) 이 분리. chart 만 업그레이드되는 패치도 있어 둘 다 명시 권장.

## 주요 설정

기본 동작은 모든 namespace 의 Deployment/StatefulSet/DaemonSet 을 watch. 본 프로젝트는 `gikview` namespace 한정으로 제한하여 권한 최소화.

```yaml
# edge/helm/reloader/values.yaml — 엄브렐라. stakater/reloader 서브차트가 자체적으로 모든 키를 top-level
# "reloader:" 아래 두므로, 의존성으로 끼면 reloader.reloader.* 로 이중 중첩됨.
reloader:
  reloader:
    watchGlobally: false            # 단일 namespace(gikview) 한정 → ClusterRole 대신 namespaced Role
    reloadOnCreate: true            # 새 ConfigMap/Secret 도 즉시 인식
    reloadStrategy: annotations      # default. env-vars 대비 안전
    readOnlyRootFileSystem: true     # /tmp emptyDir + 컨테이너 readOnlyRootFilesystem (trivy KSV-0014). 키 철자 그대로(FileSystem)
    deployment:
      # nodeSelector 는 values-<env>.yaml 의 reloader.reloader.deployment.nodeSelector 에서 설정
      resources:
        requests: { cpu: 10m, memory: 32Mi }
        limits:   { cpu: 100m, memory: 128Mi }
      containerSecurityContext:      # 차트 기본은 {} → trivy KSV-0001/0003/0004/0106
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
```

### Annotation 패턴

Reloader 는 Deployment 등의 annotation 으로 감시 대상 지정. 자동 감지 (`auto: "true"`) 와 특정 리소스 지정 (`reload: "<name>"`) 두 방식.

```yaml
# 예시: Edge Gateway Deployment
metadata:
  annotations:
    # 마운트된 Secret/ConfigMap 변경 시 모두 rollout
    secret.reloader.stakater.com/reload: "edge-gateway-tls"
    configmap.reloader.stakater.com/reload: "telegraf-lookup"
```

```yaml
# 예시: EMQX StatefulSet (여러 Secret/ConfigMap 동시)
metadata:
  annotations:
    secret.reloader.stakater.com/reload: "emqx-server-tls"
    configmap.reloader.stakater.com/reload: "emqx-acl"
```

```yaml
# 예시: step-ca (정책 변경 시 rollout)
metadata:
  annotations:
    configmap.reloader.stakater.com/reload: "step-ca-whitelist"
# step-ca 는 ca.json 을 hot-reload 못 함 → restart 시 initContainer 가 step-ca-whitelist 를
# ca.json 템플릿에 재머지 (결정 14번; rollout 트리거 메커니즘은 결정 15번).
# ⚠ step-ca StatefulSet 은 업스트림 step-certificates 차트가 워크로드 metadata annotation 훅을
#   안 노출 → 이 Reloader annotation 은 엄브렐라 post-render(kustomize) strategic-merge patch 로
#   부착 (대안 B = mapping-generator 가 rollout restart 직접 호출은 기각 — 상세는 결정 15번).
```

## 알려진 주의사항

- **annotation 누락 = 동작 안 함**: Reloader 가 설치되어도 Deployment 에 annotation 없으면 rollout 안 됨. 새 컴포넌트 배포 시 annotation 추가 누락이 가장 흔한 사고. helm chart template 에 annotation 을 강제로 박는 게 안전.

- **`auto: true` 의 부작용**: 마운트된 모든 Secret/ConfigMap 변경에 반응. 빈번히 갱신되는 다른 ConfigMap (예: 로그 레벨 변경) 도 rollout 트리거 → 의도치 않은 재시작. 본 프로젝트는 명시적 `reload: "<name>"` 패턴 권장.

- **rollout 중 일시 연결 끊김**: Reloader 가 Deployment 를 patch 하면 새 ReplicaSet 생성 → 기존 Pod 종료. EMQX 라면 MQTT 연결 일시 끊김 (수 초). ESP8266 Store-and-Forward + 재연결 로직으로 흡수. cert-manager 의 `renewBefore` 를 충분히 길게 두면 (본 프로젝트 30d) 비업무 시간대 갱신 스케줄링 가능.

- **RBAC 권한 범위**: `watchGlobally: false` 라도 cluster-scoped Role 이 필요 (Deployment patch). 단일 namespace 로 권한 제한하면 ClusterRole 대신 Role 사용 가능 (helm values 에서 분리 가능).

- **두 인스턴스 동시 실행 시 중복 rollout**: 같은 cluster 에 Reloader 가 2개 (예: 다른 namespace) 면 같은 Deployment 를 두 번 rollout 트리거. annotation 기반 분리 또는 단일 인스턴스 유지.

- **StatefulSet rolling update 전략**: EMQX StatefulSet 의 `updateStrategy.type: RollingUpdate` 일 때 Reloader 가 patch 하면 Pod 가 순차적으로 재시작. EMQX 클러스터는 active-active 라 1 Pod 단위로 끊겨도 메시지 손실 없음. `OnDelete` 전략이면 Pod 수동 삭제 필요 → 인증서 갱신 자동화 깨짐.

- **Reloader 자체 다운 시 rollout 없음**: Reloader Pod 가 죽으면 그 동안 Secret 갱신은 누적되지만 rollout 안 됨. 복구 시 직전 변경 1 회만 인식 (resource version 기반). single Pod 으로 운영하므로 Reloader 자체 healthcheck + Prometheus alert 권장 (visibility 단계).

- **dry-run / 검증 모드 없음**: 어떤 Deployment 가 rollout 될지 사전 확인 어려움. annotation 을 신중히 작성. 로그 (`Changes Detected in <name> ... Updated <deployment>`) 로 사후 확인.

## 환경별 분리 필요 항목

| 항목 | dev (alpha cluster) | prod (edge) |
|------|-----|------|
| `reloader.reloader.deployment.nodeSelector` | `kubernetes.io/hostname: alpha-w1` | `kubernetes.io/hostname: e-s1` |

namespace 스코핑은 별도 `namespaceSelector` 가 아니라 `reloader.reloader.watchGlobally: false`(공통값)가 담당 — 릴리즈 ns(`gikview`)만 watch.