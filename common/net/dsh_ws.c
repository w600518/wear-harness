#include "dsh_ws.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dsh_sha1.h"
#include "dsh_wire.h"

#define WS_OPCODE_CONTINUATION 0x0
#define WS_OPCODE_TEXT 0x1
#define WS_OPCODE_BINARY 0x2
#define WS_OPCODE_CLOSE 0x8
#define WS_OPCODE_PING 0x9
#define WS_OPCODE_PONG 0xa

#define WS_GUID "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
#define WS_MAX_MESSAGE (32u * 1024u * 1024u)

/* Case-insensitive compare for a fixed-length header name. */
static int name_equals(const char *text, const char *name, size_t len) {
    size_t i;
    for (i = 0; i < len; i++) {
        char a = text[i];
        char b = name[i];
        if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
        if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
        if (a != b) {
            return 0;
        }
    }
    return name[len] == '\0';
}

/* Reads exactly `len` bytes. Returns 0 on success. */
static int read_full(dsh_socket sock, void *buf, size_t len) {
    return dsh_net_read_full(sock, buf, len) == 0 ? 0 : -1;
}

static int wait_readable(dsh_socket sock, int timeout_ms) {
    fd_set set;
    struct timeval tv;
    int rc;

    FD_ZERO(&set);
    FD_SET(sock, &set);
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;

    rc = select((int)sock + 1, &set, NULL, NULL, &tv);
    if (rc == 0) {
        return 0;
    }
    if (rc < 0) {
        return -1;
    }
    return 1;
}

int dsh_ws_connect(dsh_http *http, const char *path, dsh_ws *ws, dsh_sb *error) {
    uint8_t key_raw[16];
    char key_b64[32];
    dsh_sb request;
    dsh_sb headers;
    char accept_header[128];
    int header_bytes = 0;
    char scratch[64];

    memset(ws, 0, sizeof(*ws));
    ws->sock = DSH_INVALID_SOCKET;
    dsh_sb_init(&ws->pending);

    if (dsh_random_bytes(key_raw, sizeof(key_raw)) != 0) {
        dsh_sb_puts(error, "cannot obtain randomness for the websocket key");
        return -1;
    }
    dsh_base64_encode(key_raw, sizeof(key_raw), key_b64);

    ws->sock = dsh_net_connect(http->host, http->port, 5000);
    if (ws->sock == DSH_INVALID_SOCKET) {
        dsh_sb_puts(error, "cannot connect to the dsh webserver");
        return -1;
    }

    dsh_sb_init(&request);
    dsh_sb_printf(&request, "GET %s HTTP/1.1\r\n", path);
    dsh_sb_printf(&request, "Host: %s\r\n", http->authority);
    dsh_sb_puts(&request, "Upgrade: websocket\r\n");
    dsh_sb_puts(&request, "Connection: Upgrade\r\n");
    dsh_sb_printf(&request, "Sec-WebSocket-Key: %s\r\n", key_b64);
    dsh_sb_puts(&request, "Sec-WebSocket-Version: 13\r\n");
    if (http->cookie[0] != '\0') {
        dsh_sb_printf(&request, "Cookie: %s\r\n", http->cookie);
    }
    dsh_sb_puts(&request, "\r\n");

    if (dsh_net_write_full(ws->sock, request.buf, request.len) != 0) {
        dsh_sb_free(&request);
        dsh_sb_puts(error, "cannot send the upgrade request");
        dsh_ws_close(ws);
        return -1;
    }
    dsh_sb_free(&request);

    /* Read the 101 response headers. */
    dsh_sb_init(&headers);
    for (;;) {
        char chunk[1024];
        int n = recv(ws->sock, chunk, (int)sizeof(chunk), 0);
        size_t i;

        if (n <= 0) {
            dsh_sb_free(&headers);
            dsh_sb_puts(error, "the webserver closed during the upgrade");
            dsh_ws_close(ws);
            return -1;
        }
        dsh_sb_put(&headers, chunk, (size_t)n);

        for (i = 0; i + 3 < headers.len; i++) {
            if (headers.buf[i] == '\r' && headers.buf[i + 1] == '\n' &&
                headers.buf[i + 2] == '\r' && headers.buf[i + 3] == '\n') {
                header_bytes = (int)(i + 4);
                break;
            }
        }
        if (header_bytes > 0) {
            break;
        }
        if (headers.len > 16384) {
            dsh_sb_free(&headers);
            dsh_sb_puts(error, "the upgrade response headers are too large");
            dsh_ws_close(ws);
            return -1;
        }
    }

    if (strncmp(headers.buf, "HTTP/1.1 101", 12) != 0 &&
        strncmp(headers.buf, "HTTP/1.0 101", 12) != 0) {
        char status[64];
        size_t copy = headers.len < 60 ? headers.len : 60;
        memcpy(status, headers.buf, copy);
        status[copy] = '\0';
        dsh_sb_printf(error, "the webserver refused the upgrade: %.48s", status);
        dsh_sb_free(&headers);
        dsh_ws_close(ws);
        return -1;
    }

    /* Validate Sec-WebSocket-Accept so a wrong endpoint cannot masquerade. */
    {
        uint8_t digest[DSH_SHA1_DIGEST_LEN];
        char expected[64];
        dsh_sha1_ctx sha;
        char *field;
        size_t field_len = 0;

        dsh_sha1_init(&sha);
        dsh_sha1_update(&sha, key_b64, strlen(key_b64));
        dsh_sha1_update(&sha, WS_GUID, strlen(WS_GUID));
        dsh_sha1_final(&sha, digest);
        dsh_base64_encode(digest, sizeof(digest), expected);

        /* Locate the accept header case-insensitively. */
        field = headers.buf;
        while (field != NULL && (size_t)(field - headers.buf) < (size_t)header_bytes) {
            char *line_end = strstr(field, "\r\n");
            char *colon = strchr(field, ':');
            if (line_end == NULL) {
                break;
            }
            if (colon != NULL && colon < line_end) {
                size_t name_len = (size_t)(colon - field);
                if (name_equals(field, "Sec-WebSocket-Accept", name_len)) {
                    char *value = colon + 1;
                    char *value_end = line_end;
                    while (value < value_end && (*value == ' ' || *value == '\t')) {
                        value++;
                    }
                    while (value_end > value && (value_end[-1] == '\r' || value_end[-1] == ' ')) {
                        value_end--;
                    }
                    field_len = (size_t)(value_end - value);
                    if (field_len >= sizeof(accept_header)) {
                        field_len = sizeof(accept_header) - 1;
                    }
                    memcpy(accept_header, value, field_len);
                    accept_header[field_len] = '\0';
                    break;
                }
            }
            field = line_end + 2;
        }

        if (field_len == 0 || strcmp(accept_header, expected) != 0) {
            dsh_sb_puts(error, "the webserver returned an invalid Sec-WebSocket-Accept");
            dsh_sb_free(&headers);
            dsh_ws_close(ws);
            return -1;
        }
    }

    dsh_sb_free(&headers);
    ws->open = 1;
    (void)scratch;
    return 0;
}

