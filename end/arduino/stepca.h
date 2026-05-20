// stepca — step-ca /1.0/sign (bootstrap) + /1.0/rekey (renew) + /health probe.
#pragma once
#include <Arduino.h>

// 새 키페어 → CSR → step-ca 호출 → 원자적 LittleFS 저장.
//   bootstrap (renew_mode=false): /1.0/sign + X5C JWT (bootstrap cert 서명).
//                                  성공 시 bootstrap 자산 삭제.
//   renew     (renew_mode=true) : /1.0/rekey + mTLS (현 device cert/key 핸드셰이크).
bool provision_cert(bool renew_mode);

bool probe_stepca_chain_only();
