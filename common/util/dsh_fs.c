/*
 * dsh_fs.c - host directory browsing for the workspace picker.
 *
 * The sender runs on the same machine as dsh, so it browses the filesystem
 * directly instead of asking dsh's picker: that picker resolves to the native
 * backend on Windows and refuses the browse verbs a remote client needs. See
 * dsh_fs.h for why.
 *
 * Paths cross this module as UTF-8 and reach the OS as UTF-16 on Windows, so a
 * directory named in any script survives the round trip.
 */
#include "dsh_fs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dsh_json.h"

#ifdef _WIN32
#include <windows.h>
#else
#include <strings.h>
#endif

/* One directory row while a level is being collected. */
typedef struct {
    char *name;
    char *path;
    int   hidden;
} dsh_fs_entry;

static void free_entries(dsh_fs_entry *entries, size_t count) {
    size_t i;
    for (i = 0; i < count; i++) {
        free(entries[i].name);
        free(entries[i].path);
    }
    free(entries);
}

static char *dup_string(const char *text) {
    size_t len;
    char  *out;
    if (text == NULL) {
        return NULL;
    }
    len = strlen(text);
    out = (char *)malloc(len + 1);
    if (out == NULL) {
        return NULL;
    }
    memcpy(out, text, len + 1);
    return out;
}

/* Case-insensitive by name, so a level reads the way a file manager lists it. */
static int compare_entries(const void *left, const void *right) {
    const dsh_fs_entry *a = (const dsh_fs_entry *)left;
    const dsh_fs_entry *b = (const dsh_fs_entry *)right;
#ifdef _WIN32
    return _stricmp(a->name, b->name);
#else
    return strcasecmp(a->name, b->name);
#endif
}

/*
 * The parent of an absolute path, or NULL when there is nowhere above it.
 *
 * Three shapes have to come out right: "C:\Users\me" answers "C:\Users" with no
 * trailing separator; "C:\Users" answers "C:\" — the root keeps its separator,
 * since "C:" names a drive-relative location rather than that root; and a root
 * itself answers NULL, because there is nothing above it. A Posix path follows
 * the same rule with "/" as the root.
 */
static char *parent_of(const char *absolute) {
    size_t len = strlen(absolute);
    size_t cut;
    char  *out;

    /* Trailing separators name nothing extra: "C:\Users\" is "C:\Users". A root
     * is the exception, and stops the strip one character early. */
    while (len > 1) {
        char last = absolute[len - 1];
        if (last != '\\' && last != '/') {
            break;
        }
        if (len == 3 && absolute[1] == ':') {
            break;
        }
        len--;
    }

    /* A root has nothing above it. */
    if (len == 0 || (len == 2 && absolute[1] == ':') ||
        (len == 3 && absolute[1] == ':' && (absolute[2] == '\\' || absolute[2] == '/'))) {
        return NULL;
    }

    /* Walk back to the separator that opens the last segment. */
    cut = len;
    while (cut > 0 && absolute[cut - 1] != '\\' && absolute[cut - 1] != '/') {
        cut--;
    }
    if (cut == 0) {
        return NULL;
    }
    /* `cut` counted that separator, so drop it — then put it back when the
     * result would be a bare drive, which is not a directory. */
    cut--;
    if (cut == 2 && absolute[1] == ':') {
        cut = 3;
    }
    if (cut == 0) {
        cut = 1;
    }

    out = (char *)malloc(cut + 1);
    if (out == NULL) {
        return NULL;
    }
    memcpy(out, absolute, cut);
    out[cut] = '\0';
    return out;
}

/*
 * Joins a child name onto a parent path.
 *
 * The separator goes in only when the parent does not already end in one: a
 * drive root is stored as `C:\`, and joining unconditionally produced
 * `C:\\Users` — a doubled separator, and a path no longer meaning what it says.
 */
static char *join_child(const char *parent, const char *name) {
    size_t a = strlen(parent);
    size_t b = strlen(name);
    int    needs = !(a > 0 && (parent[a - 1] == '\\' || parent[a - 1] == '/'));
    char  *out = (char *)malloc(a + b + (needs ? 2 : 1));

    if (out == NULL) {
        return NULL;
    }
    memcpy(out, parent, a);
    if (needs) {
        out[a] = '\\';
    }
    memcpy(out + a + (needs ? 1 : 0), name, b + 1);
    return out;
}

