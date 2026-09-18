/*
 * server/main.c - dsh-relay-server
 *
 * The relay hub. It terminates two kinds of encrypted connections:
 *
 *   sender  (DSH_ROLE_AGENT)  the Windows program forwarding one local dsh
 *                             installation's sessions and events
 *   client  (DSH_ROLE_CLIENT) the Wear OS app the operator drives
 *
 * Data flows outward from a sender to every online client; commands flow back
 * from a client to the sender that owns the addressed device and its answer
 * returns to the asking client. The server keeps each sender's last known
 * session list, runtime state and a bounded event replay buffer, so a client
 * that joins late sees a coherent picture without asking for a resend.
 *
 * Everything after the handshake is AES-256-CBC plus HMAC-SHA256, keyed by the
 * shared passphrase. The server cannot be told to relay plaintext.
 *
 * Build: see build/build.ps1
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "../common/net/dsh_net.h"
#include "../common/ui/dsh_ui.h"
#include "../common/util/dsh_cfg.h"
#include "../common/util/dsh_log.h"

#include "server.h"

#ifdef _WIN32
#include <windows.h>
#else
/*
 * The relay also builds on POSIX hosts for LAN testing. The mutex is
 * deliberately not recursive: no code path may take g_lock twice, so a
 * nesting mistake deadlocks immediately under test instead of silently
 * working on Windows, whose CRITICAL_SECTION is recursive.
 */
#include <pthread.h>
#include <signal.h>
#include <unistd.h>
typedef pthread_mutex_t dsh_mutex;
static void dsh_mutex_init(dsh_mutex *m) { pthread_mutex_init(m, NULL); }
static void dsh_mutex_lock(dsh_mutex *m) { pthread_mutex_lock(m); }
static void dsh_mutex_unlock(dsh_mutex *m) { pthread_mutex_unlock(m); }
#define CRITICAL_SECTION dsh_mutex
#define InitializeCriticalSection(m) dsh_mutex_init(m)
#define EnterCriticalSection(m) dsh_mutex_lock(m)
#define LeaveCriticalSection(m) dsh_mutex_unlock(m)
#endif

#define DSH_SERVER_VERSION "1.0.0"
#define DSH_DEFAULT_AGENT_PORT DSH_SERVER_DEFAULT_AGENT_PORT
#define DSH_DEFAULT_CLIENT_PORT DSH_SERVER_DEFAULT_CLIENT_PORT
#define DSH_REPLAY_DEPTH 256
#define DSH_MAX_PEERS 64
#define DSH_SEND_TIMEOUT_MS 5000
#define DSH_HANDSHAKE_TIMEOUT_MS 15000
#define DSH_PENDING_TTL_SECONDS 120

typedef struct peer peer;
typedef struct pending pending;

struct peer {
    dsh_socket sock;
    dsh_crypto crypto;
    int        role;
    /* Role implied by the port this connection arrived on; the HELLO must agree. */
    int        expected_role;
    int        handshaked;
    char       id[96];
    char       name[128];
    char       host[64];
    char       dsh_version[32];
    char       dsh_home[256];
    char       remote[64];
    volatile int closing;
    time_t     connected_at;
    time_t     last_seen;
    peer      *next;

    /* Sender-only: the newest state a late client needs to catch up. */
    dsh_sb sessions_json;
    int    has_sessions;
    dsh_sb state_json;
    int    has_state;
    dsh_sb replay[DSH_REPLAY_DEPTH];
    int    replay_head;
    int    replay_count;
};

struct pending {
    char     id[96];
    char     device[96];
    peer    *client;
    time_t   at;
    pending *next;
};

static CRITICAL_SECTION g_lock;
static peer            *g_peers = NULL;
static pending         *g_pending = NULL;
static char             g_passphrase[512] = "";
static int              g_agent_port = DSH_DEFAULT_AGENT_PORT;
static int              g_client_port = DSH_DEFAULT_CLIENT_PORT;
static uint64_t         g_next_id = 1;
static volatile int     g_running = 1;
static uint64_t         g_stat_frames_in = 0;
static uint64_t         g_stat_frames_out = 0;

/* ── small helpers ───────────────────────────────────────────────────────── */

static void copy_str(char *dst, size_t cap, const char *src) {
    if (cap == 0) {
        return;
    }
    if (src == NULL) {
        dst[0] = '\0';
        return;
    }
    snprintf(dst, cap, "%s", src);
}

static const char *role_name(int role) {
    return role == DSH_ROLE_AGENT ? "sender" : "client";
}

static void set_send_timeout(dsh_socket sock, int ms) {
#ifdef _WIN32
    DWORD value = (DWORD)ms;
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, (const char *)&value, sizeof(value));
#else
    struct timeval tv;
    tv.tv_sec = ms / 1000;
    tv.tv_usec = (ms % 1000) * 1000;
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
#endif
}

static void set_recv_timeout(dsh_socket sock, int ms) {
#ifdef _WIN32
    DWORD value = (DWORD)ms;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char *)&value, sizeof(value));
#else
    struct timeval tv;
    tv.tv_sec = ms / 1000;
    tv.tv_usec = (ms % 1000) * 1000;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
#endif
}

/* ── peer registry ───────────────────────────────────────────────────────── */

static void registry_add_locked(peer *p) {
    p->next = g_peers;
    g_peers = p;
}

static void registry_remove(peer *p) {
    peer **link;

    EnterCriticalSection(&g_lock);
    link = &g_peers;
    while (*link != NULL) {
        if (*link == p) {
            *link = p->next;
            break;
        }
        link = &(*link)->next;
    }
    LeaveCriticalSection(&g_lock);
}

