// sensor — 센서 데이터 수집 + MQTT 페이로드 직렬화.
// 현재는 stub (occupancy=1 고정). 실제 센서 인터페이스 추가 시 read_occupancy() 만 변경.
#pragma once
#include <Arduino.h>

void setup_sensor();

void update_sensor();

// 0/1. stub.
int read_occupancy();

// JSON 페이로드 생성. caller-owned buffer.
//   {"occupancy":N,"timestamp":"YYYY-MM-DDThh:mm:ssZ","bssid":"aa:bb:cc:dd:ee:ff","rssi":-67}
// out 권장 160B. 반환 = 쓰인 길이.
size_t build_sensor_payload(char* out, size_t out_size);

#endif
