#include "dsh_net.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#endif

static int net_started = 0;
static char net_error[128] = "";

int dsh_net_init(void) {
#ifdef _WIN32
    WSADATA data;
    if (net_started) {
        return 0;
    }
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) {
        snprintf(net_error, sizeof(net_error), "WSAStartup failed");
        return -1;
    }
    net_started = 1;
#else
    net_started = 1;
#endif
    return 0;
}

void dsh_net_shutdown(void) {
#ifdef _WIN32
    if (net_started) {
        WSACleanup();
        net_started = 0;
    }
#else
    net_started = 0;
#endif
}

const char *dsh_net_last_error(void) {
#ifdef _WIN32
    int code = WSAGetLastError();
    snprintf(net_error, sizeof(net_error), "socket error %d", code);
#else
    snprintf(net_error, sizeof(net_error), "socket error %d", errno);
#endif
    return net_error;
}

void dsh_net_configure(dsh_socket sock) {
    int one = 1;
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, (const char *)&one, sizeof(one));
}

void dsh_net_close(dsh_socket sock) {
    if (sock == DSH_INVALID_SOCKET) {
        return;
    }
#ifdef _WIN32
    closesocket(sock);
#else
    close(sock);
#endif
}

int dsh_net_read_full(dsh_socket sock, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;

    while (got < len) {
        int n = recv(sock, (char *)(p + got), (int)(len - got), 0);
        if (n == 0) {
            return -1;
        }
        if (n < 0) {
#ifdef _WIN32
            int code = WSAGetLastError();
            if (code == WSAEINTR) {
                continue;
            }
#else
            if (errno == EINTR) {
                continue;
            }
#endif
            return -2;
        }
        got += (size_t)n;
    }
    return 0;
}

int dsh_net_write_full(dsh_socket sock, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t sent = 0;

    while (sent < len) {
        int n = send(sock, (const char *)(p + sent), (int)(len - sent), 0);
        if (n <= 0) {
#ifdef _WIN32
            int code = WSAGetLastError();
            if (code == WSAEINTR) {
                continue;
            }
#else
            if (errno == EINTR) {
                continue;
            }
#endif
            return -1;
        }
        sent += (size_t)n;
    }
    return 0;
}

int dsh_net_resolve(const char *host, uint16_t port, struct sockaddr_storage *out, int *out_len) {
    struct addrinfo hints;
    struct addrinfo *result = NULL;
    char service[16];
    int rc;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    snprintf(service, sizeof(service), "%u", (unsigned)port);

    rc = getaddrinfo(host, service, &hints, &result);
    if (rc != 0 || result == NULL) {
        snprintf(net_error, sizeof(net_error), "cannot resolve %s", host);
        if (result != NULL) {
            freeaddrinfo(result);
        }
        return -1;
    }

    if (result->ai_addrlen > sizeof(*out)) {
        freeaddrinfo(result);
        return -1;
    }

    memcpy(out, result->ai_addr, result->ai_addrlen);
    *out_len = (int)result->ai_addrlen;
    freeaddrinfo(result);
    return 0;
}

dsh_socket dsh_net_listen(uint16_t port) {
    struct sockaddr_storage addr;
    int addr_len = 0;
    dsh_socket sock;
    int one = 1;

    if (dsh_net_resolve("0.0.0.0", port, &addr, &addr_len) != 0) {
        return DSH_INVALID_SOCKET;
    }

    sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock == DSH_INVALID_SOCKET) {
        return DSH_INVALID_SOCKET;
    }

    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, (const char *)&one, sizeof(one));

    if (bind(sock, (struct sockaddr *)&addr, addr_len) != 0) {
        snprintf(net_error, sizeof(net_error), "bind failed on port %u: %s",
                 (unsigned)port, dsh_net_last_error());
        dsh_net_close(sock);
        return DSH_INVALID_SOCKET;
    }

    if (listen(sock, DSH_NET_BACKLOG) != 0) {
        snprintf(net_error, sizeof(net_error), "listen failed: %s", dsh_net_last_error());
        dsh_net_close(sock);
        return DSH_INVALID_SOCKET;
    }

    return sock;
}

