#include "dsh_json.h"

#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ── string builder ──────────────────────────────────────────────────────── */

void dsh_sb_init(dsh_sb *sb) {
    sb->buf = NULL;
    sb->len = 0;
    sb->cap = 0;
    sb->oom = 0;
}

void dsh_sb_free(dsh_sb *sb) {
    free(sb->buf);
    sb->buf = NULL;
    sb->len = 0;
    sb->cap = 0;
    sb->oom = 0;
}

void dsh_sb_reset(dsh_sb *sb) {
    sb->len = 0;
    if (sb->buf != NULL) {
        sb->buf[0] = '\0';
    }
}

void dsh_sb_reserve(dsh_sb *sb, size_t extra) {
    size_t need;
    size_t cap;
    char *grown;

    if (sb->oom) {
        return;
    }

    need = sb->len + extra + 1;
    if (need <= sb->cap) {
        return;
    }

    cap = (sb->cap == 0) ? 256 : sb->cap;
    while (cap < need) {
        cap *= 2;
    }

    grown = (char *)realloc(sb->buf, cap);
    if (grown == NULL) {
        sb->oom = 1;
        return;
    }

    sb->buf = grown;
    sb->cap = cap;
}

void dsh_sb_putc(dsh_sb *sb, char c) {
    dsh_sb_reserve(sb, 1);
    if (sb->oom) {
        return;
    }
    sb->buf[sb->len++] = c;
    sb->buf[sb->len] = '\0';
}

void dsh_sb_put(dsh_sb *sb, const void *data, size_t len) {
    if (len == 0) {
        return;
    }
    dsh_sb_reserve(sb, len);
    if (sb->oom) {
        return;
    }
    memcpy(sb->buf + sb->len, data, len);
    sb->len += len;
    sb->buf[sb->len] = '\0';
}

void dsh_sb_puts(dsh_sb *sb, const char *text) {
    if (text == NULL) {
        return;
    }
    dsh_sb_put(sb, text, strlen(text));
}

void dsh_sb_printf(dsh_sb *sb, const char *fmt, ...) {
    char stack_buf[512];
    va_list args;
    int written;

    va_start(args, fmt);
    written = vsnprintf(stack_buf, sizeof(stack_buf), fmt, args);
    va_end(args);

    if (written < 0) {
        return;
    }

    if ((size_t)written < sizeof(stack_buf)) {
        dsh_sb_put(sb, stack_buf, (size_t)written);
        return;
    }

    {
        char *heap = (char *)malloc((size_t)written + 1);
        if (heap == NULL) {
            sb->oom = 1;
            return;
        }
        va_start(args, fmt);
        vsnprintf(heap, (size_t)written + 1, fmt, args);
        va_end(args);
        dsh_sb_put(sb, heap, (size_t)written);
        free(heap);
    }
}

void dsh_sb_put_i64(dsh_sb *sb, long long value) {
    dsh_sb_printf(sb, "%lld", value);
}

void dsh_sb_put_double(dsh_sb *sb, double value) {
    char text[40];
    int written;

    if (!isfinite(value)) {
        dsh_sb_puts(sb, "0");
        return;
    }

    written = snprintf(text, sizeof(text), "%.17g", value);
    if (written <= 0) {
        dsh_sb_puts(sb, "0");
        return;
    }
    dsh_sb_put(sb, text, (size_t)written);
}

static void put_hex4(dsh_sb *sb, unsigned value) {
    static const char hex[] = "0123456789abcdef";
    char out[6];
    out[0] = '\\';
    out[1] = 'u';
    out[2] = hex[(value >> 12) & 0xf];
    out[3] = hex[(value >> 8) & 0xf];
    out[4] = hex[(value >> 4) & 0xf];
    out[5] = hex[value & 0xf];
    dsh_sb_put(sb, out, 6);
}

