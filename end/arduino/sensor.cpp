#include "sensor.h"
#include <ESP8266WiFi.h>
#include <time.h>

int read_occupancy() {
  return 1;     // stub
}

static void to_rfc3339_utc(time_t t, char* out, size_t out_size) {
  struct tm tm_utc;
  gmtime_r(&t, &tm_utc);
  strftime(out, out_size, "%Y-%m-%dT%H:%M:%SZ", &tm_utc);
}

size_t build_sensor_payload(char* out, size_t out_size) {
  char ts[32];
  to_rfc3339_utc(time(nullptr), ts, sizeof(ts));

  String bssid = WiFi.BSSIDstr();    // "aa:bb:cc:dd:ee:ff"
  int    rssi  = WiFi.RSSI();        // dBm

  return snprintf(out, out_size,
    "{\"occupancy\":%d,\"timestamp\":\"%s\",\"bssid\":\"%s\",\"rssi\":%d}",
    read_occupancy(), ts, bssid.c_str(), rssi);
}
