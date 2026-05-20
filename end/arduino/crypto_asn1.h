// crypto_asn1 — ASN.1 DER 빌드/디코드 + Base64 + PEM↔DER. 저수준 레이어.
#pragma once
#include <stdint.h>
#include <stddef.h>

// ── ASN.1 DER 빌더 (out 에 인코딩 + 총 길이 반환) ────────────────────────
size_t asn1_len (uint8_t* out, size_t len);                          // length 필드
size_t asn1_seq (uint8_t* out, const uint8_t* content, size_t cl);   // SEQUENCE wrap
size_t asn1_set (uint8_t* out, const uint8_t* content, size_t cl);   // SET wrap
size_t asn1_int (uint8_t* out, const uint8_t* val, size_t vl);       // INTEGER (양수 보정)

// "06 <len> <bytes>" 형태로 인코딩된 OID — 다른 SEQ 안에 그대로 memcpy.
extern const uint8_t OID_EC_PUBKEY[9];
extern const uint8_t OID_P256[10];
extern const uint8_t OID_CN[5];
extern const uint8_t OID_ECDSA_SHA256[10];

// 한 ASN.1 element 읽기. out_val = value 시작, return = 다음 element 시작 (오류 시 nullptr).
// indefinite-length / 3B+ length 미지원 (X.509 에선 안 쓰임).
const uint8_t* asn1_walk_next(const uint8_t* p, const uint8_t* end,
                              uint8_t* out_tag, size_t* out_len,
                              const uint8_t** out_val);

// ── Base64 ─────────────────────────────────────────────────────────────
size_t base64_encode    (const uint8_t* in, size_t in_len, char* out);  // 표준 ('+/', pad)
size_t base64url_encode (const uint8_t* in, size_t in_len, char* out);  // url-safe ('-_', no pad)
size_t base64_decode    (const char* in, size_t in_len, uint8_t* out, size_t out_max);

// PEM 첫 BEGIN…END 한 블록 → DER. out_max 초과 시 0.
size_t pem_to_der(const char* pem, uint8_t* out, size_t out_max);
