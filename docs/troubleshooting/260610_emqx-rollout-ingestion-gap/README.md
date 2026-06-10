# EMQX 롤링 재시작 중 소비자 구독 유실로 센서 적재 중단

> 이 디렉토리의 문서는 Claude(Anthropic)를 활용해 작성됨.

- 발생: 2026-06-10
- 상태: 문제 해결
- 관련: [visibility phase 설계](../../architecture/edge/visibility.md)

## 증상

모든 방의 센서 occupancy 데이터가 동시에 들어오지 않음. InfluxDB의 `occupancy` 테이블을 방별로 조회하면 마지막 수신 시각이 모두 같은 순간에서 멈춰 있고, age가 일제히 25분 이상으로 증가. 9개 기기가 우연히 같은 초에 멈출 확률은 없으므로 개별 센서 문제가 아니라 상류 공유 구간의 단일 장애로 판단.

조사 과정에서 가시성 지표 공백이 겹쳐 진단이 지연됨. 끊김을 즉시 알렸어야 할 SensorNoData 알림이 freshness 지표 부재로 발화하지 못해 수동 조사로 진입.

**환경**
- EMQX 5.8.6, 2-node StatefulSet (gikview NS), mqtts 8883, headless 클러스터링(DNS)
- 소비자: telegraf(적재용, Deployment 2 replica, shared subscription `$share/...`), edge-gateway(2 replica, shared subscription)
- 적재 경로: 센서(ESP8266) → EMQX → telegraf → InfluxDB 3 Core
- 트리거: argocd `targetRevision` dev→main 전환에 따른 EMQX 매니페스트 resync로 StatefulSet 롤

## 접근

### Approach 1 — 동시 정지 시그니처에서 상류 단일 장애 추적

- 동기: 전 방의 마지막 수신 시각이 같은 초(차이 3초 이내)에 멈춤. 개별 센서의 우연한 동시 정지는 불가능하므로 센서·기기보다 상류의 공유 구간(EMQX 또는 소비자) 단일 장애로 좁힘.
- 가설:
  - H1 개별 센서/기기 다운: **기각** (전 방 동일 순간 정지 = 우연 불가)
  - H2 EMQX 클러스터 split-brain: **기각** (`emqx ctl cluster status` 양 노드 모두 `running_nodes` 2개)
  - H3 EMQX 롤 재시작으로 소비자 구독이 복구되지 않음: **채택** (`emqx ctl clients list` 에서 telegraf·edge-gateway 가 `connected=true` 이나 `subscriptions=0`)
- 검증 명령:
  - `kubectl -n gikview get events --sort-by=.lastTimestamp` → 약 28분 전 emqx-1·emqx-0 순차 Killing + 재생성. 정지 시점과 일치.
  - 적재용 telegraf 로그 → `13:28:42`, `13:29:52` connection lost EOF 후 즉시 Connected. 재연결은 성공.
  - `emqx ctl clients list` → 센서는 connected, 적재 소비자 둘 다 `subscriptions=0`.
  - `emqx ctl cluster status` → 두 노드 running (split 아님).
- 종합 결론: readiness probe가 mqtts 포트의 TCP 연결만 확인했다. 포트가 열리면 즉시 Ready로 판정되지만 그 시점에 클러스터 재형성·라우팅이 끝나지 않았다. 소비자가 준비되지 않은 broker로 재연결하면서 보낸 SUBSCRIBE 가 수락된 듯 보이나 실제로는 유실되었다. 그 결과 센서 publish는 구독자가 없어 폐기되고 적재만 조용히 멈췄다. 연결 수 지표는 정상으로 보여 장애가 드러나지 않았다. 소비자 코드 자체는 재연결 시 재구독하도록 작성되어 있었으므로 원인은 소비자가 아니라 broker 의 미완성 Ready 판정.

### Approach 2 — 진단 지연 요인(freshness 지표 공백) 분석

- 동기: 끊김이 발생했는데 SensorNoData 알림이 뜨지 않아 자동 감지가 안 됨. 알림 경로 자체를 점검.
- 가설:
  - H1 freshness 지표를 노출하는 telegraf-freshness 쿼리 실패로 gauge 가 비어 알림이 평가되지 않음: **채택**
- 검증: telegraf-freshness 로그 + InfluxDB 로그에 `/api/v3/query_sql` 500 반복. 에러 본문 `Query would scan 432 Parquet files, exceeding the file limit`.
- 종합 결론: InfluxDB 3 Core 는 compaction 이 없어 Parquet 파일이 계속 누적된다. 시간 범위 제한 없는 풀스캔 쿼리는 파일 스캔 한도(기본 432)를 넘겨 500 으로 실패한다. freshness gauge 가 비면서 SensorNoData 가 평가되지 못했다. 즉 적재가 멈춘 1차 장애와, 그것을 감지했어야 할 가시성 지표가 비어 있던 2차 사각지대가 겹쳤다.

## 해결

즉시 조치:

- 적재용 telegraf 와 edge-gateway 를 재시작해 구독을 다시 맺음. 적재 즉시 재개.
- telegraf-freshness 쿼리에는 시간 범위 제한(`WHERE time > now() - interval '6 hours'`)이 이미 포함돼 있었으나 실행 중인 파드가 옛 설정으로 떠 있어 미반영. 재시작으로 해결.

재발 방지 — EMQX 무중단 롤 (`edge/helm/emqx`):

- readiness probe 를 TCP 확인에서 노드 상태 확인으로 변경. `emqx ctl status` 는 노드가 실제 기동된 경우에만 정상 종료하므로 포트만 열린 미완성 상태를 Ready 로 오판하지 않음.
- `minReadySeconds: 30` 을 두어 한 파드가 Ready 가 된 뒤 30초를 더 기다린 다음 다음 파드를 롤. 클러스터 정착·클라이언트 재연결 안정화 시간 확보.
- `updateStrategy: RollingUpdate` 명시로 한 번에 한 파드씩만 교체하도록 의도 고정.


안전망 — 알림 추가 (`edge/helm/prometheus` rule):

- `EMQXMessagesDropped`: `sum(rate(emqx_messages_dropped[5m])) > 0`. 구독자 없는 publish 폐기 = 이번 장애 직격.
- `EMQXNoIngress`: `sum(rate(emqx_messages_received[10m])) == 0`. 센서 유입 0 = 상류 끊김. freshness 보다 빠르고 직접적.

다음에는 연결 수가 정상으로 보여도 폐기율·유입률로 같은 장애를 즉시 감지한다.

## 남은 작업

- telegraf-freshness 의 6시간 윈도우는 Parquet 파일 누적률에 따라 다시 한도에 근접할 수 있어 파일 증가를 주기적으로 확인. 윈도우보다 오래 죽은 방은 결과에서 빠져 알림 사각지대가 되므로 방별 presence 추적 보강 필요.
