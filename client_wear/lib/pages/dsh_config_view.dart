import 'package:flutter/material.dart';

import '../state/relay_session.dart';
import '../wear_m3/wear_m3.dart';

/// The remote dsh's settings: which model answers, and what permission and
/// sandbox policy the installation is under.
///
/// The session list lives on its own card to the left; this page is only about
/// how the remote side behaves once a session is open.
class DshConfigView extends StatefulWidget {
  const DshConfigView({
    super.key,
    required this.session,
    required this.scrollController,
  });

  final RelaySession session;
  final ScrollController scrollController;

  @override
  State<DshConfigView> createState() => _DshConfigViewState();
}

class _DshConfigViewState extends State<DshConfigView> {
  bool _busy = false;

  /// True while this page has a balance read of its own in flight.
  ///
  /// The value itself lives on the session — it has to survive the page and be
  /// refreshed when a turn ends — so this only drives the spinner.
  bool _balanceLoading = false;

  @override
  void initState() {
    super.initState();
    _loadBalance();
  }

  /// Re-reads the balance, showing a spinner for the duration.
  Future<void> _loadBalance() async {
    if (_balanceLoading) {
      return;
    }
    setState(() => _balanceLoading = true);
    await widget.session.refreshBalance();
    if (!mounted) {
      return;
    }
    setState(() => _balanceLoading = false);
  }

  Future<void> _pickModel() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    Map<String, dynamic>? catalog;
    try {
      catalog = await widget.session.modelCatalog();
    } on Object {
      /* Guarded below by the null check; the point of the try is the finally. */
      catalog = null;
    } finally {
      /*
       * Always released. The old code cleared the flag only on the success
       * path, so one failed request left the card permanently un-tappable —
       * which is what "模型无法使用" turned out to be.
       */
      if (mounted) {
        setState(() => _busy = false);
      }
    }
    if (!mounted || catalog == null) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            _ModelPicker(session: widget.session, catalog: catalog!),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final session = widget.session;
        final store = session.store;

        return Stack(
          children: <Widget>[
            ScalingLazyColumn(
              controller: widget.scrollController,
              topSpacer: 45,
              padding: const EdgeInsets.only(bottom: 25),
              itemCount: 7,
              itemSpacing: WearTokens.itemSpacing,
              itemBuilder: (context, index, centerDistance) {
                switch (index) {
                  case 0:
                    return _header(store);
                  case 1:
                    return _balanceCard(store);
                  case 2:
                    return _modelCard(store);
                  case 3:
                    return _permissionCard(store);
                  case 4:
                    return _goalCard(store);
                  case 5:
                    return _todoCard(store);
                  default:
                    return _globalSettingsCard(store);
                }
              },
            ),
          ],
        );
      },
    );
  }

  Widget _header(dynamic store) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: WearTokens.space1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('DSH 设置', style: text.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: WearTokens.space1),
          Text(
            store.openSessionId == null ? '未选择会话' : '这些设置作用于当前选中的会话。',
            style: text.bodySmall!.copyWith(color: colors.onSurfaceVariant),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  /// The DeepSeek account balance.
  ///
  /// Taken from the whale-widget plugin's own endpoint rather than derived from
  /// token counts: what a conversation costs is a pricing question, and that
  /// widget already answers it with the figure the account is actually billed
  /// against. Tapping refreshes.
  Widget _balanceCard(dynamic store) {
    final colors = Theme.of(context).colorScheme;
    final balance = widget.session.balance;
    final ok = balance?['ok'] == true;
    final total = balance?['totalBalance'];
    final today = balance?['todayUsage'];
    final currency = balance?['currency'];
    final symbol = currency == 'CNY' ? '¥' : '';

    final String label;
    if (balance == null && _balanceLoading) {
      label = '读取中…';
    } else if (!ok || total is! num) {
      label = '没有从 dsh 读到余额';
    } else {
      final head = '$symbol${total.toStringAsFixed(2)}';
      label = today is num
          ? '$head · 今日 $symbol${today.toStringAsFixed(2)}'
          : head;
    }

    return WearCard(
      padding: const EdgeInsets.symmetric(
        horizontal: WearTokens.space3,
        vertical: WearTokens.space2,
      ),
      leading: Icon(
        Icons.account_balance_wallet_rounded,
        color: colors.primary,
      ),
      title: '余额',
      subtitle: label,
      trailing: _balanceLoading
          ? const WearCircularProgress(size: 16, strokeWidth: 2)
          : const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _BalancePage(session: widget.session),
        ),
      ),
      semanticLabel: 'DeepSeek 余额，$label',
    );
  }

  Widget _modelCard(dynamic store) {
    final model = store.modelSelection;

    /*
     * "读取中…" was shown whenever no projection had arrived yet, which is
     * permanent while no session is open — it read as a stuck load rather than
     * as the missing precondition it actually is.
     */
    final String label;
    if (store.openSessionId == null) {
      label = '先在「会话」页选择一个会话';
    } else if (model is Map) {
      label = '${model['model'] ?? '未选择'}';
    } else {
      label = '由 dsh 决定';
    }
    final canTap = store.openSessionId != null && !_busy;

    return WearCard(
      padding: const EdgeInsets.symmetric(
        horizontal: WearTokens.space3,
        vertical: WearTokens.space2,
      ),
      leading: Icon(
        Icons.memory_rounded,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: '模型',
      subtitle: label,
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: canTap ? _pickModel : null,
      semanticLabel: '选择模型，当前 $label',
    );
  }

  Future<void> _pickPermission() async {
    final options = widget.session.store.permissionOptions;
    if (options.isEmpty || widget.session.store.openSessionId == null) {
      return;
    }
    final chosen = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => _PermissionPicker(
          current: widget.session.store.permissionPreset,
          options: options,
        ),
      ),
    );
    if (chosen != null) {
      await widget.session.setPermission(chosen);
    }
  }

  Widget _permissionCard(dynamic store) {
    final options = store.permissionOptions;
    final hasSession = store.openSessionId != null;

    /*
     * The subtitle always says what will happen on tap. A card that looks
     * tappable but silently does nothing is worse than one that explains it
     * has nothing to offer yet.
     */
    final String label;
    if (!hasSession) {
      label = '先在「会话」页选择一个会话';
    } else if (options.isEmpty) {
      label = store.permissionPreset ?? '等待会话提供预设…';
    } else {
      label = store.permissionPreset ?? '未设置';
    }

    return WearCard(
      padding: const EdgeInsets.symmetric(
        horizontal: WearTokens.space3,
        vertical: WearTokens.space2,
      ),
      leading: Icon(
        Icons.shield_outlined,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: '权限预设',
      subtitle: label,
      /* Same chevron as the model row, so the two read as a pair. */
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: options.isEmpty || !hasSession ? null : _pickPermission,
      semanticLabel: '权限预设，当前 $label',
    );
  }

  Widget _goalCard(dynamic store) {
    final colors = Theme.of(context).colorScheme;
    final session = widget.session;
    final objective = session.goalObjective;
    final hasGoal = session.hasGoal;

    return WearCard(
      padding: const EdgeInsets.symmetric(
        horizontal: WearTokens.space3,
        vertical: WearTokens.space2,
      ),
      leading: Icon(Icons.flag_rounded, color: colors.primary),
      title: '目标',
      subtitle: hasGoal
          ? '${_phaseLabel(session.goalPhase)} · ${objective ?? ''}'
          : '暂无',
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: hasGoal
          ? () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => _GoalPage(session: session),
              ),
            )
          : null,
      semanticLabel: hasGoal ? '目标 $objective' : '目标，暂无',
    );
  }

  /// Chinese label for a goal phase.
  static String _phaseLabel(String? phase) => switch (phase) {
    'active' => '进行中',
    'paused' => '已暂停',
    'blocked' => '受阻',
    'complete' => '已完成',
    _ => '未知',
  };

  Widget _todoCard(dynamic store) {
    final todos = store.todos as List<Map<String, dynamic>>;
    void open() => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _TodoPage(session: widget.session),
      ),
    );
    if (todos.isEmpty) {
      return WearCard(
        padding: const EdgeInsets.symmetric(
          horizontal: WearTokens.space3,
          vertical: WearTokens.space2,
        ),
        leading: Icon(
          Icons.checklist_rounded,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        title: '任务',
        subtitle: '暂无',
        semanticLabel: '任务，暂无',
      );
    }
    return WearCard(
      padding: const EdgeInsets.symmetric(
        horizontal: WearTokens.space3,
        vertical: WearTokens.space2,
      ),
      leading: Icon(
        Icons.checklist_rounded,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: '任务',
      subtitle: _todoSummary(todos),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: open,
      semanticLabel: '任务，${_todoSummary(todos)}',
    );
  }

  String _todoSummary(List<Map<String, dynamic>> todos) {
    var done = 0;
    var active = '';
    for (final todo in todos) {
      final status = todo['status'];
      if (status == 'completed') {
        done++;
      } else if (status == 'in_progress') {
        active = '${todo['content'] ?? ''}';
      }
    }
    final head = '$done/${todos.length} 已完成';
    return active.isEmpty ? head : '$head · $active';
  }

  /// The way into the settings that are not about one conversation.
  ///
  /// Every card above describes the open session; this one opens the layer
  /// above it — the Agent preset a new session is composed from, and the model
  /// providers the whole deployment can reach.
  Widget _globalSettingsCard(dynamic store) {
    return WearCard(
      padding: const EdgeInsets.symmetric(
        horizontal: WearTokens.space3,
        vertical: WearTokens.space2,
      ),
      leading: Icon(
        Icons.tune_rounded,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: 'DSH 全局设置',
      subtitle: 'Agent 预设与模型提供方',
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _GlobalSettingsPage(session: widget.session),
        ),
      ),
      semanticLabel: '打开 DSH 全局设置',
    );
  }
}

