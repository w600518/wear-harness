#include "dsh_log.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#ifdef _WIN32
#include <windows.h>
static CRITICAL_SECTION log_lock;
static int log_lock_ready = 0;
#define LOG_LOCK()   do { if (!log_lock_ready) { InitializeCriticalSection(&log_lock); log_lock_ready = 1; } EnterCriticalSection(&log_lock); } while (0)
#define LOG_UNLOCK() LeaveCriticalSection(&log_lock)
#else
#define LOG_LOCK()   do { } while (0)
#define LOG_UNLOCK() do { } while (0)
#endif

static dsh_log_level min_level = DSH_LOG_INFO;
static int quiet = 0;
static int use_console = 1;
static dsh_log_sink sink_fn = NULL;
static void *sink_user = NULL;

void dsh_log_set_level(dsh_log_level level) {
    min_level = level;
}

void dsh_log_set_quiet(int value) {
    quiet = value;
}

void dsh_log_set_console(int enabled) {
    use_console = enabled;
}

void dsh_log_set_sink(dsh_log_sink sink, void *userdata) {
    sink_fn = sink;
    sink_user = userdata;
}

void dsh_log(dsh_log_level level, const char *fmt, ...) {
    static const char *names[] = { "debug", "info", "warn", "error" };
    char line[2048];
    char stamp[16];
    time_t now;
    struct tm parts;
    va_list args;

    if (quiet || level < min_level) {
        return;
    }

    now = time(NULL);
#ifdef _WIN32
    {
        struct tm *tmp = localtime(&now);
        if (tmp != NULL) {
            parts = *tmp;
        } else {
            memset(&parts, 0, sizeof(parts));
        }
    }
#else
    localtime_r(&now, &parts);
#endif
    snprintf(stamp, sizeof(stamp), "%02d:%02d:%02d",
             parts.tm_hour, parts.tm_min, parts.tm_sec);

    va_start(args, fmt);
    vsnprintf(line, sizeof(line), fmt, args);
    va_end(args);

    /*
     * The sink needs the same text the console gets, so pair them here rather
     * than duplicating timestamps at every call site.
     */
    if (sink_fn != NULL) {
        char composed[2048];
        snprintf(composed, sizeof(composed), "%s [%-5s] %s",
                 stamp, names[level], line);
        sink_fn(level, composed, sink_user);
    }

    if (!use_console) {
        return;
    }

    LOG_LOCK();
    printf("%s [%-5s] ", stamp, names[level]);
    fputs(line, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    LOG_UNLOCK();
}
