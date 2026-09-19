import 'dart:async';

import 'package:flutter/material.dart';

import '../state/relay_session.dart';
import '../state/rotary_scroll.dart';
import '../wear_m3/wear_m3.dart';
import 'client_settings_view.dart';
import 'compose_view.dart';
import 'dsh_config_view.dart';
import 'session_view.dart';

/// The watch's home surface: four cards the user swipes between horizontally.
///
/// Order follows reading order — session, then message, then how the remote
/// side behaves, then how this watch connects — so the session browser sits to
/// the left of the composer and opening a session carries the user forward.
///
/// One [WearScaffold] owns the clock, the page name and the dots; the pages are
/// plain views, so a swipe never rebuilds the shell and each page keeps its own
/// scroll position.
class MainPager extends StatefulWidget {
  const MainPager({super.key, required this.session});

  final RelaySession session;

  @override
  State<MainPager> createState() => _MainPagerState();
}

class _MainPagerState extends State<MainPager> {
  static const List<String> _titles = <String>['会话', '首页', 'DSH 设置', '设置'];

  /// The composer is the landing page; the session list is one swipe left.
  static const int _homeIndex = 1;

  /*
   * keepPage is off on purpose: PageView otherwise restores its last position
   * from PageStorage, which would reopen the app on whichever card the user
   * happened to leave it on rather than on the composer.
   */
  final PageController _pages = PageController(
    initialPage: _homeIndex,
    keepPage: false,
  );
  final ScrollController _sessionScroll = ScrollController();
  final ScrollController _homeScroll = ScrollController();
  final ScrollController _configScroll = ScrollController();
  final ScrollController _settingsScroll = ScrollController();
  int _index = _homeIndex;

  /// Whether the pager is resting on the composer, as a live value.
  ///
  /// The composer's own overlay controls subscribe to this instead of being
  /// rebuilt from the top: rebuilding the pager on every scroll frame would
  /// tear down and rebuild the PageView mid-swipe.
  final ValueNotifier<bool> _onComposer = ValueNotifier<bool>(true);

  /// Whether the transcript is sitting at its newest message.
  bool _homeAtBottom = true;

  /// Whether the jump-to-newest control is on screen.
  final ValueNotifier<bool> _showJump = ValueNotifier<bool>(false);

  /// Whether the interjection list button is on screen.
  final ValueNotifier<bool> _showInterjections = ValueNotifier<bool>(false);

  /// Whether the reasoning control is on screen.
  final ValueNotifier<bool> _showReasoning = ValueNotifier<bool>(false);

  /// Vertical slot the reasoning control occupies, in logical pixels above the
  /// composer. 35 when it is second in the stack, 70 when the queue button has
  /// taken that place.
  final ValueNotifier<double> _reasoningSlot = ValueNotifier<double>(35);