dsh_socket dsh_net_connect(const char *host, uint16_t port, int timeout_ms) {
    struct sockaddr_storage addr;
    int addr_len = 0;
    dsh_socket sock;
    unsigned long nonblocking = 1;

    if (dsh_net_resolve(host, port, &addr, &addr_len) != 0) {
        return DSH_INVALID_SOCKET;
    }

    do {
        fd_set write_set;
        struct timeval tv;
        int rc;

        sock = socket(((struct sockaddr *)&addr)->sa_family, SOCK_STREAM, IPPROTO_TCP);
        if (sock == DSH_INVALID_SOCKET) {
            return DSH_INVALID_SOCKET;
        }

#ifdef _WIN32
        ioctlsocket(sock, FIONBIO, &nonblocking);
#else
        {
            int flags = fcntl(sock, F_GETFL, 0);
            fcntl(sock, F_SETFL, flags | O_NONBLOCK);
        }
#endif

        rc = connect(sock, (struct sockaddr *)&addr, addr_len);
        if (rc != 0) {
            int in_progress;
#ifdef _WIN32
            in_progress = (WSAGetLastError() == WSAEWOULDBLOCK);
#else
            in_progress = (errno == EINPROGRESS);
#endif
            if (!in_progress) {
                dsh_net_close(sock);
                sock = DSH_INVALID_SOCKET;
                break;
            }

            FD_ZERO(&write_set);
            FD_SET(sock, &write_set);
            tv.tv_sec = timeout_ms / 1000;
            tv.tv_usec = (timeout_ms % 1000) * 1000;

            rc = select((int)sock + 1, NULL, &write_set, NULL, &tv);
            if (rc <= 0) {
                snprintf(net_error, sizeof(net_error), "connect to %s:%u timed out",
                         host, (unsigned)port);
                dsh_net_close(sock);
                sock = DSH_INVALID_SOCKET;
                break;
            }
        }

        /* Restore blocking mode. */
        {
            unsigned long blocking = 0;
#ifdef _WIN32
            ioctlsocket(sock, FIONBIO, &blocking);
#else
            int flags = fcntl(sock, F_GETFL, 0);
            fcntl(sock, F_SETFL, flags & ~O_NONBLOCK);
#endif
        }

        dsh_net_configure(sock);
        return sock;
    } while (0);

    return DSH_INVALID_SOCKET;
}

/* ── message vocabulary ──────────────────────────────────────────────────── */

static const struct {
    dsh_msg_kind kind;
    const char  *name;
} MESSAGE_NAMES[] = {
    { DSH_MSG_HELLO,     "hello"     },
    { DSH_MSG_HELLO_OK,  "hello_ok"  },
    { DSH_MSG_SESSIONS,  "sessions"  },
    { DSH_MSG_EVENTS,    "events"    },
    { DSH_MSG_SNAPSHOT,  "snapshot"  },
    { DSH_MSG_STATE,     "state"     },
    { DSH_MSG_RESULT,    "result"    },
    { DSH_MSG_ACK,       "ack"       },
    { DSH_MSG_ERROR,     "error"     },
    { DSH_MSG_REQUEST,   "request"   },
    { DSH_MSG_PING,      "ping"      },
    { DSH_MSG_PONG,      "pong"      },
    { DSH_MSG_DEVICES,   "devices"   },
};

const char *dsh_msg_name(dsh_msg_kind kind) {
    size_t i;
    for (i = 0; i < sizeof(MESSAGE_NAMES) / sizeof(MESSAGE_NAMES[0]); i++) {
        if (MESSAGE_NAMES[i].kind == kind) {
            return MESSAGE_NAMES[i].name;
        }
    }
    return "unknown";
}

dsh_msg_kind dsh_msg_kind_of(const char *name, size_t len) {
    size_t i;
    if (name == NULL) {
        return DSH_MSG_UNKNOWN;
    }
    for (i = 0; i < sizeof(MESSAGE_NAMES) / sizeof(MESSAGE_NAMES[0]); i++) {
        if (strlen(MESSAGE_NAMES[i].name) == len &&
            memcmp(MESSAGE_NAMES[i].name, name, len) == 0) {
            return MESSAGE_NAMES[i].kind;
        }
    }
    return DSH_MSG_UNKNOWN;
}

