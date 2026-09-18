#include "dsh_http.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#include <bcrypt.h>
#endif

/* ── URL parsing ─────────────────────────────────────────────────────────── */

int dsh_http_init(dsh_http *http, const char *base_url) {
    const char *rest;
    const char *slash;
    size_t authority_len;

    if (http == NULL || base_url == NULL) {
        return -1;
    }

    memset(http, 0, sizeof(*http));

    if (strncmp(base_url, "http://", 7) == 0) {
        rest = base_url + 7;
    } else if (strncmp(base_url, "https://", 8) == 0) {
        /* The relay talks to a loopback dsh web server; TLS is out of scope. */
        return -1;
    } else {
        rest = base_url;
    }

    slash = strchr(rest, '/');
    authority_len = (slash != NULL) ? (size_t)(slash - rest) : strlen(rest);

    /* A base URL carrying a path would silently target the wrong surface. */
    if (slash != NULL && slash[1] != '\0' && slash[1] != '?') {
        return -1;
    }
    if (authority_len == 0 || authority_len >= sizeof(http->authority)) {
        return -1;
    }

    memcpy(http->authority, rest, authority_len);
    http->authority[authority_len] = '\0';

    /*
     * Split the authority into the name to resolve and the port. `host` must
     * never keep the port: it is handed to getaddrinfo, which would fail on
     * "127.0.0.1:3080" as a host name.
     */
    {
        const char *colon = strrchr(http->authority, ':');
        size_t host_len;

        if (colon != NULL) {
            host_len = (size_t)(colon - http->authority);
            http->port = (uint16_t)atoi(colon + 1);
        } else {
            host_len = authority_len;
            http->port = 80;
        }

        if (host_len == 0 || host_len >= sizeof(http->host)) {
            return -1;
        }
        memcpy(http->host, http->authority, host_len);
        http->host[host_len] = '\0';
    }

    if (http->port == 0) {
        return -1;
    }

    return 0;
}

/* ── token login ─────────────────────────────────────────────────────────── */

/* Pulls one "name=value" pair out of a Set-Cookie header. */
static int capture_cookie(dsh_http *http, const char *set_cookie, size_t len) {
    size_t i;
    size_t value_start = 0;
    size_t value_end;

    for (i = 0; i < len; i++) {
        if (set_cookie[i] == '=') {
            value_start = i + 1;
            break;
        }
    }
    if (value_start == 0) {
        return -1;
    }

    value_end = value_start;
    while (value_end < len && set_cookie[value_end] != ';' && set_cookie[value_end] != '\r') {
        value_end++;
    }

    /* Keep the whole name=value pair; the name is part of the Cookie header. */
    {
        size_t name_len = value_start - 1;
        size_t total = name_len + 1 + (value_end - value_start);
        if (total >= sizeof(http->cookie)) {
            return -1;
        }
        memcpy(http->cookie, set_cookie, name_len + 1);
        memcpy(http->cookie + name_len + 1, set_cookie + value_start, value_end - value_start);
        http->cookie[total] = '\0';
    }

    return 0;
}

int dsh_http_login(dsh_http *http, const char *launch_url_or_token) {
    const char *token;
    dsh_sb path;
    dsh_sb body;
    int status = 0;
    int rc;

    if (http == NULL || launch_url_or_token == NULL) {
        return -1;
    }

    token = strstr(launch_url_or_token, "token=");
    if (token != NULL) {
        token += 6;
    } else {
        token = launch_url_or_token;
    }

    dsh_sb_init(&path);
    dsh_sb_puts(&path, "/?token=");
    {
        const char *p = token;
        while (*p != '\0' && *p != '&' && *p != '#' && *p != ' ') {
            dsh_sb_putc(&path, *p++);
        }
    }

    if (path.len <= 8) {
        dsh_sb_free(&path);
        return -1;
    }

    dsh_sb_init(&body);
    rc = dsh_http_get(http, path.buf, &body, &status);
    dsh_sb_free(&body);
    dsh_sb_free(&path);

    if (rc != 0) {
        return -1;
    }
    if (http->cookie[0] == '\0') {
        return -1;
    }

    http->logged_in = 1;
    return 0;
}

