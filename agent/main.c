/*
 * agent/main.c - dsh-relay-sender
 *
 * Runs on the machine that hosts a local dsh installation. It does three
 * things:
 *
 *   1. Connects to the relay server inside the AES-256-CBC + HMAC-SHA256
 *      tunnel and announces which dsh installation it speaks for.
 *   2. Mirrors that installation outward: the session list, live session
 *      events, and the session-control baseline arrive here over dsh's own
 *      HTTP RPC surface and its `/api/remote.mux` WebSocket mux, and are
 *      forwarded to the server unchanged.
 *   3. Executes what the Wear client asks for by calling the same dsh RPC
 *      endpoints the browser GUI calls, then returns the answer.
 *
 * The sender is the only component that knows dsh's internal argument shapes;
 * the Wear client speaks the small vocabulary in METHOD_MAP below.
 *
 * Build: see build/build.ps1
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "../common/net/dsh_http.h"
#include "../common/net/dsh_net.h"
#include "../common/net/dsh_webauth.h"
#include "../common/net/dsh_ws.h"
#include "../common/ui/dsh_ui.h"
#include "../common/util/dsh_cfg.h"
#include "../common/util/dsh_log.h"

#include "agent.h"

#ifdef _WIN32
#include <windows.h>
#endif

#define DSH_AGENT_VERSION "1.0.0"

/*
 * dsh's `session/list` takes exactly one parameter and its wire name is
 * `_request`. Keeping it in one place means the argument bytes and their length
 * can never drift apart.
 */
#define DSH_ARGS_SESSION_LIST "{\"_request\":{}}"
#define MAX_FOLLOWS 8
#define LIST_POLL_MS 3000
#define PING_INTERVAL_MS 25000
#define RELAY_RECONNECT_MS 3000

/* How often to re-authenticate with a local dsh that was down at startup, and
 * how many consecutive RPC failures mean an established link has gone away. */
#define DSH_RETRY_MS 5000
#define DSH_MAX_FAILURES 3

typedef struct {
    char      session_id[192];
    char      stream_id[32];
    long long cursor;
    int       active;
    /* When this stream began, so a full table can evict the oldest. */
    unsigned long long started_ms;
} follow_stream;

typedef struct {
    /* configuration */
    char     server_host[256];
    uint16_t server_port;
    char     passphrase[512];
    char     dsh_base[256];
    char     dsh_token[712];
    char     dsh_home[512];
    char     device_name[128];
    int      poll_ms;
    int      verbose;

    /* relay side */
    dsh_socket relay_sock;
    dsh_crypto crypto;
    int        relay_ready;
    char       agent_id[128];

    /* dsh side */
    dsh_http http;
    dsh_ws   ws;
    int      dsh_ready;
    int      ws_ready;
    char     control_stream_id[32];
    int      control_subscribed;

    /*
     * The Gateway's forwarded-event stream.
     *
     * Approvals and agent questions are not RPC methods: the Host holds a
     * waterfall listener open and waits for a client to answer through it. The
     * frames arrive here as `waterfall` items carrying an eventId, and the
     * answer goes back through `$events/result`. Without this stream a watch
     * could see that a decision was pending but had no way to make it.
     */
    char     events_stream_id[32];
    int      events_subscribed;
    char     events_client_id[64];

    /* workspace/follow: carries the authoritative archived-session set. */
    char     workspace_stream_id[32];
    int      workspace_subscribed;

    follow_stream follows[MAX_FOLLOWS];
    int           next_stream_num;

    dsh_sb sessions_cache;

    /*
     * Summaries of sessions that have since left the session list.
     *
     * dsh omits archived sessions from `session/list` entirely, so once one is
     * archived its title and directory are unrecoverable from the list itself.
     * Keeping the copy the sender last saw is the only way the client can show
     * an archived row as anything other than a bare id.
     */
    dsh_sb vanished_digests;

    /*
     * The archived-session ids, as last published by the workspace feed.
     *
     * Forwarded with every session list rather than relying on the client to
     * have caught the feed frame itself: the list arrives on its own schedule,
     * and a client that connected after the feed's baseline would otherwise
     * treat every archived session as an ordinary one.
     */
    dsh_sb archived_ids;

    /*
     * The Workspace views, as last published by the feed.
     *
     * The client groups sessions by Workspace membership (`workspace.sessionIds`),
     * which is how the web UI decides what belongs to a workspace and what
     * trails under Ungrouped. `cwd` alone cannot answer that: two sessions in
     * the same directory can still differ in account, and an unassigned session
     * has no usable directory at all.
     */
    dsh_sb workspaces;

    unsigned long long next_list_poll;
    unsigned long long next_ping;
    unsigned long long next_reconnect;

    /* lifetime and reporting */
    volatile int running;
    char         last_error[256];
    unsigned long long frames_in;
    unsigned long long frames_out;

    /* dsh link health: retried on a timer, dropped after repeated failures. */
    unsigned long long next_dsh_try;
    int      dsh_failures;
} agent_state;

/*
 * One sender per process, matching the console front end's own assumption: the
 * window and the loop must see the same connection state.
 */
static agent_state *g_agent = NULL;

/* ── clock ───────────────────────────────────────────────────────────────── */

static unsigned long long now_ms(void) {
#ifdef _WIN32
    return (unsigned long long)GetTickCount64();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (unsigned long long)ts.tv_sec * 1000ull + (unsigned long long)(ts.tv_nsec / 1000000);
#endif
}

/* ── relay transport ─────────────────────────────────────────────────────── */

static int relay_send(agent_state *a, dsh_msg_kind kind, const char *id,
                      const char *payload, size_t payload_len) {
    if (!a->relay_ready) {
        return -1;
    }
    if (dsh_message_send(a->relay_sock, &a->crypto, kind, id, payload, payload_len) != 0) {
        DSH_WARN("relay link failed while sending %s", dsh_msg_name(kind));
        snprintf(a->last_error, sizeof(a->last_error), "中继连接中断");
        a->relay_ready = 0;
        return -1;
    }
    a->frames_out++;
    return 0;
}

/* Builds the sender identity message the server uses as the device roster. */
static void send_hello(agent_state *a) {
    dsh_sb payload;
    char host[128] = "unknown";
    const char *version = "unknown";
    const char *home = getenv("DSH_HOME");

#ifdef _WIN32
    {
        DWORD size = sizeof(host);
        if (!GetComputerNameA(host, &size)) {
            strcpy(host, "unknown");
        }
    }
#endif

    dsh_sb_init(&payload);
    dsh_sb_puts(&payload, "{\"device\":");
    dsh_sb_put_json_string(&payload, a->device_name, strlen(a->device_name));
    dsh_sb_puts(&payload, ",\"host\":");
    dsh_sb_put_json_string(&payload, host, strlen(host));
    dsh_sb_puts(&payload, ",\"dshVersion\":");
    dsh_sb_put_json_string(&payload, version, strlen(version));
    dsh_sb_puts(&payload, ",\"dshHome\":");
    dsh_sb_put_json_string(&payload, home != NULL ? home : "", home != NULL ? strlen(home) : 0);
    dsh_sb_puts(&payload, ",\"agentVersion\":\"" DSH_AGENT_VERSION "\"");
    dsh_sb_printf(&payload, ",\"dshReachable\":%s", a->dsh_ready ? "true" : "false");
    dsh_sb_puts(&payload, ",\"capabilities\":[\"session/list\",\"session/page\",\"session/prompt\","
                          "\"session/cancel\",\"session/rename\",\"session/fork\","
                          "\"workspace/archiveSession\",\"session/updateQueue\","
                          "\"session/selectModel\",\"session/modelCatalog\","
                          "\"commands/list\",\"commands/execute\",\"skills/list\"]}");
    relay_send(a, DSH_MSG_HELLO, NULL, payload.buf, payload.len);
    dsh_sb_free(&payload);
}

static int relay_handshake(agent_state *a) {
    uint8_t client_nonce[16];
    uint8_t proof[DSH_SHA256_DIGEST_LEN];
    uint8_t salt[16];
    uint8_t server_nonce[16];
    dsh_sb hello;
    uint8_t buffer[8192];
    uint8_t type = 0;
    size_t payload_len = 0;
    char hex[80];
    size_t got = 0;
    dsh_json *root = NULL;
    int rc;

    if (dsh_random_bytes(client_nonce, sizeof(client_nonce)) != 0) {
        DSH_ERROR("cannot obtain randomness");
        return -1;
    }

    dsh_handshake_proof(a->passphrase, client_nonce, proof);

    dsh_sb_init(&hello);
    dsh_sb_puts(&hello, "{\"role\":1,\"name\":");
    dsh_sb_put_json_string(&hello, a->device_name, strlen(a->device_name));
    dsh_sb_puts(&hello, ",\"nonce\":\"");
    dsh_hex_encode(client_nonce, sizeof(client_nonce), hex);
    dsh_sb_puts(&hello, hex);
    dsh_sb_puts(&hello, "\",\"proof\":\"");
    dsh_hex_encode(proof, sizeof(proof), hex);
    dsh_sb_puts(&hello, hex);
    dsh_sb_puts(&hello, "\"}");

    if (dsh_send_plain(a->relay_sock, DSH_FRAME_HELLO, hello.buf, hello.len) != 0) {
        DSH_WARN("cannot send HELLO to the relay");
        dsh_sb_free(&hello);
        return -1;
    }
    dsh_sb_free(&hello);

    rc = dsh_recv_plain(a->relay_sock, buffer, sizeof(buffer), &type, &payload_len);
    if (rc != 0 || type != DSH_FRAME_HELLO_ACK) {
        DSH_WARN("the relay did not answer the handshake");
        return -1;
    }

    root = dsh_json_parse((const char *)(buffer + DSH_FRAME_HEADER_LEN), payload_len);
    if (root == NULL) {
        DSH_WARN("the relay sent a malformed HELLO_ACK");
        return -1;
    }

    if (!dsh_json_bool(dsh_json_get(root, "ok"), 0)) {
        DSH_WARN("the relay rejected this sender");
        dsh_json_free(root);
        return -1;
    }

    {
        const char *salt_hex = dsh_json_string(dsh_json_get(root, "salt"), NULL, NULL);
        const char *nonce_hex = dsh_json_string(dsh_json_get(root, "nonce"), NULL, NULL);

        if (salt_hex == NULL || nonce_hex == NULL ||
            dsh_hex_decode(salt_hex, strlen(salt_hex), salt, sizeof(salt), &got) != 0 ||
            got != sizeof(salt) ||
            dsh_hex_decode(nonce_hex, strlen(nonce_hex), server_nonce, sizeof(server_nonce), &got) != 0 ||
            got != sizeof(server_nonce)) {
            DSH_WARN("the relay sent an unusable salt or nonce");
            dsh_json_free(root);
            return -1;
        }
    }

    dsh_json_free(root);

    if (dsh_crypto_derive(&a->crypto, a->passphrase, salt, client_nonce, server_nonce, 0) != 0) {
        DSH_ERROR("key derivation failed");
        return -1;
    }

    a->relay_ready = 1;
    DSH_INFO("relay link established (AES-256-CBC + HMAC-SHA256)");
    send_hello(a);
    return 0;
}

