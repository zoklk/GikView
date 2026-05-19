// crypto_pki — X.509 도메인 로직 (CSR / X5C JWT / notAfter 파스) + RNG.
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <time.h>
#include <Arduino.h>

// uECC_set_rng() 에 등록. ESP8266 RANDOM_REG32 기반.
int rng_func(uint8_t* dest, unsigned size);

// CSR (PKCS#10) — CN 만 들어가는 단순 cert request, SAN extension 없음.
// SAN 은 step-ca 가 JWT payload "sans" 필드에서 가져감. pub_xy=64B, priv_d=32B. out ≥ 700B.
size_t build_cri(uint8_t* out, const char* cn, const uint8_t* pub_xy);
size_t build_csr(uint8_t* out, const char* cn,
                 const uint8_t* pub_xy, const uint8_t* priv_d);

// EC PRIVATE KEY DER (RFC 5915) ↔ priv_d (32B).
size_t build_ec_priv_der(uint8_t* out, const uint8_t* priv_d, const uint8_t* pub_xy);
bool   ec_priv_from_der  (const uint8_t* der, size_t der_len, uint8_t* priv_d);

// X5C JWT (ES256).
//   header  : {"alg":"ES256","typ":"JWT","x5c":["<b64(signer_cert_der)>"]}
//   payload : {iss=prov, sub=cn, aud=<STEP_CA_AUDIENCE_BASE>#x5c/<prov>, sans=[cn], iat/nbf/exp, jti}
bool build_x5c_jwt(const char* cn, const char* provisioner,
                   const uint8_t* signer_cert_der, size_t signer_cert_len,
                   const uint8_t* signer_priv_d,
                   String& out_jwt);

// X.509 tbsCertificate.validity.notAfter → unix ts.
// UTCTime / GeneralizedTime, "Z" timezone 만 지원 (step-ca 발급 cert 한정).
bool parse_leaf_not_after(const char* leaf_pem, time_t* out_unix);
