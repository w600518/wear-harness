/*
 * agent/ui.c - the relay sender's window.
 *
 * The sender has more to configure than the server (a relay to reach, and a
 * local dsh to authenticate against), so the top half is a form and the bottom
 * half is the live log. The mirror loop runs on its own thread; this file only
 * reacts to messages and polls.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "agent.h"
#include "../common/ui/dsh_ui.h"

#define ID_RELAY_HOST  1101
#define ID_RELAY_PORT  1102
#define ID_PASS        1103
#define ID_DEVICE      1104
#define ID_DSH_URL     1105
#define ID_DSH_TOKEN   1106
#define ID_CONNECT     1107
#define ID_DISCONNECT  1108
#define ID_SHOW_PASS   1109
#define ID_SHOW_TOKEN  1110
#define ID_LOG         1111
#define ID_STATUS      1112
#define ID_CFGPATH     1113

#define TIMER_LOG      1
#define TIMER_STATUS   2

#define WINDOW_W 800
#define WINDOW_H 720
#define MARGIN   12

typedef struct {
    HWND window;
    HWND relay_host;
    HWND relay_port;
    HWND pass_edit;
    HWND show_pass;
    HWND device_edit;
    HWND dsh_url;
    HWND dsh_token;
    HWND show_token;
    HWND connect_button;
    HWND disconnect_button;
    HWND status_label;
    HWND cfg_label;
    HWND log_group;
    HWND log_edit;
    HANDLE worker;
    int    running;
    dsh_cfg_file *cfg;
} agent_window;

static agent_window ui;

/* ── helpers ─────────────────────────────────────────────────────────────── */

static void set_editable(int editable) {
    EnableWindow(ui.relay_host, editable);
    EnableWindow(ui.relay_port, editable);
    EnableWindow(ui.pass_edit, editable);
    EnableWindow(ui.device_edit, editable);
    EnableWindow(ui.dsh_url, editable);
    EnableWindow(ui.dsh_token, editable);
    EnableWindow(ui.connect_button, editable);
    EnableWindow(ui.disconnect_button, !editable);
}

static void reveal(HWND edit, HWND checkbox) {
    LRESULT checked = SendMessageW(checkbox, BM_GETCHECK, 0, 0);
    dsh_ui_set_password_visible(edit, checked == BST_CHECKED);
}

/* ── actions ─────────────────────────────────────────────────────────────── */

static void connect_sender(void) {
    char host[256];
    char port_text[32];
    char pass[512];
    char device[128];
    char url[256];
    char token[712];
    int port;

    if (ui.running) {
        return;
    }

    dsh_ui_get_text(ui.relay_host, host, sizeof(host));
    dsh_ui_get_text(ui.relay_port, port_text, sizeof(port_text));
    dsh_ui_get_text(ui.pass_edit, pass, sizeof(pass));
    dsh_ui_get_text(ui.device_edit, device, sizeof(device));
    dsh_ui_get_text(ui.dsh_url, url, sizeof(url));
    dsh_ui_get_text(ui.dsh_token, token, sizeof(token));

    port = atoi(port_text);
    if (host[0] == '\0') {
        dsh_ui_error(ui.window, "缺少中继地址", "请填写中继服务端的地址。");
        return;
    }
    if (port <= 0 || port > 65535) {
        dsh_ui_error(ui.window, "端口无效", "请输入 1 到 65535 之间的端口号。");
        return;
    }
    if (strlen(pass) < 8) {
        dsh_ui_error(ui.window, "口令太短",
                     "共享口令至少需要 8 个字符，并且必须与服务端、客户端完全一致。");
        return;
    }

    /* Record what is about to be used, so a restart and the file agree. */
    dsh_cfg_set_str(ui.cfg, "server_host", host);
    dsh_cfg_set_int(ui.cfg, "server_port", port);
    dsh_cfg_set_str(ui.cfg, "passphrase", pass);
    dsh_cfg_set_str(ui.cfg, "device_name", device);
    dsh_cfg_set_str(ui.cfg, "dsh_url", url);
    dsh_cfg_set_str(ui.cfg, "dsh_token", token);
    if (dsh_cfg_save(ui.cfg) != 0) {
        DSH_WARN("无法写入 %s；设置不会保留", ui.cfg->path);
    }

    agent_set_config(host, port, pass, url, token, device);

    if (agent_start() != 0) {
        dsh_ui_error(ui.window, "无法启动", "共享口令未填写。");
        return;
    }

    ui.worker = CreateThread(NULL, 0, agent_thread_proc, NULL, 0, NULL);
    ui.running = 1;
    set_editable(0);
}

static void disconnect_sender(void) {
    if (!ui.running) {
        return;
    }

    agent_stop();

    if (ui.worker != NULL) {
        WaitForSingleObject(ui.worker, 4000);
        CloseHandle(ui.worker);
        ui.worker = NULL;
    }

    ui.running = 0;
    set_editable(1);
}