static int relay_connect(agent_state *a) {
    dsh_socket sock;

    sock = dsh_net_connect(a->server_host, a->server_port, 5000);
    if (sock == DSH_INVALID_SOCKET) {
        return -1;
    }

    a->relay_sock = sock;
    a->relay_ready = 0;

    if (relay_handshake(a) != 0) {
        dsh_net_close(sock);
        a->relay_sock = DSH_INVALID_SOCKET;
        return -1;
    }

    return 0;
}

/* ── dsh side ────────────────────────────────────────────────────────────── */

static void dsh_send_stream_frame(agent_state *a, const char *stream_id,
                                  const char *endpoint, const char *args_json) {
    dsh_sb frame;

    dsh_sb_init(&frame);
    dsh_sb_puts(&frame, "{\"type\":\"open\",\"streamId\":");
    dsh_sb_put_json_string(&frame, stream_id, strlen(stream_id));
    dsh_sb_puts(&frame, ",\"endpoint\":");
    dsh_sb_put_json_string(&frame, endpoint, strlen(endpoint));
    dsh_sb_puts(&frame, ",\"payload\":{\"args\":");
    dsh_sb_puts(&frame, args_json != NULL ? args_json : "{}");
    dsh_sb_puts(&frame, "}}");

    dsh_ws_send_text(&a->ws, frame.buf, frame.len);
    dsh_sb_free(&frame);
}

static void dsh_cancel_stream(agent_state *a, const char *stream_id) {
    dsh_sb frame;

    dsh_sb_init(&frame);
    dsh_sb_puts(&frame, "{\"type\":\"cancel\",\"streamId\":");
    dsh_sb_put_json_string(&frame, stream_id, strlen(stream_id));
    dsh_sb_puts(&frame, "}");

    dsh_ws_send_text(&a->ws, frame.buf, frame.len);
    dsh_sb_free(&frame);
}

static int dsh_connect(agent_state *a) {
    dsh_sb error;

    dsh_sb_init(&error);

    if (a->dsh_token[0] != '\0') {
        if (dsh_http_login(&a->http, a->dsh_token) != 0) {
            DSH_WARN("dsh authentication failed; check dsh_token against the URL printed by `dsh web`");
            dsh_sb_free(&error);
            return -1;
        }
        DSH_INFO("authenticated with the local dsh webserver");
    } else {
        /*
         * No token configured: mint a session cookie locally from the signing
         * secret dsh persists in its credentials file. A `dsh web` launch
         * token only exists in the dsh process's memory, so this is the only
         * credential the sender can pick up on its own.
         */
        char secret[DSH_WEBAUTH_SECRET_LEN];
        char cookie[512];
        char yaml_path[600];
        long long now = (long long)time(NULL) * 1000;

        snprintf(yaml_path, sizeof(yaml_path), "%.480s\\.credentials.yaml", a->dsh_home);
        if (dsh_webauth_secret_from_file(yaml_path, secret, sizeof(secret)) == 0 &&
            dsh_webauth_cookie(secret, a->http.authority,
                               now - 60000, now + 3600000,
                               cookie, sizeof(cookie)) == 0) {
            snprintf(a->http.cookie, sizeof(a->http.cookie), "%s", cookie);
            a->http.logged_in = 1;
            DSH_INFO("minted a dsh session cookie from %s", yaml_path);
        } else {
            DSH_WARN("no dsh_token configured and %s has no usable signing secret; "
                     "run `dsh web` once to create it, or fill dsh_token", yaml_path);
            dsh_sb_free(&error);
            return -1;
        }
    }

    /* One cheap call proves the token and the endpoint shape both work. */
    {
        dsh_sb value;
        dsh_sb_init(&value);
        if (dsh_rpc_call(&a->http, "session/list",
                         DSH_ARGS_SESSION_LIST, sizeof(DSH_ARGS_SESSION_LIST) - 1,
                         &value, &error, NULL) != 0) {
            DSH_WARN("dsh rejected session/list: %s", error.buf != NULL ? error.buf : "unknown");
            dsh_sb_free(&value);
            dsh_sb_free(&error);
            return -1;
        }
        dsh_sb_free(&value);
    }

    a->dsh_ready = 1;

    if (dsh_ws_connect(&a->http, "/api/remote.mux", &a->ws, &error) == 0) {
        a->ws_ready = 1;
        DSH_INFO("dsh event mux open at /api/remote.mux");
    } else {
        DSH_WARN("dsh event mux unavailable: %s", error.buf != NULL ? error.buf : "unknown");
    }

    dsh_sb_free(&error);
    return 0;
}

/* Defined with the follow streams below; declared here because dropping a dead
 * dsh link has to tear them down. */
static void stop_all_follows(agent_state *a);

/* Defined with the other stream subscriptions below; declared here because a
 * client can ask for the forwarded-event stream to be re-opened. */
static void subscribe_events(agent_state *a);

/* Pulls the session list and forwards it when it changed. */
/*
 * Records the summaries of sessions present in `previous` but absent from `now`.
 *
 * Called with the list the sender held before this refresh, so a session that
 * has just been archived is still described by the copy from a moment ago.
 */
static void capture_vanished(agent_state *a, const char *previous, size_t previous_len,
                             const char *now, size_t now_len) {
    dsh_json *before;
    dsh_json *after;
    const dsh_json *old_items;
    const dsh_json *new_items;
    dsh_sb fresh;
    int written = 0;

    if (previous == NULL || previous_len == 0) {
        return;
    }

    before = dsh_json_parse(previous, previous_len);
    after = dsh_json_parse(now != NULL ? now : "", now_len);
    old_items = (before != NULL) ? dsh_json_get(before, "items") : NULL;
    new_items = (after != NULL) ? dsh_json_get(after, "items") : NULL;

    if (old_items == NULL || old_items->type != DSH_JSON_ARR) {
        dsh_json_free(before);
        dsh_json_free(after);
        return;
    }

    /*
     * Rebuilt from scratch each pass. It describes the sessions the current
     * list does not carry, not a history of everything that ever left it —
     * appending would repeat ids and grow without bound.
     */
    dsh_sb_init(&fresh);
    dsh_sb_puts(&fresh, "[");

    {
        size_t i;

        for (i = 0; i < old_items->u.arr.count; i++) {
            const dsh_json *item = old_items->u.arr.items[i];
            const char *id = dsh_json_string(dsh_json_get(item, "sessionId"), "", NULL);
            int still_there = 0;

            if (id[0] == '\0') {
                continue;
            }
            if (new_items != NULL && new_items->type == DSH_JSON_ARR) {
                size_t j;
                for (j = 0; j < new_items->u.arr.count; j++) {
                    const char *other = dsh_json_string(
                        dsh_json_get(new_items->u.arr.items[j], "sessionId"), "", NULL);
                    if (strcmp(other, id) == 0) {
                        still_there = 1;
                        break;
                    }
                }
            }
            if (!still_there) {
                if (written > 0) {
                    dsh_sb_puts(&fresh, ",");
                }
                dsh_json_write(item, &fresh);
                written++;
            }
        }
    }

    dsh_sb_puts(&fresh, "]");

    dsh_sb_reset(&a->vanished_digests);
    dsh_sb_put(&a->vanished_digests, fresh.buf != NULL ? fresh.buf : "[]",
               fresh.buf != NULL ? fresh.len : 2);
    dsh_sb_free(&fresh);

    dsh_json_free(before);
    dsh_json_free(after);
}

/* ── trimming the session list ──────────────────────────────────────────── */

/*
 * Projections the watch actually reads.
 *
 * Two lists, because what a session needs depends on whether it is the one on
 * screen. The watch folds projections into state for the open session only —
 * the rest of the list is drawn from `title` and `sessionStats` — yet the same
 * `permissions` table and `modelSelection` block were sent for every session.
 * Measured over a real list, those two were 99% and 96% duplicate: 47 KB
 * carrying 1 KB of information, decrypted and parsed 136 times to be discarded
 * 135 times.
 */
static int projection_is_wanted(const char *key, size_t len, int opened) {
    static const char *const opened_keys[] = {
        "title", "sessionStats", "modelSelection", "permissions",
        "goal", "todos", "agentPreset"
    };
    static const char *const listed_keys[] = {
        "title", "sessionStats"
    };
    const char *const *wanted = opened ? opened_keys : listed_keys;
    size_t count = opened
        ? sizeof(opened_keys) / sizeof(opened_keys[0])
        : sizeof(listed_keys) / sizeof(listed_keys[0]);
    size_t i;

    for (i = 0; i < count; i++) {
        if (strlen(wanted[i]) == len && memcmp(wanted[i], key, len) == 0) {
            return 1;
        }
    }
    return 0;
}

/* Writes `projections.values` keeping only the keys the watch reads. */
static void write_trimmed_values(const dsh_json *values, dsh_sb *out, int opened) {
    size_t i;
    int written = 0;

    dsh_sb_puts(out, "{");
    for (i = 0; i < values->u.obj.count; i++) {
        const char *key = values->u.obj.keys[i];
        size_t key_len = values->u.obj.keylens[i];

        if (!projection_is_wanted(key, key_len, opened)) {
            continue;
        }
        if (written) {
            dsh_sb_puts(out, ",");
        }
        dsh_sb_put_json_string(out, key, key_len);
        dsh_sb_puts(out, ":");
        dsh_json_write(values->u.obj.vals[i], out);
        written = 1;
    }
    dsh_sb_puts(out, "}");
}

/* True when [session] is one the watch is currently following. */
static int session_is_followed(const agent_state *a, const dsh_json *session) {
    const char *id = dsh_json_string(dsh_json_get(session, "sessionId"), "", NULL);
    size_t i;

    if (id[0] == '\0') {
        return 0;
    }
    for (i = 0; i < MAX_FOLLOWS; i++) {
        if (a->follows[i].active &&
            strcmp(a->follows[i].session_id, id) == 0) {
            return 1;
        }
    }
    return 0;
}

/* Writes the session array, trimming each session's projections. */
static void write_trimmed_sessions(const agent_state *a, const dsh_json *items, dsh_sb *out) {
    size_t i;

    dsh_sb_puts(out, "[");
    for (i = 0; i < items->u.arr.count; i++) {
        const dsh_json *session = items->u.arr.items[i];
        size_t k;
        int written = 0;
        int opened;

        if (i > 0) {
            dsh_sb_puts(out, ",");
        }
        if (session == NULL || session->type != DSH_JSON_OBJ) {
            dsh_sb_puts(out, "{}");
            continue;
        }
        opened = session_is_followed(a, session);

        dsh_sb_puts(out, "{");
        for (k = 0; k < session->u.obj.count; k++) {
            const char *key = session->u.obj.keys[k];
            size_t key_len = session->u.obj.keylens[k];
            const dsh_json *val = session->u.obj.vals[k];
            const dsh_json *values = NULL;

            if (val != NULL && val->type == DSH_JSON_OBJ &&
                key_len == strlen("projections") &&
                memcmp("projections", key, key_len) == 0) {
                const dsh_json *inner = dsh_json_get(val, "values");
                if (inner != NULL && inner->type == DSH_JSON_OBJ) {
                    values = inner;
                }
            }

            if (written) {
                dsh_sb_puts(out, ",");
            }
            dsh_sb_put_json_string(out, key, key_len);
            dsh_sb_puts(out, ":");
            if (values != NULL) {
                dsh_sb_puts(out, "{\"values\":");
                write_trimmed_values(values, out, opened);
                dsh_sb_puts(out, "}");
            } else {
                dsh_json_write(val, out);
            }
            written = 1;
        }
        dsh_sb_puts(out, "}");
    }
    dsh_sb_puts(out, "]");
}