/// Settings that sit above any one conversation.
///
/// Neither entry is a property of a running session: an Agent preset is baked
/// in while the session is still blank, and a model provider belongs to the
/// whole deployment rather than to any conversation.
class _GlobalSettingsPage extends StatefulWidget {
  const _GlobalSettingsPage({required this.session});

  final RelaySession session;

  @override
  State<_GlobalSettingsPage> createState() => _GlobalSettingsPageState();
}

class _GlobalSettingsPageState extends State<_GlobalSettingsPage> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final current = widget.session.store.agentPreset;

    /* The same frame the picker pages use: a scaling column with the title as
     * its first row, so the heading scrolls with the list instead of sitting
     * behind a fixed band, and the clock keeps its own space above. */
    return WearScaffold(
      timeTextController: _scroll,
      overlays: <Widget>[PositionIndicator(controller: _scroll)],
      child: ScalingLazyColumn(
        controller: _scroll,
        topSpacer: 45,
        padding: const EdgeInsets.only(bottom: 25),
        itemCount: 3,
        itemSpacing: WearTokens.itemSpacing,
        itemBuilder: (context, index, centerDistance) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: WearTokens.space2),
              child: Column(
                children: <Widget>[
                  Text(
                    'DSH 全局设置',
                    style: text.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: WearTokens.space1),
                  Text(
                    '作用于整个部署与新建的会话',
                    style: text.bodySmall!.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }
          if (index == 1) {
            return _entry(
              icon: Icons.extension_outlined,
              title: 'Agent 预设',
              subtitle: current ?? '由 dsh 决定',
              colors: colors,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => _AgentPresetsPage(session: widget.session),
                ),
              ),
              semanticLabel: '打开 Agent 预设',
            );
          }
          return _entry(
            icon: Icons.cloud_outlined,
            title: '模型提供方',
            subtitle: '已添加的模型服务',
            colors: colors,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => _ProvidersPage(session: widget.session),
              ),
            ),
            semanticLabel: '打开模型提供方',
          );
        },
      ),
    );
  }

  Widget _entry({
    required IconData icon,
    required String title,
    required String subtitle,
    required ColorScheme colors,
    required VoidCallback onTap,
    required String semanticLabel,
  }) {
    return WearCard(
      padding: const EdgeInsets.symmetric(
        horizontal: WearTokens.space3,
        vertical: WearTokens.space2,
      ),
      leading: Icon(icon, color: colors.primary),
      title: title,
      subtitle: subtitle,
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
      semanticLabel: semanticLabel,
    );
  }
}

/// The Agent presets this deployment offers.
class _AgentPresetsPage extends StatefulWidget {
  const _AgentPresetsPage({required this.session});

  final RelaySession session;

  @override
  State<_AgentPresetsPage> createState() => _AgentPresetsPageState();
}