/* True when the name is usable as exactly one path segment. */
static int segment_ok(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return 0;
    }
    if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
        return 0;
    }
    return strchr(name, '\\') == NULL && strchr(name, '/') == NULL;
}

static void set_error(char **out_error, const char *message) {
    if (out_error != NULL) {
        *out_error = dup_string(message);
    }
}

#ifdef _WIN32

static wchar_t *to_wide(const char *text) {
    int      need;
    wchar_t *out;

    need = MultiByteToWideChar(CP_UTF8, 0, text, -1, NULL, 0);
    if (need <= 0) {
        return NULL;
    }
    out = (wchar_t *)malloc((size_t)need * sizeof(wchar_t));
    if (out == NULL) {
        return NULL;
    }
    if (MultiByteToWideChar(CP_UTF8, 0, text, -1, out, need) <= 0) {
        free(out);
        return NULL;
    }
    return out;
}

static char *to_utf8(const wchar_t *text) {
    int   need;
    char *out;

    need = WideCharToMultiByte(CP_UTF8, 0, text, -1, NULL, 0, NULL, NULL);
    if (need <= 0) {
        return NULL;
    }
    out = (char *)malloc((size_t)need);
    if (out == NULL) {
        return NULL;
    }
    if (WideCharToMultiByte(CP_UTF8, 0, text, -1, out, need, NULL, NULL) <= 0) {
        free(out);
        return NULL;
    }
    return out;
}

static char *home_directory(void) {
    const char *env = getenv("USERPROFILE");

    if (env != NULL && env[0] != '\0') {
        return dup_string(env);
    }
    env = getenv("HOMEDRIVE");
    if (env != NULL && env[0] != '\0') {
        const char *tail = getenv("HOMEPATH");
        if (tail != NULL && tail[0] != '\0') {
            size_t a = strlen(env);
            size_t b = strlen(tail);
            char  *joined = (char *)malloc(a + b + 1);
            if (joined == NULL) {
                return NULL;
            }
            memcpy(joined, env, a);
            memcpy(joined + a, tail, b + 1);
            return joined;
        }
    }
    return NULL;
}

/*
 * The drive list, as a level.
 *
 * A watch that has never browsed before starts here rather than at the home
 * directory: a workspace can live on any drive, and starting inside the home
 * one hides every other drive behind an "up" walk the user has to discover
 * first. The level has no path of its own, which is how the client tells it
 * apart and shows an input hint instead of a location.
 *
 * `kind` is the Windows drive type, so a client can tell a fixed disk from a
 * removable one without probing anything itself.
 */
static int browse_drives(const char *home, char **out_json, char **out_error) {
    DWORD  mask;
    dsh_sb sb;
    int    letter;
    int    written = 0;

    mask = GetLogicalDrives();
    if (mask == 0) {
        set_error(out_error, "cannot enumerate drives");
        return -1;
    }

    dsh_sb_init(&sb);
    dsh_sb_puts(&sb, "{\"path\":\"\",\"home\":");
    dsh_sb_put_json_string(&sb, home, strlen(home));
    dsh_sb_puts(&sb, ",\"parent\":null,\"entries\":[");
    for (letter = 0; letter < 26; letter++) {
        wchar_t root[4];
        char    label[4];
        char    entry[4];
        UINT    kind;

        if ((mask & (1u << letter)) == 0) {
            continue;
        }
        root[0] = (wchar_t)(L'A' + letter);
        root[1] = L':';
        root[2] = L'\\';
        root[3] = L'\0';
        kind = GetDriveTypeW(root);
        if (kind == DRIVE_UNKNOWN || kind == DRIVE_NO_ROOT_DIR) {
            continue;
        }

        label[0] = (char)('A' + letter);
        label[1] = ':';
        label[2] = '\0';
        entry[0] = (char)('A' + letter);
        entry[1] = ':';
        entry[2] = '\\';
        entry[3] = '\0';

        if (written > 0) {
            dsh_sb_putc(&sb, ',');
        }
        dsh_sb_puts(&sb, "{\"name\":");
        dsh_sb_put_json_string(&sb, label, strlen(label));
        dsh_sb_puts(&sb, ",\"path\":");
        dsh_sb_put_json_string(&sb, entry, strlen(entry));
        dsh_sb_printf(&sb, ",\"hidden\":false,\"kind\":%u}", (unsigned)kind);
        written++;
    }
    dsh_sb_puts(&sb, "],\"truncated\":false}");
    dsh_sb_putc(&sb, '\0');

    if (sb.oom) {
        dsh_sb_free(&sb);
        set_error(out_error, "out of memory");
        return -1;
    }
    *out_json = sb.buf;
    return 0;
}

