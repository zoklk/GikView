// config.example.h — config.h 의 템플릿. 굽기 전 이 파일을 config.h 로 복사한 뒤
// 환경 특정 값 (WiFi 자격증명 / step-ca·EMQX 호스트 IP·포트) 을 채운다.
// config.h 는 .gitignore 에 포함되어 commit 대상 아님.
#pragma once
#include <stdint.h>
#include <IPAddress.h>

// ── WiFi ────────────────────────────────────────────────────────────────
constexpr const char* WIFI_SSID = "";       // 환경에 맞춰 설정
constexpr const char* WIFI_PASS = "";

// ── step-ca / EMQX (공유기 외부 IP, 포트포워딩) ─────────────────────────
// IP connect → BearSSL server_name=NULL → SAN skip + Root CA chain 검증만.
// (lwIP DNS_LOCAL_HOSTLIST 가 ESP8266 코어에서 비활성화라 hostname connect 불가.)
constexpr const char* STEP_CA_HOST_IP = "";  // 공유기 외부 IP
constexpr int         STEP_CA_PORT    = 0;   // 외부 포트 → 노드 31900 포트포워딩

// EMQX 라운드 로빈: 2개 인스턴스 — 1차 실패 시 다음 슬롯으로 fallback.
// 같은 step-ca Root CA 체인이라 BearSSL trust anchor 공유.
struct EmqxEndpoint { const char* ip; int port; };
constexpr EmqxEndpoint EMQX_ENDPOINTS[] = {
  {"", 0},   // 1차 인스턴스 (공유기 외부 IP, NodePort 포트포워딩 포트)
  {"", 0},   // 2차 인스턴스
};
constexpr size_t EMQX_ENDPOINT_COUNT = sizeof(EMQX_ENDPOINTS) / sizeof(EMQX_ENDPOINTS[0]);

// ── step-ca API ─────────────────────────────────────────────────────────
constexpr const char* STEP_CA_SIGN_PATH    = "/1.0/sign";    // bootstrap (X5C JWT)
constexpr const char* STEP_CA_REKEY_PATH   = "/1.0/rekey";   // renew (mTLS, body=CSR only)
constexpr const char* STEP_CA_HEALTH_PATH  = "/health";
// JWT aud 의 fragment "#x5c/<prov>" 가 step-ca 의 X5C provisioner 매칭 키. base host 는 무관.
constexpr const char* STEP_CA_AUDIENCE_BASE = "https://step-ca.gikview.svc.cluster.local/1.0/sign";
constexpr const char* PROV_BOOTSTRAP        = "device-bootstrap";   // 1차 발급
constexpr const char* PROV_RENEWAL          = "device-renewal";     // 2차 발급 (provisioner-ext 전환)

// ── 인증서 수명 ─────────────────────────────────────────────────────────
// 1=테스트: body 에 notAfter 명시, 그 값을 save_exp 에 저장.
// 0=운영 : provisioner default 적용, 응답 leaf 에서 notAfter 파스.
//          운영 cert lifetime 은 bootstrap cert 잔여로 자동 클램프 (X5C forbiddenAfter).
//          bootstrap cert 30d 기준 운영 cert lifetime ≤ 30d.
#define LIFETIME_MODE_TEST_EXPLICIT 0

// CERT_LIFETIME_TEST_SEC: LIFETIME_MODE=1 일 때만 사용.
// RENEW_BEFORE_SEC: 모드 무관 공용. effective cert duration 보다 작아야 함.
constexpr uint32_t CERT_LIFETIME_TEST_SEC = 600;        // 10m
constexpr uint32_t RENEW_BEFORE_SEC       = 604800;     // 7d 전부터 갱신
constexpr uint32_t PUBLISH_INTERVAL_MS    = 5000;
constexpr uint32_t RENEW_CHECK_INTV_MS    = 3600000;    // 1h 간격 검사

// ── WiFi BSSID 회전 / 회복 watchdog (wifi_session.cpp, arduino.ino) ──────
// 동일 SSID 다중 AP 환경에서 dead-upstream AP (associate 되나 상위망 없음) 를
// 걸러내고 회복 불능(heap fragmentation / dead AP)을 reboot 로 푸는 상한들.
constexpr uint32_t WIFI_ASSOC_TIMEOUT_MS  = 8000;       // BSSID 1개 associate 상한
constexpr uint32_t WIFI_PROBE_TIMEOUT_MS  = 3000;       // EMQX TCP probe 상한
constexpr uint32_t WIFI_BACKOFF_REBOOT_MS = 30000;      // 전 BSSID 실패 후 reboot 전 backoff
constexpr uint32_t MQTT_DOWN_REBOOT_MS    = 300000;     // mqtt 회복 실패 → soft reboot (5m)
// reboot 전 [0, JITTER) 랜덤 추가 — 공유 EMQX 장애로 다수 기기가 동시 reboot →
// 복구 순간 mTLS 핸드셰이크 동시 폭주(thundering herd) 를 위상 분산으로 완화.
constexpr uint32_t WIFI_REBOOT_JITTER_MS  = 15000;