class _AgentPresetsPageState extends State<_AgentPresetsPage> {
  static const String _ns = 'agent-presets';

  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _presets = const <Map<String, dynamic>>[];
  String _current = '';
  bool _loading = true;
  String? _busy;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final roster = await widget.session.agentPresetRoster();
    final described = await widget.session.settingsDescribe();
    if (!mounted) {
      return;
    }
    final presets = roster?['presets'];
    /* The default lives in settings, not on any session: it is what the Host
     * resolves when it composes a new one, which is why this page needs no
     * conversation open to be useful. */
    final entry = namespacesOf(described)[_ns];
    var current = '';
    if (entry is Map<String, dynamic>) {
      final value = entry['value'];
      final fallback = value is! Map<String, dynamic> ? null : value['default'];
      if (fallback is String) {
        current = fallback;
      }
    }
    setState(() {
      _presets = presets is List
          ? presets.whereType<Map<String, dynamic>>().toList(growable: false)
          : const <Map<String, dynamic>>[];
      _current = current;
      _loading = false;
      _error = widget.session.lastError;
    });
  }

  Future<void> _pick(String id) async {
    setState(() {
      _busy = id;
      _error = null;
    });
    final ok = await widget.session.updateSettings(_ns, <String, dynamic>{
      'default': id,
    });
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = null;
      if (ok) {
        _current = id;
      } else {
        _error = widget.session.lastError;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final current = _current;

    /* The picker-page frame: title as the first row of the column, so it
     * scrolls with the list rather than sitting in a fixed band. */
    return WearScaffold(
      timeTextController: _scroll,
      overlays: <Widget>[PositionIndicator(controller: _scroll)],
      child: _loading
          ? const Center(child: WearCircularProgress(size: 24, strokeWidth: 2))
          : ScalingLazyColumn(
              controller: _scroll,
              topSpacer: 45,
              padding: const EdgeInsets.only(bottom: 25),
              itemCount: _presets.length + (_error == null ? 1 : 2),
              itemSpacing: WearTokens.itemSpacing,
              itemBuilder: (context, index, centerDistance) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: WearTokens.space2,
                    ),
                    child: Column(
                      children: <Widget>[
                        Text(
                          'Agent 预设',
                          style: text.titleMedium,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: WearTokens.space1),
                        Text(
                          current.isEmpty ? '由 dsh 决定' : '当前默认：$current',
                          style: text.bodySmall!.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: WearTokens.space1),
                        Text(
                          '新建会话时使用，无需先选择会话。',
                          style: text.labelSmall!.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                }
                final row = index - 1;
                if (row >= _presets.length) {
                  return Text(
                    _error!,
                    style: text.labelSmall!.copyWith(color: colors.error),
                    textAlign: TextAlign.center,
                  );
                }
                final preset = _presets[row];
                final id = '${preset['id'] ?? ''}';
                final label = '${preset['name'] ?? (id.isEmpty ? '未命名' : id)}';
                final isDefault = preset['isDefault'] == true;
                final selected = id.isNotEmpty && id == current;
                final broken = preset['broken'] == true;

                return Padding(
                  padding: const EdgeInsets.only(bottom: WearTokens.space2),
                  child: WearCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: WearTokens.space3,
                      vertical: WearTokens.space2,
                    ),
                    selected: selected,
                    title: label,
                    subtitle: broken ? '这个预设无法装载' : (isDefault ? '默认预设' : id),
                    trailing: _busy == id
                        ? const WearCircularProgress(size: 16, strokeWidth: 2)
                        : (selected ? const Icon(Icons.check_rounded) : null),
                    onTap: !broken && _busy == null ? () => _pick(id) : null,
                    semanticLabel: '$label${selected ? '，当前预设' : ''}',
                  ),
                );
              },
            ),
    );
  }
}

/// A pushed page listing the models the sender reported.
class _ModelPicker extends StatelessWidget {
  const _ModelPicker({required this.session, required this.catalog});

  final RelaySession session;
  final Map<String, dynamic> catalog;

  @override
  Widget build(BuildContext context) {
    final scroll = ScrollController();
    final groups = catalog['groups'];
    final rows = <Map<String, dynamic>>[];

    if (groups is List) {
      for (final group in groups) {
        if (group is! Map<String, dynamic>) {
          continue;
        }
        final providerId = '${group['id'] ?? ''}';
        final models = group['models'];
        if (models is! List) {
          continue;
        }
        for (final model in models) {
          if (model is Map<String, dynamic>) {
            rows.add(<String, dynamic>{
              'provider': providerId,
              'id': model['id'],
              'name': model['name'] ?? model['id'],
              'description': model['description'],
            });
          }
        }
      }
    }

    final current = session.store.modelSelection;
    String? currentId;
    if (current != null) {
      currentId = '${current['model']}';
    }

    return WearScaffold(
      timeTextController: scroll,
      overlays: <Widget>[PositionIndicator(controller: scroll)],
      child: ScalingLazyColumn(
        controller: scroll,
        topSpacer: 45,
        padding: const EdgeInsets.only(bottom: 25),
        itemCount: rows.length + 1,
        itemSpacing: WearTokens.itemSpacing,
        itemBuilder: (context, index, centerDistance) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: WearTokens.space2),
              child: Text(
                '选择模型',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
            );
          }
          final row = rows[index - 1];
          final selected = row['id'] == currentId;
          final description = row['description'];

          return WearCard(
            padding: const EdgeInsets.symmetric(
              horizontal: WearTokens.space3,
              vertical: WearTokens.space2,
            ),
            leading: Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            title: '${row['name']}',
            subtitle: description is String && description.isNotEmpty
                ? description
                : '${row['provider']}',
            onTap: () async {
              await session.selectModel('${row['provider']}', '${row['id']}');
              if (context.mounted) {
                Navigator.of(context).pop();
              }
            },
            semanticLabel: '${row['name']}${selected ? '，当前' : ''}',
          );
        },
      ),
    );
  }
}

/// A pushed page listing the permission presets dsh reported.
///
/// Picking one returns its value; the caller turns it into `/permission <value>`
/// and lets the projection that follows redraw the card.
class _PermissionPicker extends StatelessWidget {
  const _PermissionPicker({required this.current, required this.options});

  final String? current;
  final List<Map<String, dynamic>> options;

  @override
  Widget build(BuildContext context) {
    final scroll = ScrollController();

    return WearScaffold(
      timeTextController: scroll,
      overlays: <Widget>[PositionIndicator(controller: scroll)],
      child: ScalingLazyColumn(
        controller: scroll,
        topSpacer: 45,
        padding: const EdgeInsets.only(bottom: 25),
        itemCount: options.length + 1,
        itemSpacing: WearTokens.itemSpacing,
        itemBuilder: (context, index, centerDistance) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: WearTokens.space2),
              child: Text(
                '权限预设',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
            );
          }

          final option = options[index - 1];
          final value = '${option['value']}';
          final selected = value == current;
          final description = option['description'];

          return WearCard(
            padding: const EdgeInsets.symmetric(
              horizontal: WearTokens.space3,
              vertical: WearTokens.space2,
            ),
            leading: Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            title: '${option['name'] ?? value}',
            subtitle: description is String && description.isNotEmpty
                ? description
                : value,
            onTap: () => Navigator.of(context).pop(value),
            semanticLabel: '${option['name'] ?? value}${selected ? '，当前' : ''}',
          );
        },
      ),
    );
  }
}

