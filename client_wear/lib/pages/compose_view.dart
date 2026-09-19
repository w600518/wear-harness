import 'dart:async';

import 'package:flutter/material.dart';

import '../relay/session_store.dart';
import '../state/active_listenable_builder.dart';
import '../state/relay_session.dart';
import '../wear_m3/wear_m3.dart';

/// One message plus the tool calls it produced.
///
/// The transcript arrives as a flat event list; grouping happens at render time
/// so the store stays a faithful record of what dsh sent.
class _Turn {
  _Turn(this.item);

  final ChatItem item;
  final List<ToolCallItem> tools = <ToolCallItem>[];
}

/// Pulls the single most informative argument out of a tool call.
///
/// Top level because both the bubble's collapsed header and the detail page
/// show it.
String _summarizeArguments(String arguments) {
  if (arguments.isEmpty || arguments == 'null') {
    return '';
  }
  final match = RegExp(
    r'"(?:file_path|path|command|pattern|url|description|prompt)"\s*:\s*"((?:[^"\\]|\\.)*)"',
  ).firstMatch(arguments);
  if (match != null) {
    return match.group(1)!.replaceAll(r'\n', ' ').replaceAll(r'\"', '"');
  }
  return arguments.length > 120 ? '${arguments.substring(0, 120)}…' : arguments;
}

/// Lines of a block on the detail page shown before it folds.
const int _detailFoldLines = 8;

/// Whether [body] is cut off when laid out at [maxWidth] under [maxLines].
///
/// Asked of the same text engine the [Text] widget will use, and answered by
/// `didExceedMaxLines` — the layout pass's own verdict on "was this clipped".
/// Counting measured lines and comparing them against the cap instead left the
/// two disagreeing right at the boundary, which is the difference between a
/// block that can be opened and one that is stuck with its tail hidden.
bool _exceedsFold(
  String body,
  TextStyle style,
  double maxWidth, {
  int maxLines = _detailFoldLines,
}) {
  if (maxWidth <= 0 || body.isEmpty) {
    return false;
  }
  final painter = TextPainter(
    text: TextSpan(text: body, style: style),
    maxLines: maxLines,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: maxWidth);
  final exceeds = painter.didExceedMaxLines;
  painter.dispose();
  return exceeds;
}

/// The full record of one assistant reply: answer, reasoning, tool calls.
///
/// Reached from the button in a message's top-right corner. It gets the whole
/// panel and its own scroll position, which is the room a transcript of
/// reasoning and a list of tool calls needs.
///
/// Every block folds past [_detailFoldLines] for the same reason the reply
/// folds in the transcript: one long answer or one tool result should not push
/// everything else off a 233 dp screen. Tap a block to open it.
class _MessageDetailPage extends StatefulWidget {
  const _MessageDetailPage({required this.item, required this.tools});

  final AssistantMessageItem item;
  final List<ToolCallItem> tools;

  @override
  State<_MessageDetailPage> createState() => _MessageDetailPageState();
}

class _MessageDetailPageState extends State<_MessageDetailPage> {
  /// Keys of the blocks the user has opened.
  ///
  /// Held here rather than inside each block because the list needs to know: an
  /// expanded block is wrapped in [UnscaledItem] so the scroll scale leaves it
  /// alone. A block that owned its own state could not tell the list anything.
  final Set<String> _open = <String>{};

