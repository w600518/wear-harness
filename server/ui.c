/*
 * server/ui.c - the relay server's window.
 *
 * One screen: what to listen on, whether the relay is up, who is connected, and
 * the log. Everything the console front end prints lands here too, because both
 * drive the same core through the same log sink.
 *
 * The accepting loop runs on its own thread; this file only reacts to messages
 * and polls the counters, so a slow client can never freeze the window.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * server.h reaches winsock2.h, which insists on being included before
 * windows.h; dsh_ui.h pulls in windows.h, so it must come second.
 */
#include "server.h"
#include "../common/ui/dsh_ui.h"

#define ID_PORT        1001
#define ID_CLIENT_PORT 1010
#define ID_PASS        1002
#define ID_START      1003
#define ID_STOP       1004
#define ID_SHOW_PASS  1005
#define ID_LOG        1006
#define ID_SENDERS    1007
#define ID_STATUS     1008
#define ID_CFGPATH    1009

#define TIMER_LOG     1
#define TIMER_STATUS  2

#define WINDOW_W 800
#define WINDOW_H 740
#define MARGIN   12

typedef struct {
    HWND window;
    HWND port_edit;
    HWND client_port_edit;
    HWND pass_edit;
    HWND show_pass;
    HWND start_button;
    HWND stop_button;
    HWND status_label;
    HWND counters_label;
    HWND cfg_label;
    HWND sender_group;
    HWND sender_list;
    HWND log_group;
    HWND log_edit;
    HANDLE worker;
    int    running;
    dsh_cfg_file *cfg;
} server_window;

static server_window ui;

/* ── actions ─────────────────────────────────────────────────────────────── */

static void start_server(void) {
    char pass[512];
    int port;
    int client_port;

    if (ui.running) {
        return;
    }

    /*
     * The ports are read from the config at every start rather than taken from
     * the window, which only mirrors them. Editing config.json and pressing
     * start is therefore enough to move the listener; nothing has to be typed
     * on a watch-sized keyboard.
     */
    port = dsh_cfg_int(ui.cfg, "port", DSH_SERVER_DEFAULT_AGENT_PORT);
    client_port = dsh_cfg_int(ui.cfg, "client_port", DSH_SERVER_DEFAULT_CLIENT_PORT);

    if (port <= 0 || port > 65535) {
        dsh_ui_error(ui.window, "端口无效",
                     "config.json 里的 port 需要是 1 到 65535 之间的数字。");
        return;
    }
    if (client_port <= 0 || client_port > 65535) {
        dsh_ui_error(ui.window, "端口无效",
                     "config.json 里的 client_port 需要是 1 到 65535 之间的数字。");
        return;
    }
    if (port == client_port) {
        dsh_ui_error(ui.window, "端口重复",
                     "发送端端口与客户端端口必须不同。\n\n"
                     "分开正是为了让服务端按端口判定角色："
                     "手表客户端无法把自己伪装成发送端。两端口相同就等于放弃了这道校验。");
        return;
    }

    dsh_ui_get_text(ui.pass_edit, pass, sizeof(pass));
    if (strlen(pass) < 8) {
        dsh_ui_error(ui.window, "口令太短",
                     "共享口令至少需要 8 个字符。\n"
                     "它决定整条隧道的强度：口令越短，越容易被离线暴力破解。");
        return;
    }

    /* The passphrase is the one field the window owns, so it is what gets
     * written back; the ports already came from the file. */
    dsh_cfg_set_str(ui.cfg, "passphrase", pass);
    if (dsh_cfg_save(ui.cfg) != 0) {
        DSH_WARN("cannot write %s; settings will not persist", ui.cfg->path);
    }

    serve_set_passphrase(pass);

    if (serve_start((uint16_t)port, (uint16_t)client_port) != 0) {
        char message[420];
        snprintf(message, sizeof(message),
                 "无法监听端口 %d 和 %d：%s\n\n"
                 "其中一个端口可能已被占用，或被防火墙拦下。",
                 port, client_port, dsh_net_last_error());
        dsh_ui_error(ui.window, "启动失败", message);
        return;
    }

    ui.worker = CreateThread(NULL, 0, serve_thread_proc, NULL, 0, NULL);
    ui.running = 1;

    EnableWindow(ui.start_button, FALSE);
    EnableWindow(ui.stop_button, TRUE);
    EnableWindow(ui.pass_edit, FALSE);
}

