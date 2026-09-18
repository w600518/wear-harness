/*
 * dsh_cfg.h - JSON configuration file that creates itself next to the binary.
 *
 * Both relay programs keep their settings in a `config.json` beside the
 * executable. On first run the file does not exist: every read supplies a
 * default, the defaults are remembered, and one save writes the complete file.
 * That means a user can start the program, then open the file to see exactly
 * the keys it understands with the values it actually used.
 *
 * Reading is deliberately forgiving: a missing key, a wrong type, or a
 * malformed file falls back to the supplied default instead of failing, because
 * a damaged preferences file should not keep a relay offline. Writes go through
 * a temporary file so an interrupted save cannot truncate a working config.
 */
#ifndef DSH_CFG_H
#define DSH_CFG_H

#include <stddef.h>

#define DSH_CFG_MAX_KEYS 32
#define DSH_CFG_KEY_LEN 64
#define DSH_CFG_VALUE_LEN 1024
#define DSH_CFG_PATH_LEN 600

typedef struct {
    char key[DSH_CFG_KEY_LEN];
    char value[DSH_CFG_VALUE_LEN];
    int  is_number;
} dsh_cfg_entry;

typedef struct {
    dsh_cfg_entry entries[DSH_CFG_MAX_KEYS];
    size_t        count;
    char          path[DSH_CFG_PATH_LEN];
    int           existed;
    int           malformed;
    int           added_default;
    int           created;
} dsh_cfg_file;

/*
 * Builds the path of `filename` in the directory holding the running
 * executable, not the current working directory: a service started from another
 * folder must still find its own config. Returns 0 on success.
 */
int dsh_cfg_path_beside_exe(char *out, size_t cap, const char *filename);

/*
 * Loads `path`. A missing file is not an error: it is created by
 * [dsh_cfg_save] once the defaults are known.
 */
int dsh_cfg_open(dsh_cfg_file *cfg, const char *path);

/*
 * Typed readers. Each one records the value in effect, so a later save writes
 * every key the program actually consulted.
 */
const char *dsh_cfg_str(dsh_cfg_file *cfg, const char *key, const char *fallback);
int         dsh_cfg_int(dsh_cfg_file *cfg, const char *key, int fallback);
int         dsh_cfg_bool(dsh_cfg_file *cfg, const char *key, int fallback);
long long   dsh_cfg_i64(dsh_cfg_file *cfg, const char *key, long long fallback);

/* Overrides a value, for command-line flags that outrank the file. */
void dsh_cfg_set_str(dsh_cfg_file *cfg, const char *key, const char *value);
void dsh_cfg_set_int(dsh_cfg_file *cfg, const char *key, int value);

/*
 * Writes the file atomically. Returns 0 on success, -1 when the directory is
 * not writable.
 */
int dsh_cfg_save(dsh_cfg_file *cfg);

/* True when the file was written rather than merely read. */
int dsh_cfg_created(const dsh_cfg_file *cfg);

void dsh_cfg_close(dsh_cfg_file *cfg);

#endif /* DSH_CFG_H */