static void mirror_session_list(agent_state *a) {
    dsh_sb value;
    dsh_sb error;

    if (!a->dsh_ready) {
        return;
    }

    dsh_sb_init(&value);
    dsh_sb_init(&error);

    if (dsh_rpc_call(&a->http, "session/list",
                     DSH_ARGS_SESSION_LIST, sizeof(DSH_ARGS_SESSION_LIST) - 1,
                     &value, &error, NULL) != 0) {
        DSH_DEBUG("session/list failed: %s", error.buf != NULL ? error.buf : "unknown");

        /*
         * dsh stopped answering. It may have restarted, or the token it was
         * started with may have been replaced; either way the sender has to
         * re-authenticate, so drop the claim and let the retry loop reconnect
         * rather than going quietly stale for the rest of the session.
         */
        if (++a->dsh_failures >= DSH_MAX_FAILURES) {
            DSH_WARN("dsh is not answering; re-authenticating");
            a->dsh_ready = 0;
            a->dsh_failures = 0;
            a->ws_ready = 0;
            dsh_ws_close(&a->ws);
            stop_all_follows(a);
            a->control_subscribed = 0;
            a->workspace_subscribed = 0;
            a->events_subscribed = 0;
            a->next_dsh_try = now_ms() + DSH_RETRY_MS;
        }

        dsh_sb_free(&value);
        dsh_sb_free(&error);
        return;
    }

    a->dsh_failures = 0;
    if (!a->dsh_ready) {
        return;
    }

    if (a->sessions_cache.buf == NULL || a->sessions_cache.len != value.len ||
        memcmp(a->sessions_cache.buf, value.buf, value.len) != 0) {
        capture_vanished(a, a->sessions_cache.buf, a->sessions_cache.len,
                         value.buf, value.len);

        dsh_sb_reset(&a->sessions_cache);
        dsh_sb_put(&a->sessions_cache, value.buf != NULL ? value.buf : "", value.len);

        {
            dsh_sb payload;
            dsh_sb_init(&payload);
            dsh_sb_puts(&payload, "{\"device\":");
            dsh_sb_put_json_string(&payload, a->device_name, strlen(a->device_name));
            dsh_sb_puts(&payload, ",\"sessions\":");
            {
                /* The RPC value is {items:[...]}; forward the array itself,
                 * with each session's projections cut down to what the watch
                 * reads. The cache keeps the untrimmed bytes so a change the
                 * watch never sees still counts as a change here. */
                dsh_json *root = dsh_json_parse(value.buf != NULL ? value.buf : "", value.len);
                const dsh_json *items = (root != NULL) ? dsh_json_get(root, "items") : NULL;
                if (items != NULL && items->type == DSH_JSON_ARR) {
                    write_trimmed_sessions(a, items, &payload);
                } else {
                    dsh_sb_puts(&payload, "[]");
                }
                dsh_json_free(root);
            }
            dsh_sb_puts(&payload, ",\"archivedDigests\":");
            if (a->vanished_digests.len > 0) {
                dsh_sb_puts(&payload, a->vanished_digests.buf);
            } else {
                dsh_sb_puts(&payload, "[]");
            }
            dsh_sb_puts(&payload, ",\"archivedSessionIds\":");
            if (a->archived_ids.len > 0) {
                dsh_sb_puts(&payload, a->archived_ids.buf);
            } else {
                dsh_sb_puts(&payload, "[]");
            }
            dsh_sb_puts(&payload, ",\"workspaces\":");
            if (a->workspaces.len > 0) {
                dsh_sb_puts(&payload, a->workspaces.buf);
            } else {
                dsh_sb_puts(&payload, "[]");
            }
            dsh_sb_puts(&payload, "}");

            relay_send(a, DSH_MSG_SESSIONS, NULL, payload.buf, payload.len);
            dsh_sb_free(&payload);
        }
    }

    dsh_sb_free(&value);
    dsh_sb_free(&error);
}

/* ── follow streams ──────────────────────────────────────────────────────── */

static follow_stream *find_follow(agent_state *a, const char *session_id) {
    int i;
    for (i = 0; i < MAX_FOLLOWS; i++) {
        if (a->follows[i].active && strcmp(a->follows[i].session_id, session_id) == 0) {
            return &a->follows[i];
        }
    }
    return NULL;
}

static follow_stream *find_follow_by_stream(agent_state *a, const char *stream_id, size_t len) {
    int i;
    for (i = 0; i < MAX_FOLLOWS; i++) {
        if (a->follows[i].active && strlen(a->follows[i].stream_id) == len &&
            memcmp(a->follows[i].stream_id, stream_id, len) == 0) {
            return &a->follows[i];
        }
    }
    return NULL;
}

/*
 * Builds the `session/follow` address for one session.
 *
 * dsh distinguishes a top-level session from a subagent: the latter is only
 * reachable through its durable parent, and subscribing with a plain session
 * address is rejected with "subagent Sessions require their durable parent
 * address". The parent comes from the session list this sender already mirrors,
 * so the client never has to know the difference.
 */
static void build_follow_address(agent_state *a, const char *session_id,
                                 const dsh_json *payload, dsh_sb *out) {
    const dsh_json *explicit_address = dsh_json_get(payload, "address");

    if (explicit_address != NULL) {
        dsh_json_write(explicit_address, out);
        return;
    }

    /* Look the session up in the mirrored list to learn whether it is a subagent. */
    if (a->sessions_cache.buf != NULL) {
        dsh_json *root = dsh_json_parse(a->sessions_cache.buf, a->sessions_cache.len);
        const dsh_json *items = (root != NULL) ? dsh_json_get(root, "items") : NULL;

        if (items != NULL && items->type == DSH_JSON_ARR) {
            size_t i;
            for (i = 0; i < items->u.arr.count; i++) {
                const dsh_json *item = items->u.arr.items[i];
                const char *id = dsh_json_string(dsh_json_get(item, "sessionId"), "", NULL);
                const char *parent = dsh_json_string(dsh_json_get(item, "parentSessionId"), NULL, NULL);
                const char *mode = dsh_json_string(dsh_json_get(payload, "mode"), "continuable", NULL);

                if (strcmp(id, session_id) != 0 || parent == NULL || parent[0] == '\0') {
                    continue;
                }

                dsh_sb_puts(out, "{\"kind\":\"subagent\",\"parentSessionId\":");
                dsh_sb_put_json_string(out, parent, strlen(parent));
                dsh_sb_puts(out, ",\"childSessionId\":");
                dsh_sb_put_json_string(out, session_id, strlen(session_id));
                dsh_sb_puts(out, ",\"mode\":");
                dsh_sb_put_json_string(out, mode, strlen(mode));
                dsh_sb_putc(out, '}');
                dsh_json_free(root);
                return;
            }
        }

        dsh_json_free(root);
    }

    dsh_sb_puts(out, "{\"kind\":\"session\",\"sessionId\":");
    dsh_sb_put_json_string(out, session_id, strlen(session_id));
    dsh_sb_putc(out, '}');
}

static void start_follow(agent_state *a, const char *session_id, const char *stream_id,
                         const dsh_json *payload) {
    dsh_sb args;
    follow_stream *slot = NULL;
    int i;

    /*
     * A session the sender already follows is re-opened, not reused.
     *
     * The client subscribes every time it opens a conversation, and it drops
     * the transcript it was holding at that moment, so it needs the opening
     * snapshot again. A reused stream sends nothing — its snapshot went out
     * when it was first opened — which left the conversation empty behind a
     * live stream and read as a session with no messages in it. Re-opening is
     * also what keeps this table free of duplicates: the slot is released here
     * and handed straight back by the allocation below.
     */
    slot = find_follow(a, session_id);
    if (slot != NULL) {
        DSH_DEBUG("re-opening follow stream %s for %s", slot->stream_id,
                  session_id);
        dsh_cancel_stream(a, slot->stream_id);
        slot->active = 0;
        slot = NULL;
    }

    for (i = 0; i < MAX_FOLLOWS; i++) {
        if (!a->follows[i].active) {
            slot = &a->follows[i];
            break;
        }
    }
    if (slot == NULL) {
        /*
         * Nothing free. Drop the oldest stream rather than refusing outright:
         * the watch follows one session at a time, so a full table means stale
         * entries, and a refusal leaves the user with a session that never
         * loads and no way to recover.
         */
        unsigned long long oldest = ~0ull;
        follow_stream *victim = NULL;

        for (i = 0; i < MAX_FOLLOWS; i++) {
            if (a->follows[i].active && a->follows[i].started_ms <= oldest) {
                oldest = a->follows[i].started_ms;
                victim = &a->follows[i];
            }
        }
        if (victim != NULL) {
            DSH_WARN("follow table full; dropping %s for %s",
                     victim->session_id, session_id);
            dsh_cancel_stream(a, victim->stream_id);
            victim->active = 0;
            slot = victim;
        }
    }
    if (slot == NULL) {
        DSH_WARN("too many followed sessions; ignoring %s", session_id);
        return;
    }

    memset(slot, 0, sizeof(*slot));
    snprintf(slot->session_id, sizeof(slot->session_id), "%s", session_id);
    snprintf(slot->stream_id, sizeof(slot->stream_id), "%s", stream_id);
    slot->active = 1;
    slot->started_ms = now_ms();

    dsh_sb_init(&args);
    dsh_sb_puts(&args, "{\"request\":{\"address\":");
    build_follow_address(a, session_id, payload, &args);
    dsh_sb_puts(&args, "}}");

    dsh_send_stream_frame(a, stream_id, "session/follow", args.buf);
    dsh_sb_free(&args);

    DSH_INFO("following session %s (stream %s)", session_id, stream_id);
}

static void stop_all_follows(agent_state *a) {
    int i;
    for (i = 0; i < MAX_FOLLOWS; i++) {
        if (a->follows[i].active) {
            dsh_cancel_stream(a, a->follows[i].stream_id);
            a->follows[i].active = 0;
        }
    }
}

/* Forwards one dsh follow frame to the relay. */
/* ── trimming a snapshot's records ──────────────────────────────────────── */

/*
 * Record types the watch ignores.
 *
 * Its own event handling names exactly which types it acts on; these are the
 * rest — the ones it folds and then does nothing with. `request/context` alone
 * carries a full request envelope, one per turn, so a snapshot of a few hundred
 * turns spends a large part of its megabyte on records that are parsed only to
 * be dropped. The watch decrypts and parses every byte that arrives, and
 * measurement put a 1 MB snapshot at more than two seconds of that.
 */
