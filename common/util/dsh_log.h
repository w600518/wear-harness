/*
 * dsh_log.h - timestamped console logging shared by the sender and the server.
 *
 * Both programs are console apps a person watches while relaying a session, so
 * output stays on one line per event and never blocks on a slow console.
 */
#ifndef DSH_LOG_H
#define DSH_LOG_H

typedef enum {
    DSH_LOG_DEBUG = 0,
    DSH_LOG_INFO,
    DSH_LOG_WARN,
    DSH_LOG_ERROR
} dsh_log_level;

/* Sets the minimum level printed. Default is DSH_LOG_INFO. */
void dsh_log_set_level(dsh_log_level level);
void dsh_log_set_quiet(int quiet);

/*
 * Enables or disables console output. A GUI-subsystem build has no console, so
 * the interface turns it off rather than paying for writes that go nowhere.
 */
void dsh_log_set_console(int enabled);

/*
 * Receives every line at or above the active level, already formatted and
 * without a trailing newline. Called on whichever thread logged, so a sink
 * must be thread safe.
 */
typedef void (*dsh_log_sink)(dsh_log_level level, const char *line, void *userdata);

void dsh_log_set_sink(dsh_log_sink sink, void *userdata);

void dsh_log(dsh_log_level level, const char *fmt, ...);

#define DSH_DEBUG(...) dsh_log(DSH_LOG_DEBUG, __VA_ARGS__)
#define DSH_INFO(...)  dsh_log(DSH_LOG_INFO, __VA_ARGS__)
#define DSH_WARN(...)  dsh_log(DSH_LOG_WARN, __VA_ARGS__)
#define DSH_ERROR(...) dsh_log(DSH_LOG_ERROR, __VA_ARGS__)

#endif /* DSH_LOG_H */
