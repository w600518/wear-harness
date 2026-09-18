#include "dsh_sha256.h"

#include <string.h>

static const uint32_t K[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
    0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
    0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
    0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
};

static uint32_t rotr32(uint32_t x, unsigned n) {
    return (x >> n) | (x << (32u - n));
}

static void sha256_compress(uint32_t state[8], const uint8_t block[64]) {
    uint32_t w[64];
    uint32_t a, b, c, d, e, f, g, h;
    int i;

    for (i = 0; i < 16; i++) {
        w[i] = ((uint32_t)block[i * 4] << 24) |
               ((uint32_t)block[i * 4 + 1] << 16) |
               ((uint32_t)block[i * 4 + 2] << 8) |
               ((uint32_t)block[i * 4 + 3]);
    }
    for (i = 16; i < 64; i++) {
        uint32_t s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    a = state[0]; b = state[1]; c = state[2]; d = state[3];
    e = state[4]; f = state[5]; g = state[6]; h = state[7];

    for (i = 0; i < 64; i++) {
        uint32_t S1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
        uint32_t ch = (e & f) ^ ((~e) & g);
        uint32_t t1 = h + S1 + ch + K[i] + w[i];
        uint32_t S0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = S0 + maj;

        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }

    state[0] += a; state[1] += b; state[2] += c; state[3] += d;
    state[4] += e; state[5] += f; state[6] += g; state[7] += h;
}

void dsh_sha256_init(dsh_sha256_ctx *c) {
    c->state[0] = 0x6a09e667u; c->state[1] = 0xbb67ae85u;
    c->state[2] = 0x3c6ef372u; c->state[3] = 0xa54ff53au;
    c->state[4] = 0x510e527fu; c->state[5] = 0x9b05688cu;
    c->state[6] = 0x1f83d9abu; c->state[7] = 0x5be0cd19u;
    c->bitlen = 0;
    c->buflen = 0;
}

void dsh_sha256_update(dsh_sha256_ctx *c, const void *data, size_t len) {
    const uint8_t *p = (const uint8_t *)data;

    c->bitlen += (uint64_t)len * 8u;

    while (len > 0) {
        size_t space = DSH_SHA256_BLOCK_LEN - c->buflen;
        size_t take = (len < space) ? len : space;

        memcpy(c->buf + c->buflen, p, take);
        c->buflen += take;
        p += take;
        len -= take;

        if (c->buflen == DSH_SHA256_BLOCK_LEN) {
            sha256_compress(c->state, c->buf);
            c->buflen = 0;
        }
    }
}

void dsh_sha256_final(dsh_sha256_ctx *c, uint8_t out[DSH_SHA256_DIGEST_LEN]) {
    uint64_t bits = c->bitlen;
    uint8_t pad[DSH_SHA256_BLOCK_LEN * 2];
    size_t padlen;
    size_t i;

    /* 0x80, zero fill, then the 64-bit big-endian length. */
    pad[0] = 0x80;
    memset(pad + 1, 0, sizeof(pad) - 1);

    padlen = (c->buflen < 56) ? (56 - c->buflen) : (120 - c->buflen);
    dsh_sha256_update(c, pad, padlen);

    for (i = 0; i < 8; i++) {
        pad[i] = (uint8_t)(bits >> (56 - 8 * i));
    }
    dsh_sha256_update(c, pad, 8);

    for (i = 0; i < 8; i++) {
        out[i * 4]     = (uint8_t)(c->state[i] >> 24);
        out[i * 4 + 1] = (uint8_t)(c->state[i] >> 16);
        out[i * 4 + 2] = (uint8_t)(c->state[i] >> 8);
        out[i * 4 + 3] = (uint8_t)(c->state[i]);
    }
}

void dsh_sha256(const void *data, size_t len, uint8_t out[DSH_SHA256_DIGEST_LEN]) {
    dsh_sha256_ctx c;
    dsh_sha256_init(&c);
    dsh_sha256_update(&c, data, len);
    dsh_sha256_final(&c, out);
}

void dsh_hmac_sha256_init(dsh_hmac_sha256_ctx *c, const uint8_t *key, size_t keylen) {
    uint8_t block[DSH_SHA256_BLOCK_LEN];
    uint8_t ipad[DSH_SHA256_BLOCK_LEN];
    size_t i;

    memset(block, 0, sizeof(block));
    if (keylen > DSH_SHA256_BLOCK_LEN) {
        dsh_sha256(key, keylen, block);
    } else {
        memcpy(block, key, keylen);
    }

    for (i = 0; i < DSH_SHA256_BLOCK_LEN; i++) {
        ipad[i] = (uint8_t)(block[i] ^ 0x36);
        c->opad[i] = (uint8_t)(block[i] ^ 0x5c);
    }

    dsh_sha256_init(&c->inner);
    dsh_sha256_update(&c->inner, ipad, DSH_SHA256_BLOCK_LEN);

    memset(block, 0, sizeof(block));
    memset(ipad, 0, sizeof(ipad));
}

void dsh_hmac_sha256_update(dsh_hmac_sha256_ctx *c, const void *data, size_t len) {
    dsh_sha256_update(&c->inner, data, len);
}

void dsh_hmac_sha256_final(dsh_hmac_sha256_ctx *c, uint8_t out[DSH_SHA256_DIGEST_LEN]) {
    uint8_t inner_digest[DSH_SHA256_DIGEST_LEN];
    dsh_sha256_ctx outer;

    dsh_sha256_final(&c->inner, inner_digest);

    dsh_sha256_init(&outer);
    dsh_sha256_update(&outer, c->opad, DSH_SHA256_BLOCK_LEN);
    dsh_sha256_update(&outer, inner_digest, DSH_SHA256_DIGEST_LEN);
    dsh_sha256_final(&outer, out);

    memset(inner_digest, 0, sizeof(inner_digest));
    memset(c->opad, 0, sizeof(c->opad));
}

void dsh_hmac_sha256(const uint8_t *key, size_t keylen,
                     const void *data, size_t len,
                     uint8_t out[DSH_SHA256_DIGEST_LEN]) {
    dsh_hmac_sha256_ctx c;
    dsh_hmac_sha256_init(&c, key, keylen);
    dsh_hmac_sha256_update(&c, data, len);
    dsh_hmac_sha256_final(&c, out);
}

void dsh_pbkdf2_hmac_sha256(const uint8_t *pass, size_t passlen,
                            const uint8_t *salt, size_t saltlen,
                            uint32_t iterations,
                            uint8_t *out, size_t outlen) {
    uint8_t u[DSH_SHA256_DIGEST_LEN];
    uint8_t t[DSH_SHA256_DIGEST_LEN];
    uint8_t block_salt[256];
    uint32_t counter = 1;
    size_t produced = 0;
    size_t i;
    uint32_t iter;

    if (iterations == 0) {
        iterations = 1;
    }
    if (saltlen > sizeof(block_salt) - 4) {
        saltlen = sizeof(block_salt) - 4;
    }

    memcpy(block_salt, salt, saltlen);

    while (produced < outlen) {
        dsh_hmac_sha256_ctx c;

        block_salt[saltlen]     = (uint8_t)(counter >> 24);
        block_salt[saltlen + 1] = (uint8_t)(counter >> 16);
        block_salt[saltlen + 2] = (uint8_t)(counter >> 8);
        block_salt[saltlen + 3] = (uint8_t)(counter);

        dsh_hmac_sha256_init(&c, pass, passlen);
        dsh_hmac_sha256_update(&c, block_salt, saltlen + 4);
        dsh_hmac_sha256_final(&c, u);

        memcpy(t, u, sizeof(t));

        for (iter = 1; iter < iterations; iter++) {
            dsh_hmac_sha256(pass, passlen, u, sizeof(u), u);
            for (i = 0; i < sizeof(t); i++) {
                t[i] ^= u[i];
            }
        }

        {
            size_t take = outlen - produced;
            if (take > sizeof(t)) {
                take = sizeof(t);
            }
            memcpy(out + produced, t, take);
            produced += take;
        }

        counter++;
    }

    memset(u, 0, sizeof(u));
    memset(t, 0, sizeof(t));
    memset(block_salt, 0, sizeof(block_salt));
}

int dsh_ct_equal(const uint8_t *a, const uint8_t *b, size_t len) {
    uint8_t diff = 0;
    size_t i;

    for (i = 0; i < len; i++) {
        diff |= (uint8_t)(a[i] ^ b[i]);
    }

    return diff == 0;
}
