# end

> 이 디렉토리의 문서는 Claude(Anthropic)를 활용해 작성됨.

ESP8266 펌웨어. 사람 감지 센서 데이터를 mTLS 로 broker 에 publish.

## 데이터 흐름

```
[end (ESP8266)]  →  edge (EMQX → Telegraf → InfluxDB)
                         (EMQX → edge-gateway)          →  web (DynamoDB)
```

step-ca 로 부트스트랩 후 mqtts 로 `sensors/<cn>/occupancy` publish.

## 디렉토리 구조

```
end/
├── README.md                개요 (본 문서)
├── arduino/                 Arduino sketch (sketch 폴더가 곧 sketch unit)
│   ├── arduino.ino          setup/loop, 모드 분기
│   ├── config.h             컴파일 상수 (WiFi, 호스트 IP, 토글, 센서 파라미터, LittleFS 경로)
│   ├── crypto_asn1.{h,cpp}  ASN.1 DER 빌드·디코드, Base64, PEM↔DER
│   ├── crypto_pki.{h,cpp}   RNG, CSR, X5C JWT, leaf notAfter 파스
│   ├── fs_store.{h,cpp}     LittleFS read/write wrapper
│   ├── stepca.{h,cpp}       /1.0/sign (bootstrap 2단계 발급), /1.0/rekey (mTLS)
│   ├── mqtt_session.{h,cpp} EMQX mqtts mTLS, publish, 재연결
│   ├── wifi_session.{h,cpp} BSSID 회전 연결 + EMQX probe (dead AP 회피), RTC blacklist
│   ├── sensor.{h,cpp}       C4001 mmWave 점유 감지·파싱, 파라미터 provision, 페이로드 직렬화
│   └── data/                LittleFS 자산 (ca-cert.pem, bootstrap-cert.pem, bootstrap-key.pem)
└── docs/                    end 범위 외 결정사항은 docs/architecture/end/firmware.md 참조
```

## 사전 준비

`arduino/config.example.h` 를 `arduino/config.h` 로 복사한 뒤 환경 특정 값 (WiFi, host IP/port) 을 채운다.

`arduino/data/` 에 다음 3개 파일을 배치한 후 LittleFS 로 업로드 한다.

| 파일 | 출처 |
|---|---|
| `ca-cert.pem` | step-ca Root CA 인증서 |
| `bootstrap-cert.pem` | 공통 bootstrap leaf (Bootstrap CA 가 서명) |
| `bootstrap-key.pem` | 위 cert 의 priv key (P-256, 평문 PEM) |

bootstrap cert 생성 절차는 [context/knowledge/step-ca.md](../context/knowledge/step-ca.md) 의 "오프라인 CA + provisioner 키 생성" 절 참조.

## 빌드 / 굽기

Arduino IDE 2.3+ 사용. 다음 라이브러리가 설치되어 있어야 한다.

