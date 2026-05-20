#include "fs_store.h"
#include "config.h"
#include "crypto_asn1.h"     // base64_encode
#include <LittleFS.h>

void save_pem(const char* path, const char* label,
              const uint8_t* der, size_t der_len) {
  File f = LittleFS.open(path, "w");
  if (!f) { Serial.printf("[fs] save_pem fail: %s\n", path); return; }

  static char b64[1024];
  size_t b64_len = base64_encode(der, der_len, b64);

  f.printf("-----BEGIN %s-----\n", label);
  for (size_t i = 0; i < b64_len; i += 64) {
    size_t chunk = (b64_len - i < 64) ? (b64_len - i) : 64;
    f.write((const uint8_t*)(b64 + i), chunk);
    f.write('\n');
  }
  f.printf("-----END %s-----\n", label);
  f.close();
}

String read_file(const char* path) {
  File f = LittleFS.open(path, "r");
  if (!f) return String();
  String s = f.readString();
  f.close();
  return s;
}

void save_exp(time_t exp) {
  File f = LittleFS.open(PATH_DEV_EXP, "w");
  if (!f) return;
  f.print((unsigned long)exp);
  f.close();
}

time_t read_exp() {
  String s = read_file(PATH_DEV_EXP);
  if (s.length() == 0) return 0;
  return (time_t)strtoul(s.c_str(), nullptr, 10);
}
