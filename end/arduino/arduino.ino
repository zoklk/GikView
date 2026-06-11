// ESP8266 ↔ gikview (step-ca 발급 + EMQX mqtts mTLS) — sketch entry.
//
// BOOTSTRAP   : /device-cert.pem 없고 /bootstrap-cert.pem 있음 → 발급 → reboot
// RENEW       : 만료 임박 → 갱신 → fallthrough op
// OPERATIONAL : EMQX mqtts → sensors/<cn>/occupancy publish
// FAIL        : 자산 부재 → 재플래시

#include "config.h"
#include "fs_store.h"
#include "stepca.h"
#include "mqtt_session.h"
#include "sensor.h"
#include "wifi_session.h"

#include <ESP8266WiFi.h>
#include <LittleFS.h>
#include <time.h>

enum Mode { MODE_BOOTSTRAP, MODE_RENEW, MODE_OPERATIONAL, MODE_FAIL };

static Mode decide_mode() {
  bool hasDev = LittleFS.exists(PATH_DEV_CERT);
  bool hasBs  = LittleFS.exists(PATH_BS_CERT);

  if (!hasDev && hasBs)  return MODE_BOOTSTRAP;
  if (!hasDev && !hasBs) {
    Serial.println("[mode] device cert / bootstrap 자산 모두 부재");
    return MODE_FAIL;
  }

  time_t now = time(nullptr);
  time_t exp = read_exp();

  if (exp == 0) {
    Serial.println("[mode] exp 파일 없음 — OPERATIONAL 시도");
    return MODE_OPERATIONAL;
  }
  if (now >= exp) {
    Serial.printf("[mode] cert 만료 (now=%lu exp=%lu)\n",
                  (unsigned long)now, (unsigned long)exp);
    return hasBs ? MODE_BOOTSTRAP : MODE_FAIL;
  }
  if (now + (time_t)RENEW_BEFORE_SEC >= exp) {
    Serial.printf("[mode] 갱신 윈도우 (만료 %lus 전)\n", (unsigned long)(exp - now));
    return MODE_RENEW;
  }
  return MODE_OPERATIONAL;
}

void setup() {
  Serial.begin(115200);
  delay(1500);

  // reboot 지터 시드 — getChipId 가 기기별로 달라 동시 reboot 시 위상 분산.
  randomSeed(ESP.getChipId() ^ micros());

  setup_sensor();

  Serial.printf("\n[init] heap=%d, reset=%s\n",
                ESP.getFreeHeap(), ESP.getResetReason().c_str());
  Serial.printf("[init] reset info: %s\n", ESP.getResetInfo().c_str());

  if (!LittleFS.begin()) {
    Serial.println("[init] LittleFS fail");
    return;
  }

  // BSSID 회전 연결 — 같은 SSID 의 AP 들을 RSSI 순으로 시도하되 각자 EMQX TCP probe
  // 로 상위망 도달성 검증. 강신호 dead AP (associate 되지만 인터넷 없음) 는 걸러내고
  // 살아있는 BSSID 에 락. 무한 retry 대신 bounded — 전부 실패 시 backoff 후 reboot.
  if (!wifi_connect_best()) {
    Serial.println("[wifi] 연결 가능한 BSSID 없음 — backoff 후 reboot");
    delay(WIFI_BACKOFF_REBOOT_MS + random(0, WIFI_REBOOT_JITTER_MS));
    ESP.restart();
  }
  Serial.printf("[wifi] connected IP=%s, heap=%d\n",
                WiFi.localIP().toString().c_str(), ESP.getFreeHeap());

  // X.509 validity / JWT iat·nbf·exp 검증에 필요.
  // NTP 도달 못 하면 영구 침묵 방지: 60s timeout 후 reboot.
  configTime(0, 0, "pool.ntp.org", "time.nist.gov");
  {
    uint32_t t0 = millis();
    while (time(nullptr) < 1700000000) {
      if (millis() - t0 > 60000) {
        Serial.println("\n[time] NTP timeout 60s — reboot");
        delay(2000);
        ESP.restart();
      }
      delay(500); Serial.print(".");
    }
  }
  Serial.println("\n[time] synced");

#if ENABLE_DIAG_STEPCA_PROBE
  probe_stepca_chain_only();
#endif

  Mode m = decide_mode();
  switch (m) {
    case MODE_BOOTSTRAP:
      Serial.println("[mode] BOOTSTRAP");
      // 센서 파라미터 설정은 cert TLS 전 (heap 깨끗할 때) 수행. UART 만 쓰고
      // 네트워크/cert 불필요. 직후 sensor_release() 로 SoftwareSerial 버퍼를
      // 반납해야 X5C 2회 핸드셰이크(heap 빡셈)에서 fragmentation OOM 안 남.
      provision_sensor();
      sensor_release();
      if (provision_cert(false)) {
        Serial.println("[boot] complete, rebooting...");
        delay(2000);
        ESP.restart();
      } else {
        // step-ca 일시 다운 / 네트워크 불안정 / whitelist rollout window 등 회복 가능 케이스
        // 대비 — 60s 후 reboot 으로 재시도. bootstrap 자산은 성공 후에만 삭제되므로
        // 다음 부팅에서 동일 흐름 재시도 가능.
        Serial.println("[boot] FAIL — 60s 후 reboot");
        delay(60000);
        ESP.restart();
      }
      break;

    case MODE_RENEW:
      Serial.println("[mode] RENEW");
      if (!provision_cert(true)) {
        Serial.println("[renew] FAIL — 옛 cert 로 OPERATIONAL 시도");
      }
      // fallthrough
    case MODE_OPERATIONAL:
      Serial.println("[mode] OPERATIONAL");
      setup_operational();
      break;

    case MODE_FAIL:
      Serial.println("[mode] FAIL — 재플래시 필요");
      break;
  }
}

