#include "dsh_cfg.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include <windows.h>

#include "../json/dsh_json.h"

/* ── UTF-8 path helpers ──────────────────────────────────────────────────── */

static int to_wide(const char *utf8, wchar_t *out, size_t cap) {
    if (utf8 == NULL || cap == 0) {
        return -1;
    }
    if (MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out, (int)cap) == 0) {
        out[0] = L'\0';
        return -1;
    }
    return 0;
}

static int to_utf8(const wchar_t *wide, char *out, size_t cap) {
    if (cap == 0) {
        return -1;
    }
    if (wide == NULL ||
        WideCharToMultiByte(CP_UTF8, 0, wide, -1, out, (int)cap, NULL, NULL) == 0) {
        out[0] = '\0';
        return -1;
    }
    return 0;
}

/* The narrow fopen() would apply the ANSI code page, so a path with Chinese
 * characters in it has to go through the wide form. */
static FILE *open_utf8(const char *path, const wchar_t *mode) {
    wchar_t wide[DSH_CFG_PATH_LEN];
    if (to_wide(path, wide, DSH_CFG_PATH_LEN) != 0) {
        return NULL;
    }
    return _wfopen(wide, mode);
}

int dsh_cfg_path_beside_exe(char *out, size_t cap, const char *filename) {
    wchar_t wide[MAX_PATH];
    wchar_t wname[256];
    DWORD len;
    wchar_t *slash;

    if (out == NULL || cap == 0 || filename == NULL) {
        return -1;
    }
    out[0] = '\0';

    len = GetModuleFileNameW(NULL, wide, MAX_PATH);
    if (len == 0 || len >= MAX_PATH) {
        return -1;
    }

    /* Keep the trailing separator, then append the file name. */
    slash = wcsrchr(wide, L'\\');
    if (slash == NULL) {
        slash = wcsrchr(wide, L'/');
    }
    if (slash != NULL) {
        slash[1] = L'\0';
    } else {
        wide[0] = L'\0';
    }

    if (to_wide(filename, wname, sizeof(wname) / sizeof(wname[0])) != 0) {
        return -1;
    }
    if (wcslen(wide) + wcslen(wname) + 1 >= MAX_PATH) {
        return -1;
    }
    wcscat(wide, wname);

    return to_utf8(wide, out, cap);
}

/* ── entries ─────────────────────────────────────────────────────────────── */

static dsh_cfg_entry *find_entry(dsh_cfg_file *cfg, const char *key) {
    size_t i;
    for (i = 0; i < cfg->count; i++) {
        if (strcmp(cfg->entries[i].key, key) == 0) {
            return &cfg->entries[i];
        }
    }
    return NULL;
}

static dsh_cfg_entry *append_entry(dsh_cfg_file *cfg, const char *key,
                                   const char *value, int is_number) {
    dsh_cfg_entry *entry;

    if (cfg->count >= DSH_CFG_MAX_KEYS) {
        return NULL;
    }

    entry = &cfg->entries[cfg->count++];
    snprintf(entry->key, sizeof(entry->key), "%s", key);
    snprintf(entry->value, sizeof(entry->value), "%s", value != NULL ? value : "");
    entry->is_number = is_number;
    cfg->added_default = 1;
    return entry;
}

/* Renders a JSON value as the text form the entries store. */
static void render_value(const dsh_json *node, char *out, size_t cap, int *is_number) {
    *is_number = 0;
    out[0] = '\0';

    if (node == NULL) {
        return;
    }

    switch (node->type) {
    case DSH_JSON_STR: {
        size_t take = node->u.str.len;
        if (take >= cap) {
            take = cap - 1;
        }
        memcpy(out, node->u.str.ptr, take);
        out[take] = '\0';
        break;
    }
    case DSH_JSON_NUM:
        snprintf(out, cap, "%.17g", node->u.num);
        *is_number = 1;
        break;
    case DSH_JSON_BOOL:
        snprintf(out, cap, "%s", node->u.boolean ? "true" : "false");
        *is_number = 1; /* Written back unquoted, like a number. */
        break;
    default:
        break;
    }
}

