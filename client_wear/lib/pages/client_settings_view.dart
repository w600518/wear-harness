import 'package:flutter/material.dart';

import '../state/relay_session.dart';
import '../wear_m3/wear_m3.dart';

/// Shown on the settings row and on the About page.
const String kAppVersion = 'V1.0.1';

/// Page 3: the client's own settings — where the relay is, what secret unlocks
/// it, and how this watch identifies itself.
///
/// Nothing here is mirrored from dsh; the remote side's settings live on page 2.
///
/// Fields are rows, not live text inputs. A `TextField` claims horizontal drags
/// for cursor movement, which on a watch leaves almost no surface left to swipe
/// between pages; tapping a row opens a dedicated input page instead, where the
/// keyboard has the whole screen.
class ClientSettingsView extends StatefulWidget {
  const ClientSettingsView({
    super.key,
    required this.session,
    required this.scrollController,
  });

  final RelaySession session;
  final ScrollController scrollController;

  @override
  State<ClientSettingsView> createState() => _ClientSettingsViewState();
}

class _ClientSettingsViewState extends State<ClientSettingsView> {
  /// True while an explicit refresh is in flight.
  bool _refreshing = false;

  /// Re-reads everything mirrored from the sender, showing progress meanwhile.
  Future<void> _refreshAll() async {
    setState(() => _refreshing = true);
    try {
      await widget.session.refreshAll();
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
      }
    }
  }

  Future<String?> _edit({
    required String label,
    required String initial,
    required String hint,
    bool secret = false,
    TextInputType keyboard = TextInputType.text,
  }) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => _TextInputPage(
          label: label,
          initial: initial,
          hint: hint,
          secret: secret,
          keyboard: keyboard,
        ),
      ),
    );
  }

  Future<void> _connect() async {
    await widget.session.connect();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _disconnect() async {
    await widget.session.disconnect();
    if (mounted) {
      setState(() {});
    }
  }

  String _mask(String value) => value.isEmpty ? '' : '•' * value.length;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final session = widget.session;
        final settings = session.settings;

        return Stack(
          children: <Widget>[
            ScalingLazyColumn(
              controller: widget.scrollController,
              topSpacer: 60,
              padding: const EdgeInsets.only(bottom: 25),
              itemCount: 8,
              itemSpacing: WearTokens.itemSpacing,
              itemBuilder: (context, index, centerDistance) {
                switch (index) {
                  case 0:
                    return _statusCard(session);
                  case 1:
                    return _fieldRow(
                      label: '服务器地址',
                      value: settings.host,
                      hint: '192.168.1.10',
                      keyboard: TextInputType.url,
                      onSave: (value) => settings.host = value,
                    );
                  case 2:
                    return _fieldRow(
                      label: '客户端端口',
                      /* Blank until the user fills it in: the port belongs to
                       * their relay, and showing a pre-filled one would look
                       * like a value that had been checked. */
                      value: settings.port > 0 ? '${settings.port}' : '',
                      hint: '7778',
                      keyboard: TextInputType.number,
                      onSave: (value) {
                        final port = int.tryParse(value.trim());
                        if (port != null && port > 0 && port <= 65535) {
                          settings.port = port;
                        }
                      },
                    );
                  case 3:
                    return _fieldRow(
                      label: '口令',
                      value: settings.passphrase,
                      hint: '至少 8 位',
                      secret: true,
                      onSave: (value) => settings.passphrase = value,
                    );
                  case 4:
                    return _fieldRow(
                      label: '设备名',
                      value: settings.deviceName,
                      hint: 'wear',
                      onSave: (value) => settings.deviceName = value,
                    );
                  case 5:
                    return WearCard(
                      leading: Icon(
                        session.isBusy
                            ? Icons.link_off_rounded
                            : Icons.link_rounded,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      title: session.isBusy ? '断开连接' : '连接中继',
                      subtitle: session.settings.isComplete
                          ? '${session.settings.host}:${session.settings.port}'
                          : '请先填写完整',
                      onTap: session.isBusy ? _disconnect : _connect,
                      semanticLabel: session.isBusy ? '断开连接' : '连接中继',
                    );
                  case 6:
                    /*
                     * Forces a re-read of everything mirrored from the sender.
                     * For a page that looks stale: the alternative is waiting
                     * for the next poll, with no way to tell whether the data
                     * is old or the other end has nothing to say.
                     */
                    return WearCard(
                      leading: Icon(
                        _refreshing
                            ? Icons.hourglass_top_rounded
                            : Icons.refresh_rounded,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      title: '重新拉取信息',
                      subtitle: _refreshing ? '正在拉取…' : '重新读取状态、会话列表与当前会话',
                      onTap: session.isConnected && !_refreshing
                          ? _refreshAll
                          : null,
                      semanticLabel: '重新拉取信息',
                    );
                  case 7:
                    return WearCard(
                      leading: Icon(
                        Icons.info_outline_rounded,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      title: '关于',
                      subtitle: 'Wear Harness $kAppVersion',
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const _AboutPage(),
                        ),
                      ),
                      semanticLabel: '关于 Wear Harness $kAppVersion',
                    );
                  default:
                    return const SizedBox.shrink();
                }
              },
            ),
          ],
        );
      },
    );
  }

  Widget _statusCard(RelaySession session) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final (IconData icon, String label, Color color) = switch (session.status) {
      RelayStatus.connected => (
        Icons.check_circle_rounded,
        '已连接',
        colors.primary,
      ),
      RelayStatus.connecting => (Icons.sync_rounded, '连接中', colors.tertiary),
      RelayStatus.failed => (Icons.error_rounded, '失败', colors.error),
      RelayStatus.frameRejected => (
        Icons.shield_rounded,
        '拒绝异常帧',
        colors.error,
      ),
      RelayStatus.disconnected => (
        Icons.cloud_off_rounded,
        '未连接',
        colors.onSurfaceVariant,
      ),
    };

    /*
     * Same padding and row shape as the field rows below. The status card used
     * to carry its own all-round inset, which made it taller than everything
     * else — so as the list scrolled and the rows scaled, this one looked like
     * it was sitting outside the effect rather than being part of the list.
     */
    return WearCard(
      padding: const EdgeInsets.symmetric(
        horizontal: WearTokens.space3,
        vertical: WearTokens.space2,
      ),
      semanticLabel: session.lastError == null
          ? label
          : '$label：${session.lastError}',
      child: Row(
        children: <Widget>[
          Icon(icon, color: color, size: 26),
          const SizedBox(width: WearTokens.space2),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: text.titleLarge!.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (session.lastError != null)
                  Text(
                    session.lastError!,
                    style: text.bodySmall!.copyWith(color: colors.error),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fieldRow({
    required String label,
    required String value,
    required String hint,
    required ValueChanged<String> onSave,
    bool secret = false,
    TextInputType keyboard = TextInputType.text,
  }) {
    final shown = secret ? _mask(value) : value;
    final empty = value.isEmpty;

    return WearCard(
      padding: const EdgeInsets.symmetric(
        horizontal: WearTokens.space3,
        vertical: WearTokens.space2,
      ),
      leading: Icon(
        Icons.edit_rounded,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        size: 18,
      ),
      title: label,
      subtitle: empty ? hint : shown,
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () async {
        final result = await _edit(
          label: label,
          initial: value,
          hint: hint,
          secret: secret,
          keyboard: keyboard,
        );
        if (result != null) {
          onSave(result);
          if (mounted) {
            setState(() {});
          }
        }
      },
      semanticLabel: '$label，${empty ? hint : shown}',
    );
  }
}

/// A full-screen prompt for one settings value.
///
/// Owning the whole screen is what makes this work on a watch: the field, the
/// keyboard and the two actions never compete with a page swipe.
class _TextInputPage extends StatefulWidget {
  const _TextInputPage({
    required this.label,
    required this.initial,
    required this.hint,
    required this.secret,
    required this.keyboard,
  });

  final String label;
  final String initial;
  final String hint;
  final bool secret;
  final TextInputType keyboard;

  @override
  State<_TextInputPage> createState() => _TextInputPageState();
}

class _TextInputPageState extends State<_TextInputPage> {
  late final TextEditingController _controller;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
    _obscure = widget.secret;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    Navigator.of(context).pop(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final scroll = ScrollController();
    final text = Theme.of(context).textTheme;

    return WearScaffold(
      timeTextController: scroll,
      child: ScalingLazyColumn(
        controller: scroll,
        topSpacer: 60,
        padding: const EdgeInsets.only(bottom: 25),
        itemCount: 3,
        itemSpacing: WearTokens.itemSpacing,
        itemBuilder: (context, index, centerDistance) {
          switch (index) {
            case 0:
              return Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: WearTokens.space2,
                ),
                child: Text(widget.label, style: text.titleMedium),
              );
            case 1:
              return WearCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: WearTokens.space3,
                  vertical: WearTokens.space2,
                ),
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  obscureText: _obscure,
                  keyboardType: widget.keyboard,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _save(),
                  style: text.bodyMedium,
                  decoration: InputDecoration(
                    hintText: widget.hint,
                    isDense: true,
                    border: InputBorder.none,
                    suffixIcon: widget.secret
                        ? IconButton(
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_rounded
                                  : Icons.visibility_off_rounded,
                            ),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                            tooltip: _obscure ? '显示' : '隐藏',
                          )
                        : null,
                  ),
                ),
              );
            default:
              return WearChipRow(
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
                    onTap: _save,
                  ),
                ],
              );
          }
        },
      ),
    );
  }
}