void dsh_sb_put_json_string(dsh_sb *sb, const char *text, size_t len) {
    size_t i;

    dsh_sb_putc(sb, '"');
    for (i = 0; i < len; i++) {
        unsigned char c = (unsigned char)text[i];
        switch (c) {
        case '"':  dsh_sb_puts(sb, "\\\""); break;
        case '\\': dsh_sb_puts(sb, "\\\\"); break;
        case '\b': dsh_sb_puts(sb, "\\b"); break;
        case '\f': dsh_sb_puts(sb, "\\f"); break;
        case '\n': dsh_sb_puts(sb, "\\n"); break;
        case '\r': dsh_sb_puts(sb, "\\r"); break;
        case '\t': dsh_sb_puts(sb, "\\t"); break;
        default:
            if (c < 0x20) {
                put_hex4(sb, c);
            } else {
                dsh_sb_putc(sb, (char)c);
            }
            break;
        }
    }
    dsh_sb_putc(sb, '"');
}

void dsh_sb_put_json_raw(dsh_sb *sb, const char *text, size_t len) {
    dsh_sb_put(sb, text, len);
}

/* ── parser ──────────────────────────────────────────────────────────────── */

typedef struct {
    const char *p;
    const char *end;
    int         depth;
} parser;

#define DSH_JSON_MAX_DEPTH 64

static dsh_json *parse_value(parser *ps);

static dsh_json *node_new(dsh_json_type type) {
    dsh_json *node = (dsh_json *)calloc(1, sizeof(dsh_json));
    if (node != NULL) {
        node->type = type;
    }
    return node;
}

static void skip_ws(parser *ps) {
    while (ps->p < ps->end) {
        char c = *ps->p;
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            ps->p++;
        } else {
            break;
        }
    }
}

