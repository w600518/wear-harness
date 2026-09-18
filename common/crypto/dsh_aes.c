#include "dsh_aes.h"

#include <string.h>

/* FIPS-197 figure 7 (forward substitution box). */
static const uint8_t SBOX[256] = {
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
};

static const uint8_t RCON[11] = {
    0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36,
};

static uint8_t RSBOX[256];
static int rsbox_ready = 0;

static void build_rsbox(void) {
    int i;
    for (i = 0; i < 256; i++) {
        RSBOX[SBOX[i]] = (uint8_t)i;
    }
    rsbox_ready = 1;
}

static uint8_t xtime(uint8_t x) {
    return (uint8_t)((x << 1) ^ ((x & 0x80u) ? 0x1bu : 0x00u));
}

/* Carry-less multiply in GF(2^8) modulo x^8 + x^4 + x^3 + x + 1. */
static uint8_t gf_mul(uint8_t a, uint8_t b) {
    uint8_t product = 0;
    int i;

    for (i = 0; i < 8; i++) {
        if (b & 1u) {
            product ^= a;
        }
        a = xtime(a);
        b = (uint8_t)(b >> 1);
    }

    return product;
}

static void add_round_key(uint8_t state[16], const uint8_t *rk) {
    int i;
    for (i = 0; i < 16; i++) {
        state[i] ^= rk[i];
    }
}

static void sub_bytes(uint8_t state[16]) {
    int i;
    for (i = 0; i < 16; i++) {
        state[i] = SBOX[state[i]];
    }
}

static void inv_sub_bytes(uint8_t state[16]) {
    int i;
    if (!rsbox_ready) {
        build_rsbox();
    }
    for (i = 0; i < 16; i++) {
        state[i] = RSBOX[state[i]];
    }
}

/* State index is r + 4*c, so row r occupies indices r, r+4, r+8, r+12. */
static void shift_rows(uint8_t s[16]) {
    uint8_t t;

    t = s[1]; s[1] = s[5]; s[5] = s[9]; s[9] = s[13]; s[13] = t;
    t = s[2]; s[2] = s[10]; s[10] = t;
    t = s[6]; s[6] = s[14]; s[14] = t;
    t = s[15]; s[15] = s[11]; s[11] = s[7]; s[7] = s[3]; s[3] = t;
}

static void inv_shift_rows(uint8_t s[16]) {
    uint8_t t;

    t = s[13]; s[13] = s[9]; s[9] = s[5]; s[5] = s[1]; s[1] = t;
    t = s[2]; s[2] = s[10]; s[10] = t;
    t = s[6]; s[6] = s[14]; s[14] = t;
    t = s[3]; s[3] = s[7]; s[7] = s[11]; s[11] = s[15]; s[15] = t;
}

static void mix_columns(uint8_t s[16]) {
    int c;

    for (c = 0; c < 4; c++) {
        uint8_t *col = s + c * 4;
        uint8_t a0 = col[0], a1 = col[1], a2 = col[2], a3 = col[3];

        col[0] = (uint8_t)(xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3);
        col[1] = (uint8_t)(a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3);
        col[2] = (uint8_t)(a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3));
        col[3] = (uint8_t)((xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3));
    }
}

static void inv_mix_columns(uint8_t s[16]) {
    int c;

    for (c = 0; c < 4; c++) {
        uint8_t *col = s + c * 4;
        uint8_t a0 = col[0], a1 = col[1], a2 = col[2], a3 = col[3];

        col[0] = (uint8_t)(gf_mul(a0, 0x0e) ^ gf_mul(a1, 0x0b) ^ gf_mul(a2, 0x0d) ^ gf_mul(a3, 0x09));
        col[1] = (uint8_t)(gf_mul(a0, 0x09) ^ gf_mul(a1, 0x0e) ^ gf_mul(a2, 0x0b) ^ gf_mul(a3, 0x0d));
        col[2] = (uint8_t)(gf_mul(a0, 0x0d) ^ gf_mul(a1, 0x09) ^ gf_mul(a2, 0x0e) ^ gf_mul(a3, 0x0b));
        col[3] = (uint8_t)(gf_mul(a0, 0x0b) ^ gf_mul(a1, 0x0d) ^ gf_mul(a2, 0x09) ^ gf_mul(a3, 0x0e));
    }
}

void dsh_aes256_init(dsh_aes256 *ctx, const uint8_t key[DSH_AES256_KEY_LEN]) {
    const int nk = 8;
    const int nr = 14;
    uint8_t w[60][4];
    int i;

    memset(ctx->round_keys, 0, sizeof(ctx->round_keys));
    ctx->rounds = nr;

    for (i = 0; i < nk; i++) {
        w[i][0] = key[4 * i];
        w[i][1] = key[4 * i + 1];
        w[i][2] = key[4 * i + 2];
        w[i][3] = key[4 * i + 3];
    }

    for (i = nk; i < 4 * (nr + 1); i++) {
        uint8_t temp[4];
        int j;

        temp[0] = w[i - 1][0];
        temp[1] = w[i - 1][1];
        temp[2] = w[i - 1][2];
        temp[3] = w[i - 1][3];

        if (i % nk == 0) {
            uint8_t t0 = temp[0];
            temp[0] = (uint8_t)(SBOX[temp[1]] ^ RCON[i / nk]);
            temp[1] = SBOX[temp[2]];
            temp[2] = SBOX[temp[3]];
            temp[3] = SBOX[t0];
        } else if (i % nk == 4) {
            for (j = 0; j < 4; j++) {
                temp[j] = SBOX[temp[j]];
            }
        }

        for (j = 0; j < 4; j++) {
            w[i][j] = (uint8_t)(w[i - nk][j] ^ temp[j]);
        }
    }

    for (i = 0; i < 4 * (nr + 1); i++) {
        ctx->round_keys[4 * i]     = w[i][0];
        ctx->round_keys[4 * i + 1] = w[i][1];
        ctx->round_keys[4 * i + 2] = w[i][2];
        ctx->round_keys[4 * i + 3] = w[i][3];
    }

    memset(w, 0, sizeof(w));
}

