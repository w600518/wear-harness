#include "dsh_ui.h"

#include <commctrl.h>
#include <stdio.h>
#include <string.h>

/* ── UTF-8 to UTF-16 ─────────────────────────────────────────────────────── */

#define WIDE_BUFFER_LEN 4096

/* C11 thread-local storage: the wide staging buffer must not be shared between
 * the UI thread and the worker that logs. */
static _Thread_local wchar_t tls_wide[WIDE_BUFFER_LEN];

const wchar_t *dsh_ui_wide(const char *utf8) {
    if (utf8 == NULL) {
        tls_wide[0] = L'\0';
        return tls_wide;
    }
    if (MultiByteToWideChar(CP_UTF8, 0, utf8, -1, tls_wide, WIDE_BUFFER_LEN) == 0) {
        /* The text did not fit or was not valid UTF-8; degrade to empty rather
         * than showing whatever happened to be in the buffer before. */
        tls_wide[0] = L'\0';
    }
    return tls_wide;
}

static void utf8_to_wide(const char *utf8, wchar_t *out, size_t out_len) {
    if (out_len == 0) {
        return;
    }
    if (utf8 == NULL || MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out,
                                            (int)out_len) == 0) {
        out[0] = L'\0';
    }
}

static void wide_to_utf8(const wchar_t *wide, char *out, size_t cap) {
    if (cap == 0) {
        return;
    }
    if (wide == NULL || WideCharToMultiByte(CP_UTF8, 0, wide, -1, out, (int)cap,
                                            NULL, NULL) == 0) {
        out[0] = '\0';
    }
}

/* ── log ring ────────────────────────────────────────────────────────────── */

#define LOG_RING_CAP (192 * 1024)
#define LOG_LINE_MAX 2048

static char log_ring[LOG_RING_CAP];
static size_t log_write = 0;
static size_t log_consume = 0;
static CRITICAL_SECTION log_ring_lock;
static int log_ring_ready = 0;
static int log_hooked = 0;

static void log_ring_init(void) {
    if (!log_ring_ready) {
        InitializeCriticalSection(&log_ring_lock);
        log_ring_ready = 1;
    }
}

void dsh_ui_log_reset(void) {
    log_ring_init();
    EnterCriticalSection(&log_ring_lock);
    log_write = 0;
    log_consume = 0;
    LeaveCriticalSection(&log_ring_lock);
}

static void log_ring_push(const char *line, size_t len) {
    if (len > LOG_RING_CAP / 4) {
        /* One enormous line must not evict everything else. */
        len = LOG_RING_CAP / 4;
    }

    log_ring_init();
    EnterCriticalSection(&log_ring_lock);

    if (log_write + len > LOG_RING_CAP) {
        /* Slide the unread tail to the front to reclaim consumed space. */
        size_t unread = log_write - log_consume;
        if (unread > LOG_RING_CAP / 2) {
            /* The UI is far behind; keep the newest half and drop the rest. */
            size_t keep = LOG_RING_CAP / 2;
            memmove(log_ring, log_ring + log_write - keep, keep);
            log_write = keep;
            log_consume = 0;
        } else {
            memmove(log_ring, log_ring + log_consume, unread);
            log_write = unread;
            log_consume = 0;
        }
    }

    memcpy(log_ring + log_write, line, len);
    log_write += len;

    LeaveCriticalSection(&log_ring_lock);
}

static void log_sink(dsh_log_level level, const char *line, void *userdata) {
    char composed[LOG_LINE_MAX];
    int written;

    (void)level;
    (void)userdata;

    written = snprintf(composed, sizeof(composed), "%s\r\n", line);
    if (written <= 0) {
        return;
    }
    log_ring_push(composed, (size_t)written);
}

void dsh_ui_log_attach(void) {
    if (!log_hooked) {
        dsh_log_set_sink(log_sink, NULL);
        log_hooked = 1;
    }
    log_ring_init();
}

size_t dsh_ui_log_take(char *out, size_t out_cap) {
    size_t available;
    size_t take;

    if (out == NULL || out_cap == 0) {
        return 0;
    }

    log_ring_init();
    EnterCriticalSection(&log_ring_lock);

    available = log_write - log_consume;
    take = available < out_cap - 1 ? available : out_cap - 1;
    if (take > 0) {
        memcpy(out, log_ring + log_consume, take);
        log_consume += take;
    }
    out[take] = '\0';

    if (log_consume >= log_write) {
        /* Everything delivered: rewind so the ring never grows unbounded. */
        log_consume = 0;
        log_write = 0;
    }

    LeaveCriticalSection(&log_ring_lock);
    return take;
}

/* ── window class and fonts ──────────────────────────────────────────────── */

#define DSH_UI_CLASS L"DshRelayUiWindow"