  @override
  void initState() {
    super.initState();
    _pages.addListener(_handlePagerScroll);
    widget.session.addListener(_refreshJumpControl);
    _homeScroll.addListener(_handleHomeScroll);
    /*
     * The crown drives whichever card is on screen. Claimed here for the card
     * the app opens on, and re-claimed when the pager settles on another; the
     * four controllers live on this state, so this is the one place that knows
     * which of them is the visible one.
     */
    RotaryScroll.claim(_activeScroll);
    /* Reconnect on open when the watch is already configured, so a glance at
     * the composer is enough to see whether the relay is up. */
    if (widget.session.settings.isComplete &&
        widget.session.status == RelayStatus.disconnected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.session.connect();
      });
    }
  }

  /// Tracks whether the pager is resting exactly on the composer.
  ///
  /// Derived from the scroll offset rather than [PageController.page]: that
  /// getter asserts when the controller is attached to more than one position,
  /// and an assertion thrown inside a scroll listener is swallowed, leaving the
  /// flag unchanged for the whole gesture.
  void _handlePagerScroll() {
    final positions = _pages.positions;
    if (positions.length != 1) {
      return;
    }
    final position = positions.first;
    if (!position.hasViewportDimension || !position.hasContentDimensions) {
      return;
    }
    final viewport = position.viewportDimension;
    if (viewport <= 0) {
      return;
    }
    final page = position.pixels / viewport;
    _onComposer.value = (page - _homeIndex).abs() < 0.01;
    _refreshJumpControl();

    /*
     * Landing on a page is the moment its data is about to be read, so the
     * browser and the config page ask the sender for fresh state instead of
     * showing whatever the last poll happened to leave behind. Guarded by the
     * last landed page so a refresh fires once per arrival rather than on every
     * scroll frame.
     */
    if ((page - page.roundToDouble()).abs() < 0.01) {
      final landed = page.round();
      if (landed != _lastLandedPage) {
        _lastLandedPage = landed;
        if (landed == 0) {
          /*
           * The browser is about to be read, so pull the list rather than show
           * whatever the last push left behind.
           *
           * This is what keeps the archived set honest. Archiving lives in the
           * workspace registry, not the session controller, so a session
           * archived anywhere other than this watch — the web UI, another
           * client — leaves no trace here until the list and the
           * `archivedSessionIds` travelling with it are read again. Without it
           * the session kept its place under a workspace heading even though it
           * was archived.
           */
          unawaited(widget.session.refreshSessions());
        }
        if (landed == 0 || landed == 2) {
          unawaited(widget.session.refreshRelayStatus());
        }
      }
    }
  }

  /// The page the pager last settled on, so a refresh fires once per arrival.
  int _lastLandedPage = _homeIndex;

  /// Decides whether the jump-to-newest control belongs on screen.
  ///
  /// It lives in the scaffold's overlay layer, outside the pager, so it has to
  /// hide itself during a swipe: a page that is only partly on screen should not
  /// be carrying a control. It is also pointless when the transcript is already
  /// at its newest message.
  void _refreshJumpControl() {
    final visible = _onComposer.value && !_homeAtBottom;
    if (_showJump.value != visible) {
      _showJump.value = visible;
    }
    /*
     * The interjection list sits directly above the jump control and follows
     * the same rules: only on the composer page, and only when there is
     * something in the list to look at.
     */
    final listVisible =
        _onComposer.value && widget.session.hasQueuedRows;
    if (_showInterjections.value != listVisible) {
      _showInterjections.value = listVisible;
    }

    /*
     * The reasoning control is shown only on the composer page and only while
     * the session's model takes a reasoning setting, and it sits one slot above
     * whatever is already there so the spacing stays even either way.
     */
    final reasoningVisible =
        _onComposer.value && widget.session.supportsReasoning;
    if (_showReasoning.value != reasoningVisible) {
      _showReasoning.value = reasoningVisible;
    }
    final slot = listVisible ? 70.0 : 35.0;
    if (_reasoningSlot.value != slot) {
      _reasoningSlot.value = slot;
    }
  }

  /// Opens the list of interjections sent from this watch.
  Future<void> _openInterjections() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _InterjectionsPage(session: widget.session),
      ),
    );
    _refreshJumpControl();
  }

  /// Offers the reasoning efforts the session's model accepts.
  ///
  /// Whatever levels the model declares are shown centred as one group: a model
  /// without Off simply has one pill fewer, and the row re-centres instead of
  /// holding an empty slot open for a level it does not offer.
  Future<void> _pickReasoning() async {
    final session = widget.session;
    final efforts = session.reasoningEfforts;
    if (efforts.isEmpty) {
      return;
    }
    final current = session.currentReasoningEffort;

    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Padding(
        /*
         * Cleared above the composer.
         *
         * The sheet is anchored to the bottom edge, and the composer owns the
         * last composerHeight of the page, so the usual space4 inset dropped
         * the pills straight onto the send row — the button was still visible
         * through them. Lifting the row by the composer's height puts it over
         * the transcript instead, which is where the other overlay controls
         * already sit.
         */
        padding: const EdgeInsets.fromLTRB(
          WearTokens.space2,
          0,
          WearTokens.space2,
          /*
           * The composer clear of the row, less the 10dp that came back off it:
           * 20 physical pixels on this 2x panel, which puts the pills just
           * inside the transcript instead of well above it.
           */
          WearTokens.composerHeight + WearTokens.space4 - 10,
        ),
        child: WearChipRow(
          alignment: WrapAlignment.center,
          /*
           * Tight gaps and dense pills so a full ladder — four levels on this
           * panel — stays on one centred row instead of wrapping the last
           * level onto a line of its own.
           */
          spacing: WearTokens.space1,
          children: <Widget>[
            for (final effort in efforts)
              WearChip(
                dense: true,
                label: session.reasoningLabel(effort),
                selected: effort['id'] == current,
                onTap: () => Navigator.of(sheetContext).pop('${effort['id']}'),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) {
      await session.setReasoningEffort(chosen);
    }
  }

  void _handleHomeScroll() {
    final positions = _homeScroll.positions;
    if (positions.isEmpty) {
      return;
    }
    final position = positions.first;
    if (!position.hasContentDimensions || !position.hasViewportDimension) {
      return;
    }
    /*
     * Whether the viewport sits at the end of the transcript.
     *
     * No "is it scrollable" precondition: a conversation that fits on one
     * screen is trivially at its own end, and requiring otherwise made the
     * jump-to-newest control appear over it — offering to scroll somewhere the
     * reader already was.
     *
     * Measured against the end of the scrollable area, with only a rounding
     * slack. The looser test — the end of the content, which sits a composer's
     * height above it — called the list arrived while a band of empty
     * background was still below, so the control disappeared with somewhere
     * left to go.
     */
    final atBottom = position.pixels >= position.maxScrollExtent - 1;
    if (atBottom == _homeAtBottom) {
      return;
    }
    _homeAtBottom = atBottom;
    _refreshJumpControl();
  }

  /// Scrolls the transcript to the very end of the list.
  ///
  /// To the end of the scrollable area, not to the end of the content. The list
  /// reserves [WearTokens.composerHeight] below its last row for the composer,
  /// and stopping at that row's end left a band of empty background below the
  /// newest message — pressing "back to the newest" landed short of the bottom,
  /// which reads as the button not working.
  void _jumpToNewest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final positions = _homeScroll.positions;
      if (positions.isEmpty) {
        return;
      }
      final position = positions.first;
      _homeScroll.jumpTo(position.maxScrollExtent);
      _refreshJumpControl();
    });
  }

  @override
  void dispose() {
    _pages.removeListener(_handlePagerScroll);
    widget.session.removeListener(_refreshJumpControl);
    _homeScroll.removeListener(_handleHomeScroll);
    _showJump.dispose();
    _showInterjections.dispose();
    _showReasoning.dispose();
    _reasoningSlot.dispose();
    _pages.dispose();
    _onComposer.dispose();
    /* Every controller this state owns gives the crown back, not only the one in
     * front: the claim is keyed by identity, and a stale one would point the
     * crown at a disposed position. */
    RotaryScroll.release(_sessionScroll);
    RotaryScroll.release(_homeScroll);
    RotaryScroll.release(_configScroll);
    RotaryScroll.release(_settingsScroll);
    _sessionScroll.dispose();
    _homeScroll.dispose();
    _configScroll.dispose();
    _settingsScroll.dispose();
    super.dispose();
  }

  ScrollController get _activeScroll => switch (_index) {
    0 => _sessionScroll,
    1 => _homeScroll,
    2 => _configScroll,
    _ => _settingsScroll,
  };

  void _goTo(int index) {
    _pages.animateToPage(
      index,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return WearScaffold(
      /* The clock fades against whichever page is scrolling. The page name is
       * not drawn: on a round panel a title under the clock eats the top of
       * the content area, and the dots at the bottom already say where you
       * are. */
      timeTextController: _activeScroll,
      /*
       * The scroll bar goes in the overlay layer, not inside a page. It tracks
       * the bezel, and a page's box is inset well inside that circle, so the
       * bar drawn with the content got clipped away exactly where the panel is
       * widest — which is where it is most visible.
       */
      overlays: <Widget>[
        /*
         * The jump-to-newest control lives here, not inside the transcript.
         * An overlay is not carried sideways by the pager, so it can decide for
         * itself whether it belongs on screen — which is the whole point: it
         * has to disappear the moment the page it belongs to starts moving.
         */
        /*
         * The reasoning control sits above the queue button, and only exists
         * while the session's model takes a reasoning setting. It carries the
         * bolt that used to mean "interject": the action is a model setting
         * rather than a message, but the glyph already reads as "how hard it
         * thinks".
         */
        /*
         * The reasoning control, stacked exactly like the two below it: an
         * outer builder that only places it, and an inner one that slides it.
         *
         * Splitting the two matters for the animation. The slot moves when the
         * queue button appears or disappears, while visibility changes with the
         * page and the model; driving both from one builder rebuilt the slide
         * widget mid-flight and the movement came out different from the other
         * buttons.
         */
        ValueListenableBuilder<double>(
          valueListenable: _reasoningSlot,
          builder: (context, slot, child) => Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: EdgeInsets.only(
                left: WearTokens.space3,
                bottom: WearTokens.composerHeight + 6 + slot,
              ),
              child: child,
            ),
          ),
          child: ValueListenableBuilder<bool>(
            valueListenable: _showReasoning,
            builder: (context, show, child) => IgnorePointer(
              ignoring: !show,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                offset: show ? Offset.zero : const Offset(-1.4, 0),
                child: child,
              ),
            ),
            child: _OverlayButton(
              icon: Icons.bolt_rounded,
              label: '推理强度',
              onTap: _pickReasoning,
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: const EdgeInsets.only(
              left: WearTokens.space3,
              /*
               * One step above the jump control. The three overlay buttons are
               * spaced evenly: jump, queue, reasoning, bottom to top.
               */
              bottom: WearTokens.composerHeight + 6 + 35,
            ),
            child: ValueListenableBuilder<bool>(
              valueListenable: _showInterjections,
              builder: (context, show, child) => IgnorePointer(
                ignoring: !show,
                child: AnimatedSlide(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  offset: show ? Offset.zero : const Offset(-1.4, 0),
                  child: child,
                ),
              ),
              child: _InterjectionsButton(onTap: _openInterjections),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: const EdgeInsets.only(
              left: WearTokens.space3,
              bottom: WearTokens.composerHeight + 6,
            ),
            child: ValueListenableBuilder<bool>(
              valueListenable: _showJump,
              builder: (context, show, child) => IgnorePointer(
                ignoring: !show,
                child: AnimatedSlide(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  offset: show ? Offset.zero : const Offset(-1.4, 0),
                  child: child,
                ),
              ),
              child: _JumpToBottom(onTap: _jumpToNewest),
            ),
          ),
        ),
        PositionIndicator(controller: _activeScroll),
        /*
         * The dots ride above the content rather than occupying a row of their
         * own. Held in the bottom slot they were part of the layout, so the
         * list had to stop above them and the leftover strip read as a black
         * band across the bottom of every page.
         */
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: WearPageIndicator(
              count: _titles.length,
              current: _index,
              onSelected: _goTo,
              semanticLabel:
                  '${_titles[_index]}，第 ${_index + 1} 页，共 ${_titles.length} 页',
            ),
          ),
        ),
      ],
      child: PageView(
        controller: _pages,
        onPageChanged: (index) {
          setState(() => _index = index);
          /* Hand the crown to the card that just settled. */
          RotaryScroll.claim(_activeScroll);
          /* Belt and braces: the scroll listener drives the flag throughout a
           * swipe, and settling on a page confirms it. */
          _onComposer.value = index == _homeIndex;
          _refreshJumpControl();
        },
        /*
         * Every page carries its own opaque background. The pages themselves
         * are plain views with nothing behind them, so without this a
         * neighbouring page's text shows through along the left and right
         * edges during a swipe — and stays there whenever the pager sits a
         * fraction of a pixel off a whole page.
         */
        children: <Widget>[
          ColoredBox(
            color: colors.surface,
            child: SessionView(
              session: widget.session,
              scrollController: _sessionScroll,
              onOpened: () => _goTo(_homeIndex),
              isActive: _index == 0,
            ),
          ),
          ColoredBox(
            color: colors.surface,
            child: ComposeView(
              session: widget.session,
              scrollController: _homeScroll,
              isActive: _index == _homeIndex,
            ),
          ),
          ColoredBox(
            color: colors.surface,
            child: DshConfigView(
              session: widget.session,
              scrollController: _configScroll,
              isActive: _index == 2,
            ),
          ),
          ColoredBox(
            color: colors.surface,
            child: ClientSettingsView(
              session: widget.session,
              scrollController: _settingsScroll,
              isActive: _index == 3,
            ),
          ),
        ],
      ),
    );
  }
}

