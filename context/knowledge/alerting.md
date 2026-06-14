# alerting (Alertmanager + Discord) — 운영 지식 메모

---

## 이미지 / 버전

**채택**: `prom/alertmanager:v0.32.1` (`docker.io/prom/alertmanager`, 2026-04-29 릴리스, 2026-06-10 기준 최신 안정)

Prometheus가 평가한 alert를 받아 그룹화·중복제거·라우팅하고 Discord로 전송. **`discord_configs` receiver는 Alertmanager v0.25+에서 네이티브 지원** → 별도 webhook 어댑터 불필요 (v0.32.1은 충족). v0.25 미만이면 generic `webhook_configs` + 변환 프록시가 필요하므로 0.25 이상 핀이 중요.

`latest` 금지, 정확한 patch 핀. 업그레이드 시 릴리스 노트 확인.

Helm chart: 자체 작성 (`edge/helm/alertmanager/`).

## 주요 설정

alert rule은 Prometheus의 `rule_files`(operator 없음)로 두고, Alertmanager는 라우팅만 담당.

```yaml
# alertmanager.yml (ConfigMap)
route:
  group_by: ['alertname', 'room_id']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: discord-default
  routes:
    - matchers: [alertname="Watchdog"]   # 외부 dead-man's-switch (결정 9)
      receiver: healthchecks
      group_wait: 0s
      group_interval: 1m
      repeat_interval: 1m                 # 분단위 ping. 감지 지연은 healthchecks.io grace(5~10m)가 결정

receivers:
  - name: discord-default
    discord_configs:
      - webhook_url_file: /etc/alertmanager/secrets/discord-webhook   # Secret 마운트, git에 평문 금지
        # 메시지 템플릿은 title/message로 커스터마이즈 가능
  - name: healthchecks
    webhook_configs:
      - url_file: /etc/alertmanager/secrets-hc/healthchecks-url   # healthchecks.io ping URL, Secret (mountPath 분리)
        send_resolved: false                                   # 핑만 보냄 (resolved 불필요)

inhibit_rules:                 # NodeDown이면 그 노드 하위 컴포넌트 알림 억제 (노이즈 감소)
  - source_matchers: [alertname="NodeDown"]
    target_matchers: [severity="warning"]
    equal: ['instance']
```

```yaml
# values.yaml
extraSecretMounts:             # webhook URL은 Secret으로 주입
  - name: discord-webhook
    secretName: alertmanager-discord
    mountPath: /etc/alertmanager/secrets
    readOnly: true
  - name: healthchecks-url
    secretName: alertmanager-healthchecks
    mountPath: /etc/alertmanager/secrets-hc   # discord와 mountPath 분리 — 같은 경로면 키 충돌
    readOnly: true
```

### alert rule (Prometheus rule_files ConfigMap)

visibility.md의 관찰 목표를 alert로. 핵심만:

```yaml
groups:
  - name: gikview-visibility
    rules:
      - alert: SensorNoData                  # 결정 3 — 10분 무데이터
        expr: time() - gikview_sensor_last_seen_seconds > 600
        for: 1m
        labels: { severity: critical }
        annotations: { summary: "room {{ $labels.room_id }} 10분+ 무데이터" }

      - alert: CertExpirySoon                 # 결정 6 — cert 만료 임박
        expr: (certmanager_certificate_expiration_timestamp_seconds - time()) / 86400 < 7
        for: 5m
        labels: { severity: warning }

      - alert: EdgeGatewayAWSFailure          # 결정 6 — STS/PutItem 실패
        expr: increase(edge_gateway_dynamodb_putitem_total{result="error"}[10m]) > 0
              or increase(edge_gateway_sts_refresh_total{result="error"}[10m]) > 0
        labels: { severity: critical }

      - alert: InfluxDiskHigh                 # 결정 4 — SSD 용량
        expr: (1 - node_filesystem_avail_bytes{mountpoint=~"/mnt/ssd.*"} / node_filesystem_size_bytes) > 0.85
        for: 10m
        labels: { severity: warning }

      - alert: EtcdFsyncSlow                  # 결정 5 — fsync latency (260420 재발)
        expr: histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])) > 0.5
        for: 5m
        labels: { severity: critical }

      - alert: NodeDown
        expr: up{job="node-exporter"} == 0
        for: 2m
        labels: { severity: critical }

      - alert: EMQXACLDenySpike               # 결정 6 — 위조/부트스트랩 연결 시도
        expr: sum(increase(emqx_authorization_deny[10m])) > 0   # headless pod SD → 노드별 카운터 합산
        labels: { severity: warning }

      - alert: Watchdog                       # 상시 발화 — 외부 watchdog 하트비트 (결정 9)
        expr: vector(1)
        labels: { severity: none }
        annotations: { summary: "alerting pipeline heartbeat" }

      - alert: HubbleDropSpike                # 결정 9 — 네트워크 drop 급증 (선택)
        expr: sum(increase(hubble_drop_total[10m])) > <임계>
        for: 10m
        labels: { severity: warning }
```

## 알려진 주의사항

- **`discord_configs` 버전 의존**: Alertmanager v0.25 미만은 discord receiver 없음 → config 로드 실패. v0.25+ 핀 필수.

- **webhook URL 평문 노출**: Discord webhook URL은 그 자체가 인증 토큰. ConfigMap/values에 박으면 git 평문 노출. 반드시 Secret + `webhook_url_file`로 주입. 유출 시 Discord에서 webhook 재발급.

- **알림 폭풍**: `group_wait`/`group_interval`/`repeat_interval`을 너무 짧게 두면 같은 장애로 Discord rate limit. Discord webhook은 분당 요청 제한이 있어 30s/5m/4h 정도로 묶음. `inhibit_rules`로 상위 장애(NodeDown) 시 하위 노이즈 억제.

- **알림 파이프 자체 사각지대**: Alertmanager/Discord가 죽으면 alert가 전송 안 돼도 알 수 없음("조용함=정상"의 함정). Watchdog alert(상시 발화)를 `repeat_interval` 짧게(~1m) healthchecks.io ping URL로 전송, grace(~5-10m) 초과 시 healthchecks.io가 외부 통보 (visibility.md 결정 9). ping URL은 토큰성 → Secret 주입.

- **rule_files 미reload**: Prometheus가 rule ConfigMap 변경을 자동 감지하려면 `--web.enable-lifecycle` + reload 트리거(Reloader 또는 `/-/reload`) 필요. 없으면 룰 수정이 반영 안 됨.

- **`for` 누락 시 플래핑**: `for`가 없으면 한 번 임계 초과로 즉시 발화 → 일시 스파이크에 오탐. freshness/디스크 등은 `for`로 지속 조건.

## 환경별 분리 필요 항목

| 항목 | dev (alpha) | prod (edge) |
|------|-----|------|
| `nodeSelector` (node_category: monitoring) | `alpha-w2` | `e-s2` |
| `alertmanager-discord` Secret (webhook URL) | dev 채널 webhook | prod 채널 webhook |
| `alertmanager-healthchecks` Secret (ping URL) | dev check ping URL | prod check ping URL |

dev는 알림 노이즈를 줄이도록 `repeat_interval`을 더 길게 두거나 critical만 라우팅하는 것도 가능.
