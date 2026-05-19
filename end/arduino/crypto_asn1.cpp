#include "crypto_asn1.h"
#include <string.h>

const uint8_t OID_EC_PUBKEY[9]     = {0x06,0x07,0x2A,0x86,0x48,0xCE,0x3D,0x02,0x01};
const uint8_t OID_P256[10]         = {0x06,0x08,0x2A,0x86,0x48,0xCE,0x3D,0x03,0x01,0x07};
const uint8_t OID_CN[5]            = {0x06,0x03,0x55,0x04,0x03};
const uint8_t OID_ECDSA_SHA256[10] = {0x06,0x08,0x2A,0x86,0x48,0xCE,0x3D,0x04,0x03,0x02};

// DER length: <128 = 1B, <256 = 0x81 + 1B, ≥256 = 0x82 + 2B.
size_t asn1_len(uint8_t* out, size_t len) {
  if (len < 128) { out[0] = (uint8_t)len; return 1; }
  if (len < 256) { out[0] = 0x81; out[1] = (uint8_t)len; return 2; }
  out[0] = 0x82; out[1] = (uint8_t)(len >> 8); out[2] = (uint8_t)(len & 0xFF);
  return 3;
}

size_t asn1_seq(uint8_t* out, const uint8_t* c, size_t cl) {
  out[0] = 0x30;
  size_t lb = asn1_len(out + 1, cl);
  memcpy(out + 1 + lb, c, cl);
  return 1 + lb + cl;
}

size_t asn1_set(uint8_t* out, const uint8_t* c, size_t cl) {
  out[0] = 0x31;
  size_t lb = asn1_len(out + 1, cl);
  memcpy(out + 1 + lb, c, cl);
  return 1 + lb + cl;
}

// high bit set 이면 unsigned 보정용 0x00 prefix.
size_t asn1_int(uint8_t* out, const uint8_t* val, size_t vl) {
  out[0] = 0x02;
  bool nz = (val[0] & 0x80) != 0;
  size_t il = vl + (nz ? 1 : 0);
  size_t lb = asn1_len(out + 1, il);
  if (nz) {
    out[1 + lb] = 0x00;
    memcpy(out + 1 + lb + 1, val, vl);
  } else {
    memcpy(out + 1 + lb, val, vl);
  }
  return 1 + lb + il;
}

const uint8_t* asn1_walk_next(const uint8_t* p, const uint8_t* end,
                              uint8_t* out_tag, size_t* out_len,
                              const uint8_t** out_val) {
  if (p >= end) return nullptr;
  uint8_t tag = *p++;
  if (p >= end) return nullptr;
  uint8_t l0 = *p++;
  size_t len;
  if ((l0 & 0x80) == 0) {
    len = l0;
  } else if (l0 == 0x81) {
    if (p >= end) return nullptr;
    len = *p++;
  } else if (l0 == 0x82) {
    if (p + 1 >= end) return nullptr;
    len = ((size_t)p[0] << 8) | p[1];
    p += 2;
  } else {
    return nullptr;
  }
  if (p + len > end) return nullptr;
  *out_tag = tag;
  *out_len = len;
  *out_val = p;
  return p + len;
}

static const char B64_STD[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static const char B64_URL[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

static size_t b64_encode_impl(const uint8_t* in, size_t in_len, char* out,
                              const char* abc, bool pad) {
  size_t op = 0;
  for (size_t i = 0; i < in_len; i += 3) {
    uint32_t v = ((uint32_t)in[i]) << 16;
    if (i + 1 < in_len) v |= ((uint32_t)in[i+1]) << 8;
    if (i + 2 < in_len) v |= in[i+2];
    out[op++] = abc[(v >> 18) & 0x3F];
    out[op++] = abc[(v >> 12) & 0x3F];
    if (i + 1 < in_len) out[op++] = abc[(v >> 6) & 0x3F];
    else if (pad)       out[op++] = '=';
    if (i + 2 < in_len) out[op++] = abc[v & 0x3F];
    else if (pad)       out[op++] = '=';
  }
  out[op] = 0;
  return op;
}

size_t base64_encode(const uint8_t* in, size_t in_len, char* out) {
  return b64_encode_impl(in, in_len, out, B64_STD, true);
}

size_t base64url_encode(const uint8_t* in, size_t in_len, char* out) {
  return b64_encode_impl(in, in_len, out, B64_URL, false);
}

static int b64_val(char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+' || c == '-') return 62;
  if (c == '/' || c == '_') return 63;
  return -1;
}

size_t base64_decode(const char* in, size_t in_len, uint8_t* out, size_t out_max) {
  size_t op = 0;
  uint32_t buf = 0;
  int bits = 0;
  for (size_t i = 0; i < in_len; i++) {
    int v = b64_val(in[i]);
    if (v < 0) continue;
    buf = (buf << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      if (op >= out_max) return 0;
      out[op++] = (buf >> bits) & 0xFF;
    }
  }
  return op;
}

size_t pem_to_der(const char* pem, uint8_t* out, size_t out_max) {
  const char* begin = strstr(pem, "-----BEGIN");
  if (!begin) return 0;
  const char* nl = strchr(begin, '\n');
  if (!nl) return 0;
  nl++;
  const char* end = strstr(nl, "-----END");
  if (!end) return 0;

  static char b64[1024];
  size_t bp = 0;
  for (const char* p = nl; p < end && bp < sizeof(b64) - 1; p++) {
    if (*p != '\n' && *p != '\r' && *p != ' ' && *p != '\t') b64[bp++] = *p;
  }
  return base64_decode(b64, bp, out, out_max);
}
