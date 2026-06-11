// wifi_session — SSID 내 BSSID 회전 연결. 각 BSSID associate 후 EMQX TCP probe 로
// "상위망 도달성" 검증 — L2 붙어도 인터넷 없는 dead AP (예: 1층 강신호 AP 가 상위망
// 다운) 를 걸러 다음 BSSID 로 회전. WL_CONNECTED 만으론 거짓 양성이라 probe 가 진짜 게이트.
// dead BSSID 는 RTC user memory 에 기록되어 soft reboot 넘어 재선택 회피 (전원 끊김엔 소거).
#pragma once
#include <Arduino.h>

// SSID scan → 같은 SSID BSSID 들을 RSSI 내림차순 → 각자 associate(bounded) + EMQX
// TCP probe. 첫 통과 BSSID 에 락 후 true. 전부 실패(assoc timeout / 상위망 불통) 시
// false — caller 가 backoff/reboot 결정.
bool wifi_connect_best();
