#include "crypto_pki.h"
#include "crypto_asn1.h"
#include "config.h"
#include <string.h>
#include <uECC.h>
extern "C" {
  #include <bearssl/bearssl_hash.h>
}

int rng_func(uint8_t* dest, unsigned size) {
  while (size) {
    uint32_t r = RANDOM_REG32;
    size_t n = size < 4 ? size : 4;
    memcpy(dest, &r, n);
    dest += n;
    size -= n;
    delayMicroseconds(1);
  }
  return 1;
}

size_t build_cri(uint8_t* out, const char* cn, const uint8_t* pub_xy) {
  static uint8_t buf[512];
  size_t p = 0;

  // version INTEGER 0
  buf[p++] = 0x02; buf[p++] = 0x01; buf[p++] = 0x00;

  // subject = SEQ OF SET OF SEQ { OID_CN, UTF8String CN }
  size_t cn_len = strlen(cn);
  static uint8_t inner[64];
  size_t ip = 0;
  memcpy(inner + ip, OID_CN, sizeof(OID_CN)); ip += sizeof(OID_CN);
  inner[ip++] = 0x0C;
  ip += asn1_len(inner + ip, cn_len);
  memcpy(inner + ip, cn, cn_len); ip += cn_len;

  static uint8_t set_buf[80], seq_buf[80];
  size_t seq_len = asn1_seq(seq_buf, inner, ip);
  size_t set_len = asn1_set(set_buf, seq_buf, seq_len);
  p += asn1_seq(buf + p, set_buf, set_len);

  // SPKI = SEQ { SEQ { OID_EC_PUBKEY, OID_P256 }, BIT STRING 00||04||X||Y }
  static uint8_t algo[32];
  size_t ap = 0;
  memcpy(algo + ap, OID_EC_PUBKEY, sizeof(OID_EC_PUBKEY)); ap += sizeof(OID_EC_PUBKEY);
  memcpy(algo + ap, OID_P256,      sizeof(OID_P256));      ap += sizeof(OID_P256);
  static uint8_t algo_seq[40];
  size_t algo_seq_len = asn1_seq(algo_seq, algo, ap);

  static uint8_t bs[68];
  bs[0] = 0x00; bs[1] = 0x04;
  memcpy(bs + 2, pub_xy, 64);
  static uint8_t bitstring[80];
  bitstring[0] = 0x03;
  size_t blen = asn1_len(bitstring + 1, 66);
  memcpy(bitstring + 1 + blen, bs, 66);
  size_t bs_total = 1 + blen + 66;

  static uint8_t spki[128];
  size_t sp = 0;
  memcpy(spki + sp, algo_seq, algo_seq_len); sp += algo_seq_len;
  memcpy(spki + sp, bitstring, bs_total);    sp += bs_total;
  p += asn1_seq(buf + p, spki, sp);

  // attributes [0] empty
  buf[p++] = 0xA0; buf[p++] = 0x00;

  return asn1_seq(out, buf, p);
}

size_t build_csr(uint8_t* out, const char* cn,
                 const uint8_t* pub_xy, const uint8_t* priv_d) {
  static uint8_t cri[512];
  size_t cri_len = build_cri(cri, cn, pub_xy);

  uint8_t hash[32];
  br_sha256_context ctx;
  br_sha256_init(&ctx);
  br_sha256_update(&ctx, cri, cri_len);
  br_sha256_out(&ctx, hash);
  yield();

  uint8_t sig_raw[64];
  if (!uECC_sign(priv_d, hash, 32, sig_raw, uECC_secp256r1())) return 0;
  yield();

  // ECDSA-Sig-Value = SEQ { INTEGER R, INTEGER S } → BIT STRING wrap
  static uint8_t r_int[40], s_int[40];
  size_t r_len = asn1_int(r_int, sig_raw,      32);
  size_t s_len = asn1_int(s_int, sig_raw + 32, 32);
  static uint8_t rs[80];
  memcpy(rs,         r_int, r_len);
  memcpy(rs + r_len, s_int, s_len);
  static uint8_t sig_seq[100];
  size_t sig_seq_len = asn1_seq(sig_seq, rs, r_len + s_len);

  static uint8_t sig_bs[110];
  sig_bs[0] = 0x00;
  memcpy(sig_bs + 1, sig_seq, sig_seq_len);
  static uint8_t sig_bitstring[120];
  sig_bitstring[0] = 0x03;
  size_t blen = asn1_len(sig_bitstring + 1, sig_seq_len + 1);
  memcpy(sig_bitstring + 1 + blen, sig_bs, sig_seq_len + 1);
  size_t sig_bs_total = 1 + blen + sig_seq_len + 1;

  static uint8_t algo_seq[20];
  size_t algo_seq_len = asn1_seq(algo_seq, OID_ECDSA_SHA256, sizeof(OID_ECDSA_SHA256));

  static uint8_t fi[700];
  size_t fp = 0;
  memcpy(fi + fp, cri,           cri_len);      fp += cri_len;
  memcpy(fi + fp, algo_seq,      algo_seq_len); fp += algo_seq_len;
  memcpy(fi + fp, sig_bitstring, sig_bs_total); fp += sig_bs_total;

  return asn1_seq(out, fi, fp);
}