/* ── request/response plumbing ───────────────────────────────────────────── */

static int read_headers(dsh_socket sock, dsh_sb *headers, int *header_bytes) {
    for (;;) {
        char chunk[1024];
        int n = recv(sock, chunk, (int)sizeof(chunk), 0);

        if (n <= 0) {
            return -1;
        }

        dsh_sb_put(headers, chunk, (size_t)n);

        {
            const char *data = headers->buf;
            size_t i;
            for (i = 0; i + 3 < headers->len; i++) {
                if (data[i] == '\r' && data[i + 1] == '\n' &&
                    data[i + 2] == '\r' && data[i + 3] == '\n') {
                    *header_bytes = (int)(i + 4);
                    return 0;
                }
            }
        }

        if (headers->len > DSH_HTTP_MAX_HEADER) {
            return -1;
        }
    }
}

static int header_field(const char *headers, size_t headers_len, const char *name,
                        char *out, size_t out_cap) {
    size_t name_len = strlen(name);
    size_t i = 0;

    while (i < headers_len) {
        size_t line_start = i;
        size_t line_end;
        size_t colon;

        while (i < headers_len && headers[i] != '\n') {
            i++;
        }
        line_end = i;
        if (i < headers_len) {
            i++;
        }

        if (line_end > line_start && headers[line_end - 1] == '\r') {
            line_end--;
        }

        colon = line_start;
        while (colon < line_end && headers[colon] != ':') {
            colon++;
        }
        if (colon >= line_end) {
            continue;
        }

        {
            size_t key_len = colon - line_start;
            if (key_len != name_len) {
                continue;
            }
            {
                size_t k;
                int match = 1;
                for (k = 0; k < name_len; k++) {
                    char a = headers[line_start + k];
                    char b = name[k];
                    if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
                    if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
                    if (a != b) {
                        match = 0;
                        break;
                    }
                }
                if (!match) {
                    continue;
                }
            }
        }

        {
            size_t value_start = colon + 1;
            size_t value_end = line_end;
            size_t value_len;

            while (value_start < value_end && (headers[value_start] == ' ' || headers[value_start] == '\t')) {
                value_start++;
            }
            value_len = value_end - value_start;
            if (value_len >= out_cap) {
                return -1;
            }
            memcpy(out, headers + value_start, value_len);
            out[value_len] = '\0';
            return 0;
        }
    }

    out[0] = '\0';
    return 1;
}

/*
 * Decodes a chunked transfer body into a contiguous buffer. Returns 1 when the
 * buffer holds a complete body (the zero-length terminator has arrived), and 0
 * while more bytes are still needed.
 */
static int decode_chunked(const char *data, size_t len, dsh_sb *out) {
    size_t pos = 0;

    for (;;) {
        size_t size_end = pos;
        unsigned long size = 0;
        int digits = 0;

        while (size_end < len && data[size_end] != '\r' && data[size_end] != '\n') {
            size_end++;
        }
        if (size_end >= len) {
            return 0; /* the size line is not complete yet */
        }

        /* Chunk extensions after ';' are ignored, matching HTTP/1.1. */
        {
            size_t k;
            for (k = pos; k < size_end; k++) {
                char c = data[k];
                unsigned digit;
                if (c == ';') {
                    break;
                }
                if (c >= '0' && c <= '9') digit = (unsigned)(c - '0');
                else if (c >= 'a' && c <= 'f') digit = (unsigned)(c - 'a' + 10);
                else if (c >= 'A' && c <= 'F') digit = (unsigned)(c - 'A' + 10);
                else return -1;
                size = size * 16 + digit;
                digits = 1;
            }
        }
        (void)digits;

        pos = size_end;
        while (pos < len && data[pos] != '\n') {
            pos++;
        }
        if (pos >= len) {
            return 0;
        }
        pos++;

        if (size == 0) {
            return out->oom ? -1 : 1;
        }
        if (pos + size > len) {
            return 0;
        }

        dsh_sb_put(out, data + pos, size);
        pos += size;

        while (pos < len && (data[pos] == '\r' || data[pos] == '\n')) {
            pos++;
        }
    }
}

