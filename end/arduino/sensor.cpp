#include "sensor.h"
#include <SoftwareSerial.h>
#include <ESP8266WiFi.h>
#include <time.h>

// 핀 설정
#define SENSOR_RX_PIN 13 
#define SENSOR_TX_PIN 14 

SoftwareSerial sensorSerial(SENSOR_RX_PIN, SENSOR_TX_PIN);

// 내부에서만 사용할 전역 변수
int currentOccupancy = 0; 

void setup_sensor() {
  sensorSerial.begin(9600);
}

// $DFHPD 문자열 파싱 내부 함수
static void parseSensorString(String data) {
  int firstComma = data.indexOf(',');
  int secondComma = data.indexOf(',', firstComma + 1);

  if (firstComma != -1 && secondComma != -1) {
    String presenceStr = data.substring(firstComma + 1, secondComma);
    presenceStr.trim();
    int newOccupancy = (presenceStr == "1") ? 1 : 0;

    if (newOccupancy != currentOccupancy) {
      currentOccupancy = newOccupancy;
      Serial.printf(">>> [Event] 상태 변경: %s (%d) <<<\n", 
                    (currentOccupancy ? "사람 있음" : "사람 없음"),  
                    currentOccupancy);
    }
  }
}

// 메인 루프에서 계속 호출되며 센서 값을 최신화하는 함수
void update_sensor() {
  // PC에서 입력한 명령어를 센서로 전달 (패스스루)
  if (Serial.available()) {
    sensorSerial.write(Serial.read());
  }

  // 버퍼에 들어온 센서 데이터 읽기
  while (sensorSerial.available() > 0) {
    String line = sensorSerial.readStringUntil('\n');
    line.trim();

    if (line.startsWith("$DFHPD")) {
      parseSensorString(line);
    } 
    else if (line.length() > 0 && !line.startsWith("$")) {
      Serial.println("Sensor Response: " + line);
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
    "{\"occupancy\":%d,\"timestamp\":\"%s\",\"bssid\":\"%s\",\"rssi\":%d}",
    read_occupancy(), ts, bssid.c_str(), rssi);
}