size_t build_ec_priv_der(uint8_t* out, const uint8_t* priv_d, const uint8_t* pub_xy) {
  uint8_t buf[200];
  size_t p = 0;
  buf[p++] = 0x02; buf[p++] = 0x01; buf[p++] = 0x01;       // version 1
  buf[p++] = 0x04; buf[p++] = 0x20;                         // OCTET STRING(32) = priv
  memcpy(buf + p, priv_d, 32); p += 32;
  buf[p++] = 0xA0; buf[p++] = sizeof(OID_P256);             // [0] parameters
  memcpy(buf + p, OID_P256, sizeof(OID_P256)); p += sizeof(OID_P256);
  buf[p++] = 0xA1; buf[p++] = 68;                           // [1] publicKey
  buf[p++] = 0x03; buf[p++] = 66;
  buf[p++] = 0x00; buf[p++] = 0x04;
  memcpy(buf + p, pub_xy, 64); p += 64;
  return asn1_seq(out, buf, p);
}

bool ec_priv_from_der(const uint8_t* der, size_t der_len, uint8_t* priv_d) {
  // "04 20 <32B>" 패턴 첫 적중 = OCTET STRING(32) = priv scalar.
  for (size_t i = 0; i + 33 < der_len; i++) {
    if (der[i] == 0x04 && der[i+1] == 0x20) {
      memcpy(priv_d, der + i + 2, 32);
      return true;
    }
  }
  return false;
}

bool build_x5c_jwt(const char* cn, const char* provisioner,
                   const uint8_t* signer_cert_der, size_t signer_cert_len,
                   const uint8_t* signer_priv_d,
                   String& out_jwt) {
  static char cert_b64[800];
  base64_encode(signer_cert_der, signer_cert_len, cert_b64);

  static char header[1024];
  int hlen = snprintf(header, sizeof(header),
    "{\"alg\":\"ES256\",\"typ\":\"JWT\",\"x5c\":[\"%s\"]}", cert_b64);
  if (hlen <= 0) return false;

  // aud 의 "#x5c/<prov>" fragment 가 step-ca X5C provisioner 매칭 키 (LoadByToken).
  char aud[160];
  snprintf(aud, sizeof(aud), "%s#x5c/%s", STEP_CA_AUDIENCE_BASE, provisioner);

  time_t now = time(nullptr);
  uint32_t r0 = RANDOM_REG32, r1 = RANDOM_REG32;
  static char payload[512];
  int plen = snprintf(payload, sizeof(payload),
    "{\"iss\":\"%s\",\"sub\":\"%s\",\"aud\":\"%s\","
    "\"sans\":[\"%s\"],"
    "\"iat\":%lu,\"nbf\":%lu,\"exp\":%lu,"
    "\"jti\":\"%08lx%08lx\"}",
    provisioner, cn, aud,
    cn,
    (unsigned long)now, (unsigned long)now, (unsigned long)(now + 300),
    (unsigned long)r0, (unsigned long)r1);
  if (plen <= 0) return false;

  static char hdr_b64[1400], pl_b64[700];
  size_t hb_len = base64url_encode((const uint8_t*)header,  hlen, hdr_b64);
  size_t pb_len = base64url_encode((const uint8_t*)payload, plen, pl_b64);

  uint8_t hash[32];
  br_sha256_context ctx;
  br_sha256_init(&ctx);
  br_sha256_update(&ctx, hdr_b64, hb_len);
  br_sha256_update(&ctx, ".",     1);
  br_sha256_update(&ctx, pl_b64,  pb_len);
  br_sha256_out(&ctx, hash);
  yield();

  uint8_t sig_raw[64];
  if (!uECC_sign(signer_priv_d, hash, 32, sig_raw, uECC_secp256r1())) return false;
  yield();

  char sig_b64[100];
  base64url_encode(sig_raw, 64, sig_b64);

  out_jwt = String(hdr_b64) + "." + pl_b64 + "." + sig_b64;
  return true;
}

// ── leaf notAfter 파스 ─────────────────────────────────────────────────
// X.509 tbsCertificate walk: [0]version?, serial, sigAlg, issuer, validity, ...
// UTCTime  (tag 0x17): "YYMMDDhhmmssZ"        — YY 50-99→19YY, 00-49→20YY
// GeneralizedTime (tag 0x18): "YYYYMMDDhhmmssZ"
static int two_digits(const char* p) {
  if (p[0] < '0' || p[0] > '9' || p[1] < '0' || p[1] > '9') return -1;
  return (p[0] - '0') * 10 + (p[1] - '0');
}