/* ── polling ─────────────────────────────────────────────────────────────── */

static void pump_log(void) {
    static char buffer[16384];
    size_t got = dsh_ui_log_take(buffer, sizeof(buffer));

    if (got > 0) {
        dsh_ui_append(ui.log_edit, buffer);
        dsh_ui_trim(ui.log_edit, 200000);
    }
}

static void refresh_status(void) {
    agent_status status;
    char line[512];

    agent_get_status(&status);

    snprintf(line, sizeof(line),
             "状态：%s      中继：%s（%s）      dsh：%s     事件流：%s",
             status.running ? "运行中" : "已停止",
             status.relay_connected ? "已连接" : "未连接",
             status.relay_target[0] != '\0' ? status.relay_target : "-",
             status.dsh_reachable ? "可达" : "不可达",
             status.mux_open ? "已建立" : "未建立");
    dsh_ui_set_text(ui.status_label, line);

    /*
     * The sender retries the relay on a timer, so a transient failure would
     * otherwise print the same "cannot connect" line on every poll. The
     * connection state is already on the line above; the log keeps the detail.
     */

    /* A second line carrying the counters keeps the first one readable. */
    {
        char counters[256];
        snprintf(counters, sizeof(counters),
                 "设备：%s      dsh：%s      会话：%d      跟随：%d      收发帧：%llu / %llu",
                 status.device_name[0] != '\0' ? status.device_name : "-",
                 status.dsh_target[0] != '\0' ? status.dsh_target : "-",
                 status.session_count, status.followed_sessions,
                 status.frames_in, status.frames_out);
        dsh_ui_set_text(GetDlgItem(ui.window, ID_CFGPATH), counters);
    }
}

/* ── lifecycle ───────────────────────────────────────────────────────────── */

static void on_close(HWND hwnd, void *userdata) {
    (void)hwnd;
    (void)userdata;

    if (ui.running) {
        disconnect_sender();
    }
    KillTimer(ui.window, TIMER_LOG);
    KillTimer(ui.window, TIMER_STATUS);
    dsh_cfg_close(ui.cfg);
}

static void layout(HWND hwnd) {
    RECT client;
    int width;
    int log_top = 300;
    int log_height;

    GetClientRect(hwnd, &client);
    width = client.right - client.left;
    log_height = client.bottom - log_top - MARGIN;
    if (log_height < 140) {
        log_height = 140;
    }

    MoveWindow(ui.log_group, MARGIN, log_top, width - MARGIN * 2, log_height, TRUE);
    MoveWindow(ui.log_edit, MARGIN * 2, log_top + 22,
               width - MARGIN * 4, log_height - 34, TRUE);
}

static HWND labelled_edit(HWND hwnd, int x, int y, int label_w,
                          const char *label, int field_x, int field_w, int id) {
    dsh_ui_label(hwnd, x, y + 4, label_w, 22, label);
    return dsh_ui_edit(hwnd, field_x, y, field_w, 26, "", 0);
}

static void create_controls(HWND hwnd) {
    int right = WINDOW_W - MARGIN * 2 - 20;

    ui.relay_host = labelled_edit(hwnd, MARGIN, MARGIN, 70, "中继地址",
                                  MARGIN + 76, 200, ID_RELAY_HOST);
    dsh_ui_label(hwnd, MARGIN + 290, MARGIN + 4, 40, 22, "端口");
    ui.relay_port = dsh_ui_edit(hwnd, MARGIN + 332, MARGIN, 70, 26, "", 0);

    dsh_ui_label(hwnd, MARGIN, MARGIN + 38, 70, 22, "共享口令");
    ui.pass_edit = dsh_ui_password(hwnd, MARGIN + 76, MARGIN + 34, 200, 26, "");
    ui.show_pass = CreateWindowExW(
        0, L"BUTTON", dsh_ui_wide("显示"),
        WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, MARGIN + 290, MARGIN + 37,
        70, 22, hwnd, (HMENU)(INT_PTR)ID_SHOW_PASS, NULL, NULL);
    dsh_ui_set_font(ui.show_pass);

    ui.device_edit = labelled_edit(hwnd, MARGIN, MARGIN + 72, 70, "设备名",
                                   MARGIN + 76, 200, ID_DEVICE);

    ui.dsh_url = labelled_edit(hwnd, MARGIN, MARGIN + 106, 70, "dsh 地址",
                               MARGIN + 76, 320, ID_DSH_URL);

    dsh_ui_label(hwnd, MARGIN, MARGIN + 140, 70, 22, "dsh token");
    ui.dsh_token = dsh_ui_password(hwnd, MARGIN + 76, MARGIN + 136, 320, 26, "");
    ui.show_token = CreateWindowExW(
        0, L"BUTTON", dsh_ui_wide("显示"),
        WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, MARGIN + 410, MARGIN + 139,
        70, 22, hwnd, (HMENU)(INT_PTR)ID_SHOW_TOKEN, NULL, NULL);
    dsh_ui_set_font(ui.show_token);

    ui.connect_button = dsh_ui_button(hwnd, MARGIN, MARGIN + 178, 130, 30,
                                      "连接中继", ID_CONNECT);
    ui.disconnect_button = dsh_ui_button(hwnd, MARGIN + 142, MARGIN + 178, 130, 30,
                                         "断开", ID_DISCONNECT);
    EnableWindow(ui.disconnect_button, FALSE);

    dsh_ui_label(hwnd, MARGIN + 290, MARGIN + 184, right - 270, 22, "");

    ui.status_label = dsh_ui_label(hwnd, MARGIN, MARGIN + 218, right, 24,
                                   "状态：已停止");

    /* The counters reuse a static control's slot; the id lets refresh_status
     * find it again without keeping a second handle. */
    {
        HWND counters = CreateWindowExW(
            0, L"STATIC", dsh_ui_wide(""), WS_CHILD | WS_VISIBLE | SS_LEFT | SS_CENTERIMAGE,
            MARGIN, MARGIN + 244, right, 22, hwnd,
            (HMENU)(INT_PTR)ID_CFGPATH, NULL, NULL);
        dsh_ui_set_font(counters);
    }

    ui.log_group = dsh_ui_group(hwnd, MARGIN, 300, right + 20, 300, "日志");
    ui.log_edit = dsh_ui_multiline(hwnd, MARGIN * 2, 322, right + 4, 268, ID_LOG);

    layout(hwnd);
}