/* Writes a frame header plus payload. `opcode` is the low nibble of byte 0. */
static int send_frame(dsh_ws *ws, uint8_t opcode, const void *payload, size_t len) {
    uint8_t header[14];
    size_t header_len = 0;
    uint8_t mask[4];
    uint8_t *masked = NULL;
    size_t i;

    header[0] = (uint8_t)(0x80 | (opcode & 0x0f));

    if (len < 126) {
        header[1] = (uint8_t)(0x80 | (uint8_t)len);
        header_len = 2;
    } else if (len <= 0xffffu) {
        header[1] = 0x80 | 126;
        header[2] = (uint8_t)(len >> 8);
        header[3] = (uint8_t)(len);
        header_len = 4;
    } else {
        uint64_t v = (uint64_t)len;
        int k;
        header[1] = 0x80 | 127;
        for (k = 0; k < 8; k++) {
            header[2 + k] = (uint8_t)(v >> (56 - 8 * k));
        }
        header_len = 10;
    }

    if (dsh_random_bytes(mask, sizeof(mask)) != 0) {
        return -1;
    }
    memcpy(header + header_len, mask, sizeof(mask));
    header_len += sizeof(mask);

    if (len > 0) {
        masked = (uint8_t *)malloc(len);
        if (masked == NULL) {
            return -1;
        }
        for (i = 0; i < len; i++) {
            masked[i] = (uint8_t)(((const uint8_t *)payload)[i] ^ mask[i % 4]);
        }
    }

    if (dsh_net_write_full(ws->sock, header, header_len) != 0 ||
        (len > 0 && dsh_net_write_full(ws->sock, masked, len) != 0)) {
        free(masked);
        return -1;
    }

    free(masked);
    return 0;
}

int dsh_ws_send_text(dsh_ws *ws, const char *text, size_t len) {
    if (ws == NULL || !ws->open) {
        return -1;
    }
    return send_frame(ws, WS_OPCODE_TEXT, text, len);
}

