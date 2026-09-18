/*
 * dsh_net.h - TCP helpers and the relay's JSON message vocabulary.
 *
 * Winsock initialization, full-length reads and writes, and a small blocking
 * connection list shared by the sender and the server.
 */
#ifndef DSH_NET_H
#define DSH_NET_H

#include <stddef.h>
#include <stdint.h>

#include "dsh_json.h"
#include "dsh_wire.h"

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET dsh_socket;
#define DSH_INVALID_SOCKET INVALID_SOCKET
#else
typedef int dsh_socket;
#define DSH_INVALID_SOCKET (-1)
#endif

#define DSH_NET_BACKLOG 32

/* Starts Winsock. Returns 0 on success; safe to call more than once. */
int dsh_net_init(void);
void dsh_net_shutdown(void);

/* Returns a printable socket error string for logs. */
const char *dsh_net_last_error(void);

/* Sets TCP_NODELAY and a short keepalive-ish send timeout. */
void dsh_net_configure(dsh_socket sock);

void dsh_net_close(dsh_socket sock);

/* Reads exactly `len` bytes. Returns 0 on success, -1 on EOF, -2 on error. */
int dsh_net_read_full(dsh_socket sock, void *buf, size_t len);
/* Writes exactly `len` bytes. Returns 0 on success, -1 on error. */
int dsh_net_write_full(dsh_socket sock, const void *buf, size_t len);

/* Listens on `port` for every interface. Returns DSH_INVALID_SOCKET on failure. */
dsh_socket dsh_net_listen(uint16_t port);

/* Connects to host:port with a bounded timeout in milliseconds. */
dsh_socket dsh_net_connect(const char *host, uint16_t port, int timeout_ms);

/* Resolves a dotted IPv4/6 literal or host name into a sockaddr_storage. */
int dsh_net_resolve(const char *host, uint16_t port, struct sockaddr_storage *out, int *out_len);

/* ── message vocabulary ──────────────────────────────────────────────────── */

/*
 * Application messages travel as JSON inside DSH_FRAME_DATA frames. The method
 * names deliberately mirror the dsh web RPC endpoints so the Wear client can
 * reuse the same vocabulary as the browser GUI.
 *
 * Envelope, one direction or the other:
 *
 *   { "t": "<kind>", "id": "<correlation>", "p": { ... } }
 *
 * The server never inspects `p` except for the routing fields it documents.
 */
typedef enum {
    DSH_MSG_UNKNOWN = 0,

    /* agent -> server */
    DSH_MSG_HELLO,          /* {t:"hello", p:{device, role, version, ...}}      */
    DSH_MSG_SESSIONS,       /* {t:"sessions", p:{sessions:[...]}}               */
    DSH_MSG_EVENTS,         /* {t:"events", p:{session, events:[...]}}          */
    DSH_MSG_SNAPSHOT,       /* {t:"snapshot", p:{session, messages:[...]}}      */
    DSH_MSG_STATE,          /* {t:"state", p:{...}} runtime status              */
    DSH_MSG_RESULT,         /* {t:"result", id:..., p:{ok, value|error}}        */
    DSH_MSG_ACK,            /* {t:"ack", id:...}                                */
    DSH_MSG_ERROR,          /* {t:"error", id:..., p:{code, message}}           */

    /* wear client -> server -> agent */
    DSH_MSG_REQUEST,        /* {t:"request", id:..., p:{method, payload}}       */
    DSH_MSG_PING,           /* {t:"ping"}                                       */
    DSH_MSG_PONG,           /* {t:"pong"}                                       */

    /* server -> wear client */
    DSH_MSG_HELLO_OK,       /* {t:"hello_ok", p:{server, salt?}}                */
    DSH_MSG_DEVICES        /* {t:"devices", p:{devices:[...]}}                 */
} dsh_msg_kind;

/* Returns the wire name for a message kind ("events", "request", ...). */
const char *dsh_msg_name(dsh_msg_kind kind);
/* Maps a wire name back to its kind, or DSH_MSG_UNKNOWN. */
dsh_msg_kind dsh_msg_kind_of(const char *name, size_t len);

/*
 * Reads one enveloped message from a socket. Handles framing, decryption and
 * allocation. On success the caller owns `*envelope` and must
 * dsh_message_free() it. Returns 0 on success, -1 on clean EOF, negative on a
 * protocol or transport failure.
 */
typedef struct {
    dsh_msg_kind kind;
    dsh_json    *root;   /* whole envelope, kept for field access */
    dsh_json    *payload;
    const char  *id;
    size_t       id_len;
    /*
     * The envelope exactly as it arrived. Forwarding relays this instead of
     * re-serializing the DOM, so numbers and key order survive untouched.
     */
    char        *raw;
    size_t       raw_len;
} dsh_message;

int dsh_message_read(dsh_socket sock, dsh_crypto *crypto, dsh_message *out);
void dsh_message_free(dsh_message *msg);

/*
 * Sends one enveloped message built from an already-serialized payload object.
 * `payload_json` may be NULL for messages without a payload.
 */
int dsh_message_send(dsh_socket sock, dsh_crypto *crypto, dsh_msg_kind kind,
                     const char *id, const char *payload_json, size_t payload_len);

/*
 * Seals an already-serialized envelope and writes it. Used by the relay to pass
 * a peer's bytes through without parsing them twice.
 */
int dsh_message_forward(dsh_socket sock, dsh_crypto *crypto,
                        const char *raw, size_t raw_len);

/* Sends a handshake frame (no crypto state yet). */
int dsh_send_plain(dsh_socket sock, uint8_t type, const void *payload, size_t len);

/*
 * Reads one handshake frame. `*payload` points into `buffer`, which the caller
 * owns and must keep alive while reading.
 */
int dsh_recv_plain(dsh_socket sock, uint8_t *buffer, size_t buffer_cap,
                   uint8_t *type_out, size_t *payload_len);

#endif /* DSH_NET_H */