/// The open session's goal, with the three mutations dsh exposes for it.
class _GoalPage extends StatefulWidget {
  const _GoalPage({required this.session});

  final RelaySession session;

  @override
  State<_GoalPage> createState() => _GoalPageState();
}

class _GoalPageState extends State<_GoalPage> {
  bool _busy = false;

  /// Runs one mutation, guarding against a second tap while it is in flight.
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _edit(String current) async {
    final controller = TextEditingController(text: current);
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => _GoalTextPage(controller: controller),
      ),
    );
    controller.dispose();
    if (value != null) {
      await _run(() => widget.session.editGoal(value));
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final session = widget.session;
        final objective = session.goalObjective ?? '暂无';
        final phase = _DshConfigViewState._phaseLabel(session.goalPhase);
        final paused = session.goalPhase == 'paused';

        return WearScaffold(
          child: Padding(
            padding: WearTokens.promptInsets,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    '目标',
                    style: text.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: WearTokens.space2),
                  WearCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: WearTokens.space3,
                      vertical: WearTokens.space2,
                    ),
                    leading: Icon(Icons.flag_rounded, color: colors.primary),
                    title: phase,
                    subtitle: objective,
                  ),
                  const SizedBox(height: WearTokens.space3),
                  WearChipRow(
                    alignment: WrapAlignment.center,
                    children: <Widget>[
                      /* Pause and resume are one position: only one of the two is
                     * ever the meaningful action for the current phase. */
                      if (paused)
                        WearChip(
                          label: '恢复',
                          icon: Icons.play_arrow_rounded,
                          onTap: _busy ? null : () => _run(session.resumeGoal),
                        )
                      else
                        WearChip(
                          label: '暂停',
                          icon: Icons.pause_rounded,
                          onTap: _busy ? null : () => _run(session.pauseGoal),
                        ),
                      WearChip(
                        label: '修改',
                        icon: Icons.edit_rounded,
                        onTap: _busy ? null : () => _edit(objective),
                      ),
                      WearChip(
                        label: '删除',
                        icon: Icons.delete_outline_rounded,
                        onTap: _busy ? null : () => _run(session.clearGoal),
                      ),
                    ],
                  ),
                  const SizedBox(height: WearTokens.space2),
                  if (_busy)
                    const Center(
                      child: WearCircularProgress(size: 20, strokeWidth: 2),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A single line that scrolls only when it does not fit.
///
/// A watch panel is narrow and task text is written for a wider screen, so the
/// long entries would otherwise be cut off and unreadable. The measurement
/// comes first on purpose: a marquee on everything is noise, and on a line that
/// already fits it would be an animation with nothing to reveal.
class _MarqueeText extends StatefulWidget {
  const _MarqueeText({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  /// Blank run between the end of the line and its repeat.
  static const double _gap = 36;

  late final AnimationController _controller = AnimationController(vsync: this);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: Directionality.of(context),
        )..layout();
        final width = painter.width;
        final height = painter.height;
        painter.dispose();

        if (width <= constraints.maxWidth || constraints.maxWidth <= 0) {
          /* It fits: plain text, and stop whatever a previous build started. */
          if (_controller.isAnimating) {
            _controller.stop();
          }
          return Text(
            widget.text,
            style: widget.style,
            maxLines: 1,
            softWrap: false,
          );
        }

        final span = width + _gap;
        _controller.duration = Duration(
          milliseconds: (span * 24).round().clamp(3000, 20000),
        );
        if (!_controller.isAnimating) {
          _controller.repeat();
        }

        /*
         * The height is pinned to the measured line height on purpose. A bare
         * `OverflowBox` inherits the parent's height constraint, and inside a
         * row that is unbounded — its layout then asks for an infinite height
         * and the whole entry fails to lay out, which showed up as a task list
         * that rendered its heading and nothing else.
         */
        return SizedBox(
          height: height,
          child: ClipRect(
            child: OverflowBox(
              minWidth: 0,
              maxWidth: double.infinity,
              alignment: Alignment.centerLeft,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  return Transform.translate(
                    offset: Offset(-span * _controller.value, 0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(widget.text, style: widget.style, maxLines: 1),
                        const SizedBox(width: _gap),
                        /* The second copy is what makes the wrap seamless: it
                         * arrives exactly as the first leaves. */
                        Text(widget.text, style: widget.style, maxLines: 1),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One session's task list, in full.
///
/// Reads the store rather than a snapshot taken when the card was tapped, so a
/// list the agent is still working through keeps moving while it is open.
class _TodoPage extends StatelessWidget {
  const _TodoPage({required this.session});

  final RelaySession session;

  /// Label and colour for one task's status.
  static (String, Color) _statusOf(String? status, ColorScheme colors) =>
      switch (status) {
        'completed' => ('已完成', colors.onSurfaceVariant),
        'in_progress' => ('进行中', colors.primary),
        _ => ('待处理', colors.onSurface),
      };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    return WearScaffold(
      child: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final todos = session.store.todos;
          var done = 0;
          for (final todo in todos) {
            if (todo['status'] == 'completed') {
              done++;
            }
          }

          /*
           * Title first, then the tasks: the heading scrolls with the list and
           * the rows run the full width of the panel, because on a round screen
           * an inset row is narrower than the arc and wastes the middle.
           */
          return ScalingLazyColumn(
            topSpacer: 45,
            padding: const EdgeInsets.only(bottom: 50),
            itemCount: todos.length + 1,
            itemSpacing: WearTokens.itemSpacing,
            itemBuilder: (context, index, centerDistance) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: WearTokens.space2,
                  ),
                  child: Column(
                    children: <Widget>[
                      Text(
                        '任务',
                        style: text.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: WearTokens.space1),
                      Text(
                        todos.isEmpty
                            ? '这个会话还没有任务'
                            : '$done/${todos.length} 已完成',
                        style: text.bodySmall!.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                );
              }

              final todo = todos[index - 1];
              final content = '${todo['content'] ?? ''}';
              final (label, color) = _statusOf(
                todo['status'] as String?,
                colors,
              );
              final completed = todo['status'] == 'completed';

              return WearCard(
                /* No horizontal inset: the row spans the panel. */
                padding: const EdgeInsets.symmetric(
                  horizontal: WearTokens.space3,
                  vertical: WearTokens.space2,
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      completed
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color: completed
                          ? colors.onSurfaceVariant
                          : colors.primary,
                    ),
                    const SizedBox(width: WearTokens.space3),
                    Expanded(
                      child: _MarqueeText(
                        text: content,
                        style: text.titleMedium!.copyWith(
                          color: completed
                              ? colors.onSurfaceVariant
                              : colors.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(width: WearTokens.space2),
                    Text(label, style: text.labelSmall!.copyWith(color: color)),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// The DeepSeek account balance, in full.
///
/// Read through the sender from the whale-widget plugin's own endpoint. The
/// page owns its read so it can refresh on demand without disturbing the
/// settings list behind it.
class _BalancePage extends StatefulWidget {
  const _BalancePage({required this.session});

  final RelaySession session;

  @override
  State<_BalancePage> createState() => _BalancePageState();
}

class _BalancePageState extends State<_BalancePage> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    await widget.session.refreshBalance();
    if (!mounted) {
      return;
    }
    setState(() => _loading = false);
  }

  static String _money(dynamic value, String symbol) =>
      value is num ? '$symbol${value.toStringAsFixed(2)}' : '—';

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final balance = widget.session.balance;
    final ok = balance?['ok'] == true;
    final symbol = balance?['currency'] == 'CNY' ? '¥' : '';
    final peak = balance?['isPeak'] == true;
    final updated = '${balance?['updatedAt'] ?? ''}';

    return WearScaffold(
      child: ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) {
          final rows = <Widget>[
            if (_loading && balance == null)
              const Center(
                child: Padding(
                  padding: EdgeInsets.only(top: WearTokens.space4),
                  child: WearCircularProgress(size: 24, strokeWidth: 2),
                ),
              )
            else ...<Widget>[
              Center(
                child: Text(
                  ok ? _money(balance?['totalBalance'], symbol) : '—',
                  style: text.displaySmall!.copyWith(
                    color: ok ? colors.primary : colors.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: WearTokens.space3),
              _row(
                context,
                Icons.today_rounded,
                '今日已用',
                ok ? _money(balance?['todayUsage'], symbol) : '—',
              ),
              _row(
                context,
                Icons.schedule_rounded,
                '时段',
                peak ? '高峰计价' : '非高峰',
              ),
              Padding(
                padding: const EdgeInsets.only(top: WearTokens.space2),
                child: Text(
                  updated.isEmpty ? '尚未取到数据' : '更新于 $updated',
                  style: text.labelSmall!.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
            const SizedBox(height: WearTokens.space4),
            if (_loading)
              const Center(
                child: WearCircularProgress(size: 20, strokeWidth: 2),
              )
            else
              Center(
                child: WearChip(
                  label: '刷新',
                  icon: Icons.refresh_rounded,
                  onTap: _load,
                  semanticLabel: '刷新余额',
                ),
              ),
          ];

          /* The title is the column's first row rather than a fixed band, so it
           * scrolls away with the figures instead of holding the top of the
           * panel. */
          return ScalingLazyColumn(
            topSpacer: 45,
            padding: const EdgeInsets.only(bottom: 25),
            itemCount: rows.length + 1,
            itemSpacing: WearTokens.itemSpacing,
            itemBuilder: (context, index, centerDistance) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: WearTokens.space2,
                  ),
                  child: Text(
                    '余额',
                    style: text.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                );
              }
              return rows[index - 1];
            },
          );
        },
      ),
    );
  }

  Widget _row(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: WearTokens.space2),
      child: WearCard(
        padding: const EdgeInsets.symmetric(
          horizontal: WearTokens.space3,
          vertical: WearTokens.space2,
        ),
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
        title: title,
        subtitle: subtitle,
        semanticLabel: '$title $subtitle',
      ),
    );
  }
}

/// Reads one value out of a nested settings document by path.
///
/// Providers are addressed as `settingsNs` + `settingsPath`, so every read and
/// write on this page is one walk down that path.
dynamic settingsAtPath(dynamic node, List<String> path) {
  dynamic current = node;
  for (final key in path) {
    if (current is! Map<String, dynamic>) {
      return null;
    }
    current = current[key];
  }
  return current;
}

/// The settings namespaces, keyed by name.
Map<String, dynamic> namespacesOf(Map<String, dynamic>? described) {
  final out = <String, dynamic>{};
  final list = described?['namespaces'];
  if (list is List) {
    for (final entry in list.whereType<Map<String, dynamic>>()) {
      final ns = entry['ns'];
      if (ns is String) {
        out[ns] = entry;
      }
    }
  }
  return out;
}

/// Every provider the deployment could be configured to talk to.
class _ProvidersPage extends StatefulWidget {
  const _ProvidersPage({required this.session});

  final RelaySession session;

  @override
  State<_ProvidersPage> createState() => _ProvidersPageState();
}

class _ProvidersPageState extends State<_ProvidersPage> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _providers = const <Map<String, dynamic>>[];
  Map<String, dynamic> _namespaces = const <String, dynamic>{};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final described = await widget.session.settingsDescribe();
    final providers = await widget.session.configurableProviders();
    if (!mounted) {
      return;
    }
    setState(() {
      _providers = providers;
      _namespaces = namespacesOf(described);
      _loading = false;
      _error = providers.isEmpty ? widget.session.lastError : null;
    });
  }

  /// Opens the editor and reloads afterwards: a save changes the rows this list
  /// is derived from.
  Future<void> _edit(Map<String, dynamic> provider) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            _ProviderEditorPage(session: widget.session, provider: provider),
      ),
    );
    if (mounted) {
      await _load();
    }
  }

  /// Whether this provider already carries configuration in the user layer.
  bool _configured(Map<String, dynamic> provider) {
    final ns = '${provider['settingsNs'] ?? ''}';
    final path = (provider['settingsPath'] as List? ?? const [])
        .whereType<String>()
        .toList(growable: false);
    final entry = _namespaces[ns];
    if (entry is! Map<String, dynamic>) {
      return false;
    }
    return settingsAtPath(entry['user'], path) is Map;
  }

  /// The providers that have been added, which is what this page lists.
  ///
  /// The directory carries every route the adapter could serve — nearly forty
  /// built-ins a user never added — so listing it whole would be a catalogue
  /// rather than this deployment's setup. Adding one is what the button above
  /// the list is for.
  List<Map<String, dynamic>> get _added =>
      _providers.where(_configured).toList(growable: false);

  Future<void> _add() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => _AddProviderPage(
          session: widget.session,
          available: _providers
              .where((p) => !_configured(p))
              .toList(growable: false),
        ),
      ),
    );
    if (mounted && changed == true) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    /* Title, button and rows are one column, so the heading scrolls away with
     * the list instead of holding a band of its own at the top. */
    return WearScaffold(
      timeTextController: _scroll,
      overlays: <Widget>[PositionIndicator(controller: _scroll)],
      child: _loading
          ? const Center(child: WearCircularProgress(size: 24, strokeWidth: 2))
          : ScalingLazyColumn(
              controller: _scroll,
              topSpacer: 45,
              padding: const EdgeInsets.only(bottom: 25),
              itemCount: _added.length + (_error == null ? 2 : 3),
              itemSpacing: WearTokens.itemSpacing,
              itemBuilder: (context, index, centerDistance) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: WearTokens.space2,
                    ),
                    child: Column(
                      children: <Widget>[
                        Text(
                          '模型提供方',
                          style: text.titleMedium,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: WearTokens.space1),
                        Text(
                          '已添加 ${_added.length} 个',
                          style: text.bodySmall!.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                }
                if (index == 1) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: WearTokens.space2),
                    child: Center(
                      child: WearChip(
                        label: '添加模型提供商',
                        icon: Icons.add_rounded,
                        selected: true,
                        onTap: _add,
                        semanticLabel: '添加模型提供商',
                      ),
                    ),
                  );
                }
                final row = index - 2;
                if (row >= _added.length) {
                  return Text(
                    _error!,
                    style: text.labelSmall!.copyWith(color: colors.error),
                    textAlign: TextAlign.center,
                  );
                }
                final provider = _added[row];
                final id = '${provider['provider'] ?? ''}';
                final label = '${provider['displayName'] ?? id}';

                /* A settings-style row, matching the cards this page was
                 * reached through: a pill reads as a filter, and these are
                 * entries that open an editor. */
                return WearCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: WearTokens.space3,
                    vertical: WearTokens.space2,
                  ),
                  leading: Icon(
                    Icons.cloud_done_rounded,
                    color: colors.primary,
                  ),
                  title: label,
                  subtitle: id,
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _edit(provider),
                  semanticLabel: '$label，已添加，点按编辑',
                );
              },
            ),
    );
  }
}