static int hex_val(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int append_utf8(dsh_sb *sb, unsigned codepoint) {
    if (codepoint < 0x80) {
        dsh_sb_putc(sb, (char)codepoint);
    } else if (codepoint < 0x800) {
        dsh_sb_putc(sb, (char)(0xc0 | (codepoint >> 6)));
        dsh_sb_putc(sb, (char)(0x80 | (codepoint & 0x3f)));
    } else if (codepoint < 0x10000) {
        dsh_sb_putc(sb, (char)(0xe0 | (codepoint >> 12)));
        dsh_sb_putc(sb, (char)(0x80 | ((codepoint >> 6) & 0x3f)));
        dsh_sb_putc(sb, (char)(0x80 | (codepoint & 0x3f)));
    } else {
        dsh_sb_putc(sb, (char)(0xf0 | (codepoint >> 18)));
        dsh_sb_putc(sb, (char)(0x80 | ((codepoint >> 12) & 0x3f)));
        dsh_sb_putc(sb, (char)(0x80 | ((codepoint >> 6) & 0x3f)));
        dsh_sb_putc(sb, (char)(0x80 | (codepoint & 0x3f)));
    }
    return sb->oom ? -1 : 0;
}

/* Reads a quoted string; on success stores a NUL-terminated copy in *out. */
static int parse_string_raw(parser *ps, char **out, size_t *outlen) {
    dsh_sb sb;

    if (ps->p >= ps->end || *ps->p != '"') {
        return -1;
    }
    ps->p++;

    dsh_sb_init(&sb);

    while (ps->p < ps->end) {
        unsigned char c = (unsigned char)*ps->p;

        if (c == '"') {
            ps->p++;
            dsh_sb_putc(&sb, '\0');
            if (sb.oom) {
                dsh_sb_free(&sb);
                return -1;
            }
            *outlen = sb.len - 1;
            *out = sb.buf;
            return 0;
        }

        if (c == '\\') {
            ps->p++;
            if (ps->p >= ps->end) {
                break;
            }
            switch (*ps->p) {
            case '"':  dsh_sb_putc(&sb, '"');  ps->p++; break;
            case '\\': dsh_sb_putc(&sb, '\\'); ps->p++; break;
            case '/':  dsh_sb_putc(&sb, '/');  ps->p++; break;
            case 'b':  dsh_sb_putc(&sb, '\b'); ps->p++; break;
            case 'f':  dsh_sb_putc(&sb, '\f'); ps->p++; break;
            case 'n':  dsh_sb_putc(&sb, '\n'); ps->p++; break;
            case 'r':  dsh_sb_putc(&sb, '\r'); ps->p++; break;
            case 't':  dsh_sb_putc(&sb, '\t'); ps->p++; break;
            case 'u': {
                unsigned cp = 0;
                int i;
                ps->p++;
                for (i = 0; i < 4; i++) {
                    int v;
                    if (ps->p >= ps->end) {
                        dsh_sb_free(&sb);
                        return -1;
                    }
                    v = hex_val(*ps->p);
                    if (v < 0) {
                        dsh_sb_free(&sb);
                        return -1;
                    }
                    cp = (cp << 4) | (unsigned)v;
                    ps->p++;
                }
                /* Recombine a surrogate pair when the low half follows. */
                if (cp >= 0xd800 && cp <= 0xdbff &&
                    (size_t)(ps->end - ps->p) >= 6 &&
                    ps->p[0] == '\\' && ps->p[1] == 'u') {
                    unsigned lo = 0;
                    int ok = 1;
                    for (i = 0; i < 4; i++) {
                        int v = hex_val(ps->p[2 + i]);
                        if (v < 0) {
                            ok = 0;
                            break;
                        }
                        lo = (lo << 4) | (unsigned)v;
                    }
                    if (ok && lo >= 0xdc00 && lo <= 0xdfff) {
                        cp = 0x10000u + ((cp - 0xd800u) << 10) + (lo - 0xdc00u);
                        ps->p += 6;
                    }
                }
                if (append_utf8(&sb, cp) != 0) {
                    dsh_sb_free(&sb);
                    return -1;
                }
                break;
            }
            default:
                dsh_sb_free(&sb);
                return -1;
            }
            continue;
        }

        dsh_sb_putc(&sb, (char)c);
        ps->p++;
    }

    dsh_sb_free(&sb);
    return -1;
}

static dsh_json *parse_object(parser *ps) {
    dsh_json *node = node_new(DSH_JSON_OBJ);
    size_t cap = 0;

    if (node == NULL) {
        return NULL;
    }
    ps->p++; /* '{' */

    skip_ws(ps);
    if (ps->p < ps->end && *ps->p == '}') {
        ps->p++;
        return node;
    }

    for (;;) {
        char *key = NULL;
        size_t keylen = 0;
        dsh_json *value;

        skip_ws(ps);
        if (parse_string_raw(ps, &key, &keylen) != 0) {
            dsh_json_free(node);
            return NULL;
        }

        skip_ws(ps);
        if (ps->p >= ps->end || *ps->p != ':') {
            free(key);
            dsh_json_free(node);
            return NULL;
        }
        ps->p++;

        value = parse_value(ps);
        if (value == NULL) {
            free(key);
            dsh_json_free(node);
            return NULL;
        }

        if (node->u.obj.count == cap) {
            size_t next = (cap == 0) ? 8 : cap * 2;
            char **keys = (char **)realloc(node->u.obj.keys, next * sizeof(char *));
            size_t *lens = (size_t *)realloc(node->u.obj.keylens, next * sizeof(size_t));
            dsh_json **vals = (dsh_json **)realloc(node->u.obj.vals, next * sizeof(dsh_json *));

            if (keys == NULL || lens == NULL || vals == NULL) {
                free(keys);
                free(lens);
                free(vals);
                free(key);
                dsh_json_free(value);
                dsh_json_free(node);
                return NULL;
            }

            node->u.obj.keys = keys;
            node->u.obj.keylens = lens;
            node->u.obj.vals = vals;
            cap = next;
        }

        node->u.obj.keys[node->u.obj.count] = key;
        node->u.obj.keylens[node->u.obj.count] = keylen;
        node->u.obj.vals[node->u.obj.count] = value;
        node->u.obj.count++;

        skip_ws(ps);
        if (ps->p < ps->end && *ps->p == ',') {
            ps->p++;
            continue;
        }
        if (ps->p < ps->end && *ps->p == '}') {
            ps->p++;
            return node;
        }
        dsh_json_free(node);
        return NULL;
    }
}

static dsh_json *parse_array(parser *ps) {
    dsh_json *node = node_new(DSH_JSON_ARR);
    size_t cap = 0;

    if (node == NULL) {
        return NULL;
    }
    ps->p++; /* '[' */

    skip_ws(ps);
    if (ps->p < ps->end && *ps->p == ']') {
        ps->p++;
        return node;
    }

    for (;;) {
        dsh_json *value = parse_value(ps);
        if (value == NULL) {
            dsh_json_free(node);
            return NULL;
        }

        if (node->u.arr.count == cap) {
            size_t next = (cap == 0) ? 8 : cap * 2;
            dsh_json **items = (dsh_json **)realloc(node->u.arr.items, next * sizeof(dsh_json *));
            if (items == NULL) {
                dsh_json_free(value);
                dsh_json_free(node);
                return NULL;
            }
            node->u.arr.items = items;
            cap = next;
        }

        node->u.arr.items[node->u.arr.count++] = value;

        skip_ws(ps);
        if (ps->p < ps->end && *ps->p == ',') {
            ps->p++;
            continue;
        }
        if (ps->p < ps->end && *ps->p == ']') {
            ps->p++;
            return node;
        }
        dsh_json_free(node);
        return NULL;
    }
}

static dsh_json *parse_literal(parser *ps, const char *text, dsh_json_type type) {
    size_t len = strlen(text);
    dsh_json *node;

    if ((size_t)(ps->end - ps->p) < len || memcmp(ps->p, text, len) != 0) {
        return NULL;
    }

    node = node_new(type);
    if (node != NULL) {
        ps->p += len;
    }
    return node;
}

static dsh_json *parse_number(parser *ps) {
    const char *start = ps->p;
    char *copy;
    char *endptr = NULL;
    size_t len;
    dsh_json *node;
    double value;

    if (ps->p < ps->end && (*ps->p == '-' || *ps->p == '+')) {
        ps->p++;
    }
    while (ps->p < ps->end && *ps->p >= '0' && *ps->p <= '9') {
        ps->p++;
    }
    if (ps->p < ps->end && *ps->p == '.') {
        ps->p++;
        while (ps->p < ps->end && *ps->p >= '0' && *ps->p <= '9') {
            ps->p++;
        }
    }
    if (ps->p < ps->end && (*ps->p == 'e' || *ps->p == 'E')) {
        ps->p++;
        if (ps->p < ps->end && (*ps->p == '-' || *ps->p == '+')) {
            ps->p++;
        }
        while (ps->p < ps->end && *ps->p >= '0' && *ps->p <= '9') {
            ps->p++;
        }
    }

    len = (size_t)(ps->p - start);
    if (len == 0) {
        return NULL;
    }

    copy = (char *)malloc(len + 1);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, start, len);
    copy[len] = '\0';

    value = strtod(copy, &endptr);
    if (endptr == copy) {
        free(copy);
        return NULL;
    }
    free(copy);

    node = node_new(DSH_JSON_NUM);
    if (node != NULL) {
        node->u.num = value;
    }
    return node;
}

