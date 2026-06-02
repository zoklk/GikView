# Argo CD — 운영 매니페스트

App-of-Apps + 서비스별 Application. `root-app` 이 `apps/` 디렉토리 watch → 각 서비스 Application 자동 생성/동기화.

결정 사유: [docs/architecture/cicd.md](../../docs/architecture/cicd.md). 본 README 는 운영 절차만.

## 디렉토리

| 파일 | 역할 |
|---|---|
| `root-app.yaml` | parent App. `apps/` 디렉토리 1단계 watch (`recurse: false`). `automated.prune/selfHeal` 활성 — 자식 App 명세 변경 시 자동 적용 |
| `apps/<service>.yaml` | 서비스별 child Application. helm path = `edge/helm/<service>`, valueFiles = `values.yaml` + `values-prod.yaml`. sync-wave annotation 으로 ordering |

dev 클러스터: 별도 ArgoCD 인스턴스, 동일 `apps/` watch, valueFiles 만 `values-dev.yaml` 로 교체. 환경 분기 = valueFiles 단일 축.

## sync-wave 정본

본 README 가 wave 번호 정본. `apps/<service>.yaml` annotation 은 본 표 반영. 변경 시 본 표 먼저 수정 → 매니페스트.

| wave | phase | 서비스 | 비고 |
|---|---|---|---|
| `-3` | security | cert-manager | CRD 먼저 — 모든 후속 컴포넌트 의존 |
| `-3` | security | reloader | annotation 부착 워크로드 뜨기 전 활성화 필요 |
| `-2` | security | step-issuer | cert-manager CRD 의존, StepClusterIssuer 동시 선언 |
| `-1` | security | mapping-generator | init Job 완료돼야 다음 wave (`emqx-acl`/`step-ca-whitelist`/`telegraf-lookup` 사전 생성) |
| `0` | security | step-ca | initContainer 가 `step-ca-whitelist` 를 ca.json 머지 |
| `0` | storage | influxdb | post-install Job 으로 `gikview` database 자동 생성 |
| `1` | security | emqx | step-ca 다음, mTLS listener 전환 |
| `2` | pipeline | telegraf | cert 발급 + `telegraf-lookup` 마운트 |
| `2` | pipeline | edge-gateway | telegraf 병행 (상호 의존 없음), `device-room-mapping` 마운트 |

sync-wave = cluster 전역 ordering. phase 경계 무시 — `security:1` (emqx) 완료 → `pipeline:2` 진입. App-of-Apps 전체 sync 자동 정렬.

## 새 Application 추가

1. `edge/helm/<service>/` 차트 작성 (`Chart.yaml`, `values.yaml`, `values-prod.yaml`, `values-dev.yaml`, `templates/`).
2. `context/phases/<phase>.md` 에 서비스 spec + sync-wave 등록.
3. `edge/argocd/apps/<service>.yaml` 작성 — 기존 파일 (예: `mapping-generator.yaml`) 복사 후 `metadata.name`, `sync-wave`, `source.path` 만 교체.
4. git commit + push → root-app 이 자동 감지, child App 생성, wave 순서로 sync.

## 수동 동기화

자동 sync 비활성 (`cicd.md` 결정 2 — 의도치 않은 배포 차단). 운영자가 명시적 트리거:

```bash
# 단일 App
argocd app sync <service>

# 전체 (root → children)
argocd app sync root
```

`/deploy <phase> <service>` = verify → apply → verify 파이프라인. apply 단계가 위 명령 호출.

## 트러블슈팅 — App refresh 무한 실패

증상: `argocd app get <service>` 에서 `OutOfSync` 지속, ApplicationController 에러 로그.

- 매니페스트 문법 — `kubectl apply --dry-run=server -f apps/<service>.yaml` 로 사전 검증.
- 차트 렌더 — `helm template edge/helm/<service> -f edge/helm/<service>/values.yaml -f edge/helm/<service>/values-prod.yaml` 로 로컬 재현.
- 인프라 레벨 문제 (네트워크/Cilium): [docs/troubleshooting/260507_cilium-snat-issue](../../docs/troubleshooting/260507_cilium-snat-issue/README.md) 참조.