/// The two ways a provider gets added.
///
/// A catalog route already exists as far as the adapter is concerned — it only
/// lacks configuration — while a custom one is declared from nothing. That is
/// the whole difference between the two paths, and the reason they are offered
/// as a choice rather than as one form.
class _AddProviderPage extends StatelessWidget {
  const _AddProviderPage({required this.session, required this.available});

  final RelaySession session;
  final List<Map<String, dynamic>> available;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    /* Title as the column's first row, so it scrolls with the choices. */
    return WearScaffold(
      child: ScalingLazyColumn(
        topSpacer: 45,
        padding: const EdgeInsets.only(bottom: 25),
        itemCount: 3,
        itemSpacing: WearTokens.itemSpacing,
        itemBuilder: (context, index, centerDistance) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: WearTokens.space2),
              child: Text(
                '添加模型提供商',
                style: text.titleMedium,
                textAlign: TextAlign.center,
              ),
            );
          }
          if (index == 1) {
            return WearCard(
              padding: const EdgeInsets.symmetric(
                horizontal: WearTokens.space3,
                vertical: WearTokens.space2,
              ),
              leading: Icon(Icons.list_alt_rounded, color: colors.primary),
              title: '添加提供商',
              subtitle: '从内置目录中选择（${available.length} 个可选）',
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () async {
                final added = await Navigator.of(context).push<bool>(
                  MaterialPageRoute<bool>(
                    builder: (_) => _ProviderPickerPage(
                      session: session,
                      candidates: available,
                    ),
                  ),
                );
                if (context.mounted && added == true) {
                  Navigator.of(context).pop(true);
                }
              },
              semanticLabel: '添加提供商',
            );
          }
          return WearCard(
            padding: const EdgeInsets.symmetric(
              horizontal: WearTokens.space3,
              vertical: WearTokens.space2,
            ),
            leading: Icon(Icons.build_outlined, color: colors.primary),
            title: '添加自定义提供商',
            subtitle: '手动填写地址、协议与模型',
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () async {
              final added = await Navigator.of(context).push<bool>(
                MaterialPageRoute<bool>(
                  builder: (_) => _CustomProviderPage(session: session),
                ),
              );
              if (context.mounted && added == true) {
                Navigator.of(context).pop(true);
              }
            },
            semanticLabel: '添加自定义提供商',
          );
        },
      ),
    );
  }
}

