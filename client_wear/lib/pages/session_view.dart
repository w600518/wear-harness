import 'dart:async';

import 'package:flutter/material.dart';

import '../state/active_listenable_builder.dart';
import '../state/relay_session.dart';
import '../wear_m3/wear_m3.dart';

/// The session browser, and the leftmost card of the home pager.
///
/// It sits left of the composer because reading order is session → message:
/// the user picks what to talk to before typing. Choosing a session here also
/// flips the pager forward to the composer.
class SessionView extends StatefulWidget {
  const SessionView({
    super.key,
    required this.session,
    required this.scrollController,
    this.onOpened,
    this.isActive = true,
  });

  final RelaySession session;
  final ScrollController scrollController;

  /// Invoked after a session is selected, so the pager can advance.
  final VoidCallback? onOpened;

  /// Whether this page is the one the pager is resting on.
  ///
  /// Off screen the page keeps its state but stops following the session, so it
  /// is not rebuilt on every frame of a snapshot being folded into another page.
  final bool isActive;

  @override
  State<SessionView> createState() => _SessionViewState();
}

/// Which slice of the sender's sessions the browser is showing.
enum SessionScope {
  /// Ordinary sessions, the ones a user starts in a project directory.
  workspace,

  /// Sessions spawned by a subagent tool call; they carry a parent.
  subagent,

  /// Sessions that have been archived, which the sender reports separately.
  archived,

  /// Ordinary sessions with no directory, which cannot be grouped under one.
  ungrouped,
}

/// One working directory and the sessions under it.
///
/// The Web UI's sidebar groups its list by workspace and orders each group by
/// recency; this is the same idea on a panel with room for one column.
class _SessionGroup {
  _SessionGroup(
    this.path, {
    this.workspaceId,
    this.title,
    this.parentSessionId,
  });

  final String path;

  /// Backing workspace id, absent for the ungrouped bucket.
  final String? workspaceId;

  /// Workspace display title, when the host supplies one.
  final String? title;

  /// Parent session this group holds subagents for, absent otherwise.
  final String? parentSessionId;

  final List<Map<String, dynamic>> sessions = <Map<String, dynamic>>[];

  /// The last path segment, which is all a watch row can usefully show.
  String get label {
    final named = title;
    if (named != null && named.isNotEmpty) {
      return named;
    }
    if (path.isEmpty) {
      return '未分组';
    }
    final parts = path
        .split(RegExp(r'[\\/]'))
        .where((part) => part.isNotEmpty)
        .toList();
    return parts.isEmpty ? path : parts.last;
  }
}