/// Jumps the transcript to its newest message.
///
/// A chevron pointing down, matching the direction the list has to travel.
/// Lives in the scaffold's overlay layer so it is not carried sideways by the
/// pager, and shows itself only when the composer page is at rest and the
/// transcript has something below it.
class _JumpToBottom extends StatelessWidget {
  const _JumpToBottom({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Semantics(
      button: true,
      label: '回到最新',
      child: SizedBox(
        width: WearTokens.chipHeight,
        height: WearTokens.chipHeight,
        child: Material(
          color: colors.surfaceContainerHigh,
          shape: CircleBorder(side: BorderSide(color: colors.outlineVariant)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 22,
              color: colors.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the list of messages queued behind the running turn.
///
/// Carries the send glyph — the same one the composer uses to put a message
/// in the queue — and appears only while the list has something in it.
class _InterjectionsButton extends StatelessWidget {
  const _InterjectionsButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Semantics(
      button: true,
      label: '排队消息',
      child: SizedBox(
        width: WearTokens.chipHeight,
        height: WearTokens.chipHeight,
        child: Material(
          color: colors.surfaceContainerHigh,
          shape: CircleBorder(side: BorderSide(color: colors.outlineVariant)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Icon(Icons.send_rounded, size: 20, color: colors.primary),
          ),
        ),
      ),
    );
  }
}

/// Every interjection sent from this watch, with its edit and send controls.
class _InterjectionsPage extends StatefulWidget {
  const _InterjectionsPage({required this.session});

  final RelaySession session;

  @override
  State<_InterjectionsPage> createState() => _InterjectionsPageState();
}

class _InterjectionsPageState extends State<_InterjectionsPage> {
  /// The entry currently being sent, so its row can show progress.
  String? _sending;

  /*
   * Owned by the state, not the build. It was created inside `build`, which
   * leaked a controller per frame and left the list with a fresh position each
   * time — nothing noticed while the page was only ever touched by finger, but
   * the crown addresses the controller by identity and a new one every frame
   * would have had nowhere to keep its offset.
   */
  final ScrollController _scroll = ScrollController();

  /// Groups the user has collapsed, by key.
  ///
  /// Both start open. The page exists to show what is waiting, and a list that
  /// opened collapsed would hide the only thing it has to say.
  final Set<String> _collapsed = <String>{};

  @override
  void initState() {
    super.initState();
    /* Pushed over the pager, so it holds the crown until it closes. */
    RotaryScroll.claim(_scroll);
  }

  @override
  void dispose() {
    RotaryScroll.release(_scroll);
    _scroll.dispose();
    super.dispose();
  }

  void _toggleGroup(String key) {
    setState(() {
      if (!_collapsed.remove(key)) {
        _collapsed.add(key);
      }
    });
  }

  Future<void> _edit(Map<String, dynamic> entry) async {
    final id = '${entry['id']}';
    final controller = TextEditingController(
      text: RelaySession.queuedText(entry),
    );
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => _EditInterjectionPage(controller: controller),
      ),
    );
    controller.dispose();
    if (value != null) {
      await widget.session.editQueuedItem(id, value);
    }
  }

  /// Sends a queued message into the turn now, rather than leaving it waiting.
  Future<void> _sendNow(Map<String, dynamic> entry) async {
    final id = '${entry['id']}';
    setState(() => _sending = id);
    await widget.session.sendQueuedItemNow(id);
    if (mounted) {
      setState(() => _sending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final pending = widget.session.queuedPending;
        final steering = widget.session.queuedSteering;

        if (pending.isEmpty && steering.isEmpty) {
          return WearScaffold(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(WearTokens.space4),
                child: Text(
                  '没有排队消息。\n有轮次进行时发送的消息会等在这里。',
                  style: text.bodySmall!.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }

        /*
         * Two collapsible groups in one flat list of rows, headed the way the
         * session page heads a working directory: the same card, leading icon,
         * count and disclosure. A flat run keeps one scroll position for the
         * page instead of two that would fight over the overlay indicator.
         */
        final rows = <Widget>[
          ..._group('排队中', 'pending', Icons.schedule_rounded, pending,
              steerable: true),
          ..._group('待插话', 'steering', Icons.bolt_rounded, steering,
              steerable: false),
        ];

        /*
         * A plain ListView, not the scaling column.
         *
         * The scaling column keeps an element per index and rebuilds it only
         * when its own bookkeeping says so, which is fine for a transcript that
         * grows at the end but wrong here: editing a row or removing one
         * changed the list without the row on screen changing, so the buttons
         * looked dead. A short fixed list does not need the scaling treatment.
         */
        return WearScaffold(
          overlays: <Widget>[PositionIndicator(controller: _scroll)],
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.only(top: 45, bottom: 25),
            itemCount: rows.length,
            itemBuilder: (context, index) => rows[index],
          ),
        );
      },
    );
  }

  /// One group: its heading, then its rows while it is open.
  List<Widget> _group(
    String label,
    String key,
    IconData icon,
    List<Map<String, dynamic>> entries, {
    required bool steerable,
  }) {
    if (entries.isEmpty) {
      return const <Widget>[];
    }
    final open = !_collapsed.contains(key);
    return <Widget>[
      _groupHeader(
        label,
        icon,
        entries.length,
        open: open,
        onTap: () => _toggleGroup(key),
      ),
      if (open)
        ...entries.map((entry) => _row(entry, steerable: steerable)),
    ];
  }

  /// A heading over one queue group, shaped like the session page's working
  /// directory heading: leading icon, label, count, and a disclosure arrow.
  Widget _groupHeader(
    String label,
    IconData icon,
    int count, {
    required bool open,
    required VoidCallback onTap,
  }) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Padding(
      /*
       * The list carries only vertical padding, so the heading brings the same
       * horizontal inset its rows do; without it the card would touch the
       * bezel while every row under it stood off.
       */
      padding: const EdgeInsets.only(
        left: WearTokens.space3,
        right: WearTokens.space3,
        top: 2,
        bottom: 2,
      ),
      child: WearCard(
        padding: const EdgeInsets.symmetric(
          horizontal: WearTokens.space3,
          vertical: WearTokens.space1,
        ),
        onTap: onTap,
        semanticLabel:
            '$label，$count 条，'
            '${open ? '已展开，点按收起' : '点按展开'}',
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
            Text('$count', style: text.labelSmall),
            const SizedBox(width: WearTokens.space1),
            Icon(
              open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              size: 18,
              color: colors.primary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(Map<String, dynamic> entry, {required bool steerable}) {
    final text = Theme.of(context).textTheme;
    final sending = _sending == '';

    return Padding(
      padding: const EdgeInsets.only(
        left: WearTokens.space3,
        right: WearTokens.space3,
        bottom: WearTokens.itemSpacing,
      ),
      child: WearCard(
        padding: const EdgeInsets.symmetric(
          horizontal: WearTokens.space3,
          vertical: WearTokens.space2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(RelaySession.queuedText(entry), style: text.bodyMedium),
            const SizedBox(height: WearTokens.space2),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                WearIconButton(
                  icon: Icons.edit_rounded,
                  size: WearTokens.chipHeight,
                  iconSize: WearTokens.chipIconSize,
                  onPressed: sending ? null : () => _edit(entry),
                  semanticLabel: '编辑排队消息',
                ),
                const SizedBox(width: WearTokens.space1),
                WearIconButton(
                  icon: Icons.delete_outline_rounded,
                  size: WearTokens.chipHeight,
                  iconSize: WearTokens.chipIconSize,
                  onPressed: sending
                      ? null
                      : () => widget.session.removeQueuedItem('${entry['id']}'),
                  semanticLabel: '删除排队消息',
                ),
                /*
                 * An interjection that already went in has nothing left to
                 * send: the row is on screen because the model has not read it
                 * yet, and steering it again addresses an item that has left
                 * the next-turn inbox. Editing and dropping it stay, because
                 * neither depends on where the message is waiting.
                 */
                if (steerable) ...<Widget>[
                  const SizedBox(width: WearTokens.space1),
                  if (sending)
                    const SizedBox(
                      width: WearTokens.chipHeight,
                      height: WearTokens.chipHeight,
                      child: Center(
                        child: WearCircularProgress(size: 18, strokeWidth: 2),
                      ),
                    )
                  else
                    WearIconButton(
                      icon: Icons.send_rounded,
                      size: WearTokens.chipHeight,
                      iconSize: WearTokens.chipIconSize,
                      onPressed: () => _sendNow(entry),
                      semanticLabel: '立刻发送',
                    ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A full-screen prompt for rewriting one interjection.
class _EditInterjectionPage extends StatefulWidget {
  const _EditInterjectionPage({required this.controller});

  final TextEditingController controller;

  @override
  State<_EditInterjectionPage> createState() => _EditInterjectionPageState();
}

class _EditInterjectionPageState extends State<_EditInterjectionPage> {
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return WearScaffold(
      child: Padding(
        padding: WearTokens.promptInsets,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('编辑插话', style: text.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: WearTokens.space2),
            TextField(
              controller: widget.controller,
              autofocus: true,
              maxLines: 4,
              minLines: 2,
              style: text.bodyMedium,
              textInputAction: TextInputAction.none,
              decoration: const InputDecoration(
                hintText: '插话内容',
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

/// One of the composer's stacked overlay buttons.
class _OverlayButton extends StatelessWidget {
  const _OverlayButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Semantics(
      button: true,
      label: label,
      child: SizedBox(
        width: WearTokens.chipHeight,
        height: WearTokens.chipHeight,
        child: Material(
          color: colors.surfaceContainerHigh,
          shape: CircleBorder(side: BorderSide(color: colors.outlineVariant)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Icon(icon, size: 22, color: colors.primary),
          ),
        ),
      ),
    );
  }
}
