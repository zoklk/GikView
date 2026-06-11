# 단일 센서 데이터 수신 중단 — 부팅 WiFi 무한 대기 + 운영 중 회복 불능

> 이 디렉토리의 문서는 Claude(Anthropic)를 활용해 작성됨.

- 발생: 2026-06-11
- 상태: 완화 조치 적용 (근본 원인 미확정, 현장 검증 대기)
- 관련: [none]

## 증상

여러 방 중 **한 방의 occupancy 데이터만** 수신 중단. 나머지 방은 정상 적재. 해당 센서(C4001 mmWave)는 물리 연결·전원 모두 정상. EMQX 연결 수가 **하나 감소**한 상태로 고정. 자동 복구는 일어나지 않음(기기 자동 reboot 없음). **전원 재인가(hard power cycle)** 시 즉시 정상 복구.

재현이 **확률적**이고, 기기 시리얼 로그를 원격 수집할 파이프라인이 없어 직접 관측이 불가. 따라서 코드 경로와 이전 사례(구관 1층 ap 불량)를 바탕으로 추론
**환경**
- end 기기: ESP8266 + DFRobot C4001 mmWave, LittleFS, BearSSL mTLS, PubSubClient
- 펌웨어 흐름: WiFi STA → NTP → step-ca cert 발급/갱신 → EMQX mqtts publish (`sensors/<cn>/occupancy`, 5s 주기)
- EMQX 접속: 라운드로빈 2 엔드포인트 (공유기 외부 IP, NodePort 포트포워딩)
- 무선 환경: 다층 건물, 동일 SSID 다중 AP(BSSID). 1층 AP 가 최강 신호이나 간헐적으로 "연결됨 + 상위망(인터넷) 없음" 관측 이력 존재

## 접근

### Approach 1 — EMQX 연결 -1 시그니처에서 센서단(레이더) 배제

- 동기: 한 방만 중단 + EMQX 연결 수 -1. 전 방 동시 정지([260610](../260610_emqx-rollout-ingestion-gap/README.md))와 대조되는 **단일 기기** 장애. 연결 수가 줄었다는 사실이 레이어를 가르는 핵심 단서.
- 가설:
  - H1 C4001 레이더 스트림 정지: **기각** — 레이더만 멈추면 ESP 는 EMQX 세션을 그대로 유지하므로 연결 수 불변이고, `publish_occupancy()` 는 마지막 `currentOccupancy` 값으로 계속 송신함. "연결 -1" 과 모순.
  - H2 ESP↔EMQX 세션 소실(TLS/MQTT 레이어): **채택** — 연결 수 감소 = 세션 끊김. 레이더가 아니라 ESP 의 네트워크/mTLS/mqtt 레이어.
- 검증: 코드 경로 확인. `sensor.cpp` 의 occupancy 갱신과 `mqtt_session.cpp` 의 publish 는 분리되어 있어, 레이더 무입력 상태에서도 publish 는 계속됨. 연결 수를 줄이는 것은 세션 끊김뿐.
- 종합 결론: 레이더/센서 데이터 문제가 아님. ESP 의 WiFi·mTLS·mqtt 레이어에서 단일 세션이 소실된 것. 진단 초점을 센서에서 ESP 네트워크 스택으로 이동.

### Approach 2 — 자동복구 부재(WDT 미발동)로 행 양상 좁히고 원인 후보 도출

- 동기: 장애 중 기기가 **자동 reboot 되지 않음**. ESP8266 은 SW WDT(~3s)·HW WDT(~8s)를 가지므로, 진짜 hard hang 이면 자동 reboot 됐어야 함. 안 됐다 = `loop()` 가 계속 돌며 connect 만 실패(=WDT 가 계속 먹이를 받음). 즉 tight hang 이 아니라 **회복 불능 상태로 헛도는** 형태.
- 가설:
  - H1 부팅 WiFi 무한 대기: **부분 기여** — `arduino.ino` 의 `while (WiFi.status() != WL_CONNECTED)` 폴링 루프에 timeout 부재. associate 실패 시 영구 정지(시리얼에 `.` 만 무한). 단 이는 부팅 경로 한정이며 "운영 중 정지" 와는 별개.
  - H2 dead-upstream AP 고착: **미확정 후보** — 최강 BSSID(1층)에 L2 association 은 유지되나 상위망이 죽어 mqtt 재연결 TCP 가 영구 실패. `WL_CONNECTED` 가 거짓 양성을 줌. 1층 AP 의 간헐 "상위망 없음" 실관측이 이를 뒷받침.
  - H3 heap fragmentation: **미확정 후보** — 재연결/handshake 반복으로 heap 이 조각나 BearSSL TLS alloc(연속 ~7-8KB)이 실패 → 재연결 영구 실패. crash 가 아니므로 WDT 미발동. uptime 누적에 따라 악화 = "잘 되다 갑자기" 양상과 부합. 코드 주석 곳곳이 이미 fragmentation 위험을 명시.