static void stop_server(void) {
    if (!ui.running) {
        return;
    }

    /* Closing the listener wakes the blocked accept(), which ends the loop. */
    serve_stop();

    if (ui.worker != NULL) {
        /* A bounded wait keeps the window responsive even if a client thread is
         * slow to unwind. */
        WaitForSingleObject(ui.worker, 4000);
        CloseHandle(ui.worker);
        ui.worker = NULL;
    }

    ui.running = 0;

    EnableWindow(ui.start_button, TRUE);
    EnableWindow(ui.stop_button, FALSE);
    EnableWindow(ui.pass_edit, TRUE);
}

/* ── polling ─────────────────────────────────────────────────────────────── */

static void pump_log(void) {
    static char buffer[16384];
    size_t got = dsh_ui_log_take(buffer, sizeof(buffer));

    if (got > 0) {
        dsh_ui_append(ui.log_edit, buffer);
        /* Keep the control bounded: a day of debug logging must not turn into a
         * gigabyte of text. */
        dsh_ui_trim(ui.log_edit, 200000);
    }
}

static void refresh_status(void) {
    server_status status;
    char line[400];
    char port_text[16];
    int i;

    server_get_status(&status);

    /*
     * The port fields mirror the config rather than a typed value, so they are
     * refreshed from the file on every tick. Editing config.json and restarting
     * the listener is the whole flow; nothing is entered in the window.
     */
    snprintf(port_text, sizeof(port_text), "%d",
             dsh_cfg_int(ui.cfg, "port", DSH_SERVER_DEFAULT_AGENT_PORT));
    dsh_ui_set_text(ui.port_edit, port_text);
    snprintf(port_text, sizeof(port_text), "%d",
             dsh_cfg_int(ui.cfg, "client_port", DSH_SERVER_DEFAULT_CLIENT_PORT));
    dsh_ui_set_text(ui.client_port_edit, port_text);

    snprintf(line, sizeof(line),
             "状态：%s      发送端端口 %d：%s      客户端端口 %d：%s",
             status.running ? "运行中" : "已停止",
             status.agent_port, status.agent_listening ? "监听中" : "未监听",
             status.client_port, status.client_listening ? "监听中" : "未监听");
    dsh_ui_set_text(ui.status_label, line);

    snprintf(line, sizeof(line),
             "发送端：%d      客户端：%d      收发帧：%llu / %llu",
             status.senders, status.clients,
             status.frames_in, status.frames_out);
    dsh_ui_set_text(ui.counters_label, line);

    if (ListView_GetItemCount(ui.sender_list) != status.sender_count) {
        dsh_ui_list_clear(ui.sender_list);
    }

    for (i = 0; i < status.sender_count; i++) {
        const server_sender_row *row = &status.sender_rows[i];
        const char *cells[5];
        cells[0] = row->id;
        cells[1] = row->name;
        cells[2] = row->host;
        cells[3] = row->remote;
        cells[4] = row->dsh_version;
        dsh_ui_list_fill_row(ui.sender_list, i, cells, 5);
    }
}

/* ── lifecycle ───────────────────────────────────────────────────────────── */

static void on_close(HWND hwnd, void *userdata) {
    (void)hwnd;
    (void)userdata;

    if (ui.running) {
        stop_server();
    }
    KillTimer(ui.window, TIMER_LOG);
    KillTimer(ui.window, TIMER_STATUS);
    dsh_cfg_close(ui.cfg);
}

/* Keeps the log panel filling the space under the fixed top area. */
static void layout(HWND hwnd) {
    RECT client;
    int width;
    int log_top = 360;
    int log_height;

    GetClientRect(hwnd, &client);
    width = client.right - client.left;
    log_height = client.bottom - log_top - MARGIN;
    if (log_height < 120) {
        log_height = 120;
    }

    MoveWindow(ui.log_group, MARGIN, log_top,
               width - MARGIN * 2, log_height, TRUE);
    MoveWindow(ui.log_edit, MARGIN * 2, log_top + 22,
               width - MARGIN * 4, log_height - 34, TRUE);

    MoveWindow(ui.sender_group, MARGIN, 190, width - MARGIN * 2, 158, TRUE);
    MoveWindow(ui.sender_list, MARGIN * 2, 212, width - MARGIN * 4, 126, TRUE);
}