static int record_is_wanted(const dsh_json *record) {
    static const char *const ignored[] = {
        "session/end-seed", "step/start", "step/end",
        "request/header", "request/context",
        "agent/inbox/spliced", "chunkrow/tool-call-chunks"
    };
    const dsh_json *event = dsh_json_get(record, "event");
    const dsh_json *node =
        (event != NULL && event->type == DSH_JSON_OBJ) ? event : record;
    const char *type = dsh_json_string(dsh_json_get(node, "type"), "", NULL);
    size_t i;

    if (type[0] == '\0') {
        /* Not readable as an event: pass it through rather than guess. */
        return 1;
    }
    for (i = 0; i < sizeof(ignored) / sizeof(ignored[0]); i++) {
        if (strcmp(ignored[i], type) == 0) {
            return 0;
        }
    }
    return 1;
}

/*
 * How many of a snapshot's records are forwarded.
 *
 * A long conversation's snapshot is its entire history: the one measured here
 * was 910 KB and cost the watch two seconds to decrypt and parse, which is
 * almost the whole time its loading mask was up. Trimming record types was not
 * enough — what remains is the messages themselves, and a 258-turn conversation
 * simply has a lot of them.
 *
 * The watch opens on the newest messages regardless, and everything older is
 * reachable through the paging the session browser already offers: it asks for
 * what precedes the oldest record it holds, and the sender answers that with
 * `session/page`. Sending the tail changes how much arrives at once, not what
 * can be reached.
 */
#define SNAPSHOT_MAX_RECORDS 300

/* Writes the record array, dropping the ignored types and keeping the tail. */
static void write_trimmed_records(const dsh_json *records, dsh_sb *out) {
    size_t i;
    size_t start = 0;
    int written = 0;

    /*
     * Records arrive in sequence order, so keeping the tail is what leaves the
     * newest ones — the messages the conversation opens on.
     */
    if (records->u.arr.count > SNAPSHOT_MAX_RECORDS) {
        start = records->u.arr.count - SNAPSHOT_MAX_RECORDS;
        DSH_INFO("snapshot trimmed: %d of %d records forwarded",
                 (int)SNAPSHOT_MAX_RECORDS, (int)records->u.arr.count);
    }

    dsh_sb_puts(out, "[");
    for (i = start; i < records->u.arr.count; i++) {
        const dsh_json *record = records->u.arr.items[i];
        if (record == NULL || !record_is_wanted(record)) {
            continue;
        }
        if (written) {
            dsh_sb_puts(out, ",");
        }
        dsh_json_write(record, out);
        written = 1;
    }
    dsh_sb_puts(out, "]");
}

static void forward_follow_value(agent_state *a, follow_stream *stream, const dsh_json *value) {
    const char *type = dsh_json_string(dsh_json_get(value, "type"), "", NULL);

    DSH_DEBUG("follow frame type=%s session=%s cursor=%lld",
              type, stream->session_id, stream->cursor);

    if (strcmp(type, "snapshot") == 0) {
        dsh_sb payload;
        const dsh_json *cursor = dsh_json_get(value, "cursor");

        stream->cursor = dsh_json_integer(cursor, 0);

        dsh_sb_init(&payload);
        dsh_sb_puts(&payload, "{\"device\":");
        dsh_sb_put_json_string(&payload, a->device_name, strlen(a->device_name));
        dsh_sb_puts(&payload, ",\"session\":");
        dsh_sb_put_json_string(&payload, stream->session_id, strlen(stream->session_id));
        dsh_sb_puts(&payload, ",\"cursor\":");
        dsh_sb_put_i64(&payload, stream->cursor);
        /*
         * The snapshot's `header` is deliberately not forwarded. The watch's
         * handling reads `session`, `cursor`, `records` and `projections` and
         * nothing else, so the header was carried across the tunnel only to be
         * decrypted, parsed and dropped.
         */
        dsh_sb_puts(&payload, ",\"records\":");
        {
            const dsh_json *records = dsh_json_get(value, "records");
            if (records != NULL && records->type == DSH_JSON_ARR) {
                write_trimmed_records(records, &payload);
            } else {
                dsh_sb_puts(&payload, "[]");
            }
        }
        dsh_sb_puts(&payload, ",\"projections\":");
        {
            const dsh_json *projections = dsh_json_get(value, "projections");
            if (projections != NULL && projections->type == DSH_JSON_OBJ) {
                /* A baseline arrives as {asOfSeq, values}; the watch unwraps
                 * `values`, so that is the level worth trimming. This is the
                 * session the watch opened, so it keeps the full set. */
                const dsh_json *values = dsh_json_get(projections, "values");
                if (values != NULL && values->type == DSH_JSON_OBJ) {
                    dsh_sb_puts(&payload, "{\"values\":");
                    write_trimmed_values(values, &payload, 1);
                    dsh_sb_puts(&payload, "}");
                } else {
                    write_trimmed_values(projections, &payload, 1);
                }
            } else {
                dsh_sb_puts(&payload, "{}");
            }
        }
        dsh_sb_puts(&payload, "}");

        relay_send(a, DSH_MSG_SNAPSHOT, NULL, payload.buf, payload.len);
        dsh_sb_free(&payload);
        return;
    }

    if (strcmp(type, "event") == 0) {
        dsh_sb payload;
        long long seq = 0;

        {
            const dsh_json *event = dsh_json_get(value, "event");
            if (event == NULL) {
                return;
            }
            seq = dsh_json_integer(dsh_json_get(event, "seq"), 0);
            if (seq <= stream->cursor) {
                return; /* already delivered */
            }

            dsh_sb_init(&payload);
            dsh_sb_puts(&payload, "{\"device\":");
            dsh_sb_put_json_string(&payload, a->device_name, strlen(a->device_name));
            dsh_sb_puts(&payload, ",\"session\":");
            dsh_sb_put_json_string(&payload, stream->session_id, strlen(stream->session_id));
            dsh_sb_puts(&payload, ",\"events\":[");
            dsh_json_write(event, &payload);
            dsh_sb_puts(&payload, "]}");

            stream->cursor = seq;
            relay_send(a, DSH_MSG_EVENTS, NULL, payload.buf, payload.len);
            dsh_sb_free(&payload);
        }
    }
}

/* Handles one frame from the dsh websocket mux. */
static void handle_mux_message(agent_state *a, const char *json, size_t len) {
    dsh_json *root = dsh_json_parse(json, len);

    if (root == NULL) {
        DSH_DEBUG("mux frame is not valid JSON (%zu bytes)", len);
        return;
    }

    {
        const char *type = dsh_json_string(dsh_json_get(root, "type"), "", NULL);
        size_t stream_len = 0;
        const char *stream_id = dsh_json_string(dsh_json_get(root, "streamId"), "", &stream_len);

        DSH_DEBUG("mux <- type=%s stream=%.*s bytes=%zu",
                  type, (int)stream_len, stream_id, len);

        if (strcmp(type, "item") == 0) {
            const dsh_json *value = dsh_json_get(root, "value");

            if (value != NULL) {
                if (strlen(a->events_stream_id) == stream_len &&
                    memcmp(a->events_stream_id, stream_id, stream_len) == 0) {
                    const char *frame_type =
                        dsh_json_string(dsh_json_get(value, "type"), "", NULL);

                    if (strcmp(frame_type, "ready") == 0) {
                        /* Every result has to name the client it answers for. */
                        snprintf(a->events_client_id, sizeof(a->events_client_id), "%s",
                                 dsh_json_string(dsh_json_get(value, "clientId"), "", NULL));
                    }

                    /*
                     * Forwarded verbatim: the client needs the event name, the
                     * eventId to answer against, and the request body.
                     */
                    dsh_sb payload;
                    dsh_sb_init(&payload);
                    dsh_sb_puts(&payload, "{\"device\":");
                    dsh_sb_put_json_string(&payload, a->device_name, strlen(a->device_name));
                    dsh_sb_puts(&payload, ",\"events\":");
                    dsh_json_write(value, &payload);
                    dsh_sb_puts(&payload, "}");
                    relay_send(a, DSH_MSG_STATE, NULL, payload.buf, payload.len);
                    dsh_sb_free(&payload);
                } else if (strlen(a->workspace_stream_id) == stream_len &&
                    memcmp(a->workspace_stream_id, stream_id, stream_len) == 0) {
                    /*
                     * Baseline carries the whole set; later frames carry it
                     * again after a change. Forwarding the value verbatim keeps
                     * the client's copy identical to dsh's.
                     */
                    dsh_sb payload;
                    const dsh_json *inner = dsh_json_get(value, "value");
                    const dsh_json *ids = dsh_json_get(value, "archivedSessionIds");
                    const dsh_json *items = dsh_json_get(inner, "items");

                    if (ids == NULL) {
                        ids = dsh_json_get(inner, "archivedSessionIds");
                    }
                    if (ids != NULL) {
                        dsh_sb_reset(&a->archived_ids);
                        dsh_json_write(ids, &a->archived_ids);
                    }
                    if (items != NULL && items->type == DSH_JSON_ARR) {
                        dsh_sb_reset(&a->workspaces);
                        dsh_json_write(items, &a->workspaces);
                    }

                    dsh_sb_init(&payload);
                    dsh_sb_puts(&payload, "{\"device\":");
                    dsh_sb_put_json_string(&payload, a->device_name, strlen(a->device_name));
                    dsh_sb_puts(&payload, ",\"archived\":");
                    dsh_json_write(value, &payload);
                    dsh_sb_puts(&payload, "}");
                    relay_send(a, DSH_MSG_STATE, NULL, payload.buf, payload.len);
                    dsh_sb_free(&payload);
                } else if (strlen(a->control_stream_id) == stream_len &&
                    memcmp(a->control_stream_id, stream_id, stream_len) == 0) {
                    /* session/control baseline and increments become relay state. */
                    dsh_sb payload;
                    dsh_sb_init(&payload);
                    dsh_sb_puts(&payload, "{\"device\":");
                    dsh_sb_put_json_string(&payload, a->device_name, strlen(a->device_name));
                    dsh_sb_puts(&payload, ",\"control\":");
                    dsh_json_write(value, &payload);
                    dsh_sb_puts(&payload, "}");
                    relay_send(a, DSH_MSG_STATE, NULL, payload.buf, payload.len);
                    dsh_sb_free(&payload);
                } else {
                    follow_stream *stream = find_follow_by_stream(a, stream_id, stream_len);
                    if (stream != NULL) {
                        forward_follow_value(a, stream, value);
                    } else {
                        DSH_DEBUG("mux item for an unknown stream %.*s",
                                  (int)stream_len, stream_id);
                    }
                }
            }
        } else if (strcmp(type, "end") == 0 || strcmp(type, "error") == 0) {
            follow_stream *stream = find_follow_by_stream(a, stream_id, stream_len);

            if (strcmp(type, "error") == 0) {
                const dsh_json *err = dsh_json_get(root, "error");
                DSH_WARN("mux stream error: %s",
                         dsh_json_string(dsh_json_get(err, "message"), "unknown", NULL));
            }
            if (stream != NULL) {
                stream->active = 0;
            }
        }
    }

    dsh_json_free(root);
}

/* ── request handling ────────────────────────────────────────────────────── */