- ESP8266 board package (BearSSL / LittleFS / ESP8266HTTPClient 포함)
- uECC (Kenneth MacKay)
- PubSubClient (Nick O'Leary)
- arduino-littlefs-upload v1.6.3+

빌드 옵션:

| 항목 | 값 |
|---|---|
| Board | NodeMCU 1.0 (ESP-12E) |
| lwIP Variant | v2 Lower Memory 또는 v2 Higher Bandwidth |
| Flash Size | 4MB (FS: 1MB) |

절차:

1. `arduino/data/` 에 인증서 자산 3개 배치
2. Arduino IDE → Tools → "Pick a different board and port" 로 NodeMCU 1.0 + 활성 COM 포트 선택
3. Tools → "LittleFS Data Upload" 로 인증서 자산 업로드
4. Sketch → Upload 로 펌웨어 굽기

## 동작

| 모드 | 진입 조건 | 흐름 |
|---|---|---|
| BOOTSTRAP | `/device-cert.pem` 없고 `/bootstrap-cert.pem` 있음 | 2단계 발급 (X5C device-bootstrap → device-renewal) → 센서 파라미터 1회 provision → reboot |
| RENEW | 정식 cert 만료 임박 (`RENEW_BEFORE_SEC` 이내) | `/1.0/rekey` mTLS → fallthrough OPERATIONAL |
| OPERATIONAL | 정식 cert 유효 | EMQX mqtts 연결, `PUBLISH_INTERVAL_MS` 마다 publish |
| FAIL | 인증서 자산 부재 | 멈춤. 펌웨어 재플래시 필요 |

부팅 → WiFi BSSID 선택 (각 BSSID associate 후 EMQX TCP probe 로 상위망 검증, 전부 실패 시 backoff reboot) → NTP 동기 (60s timeout, 실패 시 reboot) → 모드 분기. BOOTSTRAP 실패 시 60s 후 자동 reboot.

## WiFi 연결 / 회복

동일 SSID 다중 AP(다층 건물) 환경 대응. `wifi_session.{h,cpp}` + `arduino.ino` watchdog.

- 부팅 시 BSSID 를 RSSI 순으로 시도하되, associate 후 EMQX TCP probe 로 상위망 도달성 검증 → associate 만 되고 인터넷 없는 dead AP 를 걸러 회전.
- dead BSSID 는 RTC 에 blacklist (soft reboot 생존, 전원뽑기 소거). 전부 blacklist 면 비우고 재시도(영구 lockout 방지).
- 운영 중 mqtt 가 오래 못 붙으면 watchdog 가 soft reboot — heap 단편화·dead AP 원인 무관 회복. reboot 직전 랜덤 지터로 동시 reboot 폭주 분산.

설계 근거·미검증 항목: [docs/troubleshooting/260611_sensor-dropout-wifi-bssid-recovery](../docs/troubleshooting/260611_sensor-dropout-wifi-bssid-recovery/README.md)

## 센서 (C4001 mmWave)

DFRobot C4001 24GHz mmWave 점유 센서. SoftwareSerial 로 연결, `$DFHPD` 프레임을 파싱해 occupancy(0/1) 갱신.

| C4001 | ESP8266 (NodeMCU) | 비고 |
|---|---|---|
| TX | GPIO13 (D7) | 센서→ESP. TX↔RX 크로스 |
| RX | GPIO14 (D5) | ESP→센서 |
| VCC / GND | VIN(5V) / GND | 3.3~5.5V. 로직 3.3V (레벨시프터 불필요) |

센서 뒷면 DIP 스위치 = UART 방향. mmWave 는 비금속(플라스틱·석고보드) 투과하므로 불투명 케이스 안에 둬도 감지된다 (LED 빛 차단도 겸함 — 펌웨어로는 LED off 불가).

파라미터(`SENSOR_*`)는 BOOTSTRAP 성공 직후 `provision_sensor()` 가 1회 적용하고 **센서 자체 flash 에 영구저장**한다 (`setSensitivity`/`setLatency`/`setRange` → `saveConfig`). 평소 부팅엔 재적용 안 함. 값 변경 후 재적용하려면 device cert 를 지우고 재부팅(=재부트스트랩)하거나 재플래시한다.

## 설정 변경

`arduino/config.h` 가 모든 컴파일 상수의 단일 위치. 환경 변경 시 이 파일만 수정한다.

| 항목 | 운영 권장값 | 비고 |
|---|---|---|
| `WIFI_SSID` / `WIFI_PASS` | 환경에 맞춰 | |
| `STEP_CA_HOST_IP` / `STEP_CA_PORT` | 공유기 외부 IP / 9000 (포트포워딩) | |
| `EMQX_ENDPOINTS[]` | `{외부IP, 포트}` 슬롯 배열 | 라운드로빈 fallback (포트포워딩) |
| `LIFETIME_MODE_TEST_EXPLICIT` | `0` | 1=테스트 모드 (body 에 notAfter 명시) |
| `RENEW_BEFORE_SEC` | `604800` (7d) | effective cert duration 보다 작아야 함 |
| `RENEW_CHECK_INTV_MS` | `3600000` (1h) | |
| `WIFI_ASSOC_TIMEOUT_MS` | `8000` (8s) | BSSID 1개 associate 상한 |
| `WIFI_PROBE_TIMEOUT_MS` | `3000` (3s) | EMQX TCP probe 상한 |
| `WIFI_BACKOFF_REBOOT_MS` | `30000` (30s) | 전 BSSID 실패 후 reboot 전 backoff |
| `MQTT_DOWN_REBOOT_MS` | `300000` (5m) | mqtt 회복 실패 → soft reboot |
| `WIFI_REBOOT_JITTER_MS` | `15000` (15s) | reboot 전 랜덤 지터 (herd 분산) |
| `DEVICE_CN_OVERRIDE` | `nullptr` | nullptr 면 MAC[3..5] 자동 산출 |
| `SENSOR_KEEP_SENS` / `SENSOR_TRIG_SENS` | `2` / `3` | C4001 유지/트리거 민감도 0~9 (낮을수록 둔감) |
| `SENSOR_LATENCY_ON` / `SENSOR_LATENCY_OFF` | `0.1` / `1.0` | 감지 응답지연 / 사라진 뒤 유지 (초) |
| `SENSOR_RANGE_MIN` / `MAX` / `TRIG_RANGE` | `0.3` / `15.0` / `15.0` | 감지거리 (m, max ≤ 20) |
| `ENABLE_DIAG_STEPCA_PROBE` | `0` | 1=부팅 시 /health probe |

`LIFETIME_MODE_TEST_EXPLICIT` 와 `RENEW_BEFORE_SEC` 는 독립 설정이다. 토글 하나가 다른 하나를 결정하지 않는다.

## 관련 문서

- 시스템 전체: [docs/architecture/README.md](../docs/architecture/README.md)
- end 결정사항 (ADR): [docs/architecture/end/firmware.md](../docs/architecture/end/firmware.md)
- step-ca 운영 / X5C provisioner: [context/knowledge/step-ca.md](../context/knowledge/step-ca.md)
- security phase: [docs/architecture/edge/security.md](../docs/architecture/edge/security.md)
- messaging phase: [docs/architecture/edge/messaging.md](../docs/architecture/edge/messaging.md)