static peer *find_agent_locked(const char *id) {
    peer *p;

    for (p = g_peers; p != NULL; p = p->next) {
        if (p->role == DSH_ROLE_AGENT && strcmp(p->id, id) == 0) {
            return p;
        }
    }
    return NULL;
}

static int count_peers_locked(int role, int *total) {
    peer *p;
    int count = 0;

    *total = 0;
    for (p = g_peers; p != NULL; p = p->next) {
        (*total)++;
        if (p->role == role) {
            count++;
        }
    }
    return count;
}

/* Builds the device roster every client needs. Caller owns the builder. */
static void build_device_list(dsh_sb *out) {
    peer *p;
    int first = 1;

    dsh_sb_puts(out, "{\"devices\":[");
    for (p = g_peers; p != NULL; p = p->next) {
        char online[16];

        if (p->role != DSH_ROLE_AGENT) {
            continue;
        }

        if (!first) {
            dsh_sb_putc(out, ',');
        }
        first = 0;

        snprintf(online, sizeof(online), "%lld", (long long)p->last_seen);

        dsh_sb_puts(out, "{\"id\":");
        dsh_sb_put_json_string(out, p->id, strlen(p->id));
        dsh_sb_puts(out, ",\"name\":");
        dsh_sb_put_json_string(out, p->name, strlen(p->name));
        dsh_sb_puts(out, ",\"host\":");
        dsh_sb_put_json_string(out, p->host, strlen(p->host));
        dsh_sb_puts(out, ",\"dshVersion\":");
        dsh_sb_put_json_string(out, p->dsh_version, strlen(p->dsh_version));
        dsh_sb_puts(out, ",\"dshHome\":");
        dsh_sb_put_json_string(out, p->dsh_home, strlen(p->dsh_home));
        dsh_sb_puts(out, ",\"remote\":");
        dsh_sb_put_json_string(out, p->remote, strlen(p->remote));
        dsh_sb_puts(out, ",\"online\":true,\"lastSeen\":");
        dsh_sb_puts(out, online);
        dsh_sb_putc(out, '}');
    }
    dsh_sb_puts(out, "]}");
}

/* Sends one already-built payload to a single peer. Assumes the lock is held. */
static int deliver(peer *target, dsh_msg_kind kind, const char *id,
                   const char *payload, size_t payload_len) {
    int rc;

    if (target == NULL || target->closing || !target->handshaked) {
        return -1;
    }

    rc = dsh_message_send(target->sock, &target->crypto, kind, id, payload, payload_len);
    if (rc != 0) {
        target->closing = 1;
        return -1;
    }
    g_stat_frames_out++;
    return 0;
}

/* Relays raw envelope bytes unchanged; the payload is never re-serialized. */
static int deliver_raw(peer *target, const char *raw, size_t raw_len) {
    if (target == NULL || target->closing || !target->handshaked) {
        return -1;
    }
    if (dsh_message_forward(target->sock, &target->crypto, raw, raw_len) != 0) {
        target->closing = 1;
        return -1;
    }
    g_stat_frames_out++;
    return 0;
}

/* ── catch-up for new clients ────────────────────────────────────────────── */

static void send_catch_up_locked(peer *client) {
    peer *agent;

    for (agent = g_peers; agent != NULL; agent = agent->next) {
        int i;

        if (agent->role != DSH_ROLE_AGENT) {
            continue;
        }

        if (agent->has_sessions) {
            deliver(client, DSH_MSG_SESSIONS, NULL, agent->sessions_json.buf, agent->sessions_json.len);
        }
        if (agent->has_state) {
            deliver(client, DSH_MSG_STATE, NULL, agent->state_json.buf, agent->state_json.len);
        }

        /* Oldest to newest, so the client replays events in order. */
        for (i = 0; i < agent->replay_count; i++) {
            int index = (agent->replay_head - agent->replay_count + i + DSH_REPLAY_DEPTH * 2) % DSH_REPLAY_DEPTH;
            dsh_sb *item = &agent->replay[index];
            if (item->buf != NULL && item->len > 0) {
                deliver(client, DSH_MSG_EVENTS, NULL, item->buf, item->len);
            }
        }
    }
}

/* ── pending request bookkeeping ─────────────────────────────────────────── */

static void pending_add_locked(const char *id, size_t id_len, const char *device, peer *client) {
    pending *item = (pending *)calloc(1, sizeof(pending));

    if (item == NULL || id_len >= sizeof(item->id)) {
        free(item);
        return;
    }

    memcpy(item->id, id, id_len);
    item->id[id_len] = '\0';
    copy_str(item->device, sizeof(item->device), device);
    item->client = client;
    item->at = time(NULL);
    item->next = g_pending;
    g_pending = item;
}

static peer *pending_take_locked(const char *id, size_t id_len) {
    pending **link = &g_pending;

    while (*link != NULL) {
        pending *item = *link;
        if (strlen(item->id) == id_len && memcmp(item->id, id, id_len) == 0) {
            peer *client = item->client;
            *link = item->next;
            free(item);
            return client;
        }
        link = &(*link)->next;
    }
    return NULL;
}

static void pending_expire_locked(void) {
    pending **link = &g_pending;
    time_t now = time(NULL);

    while (*link != NULL) {
        pending *item = *link;
        if (now - item->at > DSH_PENDING_TTL_SECONDS) {
            *link = item->next;
            free(item);
        } else {
            link = &(*link)->next;
        }
    }
}

