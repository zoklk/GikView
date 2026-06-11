#include "wifi_session.h"
#include "config.h"

#include <ESP8266WiFi.h>
#include <string.h>

// 시간 상한은 config.h (WIFI_ASSOC_TIMEOUT_MS / WIFI_PROBE_TIMEOUT_MS). 아래는
// 내부 메모리 레이아웃 상수 — operator 튜너블 아님.
static constexpr int MAX_MATCH = 12;   // 같은 SSID BSSID 처리 상한 (스택 배열 크기)

// ── RTC blacklist (soft reboot 생존, 전원 끊김엔 garbage→magic 으로 리셋) ──
// eboot_command 가 RTC block 0..31 (128B) 점유 → user 영역은 block 32 부터.
static constexpr uint32_t RTC_MAGIC  = 0x42424C31;   // "BBL1"
static constexpr uint32_t RTC_OFFSET = 32;           // 4B 블록 단위
static constexpr int      BL_CAP     = 8;

struct Bl {
  uint32_t magic;
  uint32_t count;
  uint8_t  mac[BL_CAP][6];     // 4 + 4 + 48 = 56B (4의 배수, rtcUserMemory 요건)
};
static Bl s_bl;

static void bl_load() {
  ESP.rtcUserMemoryRead(RTC_OFFSET, (uint32_t*)&s_bl, sizeof(s_bl));
  if (s_bl.magic != RTC_MAGIC || s_bl.count > BL_CAP) {
    s_bl.magic = RTC_MAGIC;
    s_bl.count = 0;
  }
}
static void bl_save() {
  ESP.rtcUserMemoryWrite(RTC_OFFSET, (uint32_t*)&s_bl, sizeof(s_bl));
}
static bool bl_has(const uint8_t* mac) {
  for (uint32_t i = 0; i < s_bl.count; i++)
    if (!memcmp(s_bl.mac[i], mac, 6)) return true;
  return false;
}
static void bl_add(const uint8_t* mac) {
  if (bl_has(mac)) return;
  if (s_bl.count < BL_CAP) {
    memcpy(s_bl.mac[s_bl.count++], mac, 6);
  } else {
    // FIFO 밀어내기 — 가장 오래된 dead BSSID 폐기
    memmove(s_bl.mac[0], s_bl.mac[1], (BL_CAP - 1) * 6);
    memcpy(s_bl.mac[BL_CAP - 1], mac, 6);
  }
  bl_save();
}

// 상위망 도달성: EMQX 엔드포인트 중 하나라도 TCP 열리면 OK. mTLS/시계 불필요 —
// 순수 reachability 라 NTP 동기화 전(부팅 초기)에도 동작.
static bool probe_emqx() {
  for (size_t i = 0; i < EMQX_ENDPOINT_COUNT; i++) {
    IPAddress ip;
    if (!ip.fromString(EMQX_ENDPOINTS[i].ip)) continue;
    WiFiClient c;
    c.setTimeout(WIFI_PROBE_TIMEOUT_MS);
    c.setNoDelay(true);
    uint32_t t = millis();
    bool ok = c.connect(ip, EMQX_ENDPOINTS[i].port);
    c.stop();
    Serial.printf("[wifi] EMQX[%u] %s:%d probe ok=%d %lums\n",
                  (unsigned)i, EMQX_ENDPOINTS[i].ip, EMQX_ENDPOINTS[i].port,
                  ok, (unsigned long)(millis() - t));
    if (ok) return true;
  }
  return false;
}

bool wifi_connect_best() {
  bl_load();
  WiFi.persistent(false);
  WiFi.mode(WIFI_STA);
  WiFi.disconnect(true);
  delay(100);

  Serial.println("[wifi] scan...");
  int n = WiFi.scanNetworks();
  if (n <= 0) {
    Serial.printf("[wifi] scan empty (%d)\n", n);
    WiFi.scanDelete();
    return false;
  }

  // 같은 SSID 의 BSSID 인덱스만 추려 RSSI 내림차순 정렬
  int order[MAX_MATCH];
  int m = 0;
  for (int i = 0; i < n && m < MAX_MATCH; i++)
    if (WiFi.SSID(i) == WIFI_SSID) order[m++] = i;
  for (int a = 0; a < m; a++)
    for (int b = a + 1; b < m; b++)
      if (WiFi.RSSI(order[b]) > WiFi.RSSI(order[a])) {
        int t = order[a]; order[a] = order[b]; order[b] = t;
      }
  Serial.printf("[wifi] %d AP, %d match SSID\n", n, m);

  // escape hatch: 매칭된 BSSID 가 전부 blacklist 면 (EMQX 전체 다운으로 모든 AP 가
  // dead 처리된 상황) blacklist 를 비우고 재시도. 안 하면 EMQX 복구돼도 전 AP 가
  // 막혀 hard reset(전원 재인가) 전까지 영구 lockout. dead AP 는 어차피 이번 회전
  // 에서 다시 probe 실패로 걸러짐.
  bool all_bl = (m > 0);
  for (int k = 0; k < m; k++)
    if (!bl_has(WiFi.BSSID(order[k]))) { all_bl = false; break; }
  if (all_bl) {
    Serial.println("[wifi] 매칭 BSSID 전부 blacklist — 비우고 재시도");
    s_bl.count = 0;
    bl_save();
  }

  bool locked = false;
  for (int k = 0; k < m; k++) {
    int i = order[k];
    uint8_t bssid[6];
    memcpy(bssid, WiFi.BSSID(i), 6);   // scan 내부 버퍼 → 로컬 복사
    int ch   = WiFi.channel(i);
    int rssi = WiFi.RSSI(i);
    char mac[18];
    snprintf(mac, sizeof(mac), "%02x:%02x:%02x:%02x:%02x:%02x",
             bssid[0], bssid[1], bssid[2], bssid[3], bssid[4], bssid[5]);

    if (bl_has(bssid)) {
      Serial.printf("[wifi] skip blacklisted %s\n", mac);
      continue;
    }

    Serial.printf("[wifi] try %s ch=%d rssi=%d\n", mac, ch, rssi);
    WiFi.begin(WIFI_SSID, WIFI_PASS, ch, bssid, true);

    uint32_t t0 = millis();
    bool assoc = false;
    while (millis() - t0 < WIFI_ASSOC_TIMEOUT_MS) {
      if (WiFi.status() == WL_CONNECTED) { assoc = true; break; }
      delay(200); Serial.print(".");
    }
    Serial.println();
    if (!assoc) {
      Serial.printf("[wifi] %s assoc timeout\n", mac);
      WiFi.disconnect(true);
      continue;
    }

    Serial.printf("[wifi] %s assoc ok IP=%s — EMQX probe\n",
                  mac, WiFi.localIP().toString().c_str());
    if (probe_emqx()) {
      Serial.printf("[wifi] %s LOCKED (upstream ok), heap=%d\n",
                    mac, ESP.getFreeHeap());
      locked = true;
      break;
    }
    // associate 됐지만 EMQX 못 닿음 = 상위망 dead AP. blacklist + 회전.
    Serial.printf("[wifi] %s upstream DEAD — blacklist + 회전\n", mac);
    bl_add(bssid);
    WiFi.disconnect(true);
    delay(100);
  }

  WiFi.scanDelete();
  if (!locked) Serial.println("[wifi] 연결 가능한 BSSID 없음");
  return locked;
}