// ── 진단 토글 (운영=0, 디버깅=1) ──────────────────────────────────────
#define ENABLE_DIAG_STEPCA_PROBE 0   // step-ca /health 1회 probe
// EMQX endpoint TLS 핸드셰이크 단독 시도. mqtt.connect 가 ssl/mqtt 에러를
// state=-2 한 가지로 묶어버려 분리 진단용. 운영에선 핸드셰이크가 2배라
// heap fragmentation 가속 → renew 직후 OOM 위험. 디버깅 때만 1.
#define ENABLE_DIAG_TLS_PROBE    0

// ── 테스트 시나리오 ────────────────────────────────────────────────────
#define TEST_FOREIGN_TOPIC  0        // 남의 device 토픽 publish (ACL deny 기대)
constexpr const char* FOREIGN_DEVICE_ID = "device-ffffff";

// ── CN ─────────────────────────────────────────────────────────────────
// nullptr / "" 이면 MAC[3..5] 로 "device-XXXXXX" 자동 산출.
constexpr const char* DEVICE_CN_OVERRIDE = nullptr;

// ── MQTT ───────────────────────────────────────────────────────────────
constexpr const char* MQTT_TOPIC_FMT = "sensors/%s/occupancy";

// ── 센서 (C4001 mmWave, sensor.cpp) ────────────────────────────────────
// provision_sensor() 가 BOOTSTRAP 성공 직후 1회 적용 → 센서 자체 flash 에 영구저장.
// 평소 부팅엔 재적용 안 함. 값 변경 후 재적용하려면 device cert 지우고 재부팅(=재
// 부트스트랩) 또는 재플래시. 문자열로 둬서 명령 조립(setX A B)에 바로 붙음.
//   민감도 0~9 (낮을수록 둔감). latency on/off 초. 거리 m (max ≤ 20.0, min ≥ 0.3).
#define SENSOR_KEEP_SENS    "2"      // 유지 민감도 (있음 유지)
#define SENSOR_TRIG_SENS    "3"      // 트리거 민감도 (없음→있음)
#define SENSOR_LATENCY_ON   "0.1"    // 감지 응답 지연 (초)
#define SENSOR_LATENCY_OFF  "1.0"    // 사라진 뒤 유지 (초) — 작을수록 빨리 0
#define SENSOR_RANGE_MIN    "0.3"    // 최소 감지거리 (m) — 근거리 데드존
#define SENSOR_RANGE_MAX    "15.0"   // 최대 감지거리 (m) — 방 깊이
#define SENSOR_TRIG_RANGE   "15.0"   // 트리거 거리 (m) — 보통 max 와 동일

// ── LittleFS 경로 ──────────────────────────────────────────────────────
// 굽기 단계에 들어가는 자산: ca-cert.pem, bootstrap-cert.pem, bootstrap-key.pem.
// 정식 발급 후 device-* 가 생성되고 bootstrap-* 는 삭제됨.
constexpr const char* PATH_CA_CERT   = "/ca-cert.pem";
constexpr const char* PATH_BS_CERT   = "/bootstrap-cert.pem";
constexpr const char* PATH_BS_KEY    = "/bootstrap-key.pem";
constexpr const char* PATH_DEV_CERT  = "/device-cert.pem";
constexpr const char* PATH_DEV_CHAIN = "/device-chain.pem";
constexpr const char* PATH_DEV_KEY   = "/device-key.pem";
constexpr const char* PATH_DEV_EXP   = "/device-cert-exp";

// ── BearSSL TLS 버퍼 (mqtt_session.cpp 용) ─────────────────────────────
// EMQX 핸드셰이크 ~2KB + client cert chain ~1KB. heap fragmentation 환경에서
// 16KB 는 연속 alloc 실패 → OOM (ssl=-1000). 실제 필요량으로.
constexpr int TLS_RX_BUFFER = 4096;
constexpr int TLS_TX_BUFFER = 2048;

// ── step-ca rekey/sign HTTPS 버퍼 (stepca.cpp 용) ──────────────────────
// 운영 중 단편화 heap(~14KB) 핸드셰이크라 EMQX 보다 작게. EC P-256 서버 cert
// 체인 <1KB → RX 2048 충분. connect fail ssl= 뜨면 3072 로.
constexpr int STEPCA_RX_BUFFER = 2048;
constexpr int STEPCA_TX_BUFFER = 1024;
