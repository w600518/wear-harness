/*
 * dsh_webauth.h - mints dsh web session cookies from the persisted credential.
 *
 * A `dsh web` launch token lives only in the memory of the dsh process, so no
 * other program can read it. What dsh does persist is the browser-session
 * signing secret in `~/.dsh/.credentials.yaml`; the web server itself accepts
 * cookies minted with it. This module reproduces that minting locally so the
 * sender can authenticate without a hand-copied token:
 *
 *   cookie name = "dsh-auth-" + base64url(sha256(authority))
 *   body        = base64url(JSON {version, authority, issuedAt, expiresAt})
 *   value       = "v1." body "." base64url(hmac_sha256(secret, body))
 *
 * `authority` is the host[:port] exactly as it appears in the Host header of
 * every request, because the server binds the cookie to it.
 */
#ifndef DSH_WEBAUTH_H
#define DSH_WEBAUTH_H

#include <stddef.h>

#define DSH_WEBAUTH_SECRET_LEN 64 /* base64url of 32 bytes, plus NUL */

/*
 * Builds one signed cookie value (name=value) into `out`.
 *
 * `secret_b64url` is the raw base64url string stored in the credentials file.
 * `issued_ms` and `expires_ms` are Unix milliseconds; the server accepts the
 * cookie only while issued <= now < expires. Returns 0 on success, -1 on any
 * malformed input or when `cap` is too small. Deterministic: the same inputs
 * always produce the same string, which is what the conformance vectors rely on.
 */
int dsh_webauth_cookie(const char *secret_b64url, const char *authority,
                       long long issued_ms, long long expires_ms,
                       char *out, size_t cap);

/*
 * Extracts the browser-session signing secret from a dsh credentials YAML
 * file. Only understands the narrow shape dsh writes: a
 * `client-connection/browser-session:` record holding `payload.secret`.
 * Returns 0 and the base64url secret on success.
 */
int dsh_webauth_secret_from_file(const char *yaml_path, char *out, size_t cap);

#endif /* DSH_WEBAUTH_H */
