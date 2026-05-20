// mqtt_session — EMQX mqtts mTLS 세션. trust=Root, client=leaf+inter+priv, IP connect.
#pragma once
#include <Arduino.h>

bool setup_operational();        // 자산 로드 + mTLS connect + mqtt connect
void mqtt_session_loop();        // mqtt.loop + 끊김 시 재연결
void publish_occupancy();        // 자기 토픽 publish (TEST_FOREIGN_TOPIC 시 foreign 도)
const char* current_cn();
bool mqtt_session_connected();   // 끊김/재연결 중인지 외부에서 확인 (renew gate 용)

// mqtt + BearSSL 객체 해제 → heap 회복. renew 의 mTLS rekey 핸드셰이크 전 호출.
// teardown 후 setup_operational() 재호출하면 새 cert chain 으로 재구성.
void mqtt_session_teardown();