/// The catalog routes still lacking configuration.
class _ProviderPickerPage extends StatelessWidget {
  const _ProviderPickerPage({required this.session, required this.candidates});

  final RelaySession session;
  final List<Map<String, dynamic>> candidates;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    return WearScaffold(
      child: ScalingLazyColumn(
        topSpacer: 45,
        padding: const EdgeInsets.only(bottom: 25),
        itemCount: candidates.length + 1,
        itemSpacing: WearTokens.itemSpacing,
        itemBuilder: (context, index, centerDistance) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: WearTokens.space2),
              child: Text(
                '选择提供商',
                style: text.titleMedium,
                textAlign: TextAlign.center,
              ),
            );
          }
          final provider = candidates[index - 1];
          final id = '${provider['provider'] ?? ''}';
          final label = '${provider['displayName'] ?? id}';
          return WearCard(
            padding: const EdgeInsets.symmetric(
              horizontal: WearTokens.space3,
              vertical: WearTokens.space2,
            ),
            leading: Icon(Icons.add_circle_outline, color: colors.primary),
            title: label,
            subtitle: id,
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () async {
              final saved = await Navigator.of(context).push<bool>(
                MaterialPageRoute<bool>(
                  builder: (_) =>
                      _ProviderEditorPage(session: session, provider: provider),
                ),
              );
              if (context.mounted && saved == true) {
                Navigator.of(context).pop(true);
              }
            },
            semanticLabel: '添加 $label',
          );
        },
      ),
    );
  }
}

/// Declares a provider the catalog does not ship.
class _CustomProviderPage extends StatefulWidget {
  const _CustomProviderPage({required this.session});

  final RelaySession session;

  @override
  State<_CustomProviderPage> createState() => _CustomProviderPageState();
}

class _CustomProviderPageState extends State<_CustomProviderPage> {
  /* The three wire protocols the adapter serves; the profile names one, and a
   * hand-declared route cannot be defaulted into the right one. */
  static const List<String> _protocols = <String>[
    'openai-completions',
    'openai-responses',
    'anthropic-messages',
  ];

  /// A route id usable as a settings key and as the stem of a credential name.
  ///
  /// The leading letter is the second half of that: the credential reference is
  /// the uppercased id, and a POSIX shell identifier cannot start with a digit.
  static final RegExp _routePattern = RegExp(
    r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$',
  );

  final TextEditingController _route = TextEditingController();
  final TextEditingController _displayName = TextEditingController();
  final TextEditingController _baseUrl = TextEditingController();
  final TextEditingController _apiKey = TextEditingController();
  final TextEditingController _models = TextEditingController();

