/*
 * dsh_config.h - flat key=value configuration shared by the sender and server.
 *
 * Deliberately tiny: the relay has a handful of deployment-varying settings and
 * the file must be readable by a human editing it on a phone-adjacent machine.
 * Unknown keys are reported rather than ignored, because a typo in a security
 * setting (a wrong port, a misspelled passphrase key) should fail loudly.
 */
#ifndef DSH_CONFIG_H
#define DSH_CONFIG_H

#include <stddef.h>

#define DSH_CONFIG_MAX 64
#define DSH_CONFIG_KEY_MAX 64
#define DSH_CONFIG_VALUE_MAX 512

typedef struct {
    char   key[DSH_CONFIG_KEY_MAX];
    char   value[DSH_CONFIG_VALUE_MAX];
} dsh_config_entry;

typedef struct {
    dsh_config_entry entries[DSH_CONFIG_MAX];
    size_t           count;
    char             source[512];
} dsh_config;

void        dsh_config_init(dsh_config *cfg);
int         dsh_config_load(dsh_config *cfg, const char *path);
void        dsh_config_set(dsh_config *cfg, const char *key, const char *value);
const char *dsh_config_get(const dsh_config *cfg, const char *key, const char *fallback);
int         dsh_config_get_int(const dsh_config *cfg, const char *key, int fallback);
int         dsh_config_get_bool(const dsh_config *cfg, const char *key, int fallback);

/*
 * Writes a commented template containing every key the program understands.
 * `keys` is a NULL-terminated array of "key|description|default" triples.
 */
int dsh_config_write_template(const char *path, const char *const *keys);

#endif /* DSH_CONFIG_H */