/*
 * Reads the whole body once headers are parsed, then applies the framing the
 * headers declare. Chunked is checked before content-length because dsh's
 * webserver answers API calls with chunked encoding and keeps the connection
 * alive, so reading to EOF would stall until the server's idle timeout.
 */
static int read_body(dsh_socket sock, dsh_sb *headers, int header_bytes,
                     const char *transfer_encoding, const char *content_length,
                     dsh_sb *out) {
    dsh_sb raw;
    size_t body_start = (size_t)header_bytes;

    dsh_sb_init(&raw);
    if (headers->len > body_start) {
        dsh_sb_put(&raw, headers->buf + body_start, headers->len - body_start);
    }

    if (transfer_encoding[0] != '\0') {
        for (;;) {
            int rc;
            char chunk[4096];
            int n;

            /*
             * Decode from the start of `raw` on every pass and rebuild `out`,
             * because a partial buffer cannot know where a previous pass
             * stopped. Appending instead would duplicate every chunk already
             * emitted and leave trailing bytes that break the JSON parse.
             */
            dsh_sb_reset(out);
            rc = decode_chunked(raw.buf != NULL ? raw.buf : "", raw.len, out);

            if (rc == 1) {
                dsh_sb_free(&raw);
                return 0;
            }
            if (rc < 0) {
                dsh_sb_free(&raw);
                return -1;
            }

            n = recv(sock, chunk, (int)sizeof(chunk), 0);
            if (n <= 0) {
                dsh_sb_free(&raw);
                return -1; /* truncated mid-chunk */
            }
            dsh_sb_put(&raw, chunk, (size_t)n);
            if (raw.len > DSH_HTTP_MAX_BODY) {
                dsh_sb_free(&raw);
                return -1;
            }
        }
    }

    if (content_length[0] != '\0') {
        size_t want = (size_t)strtoul(content_length, NULL, 10);
        if (want > DSH_HTTP_MAX_BODY) {
            dsh_sb_free(&raw);
            return -1;
        }
        while (raw.len < want) {
            char chunk[4096];
            int n = recv(sock, chunk, (int)sizeof(chunk), 0);
            if (n <= 0) {
                break;
            }
            dsh_sb_put(&raw, chunk, (size_t)n);
        }
        dsh_sb_put(out, raw.buf != NULL ? raw.buf : "", raw.len < want ? raw.len : want);
        dsh_sb_free(&raw);
        return 0;
    }

    /* No framing headers: the server signals the end by closing. */
    for (;;) {
        char chunk[4096];
        int n = recv(sock, chunk, (int)sizeof(chunk), 0);
        if (n <= 0) {
            break;
        }
        dsh_sb_put(out, chunk, (size_t)n);
        if (out->len > DSH_HTTP_MAX_BODY) {
            dsh_sb_free(&raw);
            return -1;
        }
    }

    if (raw.len > 0) {
        dsh_sb_put(out, raw.buf, raw.len);
    }
    dsh_sb_free(&raw);
    return 0;
}

