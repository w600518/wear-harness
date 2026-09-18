/*
 * dsh_wire.h - authenticated encryption envelope for the DSH relay.
 *
 * Every post-handshake byte on the relay socket is one frame:
 *
 *   offset  size  field
 *   0       4     magic "DSHX"
 *   4       1     version (1)
 *   5       1     type
 *   6       1     flags
 *   7       1     reserved (0)
 *   8       4     sequence, big endian
 *   12      4     ciphertext length, big endian (positive multiple of 16)
 *   16      16    IV
 *   32      N     AES-256-CBC ciphertext
 *   32+N    32    HMAC-SHA256 over bytes [0, 32+N)
 *
 * The MAC covers the header, so type and sequence cannot be rewritten. Frames
 * are only accepted in strictly increasing sequence order per direction, which
 * makes a captured frame unusable after the connection closes.
 *
 * Handshake frames (DSH_FRAME_HELLO / DSH_FRAME_HELLO_ACK) are plaintext
 * because no key exists yet; they carry only public nonces and the KDF salt.
 */
#ifndef DSH_WIRE_H
#define DSH_WIRE_H

#include <stddef.h>
#include <stdint.h>

#include "dsh_aes.h"
#include "dsh_json.h"
#include "dsh_sha256.h"

#define DSH_WIRE_VERSION 1
#define DSH_FRAME_HEADER_LEN 32
#define DSH_FRAME_TAG_LEN 32
/*
 * One frame's ceiling. A session's opening window is the largest thing that
 * crosses the relay, and a long conversation with reasoning and tool output
 * comfortably exceeds 8 MiB once serialized, so the limit is generous while
 * still bounding what a malicious peer can make the other side allocate.
 */
#define DSH_FRAME_MAX_PAYLOAD (32u * 1024u * 1024u)
#define DSH_WIRE_MAGIC "DSHX"

/* Frame types. Values are wire-visible and must stay stable. */
enum {
    DSH_FRAME_HELLO     = 1, /* client -> server, plaintext */
    DSH_FRAME_HELLO_ACK = 2, /* server -> client, plaintext */
    DSH_FRAME_DATA      = 3, /* both directions, encrypted */
    DSH_FRAME_BYE       = 4  /* both directions, encrypted */
};

/* Handshake roles. */
enum {
    DSH_ROLE_AGENT  = 1, /* the Windows sender forwarding a local dsh install */
    DSH_ROLE_CLIENT = 2  /* the Flutter Wear OS client */
};

/*
 * Per-connection crypto state. Derived from the shared passphrase, the salt
 * chosen by the server, and both nonces, so two connections never share a key
 * even with an unchanged passphrase.
 */
typedef struct {
    dsh_aes256 enc;
    dsh_aes256 dec;
    uint8_t    send_key_mac[DSH_SHA256_DIGEST_LEN];
    uint8_t    recv_key_mac[DSH_SHA256_DIGEST_LEN];
    uint32_t   send_seq;
    uint32_t   recv_seq;
    int        ready;
} dsh_crypto;

/* Fills `out` with `len` cryptographically secure random bytes. */
int dsh_random_bytes(void *out, size_t len);

/*
 * Derives the four directional keys and initializes `crypto`.
 * `passphrase` is the user-chosen shared secret; `salt` and the two nonces come
 * from the handshake. `is_server` selects which direction is encryption and
 * which is decryption. Returns 0 on success.
 */
int dsh_crypto_derive(dsh_crypto *crypto,
                      const char *passphrase,
                      const uint8_t salt[16],
                      const uint8_t client_nonce[16],
                      const uint8_t server_nonce[16],
                      int is_server);

void dsh_crypto_wipe(dsh_crypto *crypto);

/*
 * Builds one encrypted frame into `out` using the next send sequence number.
 * `out` must hold DSH_FRAME_HEADER_LEN + padded length + DSH_FRAME_TAG_LEN
 * bytes; `*outlen` receives the total frame size.
 */
int dsh_wire_seal(dsh_crypto *crypto, uint8_t type, const void *payload, size_t len,
                  dsh_sb *out);

/*
 * Verifies and decrypts a complete frame of `len` bytes. On success `*payload`
 * points into `plain` and `*payload_len` holds the length. `plain` must hold at
 * least `len` bytes. Returns 0 on success, negative on any rejection.
 */
int dsh_wire_open(dsh_crypto *crypto, const uint8_t *frame, size_t len,
                  uint8_t *plain, size_t *payload_len, uint8_t *type_out,
                  uint32_t *seq_out);

/*
 * Builds a plaintext handshake frame (no crypto state required).
 */
int dsh_wire_seal_plain(uint8_t type, const void *payload, size_t len, dsh_sb *out);

/*
 * Parses a plaintext handshake frame. Returns 0 on success.
 */
int dsh_wire_open_plain(const uint8_t *frame, size_t len,
                        uint8_t *type_out, const uint8_t **payload, size_t *payload_len);

/*
 * Compares a length-delimited token against the configured passphrase in
 * constant time. Used by the server to reject a wrong key before any data
 * frame is processed.
 */
int dsh_passphrase_matches(const char *configured, const char *presented, size_t presented_len);

/*
 * Proof of key possession carried in the plaintext HELLO:
 *
 *   HMAC-SHA256(key = passphrase, data = "dsh-relay/v1" || nonce)
 *
 * The password itself never crosses the wire, and a peer without the shared
 * secret cannot open a session at all.
 */
void dsh_handshake_proof(const char *passphrase,
                         const uint8_t nonce[16],
                         uint8_t out[DSH_SHA256_DIGEST_LEN]);

/* Writes 2*len lowercase hex digits plus a terminator into `out`. */
void dsh_hex_encode(const uint8_t *data, size_t len, char *out);
/*
 * Decodes `hex_len` hex digits. Returns 0 on success; `*out_len` receives the
 * byte count. Rejects odd lengths, non-hex digits, and overflow.
 */
int dsh_hex_decode(const char *hex, size_t hex_len, uint8_t *out, size_t out_cap, size_t *out_len);

#endif /* DSH_WIRE_H */
