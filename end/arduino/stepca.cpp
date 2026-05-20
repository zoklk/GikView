#include "stepca.h"
#include "config.h"
#include "crypto_asn1.h"
#include "crypto_pki.h"
#include "fs_store.h"

#include <ESP8266WiFi.h>
#include <WiFiClientSecure.h>
#include <LittleFS.h>
#include <uECC.h>

// step-ca 평탄 JSON 응답 ({"crt":"...","ca":"..."}) 단일 키 추출.
static String json_extract(const String& body, const char* key) {
  String needle = String("\"") + key + "\":\"";
  int s = body.indexOf(needle);
  if (s < 0) return String();
  s += needle.length();
  String out;
  out.reserve(800);
  for (int i = s; i < (int)body.length(); i++) {
    char c = body[i];
    if (c == '\\' && i + 1 < (int)body.length()) {
      char n = body[++i];
      if      (n == 'n')  out += '\n';
      else if (n == 'r')  out += '\r';
      else if (n == 't')  out += '\t';
      else if (n == '"')  out += '"';
      else if (n == '\\') out += '\\';
      else if (n == '/')  out += '/';
      else                out += n;
      continue;
    }
    if (c == '"') break;
    out += c;
  }
  return out;
}

static String der_to_pem_string(const uint8_t* der, size_t der_len, const char* label) {
  static char b64[1400];
  size_t b64_len = base64_encode(der, der_len, b64);
  String pem;
  pem.reserve(b64_len + 100);
  pem += "-----BEGIN "; pem += label; pem += "-----\n";
  for (size_t i = 0; i < b64_len; i += 64) {
    size_t chunk = (b64_len - i < 64) ? (b64_len - i) : 64;
    char tmp[66];
    memcpy(tmp, b64 + i, chunk);
    tmp[chunk] = '\n';
    tmp[chunk + 1] = 0;
    pem += tmp;
  }
  pem += "-----END "; pem += label; pem += "-----\n";
  return pem;
}

static void to_rfc3339_utc(time_t t, char* out, size_t out_size) {
  struct tm tm_utc;
  gmtime_r(&t, &tm_utc);
  strftime(out, out_size, "%Y-%m-%dT%H:%M:%SZ", &tm_utc);
}

// PEM CSR 을 JSON 문자열로 escape (LF → \n, " → \", \ → \\).
static void append_json_escaped(String& dst, const String& src) {
  for (size_t i = 0; i < src.length(); i++) {
    char c = src[i];
    if      (c == '\n') dst += "\\n";
    else if (c == '\r') { /* skip */ }
    else if (c == '"')  dst += "\\\"";
    else if (c == '\\') dst += "\\\\";
    else                dst += c;
  }
}

