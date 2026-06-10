# Architecture

> 이 디렉토리의 문서는 Claude(Anthropic)를 활용해 작성됨. 시각화 자료는 자체 제작.


## 전체 아키텍처

![overall architecture](images/gikview-overview.png)

## web
| 페이즈 | 범위 | 상태 | 문서 |
|---|---|---|---|
| backend | API Gateway WebSocket, Lambda, DynamoDB, OIDC authorizer | 작업 완료 | [backend.md](web/backend.md) |
| frontend | - | - | - |

## edge

| 페이즈 | 범위 | 상태 | 문서 |
|---|---|---|---|
| cicd | 로컬 하네스, Argo CD, GHCR | 작업 완료 | [cicd.md](edge/cicd.md) |
| messaging | EMQX, NodePort 노출 | 작업 완료 | [messaging.md](edge/messaging.md) |
| storage | InfluxDB | 작업 완료 | [storage.md](edge/storage.md) |
| security | step-ca, cert-manager, mTLS, EST-like | 작업 완료 | [security.md](edge/security.md) |
| pipeline | Edge Gateway, AWS Lambda, DynamoDB, API Gateway | 작업 완료 | [pipeline.md](edge/pipeline.md) |
| visibility | Prometheus, Alertmanager, Grafana, Discord 알림 | 진행 중 | [visibility.md](edge/visibility.md) |

## end

| 페이즈 | 범위 | 상태 | 세부 문서 |
|---|---|---|---|
| firmware | ESP8266 펌웨어 (부트스트랩, mTLS rekey, EMQX publish) | 작업 완료 | [firmware.md](end/firmware.md) |