/*
 * dsh_http.h - minimal HTTP/1.1 client for talking to a local dsh web server.
 *
 * The sender uses this to drive the same `/api/<namespace>/<method>` RPC
 * surface the browser GUI uses, so the Wear client inherits exactly the
 * behaviour of the shipped web UI instead of a private side channel.
 *
 * Deliberately small: plain sockets, one request per connection, no TLS (the
 * intended deployment is a loopback dsh web server), chunked and
 * content-length bodies both handled.
 */
#ifndef DSH_HTTP_H
#define DSH_HTTP_H

#include <stddef.h>

#include "dsh_json.h"
#include "dsh_net.h"

#define DSH_HTTP_MAX_HEADER 16384
#define DSH_HTTP_MAX_BODY (32u * 1024u * 1024u)

typedef struct {
    char     host[200];      /* hostname only, as passed to connect/resolve */
    char     authority[256]; /* host[:port], as written in the Host header */
    uint16_t port;
    char     cookie[2048];   /* Cookie header value, empty until login */
    int      logged_in;
} dsh_http;

/*
 * Parses a base URL such as `http://127.0.0.1:3080`. A trailing path is
 * rejected rather than ignored, because a wrong base silently talks to the
 * wrong surface. Returns 0 on success.
 */
int dsh_http_init(dsh_http *http, const char *base_url);

/*
 * Exchanges a `?token=...` launch URL for the session cookie the dsh web
 * server issues. Accepts either `http://host:port/?token=X` or a bare token
 * combined with the base URL already in `http`. Returns 0 when a cookie was
 * captured.
 */
int dsh_http_login(dsh_http *http, const char *launch_url_or_token);

/*
 * POSTs one JSON-RPC envelope. On success `*status` holds the HTTP status and
 * `body` holds the response bytes (which may be a plain-text error page, not
 * JSON, when the status is not 200). Returns 0 when the exchange completed,
 * regardless of status.
 */
int dsh_http_post(dsh_http *http, const char *path,
                  const char *body, size_t body_len,
                  dsh_sb *out, int *status);

/* GETs a path. Returns the HTTP status through `*status`. */
int dsh_http_get(dsh_http *http, const char *path, dsh_sb *out, int *status);

/*
 * Calls one dsh RPC endpoint and unwraps the envelope.
 *
 * `args_json` is the object that goes into `payload.args`. On success
 * `*value` receives a builder holding the `value` member of `result`, and the
 * function returns 0.
 *
 * On failure the function returns -1, writes a human-readable reason into
 * `error`, and — when `error_code` is not NULL — writes dsh's own error code
 * such as `session/not-found`. Folding that code into a generic failure would
 * strip the caller of the ability to react to a specific condition, so it is
 * always surfaced separately. Transport and HTTP failures use the synthetic
 * codes `relay/transport` and `relay/http-error`.
 */
int dsh_rpc_call(dsh_http *http, const char *endpoint,
                 const char *args_json, size_t args_len,
                 dsh_sb *value, dsh_sb *error, dsh_sb *error_code);

/* Generates a short random correlation id into `out` (at least 24 bytes). */
void dsh_http_make_rpc_id(char *out, size_t cap);

#endif /* DSH_HTTP_H */
