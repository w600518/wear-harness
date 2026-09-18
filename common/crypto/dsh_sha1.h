/*
 * dsh_sha1.h - SHA-1 and base64, needed only for the WebSocket handshake.
 *
 * SHA-1 is used here because RFC 6455 fixes it for Sec-WebSocket-Accept; it is
 * never used to protect data. Everything the relay actually transmits is
 * authenticated with HMAC-SHA256.
 */
#ifndef DSH_SHA1_H
#define DSH_SHA1_H

#include <stddef.h>
#include <stdint.h>

#define DSH_SHA1_DIGEST_LEN 20

typedef struct {
    uint32_t state[5];
    uint64_t bitlen;
    uint8_t  buf[64];
    size_t   buflen;
} dsh_sha1_ctx;

void dsh_sha1_init(dsh_sha1_ctx *c);
void dsh_sha1_update(dsh_sha1_ctx *c, const void *data, size_t len);
void dsh_sha1_final(dsh_sha1_ctx *c, uint8_t out[DSH_SHA1_DIGEST_LEN]);
void dsh_sha1(const void *data, size_t len, uint8_t out[DSH_SHA1_DIGEST_LEN]);

/* Writes a NUL-terminated base64 string; `out` needs 4*((len+2)/3)+1 bytes. */
void dsh_base64_encode(const uint8_t *data, size_t len, char *out);
/* Decodes base64. Returns 0 on success, -1 on malformed input or overflow. */
int dsh_base64_decode(const char *text, size_t len, uint8_t *out, size_t out_cap, size_t *out_len);

#endif /* DSH_SHA1_H */
