/*
 * dsh_ws.h - WebSocket client for the dsh remote mux (`/api/remote.mux`).
 *
 * dsh carries every streaming RPC (`session/follow`, `session/control`,
 * `workspace/follow`) over one WebSocket mux, not SSE. The follower needs
 * `session/follow` because `session/page` refuses a cursor that did not come
 * from a follow opening frame, and `session/control` is where queue, jobs and
 * projection baselines arrive.
 *
 * Text frames only; client frames are always masked, per RFC 6455.
 */
#ifndef DSH_WS_H
#define DSH_WS_H

#include <stddef.h>

#include "dsh_http.h"
#include "dsh_json.h"
#include "dsh_net.h"

typedef struct {
    dsh_socket sock;
    int        open;
    dsh_sb     pending;   /* accumulates fragmented messages */
} dsh_ws;

/*
 * Performs the HTTP Upgrade against `path` on the host already configured in
 * `http` (including its authentication cookie). Returns 0 on success and
 * writes a reason into `error` otherwise.
 */
int dsh_ws_connect(dsh_http *http, const char *path, dsh_ws *ws, dsh_sb *error);

/* Sends one masked text message. Returns 0 on success. */
int dsh_ws_send_text(dsh_ws *ws, const char *text, size_t len);

/*
 * Waits up to `timeout_ms` for one complete text message.
 * Returns 1 and fills `out` on a message, 0 on timeout, -1 when the peer
 * closed, -2 on a protocol or transport error. Ping frames are answered
 * automatically and close frames terminate the socket.
 */
int dsh_ws_recv(dsh_ws *ws, dsh_sb *out, int timeout_ms);

void dsh_ws_close(dsh_ws *ws);

/* True when the socket has an open WebSocket session. */
int dsh_ws_is_open(const dsh_ws *ws);

#endif /* DSH_WS_H */
