/*
 * dsh_json.h - minimal JSON DOM parser plus a string builder.
 *
 * The relay never needs schema validation; it needs to read a few routing
 * fields out of an opaque payload and re-serialize. This parser covers RFC 8259
 * JSON with UTF-8 payloads passed through byte-for-byte, and rejects trailing
 * garbage so a truncated frame cannot silently parse.
 */
#ifndef DSH_JSON_H
#define DSH_JSON_H

#include <stddef.h>

typedef enum {
    DSH_JSON_NULL = 0,
    DSH_JSON_BOOL,
    DSH_JSON_NUM,
    DSH_JSON_STR,
    DSH_JSON_ARR,
    DSH_JSON_OBJ
} dsh_json_type;

typedef struct dsh_json dsh_json;

struct dsh_json {
    dsh_json_type type;
    union {
        int boolean;
        double num;
        struct {
            char  *ptr;
            size_t len;
        } str;
        struct {
            dsh_json **items;
            size_t     count;
        } arr;
        struct {
            char     **keys;
            size_t    *keylens;
            dsh_json **vals;
            size_t     count;
        } obj;
    } u;
};

/* Returns NULL on malformed input or if `len` is not fully consumed. */
dsh_json *dsh_json_parse(const char *text, size_t len);
void dsh_json_free(dsh_json *node);

/* Object accessor. Returns NULL when absent or when `node` is not an object. */
const dsh_json *dsh_json_get(const dsh_json *node, const char *key);

/* Typed accessors with caller-supplied fallbacks for absent or mistyped values. */
const char *dsh_json_string(const dsh_json *node, const char *fallback, size_t *len);
double      dsh_json_number(const dsh_json *node, double fallback);
long long   dsh_json_integer(const dsh_json *node, long long fallback);
int         dsh_json_bool(const dsh_json *node, int fallback);

/* Growable byte buffer used for both JSON construction and frame assembly. */
typedef struct dsh_sb {
    char  *buf;
    size_t len;
    size_t cap;
    int    oom;
} dsh_sb;

/* Serializes a parsed node back to text through a builder. */
void dsh_json_write(const dsh_json *node, dsh_sb *out);

void dsh_sb_init(dsh_sb *sb);
void dsh_sb_free(dsh_sb *sb);
void dsh_sb_reset(dsh_sb *sb);
void dsh_sb_reserve(dsh_sb *sb, size_t extra);
void dsh_sb_putc(dsh_sb *sb, char c);
void dsh_sb_put(dsh_sb *sb, const void *data, size_t len);
void dsh_sb_puts(dsh_sb *sb, const char *text);
void dsh_sb_printf(dsh_sb *sb, const char *fmt, ...);
void dsh_sb_put_i64(dsh_sb *sb, long long value);
void dsh_sb_put_double(dsh_sb *sb, double value);

/* Appends a JSON string literal, escaping and quoting it. */
void dsh_sb_put_json_string(dsh_sb *sb, const char *text, size_t len);
/* Appends the raw bytes of a JSON value already known to be well formed. */
void dsh_sb_put_json_raw(dsh_sb *sb, const char *text, size_t len);

#endif /* DSH_JSON_H */