// raw HTTPS — IPAddress connect → server_name=NULL → SAN skip + Root chain ✓.
// client_chain/client_key 둘 다 non-null 이면 mTLS (rekey 경로).
static bool stepca_https(const char* method, const char* path,
                         const String& req_body,
                         BearSSL::X509List* client_chain,
                         BearSSL::PrivateKey* client_key,
                         int& out_status, String& out_resp_body) {
  out_status = 0;
  out_resp_body = String();

  String caPem = read_file(PATH_CA_CERT);
  if (caPem.length() == 0) {
    Serial.println("[https] PATH_CA_CERT missing");
    return false;
  }
  BearSSL::X509List caList(caPem.c_str());

  WiFiClientSecure cli;
  cli.setTrustAnchors(&caList);
  cli.setSSLVersion(BR_TLS12, BR_TLS12);
  cli.setBufferSizes(4096, 2048);
  if (client_chain && client_key) {
    cli.setClientECCert(client_chain, client_key, 0xFFFF, 2);
  }
  caPem = String();

  IPAddress ip;
  if (!ip.fromString(STEP_CA_HOST_IP)) {
    Serial.printf("[https] bad ip: %s\n", STEP_CA_HOST_IP);
    return false;
  }

  Serial.printf("[https] %s %s → %s:%d, heap=%d%s\n",
                method, path, STEP_CA_HOST_IP, STEP_CA_PORT, ESP.getFreeHeap(),
                (client_chain ? " (mTLS)" : ""));
  uint32_t t0 = millis();
  if (!cli.connect(ip, STEP_CA_PORT)) {
    char err[128];
    int code = cli.getLastSSLError(err, sizeof(err));
    Serial.printf("[https] connect fail %lums, ssl=%d (0x%x): %s\n",
                  millis() - t0, code, code, err);
    return false;
  }
  Serial.printf("[https] connected %lums, heap=%d\n", millis() - t0, ESP.getFreeHeap());

  cli.print(method);
  cli.print(' ');
  cli.print(path);
  cli.print(" HTTP/1.1\r\n");
  cli.printf("Host: %s:%d\r\n", STEP_CA_HOST_IP, STEP_CA_PORT);
  cli.print("Connection: close\r\n");
  if (req_body.length() > 0) {
    cli.print("Content-Type: application/json\r\n");
    cli.printf("Content-Length: %u\r\n", (unsigned)req_body.length());
  }
  cli.print("\r\n");
  if (req_body.length() > 0) cli.print(req_body);

  uint32_t t_resp = millis();
  while (!cli.available() && cli.connected() && millis() - t_resp < 10000) {
    delay(10);
    yield();
  }
  if (!cli.available()) {
    Serial.printf("[https] response timeout %lums\n", millis() - t_resp);
    cli.stop();
    return false;
  }

  String status_line = cli.readStringUntil('\n');
  status_line.trim();
  int sp1 = status_line.indexOf(' ');
  if (sp1 < 0) {
    Serial.printf("[https] bad status line: %s\n", status_line.c_str());
    cli.stop();
    return false;
  }
  out_status = status_line.substring(sp1 + 1, sp1 + 4).toInt();
  Serial.printf("[https] status=%d\n", out_status);

  size_t content_length = 0;
  while (cli.connected() || cli.available()) {
    String line = cli.readStringUntil('\n');
    line.trim();
    if (line.length() == 0) break;
    if (line.startsWith("Content-Length:") || line.startsWith("content-length:")) {
      content_length = line.substring(line.indexOf(':') + 1).toInt();
    }
  }

  out_resp_body.reserve(content_length + 16);
  if (content_length > 0) {
    while (out_resp_body.length() < content_length) {
      if (cli.available()) {
        out_resp_body += (char)cli.read();
      } else if (!cli.connected()) {
        break;
      } else {
        delay(5);
        yield();
      }
    }
  } else {
    uint32_t t_b = millis();
    while ((cli.connected() || cli.available()) && millis() - t_b < 10000) {
      while (cli.available()) out_resp_body += (char)cli.read();
      delay(5);
      yield();
    }
  }

  cli.stop();
  Serial.printf("[https] body=%uB, heap=%d\n",
                (unsigned)out_resp_body.length(), ESP.getFreeHeap());
  return true;
}

// ── /1.0/sign — bootstrap / 2차 발급 (X5C JWT) ────────────────────────
// signer_not_after = 0 이면 클램프 안 함. >0 이면 새 cert notAfter 를 signer
// notAfter - 60s 로 클램프 (X5C forbiddenAfter 정책 우회).
static bool step_ca_sign(const String& csr_pem, const String& jwt,
                         time_t signer_not_after,
                         String& out_leaf, String& out_inter,
                         time_t& out_not_after) {
#if LIFETIME_MODE_TEST_EXPLICIT
  time_t expires = time(nullptr) + (time_t)CERT_LIFETIME_TEST_SEC;
  if (signer_not_after > 0 && expires > signer_not_after - 60) {
    expires = signer_not_after - 60;
    Serial.printf("[sign] clamped notAfter to signer expiry - 60s\n");
  }
  char rfc3339[32];
  to_rfc3339_utc(expires, rfc3339, sizeof(rfc3339));
  out_not_after = expires;
  Serial.printf("[sign] notAfter (explicit): %s\n", rfc3339);
#endif

  // step-ca SignRequest 의 Go json tag: "csr", "ott", "notAfter".
  String body;
  body.reserve(csr_pem.length() + jwt.length() + 96);
  body += "{\"csr\":\"";
  append_json_escaped(body, csr_pem);
  body += "\",\"ott\":\"";
  body += jwt;
  body += "\"";
#if LIFETIME_MODE_TEST_EXPLICIT
  body += ",\"notAfter\":\"";
  body += rfc3339;
  body += "\"";
#endif
  body += "}";

  int status = 0;
  String resp;
  if (!stepca_https("POST", STEP_CA_SIGN_PATH, body, nullptr, nullptr, status, resp)) {
    Serial.println("[sign] request fail (transport)");
    return false;
  }
  if (status != 200 && status != 201) {
    Serial.printf("[sign] status=%d, body: %s\n", status, resp.c_str());
    return false;
  }

  out_leaf  = json_extract(resp, "crt");
  out_inter = json_extract(resp, "ca");
  if (out_leaf.length() == 0) {
    Serial.printf("[sign] crt missing: %s\n", resp.c_str());
    return false;
  }

#if !LIFETIME_MODE_TEST_EXPLICIT
  if (!parse_leaf_not_after(out_leaf.c_str(), &out_not_after)) {
    Serial.println("[sign] parse_leaf_not_after fail");
    return false;
  }
  Serial.printf("[sign] notAfter (parsed): %lu\n", (unsigned long)out_not_after);
#endif

  Serial.printf("[sign] leaf=%dB inter=%dB\n", out_leaf.length(), out_inter.length());
  return true;
}