static void pending_drop_client_locked(peer *client) {
    pending **link = &g_pending;

    while (*link != NULL) {
        pending *item = *link;
        if (item->client == client) {
            *link = item->next;
            free(item);
        } else {
            link = &(*link)->next;
        }
    }
}

/* ── message dispatch ────────────────────────────────────────────────────── */

static void broadcast_to_clients(const char *raw, size_t raw_len, peer *except) {
    peer *p;

    EnterCriticalSection(&g_lock);
    for (p = g_peers; p != NULL; p = p->next) {
        if (p->role == DSH_ROLE_CLIENT && p != except) {
            deliver_raw(p, raw, raw_len);
        }
    }
    LeaveCriticalSection(&g_lock);
}

static void broadcast_device_list(void) {
    peer *p;
    dsh_sb list;

    dsh_sb_init(&list);
    EnterCriticalSection(&g_lock);
    build_device_list(&list);
    for (p = g_peers; p != NULL; p = p->next) {
        if (p->role == DSH_ROLE_CLIENT) {
            deliver(p, DSH_MSG_DEVICES, NULL, list.buf, list.len);
        }
    }
    LeaveCriticalSection(&g_lock);
    dsh_sb_free(&list);
}

static void handle_sender_message(peer *p, dsh_message *msg) {
    switch (msg->kind) {
    case DSH_MSG_HELLO: {
        const char *device = dsh_json_string(dsh_json_get(msg->payload, "device"), NULL, NULL);
        const char *host = dsh_json_string(dsh_json_get(msg->payload, "host"), NULL, NULL);
        const char *version = dsh_json_string(dsh_json_get(msg->payload, "dshVersion"), NULL, NULL);
        const char *home = dsh_json_string(dsh_json_get(msg->payload, "dshHome"), NULL, NULL);

        EnterCriticalSection(&g_lock);
        copy_str(p->id, sizeof(p->id), device != NULL ? device : p->name);
        copy_str(p->name, sizeof(p->name), device != NULL ? device : p->name);
        if (host != NULL) copy_str(p->host, sizeof(p->host), host);
        if (version != NULL) copy_str(p->dsh_version, sizeof(p->dsh_version), version);
        if (home != NULL) copy_str(p->dsh_home, sizeof(p->dsh_home), home);
        LeaveCriticalSection(&g_lock);

        DSH_INFO("sender online: id=%s host=%s dsh=%s home=%s",
                 p->id, p->host, p->dsh_version[0] ? p->dsh_version : "?", p->dsh_home);
        broadcast_device_list();
        break;
    }

    case DSH_MSG_SESSIONS:
        EnterCriticalSection(&g_lock);
        if (msg->raw_len > 0 && msg->payload != NULL) {
            dsh_sb_reset(&p->sessions_json);
            /*
             * Store the payload only; the envelope is rebuilt per client so a
             * late joiner gets a fresh sequence number.
             */
            dsh_json_write(msg->payload, &p->sessions_json);
            p->has_sessions = !p->sessions_json.oom;
        }
        LeaveCriticalSection(&g_lock);
        broadcast_to_clients(msg->raw, msg->raw_len, NULL);
        break;

    case DSH_MSG_STATE:
        EnterCriticalSection(&g_lock);
        if (msg->payload != NULL) {
            dsh_sb_reset(&p->state_json);
            dsh_json_write(msg->payload, &p->state_json);
            p->has_state = !p->state_json.oom;
        }
        LeaveCriticalSection(&g_lock);
        broadcast_to_clients(msg->raw, msg->raw_len, NULL);
        break;

    case DSH_MSG_EVENTS: {
        EnterCriticalSection(&g_lock);
        if (msg->raw_len > 0) {
            dsh_sb *slot = &p->replay[p->replay_head];
            dsh_sb_reset(slot);
            dsh_sb_put(slot, msg->raw, msg->raw_len);
            if (!slot->oom) {
                p->replay_head = (p->replay_head + 1) % DSH_REPLAY_DEPTH;
                if (p->replay_count < DSH_REPLAY_DEPTH) {
                    p->replay_count++;
                }
            }
        }
        LeaveCriticalSection(&g_lock);
        broadcast_to_clients(msg->raw, msg->raw_len, NULL);
        break;
    }

    /*
     * A session's opening window. It goes into the same ordered replay buffer
     * as the events that follow it, so a client that joins later receives the
     * snapshot before the tail rather than starting mid-conversation.
     */
    case DSH_MSG_SNAPSHOT: {
        EnterCriticalSection(&g_lock);
        if (msg->raw_len > 0) {
            dsh_sb *slot = &p->replay[p->replay_head];
            dsh_sb_reset(slot);
            dsh_sb_put(slot, msg->raw, msg->raw_len);
            if (!slot->oom) {
                p->replay_head = (p->replay_head + 1) % DSH_REPLAY_DEPTH;
                if (p->replay_count < DSH_REPLAY_DEPTH) {
                    p->replay_count++;
                }
            }
        }
        LeaveCriticalSection(&g_lock);
        broadcast_to_clients(msg->raw, msg->raw_len, NULL);
        break;
    }

    case DSH_MSG_RESULT:
    case DSH_MSG_ERROR:
    case DSH_MSG_ACK: {
        peer *client;

        EnterCriticalSection(&g_lock);
        client = pending_take_locked(msg->id, msg->id_len);
        if (client != NULL) {
            deliver_raw(client, msg->raw, msg->raw_len);
        }
        LeaveCriticalSection(&g_lock);

        if (client == NULL && msg->kind == DSH_MSG_ERROR) {
            DSH_WARN("sender reported an error for an unknown request id=%.*s",
                     (int)msg->id_len, msg->id != NULL ? msg->id : "");
        }
        break;
    }

    case DSH_MSG_PING:
        EnterCriticalSection(&g_lock);
        deliver(p, DSH_MSG_PONG, NULL, NULL, 0);
        LeaveCriticalSection(&g_lock);
        break;

    case DSH_MSG_PONG:
        break;

    default:
        DSH_DEBUG("sender sent unhandled message kind=%s", dsh_msg_name(msg->kind));
        break;
    }
}