  /// Owned for the whole route rather than rebuilt with it.
  ///
  /// Opening a block calls setState, so a controller created inside build()
  /// would be replaced on every expand: the list and its position indicator
  /// would rebind to a fresh one, losing the scroll offset and the scale
  /// synchronisation that were driving them.
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _toggle(String key) {
    setState(() {
      if (_open.contains(key)) {
        _open.remove(key);
      } else {
        _open.add(key);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final tools = widget.tools;
    final scroll = _scroll;
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    /// Wraps a block so it keeps full size while it is open.
    Widget block(String key, Widget child) =>
        _open.contains(key) ? UnscaledItem(child: child) : child;

    final blocks = <Widget>[
      if (item.text.isNotEmpty)
        block(
          'answer',
          _DetailSection(
            icon: Icons.auto_awesome_rounded,
            title: '回答',
            body: item.text,
            expanded: _open.contains('answer'),
            onToggle: () => _toggle('answer'),
          ),
        ),
      if (item.reasoning.isNotEmpty)
        block(
          'reasoning',
          _DetailSection(
            icon: Icons.psychology_outlined,
            title: '思考过程',
            body: item.reasoning,
            expanded: _open.contains('reasoning'),
            onToggle: () => _toggle('reasoning'),
          ),
        ),
      if (tools.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: WearTokens.space2),
          child: Text('工具调用 · ${tools.length} 次', style: text.labelMedium),
        ),
      for (var i = 0; i < tools.length; i++)
        block(
          'tool$i',
          _ToolDetail(
            item: tools[i],
            expanded: _open.contains('tool$i'),
            onToggle: () => _toggle('tool$i'),
          ),
        ),
      if (item.text.isEmpty && item.reasoning.isEmpty && tools.isEmpty)
        Padding(
          padding: const EdgeInsets.all(WearTokens.space4),
          child: Text(
            '这条回复还没有内容。',
            style: text.bodySmall!.copyWith(color: colors.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ),
      /*
       * An empty tail that scrolls with the content.
       *
       * A block can only reach the anchor line while something follows it, so
       * without this the last one stopped short of the middle of the panel and
       * the bottom arc cut into it. Left unpainted on purpose: this is space,
       * and the black behind it is the scaffold showing through.
       */
      const SizedBox(height: 60),
    ];

    return WearScaffold(
      overlays: <Widget>[PositionIndicator(controller: scroll)],
      /* The same scroll treatment as the transcript it was opened from. */
      child: ScalingLazyColumn(
        controller: scroll,
        topSpacer: 60,
        scalingEnabled: true,
        itemCount: blocks.length,
        itemSpacing: WearTokens.itemSpacing,
        itemBuilder: (context, index, centerDistance) => blocks[index],
      ),
    );
  }
}

/// One tool call shown in full, as opposed to the two-line summary in a bubble.
class _ToolDetail extends StatelessWidget {
  const _ToolDetail({
    required this.item,
    required this.expanded,
    required this.onToggle,
  });

  final ToolCallItem item;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final summary = _summarizeArguments(item.arguments);
    final result = item.result;
    final resultStyle = text.bodySmall!.copyWith(
      color: item.isError ? colors.error : colors.onSurfaceVariant,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final innerWidth = constraints.maxWidth - WearTokens.space3 * 2;
        /*
         * Both halves of the card count. The arguments summary can run past the
         * fold just as the result can, and leaving it out of the measurement is
         * what produced the card that would not collapse: a long command line
         * wrapped over several lines with a short result beneath it — tall
         * enough to need opening, with no tap to open it.
         */
        final clipped =
            (summary.isNotEmpty &&
                _exceedsFold(summary, text.bodySmall!, innerWidth)) ||
            (result != null && _exceedsFold(result, resultStyle, innerWidth));

        return WearCard(
          padding: const EdgeInsets.symmetric(
            horizontal: WearTokens.space3,
            vertical: WearTokens.space2,
          ),
          onTap: clipped ? onToggle : null,
          semanticLabel: clipped
              ? '${item.name}，${expanded ? '点按收起结果' : '点按展开结果'}'
              : item.name,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    item.pending
                        ? Icons.hourglass_top_rounded
                        : (item.isError
                              ? Icons.error_outline_rounded
                              : Icons.build_circle_outlined),
                    size: 16,
                    color: item.isError
                        ? colors.error
                        : colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: WearTokens.space1),
                  Expanded(
                    child: Text(
                      item.name,
                      style: text.labelMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (clipped)
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 16,
                      color: colors.primary,
                    ),
                ],
              ),
              if (summary.isNotEmpty) ...<Widget>[
                const SizedBox(height: WearTokens.space1),
                /* Folded like everything else on this page: a command line long
                 * enough to wrap was the tallest thing in the card and the one
                 * part that could never be shortened. */
                Text(
                  summary,
                  style: text.bodySmall,
                  maxLines: expanded ? null : _detailFoldLines,
                  overflow: expanded ? null : TextOverflow.ellipsis,
                ),
              ],
              if (result != null) ...<Widget>[
                const SizedBox(height: WearTokens.space2),
                Text(
                  result,
                  style: resultStyle,
                  maxLines: expanded ? null : _detailFoldLines,
                  overflow: expanded ? null : TextOverflow.ellipsis,
                ),
                if (clipped && !expanded)
                  Padding(
                    padding: const EdgeInsets.only(top: WearTokens.space1),
                    child: Text(
                      '点按展开结果',
                      style: text.labelSmall,
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// A titled block of long-form content on the detail page, folded when long.
class _DetailSection extends StatelessWidget {
  const _DetailSection({
    required this.icon,
    required this.title,
    required this.body,
    required this.expanded,
    required this.onToggle,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final bodyStyle = text.bodyMedium!;

    return LayoutBuilder(
      builder: (context, constraints) {
        /* Measured, not guessed at — see _exceedsFold. Both the tap and the
         * chevron follow it, so a block that fits the panel is inert. */
        final clipped = _exceedsFold(
          body,
          bodyStyle,
          constraints.maxWidth - WearTokens.space3 * 2,
        );

        return WearCard(
          padding: const EdgeInsets.symmetric(
            horizontal: WearTokens.space3,
            vertical: WearTokens.space2,
          ),
          onTap: clipped ? onToggle : null,
          semanticLabel: clipped
              ? '$title，${expanded ? '点按收起' : '点按展开全文'}'
              : title,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(icon, size: 14, color: colors.primary),
                  const SizedBox(width: WearTokens.space1),
                  Text(title, style: text.labelSmall),
                  const Spacer(),
                  if (clipped)
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 16,
                      color: colors.primary,
                    ),
                ],
              ),
              const SizedBox(height: WearTokens.space1),
              /*
               * Plain Text rather than SelectableText: a selectable field
               * swallows the tap, and the tap is what opens the rest of the
               * block.
               */
              Text(
                body,
                style: bodyStyle,
                maxLines: expanded ? null : _detailFoldLines,
                overflow: expanded ? null : TextOverflow.ellipsis,
              ),
              if (clipped && !expanded)
                Padding(
                  padding: const EdgeInsets.only(top: WearTokens.space1),
                  child: Text(
                    '点按展开全文',
                    style: text.labelSmall,
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Page 1: the conversation with the selected session, and the input that
/// sends a prompt back through the relay.
///
/// No scaffold and no page chrome: [MainPager] owns those, so this view is just
/// the transcript plus its composer.
class ComposeView extends StatefulWidget {
  const ComposeView({
    super.key,
    required this.session,
    required this.scrollController,
    this.isActive = true,
  });

  final RelaySession session;
  final ScrollController scrollController;

  /// Whether this page is the one the pager is resting on.
  ///
  /// A page that is not on screen keeps its state but stops following the
  /// session, so a transcript being folded in under the loading mask — one
  /// notification per frame — does not rebuild the three pages nobody is
  /// looking at.
  final bool isActive;

  @override
  State<ComposeView> createState() => _ComposeViewState();
}

class _ComposeViewState extends State<ComposeView>
    with AutomaticKeepAliveClientMixin {
  /// Kept alive across the pager's swipes.
  ///
  /// A page swiped out of view is normally disposed, which threw away both the
  /// scroll position and the bookkeeping that decides whether the list should
  /// follow the newest message — so sliding back rebuilt the view, reset its
  /// remembered tail sequence, and the first notification treated the session
  /// as new and jumped to the bottom. Holding the state is what makes a return
  /// to this tab land where the reader left it.
  @override
  bool get wantKeepAlive => true;

  /// Space reserved at the bottom of the list for the pinned composer.
  static const double _composerHeight = 64;

  final TextEditingController _input = TextEditingController();

  /// Newest sequence seen; a change here means real news, not older history.
  int _lastNewestSeq = 0;

  /// The session [_lastNewestSeq] was read from.
  ///
  /// Sequence numbers are only comparable within one conversation, so this is
  /// what says whether the remembered tail still describes the session on
  /// screen.
  String? _scrollSessionId;

  /// Lines of an assistant answer shown before the bubble collapses.
  static const int _collapsedLines = 6;

  /// Messages whose full answer is shown in the bubble.
  final Set<int> _expandedAnswers = <int>{};

  /// The pending event currently being answered, so its card shows progress.
  String? _answering;

  /// Whether the composer is on screen. It slides away when the user scrolls
  /// back through the transcript and returns as soon as they scroll forward.
  bool _composerVisible = true;

  /// Whether the list is sitting at its newest message.
  ///
  /// Drives the jump-to-newest control, which only has a job when there is
  /// something below the viewport.
  bool _atBottom = true;

  /// Whether the transcript is scrolled to its oldest row.
  ///
  /// Brings in the control that fetches an older page on request.
  bool _atTop = false;

  bool _composing = false;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    _input.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    /*
     * A sequence number only means anything inside one conversation. Carrying
     * the previous session's tail across made the new session's first
     * notification look like a repeat — same number, different transcript — so
     * the list was never pulled down and the conversation opened wherever the
     * scroll position happened to sit, which is usually part-way up the
     * history.
     */
    final sessionId = widget.session.store.openSessionId;
    if (sessionId != _scrollSessionId) {
      _scrollSessionId = sessionId;
      _lastNewestSeq = 0;
    }

    final items = widget.session.store.items;
    if (items.isEmpty) {
      return;
    }
    final newest = items.last.seq;
    if (newest == _lastNewestSeq) {
      return;
    }
    /*
     * A session the view has not shown yet lands on its newest message; after
     * that the tail is followed only while the reader is already at it.
     * Streaming output arrives many times a second, and pulling someone who had
     * scrolled up to re-read something back down on every chunk made the
     * transcript impossible to read while a reply was being written.
     */
    final opening = _lastNewestSeq == 0;
    _lastNewestSeq = newest;
    if (opening || _atBottom) {
      _scrollToEnd();
    }
  }

  /// Drives paging at the top, and slides the composer with the scroll.
  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) {
      return false;
    }
    final metrics = notification.metrics;

    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification) {
      /*
       * Older history is fetched on request, not on arrival. Reaching the top
       * used to fire a page request immediately, so a user who scrolled up to
       * re-read something was pulled further back without asking. The control
       * now appears at the top edge and the fetch happens when it is pressed.
       */
      final atTop = metrics.pixels <= metrics.minScrollExtent + 2;
      if (atTop != _atTop) {
        setState(() => _atTop = atTop);
      }

      /*
       * "At the bottom" only means something when there is something to scroll.
       * A transcript that fits on one screen has maxScrollExtent zero, and every
       * comparison against it is then true — which pinned the composer open.
       *
       * The threshold has to clear the composer's own bottom padding: the list
       * reserves that space, so the true maxScrollExtent sits 64 dp past where
       * the content visually ends.
       */
      final scrollable = metrics.maxScrollExtent > _composerHeight;
      final atBottom =
          scrollable &&
          metrics.pixels >= metrics.maxScrollExtent - _composerHeight;

      /* Drives the jump-to-newest control, which only has a job when there is
       * something below the viewport. */
      if (atBottom != _atBottom) {
        setState(() => _atBottom = atBottom);
      }

      if (atBottom) {
        if (!_composerVisible) {
          setState(() => _composerVisible = true);
        }
      } else if (notification is ScrollUpdateNotification && !_composing) {
        /*
         * An open composer does not move.
         *
         * While the field is showing the user is typing: sliding it away on a
         * scroll would take the keyboard's target out from under them, and the
         * transcript underneath is not what they are reading. It stays put until
         * the field is closed.
         */
        final delta = notification.scrollDelta ?? 0;
        if (delta > 2 && _composerVisible) {
          setState(() => _composerVisible = false);
        } else if (delta < -2 && !_composerVisible) {
          setState(() => _composerVisible = true);
        }
      }
    }
    return false;
  }

  /// The control that pulls in an older page of history.
  ///
  /// The same pill the composer uses for "发送消息", so the two read as one kind
  /// of control. Slides in from the top edge when the transcript reaches its
  /// oldest row, and stays put while a fetch is in flight.
  Widget _loadOlderBar() {
    final loading = widget.session.isLoadingOlder;

    return Center(
      child: WearChip(
        label: loading ? '加载中…' : '加载更早的历史',
        icon: loading ? Icons.hourglass_top_rounded : Icons.history_rounded,
        onTap: loading ? null : () => widget.session.loadOlder(),
        semanticLabel: loading ? '正在加载历史' : '加载更早的历史',
      ),
    );
  }

  /// Puts the newest message in view, with a little air beneath it.
  ///
  /// The target is the end of the *content*, not the end of the scrollable
  /// area: the list reserves [_composerHeight] below its last row for the
  /// composer, and scrolling to the raw maxScrollExtent leaves the newest
  /// message sitting above an empty gap. Twenty physical pixels below the last
  /// message reads better than parking it flush against the composer.
  ///
  /// A long transcript lays out over several frames, so the extent is still
  /// growing when the snapshot first lands. Re-checking for as long as the
  /// extent keeps moving lands at the true bottom; a fixed retry count instead
  /// gave up mid-layout and parked the view part-way up the history.
  ///
  /// One run at a time. Each call used to start its own chain of post-frame
  /// callbacks, and a streaming reply calls this many times a second — so the
  /// chains multiplied, every callback measuring and jumping, and the page
  /// stuttered exactly while an answer was being written.
  void _scrollToEnd() {
    if (_scrollingToEnd) {
      return;
    }
    _scrollingToEnd = true;
    _pumpScrollToEnd();
  }

  bool _scrollingToEnd = false;

  void _pumpScrollToEnd({int attempt = 0, double lastExtent = -1}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _scrollingToEnd = false;
        return;
      }
      final controller = widget.scrollController;
      if (!controller.hasClients) {
        /*
         * The list is not attached yet. Returning here is what left a freshly
         * opened conversation resting at the top of its history: the snapshot
         * arrives before the first layout, so every post-frame check found no
         * position to move and the scroll never happened at all.
         */
        if (attempt < 40) {
          _pumpScrollToEnd(attempt: attempt + 1, lastExtent: lastExtent);
        } else {
          _scrollingToEnd = false;
        }
        return;
      }
      final position = controller.position;
      final target = (position.maxScrollExtent - _composerHeight + 10).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((controller.offset - target).abs() >= 1) {
        controller.jumpTo(target);
      }
      if (attempt < 40 && position.maxScrollExtent != lastExtent) {
        _pumpScrollToEnd(
          attempt: attempt + 1,
          lastExtent: position.maxScrollExtent,
        );
      } else {
        _scrollingToEnd = false;
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) {
      return;
    }
    _input.clear();
    setState(() => _composing = false);
    await widget.session.sendPrompt(text);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ActiveListenableBuilder(
      active: widget.isActive,
      listenable: widget.session,
      builder: (context) {
        final store = widget.session.store;
        final items = store.items;

        if (store.openSessionId == null) {
          return _emptyPrompt();
        }

        /*
         * A session is open but nothing arrived for it.
         *
         * Reached only once the loading window has closed: while it is open the
         * shield covers the page, so the moment a switch is in progress never
         * renders as an empty conversation. After that, an empty list means
         * either a genuinely empty session or a subscription that failed, and
         * the empty state distinguishes them by the relay's own message.
         */
        if (items.isEmpty && !widget.session.isLoadingSession) {
          return _emptyTranscript();
        }

        /*
         * Tool calls are not rows of their own. Each one belongs to the message
         * that triggered it and is reached through a "tool calls" disclosure on
         * that message, which keeps a turn with six tool calls from pushing the
         * actual conversation off the screen.
         */
        final turns = _groupIntoTurns(items);

        /*
         * Decisions waiting on the user go last: the Host has paused the turn
         * until one is pressed, so they belong where the next message would be.
         */
        final pending = widget.session.pendingEvents;

        return Stack(
          children: <Widget>[
            /*
             * The transcript gets its own layer too. While a session loads it
             * is repainted on every batch that is folded in, and that repaint
             * would otherwise reach the mask sitting above it.
             */
            RepaintBoundary(
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: ScalingLazyColumn(
                controller: widget.scrollController,
                topSpacer: 60,
                /*
                 * Same scroll treatment as the reference reader's lists. An
                 * expanded message is tagged [UnscaledItem] so it stays at full
                 * size while the user is reading it.
                 */
                scalingEnabled: true,
                /* Room for the composer, which floats over the list. */
                padding: const EdgeInsets.only(bottom: _composerHeight),
                itemCount: turns.length + pending.length,
                itemSpacing: WearTokens.itemSpacing,
                itemBuilder: (context, index, centerDistance) =>
                    index < turns.length
                    ? _buildTurn(turns[index])
                    : _pendingEventCard(pending[index - turns.length]),
                ),
              ),
            ),
            if (widget.session.isLoadingSession)
              /*
               * Own layer, so the ring's animation and the list's repaints stay
               * apart: the transcript is folded in behind this mask batch by
               * batch, and without a boundary each side's repaint dragged the
               * other along with it every frame.
               */
              Positioned.fill(
                child: RepaintBoundary(child: _loadingShield()),
              ),
            /*
             * Shown whenever the transcript is at its oldest row — not gated on
             * `hasMoreHistory`, which dsh only reports on some snapshots. With
             * the flag as a precondition the control simply never appeared on a
             * session that had plenty of history left.
             */
            Positioned(
              top: 34,
              left: WearTokens.space3,
              right: WearTokens.space3,
              child: IgnorePointer(
                ignoring: !_atTop && !widget.session.isLoadingOlder,
                child: AnimatedSlide(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  /*
                   * Three times its own height, not one and a half. The control
                   * sits at top: 34, so an offset smaller than that leaves part
                   * of the pill showing above the first message and under the
                   * clock when it is supposed to be out of the way.
                   */
                  offset: _atTop || widget.session.isLoadingOlder
                      ? Offset.zero
                      : const Offset(0, -3),
                  child: _loadOlderBar(),
                ),
              ),
            ),
            /*
             * The composer is pinned to the bottom of the panel rather than
             * living at the end of the list: on a watch the newest message is
             * what you are reading, and having to scroll past it to find the
             * send button is the wrong way round.
             *
             * No background plate behind it — it is a row of pills on the empty
             * part of the transcript, and a panel-coloured strip behind it hid
             * whatever scrolled underneath.
             */
            AnimatedPositioned(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              left: 0,
              right: 0,
              bottom: _composerVisible ? 12 : -_composerHeight,
              child: _composer(),
            ),
          ],
        );
      },
    );
  }

  /// Folds the flat event list into messages, each carrying its tool calls.
  List<_Turn> _groupIntoTurns(List<ChatItem> items) {
    final turns = <_Turn>[];
    for (final item in items) {
      if (item is ToolCallItem && turns.isNotEmpty) {
        turns.last.tools.add(item);
      } else {
        turns.add(_Turn(item));
      }
    }
    return turns;
  }

  Widget _buildTurn(_Turn turn) {
    final item = turn.item;
    /*
     * Tool calls belong to the reply that produced them, so they are handed to
     * the assistant bubble instead of being rows of their own. A turn with six
     * tool calls is one message, not seven.
     */
    if (item is AssistantMessageItem) {
      final bubble = _assistantBubble(item, turn.tools);
      /* An expanded reply is being read, so it keeps full size while it
       * scrolls — scaling it would fight the thing the user just asked for. */
      return _expandedAnswers.contains(item.seq)
          ? UnscaledItem(child: bubble)
          : bubble;
    }
    return _buildItem(item);
  }

  /// Shown before a session is chosen; the picker lives on the config page.
  Widget _emptyPrompt() {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: WearTokens.space4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 32,
              color: colors.onSurfaceVariant,
            ),
            const SizedBox(height: WearTokens.space2),
            Text(
              '还没有选择会话',
              style: text.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WearTokens.space1),
            Text(
              '到「会话」页选择一个会话，再回到这里发送消息。',
              style: text.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// Shown when a session is open but no transcript arrived for it.
  ///
  /// Two cases look identical on screen and are very different to the user: a
  /// session that genuinely has nothing in it yet, and a subscription that
  /// failed. The relay's own message distinguishes them, so it is shown when
  /// there is one, along with a way to try again.
  Widget _emptyTranscript() {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final error = widget.session.lastError;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: WearTokens.space4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              error == null
                  ? Icons.chat_bubble_outline_rounded
                  : Icons.error_outline_rounded,
              size: 32,
              color: error == null ? colors.onSurfaceVariant : colors.error,
            ),
            const SizedBox(height: WearTokens.space2),
            Text(
              error == null ? '这个会话还没有消息' : '读取会话失败',
              style: text.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WearTokens.space1),
            Text(
              error ?? '在下面发送第一条消息，或回到「会话」页换一个会话。',
              style: text.bodySmall!.copyWith(
                color: error == null ? colors.onSurfaceVariant : colors.error,
              ),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            if (error != null) ...<Widget>[
              const SizedBox(height: WearTokens.space2),
              WearChip(
                label: '重新读取',
                icon: Icons.refresh_rounded,
                onTap: () {
                  final id = widget.session.store.openSessionId;
                  if (id != null) {
                    unawaited(widget.session.openSession(id));
                  }
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Covers the transcript until the opening snapshot has been folded in.
  ///
  /// Without it the page shows an empty list for a moment, which on a watch
  /// reads as "this conversation is empty" rather than "this is still loading".
  Widget _loadingShield() {
    /*
     * Opaque black, not a tinted surface.
     *
     * The transcript is folded in one message per frame behind this, so the
     * mask covers a list that is actively changing. A translucent plate showed
     * that churn through the mask and read as flicker rather than as loading;
     * black hides it and matches the window background the app starts on, so
     * the switch from the launch window to this is seamless.
     */
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const WearCircularProgress(size: 34, strokeWidth: 3),
            const SizedBox(height: WearTokens.space3),
            Text('正在载入会话…', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _buildItem(ChatItem item) {
    return switch (item) {
      UserMessageItem() => _userBubble(item),
      /* Reached only for a reply with no grouping step in front of it. */
      AssistantMessageItem() => _assistantBubble(item, const <ToolCallItem>[]),
      ToolCallItem() => _InlineToolCard(item: item),
      ApprovalItem() => _approvalCard(item),
      StatusItem() => _statusRow(item),
    };
  }

  Widget _userBubble(UserMessageItem item) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: WearTokens.space1),
      child: WearCard(
        padding: const EdgeInsets.symmetric(
          horizontal: WearTokens.space3,
          vertical: WearTokens.space2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.person_rounded, size: 14, color: colors.primary),
                const SizedBox(width: WearTokens.space1),
                Text('你', style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
            const SizedBox(height: WearTokens.space1),
            /*
             * Plain Text, matching the assistant bubble.
             *
             * A SelectableText carries its own selection controller, gesture
             * arena entry and caret machinery, and a transcript holds dozens of
             * them at once. The cost lands on the first layout and on every
             * scroll — the work the loading mask had to cover, and what made a
             * long conversation slow to appear once the mask lifted. Nothing on
             * a 233dp panel needs text selection.
             */
            Text(item.text, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  /// The assistant's reply: text by default, everything behind it on tap.
  ///
  /// A long answer is cut off after [_collapsedLines] and the whole bubble
  /// becomes the disclosure control. Tapping it reveals the full text plus the
  /// reasoning and the tool calls — the material a reader only wants when they
  /// are actually studying the answer, not while following the conversation.
  Widget _assistantBubble(AssistantMessageItem item, List<ToolCallItem> tools) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final expanded = _expandedAnswers.contains(item.seq);
    final body = item.text.isEmpty && item.reasoning.isNotEmpty
        ? item.reasoning
        : item.text;
    final hasDetail = item.reasoning.isNotEmpty || tools.isNotEmpty;
    final isLong = _isLongAnswer(body);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: WearTokens.space1),
      child: WearCard(
        padding: const EdgeInsets.symmetric(
          horizontal: WearTokens.space3,
          vertical: WearTokens.space2,
        ),
        /*
         * Tap expands the answer in place. The full record — reasoning and tool
         * calls — opens from the button in the header's top-right corner, so
         * reading a long reply never buries the conversation under its own
         * reasoning, and studying one still gets a page of its own.
         */
        onTap: isLong
            ? () => setState(() {
                if (expanded) {
                  _expandedAnswers.remove(item.seq);
                } else {
                  _expandedAnswers.add(item.seq);
                }
              })
            : null,
        semanticLabel:
            '助手回复'
            '${isLong ? '，点按${expanded ? '收起' : '展开'}回答' : ''}'
            '${hasDetail ? '，右上角按钮查看思考与工具调用' : ''}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.auto_awesome_rounded,
                  size: 14,
                  color: colors.primary,
                ),
                const SizedBox(width: WearTokens.space1),
                Text('助手', style: text.labelSmall),
                if (item.streaming) ...<Widget>[
                  const SizedBox(width: WearTokens.space2),
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: WearCircularProgress(size: 12, strokeWidth: 2),
                  ),
                ],
                if (item.interrupted) ...<Widget>[
                  const SizedBox(width: WearTokens.space2),
                  Text(
                    '已中断',
                    style: text.labelSmall!.copyWith(color: colors.error),
                  ),
                ],
                const Spacer(),
                if (tools.isNotEmpty)
                  Icon(
                    Icons.build_circle_outlined,
                    size: 13,
                    color: colors.onSurfaceVariant,
                  ),
                if (tools.isNotEmpty)
                  Text(' ${tools.length}', style: text.labelSmall),
                if (hasDetail)
                  GestureDetector(
                    onTap: () => _openDetail(item, tools),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: WearTokens.space1,
                        vertical: 2,
                      ),
                      child: Icon(
                        Icons.more_horiz_rounded,
                        size: 20,
                        color: colors.primary,
                      ),
                    ),
                  ),
                if (isLong)
                  GestureDetector(
                    /* A second, explicit way to open and close the answer. */
                    onTap: () => setState(() {
                      if (expanded) {
                        _expandedAnswers.remove(item.seq);
                      } else {
                        _expandedAnswers.add(item.seq);
                      }
                    }),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: WearTokens.space1,
                        vertical: 2,
                      ),
                      child: Icon(
                        expanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 18,
                        color: colors.primary,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: WearTokens.space1),
            /*
             * Plain Text in both states. A SelectableText swallows the tap, so
             * an expanded answer could not be tapped to collapse again — which
             * is exactly the bug this replaced.
             */
            Text(
              body.isEmpty ? '…' : body,
              style: text.bodyMedium,
              maxLines: expanded ? null : _collapsedLines,
              overflow: expanded ? null : TextOverflow.ellipsis,
            ),
            if (isLong && !expanded)
              Padding(
                padding: const EdgeInsets.only(top: WearTokens.space1),
                child: Text(
                  '点按展开回答，右上角查看思考与工具调用',
                  style: text.labelSmall,
                  textAlign: TextAlign.center,
                ),
              ),
            if (!isLong && hasDetail)
              Padding(
                padding: const EdgeInsets.only(top: WearTokens.space1),
                child: Text(
                  '右上角查看思考与工具调用',
                  style: text.labelSmall,
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Opens the full record of one reply on a page of its own.
  void _openDetail(AssistantMessageItem item, List<ToolCallItem> tools) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _MessageDetailPage(item: item, tools: tools),
      ),
    );
  }

  /// True when an answer is long enough that showing all of it would push the
  /// rest of the conversation off screen.
  bool _isLongAnswer(String body) {
    if (body.length > 220) {
      return true;
    }
    return '\n'.allMatches(body).length >= _collapsedLines;
  }

  Widget _approvalCard(ApprovalItem item) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: WearTokens.space1),
      child: WearCard(
        padding: const EdgeInsets.symmetric(
          horizontal: WearTokens.space3,
          vertical: WearTokens.space2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.gpp_maybe_rounded, size: 16, color: colors.tertiary),
                const SizedBox(width: WearTokens.space1),
                Expanded(
                  child: Text(
                    '等待审批：${item.toolName}',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
              ],
            ),
            if (item.reason.isNotEmpty) ...<Widget>[
              const SizedBox(height: WearTokens.space1),
              Text(item.reason, style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: WearTokens.space1),
            Text(
              '审批由 dsh 的命令通道处理，发送 / 开头的命令即可回应。',
              style: Theme.of(
                context,
              ).textTheme.bodySmall!.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusRow(StatusItem item) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: WearTokens.space3,
        vertical: 2,
      ),
      child: Text(
        item.detail.isEmpty ? item.label : '${item.label}：${item.detail}',
        style: text.labelSmall!.copyWith(color: colors.onSurfaceVariant),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// The trailing row: either the field or the action chips.
  Widget _composer() {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        WearTokens.space3,
        WearTokens.space1,
        WearTokens.space3,
        WearTokens.space4,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        /*
         * Stretch, not start: the chip row inside centres its own children, but
         * it can only do that if it is given the full width. Left-aligned it
         * sized itself to its contents and the send button ended up over on the
         * left of the screen.
         */
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          /*
           * The goal is deliberately not shown here.
           *
           * A line above the composer carried the objective for the open
           * session, but the transcript is the conversation and the composer is
           * for writing in it; state that belongs to the session lives on its
           * own page, where it can also be changed. Shown here it was dead
           * text that pushed the field up by a row for the whole session.
           */
          if (_composing)
            Padding(
              /*
               * 35dp off the width, half at each side. Only the open field is
               * inset: the chip row that replaces it keeps the full gutter, so
               * opening the composer reads as a field appearing inside it.
               */
              padding: const EdgeInsets.symmetric(horizontal: 17.5),
              child: WearCard(
                /* Same edge as the 发送消息 chip this field replaces, so the two
                 states read as one control rather than two. */
                bordered: true,
                /*
                 * A step down from the default card scale: field, text and both
                 * buttons together come in about 15dp shorter, so an open
                 * composer covers less of the transcript underneath it. The
                 * tighter vertical padding, the smaller text style and the
                 * reduced icon size each give back a share of that.
                 */
                padding: const EdgeInsets.symmetric(
                  horizontal: WearTokens.space3,
                  vertical: 5,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    TextField(
                      controller: _input,
                      autofocus: true,
                      maxLines: 3,
                      minLines: 1,
                      style: text.bodySmall,
                      /*
                     * No action on the keyboard's own key: on a watch the
                     * return key sits under the wrist and is easy to catch by
                     * accident. The buttons below are the only way to send.
                     */
                      textInputAction: TextInputAction.none,
                      decoration: InputDecoration(
                        hintText: '输入消息，/ 开头为命令',
                        hintStyle: text.bodySmall!.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                        isDense: true,
                        border: InputBorder.none,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        WearIconButton(
                          icon: Icons.close_rounded,
                          size: 26,
                          iconSize: 15,
                          onPressed: () => setState(() => _composing = false),
                          semanticLabel: '取消输入',
                        ),
                        const SizedBox(width: WearTokens.space1),
                        WearIconButton(
                          icon: Icons.send_rounded,
                          size: 26,
                          iconSize: 15,
                          onPressed: _send,
                          semanticLabel: '发送',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            )
          else
            WearChipRow(
              alignment: WrapAlignment.center,
              children: <Widget>[
                WearChip(
                  label: '发送消息',
                  icon: Icons.edit_rounded,
                  onTap: () => setState(() => _composing = true),
                ),
                if (widget.session.isTurnRunning)
                  /*
                   * A spinner where the stop icon would be, sized to match the
                   * chip beside it: the same corner says "working" and offers
                   * the way out of it.
                   */
                  _StopTurnButton(onTap: () => widget.session.cancelTurn()),
              ],
            ),
        ],
      ),
    );
  }

  /// A decision the Host is waiting on: an approval, or a question.
  ///
  /// These are not transcript rows. The Host has a listener open and the turn is
  /// paused until one of these buttons is pressed, so the card sits at the end
  /// of the transcript where the reply would appear.
  Widget _pendingEventCard(HostEvent event) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final busy = _answering == event.eventId;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: WearTokens.space1),
      child: WearCard(
        padding: const EdgeInsets.symmetric(
          horizontal: WearTokens.space3,
          vertical: WearTokens.space2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  event.isApproval
                      ? Icons.gpp_maybe_rounded
                      : Icons.help_outline_rounded,
                  size: 16,
                  color: colors.tertiary,
                ),
                const SizedBox(width: WearTokens.space1),
                Expanded(
                  child: Text(
                    event.isApproval ? '等待审批：${event.toolName}' : '需要你的回答',
                    style: text.labelMedium,
                  ),
                ),
              ],
            ),
            if (event.reason != null) ...<Widget>[
              const SizedBox(height: WearTokens.space1),
              Text(
                event.reason!,
                style: text.bodySmall!.copyWith(color: colors.onSurfaceVariant),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: WearTokens.space2),
            if (busy)
              const Center(
                child: WearCircularProgress(size: 18, strokeWidth: 2),
              )
            else
              _pendingAnswers(event),
          ],
        ),
      ),
    );
  }

  /// The buttons one pending event offers.
  Widget _pendingAnswers(HostEvent event) {
    if (event.isApproval) {
      return WearChipRow(
        alignment: WrapAlignment.center,
        children: <Widget>[
          WearChip(
            label: '拒绝',
            icon: Icons.close_rounded,
            onTap: () => _answer(event, () {
              widget.session.answerApproval(event, 'rejected');
            }),
          ),
          WearChip(
            label: '批准',
            icon: Icons.check_rounded,
            selected: true,
            onTap: () => _answer(event, () {
              widget.session.answerApproval(event, 'allowed-once');
            }),
          ),
        ],
      );
    }

    /*
     * A question is one bubble, not its options. Every question needs its own
     * answer, so the batch belongs on the page the bubble opens — stacked here
     * it reads as one run-on ask, which is exactly how two questions turn into
     * one on a 466px screen.
     */
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final count = event.questions.length;

    return Center(
      child: Material(
        color: colors.tertiaryContainer,
        borderRadius: BorderRadius.circular(WearTokens.radiusButton),
        child: InkWell(
          borderRadius: BorderRadius.circular(WearTokens.radiusButton),
          onTap: () => _openQuestions(event),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: WearTokens.space4,
              vertical: WearTokens.space2,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.quiz_rounded,
                  size: WearTokens.chipIconSize,
                  color: colors.onTertiaryContainer,
                ),
                const SizedBox(width: WearTokens.space2),
                Text(
                  '点击回答 $count 个问题',
                  style: text.labelLarge!.copyWith(
                    color: colors.onTertiaryContainer,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Opens the per-question page for one pending ask.
  ///
  /// The page answers the whole batch and pops itself, so this call only has to
  /// hand it the event and the session that owns the answer.
  void _openQuestions(HostEvent event) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _QuestionsPage(event: event, session: widget.session),
      ),
    );
  }

  /// Runs one answer, showing progress until it lands.
  void _answer(HostEvent event, void Function() action) {
    setState(() => _answering = event.eventId);
    action();
    /* The response is fire-and-forget; clear the spinner on the next frame so
     * the card can disappear as soon as the Host drops the event. */
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _answering == event.eventId) {
        setState(() => _answering = null);
      }
    });
  }
}

/// One tool call inside a message bubble.
///
/// The result is cut off at a few lines and opens on tap. A bubble is a
/// summary of a turn, not the place to read a command's full output — that is
/// what the page behind the corner button is for.
class _InlineToolCard extends StatefulWidget {
  const _InlineToolCard({required this.item});

  final ToolCallItem item;

  @override
  State<_InlineToolCard> createState() => _InlineToolCardState();
}

class _InlineToolCardState extends State<_InlineToolCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final summary = _summarizeArguments(item.arguments);
    final result = item.result;
    final canExpand = result != null && result.length > 120;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: WearTokens.space1),
      child: WearCard(
        padding: const EdgeInsets.symmetric(
          horizontal: WearTokens.space3,
          vertical: WearTokens.space2,
        ),
        onTap: canExpand ? () => setState(() => _expanded = !_expanded) : null,
        semanticLabel: canExpand
            ? '${item.name}，${_expanded ? '点按收起结果' : '点按展开结果'}'
            : item.name,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  item.pending
                      ? Icons.hourglass_top_rounded
                      : (item.isError
                            ? Icons.error_outline_rounded
                            : Icons.build_circle_outlined),
                  size: 16,
                  color: item.isError ? colors.error : colors.onSurfaceVariant,
                ),
                const SizedBox(width: WearTokens.space1),
                Expanded(
                  child: Text(
                    item.name,
                    style: text.labelMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (canExpand)
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 16,
                    color: colors.primary,
                  ),
              ],
            ),
            if (summary.isNotEmpty) ...<Widget>[
              const SizedBox(height: WearTokens.space1),
              Text(
                summary,
                style: text.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (result != null) ...<Widget>[
              const SizedBox(height: WearTokens.space1),
              Text(
                result,
                style: text.bodySmall!.copyWith(
                  color: item.isError ? colors.error : colors.onSurfaceVariant,
                ),
                maxLines: _expanded ? null : 6,
                overflow: _expanded ? null : TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The stop control for a running turn: a spinner with a stop glyph inside it.
///
/// One control instead of a spinner somewhere else plus a button here. Sized to
/// match the send chip beside it so the composer reads as a single row.
class _StopTurnButton extends StatelessWidget {
  const _StopTurnButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Semantics(
      button: true,
      label: '中断',
      child: SizedBox(
        width: WearTokens.chipHeight,
        height: WearTokens.chipHeight,
        child: Material(
          /* Same surface and hairline outline as the send chip beside it, so
           * the two controls read as one row rather than as a filled accent
           * button next to a plain one. */
          color: colors.surfaceContainerHigh,
          shape: CircleBorder(side: BorderSide(color: colors.outlineVariant)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Center(
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  WearCircularProgress(
                    size: WearTokens.chipHeight - 6,
                    strokeWidth: 2,
                  ),
                  Icon(Icons.stop_rounded, size: 12, color: colors.onSurface),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One question at a time, each with its own options.
///
/// Answers are collected per question and sent together: the Host asked for
/// several answers in one request, so one reply carries all of them. A question
/// the user has not answered yet is left out rather than guessed at.
class _QuestionsPage extends StatefulWidget {
  const _QuestionsPage({required this.event, required this.session});

  final HostEvent event;
  final RelaySession session;

  @override
  State<_QuestionsPage> createState() => _QuestionsPageState();
}

class _QuestionsPageState extends State<_QuestionsPage> {
  /// Chosen answer per question id: one of the offered labels, or the user's
  /// own words when nothing offered fits.
  final Map<String, String> _chosen = <String, String>{};

  /// One page per question, swiped left and right.
  final PageController _pages = PageController();

  bool _sending = false;

  /// Why the last submission was refused, when it was.
  ///
  /// A refused answer is not a decided one — the Host still holds the turn
  /// paused — so the page stays up and says what went wrong instead of closing
  /// as though the answer had landed.
  String? _error;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// Stable id for one question, which is what the answer is keyed by.
  String _idOf(Map<String, dynamic> question) =>
      '${question['id'] ?? question['questionId'] ?? ''}';

  /// Options of one question, as `{value, label}` pairs.
  ///
  /// The Host's option carries only a label, and an answer must send that label
  /// back verbatim, so value and label are the same string here.
  List<Map<String, String>> _optionsOf(Map<String, dynamic> question) {
    final raw = question['options'];
    if (raw is! List) {
      return const <Map<String, String>>[];
    }
    final out = <Map<String, String>>[];
    for (final option in raw) {
      if (option is! Map<String, dynamic>) {
        continue;
      }
      final label = '${option['label'] ?? option['name'] ?? ''}';
      if (label.isEmpty) {
        continue;
      }
      out.add({'value': label, 'label': label});
    }
    return out;
  }

  /// True when the stored answer is one of the question's own options.
  bool _isOption(Map<String, dynamic> question, String value) =>
      _optionsOf(question).any((option) => option['value'] == value);

  /// Lets the user answer one question in their own words.
  Future<void> _typeAnswer(Map<String, dynamic> question) async {
    final id = _idOf(question);
    final prompt = '${question['question'] ?? question['prompt'] ?? ''}';
    final controller = TextEditingController(text: _chosen[id] ?? '');
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) =>
            _AnswerTextPage(controller: controller, question: prompt),
      ),
    );
    controller.dispose();
    if (value != null && value.isNotEmpty) {
      setState(() {
        _chosen[id] = value;
        _error = null;
      });
    }
  }

  /// Commits the question on screen and moves to the next one.
  ///
  /// Each question is answered on its own page, but the Host settles the whole
  /// ask with a single reply: `ask_user_question` resolves one `answers` batch,
  /// and a second reply for the same event would arrive after the waterfall is
  /// already settled. So a commit records the answer and advances, and the last
  /// one sends the batch.
  Future<void> _commit(int index) async {
    final questions = widget.event.questions;
    if ((_chosen[_idOf(questions[index])] ?? '').isEmpty) {
      return;
    }
    if (index < questions.length - 1) {
      await _pages.nextPage(
        duration: WearTokens.durationBase,
        curve: WearTokens.motionStandard,
      );
      return;
    }
    await _send();
  }

  /// Sends every question's answer as the one batch the Host is waiting for.
  Future<void> _send() async {
    if (_sending) {
      return;
    }
    setState(() => _sending = true);
    /* Every question carries an entry; an unanswered one sends an empty
       selection, which is what the Host reads as "no answer" — the same batch
       the Web client builds. A chosen option returns its label verbatim, while
       anything else is the user's own words and travels as `custom`. */
    final answers = <Map<String, dynamic>>[];
    for (final question in widget.event.questions) {
      final id = _idOf(question);
      final value = _chosen[id];
      if (value == null || value.isEmpty) {
        answers.add({'id': id, 'selected': const <String>[]});
      } else if (_isOption(question, value)) {
        answers.add({
          'id': id,
          'selected': <String>[value],
        });
      } else {
        answers.add({'id': id, 'selected': const <String>[], 'custom': value});
      }
    }
    final accepted = await widget.session.answerQuestions(
      widget.event,
      answers,
    );
    if (!mounted) {
      return;
    }
    if (accepted) {
      setState(() => _sending = false);
      Navigator.of(context).pop();
      return;
    }
    /* The Host still holds the turn, so keep the answers on screen and say why
       they did not land. Closing here is what made a refused answer look like a
       made one. */
    setState(() {
      _sending = false;
      _error = widget.session.lastError ?? '答案没有被主机接受';
    });
  }

  @override
  Widget build(BuildContext context) {
    final questions = widget.event.questions;

    return WearScaffold(
      /*
       * Full panel, and no clock. The title, the clock and the extra insets this
       * page used to reserve all cost vertical room the questions needed, and
       * what was left read as a black band above and below the content. Each
       * page carries its own "第 N 题" progress instead.
       */
      contentPadding: EdgeInsets.zero,
      showTimeText: false,
      edgeBack: false,
      child: _sending
          ? const Center(child: WearCircularProgress(size: 24, strokeWidth: 2))
          : PageView.builder(
              controller: _pages,
              itemCount: questions.length,
              itemBuilder: (context, index) =>
                  _questionPage(index, questions.length),
            ),
    );
  }

  /// One question, filling its page, with every choice on its own row.
  Widget _questionPage(int index, int total) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final question = widget.event.questions[index];
    final id = _idOf(question);
    final chosen = _chosen[id];
    final answered = chosen != null && chosen.isNotEmpty;
    final last = index == total - 1;

    return ListView(
      /*
       * Horizontal gutters keep the rows off the bezel arc; the vertical ones
       * are the list's own breathing room rather than a reserved band, so the
       * page still runs to the top and bottom of the panel.
       */
      padding: const EdgeInsets.symmetric(
        horizontal: WearTokens.space5,
        vertical: WearTokens.space5,
      ),
      children: <Widget>[
        Row(
          children: <Widget>[
            /*
             * Nudged in from both ends: the title reads better clear of the
             * bezel arc, and the close button off the edge, where a
             * bezel-touching tap is easy to miss. The two ends move by the same
             * amount so the row stays symmetric.
             */
            const SizedBox(width: 20),
            Expanded(
              child: Text(
                '第 ${index + 1} 题 / 共 $total 题',
                style: text.labelMedium!.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
            WearIconButton(
              icon: Icons.close_rounded,
              variant: WearButtonVariant.plain,
              size: 32,
              iconSize: WearTokens.chipIconSize,
              semanticLabel: '取消',
              onPressed: () => Navigator.of(context).pop(),
            ),
            /*
             * The gap belongs after the button, not before it. Leading it only
             * narrows the Expanded title — the button still ends flush against
             * the row's right edge — so the trailing spacer is the one that
             * actually moves it in from the bezel.
             */
            const SizedBox(width: 30),
          ],
        ),
        const SizedBox(height: WearTokens.space2),
        Text(
          '${question['question'] ?? question['prompt'] ?? ''}',
          style: text.bodyMedium,
        ),
        const SizedBox(height: WearTokens.space3),
        for (final option in _optionsOf(question))
          _answerRow(
            label: option['label']!,
            selected: chosen == option['value'],
            onTap: () => setState(() {
              _chosen[id] = option['value']!;
              _error = null;
            }),
          ),
        _answerRow(
          label: '输入回答',
          icon: Icons.edit_rounded,
          selected: answered && !_isOption(question, chosen),
          onTap: () => _typeAnswer(question),
        ),
        const SizedBox(height: WearTokens.space3),
        Center(
          child: WearChip(
            label: last ? '提交' : '下一题',
            icon: last ? Icons.check_rounded : Icons.arrow_forward_rounded,
            selected: answered,
            onTap: answered ? () => _commit(index) : null,
          ),
        ),
        /*
         * The refusal has to be readable from the watch: this page is the only
         * place the user can act on it, and the error is the whole diagnosis.
         */
        if (_error != null) ...<Widget>[
          const SizedBox(height: WearTokens.space3),
          Text(
            _error!,
            style: text.labelSmall!.copyWith(color: colors.error),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }

  /// One answer choice, laid out as a full-width row rather than a chip.
  ///
  /// A row survives a long option label intact and puts every choice on the
  /// same vertical line, which is what a watch finger is aiming at; chips wrap
  /// into a block whose reading order changes with the label lengths.
  Widget _answerRow({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(WearTokens.radiusCard);

    return Padding(
      padding: const EdgeInsets.only(bottom: WearTokens.space2),
      child: Material(
        color: selected ? colors.primaryContainer : colors.surfaceContainerHigh,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: WearTokens.space3,
              vertical: WearTokens.space3,
            ),
            child: Row(
              children: <Widget>[
                if (icon != null) ...<Widget>[
                  Icon(
                    icon,
                    size: WearTokens.chipIconSize,
                    color: selected
                        ? colors.onPrimaryContainer
                        : colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: WearTokens.space2),
                ],
                Expanded(
                  child: Text(
                    label,
                    style: text.bodyMedium!.copyWith(
                      color: selected
                          ? colors.onPrimaryContainer
                          : colors.onSurface,
                    ),
                  ),
                ),
                if (selected)
                  Icon(
                    Icons.check_rounded,
                    size: WearTokens.chipIconSize,
                    color: colors.onPrimaryContainer,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One free-form answer for a single question.
///
/// Pops the trimmed text, or null when the user backs out. The caller owns the
/// controller and disposes it once this route has been popped.
class _AnswerTextPage extends StatelessWidget {
  const _AnswerTextPage({required this.controller, required this.question});

  final TextEditingController controller;
  final String question;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    return WearScaffold(
      child: Padding(
        padding: WearTokens.promptInsets,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('输入回答', style: text.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: WearTokens.space1),
            Text(
              question,
              style: text.labelSmall!.copyWith(color: colors.onSurfaceVariant),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WearTokens.space2),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 4,
              minLines: 2,
              style: text.bodyMedium,
              textInputAction: TextInputAction.none,
              decoration: const InputDecoration(
                hintText: '回答内容',
                isDense: true,
              ),
            ),
            const SizedBox(height: WearTokens.space2),
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