void dsh_aes256_encrypt_block(const dsh_aes256 *ctx, const uint8_t in[16], uint8_t out[16]) {
    uint8_t state[16];
    int round;

    memcpy(state, in, 16);
    add_round_key(state, ctx->round_keys);

    for (round = 1; round < ctx->rounds; round++) {
        sub_bytes(state);
        shift_rows(state);
        mix_columns(state);
        add_round_key(state, ctx->round_keys + round * 16);
    }

    sub_bytes(state);
    shift_rows(state);
    add_round_key(state, ctx->round_keys + ctx->rounds * 16);

    memcpy(out, state, 16);
    memset(state, 0, sizeof(state));
}

void dsh_aes256_decrypt_block(const dsh_aes256 *ctx, const uint8_t in[16], uint8_t out[16]) {
    uint8_t state[16];
    int round;

    memcpy(state, in, 16);
    add_round_key(state, ctx->round_keys + ctx->rounds * 16);

    for (round = ctx->rounds - 1; round > 0; round--) {
        inv_shift_rows(state);
        inv_sub_bytes(state);
        add_round_key(state, ctx->round_keys + round * 16);
        inv_mix_columns(state);
    }

    inv_shift_rows(state);
    inv_sub_bytes(state);
    add_round_key(state, ctx->round_keys);

    memcpy(out, state, 16);
    memset(state, 0, sizeof(state));
}

void dsh_aes256_cbc_encrypt(const dsh_aes256 *ctx, const uint8_t iv[16],
                            const uint8_t *in, size_t len,
                            uint8_t *out, size_t *outlen) {
    uint8_t chain[16];
    uint8_t block[16];
    /*
     * PKCS#7 is applied first, so the block loop below sees a plaintext whose
     * length is already a positive multiple of 16 and every block is complete.
     * A tail shorter than one block is padded, never encrypted on its own.
     */
    size_t padded = ((len / DSH_AES_BLOCK_LEN) + 1) * DSH_AES_BLOCK_LEN;
    uint8_t pad = (uint8_t)(padded - len);
    size_t offset;
    size_t i;

    memcpy(chain, iv, 16);

    for (offset = 0; offset < padded; offset += DSH_AES_BLOCK_LEN) {
        for (i = 0; i < DSH_AES_BLOCK_LEN; i++) {
            size_t position = offset + i;
            block[i] = (position < len) ? in[position] : pad;
            block[i] ^= chain[i];
        }

        dsh_aes256_encrypt_block(ctx, block, out + offset);
        memcpy(chain, out + offset, DSH_AES_BLOCK_LEN);
    }

    *outlen = padded;

    memset(chain, 0, sizeof(chain));
    memset(block, 0, sizeof(block));
}

int dsh_aes256_cbc_decrypt(const dsh_aes256 *ctx, const uint8_t iv[16],
                           const uint8_t *in, size_t len,
                           uint8_t *out, size_t *outlen) {
    uint8_t chain[16];
    uint8_t prev[16];
    uint8_t plain[16];
    size_t offset;
    size_t written = 0;
    uint8_t pad;
    size_t i;

    if (len == 0 || (len % 16) != 0) {
        return -1;
    }

    memcpy(chain, iv, 16);

    for (offset = 0; offset < len; offset += 16) {
        memcpy(prev, in + offset, 16);
        dsh_aes256_decrypt_block(ctx, in + offset, plain);

        for (i = 0; i < 16; i++) {
            plain[i] ^= chain[i];
        }

        memcpy(out + written, plain, 16);
        written += 16;
        memcpy(chain, prev, 16);
    }

    pad = out[written - 1];
    if (pad == 0 || pad > 16) {
        memset(chain, 0, sizeof(chain));
        memset(plain, 0, sizeof(plain));
        return -2;
    }
    for (i = 0; i < pad; i++) {
        if (out[written - 1 - i] != pad) {
            memset(chain, 0, sizeof(chain));
            memset(plain, 0, sizeof(plain));
            return -2;
        }
    }

    *outlen = written - pad;

    memset(chain, 0, sizeof(chain));
    memset(plain, 0, sizeof(plain));
    memset(prev, 0, sizeof(prev));
    return 0;
}

void dsh_aes256_wipe(dsh_aes256 *ctx) {
    memset(ctx->round_keys, 0, sizeof(ctx->round_keys));
    ctx->rounds = 0;
}
