/*
 * dsh_fs.h - host directory browsing for the workspace picker.
 *
 * The watch registers a directory as a workspace by walking the host's tree,
 * and dsh's own directory picker cannot drive that walk. Its
 * `directory-picker-auto` backend resolves to `native` on Windows whenever the
 * web server is bound to loopback, and the native backend drives an OS dialog
 * on the host display instead of answering the browse verbs a remote client
 * needs — `directoryPicker/list` comes back as `directory-picker/unavailable`.
 * The sender already runs on that same host and owns a filesystem view, so it
 * browses the tree itself.
 */
#ifndef DSH_FS_H
#define DSH_FS_H

/*
 * Upper bound on the directories one level reports. A level holding more is
 * cut, and the answer says so rather than pretending the level was that small.
 */
#define DSH_FS_MAX_ENTRIES 500

/*
 * One directory level, as a JSON object:
 *
 *   {"path":"C:\\Users\\me","home":"C:\\Users\\me","parent":"C:\\Users",
 *    "entries":[{"name":"Downloads","path":"C:\\Users\\me\\Downloads","hidden":false}],
 *    "truncated":false}
 *
 * Only directories are listed: a file cannot be a workspace. `path` NULL or
 * empty lists the user's home directory. Entries are name-sorted, and a level
 * holding more than DSH_FS_MAX_ENTRIES directories is cut with `truncated`
 * set. `parent` is null at a filesystem root.
 *
 * On success returns 0 and stores a newly allocated UTF-8 JSON string in
 * *out_json, which the caller frees. On failure returns -1 and stores a
 * newly allocated message in *out_error, likewise the caller's to free.
 */
int dsh_fs_browse(const char *path, char **out_json, char **out_error);

/*
 * Creates one child directory under an existing parent.
 *
 * `name` must be a single non-empty path segment: no separators, and neither
 * "." nor "..". The parent must already exist; a missing one is a failure
 * rather than a level to invent.
 *
 * On success returns 0 and stores the created directory's absolute UTF-8 path
 * in *out_path. On failure returns -1 and stores a message in *out_error.
 * Both are the caller's to free.
 */
int dsh_fs_mkdir(const char *parent, const char *name, char **out_path, char **out_error);

#endif /* DSH_FS_H */