// ── /1.0/rekey — renew (mTLS) ─────────────────────────────────────────
// 인증: 현 device cert+chain + priv 로 TLS 핸드셰이크.
// Body: {"csr": "<new CSR PEM>"} 단일 필드 (RekeyRequest 가 다른 필드 미지원).
// Lifetime: step-ca 의 device-renewal provisioner default 적용 (2160h=90d).
//           → 응답 leaf 의 notAfter 를 항상 파싱.
static bool step_ca_rekey(const String& csr_pem,
                          const String& device_chain_pem,
                          const String& device_key_pem,
                          String& out_leaf, String& out_inter,
                          time_t& out_not_after) {
  // mTLS 객체 — stepca_https 가 BearSSL 에 포인터 전달, 함수 끝까지 살아있어야.
  BearSSL::X509List   clientChain(device_chain_pem.c_str());
  BearSSL::PrivateKey clientKey  (device_key_pem.c_str());

  String body;
  body.reserve(csr_pem.length() + 16);
  body += "{\"csr\":\"";
  append_json_escaped(body, csr_pem);
  body += "\"}";

  int status = 0;
  String resp;
  if (!stepca_https("POST", STEP_CA_REKEY_PATH, body,
                    &clientChain, &clientKey, status, resp)) {
    Serial.println("[rekey] request fail (transport)");
    return false;
  }
  if (status != 200 && status != 201) {
    Serial.printf("[rekey] status=%d, body: %s\n", status, resp.c_str());
    return false;
  }

  out_leaf  = json_extract(resp, "crt");
  out_inter = json_extract(resp, "ca");
  if (out_leaf.length() == 0) {
    Serial.printf("[rekey] crt missing: %s\n", resp.c_str());
    return false;
  }
  if (!parse_leaf_not_after(out_leaf.c_str(), &out_not_after)) {
    Serial.println("[rekey] parse_leaf_not_after fail");
    return false;
  }
  Serial.printf("[rekey] leaf=%dB inter=%dB notAfter=%lu\n",
                out_leaf.length(), out_inter.length(),
                (unsigned long)out_not_after);
  return true;
}

// ── 공통: 키페어 + CN + CSR ─────────────────────────────────────────────
static bool gen_keypair_and_csr(const char* tag,
                                uint8_t* new_pub, uint8_t* new_priv,
                                char* cn, size_t cn_size,
                                String& out_csr_pem) {
  uECC_set_rng(&rng_func);

  if (!uECC_make_key(new_pub, new_priv, uECC_secp256r1())) {
    Serial.printf("[%s] keygen fail\n", tag);
    return false;
  }
  yield();

  if (DEVICE_CN_OVERRIDE && DEVICE_CN_OVERRIDE[0]) {
    snprintf(cn, cn_size, "%s", DEVICE_CN_OVERRIDE);
  } else {
    uint8_t mac[6];
    WiFi.macAddress(mac);
    snprintf(cn, cn_size, "device-%02x%02x%02x", mac[3], mac[4], mac[5]);
  }
  Serial.printf("[%s] CN=%s\n", tag, cn);

  static uint8_t csr_der[800];
  size_t csr_len = build_csr(csr_der, cn, new_pub, new_priv);
  if (csr_len == 0) {
    Serial.printf("[%s] CSR build fail\n", tag);
    return false;
  }
  out_csr_pem = der_to_pem_string(csr_der, csr_len, "CERTIFICATE REQUEST");
  yield();
  return true;
}