static const wchar_t *WINDOW_CLASS = DSH_UI_CLASS;
static dsh_ui_handler g_handler = NULL;
static void (*g_close_handler)(HWND, void *) = NULL;
static void *g_close_user = NULL;
static HFONT g_font = NULL;

void dsh_ui_set_close_handler(void (*handler)(HWND hwnd, void *userdata), void *userdata) {
    g_close_handler = handler;
    g_close_user = userdata;
}

static HFONT ui_font(void) {
    if (g_font == NULL) {
        NONCLIENTMETRICSW metrics;
        metrics.cbSize = sizeof(metrics);
        if (SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(metrics),
                                  &metrics, 0)) {
            /* The shell message font already resolves to a face that covers
             * Chinese on a localized Windows. */
            g_font = CreateFontIndirectW(&metrics.lfMessageFont);
        }
        if (g_font == NULL) {
            g_font = CreateFontW(-14, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                                 DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                                 CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                                 DEFAULT_PITCH | FF_DONTCARE,
                                 L"Microsoft YaHei UI");
        }
    }
    return g_font;
}

void dsh_ui_set_font(HWND control) {
    if (control != NULL) {
        SendMessageW(control, WM_SETFONT, (WPARAM)ui_font(), TRUE);
    }
}

void dsh_ui_font_all(HWND parent) {
    HWND child = GetWindow(parent, GW_CHILD);
    dsh_ui_set_font(parent);
    while (child != NULL) {
        dsh_ui_set_font(child);
        child = GetWindow(child, GW_HWNDNEXT);
    }
}

