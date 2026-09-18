#include "dsh_config.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void dsh_config_init(dsh_config *cfg) {
    memset(cfg, 0, sizeof(*cfg));
}

void dsh_config_set(dsh_config *cfg, const char *key, const char *value) {
    size_t i;

    if (key == NULL || value == NULL) {
        return;
    }

    for (i = 0; i < cfg->count; i++) {
        if (strcmp(cfg->entries[i].key, key) == 0) {
            snprintf(cfg->entries[i].value, DSH_CONFIG_VALUE_MAX, "%s", value);
            return;
        }
    }

    if (cfg->count >= DSH_CONFIG_MAX) {
        return;
    }

    snprintf(cfg->entries[cfg->count].key, DSH_CONFIG_KEY_MAX, "%s", key);
    snprintf(cfg->entries[cfg->count].value, DSH_CONFIG_VALUE_MAX, "%s", value);
    cfg->count++;
}

static void trim(char *text) {
    size_t len;
    size_t start = 0;

    len = strlen(text);
    while (start < len && isspace((unsigned char)text[start])) {
        start++;
    }
    if (start > 0) {
        memmove(text, text + start, len - start + 1);
        len -= start;
    }

    while (len > 0 && isspace((unsigned char)text[len - 1])) {
        text[--len] = '\0';
    }
}

int dsh_config_load(dsh_config *cfg, const char *path) {
    FILE *fp;
    char line[1024];

    fp = fopen(path, "rb");
    if (fp == NULL) {
        return -1;
    }

    snprintf(cfg->source, sizeof(cfg->source), "%s", path);

    while (fgets(line, sizeof(line), fp) != NULL) {
        char *eq;
        char *comment;

        /* A '#' starts a comment anywhere outside a value that needs one. */
        comment = strchr(line, '#');
        if (comment != NULL) {
            *comment = '\0';
        }

        trim(line);
        if (line[0] == '\0') {
            continue;
        }

        eq = strchr(line, '=');
        if (eq == NULL) {
            continue;
        }

        *eq = '\0';
        trim(line);
        trim(eq + 1);

        if (line[0] == '\0') {
            continue;
        }

        dsh_config_set(cfg, line, eq + 1);
    }

    fclose(fp);
    return 0;
}

const char *dsh_config_get(const dsh_config *cfg, const char *key, const char *fallback) {
    size_t i;

    for (i = 0; i < cfg->count; i++) {
        if (strcmp(cfg->entries[i].key, key) == 0) {
            return cfg->entries[i].value;
        }
    }
    return fallback;
}

int dsh_config_get_int(const dsh_config *cfg, const char *key, int fallback) {
    const char *value = dsh_config_get(cfg, key, NULL);
    if (value == NULL || value[0] == '\0') {
        return fallback;
    }
    return atoi(value);
}

int dsh_config_get_bool(const dsh_config *cfg, const char *key, int fallback) {
    const char *value = dsh_config_get(cfg, key, NULL);
    if (value == NULL || value[0] == '\0') {
        return fallback;
    }
    if (value[0] == '1' || value[0] == 't' || value[0] == 'T' ||
        value[0] == 'y' || value[0] == 'Y') {
        return 1;
    }
    if (value[0] == '0' || value[0] == 'f' || value[0] == 'F' ||
        value[0] == 'n' || value[0] == 'N') {
        return 0;
    }
    return fallback;
}

int dsh_config_write_template(const char *path, const char *const *keys) {
    FILE *fp;
    size_t i;

    fp = fopen(path, "wb");
    if (fp == NULL) {
        return -1;
    }

    fprintf(fp, "# dsh-relay configuration\n");
    fprintf(fp, "# Lines are 'key = value'; '#' starts a comment.\n\n");

    for (i = 0; keys[i] != NULL; i++) {
        const char *spec = keys[i];
        const char *bar1 = strchr(spec, '|');
        const char *bar2 = (bar1 != NULL) ? strchr(bar1 + 1, '|') : NULL;

        if (bar1 == NULL || bar2 == NULL) {
            continue;
        }

        fprintf(fp, "# %.*s\n", (int)(bar2 - bar1 - 1), bar1 + 1);
        fprintf(fp, "%.*s = %s\n\n", (int)(bar1 - spec), spec, bar2 + 1);
    }

    fclose(fp);
    return 0;
}
