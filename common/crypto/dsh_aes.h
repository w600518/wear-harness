/*
 * dsh_aes.h - AES-256 block cipher and CBC mode with PKCS#7 padding.
 *
 * C99, no dependencies. The inverse S-box is derived from the forward table at
 * first use, so only one 256-entry table is hand-maintained.
 */
#ifndef DSH_AES_H
#define DSH_AES_H

#include <stddef.h>
#include <stdint.h>

#define DSH_AES_BLOCK_LEN 16
#define DSH_AES256_KEY_LEN 32
#define DSH_AES256_ROUND_KEYS 240

typedef struct {
    uint8_t round_keys[DSH_AES256_ROUND_KEYS];
    int     rounds;
} dsh_aes256;

void dsh_aes256_init(dsh_aes256 *ctx, const uint8_t key[DSH_AES256_KEY_LEN]);
void dsh_aes256_encrypt_block(const dsh_aes256 *ctx, const uint8_t in[16], uint8_t out[16]);
void dsh_aes256_decrypt_block(const dsh_aes256 *ctx, const uint8_t in[16], uint8_t out[16]);

/*
 * PKCS#7 padded CBC. `out` must hold at least ((len / 16) + 1) * 16 bytes and
 * `*outlen` receives the padded length.
 */
void dsh_aes256_cbc_encrypt(const dsh_aes256 *ctx, const uint8_t iv[16],
                            const uint8_t *in, size_t len,
                            uint8_t *out, size_t *outlen);

/*
 * Verifies and strips PKCS#7 padding. `out` must hold at least `len` bytes and
 * `*outlen` receives the plaintext length. Returns 0 on success, -1 when the
 * length is not a positive multiple of 16, and -2 on invalid padding.
 */
int dsh_aes256_cbc_decrypt(const dsh_aes256 *ctx, const uint8_t iv[16],
                           const uint8_t *in, size_t len,
                           uint8_t *out, size_t *outlen);

/* Zeroizes key material in place. */
void dsh_aes256_wipe(dsh_aes256 *ctx);

#endif /* DSH_AES_H */