int dsh_fs_browse(const char *path, char **out_json, char **out_error) {
    char            *home = NULL;
    char            *target = NULL;
    char            *parent = NULL;
    wchar_t         *requested = NULL;
    wchar_t         *wide_home = NULL;
    wchar_t         *absolute = NULL;
    wchar_t          pattern[32768];
    WIN32_FIND_DATAW data;
    HANDLE           find;
    dsh_fs_entry    *entries = NULL;
    size_t           count = 0;
    size_t           cap = 0;
    int              truncated = 0;
    dsh_sb           sb;
    size_t           i;

    if (out_json == NULL) {
        set_error(out_error, "no output slot");
        return -1;
    }
    *out_json = NULL;

    home = home_directory();
    if (home == NULL) {
        set_error(out_error, "cannot determine the home directory");
        return -1;
    }

    /* No path means the top of the tree, which on this host is the drive list
     * rather than the home directory: see browse_drives. */
    if (path == NULL || path[0] == '\0') {
        int rc = browse_drives(home, out_json, out_error);
        free(home);
        return rc;
    }

    absolute = (wchar_t *)malloc(32768 * sizeof(wchar_t));
    if (absolute == NULL) {
        set_error(out_error, "out of memory");
        goto done;
    }

    /*
     * An absent path means the home directory, which is where a watch that has
     * never picked anything should start. Both spellings are resolved through
     * GetFullPathName so the answer reports the real level — trailing
     * separators gone, ".." already folded — rather than the caller's spelling,
     * and so the parent derived from it is the level above the real one.
     */
    if (path != NULL && path[0] != '\0') {
        requested = to_wide(path);
        if (requested == NULL) {
            set_error(out_error, "the path is not valid UTF-8");
            goto done;
        }
    } else {
        wide_home = to_wide(home);
        if (wide_home == NULL) {
            set_error(out_error, "out of memory");
            goto done;
        }
        requested = wide_home;
    }

    if (GetFullPathNameW(requested, 32767, absolute, NULL) == 0) {
        set_error(out_error, "the path cannot be resolved");
        goto done;
    }

    target = to_utf8(absolute);
    if (target == NULL) {
        set_error(out_error, "out of memory");
        goto done;
    }

    if (swprintf(pattern, 32768, L"%ls\\*", absolute) <= 0) {
        /* The path arrived through JSON, so it holds no NUL; the only way this
         * fails is a level path longer than the pattern buffer. */
        set_error(out_error, "the path is too long");
        goto done;
    }

    find = FindFirstFileW(pattern, &data);
    if (find == INVALID_HANDLE_VALUE) {
        set_error(out_error, "cannot read this directory");
        goto done;
    }

    for (;;) {
        char         *name;
        char         *full;
        size_t        next;
        dsh_fs_entry *grown;

        if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
            name = to_utf8(data.cFileName);
            if (name != NULL && strcmp(name, ".") != 0 && strcmp(name, "..") != 0) {
                if (count >= DSH_FS_MAX_ENTRIES) {
                    free(name);
                    truncated = 1;
                    break;
                }
                full = join_child(target, name);
                if (full == NULL) {
                    free(name);
                    break;
                }

                if (count == cap) {
                    next = cap == 0 ? 32 : cap * 2;
                    grown = (dsh_fs_entry *)realloc(entries, next * sizeof(dsh_fs_entry));
                    if (grown == NULL) {
                        free(name);
                        free(full);
                        break;
                    }
                    entries = grown;
                    cap = next;
                }
                entries[count].name = name;
                entries[count].path = full;
                /* The leading-dot convention is what Posix platforms call
                 * hidden; the Windows attribute is reported as well, since a
                 * level on this host can carry both kinds. */
                entries[count].hidden =
                    (name[0] == '.' || (data.dwFileAttributes & FILE_ATTRIBUTE_HIDDEN) != 0) ? 1 : 0;
                count++;
            } else {
                free(name);
            }
        }
        if (FindNextFileW(find, &data) == 0) {
            break;
        }
    }

    FindClose(find);

    if (count > 1) {
        qsort(entries, count, sizeof(dsh_fs_entry), compare_entries);
    }

    parent = parent_of(target);

    dsh_sb_init(&sb);
    dsh_sb_puts(&sb, "{\"path\":");
    dsh_sb_put_json_string(&sb, target, strlen(target));
    dsh_sb_puts(&sb, ",\"home\":");
    dsh_sb_put_json_string(&sb, home, strlen(home));
    dsh_sb_puts(&sb, ",\"parent\":");
    if (parent != NULL) {
        dsh_sb_put_json_string(&sb, parent, strlen(parent));
    } else {
        dsh_sb_puts(&sb, "null");
    }
    dsh_sb_puts(&sb, ",\"entries\":[");
    for (i = 0; i < count; i++) {
        if (i > 0) {
            dsh_sb_putc(&sb, ',');
        }
        dsh_sb_puts(&sb, "{\"name\":");
        dsh_sb_put_json_string(&sb, entries[i].name, strlen(entries[i].name));
        dsh_sb_puts(&sb, ",\"path\":");
        dsh_sb_put_json_string(&sb, entries[i].path, strlen(entries[i].path));
        dsh_sb_printf(&sb, ",\"hidden\":%s}", entries[i].hidden ? "true" : "false");
    }
    dsh_sb_puts(&sb, "],\"truncated\":");
    dsh_sb_puts(&sb, truncated ? "true" : "false");
    dsh_sb_putc(&sb, '}');
    /* The buffer is handed over as a C string, so the terminator is part of
     * what the caller receives. */
    dsh_sb_putc(&sb, '\0');

    if (sb.oom) {
        dsh_sb_free(&sb);
        set_error(out_error, "out of memory");
        goto done;
    }
    *out_json = sb.buf;