/*
 * Maps the small client vocabulary onto dsh's own endpoints. `wrap` names the
 * single argument key dsh expects; NULL means the endpoint takes no arguments.
 *
 * RAW_ARGS marks an endpoint whose arguments are the payload itself. Most dsh
 * endpoints take one named argument object and this map names its key —
 * `session/prompt` is `prompt(agent, request)`, so its payload belongs under
 * `request`. The goal endpoints are not shaped that way: `pause(agent, ref)` and
 * its siblings take `agent` and `ref` at the top level, and `edit` / `create`
 * add a `request` of their own. Naming a key for them buried the agent and the
 * reference one level down, so every goal action reached dsh with neither and
 * was refused — the buttons did nothing and said nothing.
 */
#define RAW_ARGS "-"

static const struct {
    const char *relay_method;
    const char *endpoint;
    const char *wrap;
} METHOD_MAP[] = {
    { "sessions/list",       "session/list",        "_request" },
    { "session/create",      "session/create",      "request"  },
    { "session/page",        "session/page",        "request"  },
    { "session/prompt",      "session/prompt",      "request"  },
    { "session/cancel",      "session/cancel",      "request"  },
    { "session/rename",      "session/rename",      "request"  },
    { "session/fork",        "session/fork",        "request"  },
    { "session/selectModel", "session/selectModel", "request"  },
    { "session/updateQueue", "session/updateQueue", "request"  },
    { "goals/create",        "goals/create",        RAW_ARGS   },
    { "goals/edit",          "goals/edit",          RAW_ARGS   },
    { "goals/pause",         "goals/pause",         RAW_ARGS   },
    { "goals/resume",        "goals/resume",        RAW_ARGS   },
    { "goals/complete",      "goals/complete",      RAW_ARGS   },
    { "goals/clear",         "goals/clear",         RAW_ARGS   },
    { "workspace/archiveSession", "workspace/archiveSession", "request" },
    { "workspace/create",    "workspace/create",    "request"  },
    { "workspace/rename",    "workspace/rename",    "request"  },
    { "workspace/delete",    "workspace/delete",    "request"  },
    { "session/modelCatalog", "session/modelCatalog", NULL     },
    { "session/attachment",  "session/attachment",  "request"  },
    { "commands/list",       "commands/list",       "request"  },
    { "commands/execute",    "commands/execute",    "request"  },
    { "agentPresets/list",   "agentPresets/list",   NULL       },
    { "agentPresets/select", "agentPresets/select", "request"  },
    { "settings/describe",   "settings/describe",   NULL       },
    { "skills/list",         "skills/list",         "request"  },
    { "pluginInventory/list", "pluginInventory/list", NULL     },
};

static void reply_result(agent_state *a, const char *id, const char *value_json, size_t len) {
    dsh_sb payload;
    dsh_sb_init(&payload);
    dsh_sb_puts(&payload, "{\"ok\":true,\"value\":");
    dsh_sb_put_json_raw(&payload, value_json != NULL ? value_json : "null", len);
    dsh_sb_puts(&payload, "}");
    relay_send(a, DSH_MSG_RESULT, id, payload.buf, payload.len);
    dsh_sb_free(&payload);
}

static void reply_error(agent_state *a, const char *id, const char *code, const char *message) {
    dsh_sb payload;
    dsh_sb_init(&payload);
    dsh_sb_puts(&payload, "{\"code\":");
    dsh_sb_put_json_string(&payload, code, strlen(code));
    dsh_sb_puts(&payload, ",\"message\":");
    dsh_sb_put_json_string(&payload, message, strlen(message));
    dsh_sb_puts(&payload, ",\"details\":{}}");
    relay_send(a, DSH_MSG_ERROR, id, payload.buf, payload.len);
    dsh_sb_free(&payload);
}

/*
 * Calls one dsh endpoint and turns the outcome into the matching relay reply.
 *
 * dsh's own error code is forwarded verbatim (`session/not-found`,
 * `session/agent-busy`, …) so the client can react to the specific condition
 * instead of pattern-matching a message string.
 */
static void call_and_reply(agent_state *a, const char *id, const char *endpoint,
                           const char *args, size_t args_len) {
    dsh_sb value;
    dsh_sb error;
    dsh_sb error_code;

    dsh_sb_init(&value);
    dsh_sb_init(&error);
    dsh_sb_init(&error_code);

    if (dsh_rpc_call(&a->http, endpoint, args, args_len, &value, &error, &error_code) == 0) {
        reply_result(a, id, value.buf, value.len);
    } else {
        reply_error(a, id,
                    (error_code.buf != NULL && error_code.len > 0)
                        ? error_code.buf : "dsh/call-failed",
                    error.buf != NULL ? error.buf : "unknown failure");
    }

    dsh_sb_free(&value);
    dsh_sb_free(&error);
    dsh_sb_free(&error_code);
}

/* Wraps a client payload in the argument key dsh expects. */
static void build_args(const char *wrap, const dsh_json *payload, dsh_sb *out) {
    if (wrap == NULL) {
        dsh_sb_puts(out, "{}");
        return;
    }
    if (strcmp(wrap, RAW_ARGS) == 0) {
        if (payload != NULL) {
            dsh_json_write(payload, out);
        } else {
            dsh_sb_puts(out, "{}");
        }
        return;
    }
    dsh_sb_putc(out, '{');
    dsh_sb_put_json_string(out, wrap, strlen(wrap));
    dsh_sb_putc(out, ':');
    if (payload != NULL) {
        dsh_json_write(payload, out);
    } else {
        dsh_sb_puts(out, "{}");
    }
    dsh_sb_putc(out, '}');
}

