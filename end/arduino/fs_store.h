// fs_store — LittleFS wrapper. caller 가 LittleFS.begin() 먼저.
#pragma once
#include <Arduino.h>
#include <stdint.h>
#include <time.h>

// DER 를 표준 base64 + 64자 줄바꿈 PEM 으로 저장.
void save_pem(const char* path, const char* label,
              const uint8_t* der, size_t der_len);

String read_file(const char* path);

void   save_exp(time_t exp);     // PATH_DEV_EXP 에 unix ts 텍스트
time_t read_exp();
