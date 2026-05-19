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
  Serial.printf("\n[init] heap=%d, reset=%s\n",
                ESP.getFreeHeap(), ESP.getResetReason().c_str());
  Serial.printf("[init] reset info: %s\n", ESP.getResetInfo().c_str());

  if (!LittleFS.begin()) {
    Serial.println("[init] LittleFS fail");
    return;
  }

  WiFi.mode(WIFI_STA);
  WiFi.disconnect(true);
  delay(200);

#if ENABLE_DIAG_WIFI_SCAN
  Serial.println("[wifi] scanning...");
  int n = WiFi.scanNetworks();
  Serial.printf("[wifi] %d AP found\n", n);
  for (int i = 0; i < n; i++) {
    Serial.printf("  %2d) %-32s RSSI=%d ch=%d enc=%d\n",
                  i, WiFi.SSID(i).c_str(),
                  WiFi.RSSI(i), WiFi.channel(i), WiFi.encryptionType(i));
  }
#endif

  WiFi.begin(WIFI_SSID, WIFI_PASS);
  while (WiFi.status() != WL_CONNECTED) { delay(500); Serial.print("."); }
  Serial.printf("\n[wifi] IP=%s, heap=%d\n",
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
  static uint32_t last_pub = 0, last_chk = 0, last_log = 0;
  uint32_t now_ms = millis();

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
        if (!renew_ok) {
          Serial.println("[loop] renew FAIL — 옛 cert 로 mqtt 회복 시도");
        }
        // 성공/실패 둘 다 setup_operational 재진입 — 실패 시 옛 cert 가 LittleFS 에
        // 그대로 남아있어 (원자적 rename) mqtt 재연결 가능. 옛 cert 만료 직전이면
        // 곧 EMQX handshake 거부되겠지만 그 사이까지는 publish 유지.
        setup_operational();
      }
    }
  }

  delay(10);
}