int dsh_cfg_open(dsh_cfg_file *cfg, const char *path) {
    FILE *fp;
    long size;
    char *text;
    size_t got;
    dsh_json *root;
    size_t i;

    if (cfg == NULL || path == NULL) {
        return -1;
    }

    memset(cfg, 0, sizeof(*cfg));
    snprintf(cfg->path, sizeof(cfg->path), "%s", path);

    fp = open_utf8(path, L"rb");
    if (fp == NULL) {
        /* Absent is the normal first-run case, not a failure. */
        return 0;
    }

    cfg->existed = 1;

    fseek(fp, 0, SEEK_END);
    size = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (size <= 0) {
        fclose(fp);
        return 0;
    }

    text = (char *)malloc((size_t)size + 1);
    if (text == NULL) {
        fclose(fp);
        return -1;
    }

    got = fread(text, 1, (size_t)size, fp);
    fclose(fp);
    text[got] = '\0';

    root = dsh_json_parse(text, got);
    free(text);

    if (root == NULL || root->type != DSH_JSON_OBJ) {
        /* Keep the broken file untouched so a human can fix it; the caller
         * still runs on defaults. */
        dsh_json_free(root);
        cfg->malformed = 1;
        return 0;
    }

    for (i = 0; i < root->u.obj.count && cfg->count < DSH_CFG_MAX_KEYS; i++) {
        dsh_cfg_entry *entry = &cfg->entries[cfg->count];
        int is_number = 0;
        char rendered[DSH_CFG_VALUE_LEN];

        render_value(root->u.obj.vals[i], rendered, sizeof(rendered), &is_number);

        snprintf(entry->key, sizeof(entry->key), "%.*s",
                 (int)root->u.obj.keylens[i], root->u.obj.keys[i]);
        snprintf(entry->value, sizeof(entry->value), "%s", rendered);
        entry->is_number = is_number;
        cfg->count++;
    }

    dsh_json_free(root);
    return 0;
}

/* ── typed readers ───────────────────────────────────────────────────────── */

const char *dsh_cfg_str(dsh_cfg_file *cfg, const char *key, const char *fallback) {
    dsh_cfg_entry *entry;

    if (cfg == NULL || key == NULL) {
        return fallback != NULL ? fallback : "";
    }

    entry = find_entry(cfg, key);
    if (entry == NULL) {
        const char *value = fallback != NULL ? fallback : "";
        entry = append_entry(cfg, key, value, 0);
        if (entry == NULL) {
            return value;
        }
        return entry->value;
    }
    return entry->value;
}

static long long parse_int(const char *text, long long fallback) {
    char *end = NULL;
    long long value;

    if (text == NULL || text[0] == '\0') {
        return fallback;
    }
    if (strcmp(text, "true") == 0) {
        return 1;
    }
    if (strcmp(text, "false") == 0) {
        return 0;
    }

    value = strtoll(text, &end, 10);
    if (end == text) {
        /* A quoted number or free text: try a float before giving up. */
        double d = strtod(text, &end);
        if (end == text) {
            return fallback;
        }
        return (long long)d;
    }
    return value;
}

int dsh_cfg_int(dsh_cfg_file *cfg, const char *key, int fallback) {
    dsh_cfg_entry *entry;

    if (cfg == NULL || key == NULL) {
        return fallback;
    }

    entry = find_entry(cfg, key);
    if (entry == NULL) {
        char text[32];
        snprintf(text, sizeof(text), "%d", fallback);
        entry = append_entry(cfg, key, text, 1);
        if (entry == NULL) {
            return fallback;
        }
        return fallback;
    }

    /* Normalize whatever was in the file so the rewrite is canonical. */
    {
        long long value = parse_int(entry->value, fallback);
        snprintf(entry->value, sizeof(entry->value), "%lld", value);
        entry->is_number = 1;
        return (int)value;
    }
}

long long dsh_cfg_i64(dsh_cfg_file *cfg, const char *key, long long fallback) {
    dsh_cfg_entry *entry;

    if (cfg == NULL || key == NULL) {
        return fallback;
    }

    entry = find_entry(cfg, key);
    if (entry == NULL) {
        char text[32];
        snprintf(text, sizeof(text), "%lld", fallback);
        entry = append_entry(cfg, key, text, 1);
        if (entry == NULL) {
            return fallback;
        }
        return fallback;
    }

    {
        long long value = parse_int(entry->value, fallback);
        snprintf(entry->value, sizeof(entry->value), "%lld", value);
        entry->is_number = 1;
        return value;
    }
}

int dsh_cfg_bool(dsh_cfg_file *cfg, const char *key, int fallback) {
    dsh_cfg_entry *entry;

    if (cfg == NULL || key == NULL) {
        return fallback;
    }

    entry = find_entry(cfg, key);
    if (entry == NULL) {
        entry = append_entry(cfg, key, fallback ? "true" : "false", 1);
        return entry != NULL ? fallback : fallback;
    }

    {
        int value = (int)parse_int(entry->value, fallback ? 1 : 0);
        value = value != 0;
        snprintf(entry->value, sizeof(entry->value), "%s", value ? "true" : "false");
        entry->is_number = 1;
        return value;
    }
}

void dsh_cfg_set_str(dsh_cfg_file *cfg, const char *key, const char *value) {
    dsh_cfg_entry *entry;

    if (cfg == NULL || key == NULL) {
        return;
    }

    entry = find_entry(cfg, key);
    if (entry == NULL) {
        entry = append_entry(cfg, key, value != NULL ? value : "", 0);
    } else {
        snprintf(entry->value, sizeof(entry->value), "%s", value != NULL ? value : "");
        entry->is_number = 0;
    }
}