static bool parse_x509_time(const uint8_t* val, size_t len, uint8_t tag,
                            struct tm* out) {
  if (tag == 0x17) {
    if (len < 13 || val[12] != 'Z') return false;
    int yy = two_digits((const char*)val);
    if (yy < 0) return false;
    out->tm_year = (yy >= 50 ? 1900 + yy : 2000 + yy) - 1900;
    int mo = two_digits((const char*)val + 2);
    int dd = two_digits((const char*)val + 4);
    int hh = two_digits((const char*)val + 6);
    int mi = two_digits((const char*)val + 8);
    int ss = two_digits((const char*)val + 10);
    if (mo < 0 || dd < 0 || hh < 0 || mi < 0 || ss < 0) return false;
    out->tm_mon  = mo - 1; out->tm_mday = dd;
    out->tm_hour = hh;     out->tm_min  = mi; out->tm_sec = ss;
    return true;
  } else if (tag == 0x18) {
    if (len < 15 || val[14] != 'Z') return false;
    int y1 = two_digits((const char*)val);
    int y2 = two_digits((const char*)val + 2);
    if (y1 < 0 || y2 < 0) return false;
    out->tm_year = (y1 * 100 + y2) - 1900;
    int mo = two_digits((const char*)val + 4);
    int dd = two_digits((const char*)val + 6);
    int hh = two_digits((const char*)val + 8);
    int mi = two_digits((const char*)val + 10);
    int ss = two_digits((const char*)val + 12);
    if (mo < 0 || dd < 0 || hh < 0 || mi < 0 || ss < 0) return false;
    out->tm_mon  = mo - 1; out->tm_mday = dd;
    out->tm_hour = hh;     out->tm_min  = mi; out->tm_sec = ss;
    return true;
  }
  return false;
}

// ESP8266 newlib 에 timegm 없음 — UTC tm → unix ts 직접 계산.
static time_t tm_to_unix_utc(const struct tm* t) {
  static const int month_days[] = {31,28,31,30,31,30,31,31,30,31,30,31};
  int year = t->tm_year + 1900;
  long days = 0;
  for (int y = 1970; y < year; y++) {
    days += 365;
    if ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) days += 1;
  }
  for (int m = 0; m < t->tm_mon; m++) {
    days += month_days[m];
    if (m == 1 && ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0)) days += 1;
  }
  days += t->tm_mday - 1;
  return (time_t)(days * 86400L + t->tm_hour * 3600L + t->tm_min * 60L + t->tm_sec);
}

bool parse_leaf_not_after(const char* leaf_pem, time_t* out_unix) {
  static uint8_t der[1024];
  size_t der_len = pem_to_der(leaf_pem, der, sizeof(der));
  if (der_len == 0) return false;

  const uint8_t* end = der + der_len;
  uint8_t tag;
  size_t len;
  const uint8_t* val;

  // outer SEQ { tbsCert, sigAlg, sig }
  const uint8_t* p = asn1_walk_next(der, end, &tag, &len, &val);
  if (!p || tag != 0x30) return false;
  end = val + len;
  p = val;

  // tbsCertificate SEQ
  p = asn1_walk_next(p, end, &tag, &len, &val);
  if (!p || tag != 0x30) return false;
  const uint8_t* tbs_end = val + len;
  const uint8_t* q = val;

  // [0] version 옵션 (있으면 skip)
  const uint8_t* q_peek = asn1_walk_next(q, tbs_end, &tag, &len, &val);
  if (!q_peek) return false;
  if (tag == 0xA0) q = q_peek;

  // serial / sigAlg / issuer 스킵
  q = asn1_walk_next(q, tbs_end, &tag, &len, &val);
  if (!q || tag != 0x02) return false;
  q = asn1_walk_next(q, tbs_end, &tag, &len, &val);
  if (!q || tag != 0x30) return false;
  q = asn1_walk_next(q, tbs_end, &tag, &len, &val);
  if (!q || tag != 0x30) return false;

  // validity SEQ { notBefore, notAfter }
  q = asn1_walk_next(q, tbs_end, &tag, &len, &val);
  if (!q || tag != 0x30) return false;
  const uint8_t* v_end = val + len;
  const uint8_t* r = val;

  r = asn1_walk_next(r, v_end, &tag, &len, &val);    // notBefore skip
  if (!r) return false;
  r = asn1_walk_next(r, v_end, &tag, &len, &val);    // notAfter
  if (!r) return false;

  struct tm t = {};
  if (!parse_x509_time(val, len, tag, &t)) return false;
  *out_unix = tm_to_unix_utc(&t);
  return true;
}