/* Reads one frame into `payload` (up to cap). Returns 0 on success. */
static int read_frame(dsh_ws *ws, dsh_sb *payload, uint8_t *opcode_out, int *fin_out) {
    uint8_t header[2];
    uint64_t len;
    uint8_t mask[4];
    int masked;
    uint8_t *data;
    size_t i;

    if (read_full(ws->sock, header, 2) != 0) {
        return -1;
    }

    *fin_out = (header[0] & 0x80) ? 1 : 0;
    *opcode_out = (uint8_t)(header[0] & 0x0f);
    masked = (header[1] & 0x80) ? 1 : 0;
    len = (uint64_t)(header[1] & 0x7f);

    if (len == 126) {
        uint8_t ext[2];
        if (read_full(ws->sock, ext, 2) != 0) {
            return -1;
        }
        len = ((uint64_t)ext[0] << 8) | ext[1];
    } else if (len == 127) {
        uint8_t ext[8];
        int k;
        if (read_full(ws->sock, ext, 8) != 0) {
            return -1;
        }
        len = 0;
        for (k = 0; k < 8; k++) {
            len = (len << 8) | ext[k];
        }
    }

    if (len > WS_MAX_MESSAGE) {
        return -1;
    }

    if (masked) {
        if (read_full(ws->sock, mask, 4) != 0) {
            return -1;
        }
    }

    data = (uint8_t *)malloc((size_t)len + 1);
    if (data == NULL) {
        return -1;
    }

    if (len > 0 && read_full(ws->sock, data, (size_t)len) != 0) {
        free(data);
        return -1;
    }

    if (masked) {
        for (i = 0; i < (size_t)len; i++) {
            data[i] ^= mask[i % 4];
        }
    }

    dsh_sb_put(payload, data, (size_t)len);
    free(data);
    return 0;
}

int dsh_ws_recv(dsh_ws *ws, dsh_sb *out, int timeout_ms) {
    if (ws == NULL || !ws->open) {
        return -1;
    }

    for (;;) {
        int ready = wait_readable(ws->sock, timeout_ms);

        if (ready == 0) {
            return 0;
        }
        if (ready < 0) {
            return -2;
        }

        {
            dsh_sb frame;
            uint8_t opcode = 0;
            int fin = 0;
            int rc;

            dsh_sb_init(&frame);
            rc = read_frame(ws, &frame, &opcode, &fin);
            if (rc != 0) {
                dsh_sb_free(&frame);
                return -1;
            }

            if (opcode == WS_OPCODE_PING) {
                send_frame(ws, WS_OPCODE_PONG, frame.buf, frame.len);
                dsh_sb_free(&frame);
                continue;
            }
            if (opcode == WS_OPCODE_PONG) {
                dsh_sb_free(&frame);
                continue;
            }
            if (opcode == WS_OPCODE_CLOSE) {
                send_frame(ws, WS_OPCODE_CLOSE, frame.buf, frame.len);
                dsh_sb_free(&frame);
                ws->open = 0;
                return -1;
            }

            if (opcode == WS_OPCODE_TEXT || opcode == WS_OPCODE_BINARY ||
                opcode == WS_OPCODE_CONTINUATION) {
                dsh_sb_put(&ws->pending, frame.buf != NULL ? frame.buf : "", frame.len);
                dsh_sb_free(&frame);

                if (ws->pending.len > WS_MAX_MESSAGE) {
                    dsh_sb_reset(&ws->pending);
                    return -2;
                }

                if (!fin) {
                    continue; /* more fragments follow */
                }

                dsh_sb_put(out, ws->pending.buf != NULL ? ws->pending.buf : "", ws->pending.len);
                dsh_sb_reset(&ws->pending);
                return 1;
            }

            /* Unknown control or reserved opcode: ignore it. */
            dsh_sb_free(&frame);
        }
    }
}

void dsh_ws_close(dsh_ws *ws) {
    if (ws == NULL) {
        return;
    }
    if (ws->open && ws->sock != DSH_INVALID_SOCKET) {
        /* Best-effort close handshake; the peer may already be gone. */
        send_frame(ws, WS_OPCODE_CLOSE, NULL, 0);
    }
    if (ws->sock != DSH_INVALID_SOCKET) {
        dsh_net_close(ws->sock);
        ws->sock = DSH_INVALID_SOCKET;
    }
    ws->open = 0;
    dsh_sb_free(&ws->pending);
}

int dsh_ws_is_open(const dsh_ws *ws) {
    return ws != NULL && ws->open;
}
