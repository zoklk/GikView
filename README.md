# gikview

학내 공간 실시간 점유 가시화 IoT 시스템. ESP8266 mmWave 센서 → 온프레 K3s 수집/관측 → AWS 서버리스 웹으로 사용자에게 방 상태를 실시간 전달한다.

## 아키텍처

![overall architecture](docs/architecture/images/gikview-overview.png)

```
   end                 edge                                      web
ESP8266   →(mqtts)→   EMQX ─┬→ Telegraf → InfluxDB              (시계열)
(mmWave)                    └→ Edge Gateway → DynamoDB  →  API GW WS → React SPA
```

디바이스는 mTLS(step-ca PKI)로 EMQX 에 publish. EMQX share group 분리로 Telegraf 는 raw 시계열을 InfluxDB 에, Edge Gateway 는 상태 변경만 DynamoDB 에 쓴다. 웹은 DynamoDB Streams → Lambda → API Gateway WebSocket 으로 브라우저에 push.

## 레이어

| 레이어 | 역할 | 스택 | README |
|---|---|---|---|
| end | 센서 펌웨어 | ESP8266 / mTLS / C4001 mmWave | [end/README.md](end/README.md) |
| edge | 수집·PKI·관측 | 온프레 K3s, Helm/ArgoCD | [edge/README.md](edge/README.md) |
| web | 사용자 대면 실시간 | AWS 서버리스, React SPA | [web/README.md](web/README.md) |

## 재현 시작점

각 레이어 README 의 **"사전 작업" + "배포 / 실행"** 절을 따른다. 권장 순서: **edge**(PKI·broker 먼저) → **end**(디바이스 부트스트랩) → **web**(클라우드).

## 저장소 구조

```
end/        ESP8266 펌웨어
edge/       K3s 워크로드 (helm / docker / argocd / tests)
web/        AWS 서버리스 (backend Lambda / frontend SPA)
context/    구현 명세(SoT) + 기술 운영 지식 — phases/, knowledge/
docs/       아키텍처 결정(ADR) + 트러블슈팅
config/     하네스 설정 (harness.yaml)
harness/    배포 CLI (python -m harness)
```

## 문서

- **무엇을 만드나 / 어떻게 띄우나** → 각 레이어 README (위 표).
- **무엇을 충족해야 하나(명세)·기술 운영 지식** → `context/` (phases, knowledge).
- **왜 그렇게 결정했나(ADR)·장애 회고** → `docs/` (architecture, troubleshooting).
- **에이전트 운영 매뉴얼** → [AGENTS.md](AGENTS.md) / [CLAUDE.md](CLAUDE.md).
