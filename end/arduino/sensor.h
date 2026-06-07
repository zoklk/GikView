// sensor — C4001 mmWave 점유 감지 + MQTT 페이로드 직렬화.
// SoftwareSerial 9600 으로 $DFHPD 프레임을 파싱해 occupancy(0/1) 갱신.
#pragma once
#include <Arduino.h>

void setup_sensor();

// config.h 의 SENSOR_* 값으로 C4001 파라미터 일괄 설정 (stop→set→saveConfig→start).
// BOOTSTRAP 시 cert 발급 전 1회 호출. saveConfig 로 센서 flash 영구저장.
void provision_sensor();

// SoftwareSerial 종료 — RX 버퍼 heap 반납 + $DFHPD ISR 중단.
// BOOTSTRAP 에서 provision 후 cert TLS 전에 호출 (heap 확보 + fragmentation 회피).
// 부트스트랩은 직후 reboot 하므로 안전. 재부팅 후 setup_sensor 가 다시 begin.
void sensor_release();

void update_sensor();

// 마지막으로 파싱된 점유 상태 (0=없음, 1=있음).
int read_occupancy();

// JSON 페이로드 생성. caller-owned buffer.
//   {"occupied":true,"timestamp":"YYYY-MM-DDThh:mm:ssZ","bssid":"aa:bb:cc:dd:ee:ff","rssi":-67}
// out 권장 160B. 반환 = 쓰인 길이.
size_t build_sensor_payload(char* out, size_t out_size);
