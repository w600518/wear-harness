#include "dsh_webauth.h"

#include <stdio.h>
#include <string.h>

#include "dsh_sha1.h"
#include "dsh_sha256.h"

/* ── base64url helpers (Node's base64url: no padding, - and _ alphabet) ──── */

static size_t b64url_encode(const uint8_t *data, size_t len, char *out, size_t cap) {
    size_t i;
    size_t kept;

    if (4 * ((len + 2) / 3) + 1 > cap) {
        return 0;
    }
    dsh_base64_encode(data, len, out);
    for (i = 0; out[i] != '\0'; i++) {
        if (out[i] == '+') {
            out[i] = '-';
        } else if (out[i] == '/') {
            out[i] = '_';
        }
    }
    /* Drop the '=' padding dsh_base64_encode writes; base64url has none. */
    kept = strlen(out);
    while (kept > 0 && out[kept - 1] == '=') {
        out[--kept] = '\0';
    }
    return kept;
}

static int b64url_decode(const char *text, uint8_t *out, size_t out_cap, size_t *out_len) {
    char std[128];
    size_t len = strlen(text);
    size_t i;

    if (len == 0 || len >= sizeof(std) || (len % 4) == 1) {
        return -1;
    }
    for (i = 0; i < len; i++) {
        char c = text[i];
        if (c == '-') {
            std[i] = '+';
        } else if (c == '_') {
            std[i] = '/';
        } else {
            std[i] = c;
        }
    }
    while ((len % 4) != 0) {
        std[len++] = '=';
    }
    std[len] = '\0';
    return dsh_base64_decode(std, len, out, out_cap, out_len);
}

/* ── cookie minting ──────────────────────────────────────────────────────── */

int dsh_webauth_cookie(const char *secret_b64url, const char *authority,
                       long long issued_ms, long long expires_ms,
                       char *out, size_t cap) {
    uint8_t secret[32];
    size_t secret_len;
    char body[256];
    char body_b64[384];
    char name_b64[64];
    char sig_b64[64];
    uint8_t digest[DSH_SHA256_DIGEST_LEN];
    uint8_t mac[DSH_SHA256_DIGEST_LEN];
    int body_len;
    size_t name_len;
    size_t body_b64_len;
    size_t sig_len;
    int total;

    if (secret_b64url == NULL || authority == NULL || out == NULL) {
        return -1;
    }
    if (b64url_decode(secret_b64url, secret, sizeof(secret), &secret_len) != 0 ||
        secret_len != sizeof(secret)) {
        return -1;
    }

    /* Key order and lack of spaces must match Node's JSON.stringify exactly. */
    body_len = snprintf(body, sizeof(body),
                        "{\"version\":1,\"authority\":\"%s\",\"issuedAt\":%lld,\"expiresAt\":%lld}",
                        authority, issued_ms, expires_ms);
    if (body_len <= 0 || (size_t)body_len >= sizeof(body)) {
        return -1;
    }

    body_b64_len = b64url_encode((const uint8_t *)body, (size_t)body_len,
                                 body_b64, sizeof(body_b64));
    if (body_b64_len == 0) {
        return -1;
    }

    dsh_sha256(authority, strlen(authority), digest);
    name_len = b64url_encode(digest, sizeof(digest), name_b64, sizeof(name_b64));
    if (name_len == 0) {
        return -1;
    }

    dsh_hmac_sha256(secret, sizeof(secret),
                    (const uint8_t *)body_b64, body_b64_len, mac);
    sig_len = b64url_encode(mac, sizeof(mac), sig_b64, sizeof(sig_b64));
    if (sig_len == 0) {
        return -1;
    }

    total = snprintf(out, cap, "dsh-auth-%s=v1.%s.%s", name_b64, body_b64, sig_b64);
    if (total <= 0 || (size_t)total >= cap) {
        return -1;
    }
    return 0;
}

/* ── credentials file parsing ────────────────────────────────────────────── */

int dsh_webauth_secret_from_file(const char *yaml_path, char *out, size_t cap) {
    FILE *fp;
    char line[1024];
    int in_record = 0;
    size_t record_indent = 0;

    if (yaml_path == NULL || out == NULL || cap < DSH_WEBAUTH_SECRET_LEN) {
        return -1;
    }
    fp = fopen(yaml_path, "rb");
    if (fp == NULL) {
        return -1;
    }

    while (fgets(line, sizeof(line), fp) != NULL) {
        const char *body = line;
        const char *value;
        size_t indent;

        while (*body == ' ' || *body == '\t') {
            body++;
        }
        if (*body == '\0' || *body == '\n' || *body == '\r' || *body == '#') {
            continue;
        }
        indent = (size_t)(body - line);

        if (in_record) {
            /* A key at or left of the record's own indent ends the block. */
            if (indent <= record_indent) {
                break;
            }
            if (strncmp(body, "secret:", 7) == 0) {
                size_t n;
                value = body + 7;
                while (*value == ' ' || *value == '\t') {
                    value++;
                }
                n = strlen(value);
                while (n > 0 && (value[n - 1] == '\n' || value[n - 1] == '\r' ||
                                 value[n - 1] == ' ' || value[n - 1] == '\t')) {
                    n--;
                }
                if (n == 0 || n >= cap) {
                    break;
                }
                memcpy(out, value, n);
                out[n] = '\0';
                fclose(fp);
                return 0;
            }
            continue;
        }

        if (strncmp(body, "client-connection/browser-session:", 34) == 0) {
            in_record = 1;
            record_indent = indent;
        }
    }

    fclose(fp);
    return -1;
}