- 판별 한계: H2·H3 는 (전원 재인가로만 회복, 연결 -1, WDT 미발동) 외형이 동일. 시리얼 수집 부재 + 확률적 재현으로 직접 판별 불가. 또한 총 free heap(`ESP.getFreeHeap()`)은 단편화를 드러내지 못함(총량은 멀쩡, 최대 연속블록만 축소) → publish payload 로 heap 을 실어 보내는 telemetry 는 무의미하고 5s 상시 오버헤드만 추가.
- 종합 결론: 근본 원인은 H2·H3 중 미확정. 다만 두 후보 모두 "장시간 재연결 실패 후 회복 불능" 으로 수렴하고, 전원 재인가(=clean heap + RF 리셋)가 둘 다 해소함. 따라서 **원인 판별 없이 두 경우를 모두 덮는 회복 전략**으로 대응하기로 함.

## 해결

`end/arduino` 펌웨어 측 조치. 원인 판별에 의존하지 않고 두 후보를 모두 덮도록 설계.

**1. 부팅 WiFi 무한 대기 제거 + BSSID 회전 (`wifi_session.{h,cpp}` 신규)**

- scan → 동일 SSID 의 BSSID 들을 RSSI 내림차순 정렬 → 각 BSSID 를 핀 하여 associate(8s bound) 후 **EMQX 엔드포인트 TCP probe(3s)**.
- probe 는 L4 reachability 만 확인(cert/mTLS 무관, 시계 불필요). 상위망 도달성을 검증해, associate 는 되지만 EMQX 에 못 닿는 dead-upstream AP 를 걸러 다음 BSSID 로 회전.
- probe 실패 BSSID 는 RTC user memory 에 blacklist. **soft reboot 는 생존, hard reset(전원 재인가)에는 소거** — 사람이 전원을 뽑으면 전 BSSID 에 다시 기회.
- 전 BSSID 실패(전부 dead 또는 EMQX 불통) 시 30s backoff 후 reboot. 무한 retry 제거.
- 타이밍: BSSID 별 8s assoc + 3s×엔드포인트 probe 를 **순차** 수행, 전부 실패한 **이후** 30s backoff. 최악 ≈ `BSSID수 × (8s + 엔드포인트수×3s) + 30s`.

**2. 운영 reconnect watchdog (`arduino.ino` loop)**

- mqtt 가 5분간 재연결 실패하면 **soft reboot**. 원인 무관 만능 회복: heap 단편화면 clean heap 확보, dead AP 면 부팅 probe 가 그 AP 를 걸러 회전(RTC blacklist 가 soft reboot 를 넘어 유지).
- blacklist 는 **부팅 probe 한 곳에서만** 찍음 — heap 이 원인인데 BSSID 는 멀쩡한 경우 운영 watchdog 가 멀쩡한 BSSID 를 오죽이는 false positive 방지.
- renew teardown 중에는 `current_cn()` 이 비어 watchdog 미발동(오발 방지).

| 원인 | 덮는 메커니즘 |
|---|---|
| H1 부팅 assoc 무한 대기 | 8s bound × 회전 → 30s backoff reboot |
| H2 dead-upstream AP | watchdog reboot → 부팅 probe 가 회전 + blacklist |
| H3 heap fragmentation | watchdog reboot → clean heap (blacklist 안 찍음) |
| 초기 dead AP | 부팅 probe 회전 |

**3. 반복 reboot 안전장치**

- **escape hatch** (`wifi_session.cpp`): 매칭된 BSSID 가 전부 blacklist 면 비우고 재시도. EMQX **전체** 다운은 모든 AP 에서 probe 실패 → 전부 blacklist 되는데, RTC 가 soft reboot 를 넘어 유지되므로 EMQX 복구 후에도 전 AP 가 막혀 hard reset 전까지 영구 lockout 되는 것을 차단. dead AP 는 어차피 다음 회전에서 다시 걸러짐.
- **reboot 지터** (`WIFI_REBOOT_JITTER_MS`, `arduino.ino`): backoff·watchdog reboot 직전 `[0, 15s)` 랜덤 추가. 공유 EMQX 장애로 다수 기기가 동시 reboot → 복구 순간 mTLS 핸드셰이크 동시 폭주(thundering herd, EMQX CPU 압박)를 위상 분산으로 완화. 시드는 `ESP.getChipId()` 로 기기별 decorrelate.
- 무해: 일반 OPERATIONAL reboot 는 flash 미기록(cert·센서 saveConfig 는 BOOTSTRAP/renew 한정) → LittleFS·센서 flash wear 없음.

## 남은 작업

- **현장 검증 대기** — 확률적 재현이라 조치 적용 후 재발 여부로만 효과 확인 가능. 컴파일은 실기(arduino) 툴체인으로 별도 빌드 필요.
- **reboot storm 경계** — EMQX 전체 다운 시 기기가 reboot 를 반복함(escape hatch + 지터로 lockout·herd 는 완화). 장기 EMQX 장애에서 reboot 빈도 자체를 더 줄이려면 backoff 상향 검토. 서버측에서 해당 CN 의 connect/disconnect flapping 으로 감지 가능 — 알림은 [260610](../260610_emqx-rollout-ingestion-gap/README.md) 의 EMQX rule 옆에 추가 고려.
- 시간 상한(`WIFI_ASSOC_TIMEOUT_MS`/`WIFI_PROBE_TIMEOUT_MS`/`WIFI_BACKOFF_REBOOT_MS`/`MQTT_DOWN_REBOOT_MS`)은 템플릿 관례대로 `config.h`(config.example.h)에 모음 — 실기 `config.h` 동기화 필요.
