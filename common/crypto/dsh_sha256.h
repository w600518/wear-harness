/*
 * dsh_sha256.h - SHA-256, HMAC-SHA256 and PBKDF2-HMAC-SHA256.
 *
 * Self-contained, dependency-free C99 implementation shared by the DSH relay
 * sender (agent), the relay server, and the wire-format tests. FIPS 180-4,
 * RFC 2104 and RFC 8018 conformant.
 */
#ifndef DSH_SHA256_H
#define DSH_SHA256_H

#include <stddef.h>
#include <stdint.h>

#define DSH_SHA256_DIGEST_LEN 32
#define DSH_SHA256_BLOCK_LEN 64

typedef struct {
    uint32_t state[8];
    uint64_t bitlen;
    uint8_t  buf[DSH_SHA256_BLOCK_LEN];
    size_t   buflen;
} dsh_sha256_ctx;

typedef struct {
    dsh_sha256_ctx inner;
    uint8_t        opad[DSH_SHA256_BLOCK_LEN];
} dsh_hmac_sha256_ctx;

void dsh_sha256_init(dsh_sha256_ctx *c);
void dsh_sha256_update(dsh_sha256_ctx *c, const void *data, size_t len);
void dsh_sha256_final(dsh_sha256_ctx *c, uint8_t out[DSH_SHA256_DIGEST_LEN]);
void dsh_sha256(const void *data, size_t len, uint8_t out[DSH_SHA256_DIGEST_LEN]);

void dsh_hmac_sha256_init(dsh_hmac_sha256_ctx *c, const uint8_t *key, size_t keylen);
void dsh_hmac_sha256_update(dsh_hmac_sha256_ctx *c, const void *data, size_t len);
void dsh_hmac_sha256_final(dsh_hmac_sha256_ctx *c, uint8_t out[DSH_SHA256_DIGEST_LEN]);
void dsh_hmac_sha256(const uint8_t *key, size_t keylen,
                     const void *data, size_t len,
                     uint8_t out[DSH_SHA256_DIGEST_LEN]);

/*
 * Fills outlen bytes of derived key material. Callers must keep outlen under
 * (2^32 - 1) * 32 bytes, which is the specification's own ceiling.
 */
void dsh_pbkdf2_hmac_sha256(const uint8_t *pass, size_t passlen,
                            const uint8_t *salt, size_t saltlen,
                            uint32_t iterations,
                            uint8_t *out, size_t outlen);

/* Constant-time equality for MAC verification; returns 1 when equal. */
int dsh_ct_equal(const uint8_t *a, const uint8_t *b, size_t len);

#endif /* DSH_SHA256_H */