static void handle_client_message(peer *p, dsh_message *msg) {
    switch (msg->kind) {
    case DSH_MSG_REQUEST: {
        const char *device;
        const char *method;
        peer *agent;

        if (msg->payload == NULL) {
            DSH_WARN("client sent a request without a payload");
            break;
        }

        device = dsh_json_string(dsh_json_get(msg->payload, "device"), NULL, NULL);
        method = dsh_json_string(dsh_json_get(msg->payload, "method"), NULL, NULL);

        EnterCriticalSection(&g_lock);

        if (device == NULL || device[0] == '\0') {
            /* Single-sender deployments do not need to name the device. */
            for (agent = g_peers; agent != NULL; agent = agent->next) {
                if (agent->role == DSH_ROLE_AGENT) {
                    break;
                }
            }
        } else {
            agent = find_agent_locked(device);
        }

        if (agent == NULL || agent->role != DSH_ROLE_AGENT) {
            dsh_sb error;
            dsh_sb_init(&error);
            dsh_sb_puts(&error, "{\"code\":\"relay/no-sender\",\"message\":");
            dsh_sb_puts(&error, device != NULL ? "\"no sender is connected for that device\"" :
                                                 "\"no sender is connected\"");
            dsh_sb_puts(&error, ",\"details\":{}}");
            deliver(p, DSH_MSG_ERROR, msg->id, error.buf, error.len);
            dsh_sb_free(&error);
            DSH_WARN("client request %.*s rejected: no sender",
                     (int)msg->id_len, msg->id != NULL ? msg->id : "");
            LeaveCriticalSection(&g_lock);
            break;
        }

        pending_add_locked(msg->id, msg->id_len, agent->id, p);
        deliver_raw(agent, msg->raw, msg->raw_len);

        DSH_INFO("relay request id=%.*s method=%s -> sender %s",
                 (int)msg->id_len, msg->id != NULL ? msg->id : "",
                 method != NULL ? method : "?", agent->id);

        LeaveCriticalSection(&g_lock);
        break;
    }

    case DSH_MSG_DEVICES: {
        /* A client may ask for a refresh by sending an empty devices message. */
        dsh_sb list;
        dsh_sb_init(&list);
        EnterCriticalSection(&g_lock);
        build_device_list(&list);
        deliver(p, DSH_MSG_DEVICES, msg->id, list.buf, list.len);
        LeaveCriticalSection(&g_lock);
        dsh_sb_free(&list);
        break;
    }

    case DSH_MSG_PING:
        EnterCriticalSection(&g_lock);
        deliver(p, DSH_MSG_PONG, msg->id, NULL, 0);
        LeaveCriticalSection(&g_lock);
        break;

    case DSH_MSG_HELLO:
        /* The encrypted hello carries the client's display name. */
        {
            const char *name = dsh_json_string(dsh_json_get(msg->payload, "device"), NULL, NULL);
            if (name != NULL && name[0] != '\0') {
                EnterCriticalSection(&g_lock);
                copy_str(p->name, sizeof(p->name), name);
                LeaveCriticalSection(&g_lock);
            }
        }
        break;

    default:
        DSH_DEBUG("client sent unhandled message kind=%s", dsh_msg_name(msg->kind));
        break;
    }
}

/* ── connection lifecycle ────────────────────────────────────────────────── */

