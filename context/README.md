# context

> 이 디렉토리의 문서는 Claude(Anthropic)를 활용해 작성됨.

이 디렉토리는 두 역할을 겸한다.
(1) 하네스·에이전트가 무엇을 어디에 어떻게 배포할지 파악하는 **운영 컨텍스트**
(2) 각 컴포넌트가 무엇을 충족해야 하는지 정의하는 **개발 명세 SoT**.

## 디렉토리 구조

```
context/
├── README.md
├── conventions.md
├── tech_stack.md
├── phases/
│   ├── _template.md
│   ├── edge-messaging.md
│   ├── edge-pipeline.md
│   ├── edge-security.md
│   ├── edge-storage.md
│   ├── edge-visibility.md
│   ├── web-backend.md
│   ├── web-frontend.md
│   └── web-visibility.md
└── knowledge/
    ├── _template.md
    ├── alerting.md
    ├── aws-resources.md
    ├── cert-manager.md
    ├── cilium-l2.md
    ├── cloudflare-tunnel.md
    ├── emqx.md
    ├── front-back-spec.md
    ├── grafana.md
    ├── hubble.md
    ├── iam-roles-anywhere.md
    ├── influxdb.md
    ├── node-exporter.md
    ├── prometheus.md
    ├── reloader.md
    ├── step-ca.md
    ├── step-issuer.md
    └── telegraf.md
```

## conventions.md

모든 서비스에 공통 적용되는 정적 프로젝트 규약. 네임스페이스, 레이블, 릴리스 이름, 이미지 태그, 빌드 플랫폼 등. 실제 값의 SoT 는 `config/harness.yaml` 이고, 이 문서는 **왜** 그렇게 정했는지를 기록한다.

## tech_stack.md

클러스터·패키징·하네스 의존 도구의 현재 버전을 한눈에. 새 기여자(사람/에이전트)가 무언가 쓰기 전에 가장 먼저 읽는 문서.

## phases/

phase 는 일관된 작업 단위로, 한 phase 안의 service 들은 함께 배포·검증된다. `## Service: <name>` 헤딩이 곧 `edge/helm/<name>/`, `edge/docker/<name>/` 디렉토리명이고, `/deploy <phase> <service>` 가 phase 파일에서 이 헤딩을 매칭해 동작한다.

모노레포로 layer 가 섞이지만 디렉토리는 **평탄 구조**로 둔다. layer 구분은 파일명 prefix (`edge-`, `web-`) 로 한다. claude code command `/deploy` 가 단일 디렉토리에서 phase 파일을 찾기 때문이다. 새 phase 는 `_template.md` 복사로 시작한다.

## knowledge/

기술별·도메인별 운영 지식. phase 의 service 가 `**references**:` 로 가리키면 phase-spec-reader 가 자동 Read 하고, runtime-diagnoser 도 실패 진단 시 먼저 참조한다. 환경별 차이, 알려진 함정, 필수 비자명 설정이 여기 들어간다. 단일 기술별 작성이 기본이고, 다리소스 카탈로그형 (`aws-resources.md`) 은 예외다.

knowledge 의 환경별 값은 정본이 아니다. 실제값의 SoT 는 각 service 의 helm chart 또는 phase 문서다. 여기는 공통 형태와 함정만 둔다. 새 knowledge 는 `_template.md` 복사로 시작한다.
