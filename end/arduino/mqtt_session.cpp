#include "mqtt_session.h"
#include "config.h"
#include "fs_store.h"
#include "sensor.h"

#include <ESP8266WiFi.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>

// X509List/PrivateKey 는 BearSSL 이 포인터로 보관 — secureClient 보다 수명 길어야.
static BearSSL::X509List*   s_ca_list    = nullptr;
static BearSSL::X509List*   s_dev_chain  = nullptr;
static BearSSL::PrivateKey* s_dev_key    = nullptr;
static WiFiClientSecure     s_secure;
static PubSubClient         s_mqtt(s_secure);
static char                 s_cn[32]     = {0};
static uint32_t             s_last_reconn = 0;

const char* current_cn() { return s_cn; }

static void derive_cn() {
  if (DEVICE_CN_OVERRIDE && DEVICE_CN_OVERRIDE[0]) {
    snprintf(s_cn, sizeof(s_cn), "%s", DEVICE_CN_OVERRIDE);
  } else {
    uint8_t mac[6];
    WiFi.macAddress(mac);
    snprintf(s_cn, sizeof(s_cn), "device-%02x%02x%02x", mac[3], mac[4], mac[5]);
  }
}

bool setup_operational() {
  // renew 후 재호출 — 기존 세션 닫기
  if (s_mqtt.connected()) {
    Serial.println("[op] disconnecting previous mqtt session");
    s_mqtt.disconnect();
  }

  String caPem    = read_file(PATH_CA_CERT);
  String certPem  = read_file(PATH_DEV_CERT);
  String chainPem = read_file(PATH_DEV_CHAIN);
  String keyPem   = read_file(PATH_DEV_KEY);
  if (caPem.length() == 0 || certPem.length() == 0 || keyPem.length() == 0) {
    Serial.println("[op] assets missing (ca/cert/key)");
    return false;
  }

  if (s_ca_list)   { delete s_ca_list;   s_ca_list   = nullptr; }
  if (s_dev_chain) { delete s_dev_chain; s_dev_chain = nullptr; }
  if (s_dev_key)   { delete s_dev_key;   s_dev_key   = nullptr; }

  s_ca_list = new BearSSL::X509List(caPem.c_str());

  // EMQX 5.8.6 partial_chain 미지원 → client 가 [leaf, intermediate] 둘 다 제시 필수.
  String fullChain = certPem + chainPem;
  s_dev_chain = new BearSSL::X509List(fullChain.c_str());
  s_dev_key   = new BearSSL::PrivateKey(keyPem.c_str());

  caPem = String(); certPem = String(); chainPem = String();
  keyPem = String(); fullChain = String();

  derive_cn();

  s_secure.setTrustAnchors(s_ca_list);
  s_secure.setSSLVersion(BR_TLS12, BR_TLS12);
  s_secure.setClientECCert(s_dev_chain, s_dev_key, 0xFFFF, 2);
  s_secure.setBufferSizes(TLS_RX_BUFFER, TLS_TX_BUFFER);

  // IPAddress connect → server_name=NULL → SAN skip, chain ✓.
  IPAddress emqx_ip;
  if (!emqx_ip.fromString(EMQX_HOST_IP)) {
    Serial.printf("[op] bad EMQX_HOST_IP: %s\n", EMQX_HOST_IP);
    return false;
  }

  Serial.printf("[op] pre-connect heap=%d, cn=%s, target=%s:%d\n",
                ESP.getFreeHeap(), s_cn, EMQX_HOST_IP, EMQX_PORT);

  // 1) TCP probe — TLS 전 도달성 격리
  {
    WiFiClient tcp;
    tcp.setNoDelay(true);
    uint32_t t = millis();
    bool tcp_ok = tcp.connect(emqx_ip, EMQX_PORT);
    Serial.printf("[op] TCP probe ok=%d, %lums\n", tcp_ok, millis() - t);
    tcp.stop();
    if (!tcp_ok) {
      Serial.println("[op] TCP fail — 포트포워딩 / EMQX listen 확인");
      return false;
    }
  }

  // 2) TLS probe — mTLS 핸드셰이크 단독 시도. PubSubClient 안에서 실패하면
  // BearSSL 에러가 mqtt.state=-2 한 가지로 묶여 분리 진단 어려움.
  Serial.printf("[op] direct TLS probe → %s:%d\n", EMQX_HOST_IP, EMQX_PORT);
  Serial.flush();
  uint32_t t_tls = millis();
  bool tls_ok = s_secure.connect(emqx_ip, EMQX_PORT);
  uint32_t tls_ms = millis() - t_tls;
  {
    char err[128];
    int code = s_secure.getLastSSLError(err, sizeof(err));
    Serial.printf("[op] direct TLS ok=%d, %lums, heap=%d, ssl=%d (0x%x): %s\n",
                  tls_ok, tls_ms, ESP.getFreeHeap(), code, code, err);
  }
  if (!tls_ok) {
    s_secure.stop();
    return false;
  }
  s_secure.stop();

  // 3) MQTT connect
  s_mqtt.setServer(emqx_ip, EMQX_PORT);
  Serial.printf("[op] mqtt.connect as %s\n", s_cn);
  Serial.flush();
  uint32_t t0 = millis();
  bool ok = s_mqtt.connect(s_cn);
  Serial.flush();
  Serial.printf("[op] mqtt.connect returned %lums ok=%d, heap=%d\n",
                millis() - t0, ok, ESP.getFreeHeap());

  if (!ok) {
    char err[128];
    int code = s_secure.getLastSSLError(err, sizeof(err));
    // PubSubClient state: -4=timeout, -3=conn_lost, -2=connect_failed,
    //                     -1=disconnected, 0=connected,
    //                      1=bad_protocol, 2=bad_id, 3=unavailable,
    //                      4=bad_credentials, 5=unauthorized
    Serial.printf("[op] ssl=%d (0x%x): %s | mqtt.state=%d\n",
                  code, code, err, s_mqtt.state());
  }
  return ok;
}