static dsh_json *parse_value(parser *ps) {
    dsh_json *node;

    if (ps->depth >= DSH_JSON_MAX_DEPTH) {
        return NULL;
    }
    ps->depth++;

    skip_ws(ps);
    if (ps->p >= ps->end) {
        ps->depth--;
        return NULL;
    }

    switch (*ps->p) {
    case '{':
        node = parse_object(ps);
        break;
    case '[':
        node = parse_array(ps);
        break;
    case '"': {
        char *text = NULL;
        size_t len = 0;
        node = node_new(DSH_JSON_STR);
        if (node != NULL) {
            if (parse_string_raw(ps, &text, &len) != 0) {
                free(node);
                ps->depth--;
                return NULL;
            }
            node->u.str.ptr = text;
            node->u.str.len = len;
        }
        break;
    }
    case 't':
        node = parse_literal(ps, "true", DSH_JSON_BOOL);
        if (node != NULL) {
            node->u.boolean = 1;
        }
        break;
    case 'f':
        node = parse_literal(ps, "false", DSH_JSON_BOOL);
        if (node != NULL) {
            node->u.boolean = 0;
        }
        break;
    case 'n':
        node = parse_literal(ps, "null", DSH_JSON_NULL);
        break;
    default:
        node = parse_number(ps);
        break;
    }

    ps->depth--;
    return node;
}

dsh_json *dsh_json_parse(const char *text, size_t len) {
    parser ps;
    dsh_json *node;

    if (text == NULL) {
        return NULL;
    }

    ps.p = text;
    ps.end = text + len;
    ps.depth = 0;

    node = parse_value(&ps);
    if (node == NULL) {
        return NULL;
    }

    skip_ws(&ps);
    if (ps.p != ps.end) {
        dsh_json_free(node);
        return NULL;
    }
    return node;
}

