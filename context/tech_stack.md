# gikview — 기술 스택

이 프로젝트가 무엇으로 돌아가는지 한눈에. 항상 최신으로 유지하세요
— 새로 합류한 기여자(사람이든 에이전트든)가 무언가를 쓰기 전에
가장 먼저 읽을 문서입니다.

## 클러스터

- **Kubernetes 버전**: 1.34.3
- **배포판**: K3s
- **CNI**: cilium 1.19.2
- **Ingress 컨트롤러**: none

## 패키징

- **Helm**: v3.19.5 차트는 `edge/helm/<service>/` 아래에 둡니다.
- **컨테이너 런타임**: containerd. 이미지는 `config/harness.yaml` 의
  `conventions.registry` 로 push 됩니다.

## 하네스 의존 도구 (체크용)

별도로 설치해 두세요. CLI 는 바이너리가 없으면 `fail` 이 아니라
`skip` 으로 처리합니다:

- `yamllint` — 정적 YAML 위생 검사
- `helm` — 차트 lint, dry-run, 템플릿 렌더링
- `kubeconform` — k8s API 스키마 검증
- `trivy` — 차트 config 스캔 (선택)
- `gitleaks` — 시크릿 스캔 (선택)
- `hadolint` — Dockerfile lint
- `docker`, `kubectl` — 하네스 CLI 만 직접 호출

## 관측성

## 보안 태세

## 알려진 제약