done:
    free(home);
    free(target);
    free(parent);
    if (requested != wide_home) {
        free(requested);
    }
    free(wide_home);
    free(absolute);
    free_entries(entries, count);
    return *out_json != NULL ? 0 : -1;
}

int dsh_fs_mkdir(const char *parent, const char *name, char **out_path, char **out_error) {
    char    *target = NULL;
    wchar_t *wide = NULL;
    DWORD    code;

    if (out_path == NULL) {
        set_error(out_error, "no output slot");
        return -1;
    }
    *out_path = NULL;

    if (parent == NULL || parent[0] == '\0') {
        set_error(out_error, "no parent directory");
        return -1;
    }
    if (!segment_ok(name)) {
        set_error(out_error, "the name must be a single non-empty path segment");
        return -1;
    }

    target = join_child(parent, name);
    if (target == NULL) {
        set_error(out_error, "out of memory");
        return -1;
    }

    wide = to_wide(target);
    if (wide == NULL) {
        free(target);
        set_error(out_error, "the path is not valid UTF-8");
        return -1;
    }

    if (CreateDirectoryW(wide, NULL) == 0) {
        code = GetLastError();
        free(wide);
        free(target);
        set_error(out_error,
                  code == ERROR_ALREADY_EXISTS
                      ? "a directory with that name already exists"
                      : "the directory could not be created");
        return -1;
    }

    free(wide);
    *out_path = target;
    return 0;
}

#else /* !_WIN32 */

/*
 * The sender is a Windows program. These stubs keep a Posix build of the shared
 * library honest instead of failing to link.
 */
int dsh_fs_browse(const char *path, char **out_json, char **out_error) {
    (void)path;
    (void)out_json;
    set_error(out_error, "directory browsing is only implemented on Windows");
    return -1;
}

int dsh_fs_mkdir(const char *parent, const char *name, char **out_path, char **out_error) {
    (void)parent;
    (void)name;
    (void)out_path;
    set_error(out_error, "directory creation is only implemented on Windows");
    return -1;
}

#endif /* _WIN32 */