// ── 공통: 원자적 LittleFS 저장 ─────────────────────────────────────────
static bool save_device_assets(const char* tag,
                               const String& leafPem, const String& interPem,
                               const uint8_t* new_priv, const uint8_t* new_pub,
                               time_t not_after) {
  static uint8_t new_key_der[200];
  size_t new_key_len = build_ec_priv_der(new_key_der, new_priv, new_pub);

  { File f = LittleFS.open("/device-cert.pem.new",  "w"); f.print(leafPem);  f.close(); }
  { File f = LittleFS.open("/device-chain.pem.new", "w"); f.print(interPem); f.close(); }
  save_pem("/device-key.pem.new", "EC PRIVATE KEY", new_key_der, new_key_len);

  if (LittleFS.open("/device-cert.pem.new", "r").size() == 0 ||
      LittleFS.open("/device-key.pem.new",  "r").size() == 0) {
    Serial.printf("[%s] new file empty — abort\n", tag);
    return false;
  }

  LittleFS.remove(PATH_DEV_CERT);  LittleFS.rename("/device-cert.pem.new",  PATH_DEV_CERT);
  LittleFS.remove(PATH_DEV_CHAIN); LittleFS.rename("/device-chain.pem.new", PATH_DEV_CHAIN);
  LittleFS.remove(PATH_DEV_KEY);   LittleFS.rename("/device-key.pem.new",   PATH_DEV_KEY);
  save_exp(not_after);

  time_t now = time(nullptr);
  Serial.printf("[%s] OK, exp in %lds, heap=%d\n",
                tag, (long)(not_after - now), ESP.getFreeHeap());
  return true;
}

// ── 1차 발급 (bootstrap → device-bootstrap provisioner cert) ──────────
// bootstrap cert/key 로 X5C JWT 서명 → /1.0/sign(aud=#x5c/device-bootstrap).
// 응답은 caller (provision_cert) 가 받아 2차 발급의 signer 로 재사용.
static bool sign_with_bootstrap(const char* cn,
                                const String& csr_pem,
                                String& out_leaf_pem,
                                time_t& out_not_after) {
  String signerCertPem = read_file(PATH_BS_CERT);
  String signerKeyPem  = read_file(PATH_BS_KEY);
  if (signerCertPem.length() == 0 || signerKeyPem.length() == 0) {
    Serial.println("[boot1] bootstrap assets missing");
    return false;
  }

  static uint8_t signer_cert_der[600];
  size_t signer_cert_len = pem_to_der(signerCertPem.c_str(),
                                      signer_cert_der, sizeof(signer_cert_der));
  static uint8_t signer_key_der[200];
  size_t signer_key_len = pem_to_der(signerKeyPem.c_str(),
                                     signer_key_der, sizeof(signer_key_der));
  if (signer_cert_len == 0 || signer_key_len == 0) {
    Serial.println("[boot1] pem→der fail");
    return false;
  }
  uint8_t signer_priv[32];
  if (!ec_priv_from_der(signer_key_der, signer_key_len, signer_priv)) {
    Serial.println("[boot1] ec_priv_from_der fail");
    return false;
  }
  signerCertPem = String();    // PEM 즉시 해제 (DER 만 유지)
  signerKeyPem  = String();

  String jwt;
  if (!build_x5c_jwt(cn, PROV_BOOTSTRAP, signer_cert_der, signer_cert_len,
                     signer_priv, jwt)) {
    Serial.println("[boot1] jwt build fail");
    return false;
  }
  Serial.printf("[boot1] JWT %dB built, heap=%d\n", jwt.length(), ESP.getFreeHeap());

  String interPem;    // 1차의 intermediate 는 폐기 (2차 응답에서 다시 받음)
  bool ok = step_ca_sign(csr_pem, jwt, /*signer_not_after=*/0,
                         out_leaf_pem, interPem, out_not_after);
  jwt      = String();
  interPem = String();
  return ok;
}

// ── 2차 발급 (device-bootstrap cert → device-renewal provisioner cert) ─
// 1차 발급으로 받은 cert/key 로 X5C JWT 서명 → /1.0/sign(aud=#x5c/device-renewal).
// 응답 cert 의 provisioner-ext = device-renewal → 이후 mTLS rekey 가능.
//
// forbiddenAfter 클램프: signer = 1차 cert. 새 cert notAfter ≤ signer notAfter - 60s.
static bool sign_with_first_cert(const char* cn,
                                 const String& first_leaf_pem,
                                 const uint8_t* first_priv,
                                 time_t first_not_after,
                                 const String& csr_pem,
                                 String& out_leaf_pem,
                                 String& out_inter_pem,
                                 time_t& out_not_after) {
  static uint8_t signer_cert_der[600];
  size_t signer_cert_len = pem_to_der(first_leaf_pem.c_str(),
                                      signer_cert_der, sizeof(signer_cert_der));
  if (signer_cert_len == 0) {
    Serial.println("[boot2] first cert pem→der fail");
    return false;
  }

  String jwt;
  if (!build_x5c_jwt(cn, PROV_RENEWAL, signer_cert_der, signer_cert_len,
                     first_priv, jwt)) {
    Serial.println("[boot2] jwt build fail");
    return false;
  }
  Serial.printf("[boot2] JWT %dB built, heap=%d\n", jwt.length(), ESP.getFreeHeap());

  bool ok = step_ca_sign(csr_pem, jwt, first_not_after,
                         out_leaf_pem, out_inter_pem, out_not_after);
  jwt = String();
  return ok;
}