int dsh_send_plain(dsh_socket sock, uint8_t type, const void *payload, size_t len) {
    dsh_sb frame;
    int rc;

    dsh_sb_init(&frame);
    rc = dsh_wire_seal_plain(type, payload, len, &frame);
    if (rc == 0) {
        rc = dsh_net_write_full(sock, frame.buf, frame.len);
    }
    dsh_sb_free(&frame);
    return rc;
}

int dsh_recv_plain(dsh_socket sock, uint8_t *buffer, size_t buffer_cap,
                   uint8_t *type_out, size_t *payload_len) {
    uint32_t body_len;
    int rc;

    if (buffer_cap < DSH_FRAME_HEADER_LEN) {
        return -3;
    }

    rc = dsh_net_read_full(sock, buffer, DSH_FRAME_HEADER_LEN);
    if (rc != 0) {
        return rc;
    }

    if (memcmp(buffer, DSH_WIRE_MAGIC, 4) != 0) {
        return -3;
    }

    body_len = ((uint32_t)buffer[12] << 24) | ((uint32_t)buffer[13] << 16) |
               ((uint32_t)buffer[14] << 8) | (uint32_t)buffer[15];

    if (body_len > DSH_FRAME_MAX_PAYLOAD) {
        return -3;
    }
    if (DSH_FRAME_HEADER_LEN + (size_t)body_len > buffer_cap) {
        return -3;
    }

    if (body_len > 0) {
        rc = dsh_net_read_full(sock, buffer + DSH_FRAME_HEADER_LEN, body_len);
        if (rc != 0) {
            return rc;
        }
    }

    {
        const uint8_t *payload = NULL;
        size_t len = 0;
        if (dsh_wire_open_plain(buffer, DSH_FRAME_HEADER_LEN + (size_t)body_len,
                                type_out, &payload, &len) != 0) {
            return -3;
        }
        /* Normalize in place so callers can read straight after the header. */
        if (payload != buffer + DSH_FRAME_HEADER_LEN && len > 0) {
            memmove(buffer + DSH_FRAME_HEADER_LEN, payload, len);
        }
        *payload_len = len;
    }

    return 0;
}

int dsh_message_send(dsh_socket sock, dsh_crypto *crypto, dsh_msg_kind kind,
                     const char *id, const char *payload_json, size_t payload_len) {
    dsh_sb envelope;
    int rc;

    dsh_sb_init(&envelope);
    dsh_sb_puts(&envelope, "{\"t\":");
    dsh_sb_put_json_string(&envelope, dsh_msg_name(kind), strlen(dsh_msg_name(kind)));

    if (id != NULL && id[0] != '\0') {
        dsh_sb_puts(&envelope, ",\"id\":");
        dsh_sb_put_json_string(&envelope, id, strlen(id));
    }

    if (payload_json != NULL && payload_len > 0) {
        dsh_sb_puts(&envelope, ",\"p\":");
        dsh_sb_put_json_raw(&envelope, payload_json, payload_len);
    }

    dsh_sb_putc(&envelope, '}');

    if (envelope.oom) {
        dsh_sb_free(&envelope);
        return -1;
    }

    {
        dsh_sb frame;
        dsh_sb_init(&frame);
        rc = dsh_wire_seal(crypto, DSH_FRAME_DATA, envelope.buf, envelope.len, &frame);
        if (rc == 0) {
            rc = dsh_net_write_full(sock, frame.buf, frame.len);
        }
        dsh_sb_free(&frame);
    }

    dsh_sb_free(&envelope);
    return rc;
}