void loop() {

  // 메인 루프 돌때마다 currentOccupancy 갱신
  // 시리얼 모니터에 입력하는 명령어도 센서로 전달
  update_sensor();

  static uint32_t last_pub = 0, last_chk = 0, last_log = 0;
  uint32_t now_ms = millis();

  // 운영 reconnect watchdog — mqtt 가 MQTT_DOWN_REBOOT_MS 동안 회복 못 하면 soft
  // reboot. 원인 무관 만능 회복: heap fragmentation 이면 clean heap 확보, dead-
  // upstream AP 면 부팅 probe 가 걸러 다음 BSSID 회전 (RTC blacklist 는 soft reboot
  // 생존). blacklist 는 부팅 probe 한 곳에서만 찍어 — heap 원인일 때 멀쩡한 BSSID 를
  // 오죽이는 false positive 방지. renew teardown 중엔 current_cn() 이 비어 미발동.
  // 상한은 config.h MQTT_DOWN_REBOOT_MS.
  static uint32_t mqtt_down_since = 0;
  if (mqtt_session_connected()) {
    mqtt_down_since = 0;
  } else if (current_cn()[0]) {
    if (mqtt_down_since == 0) {
      mqtt_down_since = now_ms ? now_ms : 1;
    } else if (now_ms - mqtt_down_since > MQTT_DOWN_REBOOT_MS) {
      Serial.printf("[loop] mqtt %lus 회복 실패 — soft reboot\n",
                    (unsigned long)((now_ms - mqtt_down_since) / 1000));
      delay(1000 + random(0, WIFI_REBOOT_JITTER_MS));
      ESP.restart();
    }
  }

  if (now_ms - last_log > 30000) {
    Serial.printf("[loop] heap=%d cn=%s\n",
                  ESP.getFreeHeap(),
                  current_cn()[0] ? current_cn() : "(none)");
    last_log = now_ms;
  }

  mqtt_session_loop();

  if (now_ms - last_pub > PUBLISH_INTERVAL_MS) {
    publish_occupancy();
    last_pub = now_ms;
  }

  if (now_ms - last_chk > RENEW_CHECK_INTV_MS) {
    last_chk = now_ms;
    // mqtt 끊긴 상태에서 renew 시도하면:
    //   1) step-ca 가 EMQX 와 같은 네트워크 → HTTPS 도 못 닿을 확률 높음
    //   2) 직전 reconnect 실패가 BearSSL alloc/free 로 heap fragmentation 남김
    //      → rekey 핸드셰이크 (~10KB 연속 alloc) OOM 위험
    // 연결 회복 우선 — 다음 RENEW_CHECK_INTV_MS (1h) 후 재검사.
    // 트레이드오프: renew window 전체 (7d) 동안 mqtt 회복 못 하면 cert 만료 → 사람 손.
    if (!mqtt_session_connected()) {
      Serial.println("[loop] mqtt 미연결 — renew 검사 스킵");
    } else {
      time_t exp = read_exp();
      if (exp != 0) {
        long until = (long)(exp - time(nullptr));
        Serial.printf("[loop] cert exp in %lds (renew window=%us)\n",
                      until, RENEW_BEFORE_SEC);
        if (until <= (long)RENEW_BEFORE_SEC) {
          Serial.println("[loop] 갱신 윈도우 진입 — teardown + provision_cert(renew)");
          // mqtt + BearSSL 객체가 ~7-8KB heap 잡고 있어 rekey 의 mTLS 핸드셰이크
          // (RX/TX 6KB + 추가 X509List/PrivateKey) alloc 이 실패. renew 동안 일시 해제.
          mqtt_session_teardown();
          bool renew_ok = provision_cert(true);
          if (renew_ok) {
            // rekey 핸드셰이크 직후의 holey heap 에 곧바로 EMQX mTLS 핸드셰이크를 또
            // 얹으면 fragmentation 으로 OOM (3KB alloc fail) 됨. bootstrap 처럼 reboot
            // 으로 clean heap 확보. 갱신은 운영에서 30d 주기라 publish 갭 무시 가능.
            Serial.println("[loop] renew OK — clean heap 위해 reboot");
            delay(2000);
            ESP.restart();
          }
          // 실패 시 옛 cert 가 LittleFS 에 그대로 남아있어 (원자적 rename) mqtt 재연결
          // 가능. 옛 cert 만료 직전이면 곧 EMQX handshake 거부되겠지만 그 사이까지는
          // publish 유지. reboot 하면 다시 RENEW 모드로 들어와 재시도 — 어느 쪽이든 OK.
          Serial.println("[loop] renew FAIL — 옛 cert 로 mqtt 회복 시도");
          setup_operational();
        }
      }
    }
  }

  delay(10);
}