static void create_controls(HWND hwnd) {
    int content_w = WINDOW_W - MARGIN * 2 - 16;

    dsh_ui_label(hwnd, MARGIN, MARGIN + 4, 82, 22, "发送端端口");
    ui.port_edit = dsh_ui_edit(hwnd, MARGIN + 88, MARGIN, 76, 26, "", 1);

    dsh_ui_label(hwnd, MARGIN + 180, MARGIN + 4, 82, 22, "客户端端口");
    ui.client_port_edit = dsh_ui_edit(hwnd, MARGIN + 268, MARGIN, 76, 26, "", 1);

    dsh_ui_label(hwnd, MARGIN, MARGIN + 42, 82, 22, "共享口令");
    ui.pass_edit = dsh_ui_password(hwnd, MARGIN + 88, MARGIN + 38, 220, 26, "");
    ui.show_pass = CreateWindowExW(
        0, L"BUTTON", dsh_ui_wide("显示"),
        WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, MARGIN + 316, MARGIN + 41, 70, 22,
        hwnd, (HMENU)(INT_PTR)ID_SHOW_PASS, NULL, NULL);
    dsh_ui_set_font(ui.show_pass);

    ui.start_button = dsh_ui_button(hwnd, MARGIN, MARGIN + 78, 120, 30, "启动服务", ID_START);
    ui.stop_button = dsh_ui_button(hwnd, MARGIN + 132, MARGIN + 78, 120, 30, "停止服务", ID_STOP);
    EnableWindow(ui.stop_button, FALSE);

    ui.cfg_label = dsh_ui_label(hwnd, MARGIN + 268, MARGIN + 84, content_w - 240, 22, "");

    ui.sender_group = dsh_ui_group(hwnd, MARGIN, 190, content_w + 16, 158,
                                   "在线发送端");
    ui.sender_list = dsh_ui_list(hwnd, MARGIN * 2, 212, content_w - 8, 126, ID_SENDERS);
    {
        static const char *titles[5] = { "标识", "名称", "主机", "来源", "dsh 版本" };
        static const int widths[5] = { 190, 150, 120, 160, 100 };
        dsh_ui_list_columns(ui.sender_list, titles, widths, 5);
    }

    ui.status_label = dsh_ui_label(hwnd, MARGIN * 2, 124, content_w, 24,
                                   "状态：已停止");
    ui.counters_label = dsh_ui_label(hwnd, MARGIN * 2, 152, content_w, 22,
                                     "发送端连到发送端端口，手表客户端连到客户端端口。");

    ui.log_group = dsh_ui_group(hwnd, MARGIN, 360, content_w + 16, 300, "日志");
    ui.log_edit = dsh_ui_multiline(hwnd, MARGIN * 2, 382, content_w - 8, 268, ID_LOG);

    layout(hwnd);
}

static LRESULT CALLBACK server_window_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
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
        case ID_START:
            start_server();
            refresh_status();
            return 0;
        case ID_STOP:
            stop_server();
            refresh_status();
            return 0;
        case ID_SHOW_PASS: {
            /* Toggling ES_PASSWORD at run time does nothing; the mask is a
             * creation-time style, so the password character is switched. */
            LRESULT checked = SendMessageW(ui.show_pass, BM_GETCHECK, 0, 0);
            dsh_ui_set_password_visible(ui.pass_edit, checked == BST_CHECKED);
            return 0;
        }
        default:
            break;
        }
        return 0;

    default:
        break;
    }

    /*
     * Unhandled messages must reach DefWindowProcW. Returning 0 instead makes
     * WM_NCCREATE answer FALSE and the window fails to be created at all, which
     * is exactly what a bare `return 0` here causes.
     */
    return DefWindowProcW(hwnd, msg, wp, lp);
}

int server_ui_run(HINSTANCE instance, dsh_cfg_file *cfg) {
    char path_line[DSH_CFG_PATH_LEN + 64];

    memset(&ui, 0, sizeof(ui));
    ui.cfg = cfg;

    ui.window = dsh_ui_create_window(instance, "DSH Relay 服务端",
                                     WINDOW_W, WINDOW_H, server_window_proc);
    if (ui.window == NULL) {
        return 1;
    }

    /* Seed the fields from the config that main() already loaded. */
    {
        char port_text[32];
        snprintf(port_text, sizeof(port_text), "%d",
                 dsh_cfg_int(cfg, "port", DSH_SERVER_DEFAULT_AGENT_PORT));
        dsh_ui_set_text(ui.port_edit, port_text);

        snprintf(port_text, sizeof(port_text), "%d",
                 dsh_cfg_int(cfg, "client_port", DSH_SERVER_DEFAULT_CLIENT_PORT));
        dsh_ui_set_text(ui.client_port_edit, port_text);

        dsh_ui_set_text(ui.pass_edit, dsh_cfg_str(cfg, "passphrase", ""));
        SendMessageW(ui.show_pass, BM_SETCHECK, BST_CHECKED, 0);
        dsh_ui_set_password_visible(ui.pass_edit, 1);
    }

    snprintf(path_line, sizeof(path_line), "配置文件：%s", cfg->path);
    dsh_ui_set_text(ui.cfg_label, path_line);

    dsh_ui_set_close_handler(on_close, NULL);

    DSH_INFO("DSH Relay 服务端已就绪，点击“启动服务”开始监听");
    refresh_status();

    return dsh_ui_run();
}