/// What this app is, who built it, and where its parts came from.
///
/// The balance figure gets its own line rather than a footnote: it is the one
/// feature that reads from somebody else's plugin instead of from dsh, and the
/// people who wrote that plugin are worth naming where a user can see it.
class _AboutPage extends StatelessWidget {
  const _AboutPage();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    return WearScaffold(
      child: ScalingLazyColumn(
        topSpacer: 45,
        padding: const EdgeInsets.only(bottom: 25),
        itemCount: 4,
        itemSpacing: WearTokens.itemSpacing,
        itemBuilder: (context, index, centerDistance) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: WearTokens.space2),
              child: Text(
                '关于',
                style: text.titleMedium,
                textAlign: TextAlign.center,
              ),
            );
          }
          if (index == 1) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: WearTokens.space2),
              child: Column(
                children: <Widget>[
                  Text(
                    'Wear Harness',
                    style: text.titleLarge!.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: WearTokens.space1),
                  Text(
                    kAppVersion,
                    style: text.labelMedium!.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }
          if (index == 2) {
            return _row(context, Icons.person_outline_rounded, '制作者', '真不玩喷');
          }
          return _row(
            context,
            Icons.volunteer_activism_outlined,
            '余额技术方法来源',
            'MeteorNOX/DeepSeek-Balance-Whale-Widget',
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
    return WearCard(
      padding: const EdgeInsets.symmetric(
        horizontal: WearTokens.space3,
        vertical: WearTokens.space2,
      ),
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: title,
      subtitle: subtitle,
      semanticLabel: '$title $subtitle',
    );
  }
}