void dsh_cfg_set_int(dsh_cfg_file *cfg, const char *key, int value) {
    dsh_cfg_entry *entry;

    if (cfg == NULL || key == NULL) {
        return;
    }

    entry = find_entry(cfg, key);
    if (entry == NULL) {
        char text[32];
        snprintf(text, sizeof(text), "%d", value);
        append_entry(cfg, key, text, 1);
        return;
    }

    snprintf(entry->value, sizeof(entry->value), "%d", value);
    entry->is_number = 1;
}

/* ── save ────────────────────────────────────────────────────────────────── */

int dsh_cfg_created(const dsh_cfg_file *cfg) {
    return cfg != NULL && cfg->created;
}

int dsh_cfg_save(dsh_cfg_file *cfg) {
    dsh_sb json;
    wchar_t wide_temp[DSH_CFG_PATH_LEN];
    wchar_t wide_path[DSH_CFG_PATH_LEN];
    char temp_path[DSH_CFG_PATH_LEN];
    FILE *fp;
    size_t i;
    int rc = 0;

    if (cfg == NULL || cfg->path[0] == '\0') {
        return -1;
    }

    /*
     * Carry over keys this program never asked about. The server and the sender
     * have different settings and may well sit in one folder; without this, each
     * would erase the other's entries every time it saved.
     */
    {
        dsh_cfg_file on_disk;
        if (dsh_cfg_open(&on_disk, cfg->path) == 0 && !on_disk.malformed) {
            for (i = 0; i < on_disk.count; i++) {
                if (find_entry(cfg, on_disk.entries[i].key) == NULL) {
                    append_entry(cfg, on_disk.entries[i].key,
                                 on_disk.entries[i].value,
                                 on_disk.entries[i].is_number);
                }
            }
        }
        dsh_cfg_close(&on_disk);
    }

    dsh_sb_init(&json);
    dsh_sb_puts(&json, "{\n");
    for (i = 0; i < cfg->count; i++) {
        const dsh_cfg_entry *entry = &cfg->entries[i];
        dsh_sb_puts(&json, "  ");
        dsh_sb_put_json_string(&json, entry->key, strlen(entry->key));
        dsh_sb_puts(&json, ": ");
        if (entry->is_number && entry->value[0] != '\0') {
            dsh_sb_put_json_raw(&json, entry->value, strlen(entry->value));
        } else {
            dsh_sb_put_json_string(&json, entry->value, strlen(entry->value));
        }
        dsh_sb_puts(&json, i + 1 < cfg->count ? ",\n" : "\n");
    }
    dsh_sb_puts(&json, "}\n");

    if (json.oom) {
        dsh_sb_free(&json);
        return -1;
    }

    /*
     * Write beside the target and swap it in, so a crash or a full disk cannot
     * leave a half-written config where a working one used to be.
     */
    snprintf(temp_path, sizeof(temp_path), "%s.tmp", cfg->path);
    if (to_wide(temp_path, wide_temp, DSH_CFG_PATH_LEN) != 0 ||
        to_wide(cfg->path, wide_path, DSH_CFG_PATH_LEN) != 0) {
        dsh_sb_free(&json);
        return -1;
    }

    fp = _wfopen(wide_temp, L"wb");
    if (fp == NULL) {
        dsh_sb_free(&json);
        return -1;
    }

    if (fwrite(json.buf, 1, json.len, fp) != json.len) {
        rc = -1;
    }
    if (fclose(fp) != 0) {
        rc = -1;
    }
    dsh_sb_free(&json);

    if (rc != 0) {
        _wremove(wide_temp);
        return -1;
    }

    /*
     * A file we could not parse is set aside before being replaced, so a user
     * who hand-edited it badly can recover what they wrote.
     */
    if (cfg->malformed && cfg->existed) {
        wchar_t wide_backup[DSH_CFG_PATH_LEN];
        char backup[DSH_CFG_PATH_LEN];
        snprintf(backup, sizeof(backup), "%s.bak", cfg->path);
        if (to_wide(backup, wide_backup, DSH_CFG_PATH_LEN) == 0) {
            MoveFileExW(wide_path, wide_backup, MOVEFILE_REPLACE_EXISTING);
        }
    }

    if (!MoveFileExW(wide_temp, wide_path,
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        _wremove(wide_temp);
        return -1;
    }

    cfg->created = !cfg->existed;
    cfg->existed = 1;
    cfg->added_default = 0;
    return 0;
}

void dsh_cfg_close(dsh_cfg_file *cfg) {
    if (cfg != NULL) {
        memset(cfg, 0, sizeof(*cfg));
    }
}