static int request(dsh_http *http, const char *method, const char *path,
                   const char *content_type, const char *body, size_t body_len,
                   dsh_sb *out, int *status) {
    dsh_socket sock;
    dsh_sb req;
    dsh_sb headers;
    char transfer_encoding[64];
    char content_length_header[64];
    int header_bytes = 0;
    int rc;

    sock = dsh_net_connect(http->host, http->port, 5000);
    if (sock == DSH_INVALID_SOCKET) {
        return -1;
    }

    /*
     * A receive timeout keeps a stalled or mis-framed response from hanging the
     * sender forever; the relay loop must always regain control.
     */
    {
#ifdef _WIN32
        DWORD timeout = 15000;
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout, sizeof(timeout));
#else
        struct timeval tv;
        tv.tv_sec = 15;
        tv.tv_usec = 0;
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
#endif
    }

    dsh_sb_init(&req);
    dsh_sb_printf(&req, "%s %s HTTP/1.1\r\n", method, path);
    dsh_sb_printf(&req, "Host: %s\r\n", http->authority);
    dsh_sb_puts(&req, "Connection: close\r\n");
    dsh_sb_puts(&req, "Accept-Encoding: identity\r\n");
    if (http->cookie[0] != '\0') {
        dsh_sb_printf(&req, "Cookie: %s\r\n", http->cookie);
    }
    if (content_type != NULL) {
        dsh_sb_printf(&req, "Content-Type: %s\r\n", content_type);
        dsh_sb_printf(&req, "Content-Length: %lu\r\n", (unsigned long)body_len);
    }
    dsh_sb_puts(&req, "\r\n");
    if (body != NULL && body_len > 0) {
        dsh_sb_put(&req, body, body_len);
    }

    if (req.oom) {
        dsh_sb_free(&req);
        dsh_net_close(sock);
        return -1;
    }

    if (dsh_net_write_full(sock, req.buf, req.len) != 0) {
        dsh_sb_free(&req);
        dsh_net_close(sock);
        return -1;
    }
    dsh_sb_free(&req);

    dsh_sb_init(&headers);
    if (read_headers(sock, &headers, &header_bytes) != 0) {
        dsh_sb_free(&headers);
        dsh_net_close(sock);
        return -1;
    }

    {
        int code = 0;
        const char *line = headers.buf;
        const char *space = strchr(line, ' ');
        if (space != NULL) {
            code = atoi(space + 1);
        }
        *status = code;
    }

    if (header_field(headers.buf, (size_t)header_bytes, "Transfer-Encoding",
                     transfer_encoding, sizeof(transfer_encoding)) != 0) {
        transfer_encoding[0] = '\0';
    }
    if (header_field(headers.buf, (size_t)header_bytes, "Content-Length",
                     content_length_header, sizeof(content_length_header)) != 0) {
        content_length_header[0] = '\0';
    }
    {
        char set_cookie[2048];
        if (header_field(headers.buf, (size_t)header_bytes, "Set-Cookie",
                         set_cookie, sizeof(set_cookie)) == 0) {
            capture_cookie(http, set_cookie, strlen(set_cookie));
        }
    }

    rc = read_body(sock, &headers, header_bytes, transfer_encoding, content_length_header, out);

    dsh_sb_free(&headers);
    dsh_net_close(sock);

    return rc;
}

int dsh_http_get(dsh_http *http, const char *path, dsh_sb *out, int *status) {
    return request(http, "GET", path, NULL, NULL, 0, out, status);
}

int dsh_http_post(dsh_http *http, const char *path,
                  const char *body, size_t body_len,
                  dsh_sb *out, int *status) {
    return request(http, "POST", path, "application/json", body, body_len, out, status);
}

/* ── RPC envelope ────────────────────────────────────────────────────────── */

void dsh_http_make_rpc_id(char *out, size_t cap) {
    uint8_t raw[12];
    static const char digits[] = "0123456789abcdef";
    size_t i;

    if (cap < 25) {
        if (cap > 0) {
            out[0] = '\0';
        }
        return;
    }
    if (dsh_random_bytes(raw, sizeof(raw)) != 0) {
        memset(raw, 0, sizeof(raw));
    }
    for (i = 0; i < sizeof(raw) && i * 2 + 2 < cap; i++) {
        out[i * 2] = digits[raw[i] >> 4];
        out[i * 2 + 1] = digits[raw[i] & 0x0f];
    }
    out[i * 2] = '\0';
}