static LRESULT CALLBACK agent_window_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE:
        ui.window = hwnd;
        create_controls(hwnd);
        SetTimer(hwnd, TIMER_LOG, 200, NULL);
        SetTimer(hwnd, TIMER_STATUS, 1000, NULL);
        return 0;

    case WM_SIZE:
        if (ui.log_edit != NULL) {
            layout(hwnd);
        }
        return 0;

    case WM_TIMER:
        if (wp == TIMER_LOG) {
            pump_log();
        } else if (wp == TIMER_STATUS) {
            refresh_status();
        }
        return 0;

    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case ID_CONNECT:
            connect_sender();
            refresh_status();
            return 0;
        case ID_DISCONNECT:
            disconnect_sender();
            refresh_status();
            return 0;
        case ID_SHOW_PASS:
            reveal(ui.pass_edit, ui.show_pass);
            return 0;
        case ID_SHOW_TOKEN:
            reveal(ui.dsh_token, ui.show_token);
            return 0;
        default:
            break;
        }
        return 0;

    default:
        break;
    }

    /* Anything unhandled must reach DefWindowProcW, or WM_NCCREATE answers
     * FALSE and the window never appears. */
    return DefWindowProcW(hwnd, msg, wp, lp);
}

int agent_ui_run(HINSTANCE instance, dsh_cfg_file *cfg) {
    memset(&ui, 0, sizeof(ui));
    ui.cfg = cfg;

    ui.window = dsh_ui_create_window(instance, "DSH Relay 发送端",
                                     WINDOW_W, WINDOW_H, agent_window_proc);
    if (ui.window == NULL) {
        return 1;
    }

    {
        char port_text[32];
        snprintf(port_text, sizeof(port_text), "%d",
                 dsh_cfg_int(cfg, "server_port", 7777));
        dsh_ui_set_text(ui.relay_host, dsh_cfg_str(cfg, "server_host", "127.0.0.1"));
        dsh_ui_set_text(ui.relay_port, port_text);
        dsh_ui_set_text(ui.pass_edit, dsh_cfg_str(cfg, "passphrase", ""));
        dsh_ui_set_text(ui.device_edit, dsh_cfg_str(cfg, "device_name", ""));
        dsh_ui_set_text(ui.dsh_url, dsh_cfg_str(cfg, "dsh_url", "http://127.0.0.1:3080"));
        dsh_ui_set_text(ui.dsh_token, dsh_cfg_str(cfg, "dsh_token", ""));

        /* Secrets start revealed: this window is on the machine that already
         * holds them, and a mistyped token is the most common failure. */
        SendMessageW(ui.show_pass, BM_SETCHECK, BST_CHECKED, 0);
        SendMessageW(ui.show_token, BM_SETCHECK, BST_CHECKED, 0);
        reveal(ui.pass_edit, ui.show_pass);
        reveal(ui.dsh_token, ui.show_token);
    }

    {
        char line[DSH_CFG_PATH_LEN + 64];
        snprintf(line, sizeof(line), "配置文件：%s", cfg->path);
        dsh_ui_set_text(ui.status_label, line);
    }

    dsh_ui_set_close_handler(on_close, NULL);

    DSH_INFO("DSH Relay 发送端已就绪，点击“连接中继”开始转发");
    refresh_status();

    return dsh_ui_run();
}