// ── provision_cert ────────────────────────────────────────────────────
// renew_mode=false : 2단계 발급 (bootstrap → device-bootstrap → device-renewal).
//                    저장되는 cert 의 provisioner-ext 가 device-renewal 이라
//                    이후 mTLS rekey 가능.
// renew_mode=true  : /1.0/rekey + mTLS (현 device cert/key 핸드셰이크).
bool provision_cert(bool renew_mode) {
  if (renew_mode) {
    Serial.printf("[renew] start, heap=%d\n", ESP.getFreeHeap());

    uint8_t new_pub[64], new_priv[32];
    char cn[32];
    String csr_pem;
    if (!gen_keypair_and_csr("renew", new_pub, new_priv, cn, sizeof(cn), csr_pem)) {
      return false;
    }

    String chainPem = read_file(PATH_DEV_CERT);
    String chainExtra = read_file(PATH_DEV_CHAIN);
    String keyPem = read_file(PATH_DEV_KEY);
    if (chainPem.length() == 0 || keyPem.length() == 0) {
      Serial.println("[renew] device assets missing");
      return false;
    }
    chainPem += chainExtra;     // mTLS 에 leaf+intermediate 둘 다 제시
    chainExtra = String();

    Serial.printf("[renew] mTLS rekey, heap=%d\n", ESP.getFreeHeap());
    String leafPem, interPem;
    time_t not_after = 0;
    bool ok = step_ca_rekey(csr_pem, chainPem, keyPem,
                            leafPem, interPem, not_after);
    chainPem = String();
    keyPem   = String();
    csr_pem  = String();
    if (!ok) {
      Serial.println("[renew] rekey fail");
      return false;
    }

    return save_device_assets("renew", leafPem, interPem, new_priv, new_pub, not_after);
  }

  // ── 2단계 bootstrap ────────────────────────────────────────────────
  Serial.printf("[boot] start, heap=%d\n", ESP.getFreeHeap());

  // 1차: bootstrap → device-bootstrap cert
  uint8_t first_pub[64], first_priv[32];
  char cn[32];
  String first_csr;
  if (!gen_keypair_and_csr("boot1", first_pub, first_priv, cn, sizeof(cn), first_csr)) {
    return false;
  }

  String first_leaf_pem;
  time_t first_not_after = 0;
  bool ok1 = sign_with_bootstrap(cn, first_csr, first_leaf_pem, first_not_after);
  first_csr = String();    // CSR 즉시 해제
  if (!ok1) {
    Serial.println("[boot1] sign fail");
    return false;
  }
  Serial.printf("[boot1] OK, heap=%d\n", ESP.getFreeHeap());

  // 2차: 1차 cert → device-renewal cert
  uint8_t second_pub[64], second_priv[32];
  String second_csr;
  if (!gen_keypair_and_csr("boot2", second_pub, second_priv, cn, sizeof(cn), second_csr)) {
    return false;
  }

  String second_leaf_pem, second_inter_pem;
  time_t second_not_after = 0;
  bool ok2 = sign_with_first_cert(cn, first_leaf_pem, first_priv, first_not_after,
                                  second_csr, second_leaf_pem, second_inter_pem,
                                  second_not_after);
  second_csr     = String();
  first_leaf_pem = String();
  // 1차 priv 폐기 (메모리 zero)
  memset(first_priv, 0, sizeof(first_priv));
  if (!ok2) {
    Serial.println("[boot2] sign fail");
    return false;
  }
  Serial.printf("[boot2] OK, heap=%d\n", ESP.getFreeHeap());

  // 2차 cert 를 device assets 으로 저장
  if (!save_device_assets("boot", second_leaf_pem, second_inter_pem,
                          second_priv, second_pub, second_not_after)) {
    return false;
  }

  LittleFS.remove(PATH_BS_CERT);
  LittleFS.remove(PATH_BS_KEY);
  Serial.println("[boot] bootstrap assets removed");
  return true;
}

bool probe_stepca_chain_only() {
  Serial.println("[probe] step-ca /health (chain verify, SAN skip)");
  int status = 0;
  String resp;
  if (!stepca_https("GET", STEP_CA_HEALTH_PATH, String(),
                    nullptr, nullptr, status, resp)) {
    Serial.println("[probe] request fail (transport)");
    return false;
  }
  Serial.printf("[probe] status=%d body=%s\n", status, resp.c_str());
  return status == 200;
}