void publish_occupancy() {
  if (!s_mqtt.connected() || !s_cn[0]) return;

  char topic[64], payload[160];
  snprintf(topic, sizeof(topic), MQTT_TOPIC_FMT, s_cn);
  size_t plen = build_sensor_payload(payload, sizeof(payload));
  bool ok = s_mqtt.publish(topic, payload);
  // 페이로드 본문은 노출 안 함 (시리얼이 곧 평문 노출 채널). size + 결과만.
  Serial.printf("[pub] %s (%uB, ok=%d)\n", topic, (unsigned)plen, ok);

#if TEST_FOREIGN_TOPIC
  // QoS 0 라 ACL deny 되어도 client publish() 는 ok=1. 검증은 EMQX 로그.
  char ftopic[64];
  snprintf(ftopic, sizeof(ftopic), MQTT_TOPIC_FMT, FOREIGN_DEVICE_ID);
  bool fok = s_mqtt.publish(ftopic, payload);
  Serial.printf("[pub-foreign] %s (%uB, ok=%d)\n", ftopic, (unsigned)plen, fok);
#endif
}

void mqtt_session_teardown() {
  if (s_mqtt.connected()) {
    Serial.println("[op] tearing down mqtt session (renew prep)");
    s_mqtt.disconnect();
  }
  s_secure.stop();
  if (s_ca_list)   { delete s_ca_list;   s_ca_list   = nullptr; }
  if (s_dev_chain) { delete s_dev_chain; s_dev_chain = nullptr; }
  if (s_dev_key)   { delete s_dev_key;   s_dev_key   = nullptr; }
  // mqtt_session_loop 가 s_cn[0] 보고 재연결 시도하므로 teardown 동안엔 비워둠.
  s_cn[0] = 0;
  Serial.printf("[op] teardown done, heap=%d\n", ESP.getFreeHeap());
}

void mqtt_session_loop() {
  if (s_mqtt.connected()) {
    s_mqtt.loop();
    return;
  }
  if (!s_cn[0]) return;     // operational 미진입 — 재연결 안 함

  uint32_t now = millis();
  if (now - s_last_reconn < 5000) return;
  s_last_reconn = now;

  Serial.println("[loop] mqtt reconnect");
  s_mqtt.connect(s_cn);
}
