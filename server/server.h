/*
 * server.h - the seam between the relay server's core and its two front ends.
 *
 * The console front end and the window front end drive the same accepting loop;
 * the window runs it on a worker thread and polls [server_status]. Nothing here
 * depends on the GUI, so a console-only build links without the UI at all.
 *
 * The relay listens on two ports rather than one. Senders connect to the agent
 * port and clients to the client port, and the port a connection arrived on
 * fixes its role: a peer that claims the other role in its HELLO is refused.
 * That keeps the two trust domains separable at the firewall, and makes a
 * forged role useless.
 */
#ifndef DSH_SERVER_H
#define DSH_SERVER_H

#include <stdint.h>

/*
 * dsh_net.h brings in winsock2.h, which must precede windows.h. Including it
 * first also makes windows.h available to the rest of this header.
 */
#include "../common/net/dsh_net.h"
#include "../common/util/dsh_cfg.h"

#include <windows.h>

#define DSH_SERVER_DEFAULT_AGENT_PORT 7777
#define DSH_SERVER_DEFAULT_CLIENT_PORT 7778

#define DSH_SERVER_STATUS_SENDERS 8
#define DSH_SERVER_STATUS_TEXT 256

/* One sender's row in the window's roster. */
typedef struct {
    char id[96];
    char name[128];
    char host[64];
    char remote[64];
    char dsh_version[32];
    int  dsh_home_set;
} server_sender_row;

/* Everything the window renders, read under the registry lock. */
typedef struct {
    int  running;
    int  agent_listening;
    int  client_listening;
    int  agent_port;
    int  client_port;

    int  senders;
    int  clients;
    unsigned long long frames_in;
    unsigned long long frames_out;
    unsigned long long replay_frames;

    int  sender_count;
    server_sender_row sender_rows[DSH_SERVER_STATUS_SENDERS];
} server_status;

/*
 * Creates both listening sockets and marks the server as running. The two ports
 * must differ. Returns 0 on success; on failure the caller can read
 * dsh_net_last_error().
 */
int serve_start(uint16_t agent_port, uint16_t client_port);

/*
 * Stops the accepting loop and closes both listeners. Safe to call from another
 * thread than the one inside serve_loop(), and safe to call twice.
 */
void serve_stop(void);

/* True between a successful serve_start() and a serve_stop(). */
int serve_is_running(void);

/* Blocking accept loop over both listeners. Returns once serve_stop() runs. */
void serve_loop(void);

/*
 * Replaces the shared secret the handshake uses. The window calls this with
 * what the user typed before starting, so the core keeps reading one global.
 */
void serve_set_passphrase(const char *passphrase);

/* Worker-thread wrapper around the pair above, for the window front end. */
DWORD WINAPI serve_thread_proc(LPVOID unused);

/* Fills `out` with the current counters and sender roster. */
void server_get_status(server_status *out);

/*
 * Window front end; block until the user closes it. `cfg` stays alive for the
 * whole call: the window reads the ports and passphrase from it and writes
 * changes back through dsh_cfg_save.
 */
int server_ui_run(HINSTANCE instance, dsh_cfg_file *cfg);

#endif /* DSH_SERVER_H */