static LRESULT CALLBACK ui_window_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_GETMINMAXINFO: {
        MINMAXINFO *info = (MINMAXINFO *)lp;
        info->ptMinTrackSize.x = 520;
        info->ptMinTrackSize.y = 420;
        return 0;
    }
    case WM_CLOSE:
        if (g_close_handler != NULL) {
            g_close_handler(hwnd, g_close_user);
        }
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    default:
        break;
    }

    if (g_handler != NULL) {
        return g_handler(hwnd, msg, wp, lp);
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

HWND dsh_ui_create_window(HINSTANCE instance, const char *title,
                          int width, int height, dsh_ui_handler handler) {
    WNDCLASSEXW wc;
    HWND hwnd;
    INITCOMMONCONTROLSEX icc;

    /* List views need the common controls library initialised first. */
    icc.dwSize = sizeof(icc);
    icc.dwICC = ICC_LISTVIEW_CLASSES | ICC_STANDARD_CLASSES;
    InitCommonControlsEx(&icc);

    g_handler = handler;

    memset(&wc, 0, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = ui_window_proc;
    wc.hInstance = instance;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    wc.lpszClassName = WINDOW_CLASS;

    if (RegisterClassExW(&wc) == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        return NULL;
    }

    hwnd = CreateWindowExW(0, WINDOW_CLASS, dsh_ui_wide(title),
                           WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
                           width, height, NULL, NULL, instance, NULL);
    if (hwnd == NULL) {
        return NULL;
    }

    ShowWindow(hwnd, SW_SHOWNORMAL);
    UpdateWindow(hwnd);
    return hwnd;
}

int dsh_ui_run(void) {
    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        if (IsDialogMessageW(GetActiveWindow(), &msg)) {
            continue;
        }
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return (int)msg.wParam;
}

/* ── control helpers ─────────────────────────────────────────────────────── */

static HWND make_control(HWND parent, const wchar_t *class_name, const char *text,
                         DWORD style, DWORD ex_style,
                         int x, int y, int w, int h, int id) {
    HWND control = CreateWindowExW(
        ex_style, class_name, dsh_ui_wide(text), WS_CHILD | WS_VISIBLE | style,
        x, y, w, h, parent, (HMENU)(INT_PTR)id, NULL, NULL);
    dsh_ui_set_font(control);
    return control;
}

HWND dsh_ui_label(HWND parent, int x, int y, int w, int h, const char *text) {
    return make_control(parent, L"STATIC", text, SS_LEFT | SS_CENTERIMAGE, 0,
                        x, y, w, h, 0);
}

HWND dsh_ui_heading(HWND parent, int x, int y, int w, int h, const char *text) {
    HWND control = make_control(parent, L"STATIC", text,
                                SS_LEFT | SS_CENTERIMAGE, 0, x, y, w, h, 0);
    /* A slightly larger face gives the sections a visible hierarchy without
     * pulling in a whole layout toolkit. */
    SendMessageW(control, WM_SETFONT,
                 (WPARAM)CreateFontW(-16, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE,
                                     FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                                     CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                                     DEFAULT_PITCH | FF_DONTCARE,
                                     L"Microsoft YaHei UI"),
                 TRUE);
    return control;
}

HWND dsh_ui_edit(HWND parent, int x, int y, int w, int h, const char *text, int read_only) {
    DWORD style = WS_TABSTOP | ES_AUTOHSCROLL;
    if (read_only) {
        style |= ES_READONLY;
    }
    return make_control(parent, L"EDIT", text, style, WS_EX_CLIENTEDGE, x, y, w, h, 0);
}

HWND dsh_ui_password(HWND parent, int x, int y, int w, int h, const char *text) {
    return make_control(parent, L"EDIT", text,
                        WS_TABSTOP | ES_AUTOHSCROLL | ES_PASSWORD,
                        WS_EX_CLIENTEDGE, x, y, w, h, 0);
}

void dsh_ui_set_password_visible(HWND edit, int visible) {
    if (edit == NULL) {
        return;
    }

    /* EM_SETPASSWORDCHAR with 0 removes the mask; restoring it needs the
     * character back, not the style bit. U+25CF is the bullet Windows uses. */
    SendMessageW(edit, EM_SETPASSWORDCHAR, visible ? 0 : (WPARAM)0x25CF, 0);
    InvalidateRect(edit, NULL, TRUE);
}

HWND dsh_ui_button(HWND parent, int x, int y, int w, int h, const char *text, int id) {
    return make_control(parent, L"BUTTON", text, WS_TABSTOP | BS_PUSHBUTTON,
                        0, x, y, w, h, id);
}

HWND dsh_ui_group(HWND parent, int x, int y, int w, int h, const char *text) {
    return make_control(parent, L"BUTTON", text, BS_GROUPBOX, 0, x, y, w, h, 0);
}

HWND dsh_ui_multiline(HWND parent, int x, int y, int w, int h, int id) {
    return make_control(parent, L"EDIT", "",
                        WS_TABSTOP | WS_VSCROLL | ES_MULTILINE | ES_READONLY |
                            ES_AUTOVSCROLL,
                        WS_EX_CLIENTEDGE, x, y, w, h, id);
}

HWND dsh_ui_list(HWND parent, int x, int y, int w, int h, int id) {
    return make_control(parent, WC_LISTVIEWW, "",
                        LVS_REPORT | LVS_SINGLESEL | LVS_SHOWSELALWAYS | WS_TABSTOP,
                        WS_EX_CLIENTEDGE, x, y, w, h, id);
}

void dsh_ui_get_text(HWND control, char *out, size_t cap) {
    wchar_t wide[2048];
    int len;

    if (out == NULL || cap == 0) {
        return;
    }
    out[0] = '\0';
    if (control == NULL) {
        return;
    }

    len = GetWindowTextW(control, wide, (int)(sizeof(wide) / sizeof(wide[0])));
    if (len <= 0) {
        return;
    }
    wide[len] = L'\0';
    wide_to_utf8(wide, out, cap);
}

void dsh_ui_set_text(HWND control, const char *utf8) {
    if (control != NULL) {
        SetWindowTextW(control, dsh_ui_wide(utf8));
    }
}

void dsh_ui_append(HWND edit, const char *utf8) {
    int length;

    if (edit == NULL || utf8 == NULL || utf8[0] == '\0') {
        return;
    }

    length = GetWindowTextLengthW(edit);
    SendMessageW(edit, EM_SETSEL, (WPARAM)length, (LPARAM)length);
    SendMessageW(edit, EM_REPLACESEL, FALSE, (LPARAM)dsh_ui_wide(utf8));
    SendMessageW(edit, EM_SCROLLCARET, 0, 0);
}

void dsh_ui_trim(HWND edit, int max_chars) {
    int length = GetWindowTextLengthW(edit);

    if (length <= max_chars) {
        return;
    }

    /* Drop the oldest half in one edit, so trimming cost stays amortised. */
    SendMessageW(edit, EM_SETSEL, 0, (LPARAM)(length / 2));
    SendMessageW(edit, EM_REPLACESEL, FALSE, (LPARAM)L"");
    SendMessageW(edit, EM_SETSEL, (WPARAM)-1, (LPARAM)-1);
}

/* ── list view ───────────────────────────────────────────────────────────── */

void dsh_ui_list_columns(HWND list, const char *const *titles, const int *widths, int count) {
    LVCOLUMNW column;
    int i;

    if (list == NULL) {
        return;
    }

    memset(&column, 0, sizeof(column));
    column.mask = LVCF_TEXT | LVCF_WIDTH | LVCF_SUBITEM;
    for (i = 0; i < count; i++) {
        column.pszText = (LPWSTR)dsh_ui_wide(titles[i]);
        column.cx = widths[i];
        column.iSubItem = i;
        ListView_InsertColumn(list, i, &column);
    }

    ListView_SetExtendedListViewStyle(
        list, LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER | LVS_EX_GRIDLINES);
}

void dsh_ui_list_clear(HWND list) {
    if (list != NULL) {
        ListView_DeleteAllItems(list);
    }
}

int dsh_ui_list_add(HWND list, const char *const *cells, int count) {
    LVITEMW item;
    int row;

    if (list == NULL) {
        return -1;
    }

    memset(&item, 0, sizeof(item));
    item.mask = LVIF_TEXT;
    item.iItem = ListView_GetItemCount(list);
    item.pszText = (LPWSTR)dsh_ui_wide(count > 0 ? cells[0] : "");
    row = ListView_InsertItem(list, &item);
    if (row < 0) {
        return -1;
    }

    for (int i = 1; i < count; i++) {
        ListView_SetItemText(list, row, i, (LPWSTR)dsh_ui_wide(cells[i]));
    }
    return row;
}

void dsh_ui_list_fill_row(HWND list, int index, const char *const *cells, int count) {
    int existing;

    if (list == NULL || index < 0) {
        return;
    }

    existing = ListView_GetItemCount(list);
    if (index >= existing) {
        dsh_ui_list_add(list, cells, count);
        return;
    }

    for (int i = 0; i < count; i++) {
        ListView_SetItemText(list, index, i, (LPWSTR)dsh_ui_wide(cells[i]));
    }
}

/* ── dialogs ─────────────────────────────────────────────────────────────── */

void dsh_ui_info(HWND parent, const char *title, const char *message) {
    MessageBoxW(parent, dsh_ui_wide(message), dsh_ui_wide(title),
                MB_OK | MB_ICONINFORMATION);
}

void dsh_ui_error(HWND parent, const char *title, const char *message) {
    MessageBoxW(parent, dsh_ui_wide(message), dsh_ui_wide(title),
                MB_OK | MB_ICONERROR);
}

int dsh_ui_confirm(HWND parent, const char *title, const char *message) {
    return MessageBoxW(parent, dsh_ui_wide(message), dsh_ui_wide(title),
                       MB_OKCANCEL | MB_ICONQUESTION) == IDOK;
}

int dsh_ui_file_dialog(HWND parent, int save, const char *title,
                       const char *filter, char *out, size_t cap) {
    OPENFILENAMEW ofn;
    wchar_t wide_path[MAX_PATH];
    wchar_t wide_filter[512];

    if (out == NULL || cap == 0) {
        return 0;
    }
    out[0] = '\0';
    wide_path[0] = L'\0';

    /* The filter string is "name|pattern|name|pattern|", which is exactly the
     * double-NUL-terminated form the dialog wants once the pipes become NULs. */
    if (filter == NULL || filter[0] == '\0') {
        filter = "All files|*.*|";
    }
    utf8_to_wide(filter, wide_filter, sizeof(wide_filter) / sizeof(wide_filter[0]));
    for (wchar_t *p = wide_filter; *p != L'\0'; p++) {
        if (*p == L'|') {
            *p = L'\0';
        }
    }

    memset(&ofn, 0, sizeof(ofn));
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = parent;
    ofn.lpstrFilter = wide_filter;
    ofn.lpstrFile = wide_path;
    ofn.nMaxFile = MAX_PATH;
    ofn.lpstrTitle = dsh_ui_wide(title);
    ofn.Flags = OFN_NOCHANGEDIR | OFN_PATHMUSTEXIST;
    if (save) {
        ofn.Flags |= OFN_OVERWRITEPROMPT;
    } else {
        ofn.Flags |= OFN_FILEMUSTEXIST;
    }

    if (save ? !GetSaveFileNameW(&ofn) : !GetOpenFileNameW(&ofn)) {
        return 0;
    }

    wide_to_utf8(wide_path, out, cap);
    return out[0] != '\0';
}

int dsh_ui_attach_console(void) {
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);

    /*
     * If stdout is already usable — the process was started from a console, or
     * the caller redirected it to a file or a pipe — leave it alone. Rebinding
     * it to CONOUT$ would silently discard a `> log.txt` redirection.
     */
    if (out != NULL && out != INVALID_HANDLE_VALUE &&
        GetFileType(out) != FILE_TYPE_UNKNOWN) {
        return 1;
    }

    /* A GUI-subsystem binary starts with no console at all; adopt the parent's
     * so `--console` and `--help` behave like a console program. */
    if (!AttachConsole(ATTACH_PARENT_PROCESS)) {
        return 0;
    }

    freopen("CONOUT$", "w", stdout);
    freopen("CONOUT$", "w", stderr);
    freopen("CONIN$", "r", stdin);

    /* The shell prints its prompt on the same line, so start on a fresh one. */
    fputc('\n', stdout);
    fflush(stdout);
    return 1;
}