static int do_handshake(peer *p) {
    uint8_t buffer[4096];
    uint8_t type = 0;
    size_t payload_len = 0;
    const uint8_t *payload = NULL;
    dsh_json *hello = NULL;
    uint8_t salt[16];
    uint8_t server_nonce[16];
    uint8_t client_nonce[16];
    uint8_t proof[DSH_SHA256_DIGEST_LEN];
    uint8_t expected[DSH_SHA256_DIGEST_LEN];
    size_t nonce_len = 0;
    const char *nonce_hex;
    const char *proof_hex;
    const char *name;
    long long role;
    dsh_sb ack;
    int rc = -1;

    rc = dsh_recv_plain(p->sock, buffer, sizeof(buffer), &type, &payload_len);
    if (rc != 0) {
        DSH_WARN("handshake: no HELLO from %s", p->remote);
        return -1;
    }
    if (type != DSH_FRAME_HELLO) {
        DSH_WARN("handshake: expected HELLO, got frame type %u", (unsigned)type);
        return -1;
    }

    payload = buffer + DSH_FRAME_HEADER_LEN;
    hello = dsh_json_parse((const char *)payload, payload_len);
    if (hello == NULL) {
        DSH_WARN("handshake: malformed HELLO from %s", p->remote);
        return -1;
    }

    role = dsh_json_integer(dsh_json_get(hello, "role"), 0);
    if (role != DSH_ROLE_AGENT && role != DSH_ROLE_CLIENT) {
        DSH_WARN("handshake: unknown role from %s", p->remote);
        dsh_json_free(hello);
        return -1;
    }

    /*
     * The port decides the role. A client presenting itself as a sender (or the
     * reverse) is refused here, before any key is derived, so the two trust
     * domains cannot be crossed by editing one field on the wire.
     */
    if ((int)role != p->expected_role) {
        DSH_WARN("handshake: refused a %s on the %s port (from %s)",
                 role_name((int)role), role_name(p->expected_role), p->remote);
        dsh_json_free(hello);
        return -1;
    }

    name = dsh_json_string(dsh_json_get(hello, "name"), "unnamed", NULL);
    nonce_hex = dsh_json_string(dsh_json_get(hello, "nonce"), NULL, NULL);
    proof_hex = dsh_json_string(dsh_json_get(hello, "proof"), NULL, NULL);

    if (nonce_hex == NULL || dsh_hex_decode(nonce_hex, strlen(nonce_hex),
                                           client_nonce, sizeof(client_nonce), &nonce_len) != 0 ||
        nonce_len != sizeof(client_nonce)) {
        DSH_WARN("handshake: bad nonce from %s", p->remote);
        dsh_json_free(hello);
        return -1;
    }

    if (proof_hex == NULL || dsh_hex_decode(proof_hex, strlen(proof_hex),
                                            proof, sizeof(proof), &nonce_len) != 0 ||
        nonce_len != sizeof(proof)) {
        DSH_WARN("handshake: bad proof from %s", p->remote);
        dsh_json_free(hello);
        return -1;
    }

    dsh_handshake_proof(g_passphrase, client_nonce, expected);
    if (!dsh_ct_equal(expected, proof, sizeof(expected))) {
        DSH_WARN("handshake: rejected %s from %s (wrong passphrase)",
                 role_name((int)role), p->remote);
        dsh_json_free(hello);
        return -1;
    }

    if (dsh_random_bytes(salt, sizeof(salt)) != 0 ||
        dsh_random_bytes(server_nonce, sizeof(server_nonce)) != 0) {
        DSH_ERROR("handshake: cannot obtain randomness");
        dsh_json_free(hello);
        return -1;
    }

    if (dsh_crypto_derive(&p->crypto, g_passphrase, salt, client_nonce, server_nonce, 1) != 0) {
        DSH_ERROR("handshake: key derivation failed");
        dsh_json_free(hello);
        return -1;
    }

    p->role = (int)role;
    copy_str(p->name, sizeof(p->name), name);

    dsh_sb_init(&ack);
    dsh_sb_puts(&ack, "{\"ok\":true,\"server\":\"dsh-relay\",\"version\":\"");
    dsh_sb_puts(&ack, DSH_SERVER_VERSION);
    dsh_sb_puts(&ack, "\",\"salt\":\"");
    {
        char hex[33];
        dsh_hex_encode(salt, sizeof(salt), hex);
        dsh_sb_puts(&ack, hex);
    }
    dsh_sb_puts(&ack, "\",\"nonce\":\"");
    {
        char hex[33];
        dsh_hex_encode(server_nonce, sizeof(server_nonce), hex);
        dsh_sb_puts(&ack, hex);
    }
    dsh_sb_puts(&ack, "\"}");

    if (dsh_send_plain(p->sock, DSH_FRAME_HELLO_ACK, ack.buf, ack.len) != 0) {
        DSH_WARN("handshake: cannot send ACK to %s", p->remote);
        dsh_sb_free(&ack);
        dsh_json_free(hello);
        return -1;
    }
    dsh_sb_free(&ack);

    /* Past the handshake the socket becomes a streaming channel again. */
    set_recv_timeout(p->sock, 0);

    p->handshaked = 1;
    p->last_seen = time(NULL);

    dsh_json_free(hello);
    return 0;
}

static void peer_init(peer *p, dsh_socket sock) {
    memset(p, 0, sizeof(*p));
    p->sock = sock;
    p->closing = 0;
    p->connected_at = time(NULL);
    dsh_sb_init(&p->sessions_json);
    dsh_sb_init(&p->state_json);
    {
        int i;
        for (i = 0; i < DSH_REPLAY_DEPTH; i++) {
            dsh_sb_init(&p->replay[i]);
        }
    }
}

static void peer_free(peer *p) {
    int i;

    dsh_crypto_wipe(&p->crypto);
    dsh_sb_free(&p->sessions_json);
    dsh_sb_free(&p->state_json);
    for (i = 0; i < DSH_REPLAY_DEPTH; i++) {
        dsh_sb_free(&p->replay[i]);
    }
    free(p);
}

static void connection_loop(peer *p) {
    for (;;) {
        dsh_message msg;
        int rc;

        rc = dsh_message_read(p->sock, &p->crypto, &msg);
        if (rc == -1) {
            DSH_INFO("%s %s disconnected", role_name(p->role), p->name);
            break;
        }
        if (rc != 0) {
            DSH_WARN("%s %s dropped: frame rejected (code %d)",
                     role_name(p->role), p->name, rc);
            break;
        }

        g_stat_frames_in++;
        p->last_seen = time(NULL);

        if (p->role == DSH_ROLE_AGENT) {
            handle_sender_message(p, &msg);
        } else {
            handle_client_message(p, &msg);
        }

        dsh_message_free(&msg);

        if (p->closing) {
            break;
        }
    }
}