int dsh_rpc_call(dsh_http *http, const char *endpoint,
                 const char *args_json, size_t args_len,
                 dsh_sb *value, dsh_sb *error, dsh_sb *error_code) {
    dsh_sb path;
    dsh_sb envelope;
    dsh_sb response;
    char rpc_id[32];
    int status = 0;
    int rc;

    if (error_code != NULL) {
        dsh_sb_reset(error_code);
    }

    dsh_http_make_rpc_id(rpc_id, sizeof(rpc_id));

    dsh_sb_init(&path);
    dsh_sb_printf(&path, "/api/%s", endpoint);

    dsh_sb_init(&envelope);
    dsh_sb_puts(&envelope, "{\"type\":\"client-request\",\"rpcId\":");
    dsh_sb_put_json_string(&envelope, rpc_id, strlen(rpc_id));
    dsh_sb_puts(&envelope, ",\"method\":");
    dsh_sb_put_json_string(&envelope, endpoint, strlen(endpoint));
    dsh_sb_puts(&envelope, ",\"payload\":{\"args\":");
    if (args_json != NULL && args_len > 0) {
        dsh_sb_put_json_raw(&envelope, args_json, args_len);
    } else {
        dsh_sb_puts(&envelope, "{}");
    }
    dsh_sb_puts(&envelope, "}}");

    if (envelope.oom) {
        dsh_sb_free(&path);
        dsh_sb_free(&envelope);
        return -1;
    }

    dsh_sb_init(&response);
    rc = dsh_http_post(http, path.buf, envelope.buf, envelope.len, &response, &status);
    dsh_sb_free(&path);
    dsh_sb_free(&envelope);

    if (rc != 0) {
        dsh_sb_printf(error, "transport failure calling %s", endpoint);
        if (error_code != NULL) {
            dsh_sb_puts(error_code, "relay/transport");
        }
        dsh_sb_free(&response);
        return -1;
    }

    /*
     * dsh answers non-envelope failures with a plain-text body, so the status
     * has to be checked before the JSON is parsed.
     */
    if (status != 200) {
        dsh_sb_printf(error, "HTTP %d from %s: %.200s", status, endpoint,
                      response.buf != NULL ? response.buf : "");
        if (error_code != NULL) {
            dsh_sb_puts(error_code, "relay/http-error");
        }
        dsh_sb_free(&response);
        return -1;
    }

    {
        dsh_json *root = dsh_json_parse(response.buf != NULL ? response.buf : "",
                                        response.len);
        if (root == NULL) {
            dsh_sb_printf(error, "malformed JSON from %s", endpoint);
            if (error_code != NULL) {
                dsh_sb_puts(error_code, "relay/bad-response");
            }
            dsh_sb_free(&response);
            return -1;
        }

        {
            const dsh_json *result = dsh_json_get(root, "result");
            const dsh_json *ok = dsh_json_get(result, "ok");

            if (!dsh_json_bool(ok, 0)) {
                const dsh_json *err = dsh_json_get(result, "error");
                const char *code = dsh_json_string(dsh_json_get(err, "code"), "unknown", NULL);
                const char *message = dsh_json_string(dsh_json_get(err, "message"), "", NULL);

                /* dsh's own code travels out separately from the message. */
                if (error_code != NULL) {
                    dsh_sb_puts(error_code, code);
                }
                dsh_sb_printf(error, "%s: %s", code, message);
                dsh_json_free(root);
                dsh_sb_free(&response);
                return -1;
            }

            {
                const dsh_json *value_node = dsh_json_get(result, "value");
                if (value_node != NULL) {
                    dsh_json_write(value_node, value);
                } else {
                    dsh_sb_puts(value, "null");
                }
            }
        }

        dsh_json_free(root);
    }

    dsh_sb_free(&response);
    return 0;
}