  String _protocol = _protocols.first;
  int _revision = 0;
  bool _loading = true;
  bool _saving = false;
  bool _discovering = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _route.dispose();
    _displayName.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _models.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final described = await widget.session.settingsDescribe();
    if (!mounted) {
      return;
    }
    final entry = namespacesOf(described)['llm-pi-ai'];
    setState(() {
      if (entry is Map<String, dynamic>) {
        final r = entry['revision'];
        _revision = r is int ? r : 0;
      }
      _loading = false;
    });
  }

  /// Asks the endpoint itself which models it serves.
  ///
  /// The Host performs the call, so a key typed here works before anything is
  /// saved — which is the point: you can find out whether the endpoint and key
  /// are right while still filling the form in.
  Future<void> _discover() async {
    final baseURL = _baseUrl.text.trim();
    if (baseURL.isEmpty) {
      setState(() => _error = '先填服务地址');
      return;
    }
    setState(() {
      _discovering = true;
      _error = null;
    });
    final models = await widget.session.discoverModels(
      'llm-pi-ai',
      baseURL: baseURL,
      api: _protocol,
      apiKey: _apiKey.text.trim(),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _discovering = false;
      if (models.isEmpty) {
        _error = widget.session.lastError ?? '没有获取到模型';
        return;
      }
      _models.text = models
          .map((model) => '${model['id'] ?? ''}')
          .where((id) => id.isNotEmpty)
          .join('\n');
    });
  }

  Future<void> _create() async {
    final route = _route.text.trim();
    final ids = _models.text
        .split(RegExp('[\\n,]'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);

    if (!_routePattern.hasMatch(route)) {
      setState(() => _error = '路由名只能是小写字母、数字和连字符，且以字母开头');
      return;
    }
    if (_baseUrl.text.trim().isEmpty) {
      setState(() => _error = '服务地址不能为空');
      return;
    }
    if (ids.isEmpty) {
      setState(() => _error = '至少填一个模型 id');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final key = _apiKey.text.trim();
    final credentialRef = route.toUpperCase().replaceAll(
      RegExp('[^A-Z0-9]'),
      '_',
    );
    final profile = <String, dynamic>{
      'api': _protocol,
      'baseURL': _baseUrl.text.trim(),
      'models': [
        for (final id in ids) {'id': id},
      ],
      if (_displayName.text.trim().isNotEmpty)
        'displayName': _displayName.text.trim(),
      /* The reference is recorded only when a key is actually being stored: a
       * route left keyless keeps its provider-native auth path instead of
       * resolving a reference nothing ever sets. */
      if (key.isNotEmpty) 'apiKeyEnv': credentialRef,
    };

    final written = await widget.session.mutateSettings(
      'llm-pi-ai',
      <Map<String, dynamic>>[
        {
          'op': 'set',
          'path': ['providers', route],
          'value': profile,
        },
      ],
      _revision,
    );
    if (!mounted) {
      return;
    }
    if (!written) {
      setState(() {
        _saving = false;
        _error = widget.session.lastError;
      });
      return;
    }
    if (key.isNotEmpty) {
      final stored = await widget.session.setCredential(credentialRef, key);
      if (!mounted) {
        return;
      }
      if (!stored) {
        setState(() {
          _saving = false;
          _error = widget.session.lastError;
        });
        return;
      }
    }
    if (mounted) {
      setState(() => _saving = false);
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    return WearScaffold(
      child: _loading
          ? const Center(child: WearCircularProgress(size: 24, strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: WearTokens.space5,
                vertical: WearTokens.space5,
              ),
              children: <Widget>[
                Text(
                  '自定义提供商',
                  style: text.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: WearTokens.space3),
                Text('路由名', style: text.labelMedium),
                TextField(
                  controller: _route,
                  style: text.bodySmall,
                  textInputAction: TextInputAction.none,
                  decoration: const InputDecoration(
                    hintText: 'acme-gateway',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: WearTokens.space3),
                Text('显示名称（可选）', style: text.labelMedium),
                TextField(
                  controller: _displayName,
                  style: text.bodySmall,
                  textInputAction: TextInputAction.none,
                  decoration: const InputDecoration(
                    hintText: '留空则用路由名',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: WearTokens.space3),
                Text('服务地址', style: text.labelMedium),
                TextField(
                  controller: _baseUrl,
                  style: text.bodySmall,
                  textInputAction: TextInputAction.none,
                  decoration: const InputDecoration(
                    hintText: 'https://example.com/v1',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: WearTokens.space3),
                Text('协议', style: text.labelMedium),
                const SizedBox(height: WearTokens.space1),
                WearChipRow(
                  alignment: WrapAlignment.start,
                  children: <Widget>[
                    for (final protocol in _protocols)
                      WearChip(
                        label: protocol,
                        selected: _protocol == protocol,
                        onTap: () => setState(() => _protocol = protocol),
                      ),
                  ],
                ),
                const SizedBox(height: WearTokens.space3),
                Text('API Key（可选）', style: text.labelMedium),
                TextField(
                  controller: _apiKey,
                  style: text.bodySmall,
                  obscureText: true,
                  textInputAction: TextInputAction.none,
                  decoration: const InputDecoration(
                    hintText: '留空则该路由不存密钥',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: WearTokens.space3),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text('模型（每行一个 id）', style: text.labelMedium),
                    ),
                    if (_discovering)
                      const WearCircularProgress(size: 16, strokeWidth: 2)
                    else
                      WearChip(
                        label: '自动获取',
                        icon: Icons.cloud_download_rounded,
                        onTap: _discover,
                        semanticLabel: '自动获取可用模型',
                      ),
                  ],
                ),
                const SizedBox(height: WearTokens.space1),
                TextField(
                  controller: _models,
                  style: text.bodySmall,
                  minLines: 3,
                  maxLines: 8,
                  textInputAction: TextInputAction.none,
                  decoration: const InputDecoration(
                    hintText: 'deepseek-v4-flash',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: WearTokens.space4),
                if (_saving)
                  const Center(
                    child: WearCircularProgress(size: 20, strokeWidth: 2),
                  )
                else
                  Center(
                    child: WearChip(
                      label: '创建',
                      icon: Icons.add_rounded,
                      selected: true,
                      onTap: _create,
                    ),
                  ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: WearTokens.space3),
                  Text(
                    _error!,
                    style: text.labelSmall!.copyWith(color: colors.error),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
    );
  }
}

/// Edits one provider: its endpoint, its credential and its model list.
///
/// The write is a single path-addressed op into the provider's settings
/// namespace, built from the revision this page read — so a change made
/// elsewhere while the page was open is refused rather than overwritten.
class _ProviderEditorPage extends StatefulWidget {
  const _ProviderEditorPage({required this.session, required this.provider});

  final RelaySession session;
  final Map<String, dynamic> provider;

  @override
  State<_ProviderEditorPage> createState() => _ProviderEditorPageState();
}

class _ProviderEditorPageState extends State<_ProviderEditorPage> {
  final TextEditingController _baseUrl = TextEditingController();
  final TextEditingController _apiKey = TextEditingController();
  final TextEditingController _models = TextEditingController();

  String _credentialRef = '';
  int _revision = 0;
  bool _loading = true;
  bool _saving = false;
  bool _discovering = false;
  String? _error;

  String get _ns => '${widget.provider['settingsNs'] ?? ''}';

  List<String> get _path =>
      (widget.provider['settingsPath'] as List? ?? const [])
          .whereType<String>()
          .toList(growable: false);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _models.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final described = await widget.session.settingsDescribe();
    if (!mounted) {
      return;
    }
    final entry = namespacesOf(described)[_ns];
    var revision = 0;
    dynamic user;
    dynamic value;
    if (entry is Map<String, dynamic>) {
      final r = entry['revision'];
      revision = r is int ? r : 0;
      user = entry['user'];
      value = entry['value'];
    }
    /* The user layer wins where it exists: that is the layer a write lands in,
     * and showing the merged value would hide what is actually stored. */
    final mine = settingsAtPath(user, _path);
    final current = mine is Map<String, dynamic>
        ? mine
        : settingsAtPath(value, _path);
    final config = current is Map<String, dynamic>
        ? current
        : const <String, dynamic>{};
    final models = config['models'];

    setState(() {
      _revision = revision;
      _baseUrl.text = '${config['baseURL'] ?? ''}';
      final ref = config['apiKeyEnv'];
      _credentialRef = ref is String && ref.isNotEmpty
          ? ref
          : '${widget.provider['provider'] ?? 'PROVIDER'}'
                .toUpperCase()
                .replaceAll(RegExp('[^A-Z0-9]'), '_');
      _models.text = models is List
          ? models
                .whereType<Map<String, dynamic>>()
                .map((m) => '${m['id'] ?? ''}')
                .where((id) => id.isNotEmpty)
                .join('\n')
          : '';
      _loading = false;
    });
  }

  /// Asks the endpoint itself which models it serves — see _CustomProviderPage.
  Future<void> _discover() async {
    final baseURL = _baseUrl.text.trim();
    if (baseURL.isEmpty) {
      setState(() => _error = '先填服务地址');
      return;
    }
    setState(() {
      _discovering = true;
      _error = null;
    });
    final models = await widget.session.discoverModels(
      _ns,
      baseURL: baseURL,
      api: '${widget.provider['api'] ?? 'openai-completions'}',
      apiKey: _apiKey.text.trim(),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _discovering = false;
      if (models.isEmpty) {
        _error = widget.session.lastError ?? '没有获取到模型';
        return;
      }
      _models.text = models
          .map((model) => '${model['id'] ?? ''}')
          .where((id) => id.isNotEmpty)
          .join('\n');
    });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final ids = _models.text
        .split(RegExp('[\\n,]'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    final ok = await widget.session.mutateSettings(_ns, <Map<String, dynamic>>[
      {
        'op': 'set',
        'path': _path,
        'value': {
          'baseURL': _baseUrl.text.trim(),
          'apiKeyEnv': _credentialRef,
          if (ids.isNotEmpty)
            'models': [
              for (final id in ids) {'id': id},
            ],
        },
      },
    ], _revision);
    if (!mounted) {
      return;
    }
    if (!ok) {
      setState(() {
        _saving = false;
        _error = widget.session.lastError;
      });
      return;
    }
    /* The secret is stored on its own, by reference: the settings document
     * carries only the reference, so a key never lands in a file that is read
     * back to every client. */
    final key = _apiKey.text.trim();
    if (key.isNotEmpty) {
      final stored = await widget.session.setCredential(_credentialRef, key);
      if (!mounted) {
        return;
      }
      if (!stored) {
        setState(() {
          _saving = false;
          _error = widget.session.lastError;
        });
        return;
      }
    }
    if (mounted) {
      setState(() => _saving = false);
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    return WearScaffold(
      child: _loading
          ? const Center(child: WearCircularProgress(size: 24, strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: WearTokens.space5,
                vertical: WearTokens.space5,
              ),
              children: <Widget>[
                Text(
                  '${widget.provider['displayName'] ?? widget.provider['provider'] ?? ''}',
                  style: text.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: WearTokens.space1),
                Text(
                  '$_ns${_path.isEmpty ? '' : ' · ${_path.join('/')}'}',
                  style: text.labelSmall!.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: WearTokens.space3),
                Text('服务地址', style: text.labelMedium),
                TextField(
                  controller: _baseUrl,
                  style: text.bodySmall,
                  textInputAction: TextInputAction.none,
                  decoration: const InputDecoration(
                    hintText: 'https://example.com/v1',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: WearTokens.space3),
                Text('API Key（凭据名 $_credentialRef）', style: text.labelMedium),
                TextField(
                  controller: _apiKey,
                  style: text.bodySmall,
                  obscureText: true,
                  textInputAction: TextInputAction.none,
                  decoration: const InputDecoration(
                    hintText: '留空则不改动已存的密钥',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: WearTokens.space3),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text('模型（每行一个 id）', style: text.labelMedium),
                    ),
                    if (_discovering)
                      const WearCircularProgress(size: 16, strokeWidth: 2)
                    else
                      WearChip(
                        label: '自动获取',
                        icon: Icons.cloud_download_rounded,
                        onTap: _discover,
                        semanticLabel: '自动获取可用模型',
                      ),
                  ],
                ),
                const SizedBox(height: WearTokens.space1),
                TextField(
                  controller: _models,
                  style: text.bodySmall,
                  minLines: 3,
                  maxLines: 8,
                  textInputAction: TextInputAction.none,
                  decoration: const InputDecoration(
                    hintText: 'deepseek-v4-flash',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: WearTokens.space4),
                if (_saving)
                  const Center(
                    child: WearCircularProgress(size: 20, strokeWidth: 2),
                  )
                else
                  Center(
                    child: WearChip(
                      label: '保存',
                      icon: Icons.check_rounded,
                      selected: true,
                      onTap: _save,
                    ),
                  ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: WearTokens.space3),
                  Text(
                    _error!,
                    style: text.labelSmall!.copyWith(color: colors.error),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
    );
  }
}

/// A full-screen prompt for rewriting the goal's objective.
class _GoalTextPage extends StatelessWidget {
  const _GoalTextPage({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return WearScaffold(
      child: Padding(
        padding: WearTokens.promptInsets,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('修改目标', style: text.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: WearTokens.space2),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 4,
              minLines: 2,
              style: text.bodyMedium,
              textInputAction: TextInputAction.none,
              decoration: const InputDecoration(
                hintText: '目标内容',
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
                  label: '保存',
                  icon: Icons.check_rounded,
                  selected: true,
                  onTap: () {
                    final value = controller.text.trim();
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
