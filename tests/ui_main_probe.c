#include <windows.h>
#include <stdio.h>
static LRESULT CALLBACK proc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_CREATE) { SetTimer(h, 1, 700, NULL); return 0; }
    if (m == WM_TIMER) { DestroyWindow(h); return 0; }
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(h, m, w, l);
}
/* Does a GUI-subsystem link still accept a plain main()? */
int main(int argc, char **argv) {
    WNDCLASSEXW wc; MSG msg; HWND hwnd;
    FILE *fp;
    (void)argc; (void)argv;
    memset(&wc, 0, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"MainEntryProbe";
    RegisterClassExW(&wc);
    hwnd = CreateWindowExW(0, L"MainEntryProbe", L"probe", WS_OVERLAPPEDWINDOW,
                           0,0,200,120,NULL,NULL,wc.hInstance,NULL);
    ShowWindow(hwnd, SW_SHOWNORMAL);
    while (GetMessageW(&msg, NULL, 0, 0) > 0) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    fp = fopen("main-entry-result.txt", "wb");
    if (fp) { fprintf(fp, "main() entry works under -mwindows\n"); fclose(fp); }
    return 0;
}