static void handle_request(agent_state *a, dsh_message *msg) {
    size_t method_len = 0;
    const char *method = dsh_json_string(dsh_json_get(msg->payload, "method"), "", &method_len);
    const dsh_json *payload = dsh_json_get(msg->payload, "payload");
    char method_buf[96];
    size_t i;

    if (method_len >= sizeof(method_buf)) {
        reply_error(a, msg->id, "relay/bad-request", "method name is too long");
        return;
    }
    memcpy(method_buf, method, method_len);
    method_buf[method_len] = '\0';

    /* Local relay methods never reach dsh. */
    if (strcmp(method_buf, "relay/status") == 0) {
        dsh_sb value;
        int followed = 0;

        for (i = 0; i < MAX_FOLLOWS; i++) {
            if (a->follows[i].active) {
                followed++;
            }
        }

        dsh_sb_init(&value);
        dsh_sb_printf(&value,
                      "{\"device\":\"%s\",\"agentVersion\":\"" DSH_AGENT_VERSION "\","
                      "\"dshReachable\":%s,\"eventMux\":%s,\"followedSessions\":%d}",
                      a->device_name,
                      a->dsh_ready ? "true" : "false",
                      a->ws_ready ? "true" : "false",
                      followed);
        reply_result(a, msg->id, value.buf, value.len);
        dsh_sb_free(&value);
        return;
    }

    /*
     * Everything the watch needs on the way in, answered in one round trip.
     *
     * Opening the app, and opening a conversation inside it, each used to cost
     * three or four separate requests — the relay status, the session list, the
     * model catalog, the balance — and each came back on its own, so the client
     * parsed and rebuilt several times before the page settled. All of them are
     * request/response shapes against the same loopback dsh, so the sender can
     * collect them together and the client can apply one result.
     *
     * The subscribe paths are deliberately not folded in: they open streams,
     * and a stream is not a value that fits in a reply.
     *
     * Each part defaults on. A caller that already holds one of them — the
     * composer keeps the session list — turns it off rather than paying to
     * receive and parse it again.
     */
    if (strcmp(method_buf, "relay/bundle") == 0) {
        dsh_sb value;
        dsh_sb part;
        dsh_sb error;
        dsh_sb error_code;
        dsh_sb failures;
        int want_sessions = dsh_json_bool(dsh_json_get(payload, "sessions"), 1);
        int want_catalog = dsh_json_bool(dsh_json_get(payload, "catalog"), 1);
        int want_balance = dsh_json_bool(dsh_json_get(payload, "balance"), 1);
        int followed = 0;

        for (i = 0; i < MAX_FOLLOWS; i++) {
            if (a->follows[i].active) {
                followed++;
            }
        }

        dsh_sb_init(&value);
        dsh_sb_init(&part);
        dsh_sb_init(&error);
        dsh_sb_init(&error_code);
        dsh_sb_init(&failures);

        dsh_sb_printf(&value,
                      "{\"status\":{\"device\":\"%s\",\"agentVersion\":\"" DSH_AGENT_VERSION "\","
                      "\"dshReachable\":%s,\"eventMux\":%s,\"followedSessions\":%d}",
                      a->device_name,
                      a->dsh_ready ? "true" : "false",
                      a->ws_ready ? "true" : "false",
                      followed);

        if (want_sessions) {
            dsh_sb_reset(&part);
            dsh_sb_reset(&error);
            dsh_sb_reset(&error_code);
            if (dsh_rpc_call(&a->http, "session/list",
                             DSH_ARGS_SESSION_LIST, sizeof(DSH_ARGS_SESSION_LIST) - 1,
                             &part, &error, &error_code) == 0) {
                dsh_sb_puts(&value, ",\"sessions\":");
                dsh_sb_put_json_raw(&value, part.buf, part.len);
            } else {
                if (failures.len > 0) dsh_sb_puts(&failures, ",");
                dsh_sb_printf(&failures, "\"sessions\":\"%s\"",
                              error_code.len > 0 ? error_code.buf : "relay/transport");
            }
        }

        if (want_catalog) {
            dsh_sb_reset(&part);
            dsh_sb_reset(&error);
            dsh_sb_reset(&error_code);
            if (dsh_rpc_call(&a->http, "session/modelCatalog", NULL, 0,
                             &part, &error, &error_code) == 0) {
                dsh_sb_puts(&value, ",\"catalog\":");
                dsh_sb_put_json_raw(&value, part.buf, part.len);
            } else {
                if (failures.len > 0) dsh_sb_puts(&failures, ",");
                dsh_sb_printf(&failures, "\"catalog\":\"%s\"",
                              error_code.len > 0 ? error_code.buf : "relay/transport");
            }
        }

        if (want_balance) {
            int balance_status = 0;
            dsh_sb_reset(&part);
            if (dsh_http_get(&a->http, "/dsh-whale/balance.json", &part, &balance_status) == 0 &&
                balance_status == 200) {
                dsh_sb_puts(&value, ",\"balance\":");
                dsh_sb_put_json_raw(&value, part.buf, part.len);
            } else {
                if (failures.len > 0) dsh_sb_puts(&failures, ",");
                dsh_sb_puts(&failures, "\"balance\":\"relay/balance-unavailable\"");
            }
        }

        if (failures.len > 0) {
            dsh_sb_puts(&value, ",\"errors\":{");
            dsh_sb_put(&value, failures.buf, failures.len);
            dsh_sb_puts(&value, "}");
        }
        dsh_sb_puts(&value, "}");

        reply_result(a, msg->id, value.buf, value.len);

        dsh_sb_free(&value);
        dsh_sb_free(&part);
        dsh_sb_free(&error);
        dsh_sb_free(&error_code);
        dsh_sb_free(&failures);
        return;
    }

    if (strcmp(method_buf, "session/subscribe") == 0) {
        const char *session_id = dsh_json_string(dsh_json_get(payload, "sessionId"),
                                                 dsh_json_string(dsh_json_get(payload, "session"), "", NULL),
                                                 NULL);
        char stream_id[32];

        if (!a->ws_ready) {
            reply_error(a, msg->id, "relay/mux-unavailable",
                        "the dsh event mux is not connected on the sender");
            return;
        }
        if (session_id[0] == '\0') {
            reply_error(a, msg->id, "relay/bad-request", "sessionId is required");
            return;
        }

        snprintf(stream_id, sizeof(stream_id), "s%d", a->next_stream_num++);
        start_follow(a, session_id, stream_id, payload);
        reply_result(a, msg->id, "{\"subscribed\":true}", 19);
        return;
    }

    if (strcmp(method_buf, "session/unsubscribe") == 0) {
        const char *session_id = dsh_json_string(dsh_json_get(payload, "sessionId"), "", NULL);
        follow_stream *stream = find_follow(a, session_id);
        if (stream != NULL) {
            dsh_cancel_stream(a, stream->stream_id);
            stream->active = 0;
        }
        reply_result(a, msg->id, "{\"subscribed\":false}", 20);
        return;
    }

    if (!a->dsh_ready) {
        reply_error(a, msg->id, "relay/dsh-unavailable",
                    "the sender has no authenticated connection to its local dsh webserver");
        return;
    }

    /*
     * `session/page` takes a SessionAddress, not a session id, and its
     * throughSeq must be the cursor of an open follow. The client speaks in
     * plain session ids, so the sender supplies both.
     */
    /*
     * Answers one forwarded waterfall event.
     *
     * The Host is holding the listener open waiting for this; the client names
     * the event and says whether it is deciding (`result`, with the decision as
     * the value) or passing (`next`). `clientId` comes from the stream's ready
     * frame — every result has to quote the client it answers for, and the
     * gateway rejects one that names nothing.
     */
    if (strcmp(method_buf, "events/respond") == 0) {
        dsh_sb args;
        const char *event_id = dsh_json_string(dsh_json_get(payload, "eventId"), "", NULL);
        const char *kind = dsh_json_string(dsh_json_get(payload, "kind"), "result", NULL);
        const dsh_json *value = dsh_json_get(payload, "value");

        if (event_id[0] == '\0') {
            reply_error(a, msg->id, "relay/bad-request", "eventId is required");
            return;
        }
        if (a->events_client_id[0] == '\0') {
            reply_error(a, msg->id, "relay/not-subscribed",
                        "the forwarded-event stream has not sent its ready frame yet");
            return;
        }

        dsh_sb_init(&args);
        /*
         * No `args` wrapper here: `dsh_rpc_call` builds the request envelope and
         * adds `"payload":{"args":…}` itself, the way `build_args` relies on for
         * every other endpoint. Wrapping it here as well nested the arguments
         * one level too deep, and the gateway — which reads `clientId`,
         * `eventId` and `outcome` off the top of that object — rejected the
         * result as malformed.
         */
        dsh_sb_puts(&args, "{\"clientId\":");
        dsh_sb_put_json_string(&args, a->events_client_id, strlen(a->events_client_id));
        dsh_sb_puts(&args, ",\"eventId\":");
        dsh_sb_put_json_string(&args, event_id, strlen(event_id));
        dsh_sb_puts(&args, ",\"outcome\":{\"kind\":");
        dsh_sb_put_json_string(&args, kind, strlen(kind));
        if (value != NULL) {
            dsh_sb_puts(&args, ",\"value\":");
            dsh_json_write(value, &args);
        }
        dsh_sb_puts(&args, "}}");

        call_and_reply(a, msg->id, "$events/result", args.buf, args.len);
        dsh_sb_free(&args);
        return;
    }

    /*
     * Re-opens the forwarded-event stream so the Host replays what it still
     * holds.
     *
     * The gateway hands every pending waterfall to a client the moment its
     * `$events` stream registers, and that is the only replay it offers: a frame
     * missed while nobody was listening is never sent again. A watch that opens
     * a conversation after the ask was raised therefore missed the original
     * frame and would never learn there is anything to answer, so it asks for
     * this and the fresh subscription does the work. Re-opening rather than
     * adding a second stream keeps one answer channel, which is what the stored
     * client id names.
     */
    if (strcmp(method_buf, "events/refresh") == 0) {
        const char *ok = "{\"subscribed\":true}";

        if (!a->ws_ready) {
            reply_error(a, msg->id, "relay/not-connected",
                        "the dsh websocket is not connected");
            return;
        }

        if (a->events_subscribed) {
            dsh_cancel_stream(a, a->events_stream_id);
            a->events_subscribed = 0;
            a->events_client_id[0] = '\0';
        }
        subscribe_events(a);

        reply_result(a, msg->id, ok, strlen(ok));
        return;
    }

    /*
     * The DeepSeek balance the whale-widget plugin publishes.
     *
     * That plugin serves `/dsh-whale/balance.json` from the dsh webserver, so
     * this is one plain GET on the loopback connection the relay already holds:
     * no TLS, and no credential has to be read out of dsh's store. The endpoint
     * needs no session cookie either, so it answers independently of the RPC
     * surface — which is why a failure here is reported as its own condition
     * rather than as a dsh call failure.
     */
    if (strcmp(method_buf, "balance/get") == 0) {
        dsh_sb body;
        int status = 0;

        dsh_sb_init(&body);
        if (dsh_http_get(&a->http, "/dsh-whale/balance.json", &body, &status) != 0) {
            reply_error(a, msg->id, "relay/balance-unavailable",
                        "the local dsh webserver did not answer");
        } else if (status != 200) {
            reply_error(a, msg->id, "relay/balance-unavailable",
                        "the whale-widget balance endpoint is not serving");
        } else {
            reply_result(a, msg->id, body.buf, body.len);
        }
        dsh_sb_free(&body);
        return;
    }

    if (strcmp(method_buf, "session/page") == 0) {
        dsh_sb args;
        const char *session_id = dsh_json_string(dsh_json_get(payload, "sessionId"), "", NULL);
        long long through_seq = dsh_json_integer(dsh_json_get(payload, "throughSeq"), -1);
        long long before_seq = dsh_json_integer(dsh_json_get(payload, "beforeSeq"), -1);
        long long max_messages = dsh_json_integer(dsh_json_get(payload, "maxMessages"), 0);

        if (session_id[0] == '\0') {
            reply_error(a, msg->id, "relay/bad-request", "sessionId is required");
            return;
        }

        if (through_seq < 0) {
            follow_stream *stream = find_follow(a, session_id);
            if (stream == NULL) {
                reply_error(a, msg->id, "relay/not-following",
                            "subscribe to the session before paging its history");
                return;
            }
            through_seq = stream->cursor;
        }

        dsh_sb_init(&args);
        dsh_sb_puts(&args, "{\"request\":{\"address\":");
        build_follow_address(a, session_id, payload, &args);
        dsh_sb_printf(&args, ",\"throughSeq\":%lld", through_seq);
        if (before_seq >= 0) {
            dsh_sb_printf(&args, ",\"beforeSeq\":%lld", before_seq);
        }
        if (max_messages > 0) {
            dsh_sb_printf(&args, ",\"maxMessages\":%lld", max_messages);
        }
        dsh_sb_puts(&args, "}}");

        call_and_reply(a, msg->id, "session/page", args.buf, args.len);
        dsh_sb_free(&args);
        return;
    }

    /*
     * A prompt carries a request id and structured content parts. The client
     * submits plain text, so the sender mints the id and builds the part list.
     */
    if (strcmp(method_buf, "session/prompt") == 0) {
        dsh_sb args;
        dsh_sb value;
        dsh_sb error;
        dsh_sb error_code;
        const char *session_id = dsh_json_string(dsh_json_get(payload, "sessionId"), "", NULL);
        size_t text_len = 0;
        const char *text = dsh_json_string(dsh_json_get(payload, "text"), "", &text_len);
        const char *mode = dsh_json_string(dsh_json_get(payload, "mode"), "queue", NULL);
        char request_id[32];

        if (session_id[0] == '\0') {
            reply_error(a, msg->id, "relay/bad-request", "sessionId is required");
            return;
        }
        if (text_len == 0) {
            reply_error(a, msg->id, "relay/bad-request", "text is required");
            return;
        }
        if (strcmp(mode, "queue") != 0 && strcmp(mode, "steer") != 0) {
            mode = "queue";
        }

        dsh_http_make_rpc_id(request_id, sizeof(request_id));

        dsh_sb_init(&args);
        dsh_sb_puts(&args, "{\"request\":{\"requestId\":");
        dsh_sb_put_json_string(&args, request_id, strlen(request_id));
        dsh_sb_puts(&args, ",\"sessionId\":");
        dsh_sb_put_json_string(&args, session_id, strlen(session_id));
        dsh_sb_puts(&args, ",\"mode\":");
        dsh_sb_put_json_string(&args, mode, strlen(mode));
        dsh_sb_puts(&args, ",\"content\":[{\"type\":\"text\",\"text\":");
        dsh_sb_put_json_string(&args, text, text_len);
        dsh_sb_puts(&args, "}]}}");

        dsh_sb_init(&value);
        dsh_sb_init(&error);
        dsh_sb_init(&error_code);
        if (dsh_rpc_call(&a->http, "session/prompt", args.buf, args.len,
                         &value, &error, &error_code) == 0) {
            DSH_INFO("prompt accepted for %s (%s, %zu bytes)", session_id, mode, text_len);
            reply_result(a, msg->id, value.buf, value.len);
        } else {
            DSH_WARN("prompt rejected for %s: %s", session_id,
                     error.buf != NULL ? error.buf : "unknown");
            reply_error(a, msg->id,
                        (error_code.buf != NULL && error_code.len > 0)
                            ? error_code.buf : "dsh/call-failed",
                        error.buf != NULL ? error.buf : "unknown failure");
        }

        dsh_sb_free(&args);
        dsh_sb_free(&value);
        dsh_sb_free(&error);
        dsh_sb_free(&error_code);
        return;
    }

    /* Mapped endpoints get the argument key dsh expects. */
    for (i = 0; i < sizeof(METHOD_MAP) / sizeof(METHOD_MAP[0]); i++) {
        if (strcmp(METHOD_MAP[i].relay_method, method_buf) == 0) {
            dsh_sb args;

            dsh_sb_init(&args);
            build_args(METHOD_MAP[i].wrap, payload, &args);
            call_and_reply(a, msg->id, METHOD_MAP[i].endpoint, args.buf, args.len);
            dsh_sb_free(&args);
            return;
        }
    }

    /*
     * Escape hatch: any other method is passed through as a dsh endpoint with
     * the client payload used verbatim as the arguments object. This is how a
     * client reaches endpoints this sender does not model.
     */
    {
        dsh_sb args;

        dsh_sb_init(&args);
        if (payload != NULL) {
            dsh_json_write(payload, &args);
        } else {
            dsh_sb_puts(&args, "{}");
        }

        call_and_reply(a, msg->id, method_buf, args.buf, args.len);
        dsh_sb_free(&args);
    }
}

/* ── main loop ───────────────────────────────────────────────────────────── */