#ifdef _WIN32
static DWORD WINAPI connection_thread(LPVOID arg) {
#else
static void *connection_thread(void *arg) {
#endif
    peer *p = (peer *)arg;

    set_recv_timeout(p->sock, DSH_HANDSHAKE_TIMEOUT_MS);

    if (do_handshake(p) != 0) {
        dsh_net_close(p->sock);
        peer_free(p);
#ifdef _WIN32
        return 0;
#else
        return NULL;
#endif
    }

    {
        int total = 0;
        int senders;
        int clients;

        EnterCriticalSection(&g_lock);
        p->id[0] = '\0';
        snprintf(p->id, sizeof(p->id), "%s-%llu",
                 p->name[0] ? p->name : role_name(p->role),
                 (unsigned long long)g_next_id++);
        senders = count_peers_locked(DSH_ROLE_AGENT, &total);
        clients = count_peers_locked(DSH_ROLE_CLIENT, &total);
        registry_add_locked(p);
        LeaveCriticalSection(&g_lock);

        DSH_INFO("%s connected: %s from %s (%d senders, %d clients)",
                 role_name(p->role), p->id, p->remote,
                 p->role == DSH_ROLE_AGENT ? senders + 1 : senders,
                 p->role == DSH_ROLE_CLIENT ? clients + 1 : clients);
    }

    if (p->role == DSH_ROLE_CLIENT) {
        dsh_sb list;
        dsh_sb_init(&list);

        EnterCriticalSection(&g_lock);
        build_device_list(&list);
        deliver(p, DSH_MSG_DEVICES, NULL, list.buf, list.len);
        send_catch_up_locked(p);
        pending_expire_locked();
        LeaveCriticalSection(&g_lock);

        dsh_sb_free(&list);
    } else {
        broadcast_device_list();
    }

    connection_loop(p);

    registry_remove(p);

    EnterCriticalSection(&g_lock);
    pending_drop_client_locked(p);
    LeaveCriticalSection(&g_lock);

    if (p->role == DSH_ROLE_AGENT) {
        broadcast_device_list();
    }

    dsh_net_close(p->sock);

    DSH_INFO("%s gone: %s", role_name(p->role), p->id);

    peer_free(p);

#ifdef _WIN32
    return 0;
#else
    return NULL;
#endif
}

static void start_thread(peer *p) {
#ifdef _WIN32
    HANDLE handle = CreateThread(NULL, 0, connection_thread, p, 0, NULL);
    if (handle == NULL) {
        DSH_ERROR("cannot start a connection thread");
        dsh_net_close(p->sock);
        peer_free(p);
        return;
    }
    CloseHandle(handle);
#else
    pthread_t thread;
    if (pthread_create(&thread, NULL, connection_thread, p) != 0) {
        DSH_ERROR("cannot start a connection thread");
        dsh_net_close(p->sock);
        peer_free(p);
        return;
    }
    pthread_detach(thread);
#endif
}

/* ── startup ─────────────────────────────────────────────────────────────── */

static void print_usage(const char *argv0) {
    printf("dsh-relay-server %s\n\n", DSH_SERVER_VERSION);
    printf("usage: %s [options]\n\n", argv0);
    printf("  --config PATH        read settings from PATH instead of config.json\n");
    printf("  --port N             sender port (default %d)\n", DSH_DEFAULT_AGENT_PORT);
    printf("  --client-port N      client port (default %d)\n", DSH_DEFAULT_CLIENT_PORT);
    printf("  --passphrase VALUE   shared secret; overrides the config file\n");
    printf("  --console            run without the window, as a console program\n");
    printf("  --verbose            log at debug level\n");
    printf("  --quiet              log errors only\n");
    printf("  --help               show this text\n\n");
    printf("The relay listens on two ports: senders connect to the sender port and\n");
    printf("clients to the client port, and the port a connection arrives on fixes\n");
    printf("its role. With no mode flag the server opens its window. Settings live in\n");
    printf("config.json beside this executable; it is created on first run.\n");
}

static void apply_log_level(const char *value) {
    if (value == NULL) {
        return;
    }
    if (strcmp(value, "debug") == 0) {
        dsh_log_set_level(DSH_LOG_DEBUG);
    } else if (strcmp(value, "warn") == 0) {
        dsh_log_set_level(DSH_LOG_WARN);
    } else if (strcmp(value, "error") == 0) {
        dsh_log_set_level(DSH_LOG_ERROR);
    } else {
        dsh_log_set_level(DSH_LOG_INFO);
    }
}

/* ── serving ─────────────────────────────────────────────────────────────── */

/*
 * Two listeners, not one. The port a connection arrives on decides what it is
 * allowed to be, so a peer cannot claim the other role in its HELLO. Bind
 * failures on the second port roll back the first, leaving nothing half-open.
 */
static dsh_socket g_agent_listener = DSH_INVALID_SOCKET;
static dsh_socket g_client_listener = DSH_INVALID_SOCKET;

int serve_start(uint16_t agent_port, uint16_t client_port) {
    if (g_agent_listener != DSH_INVALID_SOCKET || g_client_listener != DSH_INVALID_SOCKET) {
        return 0;
    }
    if (agent_port == client_port) {
        /* Two roles in one port would defeat the point of splitting them. */
        return -1;
    }

    g_agent_listener = dsh_net_listen(agent_port);
    if (g_agent_listener == DSH_INVALID_SOCKET) {
        return -1;
    }

    g_client_listener = dsh_net_listen(client_port);
    if (g_client_listener == DSH_INVALID_SOCKET) {
        dsh_net_close(g_agent_listener);
        g_agent_listener = DSH_INVALID_SOCKET;
        return -1;
    }

    DSH_INFO("sender port  %u", (unsigned)agent_port);
    DSH_INFO("client port  %u", (unsigned)client_port);

    g_running = 1;
    return 0;
}

void serve_stop(void) {
    dsh_socket closing;

    g_running = 0;

    closing = g_agent_listener;
    g_agent_listener = DSH_INVALID_SOCKET;
    if (closing != DSH_INVALID_SOCKET) {
        dsh_net_close(closing);
    }

    closing = g_client_listener;
    g_client_listener = DSH_INVALID_SOCKET;
    if (closing != DSH_INVALID_SOCKET) {
        dsh_net_close(closing);
    }
}

int serve_is_running(void) {
    return g_running != 0 &&
           g_agent_listener != DSH_INVALID_SOCKET &&
           g_client_listener != DSH_INVALID_SOCKET;
}

void serve_set_passphrase(const char *passphrase) {
    copy_str(g_passphrase, sizeof(g_passphrase),
             passphrase != NULL ? passphrase : "");
}

/* Accepts one connection on `listener` and starts its thread. */
static void accept_one(dsh_socket listener, int expected_role) {
    struct sockaddr_storage remote_addr;
    int addr_len = (int)sizeof(remote_addr);
    dsh_socket client_sock;
    peer *p;

    client_sock = accept(listener, (struct sockaddr *)&remote_addr, &addr_len);
    if (client_sock == DSH_INVALID_SOCKET) {
        return;
    }

    dsh_net_configure(client_sock);
    set_send_timeout(client_sock, DSH_SEND_TIMEOUT_MS);

    p = (peer *)malloc(sizeof(peer));
    if (p == NULL) {
        DSH_ERROR("out of memory accepting a connection");
        dsh_net_close(client_sock);
        return;
    }

    peer_init(p, client_sock);
    p->expected_role = expected_role;

    {
        char host[NI_MAXHOST];
        char service[NI_MAXSERV];
        if (getnameinfo((struct sockaddr *)&remote_addr, addr_len,
                        host, sizeof(host), service, sizeof(service),
                        NI_NUMERICHOST | NI_NUMERICSERV) == 0) {
            snprintf(p->remote, sizeof(p->remote), "%s:%s", host, service);
        } else {
            copy_str(p->remote, sizeof(p->remote), "unknown");
        }
    }

    start_thread(p);
}

void serve_loop(void) {
    while (g_running) {
        fd_set read_set;
        struct timeval tv;
        dsh_socket highest;
        int ready;

        if (g_agent_listener == DSH_INVALID_SOCKET || g_client_listener == DSH_INVALID_SOCKET) {
            break;
        }

        FD_ZERO(&read_set);
        FD_SET(g_agent_listener, &read_set);
        FD_SET(g_client_listener, &read_set);
        highest = g_agent_listener > g_client_listener ? g_agent_listener
                                                       : g_client_listener;

        tv.tv_sec = 0;
        tv.tv_usec = 200 * 1000;

        /* A short wait rather than a blocking accept, so serve_stop() takes
         * effect even if a listener failed to wake the call. */
        ready = select((int)highest + 1, &read_set, NULL, NULL, &tv);
        if (ready <= 0) {
            continue;
        }

        if (FD_ISSET(g_agent_listener, &read_set)) {
            accept_one(g_agent_listener, DSH_ROLE_AGENT);
        }
        if (FD_ISSET(g_client_listener, &read_set)) {
            accept_one(g_client_listener, DSH_ROLE_CLIENT);
        }
    }
}

DWORD WINAPI serve_thread_proc(LPVOID unused) {
    (void)unused;
    serve_loop();
    return 0;
}

void server_get_status(server_status *out) {
    peer *p;
    int rows = 0;

    if (out == NULL) {
        return;
    }
    memset(out, 0, sizeof(*out));

    EnterCriticalSection(&g_lock);
    out->running = serve_is_running();
    out->agent_listening = g_agent_listener != DSH_INVALID_SOCKET;
    out->client_listening = g_client_listener != DSH_INVALID_SOCKET;
    out->agent_port = g_agent_port;
    out->client_port = g_client_port;
    out->frames_in = g_stat_frames_in;
    out->frames_out = g_stat_frames_out;

    for (p = g_peers; p != NULL; p = p->next) {
        if (p->role == DSH_ROLE_AGENT) {
            out->senders++;
            out->replay_frames += (unsigned long long)p->replay_count;
            if (rows < DSH_SERVER_STATUS_SENDERS) {
                server_sender_row *row = &out->sender_rows[rows++];
                snprintf(row->id, sizeof(row->id), "%s", p->id);
                snprintf(row->name, sizeof(row->name), "%s", p->name);
                snprintf(row->host, sizeof(row->host), "%s", p->host);
                snprintf(row->remote, sizeof(row->remote), "%s", p->remote);
                snprintf(row->dsh_version, sizeof(row->dsh_version), "%s",
                         p->dsh_version[0] != '\0' ? p->dsh_version : "-");
                row->dsh_home_set = p->dsh_home[0] != '\0';
            }
        } else {
            out->clients++;
        }
    }
    LeaveCriticalSection(&g_lock);

    out->sender_count = rows;
}

#ifdef _WIN32
static BOOL WINAPI console_handler(DWORD signal) {
    if (signal == CTRL_C_EVENT || signal == CTRL_BREAK_EVENT || signal == CTRL_CLOSE_EVENT) {
        printf("\nshutting down\n");
        ExitProcess(0);
    }
    return FALSE;
}
#else
static void console_handler(int signal) {
    (void)signal;
    g_running = 0;
}
#endif

int main(int argc, char **argv) {
    dsh_cfg_file cfg;
    char cfg_path[DSH_CFG_PATH_LEN];
    const char *config_path = NULL;
    const char *passphrase_override = NULL;
    int port_override = -1;
    int client_port_override = -1;
    int verbose = 0;
    int quiet = 0;
    int console_mode = 0;
    int i;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            print_usage(argv[0]);
            return 0;
        } else if (strcmp(argv[i], "--config") == 0 && i + 1 < argc) {
            config_path = argv[++i];
        } else if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port_override = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--client-port") == 0 && i + 1 < argc) {
            client_port_override = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--passphrase") == 0 && i + 1 < argc) {
            passphrase_override = argv[++i];
        } else if (strcmp(argv[i], "--verbose") == 0) {
            verbose = 1;
        } else if (strcmp(argv[i], "--quiet") == 0) {
            quiet = 1;
        } else if (strcmp(argv[i], "--console") == 0) {
            /* Run without a window, as the relay did before it had one. */
            console_mode = 1;
        } else {
            fprintf(stderr, "unknown option: %s\n", argv[i]);
            print_usage(argv[0]);
            return 1;
        }
    }

    /*
     * Settings live in config.json beside the executable. Reading supplies a
     * default for every key the file omits; saving then writes the complete
     * file, so a first run leaves behind a config that documents itself.
     */
    if (config_path == NULL) {
        if (dsh_cfg_path_beside_exe(cfg_path, sizeof(cfg_path), "config.json") != 0) {
            snprintf(cfg_path, sizeof(cfg_path), "config.json");
        }
        config_path = cfg_path;
    }

    /* The window has no console, so route the log into its panel before the
     * first message a user needs to see. */
    if (!console_mode) {
        dsh_log_set_console(0);
        dsh_ui_log_attach();
    }

    if (dsh_cfg_open(&cfg, config_path) != 0) {
        fprintf(stderr, "cannot read config file: %s\n", config_path);
        return 1;
    }
    if (cfg.malformed) {
        DSH_WARN("%s is not valid JSON; running on defaults and archiving it as .bak",
                 config_path);
    }

    g_agent_port = dsh_cfg_int(&cfg, "port", DSH_DEFAULT_AGENT_PORT);
    if (port_override > 0) {
        g_agent_port = port_override;
        dsh_cfg_set_int(&cfg, "port", g_agent_port);
    }

    g_client_port = dsh_cfg_int(&cfg, "client_port", DSH_DEFAULT_CLIENT_PORT);
    if (client_port_override > 0) {
        g_client_port = client_port_override;
        dsh_cfg_set_int(&cfg, "client_port", g_client_port);
    }

    copy_str(g_passphrase, sizeof(g_passphrase),
             passphrase_override != NULL
                 ? passphrase_override
                 : dsh_cfg_str(&cfg, "passphrase", ""));
    if (passphrase_override != NULL) {
        dsh_cfg_set_str(&cfg, "passphrase", passphrase_override);
    }

    if (g_passphrase[0] != '\0' && strlen(g_passphrase) < 8) {
        DSH_WARN("the passphrase is shorter than 8 characters; the relay key is only as strong as this secret");
    }

    apply_log_level(dsh_cfg_str(&cfg, "log_level", "info"));
    if (verbose) {
        dsh_log_set_level(DSH_LOG_DEBUG);
        dsh_cfg_set_str(&cfg, "log_level", "debug");
    }
    if (quiet) {
        dsh_log_set_level(DSH_LOG_ERROR);
        dsh_cfg_set_str(&cfg, "log_level", "error");
    }

    if (dsh_cfg_save(&cfg) != 0) {
        DSH_WARN("cannot write %s; settings will not persist", config_path);
    } else if (dsh_cfg_created(&cfg)) {
        DSH_INFO("created default configuration at %s", config_path);
    }