class _SessionViewState extends State<SessionView>
    with AutomaticKeepAliveClientMixin {
  /// Kept alive across the pager's swipes: it holds the scroll position and the
  /// scope and group choices made in this tab, and a disposal throws all three
  /// away every time the user looks at another page.
  @override
  bool get wantKeepAlive => true;

  SessionScope _scope = SessionScope.workspace;

  /// Working directories whose sessions are open.
  ///
  /// Empty by default: the browser opens as a list of categories, and the user
  /// picks the one they want. On a 233 dp panel a handful of expanded groups
  /// would push everything else off the screen.
  final Set<String> _expandedGroups = <String>{};

  void _toggleGroup(_SessionGroup group) {
    setState(() {
      if (!_expandedGroups.remove(group.path)) {
        _expandedGroups.add(group.path);
      }
    });
  }

  /// Every session the browser can show.
  ///
  /// One list for all four scopes. dsh's `session/list` does not filter by
  /// archived state — `session-controller` contains no archive handling at all;
  /// archiving is owned by the workspace registry — so an archived session
  /// still arrives here with its title, directory and timestamps intact. Which
  /// scope it belongs to is decided by [SessionScope], not by the source.
  List<Map<String, dynamic>> get _all => widget.session.store.sessions;

  /// Whether a session is accounted to some workspace.
  ///
  /// Membership through `sessionIds` is the authoritative test and matches the
  /// web UI, but it lags: a session dsh has just created is not in any
  /// workspace's member list yet even though it runs in that workspace's
  /// directory. Falling back to the directory — and only counting it when a
  /// workspace actually owns that directory — keeps such a session under the
  /// right heading instead of dropping it into Ungrouped.
  bool _isAssigned(Map<String, dynamic> session) {
    if (widget.session.store.workspaceOf(session) != null) {
      return true;
    }

    final cwd = widget.session.cwdOf(session) ?? '';
    if (cwd.isEmpty) {
      return false;
    }

    final workspaces = widget.session.store.workspaces;
    if (workspaces.isEmpty) {
      /* No workspace list yet: the directory is the only evidence available. */
      return true;
    }
    return workspaces.any((workspace) => workspace['path'] == cwd);
  }

  /// The workspace a session belongs under, by membership or by directory.
  _SessionGroup? _groupFor(
    Map<String, dynamic> session,
    List<_SessionGroup> groups,
  ) {
    final byMembership = widget.session.store.workspaceOf(session);
    if (byMembership != null) {
      final id = byMembership['workspaceId'];
      for (final group in groups) {
        if (id is String && group.workspaceId == id) {
          return group;
        }
      }
    }

    /* Not a member yet, but the directory may still name a workspace. */
    final cwd = widget.session.cwdOf(session) ?? '';
    if (cwd.isEmpty) {
      return null;
    }
    for (final group in groups) {
      if (group.path == cwd) {
        return group;
      }
    }
    return null;
  }

  /// True when a session is a subagent, by the same test the web UI uses.
  ///
  /// `origin === 'subagent'`, not the presence of a parent: a session can carry
  /// `parentSessionId` without being a subagent, and a subagent spawned by
  /// another subagent has one too — which is how grandchildren came to be
  /// listed as sessions of their own.
  bool _isSubagent(Map<String, dynamic> session) =>
      session['origin'] == 'subagent';

  /// Walks up the parent chain to the session that started this whole line.
  ///
  /// Every level is a subagent of the level above, so the top of the chain is
  /// the conversation the user actually started. Following it is what lets a
  /// grandchild be shown under its grandparent rather than beside it.
  Map<String, dynamic>? _rootAncestor(
    Map<String, dynamic> session,
    Map<String, Map<String, dynamic>> byId,
  ) {
    var current = session;
    final seen = <String>{};

    while (_isSubagent(current)) {
      final id = current['sessionId'];
      if (id is! String || !seen.add(id)) {
        break;
      }
      final parentId = current['parentSessionId'];
      if (parentId is! String) {
        break;
      }
      final parent = byId[parentId];
      if (parent == null) {
        break;
      }
      current = parent;
    }
    return current;
  }

  /// How many subagent hops separate a session from its root ancestor.
  int _lineageDepth(
    Map<String, dynamic> session,
    Map<String, Map<String, dynamic>> byId,
  ) {
    var current = session;
    var depth = 0;
    final seen = <String>{};

    while (_isSubagent(current)) {
      final id = current['sessionId'];
      if (id is! String || !seen.add(id)) {
        break;
      }
      final parentId = current['parentSessionId'];
      if (parentId is! String) {
        break;
      }
      final parent = byId[parentId];
      if (parent == null) {
        break;
      }
      current = parent;
      depth++;
    }
    return depth;
  }

  /// Groups subagents under the conversation that started their line.
  ///
  /// The arrangement is workspace → session → subagent → the subagents that
  /// subagent started, and so on. Every level keeps its place in the chain, so
  /// a grandchild reads as one level deeper rather than as an unrelated
  /// session.
  List<_SessionGroup> _groupSubagents(List<Map<String, dynamic>> visible) {
    final byId = <String, Map<String, dynamic>>{
      for (final session in widget.session.store.sessions)
        if (session['sessionId'] is String)
          session['sessionId'] as String: session,
    };

    final byRoot = <String, List<Map<String, dynamic>>>{};
    final roots = <String, Map<String, dynamic>>{};

    for (final child in visible) {
      final root = _rootAncestor(child, byId);
      final id = root?['sessionId'];
      final key = id is String ? id : '';
      byRoot.putIfAbsent(key, () => <Map<String, dynamic>>[]).add(child);
      if (root != null) {
        roots[key] = root;
      }
    }

    final groups = <_SessionGroup>[];
    for (final entry in byRoot.entries) {
      final root = roots[entry.key];

      /* Deepest first within a line, so a parent precedes its own children. */
      final members = entry.value
        ..sort(
          (a, b) => _lineageDepth(a, byId).compareTo(_lineageDepth(b, byId)),
        );

      groups.add(
        _SessionGroup(
          root == null ? '' : (widget.session.cwdOf(root) ?? ''),
          title: root == null ? null : _titleOf(root),
          parentSessionId: entry.key.isEmpty ? null : entry.key,
        )..sessions.addAll(members),
      );
    }

    groups.sort((a, b) {
      if (a.path.isEmpty != b.path.isEmpty) {
        return a.path.isEmpty ? 1 : -1;
      }
      final byPath = a.path.compareTo(b.path);
      return byPath != 0 ? byPath : a.label.compareTo(b.label);
    });
    return groups;
  }

  /// A session's display title, falling back to its directory.
  String _titleOf(Map<String, dynamic> session) {
    final projections = session['projections'];
    if (projections is Map<String, dynamic>) {
      final values = projections['values'];
      if (values is Map<String, dynamic>) {
        final title = values['title'];
        if (title is String && title.isNotEmpty) {
          return title;
        }
      }
    }
    final cwd = widget.session.cwdOf(session) ?? '';
    if (cwd.isEmpty) {
      return '未命名会话';
    }
    final parts = cwd
        .split(RegExp(r'[\\/]'))
        .where((part) => part.isNotEmpty)
        .toList();
    return parts.isEmpty ? cwd : parts.last;
  }

  /// Sessions belonging to the selected scope, newest first.
  List<Map<String, dynamic>> get _visible {
    final filtered = _all.where((session) {
      final archived = widget.session.isArchived(session);
      final subagent = _isSubagent(session);
      final assigned = _isAssigned(session);

      switch (_scope) {
        case SessionScope.archived:
          return archived;
        case SessionScope.subagent:
          /*
           * Archived sessions are their own bucket, so the other scopes
           * exclude them — otherwise a subagent that was archived would appear
           * under both headings.
           */
          return !archived && subagent;
        case SessionScope.workspace:
          return !archived && !subagent && assigned;
        case SessionScope.ungrouped:
          return !archived && !subagent && !assigned;
      }
    }).toList();

    filtered.sort((a, b) {
      final left = a['updatedAt'];
      final right = b['updatedAt'];
      if (left is num && right is num) {
        return right.compareTo(left);
      }
      return 0;
    });
    return filtered.length > 40 ? filtered.sublist(0, 40) : filtered;
  }

  /// The visible sessions grouped by workspace membership.
  ///
  /// One group per workspace, in the host's order, resolving members through
  /// `sessionIds` — the same derivation the web UI's browser uses. Sessions
  /// accounted to no workspace trail in a final ungrouped group.
  ///
  /// Before the workspace list arrives, groups are formed from the directory
  /// instead: that is the path the host registers a workspace for, and grouping
  /// by nothing would show every session as ungrouped until the feed comes up.
  List<_SessionGroup> get _grouped {
    final visible = _visible;

    if (_scope == SessionScope.subagent) {
      return _groupSubagents(visible);
    }

    final groups = <_SessionGroup>[];
    final accounted = <String>{};

    if (widget.session.store.workspaces.isEmpty) {
      final byPath = <String, _SessionGroup>{};
      for (final session in visible) {
        final path = widget.session.cwdOf(session) ?? '';
        byPath
            .putIfAbsent(path, () => _SessionGroup(path))
            .sessions
            .add(session);
      }
      final ordered = byPath.values.toList()
        ..sort((a, b) {
          /* The ungrouped bucket always goes last, whatever its timestamps. */
          if (a.path.isEmpty != b.path.isEmpty) {
            return a.path.isEmpty ? 1 : -1;
          }
          return a.label.compareTo(b.label);
        });
      return ordered;
    }

    for (final workspace in widget.session.store.workspaces) {
      final ids = workspace['sessionIds'];
      if (ids is! List) {
        continue;
      }
      final id = workspace['workspaceId'];
      final path = workspace['path'];
      final group = _SessionGroup(
        path is String ? path : '',
        workspaceId: id is String ? id : null,
        title: workspace['title'] is String
            ? workspace['title'] as String
            : null,
      );

      for (final session in visible) {
        final sessionId = session['sessionId'];
        if (sessionId is String && ids.contains(sessionId)) {
          group.sessions.add(session);
          accounted.add(sessionId);
        }
      }
      if (group.sessions.isNotEmpty) {
        groups.add(group);
      }
    }

    /*
     * Sessions the member lists do not name yet but whose directory a workspace
     * owns. A freshly created session is in this state for a moment, and
     * without this pass it would surface under Ungrouped and then jump to its
     * real heading a moment later.
     */
    for (final session in visible) {
      final sessionId = session['sessionId'];
      if (sessionId is String && accounted.contains(sessionId)) {
        continue;
      }
      final owner = _groupFor(session, groups);
      if (owner != null) {
        owner.sessions.add(session);
        if (sessionId is String) {
          accounted.add(sessionId);
        }
      }
    }

    /* Whatever no workspace claimed. */
    final loose = visible
        .where((session) => !accounted.contains(session['sessionId']))
        .toList();
    if (loose.isNotEmpty) {
      groups.add(_SessionGroup('')..sessions.addAll(loose));
    }

    return groups;
  }

  /// Opens a session and moves to the conversation on the same frame.
  ///
  /// This used to await [RelaySession.openSession] before advancing the pager,
  /// which kept the browser on screen for as long as the subscribe and the
  /// model catalog took: on a session that has to be fetched, that is a visible
  /// stall with nothing moving and no hint that the tap registered.
  ///
  /// The switch now happens immediately and the conversation fills in behind
  /// it. Nothing is lost by not waiting: the open session and its notification
  /// are both recorded synchronously, before the first await inside
  /// openSession, so the composer page paints the right conversation as soon as
  /// it appears — with whatever loading state it has until the snapshot lands.
  void _open(String sessionId) {
    unawaited(widget.session.openSession(sessionId));
    widget.onOpened?.call();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ActiveListenableBuilder(
      active: widget.isActive,
      listenable: widget.session,
      builder: (context) {
        final session = widget.session;
        final groups = _grouped;
        final devices = session.devices;
        final headCount = devices.length > 1 ? 2 : 1;

        /*
         * Flattened for the scaling column: one heading row per working
         * directory, and its sessions only while that heading is open.
         */
        final rows = <Widget>[];
        for (final group in groups) {
          rows.add(_groupHeader(group));
          if (_expandedGroups.contains(group.path)) {
            for (final entry in group.sessions) {
              rows.add(_sessionCard(entry));
            }
          }
        }

        return Stack(
          children: <Widget>[
            ScalingLazyColumn(
              controller: widget.scrollController,
              topSpacer: 45,
              /* 50 rather than the 25 the other lists use: this one ends on a
               * row that opens a session, and on a round panel the last row
               * otherwise sits close enough to the bezel that the arc clips it
               * as the list settles. */
              padding: const EdgeInsets.only(bottom: 50),
              itemCount: headCount + 1 + rows.length,
              itemSpacing: WearTokens.itemSpacing,
              itemBuilder: (context, index, centerDistance) {
                var cursor = 0;
                if (devices.length > 1) {
                  if (index == 0) {
                    return _deviceRow(devices);
                  }
                  cursor = 1;
                }
                if (index == cursor) {
                  return _header(session, _visible.length);
                }
                if (index == cursor + 1) {
                  return _scopeRow();
                }
                return rows[index - cursor - 2];
              },
            ),
          ],
        );
      },
    );
  }

  /// Starts a new session in a group's working directory.
  ///
  /// The group is opened afterwards so the session that was just created is
  /// actually visible rather than hidden inside a collapsed heading.
  Future<void> _createSession(_SessionGroup group) async {
    setState(() => _expandedGroups.add(group.path));
    await widget.session.createSession(group.path);
  }

  /// The heading for one working directory, and its open/close control.
  Widget _groupHeader(_SessionGroup group) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final open = _expandedGroups.contains(group.path);

    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: WearCard(
        padding: const EdgeInsets.symmetric(
          horizontal: WearTokens.space3,
          vertical: WearTokens.space1,
        ),
        onTap: () => _toggleGroup(group),
        semanticLabel:
            '${group.label}，${group.sessions.length} 个会话，'
            '${open ? '已展开，点按收起' : '点按展开'}',
        child: Row(
          children: <Widget>[
            Icon(
              group.path.isEmpty
                  ? Icons.help_outline_rounded
                  : Icons.folder_rounded,
              size: 16,
              color: colors.primary,
            ),
            const SizedBox(width: WearTokens.space2),
            Expanded(
              child: Text(
                group.label,
                style: text.labelLarge,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text('${group.sessions.length}', style: text.labelSmall),
            /*
             * Plus, then the disclosure, then the menu.
             *
             * Both actions are suppressed under the archived scope: those
             * groups are directories remembered from sessions that no longer
             * appear in the sender's list, and neither creating inside one nor
             * renaming/removing it is meaningful there — the session list, not
             * the workspace registry, is what archived them.
             */
            if (group.path.isNotEmpty && _scope != SessionScope.archived)
              GestureDetector(
                /*
                 * Its own tap target and opaque hit test, so adding a session
                 * does not also toggle the group underneath the finger.
                 */
                onTap: () => _createSession(group),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: WearTokens.space1,
                  ),
                  child: Icon(
                    Icons.add_rounded,
                    size: 20,
                    color: colors.primary,
                    semanticLabel: '在 ${group.label} 中新增会话',
                  ),
                ),
              ),
            const SizedBox(width: WearTokens.space1),
            Icon(
              open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              size: 18,
              color: colors.primary,
            ),
            /* Nothing to manage for the ungrouped bucket: it is not a workspace. */
            if (group.path.isNotEmpty &&
                _scope != SessionScope.archived) ...<Widget>[
              const SizedBox(width: WearTokens.space1),
              GestureDetector(
                onTap: () => _showWorkspaceMenu(group),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: WearTokens.space1,
                  ),
                  child: Icon(
                    Icons.more_vert_rounded,
                    size: 20,
                    color: colors.primary,
                    semanticLabel: '${group.label} 的工作区操作',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Rename or delete a workspace, as a row of chips.
  Future<void> _showWorkspaceMenu(_SessionGroup group) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(
          WearTokens.space2,
          0,
          WearTokens.space2,
          WearTokens.space4,
        ),
        child: WearChipRow(
          alignment: WrapAlignment.center,
          children: <Widget>[
            WearChip(
              label: '重命名',
              icon: Icons.edit_rounded,
              onTap: () => Navigator.of(sheetContext).pop('rename'),
            ),
            WearChip(
              label: '删除',
              icon: Icons.delete_outline_rounded,
              onTap: () => Navigator.of(sheetContext).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) {
      return;
    }

    if (action == 'rename') {
      final name = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(
          builder: (_) =>
              _RenameSessionPage(initial: group.label, heading: '重命名工作区'),
        ),
      );
      if (name != null) {
        await widget.session.renameWorkspace(group.path, name);
      }
    } else if (action == 'delete') {
      await _deleteWorkspace(group);
    }
  }

  /// Removes a workspace registration after confirming it.
  Future<void> _deleteWorkspace(_SessionGroup group) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(
          WearTokens.space2,
          0,
          WearTokens.space2,
          WearTokens.space4,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '删除工作区「${group.label}」？',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WearTokens.space2),
            WearChipRow(
              alignment: WrapAlignment.center,
              children: <Widget>[
                WearChip(
                  label: '取消',
                  icon: Icons.close_rounded,
                  onTap: () => Navigator.of(sheetContext).pop(false),
                ),
                WearChip(
                  label: '删除',
                  icon: Icons.delete_outline_rounded,
                  onTap: () => Navigator.of(sheetContext).pop(true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await widget.session.deleteWorkspace(group.path);
  }

  Widget _header(RelaySession session, int count) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final (IconData icon, String label, Color color) = switch (session.status) {
      RelayStatus.connected => (
        Icons.cloud_done_rounded,
        '中继已连接',
        colors.primary,
      ),
      RelayStatus.connecting => (Icons.sync_rounded, '连接中', colors.tertiary),
      RelayStatus.failed => (Icons.error_rounded, '连接失败', colors.error),
      _ => (Icons.cloud_off_rounded, '未连接', colors.onSurfaceVariant),
    };

    /*
     * An empty list is the normal state of several different problems, so say
     * which one it is instead of leaving the user with a blank page.
     *
     * The "go and configure it" line is only for a watch that has nothing
     * filled in yet. Once the address and passphrase are set, a watch that is
     * merely between attempts should not be told to go and type them again.
     */
    final String detail;
    if (!session.settings.isComplete) {
      detail = '到「设置」页填写服务器与口令';
    } else if (session.status != RelayStatus.connected) {
      detail = session.lastError ?? '正在连接中继…';
    } else if (count > 0) {
      detail = switch (_scope) {
        SessionScope.subagent => '$count 个子代理会话',
        SessionScope.archived => '$count 个已归档会话',
        SessionScope.ungrouped => '$count 个未分组会话',
        SessionScope.workspace => '$count 个工作区会话',
      };
    } else if (session.relayStatus == null) {
      detail = '已连接中继，正在询问发送端状态…';
    } else if (!session.senderDshReachable) {
      detail = '发送端还没连上本机 dsh：在发送端填好 dsh token，会话就会出现在这里。';
    } else if (_scope == SessionScope.subagent) {
      detail = '发送端已连上 dsh，但那边目前没有子代理会话。';
    } else if (_scope == SessionScope.archived) {
      detail = '没有已归档的会话。归档过的会话会集中显示在这里。';
    } else if (_scope == SessionScope.ungrouped) {
      detail = '没有未分组的会话。没有目录的会话会集中显示在这里。';
    } else {
      detail = '发送端已连上 dsh，但那边目前还没有工作区会话。';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: WearTokens.space1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: 16, color: color),
              const SizedBox(width: WearTokens.space1),
              Flexible(child: Text(label, style: text.titleMedium)),
            ],
          ),
          const SizedBox(height: WearTokens.space1),
          Text(
            detail,
            style: text.bodySmall,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _deviceRow(List<Map<String, dynamic>> devices) {
    final active = widget.session.activeDevice;
    return WearCard(
      padding: const EdgeInsets.symmetric(
        horizontal: WearTokens.space2,
        vertical: WearTokens.space1,
      ),
      child: WearChipRow(
        alignment: WrapAlignment.center,
        children: <Widget>[
          for (final device in devices)
            WearChip(
              label: '${device['name'] ?? device['id']}',
              selected: device['id'] == active,
              onTap: () => widget.session.selectDevice(device['id'] as String?),
            ),
        ],
      ),
    );
  }

  Widget _scopeRow() {
    return WearChipRow(
      alignment: WrapAlignment.center,
      children: <Widget>[
        WearChip(
          label: '工作区',
          icon: Icons.folder_rounded,
          selected: _scope == SessionScope.workspace,
          onTap: () => setState(() => _scope = SessionScope.workspace),
        ),
        WearChip(
          label: '子代理',
          icon: Icons.account_tree_rounded,
          selected: _scope == SessionScope.subagent,
          onTap: () => setState(() => _scope = SessionScope.subagent),
        ),
        WearChip(
          label: '已归档',
          icon: Icons.archive_outlined,
          selected: _scope == SessionScope.archived,
          onTap: () => setState(() => _scope = SessionScope.archived),
        ),
        WearChip(
          label: '未分组',
          icon: Icons.help_outline_rounded,
          selected: _scope == SessionScope.ungrouped,
          onTap: () => setState(() => _scope = SessionScope.ungrouped),
        ),
      ],
    );
  }

  Widget _sessionCard(Map<String, dynamic> item) {
    final colors = Theme.of(context).colorScheme;
    final projections = item['projections'];
    String? title;
    num? turns;
    if (projections is Map<String, dynamic>) {
      final values = projections['values'];
      if (values is Map<String, dynamic>) {
        final raw = values['title'];
        if (raw is String && raw.isNotEmpty) {
          title = raw;
        }
        final stats = values['sessionStats'];
        if (stats is Map<String, dynamic>) {
          turns = stats['turns'] as num?;
        }
      }
    }

    final cwd = item['cwd'];
    final fallback = cwd is String && cwd.isNotEmpty
        ? cwd.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).lastOrNull ??
              cwd
        : '未命名会话';

    final running = item['running'] == true;
    final isSubagent = _isSubagent(item);
    final nesting = _lineageDepth(item, <String, Map<String, dynamic>>{
      for (final session in widget.session.store.sessions)
        if (session['sessionId'] is String)
          session['sessionId'] as String: session,
    });
    final selected = item['sessionId'] == widget.session.store.openSessionId;

    final subtitle = <String>[
      if (selected) '已选中',
      if (running) '运行中',
      if (isSubagent) '子代理',
      /* How deep in the line this one sits: 子代理, 子代理², … */
      if (nesting > 1) '第 $nesting 级',
      if (widget.session.isArchived(item)) '已归档',
      if (turns != null && turns > 0) '$turns 轮',
      _relativeTime(item['updatedAt']),
    ].join(' · ');

    final id = item['sessionId'];
    final label = title ?? fallback;
    final text = Theme.of(context).textTheme;

    return WearCard(
      padding: const EdgeInsets.symmetric(
        horizontal: WearTokens.space3,
        vertical: WearTokens.space2,
      ),
      onTap: id is String ? () => _open(id) : null,
      semanticLabel: '$label，$subtitle',
      /*
       * Hand-built rather than the card's title/subtitle slots: the trailing
       * slot has no tap target of its own, and the menu button must not open
       * the session the way tapping the card does.
       */
      child: Row(
        children: <Widget>[
          Icon(
            selected
                ? Icons.radio_button_checked_rounded
                : (running
                      ? Icons.play_circle_fill_rounded
                      : (isSubagent
                            ? Icons.account_tree_rounded
                            : Icons.chat_bubble_outline_rounded)),
            color: selected || running
                ? colors.primary
                : colors.onSurfaceVariant,
          ),
          const SizedBox(width: WearTokens.space3),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: text.titleMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  subtitle,
                  style: text.bodySmall!.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (id is String)
            GestureDetector(
              /* Opaque, so pressing the dots does not also open the session. */
              onTap: () => _showSessionMenu(id, label),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: WearTokens.space1,
                ),
                child: Icon(
                  Icons.more_vert_rounded,
                  size: 20,
                  color: colors.primary,
                  semanticLabel: '$label 的更多操作',
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The per-session actions, as a row of chips.
  Future<void> _showSessionMenu(String sessionId, String title) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(
          WearTokens.space2,
          0,
          WearTokens.space2,
          WearTokens.space4,
        ),
        child: WearChipRow(
          alignment: WrapAlignment.center,
          children: <Widget>[
            WearChip(
              label: '重命名',
              icon: Icons.edit_rounded,
              onTap: () => Navigator.of(sheetContext).pop('rename'),
            ),
            WearChip(
              label: '分叉会话',
              icon: Icons.call_split_rounded,
              onTap: () => Navigator.of(sheetContext).pop('fork'),
            ),
            WearChip(
              label: '归档会话',
              icon: Icons.archive_outlined,
              onTap: () => Navigator.of(sheetContext).pop('archive'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) {
      return;
    }

    /* The fork inherits the original's directory so it groups correctly. */
    final cwd = _cwdOf(sessionId);

    switch (action) {
      case 'rename':
        final name = await Navigator.of(context).push<String>(
          MaterialPageRoute<String>(
            builder: (_) => _RenameSessionPage(initial: title),
          ),
        );
        if (name != null) {
          await widget.session.renameSession(sessionId, name);
        }
      case 'fork':
        await widget.session.forkSession(sessionId, cwd: cwd);
        if (mounted) {
          widget.onOpened?.call();
        }
      case 'archive':
        await widget.session.archiveSession(sessionId);
      default:
        break;
    }
  }

  /// The directory a session sits in, by dsh's report or the local record.
  String? _cwdOf(String sessionId) {
    for (final item in _all) {
      if (item['sessionId'] == sessionId) {
        return widget.session.cwdOf(item);
      }
    }
    return null;
  }

  static String _relativeTime(dynamic raw) {
    if (raw is! num) {
      return '';
    }
    final then = DateTime.fromMillisecondsSinceEpoch(raw.toInt());
    final delta = DateTime.now().difference(then);
    if (delta.inMinutes < 1) return '刚刚';
    if (delta.inMinutes < 60) return '${delta.inMinutes} 分钟前';
    if (delta.inHours < 24) return '${delta.inHours} 小时前';
    if (delta.inDays < 30) return '${delta.inDays} 天前';
    return '${then.year}-${then.month.toString().padLeft(2, '0')}-'
        '${then.day.toString().padLeft(2, '0')}';
  }
}

extension<T> on Iterable<T> {
  T? get lastOrNull => isEmpty ? null : last;
}

/// A full-screen prompt for renaming one session.
///
/// Owns the whole panel for the same reason the settings prompt does: the
/// field, the keyboard and the actions must not compete with a page swipe.
class _RenameSessionPage extends StatefulWidget {
  const _RenameSessionPage({required this.initial, this.heading = '重命名会话'});

  final String initial;
  final String heading;

  @override
  State<_RenameSessionPage> createState() => _RenameSessionPageState();
}

class _RenameSessionPageState extends State<_RenameSessionPage> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return WearScaffold(
      child: Padding(
        padding: WearTokens.promptInsets,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              widget.heading,
              style: text.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WearTokens.space2),
            TextField(
              controller: _controller,
              autofocus: true,
              style: text.bodyMedium,
              decoration: const InputDecoration(hintText: '会话名称'),
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
                  label: '保存',
                  icon: Icons.check_rounded,
                  selected: true,
                  onTap: () {
                    final value = _controller.text.trim();
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