static void on_relay_readable(agent_state *a) {
    dsh_message msg;
    int rc = dsh_message_read(a->relay_sock, &a->crypto, &msg);

    if (rc == -1) {
        DSH_INFO("relay closed the connection");
        a->relay_ready = 0;
        return;
    }
    if (rc == -2) {
        /* A reset socket, not a rejected frame: the peer went away. */
        DSH_WARN("relay connection lost");
        a->relay_ready = 0;
        return;
    }
    if (rc != 0) {
        DSH_WARN("relay frame rejected (code %d)", rc);
        a->relay_ready = 0;
        return;
    }

    a->frames_in++;

    switch (msg.kind) {
    case DSH_MSG_REQUEST:
        handle_request(a, &msg);
        break;
    case DSH_MSG_PING:
        relay_send(a, DSH_MSG_PONG, NULL, NULL, 0);
        break;
    case DSH_MSG_DEVICES:
        /* A roster change; nothing for the sender to do. */
        break;
    default:
        DSH_DEBUG("relay sent %s", dsh_msg_name(msg.kind));
        break;
    }

    dsh_message_free(&msg);
}

static void pump_mux(agent_state *a, int timeout_ms) {
    dsh_sb message;
    int rc;
    int budget = 128;

    if (!a->ws_ready) {
        return;
    }

    /*
     * Drain every frame the mux already has, rather than one per call.
     *
     * The main loop ticks every 200 ms, so handling a single frame per tick
     * capped the relay at five events a second: a streaming reply would pile up
     * in the socket and the transcript would visibly lag behind dsh. The first
     * read keeps the caller's timeout so an idle sender still blocks normally;
     * the rest are non-blocking, and the budget stops a very chatty dsh from
     * starving the relay socket.
     */
    while (budget-- > 0) {
        dsh_sb_init(&message);
        rc = dsh_ws_recv(&a->ws, &message, timeout_ms);

        if (rc == 1) {
            handle_mux_message(a, message.buf, message.len);
            dsh_sb_free(&message);
            timeout_ms = 0;
            continue;
        }

        if (rc < 0) {
            DSH_WARN("dsh event mux dropped; reopening on the next cycle");
            dsh_ws_close(&a->ws);
            a->ws_ready = 0;
            stop_all_follows(a);
            a->control_subscribed = 0;
            a->workspace_subscribed = 0;
            a->events_subscribed = 0;
        }

        dsh_sb_free(&message);
        break;
    }
}

/*
 * Opens the workspace feed.
 *
 * dsh's workspace controller is the only place that knows which sessions are
 * archived, and it publishes them as `archivedSessionIds` on this stream. The
 * session list deliberately omits archived sessions, so without this feed the
 * client has no way to learn the set — it could only remember what it archived
 * itself, and lost that on restart.
 */
/* Opens the Gateway forwarded-event stream, which carries approvals. */
static void subscribe_events(agent_state *a) {
    if (a->ws_ready && !a->events_subscribed) {
        snprintf(a->events_stream_id, sizeof(a->events_stream_id), "e%d",
                 a->next_stream_num++);
        dsh_send_stream_frame(a, a->events_stream_id, "$events", "{}");
        a->events_subscribed = 1;
        DSH_INFO("subscribed to the dsh forwarded-event stream");
    }
}

static void subscribe_workspace(agent_state *a) {
    if (a->ws_ready && !a->workspace_subscribed) {
        snprintf(a->workspace_stream_id, sizeof(a->workspace_stream_id), "w%d",
                 a->next_stream_num++);
        dsh_send_stream_frame(a, a->workspace_stream_id, "workspace/follow", "{}");
        a->workspace_subscribed = 1;
        DSH_INFO("subscribed to the dsh workspace stream");
    }
}

static void subscribe_control(agent_state *a) {
    if (a->ws_ready && !a->control_subscribed) {
        snprintf(a->control_stream_id, sizeof(a->control_stream_id), "c%d", a->next_stream_num++);
        dsh_send_stream_frame(a, a->control_stream_id, "session/control", "{}");
        a->control_subscribed = 1;
        DSH_INFO("subscribed to the dsh session-control stream");
    }
}

