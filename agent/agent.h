/*
 * agent.h - the seam between the sender's core and its two front ends.
 *
 * The console front end runs [agent_run] directly; the window starts it on a
 * worker thread and polls [agent_status]. Nothing here depends on the GUI, so
 * the console path links without the UI.
 */
#ifndef DSH_AGENT_H
#define DSH_AGENT_H

#include <stdint.h>

#include "../common/net/dsh_net.h"
#include "../common/util/dsh_cfg.h"

#include <windows.h>

typedef struct {
    /* lifetime */
    int running;

    /* relay tunnel */
    int relay_connected;

    /* local dsh */
    int dsh_reachable;
    int mux_open;
    int followed_sessions;
    int session_count;

    /* traffic */
    unsigned long long frames_in;
    unsigned long long frames_out;

    /* what the window shows in its header */
    char device_name[128];
    char relay_target[300];
    char dsh_target[300];
    char last_error[256];
} agent_status;

/*
 * Copies the settings the next [agent_start] will use. The window calls this
 * after the user edits the fields; the console front end calls it once at boot.
 */
void agent_set_config(const char *server_host, int server_port,
                      const char *passphrase, const char *dsh_url,
                      const char *dsh_token, const char *device_name,
                      const char *dsh_home);

/*
 * Initializes the connection state and authenticates to the local dsh. Does not
 * block: the relay tunnel and the mirror are driven by [agent_run].
 * Returns 0 on success, -1 when the settings are unusable.
 */
int agent_start(void);

/* Stops the loop and closes both sides. Safe to call from another thread. */
void agent_stop(void);

int agent_is_running(void);

/* Blocking loop. Returns once agent_stop() has been called. */
void agent_run(void);

/* Worker-thread wrapper around [agent_run], for the window front end. */
DWORD WINAPI agent_thread_proc(LPVOID unused);

/* Fills `out` with the current counters and target descriptions. */
void agent_get_status(agent_status *out);

/* Window front end; blocks until the user closes it. */
int agent_ui_run(HINSTANCE instance, dsh_cfg_file *cfg);

#endif /* DSH_AGENT_H */
