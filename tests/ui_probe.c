/*
 * ui_probe.c - verifies the toolchain can build a Win32 GUI with Chinese text.
 *
 * Not part of the product: it exists to prove three assumptions before the real
 * UI is written — that llvm-mingw links a GUI-subsystem binary, that UTF-8
 * source literals survive into a wide control, and that a control can be
 * created and measured off the message loop.
 */
#include <windows.h>
#include <stdio.h>

static const char *TITLE = "DSH Relay 探针 · Probe";

static LRESULT CALLBACK probe_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE: {
        /* MultiByteToWideChar with CP_UTF8 turns the literal into what a W
         * control expects, which is the path the real UI will use. */
        wchar_t wide[128];
        int n = MultiByteToWideChar(CP_UTF8, 0, TITLE, -1, wide, 128);
        HWND label = CreateWindowExW(0, L"STATIC",
                                     n > 0 ? wide : L"(conversion failed)",
                                     WS_CHILD | WS_VISIBLE | SS_CENTER,
                                     10, 10, 260, 40, hwnd, NULL, NULL, NULL);
        if (label == NULL) {
            PostQuitMessage(2);
            return 0;
        }
        SetTimer(hwnd, 1, 900, NULL);
        return 0;
    }
    case WM_TIMER:
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
}

int WINAPI WinMain(HINSTANCE instance, HINSTANCE prev, LPSTR cmdline, int show) {
    WNDCLASSEXW wc;
    HWND hwnd;
    MSG msg;
    int frames = 0;
    (void)prev;
    (void)cmdline;

    wc.cbSize = sizeof(wc);
    wc.style = 0;
    wc.lpfnWndProc = probe_proc;
    wc.cbClsExtra = 0;
    wc.cbWndExtra = 0;
    wc.hInstance = instance;
    wc.hIcon = NULL;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = L"DshUiProbe";
    wc.hIconSm = NULL;

    if (RegisterClassExW(&wc) == 0) {
        return 1;
    }

    hwnd = CreateWindowExW(0, L"DshUiProbe", L"probe", WS_OVERLAPPEDWINDOW,
                           100, 100, 320, 140, NULL, NULL, instance, NULL);
    if (hwnd == NULL) {
        return 1;
    }

    ShowWindow(hwnd, SW_SHOWNORMAL);

    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
        frames++;
    }

    /* Written to a file rather than stdout: a GUI-subsystem binary may have no
     * console, which is exactly the constraint the real UI must respect. */
    {
        FILE *fp = fopen("ui-probe-result.txt", "wb");
        if (fp != NULL) {
            fprintf(fp, "gui ok, messages pumped=%d\n", frames);
            fclose(fp);
        }
    }

    return 0;
}