static void print_usage(const char *argv0) {
    printf("dsh-relay-sender %s\n\n", DSH_AGENT_VERSION);
    printf("usage: %s [options]\n\n", argv0);
    printf("  --config PATH        read settings from PATH instead of config.json\n");
    printf("  --server HOST        relay host (default 127.0.0.1)\n");
    printf("  --port N             relay port (default 7777)\n");
    printf("  --passphrase VALUE   shared secret\n");
    printf("  --dsh-url URL        local dsh web base URL (default http://127.0.0.1:3080)\n");
    printf("  --dsh-token VALUE    token from the URL printed by `dsh web`; empty\n"
           "                       mints one from the dsh credentials file\n");
    printf("  --dsh-home PATH      dsh state directory (default %%USERPROFILE%%\\.dsh)\n");
    printf("  --name VALUE         device name shown to clients\n");
    printf("  --console            run without the window, as a console program\n");
    printf("  --verbose            log at debug level\n");
    printf("  --help               show this text\n\n");
    printf("With no mode flag the sender opens its window. Settings live in\n");
    printf("config.json beside this executable; it is created on first run.\n");
    printf("The sender never exposes a listening port of its own.\n");
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

static void default_device_name(char *out, size_t cap) {
    char host[128] = "dsh-sender";
#ifdef _WIN32
    DWORD size = sizeof(host);
    if (!GetComputerNameA(host, &size)) {
        strcpy(host, "dsh-sender");
    }
#endif
    snprintf(out, cap, "%s", host);
}

#ifdef _WIN32
static BOOL WINAPI console_handler(DWORD signal) {
    if (signal == CTRL_C_EVENT || signal == CTRL_BREAK_EVENT || signal == CTRL_CLOSE_EVENT) {
        printf("\nshutting down\n");
        ExitProcess(0);
    }
    return FALSE;
}
#endif

/* ── lifecycle ───────────────────────────────────────────────────────────── */

/* Where the local dsh keeps its state; the credentials file lives inside. */
static const char *default_dsh_home(void) {
    static char home[512];
    const char *base = getenv("USERPROFILE");
    if (base == NULL) {
        base = getenv("HOME");
    }
    if (base != NULL && base[0] != '\0') {
        snprintf(home, sizeof(home), "%s\\.dsh", base);
    } else {
        snprintf(home, sizeof(home), ".dsh");
    }
    return home;
}

void agent_set_config(const char *server_host, int server_port,
                      const char *passphrase, const char *dsh_url,
                      const char *dsh_token, const char *device_name,
                      const char *dsh_home) {
    if (g_agent == NULL) {
        g_agent = (agent_state *)calloc(1, sizeof(agent_state));
        if (g_agent == NULL) {
            return;
        }
        g_agent->relay_sock = DSH_INVALID_SOCKET;
        g_agent->ws.sock = DSH_INVALID_SOCKET;
        dsh_sb_init(&g_agent->sessions_cache);
        dsh_sb_init(&g_agent->vanished_digests);
        dsh_sb_init(&g_agent->archived_ids);
        dsh_sb_init(&g_agent->workspaces);
        g_agent->poll_ms = LIST_POLL_MS;
    }

    snprintf(g_agent->server_host, sizeof(g_agent->server_host), "%s",
             server_host != NULL && server_host[0] != '\0' ? server_host : "127.0.0.1");
    g_agent->server_port = (uint16_t)(server_port > 0 ? server_port : 7777);
    snprintf(g_agent->passphrase, sizeof(g_agent->passphrase), "%s",
             passphrase != NULL ? passphrase : "");
    snprintf(g_agent->dsh_base, sizeof(g_agent->dsh_base), "%s",
             dsh_url != NULL && dsh_url[0] != '\0' ? dsh_url : "http://127.0.0.1:3080");
    snprintf(g_agent->dsh_token, sizeof(g_agent->dsh_token), "%s",
             dsh_token != NULL ? dsh_token : "");
    snprintf(g_agent->dsh_home, sizeof(g_agent->dsh_home), "%s",
             dsh_home != NULL && dsh_home[0] != '\0' ? dsh_home : default_dsh_home());
    if (device_name != NULL && device_name[0] != '\0') {
        snprintf(g_agent->device_name, sizeof(g_agent->device_name), "%s", device_name);
    } else if (g_agent->device_name[0] == '\0') {
        default_device_name(g_agent->device_name, sizeof(g_agent->device_name));
    }
}

int agent_start(void) {
    agent_state *a = g_agent;

    if (a == NULL) {
        return -1;
    }
    if (a->passphrase[0] == '\0') {
        snprintf(a->last_error, sizeof(a->last_error), "共享口令未填写");
        return -1;
    }

    a->running = 1;
    a->last_error[0] = '\0';
    a->next_reconnect = 0;
    a->next_list_poll = 0;
    a->next_ping = 0;

    DSH_INFO("dsh-relay-sender %s", DSH_AGENT_VERSION);
    DSH_INFO("device=%s relay=%s:%u dsh=%s",
             a->device_name, a->server_host, (unsigned)a->server_port, a->dsh_base);

    if (dsh_http_init(&a->http, a->dsh_base) != 0) {
        DSH_WARN("dsh_url 必须是形如 http://127.0.0.1:3080 的裸地址；会话镜像已禁用");
        snprintf(a->last_error, sizeof(a->last_error), "dsh_url 无效");
    } else {
        dsh_connect(a);
    }

    return 0;
}

void agent_stop(void) {
    agent_state *a = g_agent;

    if (a == NULL) {
        return;
    }

    a->running = 0;

    /* Closing both sockets wakes the loop out of select() immediately rather
     * than waiting for its next tick. */
    if (a->relay_sock != DSH_INVALID_SOCKET) {
        dsh_socket closing = a->relay_sock;
        a->relay_sock = DSH_INVALID_SOCKET;
        a->relay_ready = 0;
        dsh_net_close(closing);
    }
    stop_all_follows(a);
    dsh_ws_close(&a->ws);
    a->ws_ready = 0;
    a->control_subscribed = 0;
}

int agent_is_running(void) {
    return g_agent != NULL && g_agent->running != 0;
}

void agent_run(void) {
    agent_state *a = g_agent;

    if (a == NULL) {
        return;
    }

    while (a->running) {
        unsigned long long now = now_ms();
        fd_set read_set;
        struct timeval tv;
        dsh_socket highest;
        int ready;

        if (!a->relay_ready && now >= a->next_reconnect) {
            if (relay_connect(a) == 0) {
                /*
                 * A fresh tunnel restarts the mirror from a clean slate.
                 *
                 * The caches have to be dropped for that to mean anything. The
                 * session mirror only publishes when the list differs from its
                 * cache, so after a reconnect it compared against the previous
                 * run's copy, found them equal, and sent nothing — leaving the
                 * client with an empty browser for its whole session.
                 *
                 * The stream subscriptions are reset for the same reason: they
                 * belong to the tunnel that just went away.
                 */
                dsh_sb_reset(&a->sessions_cache);
                a->control_subscribed = 0;
                a->workspace_subscribed = 0;
                stop_all_follows(a);

                mirror_session_list(a);
                subscribe_control(a);
                subscribe_workspace(a);
                subscribe_events(a);
            } else {
                DSH_WARN("cannot reach the relay at %s:%u; retrying",
                         a->server_host, (unsigned)a->server_port);
                snprintf(a->last_error, sizeof(a->last_error),
                         "无法连接中继 %s:%u", a->server_host, (unsigned)a->server_port);
                a->next_reconnect = now + RELAY_RECONNECT_MS;
            }
        }

        /*
         * Re-authenticate on a timer until the dsh link is up.
         *
         * dsh is often started after the sender, or restarted with a fresh
         * token while the sender keeps running. Without this retry a single
         * failure at startup left the sender permanently unable to mirror
         * sessions — the client connected fine and then saw nothing at all.
         */
        if (!a->dsh_ready && a->http.host[0] != '\0' && now >= a->next_dsh_try) {
            if (dsh_connect(a) != 0) {
                a->next_dsh_try = now + DSH_RETRY_MS;
            }
        }

        if (a->dsh_ready && !a->ws_ready) {
            dsh_sb error;
            dsh_sb_init(&error);
            if (dsh_ws_connect(&a->http, "/api/remote.mux", &a->ws, &error) == 0) {
                a->ws_ready = 1;
                a->control_subscribed = 0;
                a->workspace_subscribed = 0;
                a->events_subscribed = 0;
                DSH_INFO("dsh event mux reconnected");
                subscribe_control(a);
                subscribe_workspace(a);
                subscribe_events(a);
            }
            dsh_sb_free(&error);
        }

        if (a->dsh_ready && now >= a->next_list_poll) {
            mirror_session_list(a);
            a->next_list_poll = now + (unsigned long long)a->poll_ms;
        }

        if (a->relay_ready && now >= a->next_ping) {
            relay_send(a, DSH_MSG_PING, NULL, NULL, 0);
            a->next_ping = now + PING_INTERVAL_MS;
        }

        /* Wait on the relay socket, then drain one mux frame. */
        highest = a->relay_sock;
        FD_ZERO(&read_set);
        if (a->relay_ready && a->relay_sock != DSH_INVALID_SOCKET) {
            FD_SET(a->relay_sock, &read_set);
        }
        tv.tv_sec = 0;
        tv.tv_usec = 200 * 1000;

        ready = select((int)highest + 1, &read_set, NULL, NULL, &tv);

        if (ready > 0 && a->relay_ready && FD_ISSET(a->relay_sock, &read_set)) {
            on_relay_readable(a);
        }

        pump_mux(a, 0);
    }
}

DWORD WINAPI agent_thread_proc(LPVOID unused) {
    (void)unused;
    agent_run();
    return 0;
}

void agent_get_status(agent_status *out) {
    agent_state *a = g_agent;
    int i;

    if (out == NULL) {
        return;
    }
    memset(out, 0, sizeof(*out));
    if (a == NULL) {
        return;
    }

    out->running = a->running != 0;
    out->relay_connected = a->relay_ready != 0;
    out->dsh_reachable = a->dsh_ready != 0;
    out->mux_open = a->ws_ready != 0;
    out->frames_in = a->frames_in;
    out->frames_out = a->frames_out;

    for (i = 0; i < MAX_FOLLOWS; i++) {
        if (a->follows[i].active) {
            out->followed_sessions++;
        }
    }

    if (a->sessions_cache.buf != NULL) {
        dsh_json *root = dsh_json_parse(a->sessions_cache.buf, a->sessions_cache.len);
        const dsh_json *items = root != NULL ? dsh_json_get(root, "items") : NULL;
        if (items != NULL && items->type == DSH_JSON_ARR) {
            out->session_count = (int)items->u.arr.count;
        }
        dsh_json_free(root);
    }

    snprintf(out->device_name, sizeof(out->device_name), "%s", a->device_name);
    snprintf(out->relay_target, sizeof(out->relay_target), "%s:%u",
             a->server_host, (unsigned)a->server_port);
    snprintf(out->dsh_target, sizeof(out->dsh_target), "%s", a->dsh_base);
    snprintf(out->last_error, sizeof(out->last_error), "%s", a->last_error);
}

int main(int argc, char **argv) {
    dsh_cfg_file cfg;
    char cfg_path[DSH_CFG_PATH_LEN];
    const char *config_path = NULL;
    const char *opt_server = NULL;
    const char *opt_passphrase = NULL;
    const char *opt_dsh_url = NULL;
    const char *opt_dsh_token = NULL;
    const char *opt_dsh_home = NULL;
    const char *opt_name = NULL;
    int opt_port = -1;
    int opt_verbose = 0;
    int console_mode = 0;
    int want_help = 0;
    int i;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            want_help = 1;
        } else if (strcmp(argv[i], "--config") == 0 && i + 1 < argc) {
            config_path = argv[++i];
        } else if (strcmp(argv[i], "--server") == 0 && i + 1 < argc) {
            opt_server = argv[++i];
        } else if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            opt_port = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--passphrase") == 0 && i + 1 < argc) {
            opt_passphrase = argv[++i];
        } else if (strcmp(argv[i], "--dsh-url") == 0 && i + 1 < argc) {
            opt_dsh_url = argv[++i];
        } else if (strcmp(argv[i], "--dsh-token") == 0 && i + 1 < argc) {
            opt_dsh_token = argv[++i];
        } else if (strcmp(argv[i], "--dsh-home") == 0 && i + 1 < argc) {
            opt_dsh_home = argv[++i];
        } else if (strcmp(argv[i], "--name") == 0 && i + 1 < argc) {
            opt_name = argv[++i];
        } else if (strcmp(argv[i], "--console") == 0) {
            /* Run without a window, as the sender did before it had one. */
            console_mode = 1;
        } else if (strcmp(argv[i], "--verbose") == 0) {
            opt_verbose = 1;
        } else {
            fprintf(stderr, "unknown option: %s\n", argv[i]);
            print_usage(argv[0]);
            return 1;
        }
    }

    if (dsh_cfg_path_beside_exe(cfg_path, sizeof(cfg_path), "config.json") != 0) {
        snprintf(cfg_path, sizeof(cfg_path), "config.json");
    }
    if (config_path == NULL) {
        config_path = cfg_path;
    }

    /* A GUI-subsystem build has no console, so --help and every log line need
     * somewhere to go before the window exists. */
    if (!console_mode) {
        dsh_log_set_console(0);
        dsh_ui_log_attach();
    } else {
        dsh_ui_attach_console();
    }

    if (want_help) {
        if (console_mode || dsh_ui_attach_console()) {
            print_usage(argv[0]);
        } else {
            dsh_ui_info(NULL, "dsh-relay-sender",
                        "用法：dsh-relay-sender [选项]\n\n"
                        "  --config PATH        从 PATH 读取配置（默认 exe 同目录 config.json）\n"
                        "  --server HOST        中继服务器地址（默认 127.0.0.1）\n"
                        "  --port N             中继端口（默认 7777）\n"
                        "  --passphrase VALUE   共享口令，需与服务端、客户端一致\n"
                        "  --dsh-url URL        本地 dsh 地址（默认 http://127.0.0.1:3080）\n"
                        "  --dsh-token VALUE    dsh web 启动时打印的 token；留空则自动从\n"
                        "                       dsh 凭据文件铸造会话\n"
                        "  --dsh-home PATH      dsh 状态目录（默认 %%USERPROFILE%%\\.dsh）\n"
                        "  --name VALUE         对客户端显示的设备名\n"
                        "  --console            以控制台方式运行，不打开窗口\n"
                        "  --verbose            输出调试日志\n\n"
                        "不带模式参数时打开窗口；config.json 在首次运行时自动创建。");
        }
        return 0;
    }

    if (dsh_cfg_open(&cfg, config_path) != 0) {
        fprintf(stderr, "cannot read config file: %s\n", config_path);
        return 1;
    }
    if (cfg.malformed) {
        DSH_WARN("%s 不是合法 JSON，已按默认值运行并把它另存为 .bak", config_path);
    }

    {
        char device[128];
        int port = opt_port > 0 ? opt_port : dsh_cfg_int(&cfg, "server_port", 7777);
        const char *host = opt_server != NULL ? opt_server
                                              : dsh_cfg_str(&cfg, "server_host", "127.0.0.1");
        const char *pass = opt_passphrase != NULL ? opt_passphrase
                                                  : dsh_cfg_str(&cfg, "passphrase", "");
        const char *url = opt_dsh_url != NULL ? opt_dsh_url
                                              : dsh_cfg_str(&cfg, "dsh_url", "http://127.0.0.1:3080");
        const char *token = opt_dsh_token != NULL ? opt_dsh_token
                                                  : dsh_cfg_str(&cfg, "dsh_token", "");
        const char *configured_name = dsh_cfg_str(&cfg, "device_name", "");
        const char *home = opt_dsh_home != NULL ? opt_dsh_home
                                                : dsh_cfg_str(&cfg, "dsh_home", default_dsh_home());

        if (opt_name != NULL) {
            snprintf(device, sizeof(device), "%s", opt_name);
        } else if (configured_name[0] != '\0') {
            snprintf(device, sizeof(device), "%s", configured_name);
        } else {
            default_device_name(device, sizeof(device));
        }

        /* Command-line flags outrank the file, and the file records what was
         * actually used so the next run starts from the same place. */
        if (opt_port > 0) dsh_cfg_set_int(&cfg, "server_port", port);
        if (opt_server != NULL) dsh_cfg_set_str(&cfg, "server_host", host);
        if (opt_passphrase != NULL) dsh_cfg_set_str(&cfg, "passphrase", pass);
        if (opt_dsh_url != NULL) dsh_cfg_set_str(&cfg, "dsh_url", url);
        if (opt_dsh_token != NULL) dsh_cfg_set_str(&cfg, "dsh_token", token);
        if (opt_dsh_home != NULL) dsh_cfg_set_str(&cfg, "dsh_home", home);
        if (opt_name != NULL) dsh_cfg_set_str(&cfg, "device_name", device);

        apply_log_level(dsh_cfg_str(&cfg, "log_level", "info"));
        if (opt_verbose) {
            /* Applied after the config default, which would otherwise win. */
            dsh_log_set_level(DSH_LOG_DEBUG);
            dsh_cfg_set_str(&cfg, "log_level", "debug");
        }

        if (dsh_cfg_save(&cfg) != 0) {
            DSH_WARN("无法写入 %s；设置不会保留", config_path);
        } else if (dsh_cfg_created(&cfg)) {
            DSH_INFO("已在 %s 创建默认配置", config_path);
        }

#ifdef _WIN32
        SetConsoleCtrlHandler(console_handler, TRUE);
#endif

        if (dsh_net_init() != 0) {
            DSH_ERROR("cannot initialize networking");
            return 1;
        }

        agent_set_config(host, port, pass, url, token, device, home);
    }

    if (!console_mode) {
        return agent_ui_run(GetModuleHandleW(NULL), &cfg);
    }

    if (agent_start() != 0) {
        fprintf(stderr,
                "refusing to start: no passphrase configured.\n"
                "Set one with --passphrase VALUE, or add 'passphrase' to %s.\n"
                "It must match the relay server and every client.\n",
                config_path);
        return 1;
    }

    agent_run();
    agent_stop();
    return 0;
}