#ifdef _WIN32
    InitializeCriticalSection(&g_lock);
    SetConsoleCtrlHandler(console_handler, TRUE);
#else
    {
        struct sigaction action;
        memset(&action, 0, sizeof(action));
        action.sa_handler = console_handler;
        sigaction(SIGINT, &action, NULL);
        sigaction(SIGTERM, &action, NULL);
        InitializeCriticalSection(&g_lock);
    }
#endif

    if (dsh_net_init() != 0) {
        DSH_ERROR("cannot initialize networking");
        return 1;
    }

    /*
     * With no mode flag the program opens its window, and the window owns
     * starting and stopping the relay. `--console` keeps the original
     * behaviour so scripts and the integration tests are unaffected.
     */
    if (!console_mode) {
        return server_ui_run(GetModuleHandleW(NULL), &cfg);
    }

    if (g_passphrase[0] == '\0') {
        fprintf(stderr,
                "refusing to start: no passphrase configured.\n"
                "Set one with --passphrase VALUE, or add 'passphrase = ...' to the config file.\n"
                "Every sender and client must use the same value.\n");
        dsh_net_shutdown();
        return 1;
    }

    if (g_agent_port == g_client_port) {
        DSH_ERROR("the sender port and the client port must differ (both are %d)",
                  g_agent_port);
        dsh_net_shutdown();
        return 1;
    }

    if (serve_start((uint16_t)g_agent_port, (uint16_t)g_client_port) != 0) {
        DSH_ERROR("cannot listen on ports %d and %d: %s",
                  g_agent_port, g_client_port, dsh_net_last_error());
        dsh_net_shutdown();
        return 1;
    }

    DSH_INFO("dsh-relay-server %s ready", DSH_SERVER_VERSION);
    DSH_INFO("cipher: AES-256-CBC + HMAC-SHA256, key derived from the shared passphrase");
    if (config_path != NULL) {
        DSH_INFO("config: %s", config_path);
    }
    DSH_INFO("press Ctrl+C to stop");

    serve_loop();

    serve_stop();
    dsh_net_shutdown();

    DSH_INFO("stopped after %llu inbound and %llu outbound frames",
             (unsigned long long)g_stat_frames_in,
             (unsigned long long)g_stat_frames_out);
    return 0;
}
