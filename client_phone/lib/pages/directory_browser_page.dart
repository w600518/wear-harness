import 'dart:async';

import 'package:flutter/material.dart';

import '../state/relay_session.dart';
import '../state/rotary_scroll.dart';
import '../wear_m3/wear_m3.dart';

/// Picks a directory on the host and registers it as a workspace.
///
/// The listing comes from dsh's browse backend — the half of the directory
/// picker built for remote clients, which walks the host filesystem without
/// rendering anything on the host's display. Walking the tree is the only
/// workable way to name a directory here: a watch has no keyboard worth typing
/// an absolute path into, and the path would have to be spelled exactly right,
/// separators and all.
class DirectoryBrowserPage extends StatefulWidget {
  const DirectoryBrowserPage({super.key, required this.session});

  final RelaySession session;

  @override
  State<DirectoryBrowserPage> createState() => _DirectoryBrowserPageState();
}

class _DirectoryBrowserPageState extends State<DirectoryBrowserPage> {
  final ScrollController _scroll = ScrollController();

  /*
   * The path field doubles as the location display, so it always holds the
   * level on screen — and an empty string at the drive list, which is what the
   * hint text says.
   */
  final TextEditingController _path = TextEditingController();

  Map<String, dynamic>? _listing;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    /* This page covers the pager, so it takes the crown while it is up; closing
     * it uncovers the pager's own claim. */
    RotaryScroll.claim(_scroll);
    unawaited(_load());
  }

  @override
  void dispose() {
    RotaryScroll.release(_scroll);
    _scroll.dispose();
    _path.dispose();
    super.dispose();
  }

  /// Lists one level. No path means the top of the tree, which the sender
  /// answers with the drive list rather than with the home directory.
  ///
  /// The previous level stays on screen while the new one loads: replacing it
  /// with a spinner would blank the page on every step deeper, and each step is
  /// a single round trip.
  Future<void> _load([String? path]) async {
    setState(() => _error = null);
    final listing = await widget.session.listDirectory(path);
    if (!mounted) {
      return;
    }
    setState(() {
      if (listing == null) {
        _error = widget.session.lastError ?? '无法读取该目录';
      } else {
        _listing = listing;
        final resolved = listing['path'];
        /*
         * The sender folds what it was given — separators, ".." and all — so the
         * field shows where the level actually is, not what was typed or tapped
         * to reach it.
         */
        _path.text = resolved is String ? resolved : '';
      }
    });
  }

  /// Jumps to whatever the user typed, once it looks like a path at all.
  void _submitPath(String value) {
    final target = value.trim();
    if (target.isEmpty || target == _currentPath) {
      return;
    }
    unawaited(_load(target));
  }

  /// The level currently on screen, as dsh reported it.
  String? get _currentPath {
    final path = _listing?['path'];
    return path is String && path.isNotEmpty ? path : null;
  }

  /// Where the up control leads, as a path.
  ///
  /// The empty string means the drive list, and null means there is nowhere
  /// above at all.
  ///
  /// A level's `parent` field is not enough on its own. The drive list is a
  /// level the sender composes rather than one the filesystem has, so it has no
  /// path — and a drive root has no `parent`, since `C:\` genuinely has nothing
  /// above it. Between them that left no way back from a drive root to the list
  /// of drives, which is the step a user takes on every visit. The drive list
  /// is therefore named by the empty string: it is the level above a drive root,
  /// and being the one level without a path it is also the one that ends the
  /// walk.
  String? get _upTarget {
    final parent = _listing?['parent'];
    if (parent is String && parent.isNotEmpty) {
      return parent;
    }
    final path = _listing?['path'];
    return (path is String && path.isNotEmpty) ? '' : null;
  }

  List<Map<String, dynamic>> get _entries {
    final entries = _listing?['entries'];
    if (entries is! List) {
      return const <Map<String, dynamic>>[];
    }
    return entries.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  /// Registers the level on screen as a workspace and closes the page.
  Future<void> _addHere() async {
    final path = _currentPath;
    if (path == null) {
      return;
    }
    setState(() => _busy = true);
    final added = await widget.session.addWorkspace(path);
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    if (added) {
      /* The path goes back with the pop so the browser can open the heading it
       * just created instead of leaving a collapsed one behind. */
      Navigator.of(context).pop(path);
    } else {
      /* The failure stays on this page: the level is still on screen, and the
       * user can pick a different one without walking back here. */
      setState(() => _error = widget.session.lastError ?? '添加工作区失败');
    }
  }

  /// Creates a child directory here, then re-lists the level to show it.
  Future<void> _createHere() async {
    final path = _currentPath;
    if (path == null) {
      return;
    }
    final controller = TextEditingController();
    final name = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => _NewDirectoryPage(controller: controller),
      ),
    );
    controller.dispose();
    if (name == null || !mounted) {
      return;
    }
    setState(() => _busy = true);
    final created = await widget.session.createDirectory(path, name);
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    if (created == null) {
      setState(() => _error = widget.session.lastError ?? '新建文件夹失败');
      return;
    }
    /*
     * Re-list rather than appending the new row locally: the level is dsh's,
     * and its own answer is the one that stays right when the name collided
     * with something the entry bound had truncated away.
     */
    await _load(path);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    if (_listing == null) {
      return WearScaffold(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(WearTokens.space4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (_error == null)
                  const WearCircularProgress()
                else
                  Text(
                    _error!,
                    style: text.bodySmall!.copyWith(color: colors.error),
                    textAlign: TextAlign.center,
                  ),
                const SizedBox(height: WearTokens.space3),
                WearChipRow(
                  alignment: WrapAlignment.center,
                  children: <Widget>[
                    WearChip(
                      label: _error == null ? '取消' : '重试',
                      icon: _error == null
                          ? Icons.close_rounded
                          : Icons.refresh_rounded,
                      onTap: () => _error == null
                          ? Navigator.of(context).pop()
                          : unawaited(_load()),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    final up = _upTarget;
    final rows = <Widget>[
      _pathField(),
      if (_error != null) _errorRow(_error!),
      if (up != null)
        _entryRow(
          icon: Icons.arrow_upward_rounded,
          /* Named for what it leads to at a drive root, where the level above is
           * the list of drives rather than a directory. */
          label: up.isEmpty ? '选择磁盘' : '上级目录',
          onTap: () => unawaited(_load(up.isEmpty ? null : up)),
        ),
      for (final entry in _entries)
        _entryRow(
          icon: entry['hidden'] == true
              ? Icons.folder_off_rounded
              : Icons.folder_rounded,
          label: '${entry['name']}',
          onTap: () {
            final target = entry['path'];
            if (target is String && target.isNotEmpty) {
              unawaited(_load(target));
            }
          },
        ),
      _actions(),
    ];

    return WearScaffold(
      overlays: <Widget>[PositionIndicator(controller: _scroll)],
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.only(top: 45, bottom: 25),
        itemCount: rows.length,
        itemBuilder: (context, index) => rows[index],
      ),
    );
  }

  /// The level being browsed, and the field that goes to another one.
  ///
  /// It is an input rather than a label because walking a deep tree a level at a
  /// time is slow on a watch and the path is usually already known. The text is
  /// `labelLarge`, the size the scope chips use, so the field reads as part of
  /// the same surface rather than as a heading above it.
  Widget _pathField() {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(
        left: WearTokens.space3,
        right: WearTokens.space3,
        bottom: WearTokens.itemSpacing,
      ),
      child: WearCard(
        padding: const EdgeInsets.symmetric(
          horizontal: WearTokens.space3,
          vertical: WearTokens.space1,
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.my_location_rounded, size: 16, color: colors.primary),
            const SizedBox(width: WearTokens.space2),
            Expanded(
              child: TextField(
                controller: _path,
                style: text.labelLarge,
                maxLines: 1,
                textInputAction: TextInputAction.go,
                onSubmitted: _submitPath,
                decoration: InputDecoration(
                  hintText: '输入路径',
                  hintStyle: text.labelLarge!.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                  isDense: true,
                  border: InputBorder.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorRow(String message) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(
        left: WearTokens.space3,
        right: WearTokens.space3,
        bottom: WearTokens.itemSpacing,
      ),
      child: Text(
        message,
        style: text.bodySmall!.copyWith(color: colors.error),
        maxLines: 4,
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _entryRow({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(
        left: WearTokens.space3,
        right: WearTokens.space3,
        bottom: WearTokens.itemSpacing,
      ),
      child: WearCard(
        padding: const EdgeInsets.symmetric(
          horizontal: WearTokens.space3,
          vertical: WearTokens.space1,
        ),
        onTap: onTap,
        semanticLabel: '进入 $label',
        child: Row(
          children: <Widget>[
            Icon(icon, size: 16, color: colors.primary),
            const SizedBox(width: WearTokens.space2),
            Expanded(
              child: Text(
                label,
                style: text.labelLarge,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: colors.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  /// This level's two actions: register it, or make a directory inside it.
  ///
  /// Both are offered at every level rather than only at the root of a drive,
  /// because nothing distinguishes the level a workspace should live at.
  Widget _actions() {
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.only(top: WearTokens.space2),
        child: Center(child: WearCircularProgress(size: 22, strokeWidth: 2)),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: WearTokens.space2),
      child: WearChipRow(
        alignment: WrapAlignment.center,
        children: <Widget>[
          WearChip(
            label: '新建文件夹',
            icon: Icons.create_new_folder_rounded,
            onTap: () => unawaited(_createHere()),
          ),
          WearChip(
            label: '添加此目录',
            icon: Icons.add_rounded,
            selected: true,
            onTap: () => unawaited(_addHere()),
          ),
        ],
      ),
    );
  }
}

/// A full-screen prompt for one new directory name.
///
/// Shaped like the interjection editor: on a watch the keyboard is already the
/// whole screen, so the page around it carries only the title and the two
/// decisions.
class _NewDirectoryPage extends StatefulWidget {
  const _NewDirectoryPage({required this.controller});

  final TextEditingController controller;

  @override
  State<_NewDirectoryPage> createState() => _NewDirectoryPageState();
}

class _NewDirectoryPageState extends State<_NewDirectoryPage> {
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return WearScaffold(
      child: Padding(
        padding: WearTokens.promptInsets,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('新建文件夹', style: text.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: WearTokens.space2),
            TextField(
              controller: widget.controller,
              autofocus: true,
              maxLines: 2,
              minLines: 1,
              style: text.bodyMedium,
              textInputAction: TextInputAction.none,
              decoration: const InputDecoration(
                hintText: '文件夹名称',
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            WearChipRow(
              alignment: WrapAlignment.center,
              children: <Widget>[
                WearChip(
                  label: '取消',
                  icon: Icons.close_rounded,
                  onTap: () => Navigator.of(context).pop(),
                ),
                WearChip(
                  label: '创建',
                  icon: Icons.check_rounded,
                  selected: true,
                  onTap: () {
                    final value = widget.controller.text.trim();
                    Navigator.of(context).pop(value.isEmpty ? null : value);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