int dsh_message_read(dsh_socket sock, dsh_crypto *crypto, dsh_message *out) {
    uint8_t header[DSH_FRAME_HEADER_LEN];
    uint8_t *frame = NULL;
    uint8_t *plain = NULL;
    uint32_t body_len;
    size_t total;
    size_t plain_len = 0;
    uint8_t type = 0;
    uint32_t seq = 0;
    int rc;

    memset(out, 0, sizeof(*out));

    rc = dsh_net_read_full(sock, header, sizeof(header));
    if (rc != 0) {
        return rc;
    }

    if (memcmp(header, DSH_WIRE_MAGIC, 4) != 0) {
        return -3;
    }
    if ((header[6] & 0x01u) != 0) {
        return -3;
    }

    body_len = ((uint32_t)header[12] << 24) | ((uint32_t)header[13] << 16) |
               ((uint32_t)header[14] << 8) | (uint32_t)header[15];

    if (body_len > DSH_FRAME_MAX_PAYLOAD) {
        return -3;
    }

    total = DSH_FRAME_HEADER_LEN + (size_t)body_len + DSH_FRAME_TAG_LEN;
    frame = (uint8_t *)malloc(total);
    plain = (uint8_t *)malloc((size_t)body_len + DSH_AES_BLOCK_LEN);
    if (frame == NULL || plain == NULL) {
        free(frame);
        free(plain);
        return -4;
    }

    memcpy(frame, header, sizeof(header));
    rc = dsh_net_read_full(sock, frame + DSH_FRAME_HEADER_LEN,
                           (size_t)body_len + DSH_FRAME_TAG_LEN);
    if (rc != 0) {
        free(frame);
        free(plain);
        return rc;
    }

    rc = dsh_wire_open(crypto, frame, total, plain, &plain_len, &type, &seq);
    free(frame);

    if (rc != 0) {
        free(plain);
        return -5;
    }

    if (type == DSH_FRAME_BYE || plain_len == 0) {
        free(plain);
        return -1;
    }

    out->root = dsh_json_parse((const char *)plain, plain_len);

    if (out->root == NULL) {
        /*
         * The frame authenticated and decrypted, so the keys agree — what
         * arrived simply is not JSON. Print the head of it: without this the
         * only symptom is "frame rejected (code -6)", which says nothing about
         * which side produced the bad payload or what it contained.
         */
        size_t shown = plain_len < 400 ? plain_len : 400;
        char preview[512];
        size_t i;

        for (i = 0; i < shown; i++) {
            unsigned char c = plain[i];
            preview[i] = (c >= 0x20 && c < 0x7f) ? (char)c : '.';
        }
        preview[shown] = '\0';

        printf("[warn] frame payload is not JSON (%zu bytes):\n%s\n", plain_len, preview);
        fflush(stdout);
        free(plain);
        return -6;
    }

    /* Keep a verbatim copy so relaying never re-serializes the payload. */
    out->raw = (char *)malloc(plain_len + 1);
    if (out->raw == NULL) {
        free(plain);
        dsh_json_free(out->root);
        out->root = NULL;
        return -4;
    }
    memcpy(out->raw, plain, plain_len);
    out->raw[plain_len] = '\0';
    out->raw_len = plain_len;
    free(plain);

    {
        const dsh_json *tag = dsh_json_get(out->root, "t");
        size_t name_len = 0;
        const char *name = dsh_json_string(tag, NULL, &name_len);

        out->kind = dsh_msg_kind_of(name, name_len);
        out->payload = (dsh_json *)dsh_json_get(out->root, "p");
        out->id = dsh_json_string(dsh_json_get(out->root, "id"), NULL, &out->id_len);
    }

    return 0;
}

void dsh_message_free(dsh_message *msg) {
    if (msg == NULL) {
        return;
    }
    dsh_json_free(msg->root);
    free(msg->raw);
    msg->root = NULL;
    msg->raw = NULL;
    msg->raw_len = 0;
    msg->payload = NULL;
    msg->id = NULL;
    msg->id_len = 0;
    msg->kind = DSH_MSG_UNKNOWN;
}

int dsh_message_forward(dsh_socket sock, dsh_crypto *crypto,
                        const char *raw, size_t raw_len) {
    dsh_sb frame;
    int rc;

    if (raw == NULL || raw_len == 0) {
        return -1;
    }

    dsh_sb_init(&frame);
    rc = dsh_wire_seal(crypto, DSH_FRAME_DATA, raw, raw_len, &frame);
    if (rc == 0) {
        rc = dsh_net_write_full(sock, frame.buf, frame.len);
    }
    dsh_sb_free(&frame);
    return rc;
}
