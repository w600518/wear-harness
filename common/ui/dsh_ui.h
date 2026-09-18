/*
 * dsh_ui.h - native Win32 GUI toolkit shared by the relay server and sender.
 *
 * The relay programs are console tools first: `--console` keeps the original
 * behaviour, and with no flag they show this window instead. Both modes drive
 * the same core, so the GUI never becomes a second implementation.
 *
 * Deliberately built on plain Win32 controls: llvm-mingw links them with no
 * extra dependency, and the resulting binaries stay a few hundred kilobytes.
 * All text crosses the API as UTF-8 and is widened here, so callers never
 * juggle two string types.
 */
#ifndef DSH_UI_H
#define DSH_UI_H

/*
 * windows.h must come first: commctrl.h declares its types in terms of LONG,
 * HWND and friends, and fails with "unknown type name" if it is included alone.
 */
#include <windows.h>
#include <commctrl.h>

#include <stddef.h>

#include "../util/dsh_log.h"

/* ── UTF-8 bridge ────────────────────────────────────────────────────────── */

/*
 * Converts UTF-8 to UTF-16 in a per-thread buffer, for the Win32 W APIs.
 * The returned pointer is valid until the next call on the same thread.
 */
const wchar_t *dsh_ui_wide(const char *utf8);

/* ── log bridge ──────────────────────────────────────────────────────────── */

/*
 * The log sink runs on whichever thread logged, while the window repaints on
 * the UI thread. Instead of marshalling strings across threads, sink output
 * lands in a bounded ring that the window drains on a timer.
 */
void   dsh_ui_log_attach(void);
void   dsh_ui_log_reset(void);

/*
 * Copies everything logged since the last call into `out` (NUL terminated) and
 * returns the byte count. Text longer than `out_cap` is truncated, and the
 * truncation is counted as consumed so the UI cannot fall permanently behind.
 */
size_t dsh_ui_log_take(char *out, size_t out_cap);

/* ── window construction ─────────────────────────────────────────────────── */

typedef LRESULT (*dsh_ui_handler)(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp);

/*
 * Registers the shared window class and creates a window. `handler` receives
 * messages the toolkit does not consume.
 *
 * The handler owns DefWindowProcW: it must forward anything it does not handle,
 * otherwise WM_NCCREATE answers FALSE and the window is never created.
 */
HWND dsh_ui_create_window(HINSTANCE instance, const char *title,
                          int width, int height, dsh_ui_handler handler);

/* Runs the message loop until the window closes. Returns the exit code. */
int  dsh_ui_run(void);

/*
 * Registers a callback invoked just before the window closes, so a front end
 * can stop its service and persist settings. There is no way to veto the close:
 * a stuck shutdown must not trap the user in the window.
 */
void dsh_ui_set_close_handler(void (*handler)(HWND hwnd, void *userdata), void *userdata);

/* Installs the shell UI font on a control so Chinese text renders properly. */
void dsh_ui_set_font(HWND control);
/* Applies the shell font to every control in `parent`. */
void dsh_ui_font_all(HWND parent);

/* ── controls ────────────────────────────────────────────────────────────── */

HWND dsh_ui_label(HWND parent, int x, int y, int w, int h, const char *text);
HWND dsh_ui_heading(HWND parent, int x, int y, int w, int h, const char *text);
HWND dsh_ui_edit(HWND parent, int x, int y, int w, int h, const char *text, int read_only);
HWND dsh_ui_password(HWND parent, int x, int y, int w, int h, const char *text);

/*
 * Shows or re-masks a password field.
 *
 * Win32 applies ES_PASSWORD when the control is created, so clearing the style
 * bit at run time leaves the text masked. The character itself has to change,
 * through EM_SETPASSWORDCHAR, followed by a repaint.
 */
void dsh_ui_set_password_visible(HWND edit, int visible);
HWND dsh_ui_button(HWND parent, int x, int y, int w, int h, const char *text, int id);
HWND dsh_ui_group(HWND parent, int x, int y, int w, int h, const char *text);
HWND dsh_ui_multiline(HWND parent, int x, int y, int w, int h, int id);
HWND dsh_ui_list(HWND parent, int x, int y, int w, int h, int id);

/* Reads a control's text as UTF-8. Always NUL terminates. */
void dsh_ui_get_text(HWND control, char *out, size_t cap);
void dsh_ui_set_text(HWND control, const char *utf8);

/* Appends text to a multiline edit without disturbing the caret. */
void dsh_ui_append(HWND edit, const char *utf8);
/* Trims the edit when it grows past `max_chars`, keeping the newest half. */
void dsh_ui_trim(HWND edit, int max_chars);

/* ── list view helpers ───────────────────────────────────────────────────── */

void dsh_ui_list_columns(HWND list, const char *const *titles, const int *widths, int count);
void dsh_ui_list_clear(HWND list);
int  dsh_ui_list_add(HWND list, const char *const *cells, int count);
void dsh_ui_list_fill_row(HWND list, int index, const char *const *cells, int count);

/* ── dialogs ─────────────────────────────────────────────────────────────── */

void dsh_ui_info(HWND parent, const char *title, const char *message);
void dsh_ui_error(HWND parent, const char *title, const char *message);
int  dsh_ui_confirm(HWND parent, const char *title, const char *message);

/*
 * Standard file dialogs. `save` selects between the save and open forms; the
 * buffer receives a UTF-8 path.
 */
int dsh_ui_file_dialog(HWND parent, int save, const char *title,
                       const char *filter, char *out, size_t cap);

/* `--console` support: reattaches stdout/stderr to the parent console. */
int dsh_ui_attach_console(void);

#endif /* DSH_UI_H */
