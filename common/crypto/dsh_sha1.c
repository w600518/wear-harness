#include "dsh_sha1.h"

#include <string.h>

static uint32_t rotl32(uint32_t x, unsigned n) {
    return (x << n) | (x >> (32u - n));
}

void dsh_sha1_init(dsh_sha1_ctx *c) {
    c->state[0] = 0x67452301u;
    c->state[1] = 0xefcdab89u;
    c->state[2] = 0x98badcfeu;
    c->state[3] = 0x10325476u;
    c->state[4] = 0xc3d2e1f0u;
    c->bitlen = 0;
    c->buflen = 0;
}

static void sha1_compress(uint32_t state[5], const uint8_t block[64]) {
    uint32_t w[80];
    uint32_t a, b, c, d, e;
    int i;

    for (i = 0; i < 16; i++) {
        w[i] = ((uint32_t)block[i * 4] << 24) |
               ((uint32_t)block[i * 4 + 1] << 16) |
               ((uint32_t)block[i * 4 + 2] << 8) |
               ((uint32_t)block[i * 4 + 3]);
    }
    for (i = 16; i < 80; i++) {
        w[i] = rotl32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }

    a = state[0]; b = state[1]; c = state[2]; d = state[3]; e = state[4];

    for (i = 0; i < 80; i++) {
        uint32_t f;
        uint32_t k;

        if (i < 20) {
            f = (b & c) | ((~b) & d);
            k = 0x5a827999u;
        } else if (i < 40) {
            f = b ^ c ^ d;
            k = 0x6ed9eba1u;
        } else if (i < 60) {
            f = (b & c) | (b & d) | (c & d);
            k = 0x8f1bbcdcu;
        } else {
            f = b ^ c ^ d;
            k = 0xca62c1d6u;
        }

        {
            uint32_t temp = rotl32(a, 5) + f + e + k + w[i];
            e = d;
            d = c;
            c = rotl32(b, 30);
            b = a;
            a = temp;
        }
    }

    state[0] += a; state[1] += b; state[2] += c; state[3] += d; state[4] += e;
}

void dsh_sha1_update(dsh_sha1_ctx *c, const void *data, size_t len) {
    const uint8_t *p = (const uint8_t *)data;

    c->bitlen += (uint64_t)len * 8u;

    while (len > 0) {
        size_t space = 64 - c->buflen;
        size_t take = (len < space) ? len : space;

        memcpy(c->buf + c->buflen, p, take);
        c->buflen += take;
        p += take;
        len -= take;

        if (c->buflen == 64) {
            sha1_compress(c->state, c->buf);
            c->buflen = 0;
        }
    }
}

void dsh_sha1_final(dsh_sha1_ctx *c, uint8_t out[DSH_SHA1_DIGEST_LEN]) {
    uint64_t bits = c->bitlen;
    uint8_t pad[128];
    size_t padlen;
    size_t i;

    pad[0] = 0x80;
    memset(pad + 1, 0, sizeof(pad) - 1);

    padlen = (c->buflen < 56) ? (56 - c->buflen) : (120 - c->buflen);
    dsh_sha1_update(c, pad, padlen);

    for (i = 0; i < 8; i++) {
        pad[i] = (uint8_t)(bits >> (56 - 8 * i));
    }
    dsh_sha1_update(c, pad, 8);

    for (i = 0; i < 5; i++) {
        out[i * 4]     = (uint8_t)(c->state[i] >> 24);
        out[i * 4 + 1] = (uint8_t)(c->state[i] >> 16);
        out[i * 4 + 2] = (uint8_t)(c->state[i] >> 8);
        out[i * 4 + 3] = (uint8_t)(c->state[i]);
    }
}

void dsh_sha1(const void *data, size_t len, uint8_t out[DSH_SHA1_DIGEST_LEN]) {
    dsh_sha1_ctx c;
    dsh_sha1_init(&c);
    dsh_sha1_update(&c, data, len);
    dsh_sha1_final(&c, out);
}

static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

void dsh_base64_encode(const uint8_t *data, size_t len, char *out) {
    size_t i = 0;
    size_t o = 0;

    while (i + 2 < len) {
        uint32_t v = ((uint32_t)data[i] << 16) | ((uint32_t)data[i + 1] << 8) | data[i + 2];
        out[o++] = B64[(v >> 18) & 0x3f];
        out[o++] = B64[(v >> 12) & 0x3f];
        out[o++] = B64[(v >> 6) & 0x3f];
        out[o++] = B64[v & 0x3f];
        i += 3;
    }

    if (i < len) {
        uint32_t v = (uint32_t)data[i] << 16;
        int remaining = (int)(len - i);

        if (remaining == 2) {
            v |= (uint32_t)data[i + 1] << 8;
        }

        out[o++] = B64[(v >> 18) & 0x3f];
        out[o++] = B64[(v >> 12) & 0x3f];
        out[o++] = (remaining == 2) ? B64[(v >> 6) & 0x3f] : '=';
        out[o++] = '=';
    }

    out[o] = '\0';
}

static int b64_value(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

int dsh_base64_decode(const char *text, size_t len, uint8_t *out, size_t out_cap, size_t *out_len) {
    size_t i = 0;
    size_t written = 0;

    while (i + 3 < len) {
        int v0 = b64_value(text[i]);
        int v1 = b64_value(text[i + 1]);
        int v2 = (text[i + 2] == '=') ? 0 : b64_value(text[i + 2]);
        int v3 = (text[i + 3] == '=') ? 0 : b64_value(text[i + 3]);
        uint32_t v;

        if (v0 < 0 || v1 < 0 || v2 < 0 || v3 < 0) {
            return -1;
        }

        v = ((uint32_t)v0 << 18) | ((uint32_t)v1 << 12) | ((uint32_t)v2 << 6) | (uint32_t)v3;

        if (written >= out_cap) {
            return -1;
        }
        out[written++] = (uint8_t)(v >> 16);

        if (text[i + 2] != '=') {
            if (written >= out_cap) {
                return -1;
            }
            out[written++] = (uint8_t)(v >> 8);
        }
        if (text[i + 3] != '=') {
            if (written >= out_cap) {
                return -1;
            }
            out[written++] = (uint8_t)v;
        }

        i += 4;
    }

    if (out_len != NULL) {
        *out_len = written;
    }
    return 0;
}
