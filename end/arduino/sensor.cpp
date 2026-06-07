#include "sensor.h"
#include "config.h"
#include <SoftwareSerial.h>
#include <ESP8266WiFi.h>
#include <time.h>
#include <string.h>

// 핀 설정
#define SENSOR_RX_PIN 13
#define SENSOR_TX_PIN 14

SoftwareSerial sensorSerial(SENSOR_RX_PIN, SENSOR_TX_PIN);

// 전역 변수 대신 static으로 선언
static int currentOccupancy = 0;

// static 버퍼 할당(최대 64 바이트)
#define RX_BUF_SIZE 64
static char rx_buffer[RX_BUF_SIZE];
static int rx_index = 0;

void setup_sensor() {
  sensorSerial.begin(9600);
}

// 센서 명령 1개 전송 + CRLF 종결 + wait_ms 동안 응답(Done/Error) 에코.
// 한 글자씩 흘리지 않고 원샷 전송 — RX 스트림 인터리브/종결자 누락 방지.
static void send_sensor_cmd(const char* cmd, uint32_t wait_ms) {
  sensorSerial.print(cmd);
  sensorSerial.print("\r\n");
  Serial.printf("[sensor cmd] %s\n", cmd);
  uint32_t t0 = millis();
  while (millis() - t0 < wait_ms) {
    while (sensorSerial.available() > 0) Serial.write(sensorSerial.read());
    delay(2);
  }
}

// config.h SENSOR_* 값으로 C4001 일괄 설정. 순서는 DFRobot_C4001 라이브러리와 동일:
// stop → set들 → saveConfig(1회) → start. saveConfig 가 센서 flash 에 영구저장하므로
// BOOTSTRAP 성공 직후 1회면 충분. start 후 $DFHPD 스트리밍 재개되어 update_sensor 정상.
void provision_sensor() {
  Serial.println("[sensor] provision 시작");
  send_sensor_cmd("sensorStop", 1200);     // stop 안정화 (라이브러리도 ~1s 대기)
  send_sensor_cmd("setSensitivity " SENSOR_KEEP_SENS " " SENSOR_TRIG_SENS, 300);
  send_sensor_cmd("setLatency "     SENSOR_LATENCY_ON " " SENSOR_LATENCY_OFF, 300);
  send_sensor_cmd("setRange "       SENSOR_RANGE_MIN " " SENSOR_RANGE_MAX, 300);
  send_sensor_cmd("setTrigRange "   SENSOR_TRIG_RANGE, 300);
  send_sensor_cmd("saveConfig", 500);      // flash 쓰기
  send_sensor_cmd("sensorStart", 300);
  Serial.println("[sensor] provision 완료");
}

void sensor_release() {
  sensorSerial.end();
  Serial.printf("[sensor] released, heap=%d\n", ESP.getFreeHeap());
}

// C-style 문자열 파싱 함수 (메모리 할당 없음)
static void parseSensorString(const char* data) {
  // 1. 첫 번째 콤마 찾기
  const char* firstComma = strchr(data, ',');
  if (!firstComma) return; // 콤마가 없으면 무시

  // 2. 두 번째 콤마 찾기
  const char* secondComma = strchr(firstComma + 1, ',');
  if (!secondComma) return; // 콤마가 없으면 무시

  // 3. 두 콤마 사이의 값을 확인 ('0' 또는 '1')
  // 공백이 포함되어 있을 수 있으므로 포인터를 이동하며 확인
  int newOccupancy = -1;
  for (const char* p = firstComma + 1; p < secondComma; ++p) {
    if (*p == '1') {
      newOccupancy = 1;
      break;
    } else if (*p == '0') {
      newOccupancy = 0;
      break;
    }
  }

  // 상태가 유효하고, 이전 상태와 다를 때만 업데이트
  if (newOccupancy != -1 && newOccupancy != currentOccupancy) {
    currentOccupancy = newOccupancy;
    Serial.printf(">>> [Event] 상태 변경: %s (%d) <<<\n",
                  (currentOccupancy ? "사람 있음" : "사람 없음"),
                  currentOccupancy);
  }
}

// 메인 루프에서 계속 호출되며 센서 값을 최신화하는 함수
void update_sensor() {
  // PC에서 입력한 명령어를 센서로 전달 (패스스루)
  if (Serial.available()) {
    sensorSerial.write(Serial.read());
  }

  // 문자열 없이 한 글자씩 정적 버퍼에 채워 넣기 (비차단)
  while (sensorSerial.available() > 0) {
    char c = sensorSerial.read();

    if (c == '\n') {
      // 줄바꿈을 만나면 문자열 끝에 널 문자(\0) 삽입
      rx_buffer[rx_index] = '\0';

      // 혹시 남아있을 수 있는 '\r' 제거
      if (rx_index > 0 && rx_buffer[rx_index - 1] == '\r') {
        rx_buffer[rx_index - 1] = '\0';
      }

      // 1. 데이터 패킷인지 확인 ($DFHPD 로 시작하는지)
      if (strncmp(rx_buffer, "$DFHPD", 6) == 0) {
        parseSensorString(rx_buffer);
      }
      // 2. 설정 응답(Done, Error)이나 부팅 메시지 출력
      else if (rx_index > 0 && rx_buffer[0] != '$') {
        Serial.printf("Sensor Response: %s\n", rx_buffer);
      }

      // 처리가 끝났으므로 인덱스를 초기화하여 버퍼 재사용
      rx_index = 0;
    }
    else {
      // 버퍼 오버플로우 방지: 널 문자 공간(1 byte)을 남기고 저장
      if (rx_index < RX_BUF_SIZE - 1) {
        rx_buffer[rx_index++] = c;
      }
    }
  }
}

// 외부에서 현재 상태를 가져갈 때 호출
int read_occupancy() {
  return currentOccupancy;
}

// 시간 포맷 변환 내부 함수
static void to_rfc3339_utc(time_t t, char* out, size_t out_size) {
  struct tm tm_utc;
  gmtime_r(&t, &tm_utc);
  strftime(out, out_size, "%Y-%m-%dT%H:%M:%SZ", &tm_utc);
}

// JSON 페이로드 생성 함수
size_t build_sensor_payload(char* out, size_t out_size) {
  char ts[32];
  to_rfc3339_utc(time(nullptr), ts, sizeof(ts));

  String bssid = WiFi.BSSIDstr();    // "aa:bb:cc:dd:ee:ff"
  int    rssi  = WiFi.RSSI();        // dBm

  return snprintf(out, out_size,
    "{\"occupied\":%s,\"timestamp\":\"%s\",\"bssid\":\"%s\",\"rssi\":%d}",
    read_occupancy() ? "true" : "false", ts, bssid.c_str(), rssi);
}