#include "dsh_wire.h"

#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#include <bcrypt.h>
#endif

#define DSH_KDF_ITERATIONS 50000u
#define DSH_ID_LEN 16

static void put_u32_be(uint8_t *out, uint32_t value) {
    out[0] = (uint8_t)(value >> 24);
    out[1] = (uint8_t)(value >> 16);
    out[2] = (uint8_t)(value >> 8);
    out[3] = (uint8_t)(value);
}

static uint32_t get_u32_be(const uint8_t *in) {
    return ((uint32_t)in[0] << 24) |
           ((uint32_t)in[1] << 16) |
           ((uint32_t)in[2] << 8) |
           ((uint32_t)in[3]);
}

int dsh_random_bytes(void *out, size_t len) {
#ifdef _WIN32
    if (len == 0) {
        return 0;
    }
    if (BCryptGenRandom(NULL, (PUCHAR)out, (ULONG)len, BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
        return -1;
    }
    return 0;
#else
    FILE *fp;
    size_t got;

    if (len == 0) {
        return 0;
    }
    fp = fopen("/dev/urandom", "rb");
    if (fp == NULL) {
        return -1;
    }
    got = fread(out, 1, len, fp);
    fclose(fp);
    return (got == len) ? 0 : -1;
#endif
}

int dsh_passphrase_matches(const char *configured, const char *presented, size_t presented_len) {
    size_t configured_len;
    size_t i;
    uint8_t diff = 0;
    size_t span;

    if (configured == NULL || presented == NULL) {
        return 0;
    }

    configured_len = strlen(configured);
    span = (configured_len > presented_len) ? configured_len : presented_len;

    for (i = 0; i < span; i++) {
        uint8_t a = (i < configured_len) ? (uint8_t)configured[i] : 0u;
        uint8_t b = (i < presented_len) ? (uint8_t)presented[i] : 0u;
        diff |= (uint8_t)(a ^ b);
    }

    return (diff == 0) && (configured_len == presented_len);
}

/*
 * Expands the shared passphrase into the four directional keys. The KDF input
 * mixes the server salt with both handshake nonces, so a repeated passphrase
 * never produces a repeated session key and a replayed handshake derives keys
 * that the peer does not hold.
 */
int dsh_crypto_derive(dsh_crypto *crypto,
                      const char *passphrase,
                      const uint8_t salt[DSH_ID_LEN],
                      const uint8_t client_nonce[DSH_ID_LEN],
                      const uint8_t server_nonce[DSH_ID_LEN],
                      int is_server) {
    uint8_t mixed[DSH_ID_LEN * 3];
    uint8_t master[64];
    uint8_t key_c2s[32];
    uint8_t key_s2c[32];
    uint8_t mac_c2s[DSH_SHA256_DIGEST_LEN];
    uint8_t mac_s2c[DSH_SHA256_DIGEST_LEN];
    static const uint8_t label_c2s[4] = { 'c', '2', 's', 0 };
    static const uint8_t label_s2c[4] = { 's', '2', 'c', 0 };
    static const uint8_t label_mc2s[4] = { 'm', 'c', '2', 's' };
    static const uint8_t label_ms2c[4] = { 'm', 's', '2', 'c' };

    if (crypto == NULL || passphrase == NULL) {
        return -1;
    }

    memset(crypto, 0, sizeof(*crypto));

    memcpy(mixed, salt, DSH_ID_LEN);
    memcpy(mixed + DSH_ID_LEN, client_nonce, DSH_ID_LEN);
    memcpy(mixed + DSH_ID_LEN * 2, server_nonce, DSH_ID_LEN);

    dsh_pbkdf2_hmac_sha256((const uint8_t *)passphrase, strlen(passphrase),
                           mixed, sizeof(mixed),
                           DSH_KDF_ITERATIONS,
                           master, sizeof(master));

    dsh_hmac_sha256(master, sizeof(master), label_c2s, sizeof(label_c2s), key_c2s);
    dsh_hmac_sha256(master, sizeof(master), label_s2c, sizeof(label_s2c), key_s2c);
    dsh_hmac_sha256(master, sizeof(master), label_mc2s, sizeof(label_mc2s), mac_c2s);
    dsh_hmac_sha256(master, sizeof(master), label_ms2c, sizeof(label_ms2c), mac_s2c);

    dsh_aes256_init(&crypto->enc, is_server ? key_s2c : key_c2s);
    dsh_aes256_init(&crypto->dec, is_server ? key_c2s : key_s2c);

    if (is_server) {
        memcpy(crypto->send_key_mac, mac_s2c, DSH_SHA256_DIGEST_LEN);
        memcpy(crypto->recv_key_mac, mac_c2s, DSH_SHA256_DIGEST_LEN);
    } else {
        memcpy(crypto->send_key_mac, mac_c2s, DSH_SHA256_DIGEST_LEN);
        memcpy(crypto->recv_key_mac, mac_s2c, DSH_SHA256_DIGEST_LEN);
    }

    /*
     * Sequences start at 1 so the replay check (`seq <= recv_seq`) can use the
     * zero-initialized receive counter as "nothing seen yet".
     */
    crypto->send_seq = 1;
    crypto->recv_seq = 0;
    crypto->ready = 1;

    memset(master, 0, sizeof(master));
    memset(key_c2s, 0, sizeof(key_c2s));
    memset(key_s2c, 0, sizeof(key_s2c));
    memset(mixed, 0, sizeof(mixed));

    return 0;
}

void dsh_crypto_wipe(dsh_crypto *crypto) {
    if (crypto == NULL) {
        return;
    }
    dsh_aes256_wipe(&crypto->enc);
    dsh_aes256_wipe(&crypto->dec);
    memset(crypto->send_key_mac, 0, sizeof(crypto->send_key_mac));
    memset(crypto->recv_key_mac, 0, sizeof(crypto->recv_key_mac));
    crypto->send_seq = 0;
    crypto->recv_seq = 0;
    crypto->ready = 0;
}

/*
 * Writes the full frame bytes (header, IV, ciphertext, tag) for a plaintext.
 * Shared by the encrypted and handshake sealers.
 */
static int seal_common(const dsh_aes256 *aes, const uint8_t *mac_key,
                       uint8_t type, uint32_t seq,
                       const void *payload, size_t len, dsh_sb *out) {
    uint8_t header[DSH_FRAME_HEADER_LEN];
    uint8_t iv[DSH_AES_BLOCK_LEN];
    uint8_t tag[DSH_SHA256_DIGEST_LEN];
    uint8_t *cipher = NULL;
    size_t cipher_len = 0;
    dsh_hmac_sha256_ctx hmac;
    size_t base;

    if (len > DSH_FRAME_MAX_PAYLOAD) {
        return -1;
    }

    if (dsh_random_bytes(iv, sizeof(iv)) != 0) {
        return -1;
    }

    cipher_len = ((len / DSH_AES_BLOCK_LEN) + 1) * DSH_AES_BLOCK_LEN;
    cipher = (uint8_t *)malloc(cipher_len);
    if (cipher == NULL) {
        return -1;
    }

    {
        size_t written = 0;
        dsh_aes256_cbc_encrypt(aes, iv, (const uint8_t *)payload, len, cipher, &written);
        if (written != cipher_len) {
            free(cipher);
            return -1;
        }
    }

    memcpy(header, DSH_WIRE_MAGIC, 4);
    header[4] = (uint8_t)DSH_WIRE_VERSION;
    header[5] = type;
    header[6] = 0;
    header[7] = 0;
    put_u32_be(header + 8, seq);
    put_u32_be(header + 12, (uint32_t)cipher_len);
    memcpy(header + 16, iv, DSH_AES_BLOCK_LEN);

    base = out->len;
    dsh_sb_put(out, header, sizeof(header));
    dsh_sb_put(out, cipher, cipher_len);

    if (mac_key != NULL) {
        dsh_hmac_sha256_init(&hmac, mac_key, DSH_SHA256_DIGEST_LEN);
        dsh_hmac_sha256_update(&hmac, out->buf + base, out->len - base);
        dsh_hmac_sha256_final(&hmac, tag);
        dsh_sb_put(out, tag, sizeof(tag));
    }

    free(cipher);
    return out->oom ? -1 : 0;
}

int dsh_wire_seal(dsh_crypto *crypto, uint8_t type, const void *payload, size_t len,
                  dsh_sb *out) {
    if (crypto == NULL || !crypto->ready) {
        return -1;
    }

    {
        uint32_t seq = crypto->send_seq++;
        int rc = seal_common(&crypto->enc, crypto->send_key_mac, type, seq, payload, len, out);
        if (rc != 0) {
            crypto->send_seq--;
        }
        return rc;
    }
}

int dsh_wire_seal_plain(uint8_t type, const void *payload, size_t len, dsh_sb *out) {
    /* The handshake has no shared key yet, so the tag slot stays empty. */
    uint8_t header[DSH_FRAME_HEADER_LEN];
    uint8_t iv[DSH_AES_BLOCK_LEN];

    if (len > DSH_FRAME_MAX_PAYLOAD) {
        return -1;
    }

    memset(iv, 0, sizeof(iv));
    memcpy(header, DSH_WIRE_MAGIC, 4);
    header[4] = (uint8_t)DSH_WIRE_VERSION;
    header[5] = type;
    header[6] = 0x01; /* flags bit 0 marks a plaintext handshake frame */
    header[7] = 0;
    put_u32_be(header + 8, 0);
    put_u32_be(header + 12, (uint32_t)len);
    memcpy(header + 16, iv, DSH_AES_BLOCK_LEN);

    dsh_sb_put(out, header, sizeof(header));
    dsh_sb_put(out, payload, len);

    return out->oom ? -1 : 0;
}

int dsh_wire_open_plain(const uint8_t *frame, size_t len,
                        uint8_t *type_out, const uint8_t **payload, size_t *payload_len) {
    uint32_t body_len;

    if (frame == NULL || len < DSH_FRAME_HEADER_LEN) {
        return -1;
    }
    if (memcmp(frame, DSH_WIRE_MAGIC, 4) != 0) {
        return -1;
    }
    if (frame[4] != (uint8_t)DSH_WIRE_VERSION) {
        return -1;
    }
    if ((frame[6] & 0x01u) == 0) {
        return -1;
    }

    body_len = get_u32_be(frame + 12);
    if ((size_t)body_len != len - DSH_FRAME_HEADER_LEN) {
        return -1;
    }

    *type_out = frame[5];
    *payload = frame + DSH_FRAME_HEADER_LEN;
    *payload_len = body_len;
    return 0;
}

int dsh_wire_open(dsh_crypto *crypto, const uint8_t *frame, size_t len,
                  uint8_t *plain, size_t *payload_len, uint8_t *type_out,
                  uint32_t *seq_out) {
    uint8_t expect_tag[DSH_SHA256_DIGEST_LEN];
    uint8_t iv[DSH_AES_BLOCK_LEN];
    dsh_hmac_sha256_ctx hmac;
    uint32_t cipher_len;
    uint32_t seq;
    size_t written = 0;

    if (crypto == NULL || !crypto->ready || frame == NULL || plain == NULL) {
        return -1;
    }
    if (len < DSH_FRAME_HEADER_LEN + DSH_AES_BLOCK_LEN + DSH_FRAME_TAG_LEN) {
        return -1;
    }
    if (memcmp(frame, DSH_WIRE_MAGIC, 4) != 0) {
        return -1;
    }
    if (frame[4] != (uint8_t)DSH_WIRE_VERSION) {
        return -1;
    }
    if ((frame[6] & 0x01u) != 0) {
        return -1; /* handshake frame arriving on an established channel */
    }

    seq = get_u32_be(frame + 8);
    cipher_len = get_u32_be(frame + 12);

    if (cipher_len == 0 || (cipher_len % DSH_AES_BLOCK_LEN) != 0) {
        return -1;
    }
    if ((size_t)cipher_len != len - DSH_FRAME_HEADER_LEN - DSH_FRAME_TAG_LEN) {
        return -1;
    }

    /*
     * Verify before anything else reads frame state: the sequence number sits
     * in the header and is only trustworthy once the MAC over that header
     * checks out. A tampered frame must be indistinguishable from a random one,
     * so it can never advance or reveal the replay window.
     */
    dsh_hmac_sha256_init(&hmac, crypto->recv_key_mac, DSH_SHA256_DIGEST_LEN);
    dsh_hmac_sha256_update(&hmac, frame, DSH_FRAME_HEADER_LEN + cipher_len);
    dsh_hmac_sha256_final(&hmac, expect_tag);

    if (!dsh_ct_equal(expect_tag, frame + DSH_FRAME_HEADER_LEN + cipher_len, DSH_SHA256_DIGEST_LEN)) {
        return -2;
    }

    if (seq <= crypto->recv_seq) {
        return -1; /* authenticated replay or reorder */
    }

    memcpy(iv, frame + 16, DSH_AES_BLOCK_LEN);

    if (dsh_aes256_cbc_decrypt(&crypto->dec, iv,
                               frame + DSH_FRAME_HEADER_LEN, cipher_len,
                               plain, &written) != 0) {
        return -3;
    }

    crypto->recv_seq = seq;
    *payload_len = written;
    if (type_out != NULL) {
        *type_out = frame[5];
    }
    if (seq_out != NULL) {
        *seq_out = seq;
    }
    return 0;
}

void dsh_handshake_proof(const char *passphrase,
                         const uint8_t nonce[16],
                         uint8_t out[DSH_SHA256_DIGEST_LEN]) {
    static const char context[] = "dsh-relay/v1";
    dsh_hmac_sha256_ctx hmac;

    dsh_hmac_sha256_init(&hmac, (const uint8_t *)passphrase,
                         passphrase != NULL ? strlen(passphrase) : 0);
    dsh_hmac_sha256_update(&hmac, context, sizeof(context) - 1);
    dsh_hmac_sha256_update(&hmac, nonce, 16);
    dsh_hmac_sha256_final(&hmac, out);
}

void dsh_hex_encode(const uint8_t *data, size_t len, char *out) {
    static const char digits[] = "0123456789abcdef";
    size_t i;

    for (i = 0; i < len; i++) {
        out[i * 2] = digits[data[i] >> 4];
        out[i * 2 + 1] = digits[data[i] & 0x0f];
    }
    out[len * 2] = '\0';
}

int dsh_hex_decode(const char *hex, size_t hex_len, uint8_t *out, size_t out_cap, size_t *out_len) {
    size_t i;

    if (hex == NULL || out == NULL) {
        return -1;
    }
    if ((hex_len % 2) != 0 || hex_len / 2 > out_cap) {
        return -1;
    }

    for (i = 0; i < hex_len / 2; i++) {
        unsigned value = 0;
        int j;
        for (j = 0; j < 2; j++) {
            char c = hex[i * 2 + j];
            unsigned digit;
            if (c >= '0' && c <= '9') {
                digit = (unsigned)(c - '0');
            } else if (c >= 'a' && c <= 'f') {
                digit = (unsigned)(c - 'a' + 10);
            } else if (c >= 'A' && c <= 'F') {
                digit = (unsigned)(c - 'A' + 10);
            } else {
                return -1;
            }
            value = (value << 4) | digit;
        }
        out[i] = (uint8_t)value;
    }

    if (out_len != NULL) {
        *out_len = hex_len / 2;
    }
    return 0;
}