void dsh_json_free(dsh_json *node) {
    size_t i;

    if (node == NULL) {
        return;
    }

    switch (node->type) {
    case DSH_JSON_STR:
        free(node->u.str.ptr);
        break;
    case DSH_JSON_ARR:
        for (i = 0; i < node->u.arr.count; i++) {
            dsh_json_free(node->u.arr.items[i]);
        }
        free(node->u.arr.items);
        break;
    case DSH_JSON_OBJ:
        for (i = 0; i < node->u.obj.count; i++) {
            free(node->u.obj.keys[i]);
            dsh_json_free(node->u.obj.vals[i]);
        }
        free(node->u.obj.keys);
        free(node->u.obj.keylens);
        free(node->u.obj.vals);
        break;
    default:
        break;
    }

    free(node);
}

const dsh_json *dsh_json_get(const dsh_json *node, const char *key) {
    size_t i;
    size_t keylen;

    if (node == NULL || node->type != DSH_JSON_OBJ || key == NULL) {
        return NULL;
    }

    keylen = strlen(key);
    for (i = 0; i < node->u.obj.count; i++) {
        if (node->u.obj.keylens[i] == keylen &&
            memcmp(node->u.obj.keys[i], key, keylen) == 0) {
            return node->u.obj.vals[i];
        }
    }
    return NULL;
}

const char *dsh_json_string(const dsh_json *node, const char *fallback, size_t *len) {
    if (node == NULL || node->type != DSH_JSON_STR) {
        if (len != NULL && fallback != NULL) {
            *len = strlen(fallback);
        }
        return fallback;
    }
    if (len != NULL) {
        *len = node->u.str.len;
    }
    return node->u.str.ptr;
}

double dsh_json_number(const dsh_json *node, double fallback) {
    if (node == NULL) {
        return fallback;
    }
    if (node->type == DSH_JSON_NUM) {
        return node->u.num;
    }
    if (node->type == DSH_JSON_BOOL) {
        return node->u.boolean ? 1.0 : 0.0;
    }
    return fallback;
}

long long dsh_json_integer(const dsh_json *node, long long fallback) {
    double value = dsh_json_number(node, (double)fallback);
    return (long long)value;
}

int dsh_json_bool(const dsh_json *node, int fallback) {
    if (node == NULL) {
        return fallback;
    }
    if (node->type == DSH_JSON_BOOL) {
        return node->u.boolean;
    }
    if (node->type == DSH_JSON_NUM) {
        return node->u.num != 0.0;
    }
    return fallback;
}

void dsh_json_write(const dsh_json *node, dsh_sb *out) {
    size_t i;

    if (node == NULL) {
        dsh_sb_puts(out, "null");
        return;
    }

    switch (node->type) {
    case DSH_JSON_NULL:
        dsh_sb_puts(out, "null");
        break;
    case DSH_JSON_BOOL:
        dsh_sb_puts(out, node->u.boolean ? "true" : "false");
        break;
    case DSH_JSON_NUM:
        dsh_sb_put_double(out, node->u.num);
        break;
    case DSH_JSON_STR:
        dsh_sb_put_json_string(out, node->u.str.ptr, node->u.str.len);
        break;
    case DSH_JSON_ARR:
        dsh_sb_putc(out, '[');
        for (i = 0; i < node->u.arr.count; i++) {
            if (i > 0) {
                dsh_sb_putc(out, ',');
            }
            dsh_json_write(node->u.arr.items[i], out);
        }
        dsh_sb_putc(out, ']');
        break;
    case DSH_JSON_OBJ:
        dsh_sb_putc(out, '{');
        for (i = 0; i < node->u.obj.count; i++) {
            if (i > 0) {
                dsh_sb_putc(out, ',');
            }
            dsh_sb_put_json_string(out, node->u.obj.keys[i], node->u.obj.keylens[i]);
            dsh_sb_putc(out, ':');
            dsh_json_write(node->u.obj.vals[i], out);
        }
        dsh_sb_putc(out, '}');
        break;
    }
}
