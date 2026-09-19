import 'dart:convert';

import '../relay/relay_client.dart';

/// One renderable row in a conversation.
///
/// dsh emits 51 session event types; this is the subset a watch surface shows,
/// folded into rows a `ScalingLazyColumn` can build directly.
sealed class ChatItem {
  const ChatItem({required this.seq});

  /// Session sequence this row was derived from, for stable ordering.
  final int seq;
}

/// A user prompt as it appears in the transcript.
class UserMessageItem extends ChatItem {
  const UserMessageItem({
    required super.seq,
    required this.text,
    this.queued = false,
  });

  final String text;

  /// True while the prompt is still queued rather than in the transcript.
  final bool queued;
}

/// An assistant reply. [streaming] is true while text is still arriving, so the
/// UI can show a progress affordance without a second state field.
class AssistantMessageItem extends ChatItem {
  const AssistantMessageItem({
    required super.seq,
    required this.text,
    this.reasoning = '',
    this.streaming = false,
    this.interrupted = false,
  });

  final String text;
  final String reasoning;
  final bool streaming;
  final bool interrupted;

  AssistantMessageItem copyWith({
    String? text,
    String? reasoning,
    bool? streaming,
    bool? interrupted,
  }) {
    return AssistantMessageItem(
      seq: seq,
      text: text ?? this.text,
      reasoning: reasoning ?? this.reasoning,
      streaming: streaming ?? this.streaming,
      interrupted: interrupted ?? this.interrupted,
    );
  }
}

/// A tool the agent invoked, with the result once it lands.
class ToolCallItem extends ChatItem {
  const ToolCallItem({
    required super.seq,
    required this.callId,
    required this.name,
    required this.arguments,
    this.result,
    this.isError = false,
    this.pending = true,
  });

  final String callId;
  final String name;
  final String arguments;
  final String? result;
  final bool isError;
  final bool pending;

  ToolCallItem withResult(String text, {required bool error}) {
    return ToolCallItem(
      seq: seq,
      callId: callId,
      name: name,
      arguments: arguments,
      result: text,
      isError: error,
      pending: false,
    );
  }
}

/// A low-frequency state change worth one line: approval, permission, sandbox
/// mode, plan mode, goal, model selection, a failed turn.
class StatusItem extends ChatItem {
  const StatusItem({required super.seq, required this.label, this.detail = ''});

  final String label;
  final String detail;
}

/// A pending approval the user must answer.
class ApprovalItem extends ChatItem {
  const ApprovalItem({
    required super.seq,
    required this.approvalId,
    required this.toolName,
    this.reason = '',
  });

  final String approvalId;
  final String toolName;
  final String reason;
}

/// The mirrored state of one dsh installation: its session list and, for the
/// session currently open, its folded transcript.
///
/// The store is deliberately transport-agnostic: [applyMessage] takes relay
/// messages, so the same folding serves a live connection and a replayed
/// snapshot.
class SessionStore {
  SessionStore({this.maxItems = 400});

  /// Upper bound on retained rows. A watch cannot usefully scroll thousands.
  final int maxItems;

  final List<Map<String, dynamic>> _sessions = [];
  final List<ChatItem> _items = [];

  /// Session id the items belong to, or null when nothing is open.
  String? _openSession;

  /// dsh's follow cursor: the highest sequence delivered. Paging backwards uses
  /// this value, and dsh rejects any cursor it did not issue.
  int _cursor = 0;

  /// Lowest sequence currently held. Older history is requested from here.
  int _oldestSeq = 0;

  /// True while dsh reports records behind the window that is already loaded.
  ///
  /// The opening snapshot is deliberately a window rather than the whole
  /// transcript, so this is what tells the UI it may ask for more.
  bool hasMoreHistory = false;

  /// True once the opening snapshot for the open session has been folded in.
  ///
  /// Subscribing and receiving the snapshot are different moments; a loading
  /// shield has to wait for the second one.
  bool hasSnapshot = false;

  /// Highest applied event sequence, used to drop replays and duplicates.
  int _lastSeq = 0;

  /// Text accumulated from streaming chunks for the in-flight assistant reply.
  /// True from `turn/start` until `turn/end`.
  ///
  /// Broader than the streaming flag on the assistant row: a turn spends most
  /// of its life running tools, during which nothing is streaming but the turn
  /// is very much in progress and interruptible.
  bool turnRunning = false;

  /// Whether the history replayed by the last snapshot ended on a turn start.
  ///
  /// A window that stops after a start with no end after it is a turn still in
  /// flight, and that is the one reading of history allowed to raise the live
  /// flag — an ordinary replayed start says nothing about now.
  bool _historyEndsOnOpenTurn = false;

  /// Chunk event sequences already folded into the stream buffers.
  ///
  /// Nothing else in the store needs this: settled messages are de-duplicated by
  /// sequence in [_append]. Chunks are different — they accumulate text rather
  /// than append a row, so a repeat is invisible to that check and shows up as
  /// the same words twice in the reply.
  final Set<int> _foldedChunks = <int>{};

  String _streamText = '';
  String _streamReasoning = '';

  /// Session-level values that arrive as events or projections.
  String? title;
  String? goalLabel;

  /// The open session's goal projection, verbatim.
  ///
  /// Kept whole rather than reduced to its label: every goal mutation is keyed
  /// by the `ref` inside it (`{id, revision}`), and the phase is what decides
  /// whether pause or resume is the meaningful action.
  Map<String, dynamic>? goal;

  /// Which session [goal] was reported for.
  ///
  /// A goal belongs to one session. Recording the owner means a projection that
  /// arrives late — a control frame from a session the user has since left —
  /// cannot be shown as if it described the one on screen.
  String? goalSessionId;
  List<Map<String, dynamic>> todos = const [];
  Map<String, dynamic>? modelSelection;
  String? permissionPreset;
  String? sandboxMode;

  /// The Agent preset this session was composed from, as the Host reports it.
  ///
  /// Absent for a session the Host has not described yet, and fixed once the
  /// conversation has run — the composition is what produced its history.
  String? agentPreset;

  /// The permission presets dsh reported, each `{value, name, description}`.
  ///
  /// A preset bundles a sandbox mode and an approval policy, so this one list
  /// is what the watch offers instead of two independent switches.
  List<Map<String, dynamic>> permissionOptions = const <Map<String, dynamic>>[];
  bool planModeActive = false;
  bool permissionAskPending = false;

  List<Map<String, dynamic>> get sessions => List.unmodifiable(_sessions);
  List<ChatItem> get items => List.unmodifiable(_items);

  /// Session currently folded into [items], or null when nothing is open.
  String? get openSessionId => _openSession;

  int get cursor => _cursor;

  /// Lowest sequence held; paging backwards starts from here.
  int get oldestSeq => _oldestSeq;
  bool get hasConversation => _items.isNotEmpty;

  /// The most recent assistant row, which streaming text updates in place.
  AssistantMessageItem? get _streamingItem {
    for (var i = _items.length - 1; i >= 0; i--) {
      final item = _items[i];
      if (item is AssistantMessageItem && item.streaming) {
        return item;
      }
      if (item is UserMessageItem) {
        break;
      }
    }
    return null;
  }

  /// Opens a session locally, discarding any previously folded transcript.
  void openSession(String sessionId) {
    if (_openSession == sessionId) {
      return;
    }
    _openSession = sessionId;
    _resetTranscript();
  }

  /// Closes the open session, leaving the browser as the only thing on screen.
  ///
  /// Used when the session the user is reading stops existing for them — being
  /// archived, for one. Without this the transcript would sit there for a
  /// session that is no longer in any list.
  void closeSession() {
    if (_openSession == null) {
      return;
    }
    _openSession = null;
    _resetTranscript();
  }

  void _resetTranscript() {
    _items.clear();
    _cursor = 0;
    _oldestSeq = 0;
    _lastSeq = 0;
    _foldedChunks.clear();
    turnRunning = false;
    _historyEndsOnOpenTurn = false;
    _streamText = '';
    _streamReasoning = '';
    hasSnapshot = false;
    hasMoreHistory = false;
    title = null;
    goalLabel = null;
    goal = null;
    goalSessionId = null;
    /*
     * Session-scoped projections describe the session that just closed, so they
     * go with it: leaving the model set here showed the previous conversation's
     * model against the new one until its own projection arrived — and if that
     * arrived first, this value was simply wrong.
     */
    modelSelection = null;
    agentPreset = null;
    queuedItems = const <Map<String, dynamic>>[];
    pendingEvents.clear();
    todos = const [];
    planModeActive = false;
  }

  /// Routes one relay message into the store.
  void applyMessage(RelayMessage message) {
    switch (message.kind) {
      case 'sessions':
        _applySessions(message.payload);
      case 'snapshot':
        _applySnapshot(message.payload);
      case 'events':
        _applyEvents(message.payload);
      case 'state':
        _applyControl(message.payload);
      default:
        break;
    }
  }

  void _applySessions(Map<String, dynamic>? payload) {
    final list = payload?['sessions'];
    if (list is! List) {
      return;
    }
    _sessions
      ..clear()
      ..addAll(list.whereType<Map<String, dynamic>>());

    /*
     * The workspaces themselves, forwarded with the list. Membership is what
     * decides which sessions belong to a workspace and which trail under
     * Ungrouped, so the client cannot group correctly without them.
     */
    final spaces = payload?['workspaces'];
    if (spaces is List) {
      workspaces = spaces.whereType<Map<String, dynamic>>().toList(
        growable: false,
      );
    }

    /*
     * The sender forwards dsh's archived set with the list. Taking it here as
     * well as from the workspace feed matters: a client that connects after the
     * feed's baseline frame would otherwise never learn which sessions are
     * archived, and would show them as ordinary ones.
     */
    final ids = payload?['archivedSessionIds'];
    if (ids is List) {
      archivedSessionIds
        ..clear()
        ..addAll(ids.whereType<String>());
    }

    /*
     * Summaries of sessions the sender has seen leave the list — in practice
     * the ones that were archived. dsh drops those from `session/list`
     * entirely, so this copy is the only description of them the client will
     * ever get, and it arrives with every refresh rather than having to be
     * captured at archive time (which a restart would lose).
     */
    final digests = payload?['archivedDigests'];
    if (digests is List) {
      for (final entry in digests) {
        if (entry is Map<String, dynamic>) {
          final id = entry['sessionId'];
          if (id is String && id.isNotEmpty) {
            archivedDigests[id] = entry;
          }
        }
      }
    }

    /* Keep the open session's title current even without an event. */
    final open = _openSession;
    if (open != null) {
      for (final session in _sessions) {
        if (session['sessionId'] != open) {
          continue;
        }
        final projections = session['projections'];
        if (projections is Map<String, dynamic>) {
          final values = projections['values'];
          if (values is Map<String, dynamic>) {
            /*
             * The session list carries the open session's projections too.
             * Folding the whole set — not just the title — is what lets the
             * config page show the model and the permission presets the session
             * is actually running with, instead of waiting for a snapshot that
             * only arrives once it is opened.
             */
            _applyProjections(values);
          }
        }
      }
    }
  }

  void _applySnapshot(Map<String, dynamic>? payload) {
    if (payload == null) {
      return;
    }
    final session = payload['session'];
    if (session is! String) {
      return;
    }
    /*
     * Only a snapshot for the session on screen counts.
     *
     * The flag used to be set before this check, so a snapshot for any other
     * session marked the open one as loaded while its records were discarded —
     * leaving an empty list behind a "loaded" flag, which is what made the page
     * report an empty conversation. A snapshot that never arrives is covered by
     * the loading window instead.
     */
    if (_openSession != null && _openSession != session) {
      return;
    }
    hasSnapshot = true;
    _openSession ??= session;
    _items.clear();
    _lastSeq = 0;
    _oldestSeq = 0;
    _streamText = '';
    _streamReasoning = '';
    _pendingRecords.clear();
    _pendingCursor = 0;

    final cursor = payload['cursor'];
    if (cursor is int) {
      _cursor = cursor;
    }

    final hasMore = payload['hasMore'];
    if (hasMore is bool) {
      hasMoreHistory = hasMore;
    }

    final records = payload['records'];
    if (records is List) {
      _pendingRecords.addAll(records);
    }

    final projections = payload['projections'];
    if (projections is Map<String, dynamic>) {
      _applyProjections(projections);
    }

    /*
     * Nothing is folded here. The caller drives every slice — see
     * [foldSnapshotSlice] — so the frame this snapshot arrives on stays cheap:
     * folding even one slice inside the message handler put a spike on the
     * exact frame the mask appears, which is the stutter that shows up as the
     * mask briefly freezing before it starts to fill.
     */
    if (_pendingRecords.isEmpty) {
      _finishSnapshotFold();
    }
  }

  /// Records from the opening snapshot that have not been folded in yet.
  ///
  /// A snapshot carries the whole conversation. Folding it in a single pass
  /// blocks the frame the mask lifts on, which is what turned opening a long
  /// session into a pause followed by the whole transcript appearing at once.
  final List<dynamic> _pendingRecords = <dynamic>[];
  int _pendingCursor = 0;

  /// True while snapshot records are still waiting to be folded.
  bool get isFoldingSnapshot => _pendingCursor < _pendingRecords.length;

  /// Folds the next slice of snapshot records into the transcript.
  ///
  /// One record per call by default: the transcript is meant to grow visibly
  /// under the loading mask, a message at a time, so the page arrives already
  /// rendered rather than appearing in a lump when the mask lifts. Returns true
  /// when more remain, so the caller can schedule another frame rather than
  /// driving the whole history through in one loop. A cursor is used rather
  /// than removing from the front, which would make this O(n²) on a long
  /// conversation.
  bool foldSnapshotSlice({int max = 8}) {
    var folded = 0;
    while (_pendingCursor < _pendingRecords.length && folded < max) {
      final record = _pendingRecords[_pendingCursor++];
      folded++;
      final event = _eventOf(record);
      if (event != null) {
        _applyEvent(event, fromHistory: true);
      }
    }

    if (_pendingCursor >= _pendingRecords.length) {
      _finishSnapshotFold();
      return false;
    }
    return true;
  }

  /// Closes out a snapshot once every record has been folded.
  void _finishSnapshotFold() {
    _pendingRecords.clear();
    _pendingCursor = 0;

    /* Anything still marked streaming came from history, so it is settled. */
    _closeStreaming();

    /*
     * Let the window decide whether a turn is in flight. Without this a
     * conversation opened while its answer was being written showed no stop
     * button: the running turn's start is in the replayed history, and history
     * is not allowed to raise the flag on its own.
     */
    turnRunning = _historyEndsOnOpenTurn;
  }

  /// Folds an older page of history in ahead of what is already loaded.
  ///
  /// `session/page` walks backwards from the oldest record held, so the reply
  /// carries events the store has never seen and which all sit *before* the
  /// current transcript. They go through the same folding as live events, then
  /// the list is put back into sequence order and de-duplicated, because a page
  /// boundary can repeat a record that is already held.
  void prependHistory(dynamic value) {
    if (value is! Map<String, dynamic>) {
      return;
    }
    final records = value['records'] ?? value['messages'];
    if (records is! List) {
      return;
    }

    final before = _items.length;
    for (final record in records) {
      final event = _eventOf(record);
      if (event != null) {
        _applyEvent(event, fromHistory: true);
      }
    }

    final hasMore = value['hasMore'];
    if (hasMore is bool) {
      hasMoreHistory = hasMore;
    }

    _items.sort((a, b) => a.seq.compareTo(b.seq));

    final seen = <int>{};
    _items.retainWhere((item) => seen.add(item.seq));

    if (_items.length == before) {
      /* Nothing new came back. Stop asking rather than requesting the same page
       * again on every scroll to the top. */
      hasMoreHistory = false;
    }
  }

  void _applyEvents(Map<String, dynamic>? payload) {
    if (payload == null) {
      return;
    }
    final session = payload['session'];
    if (session is String && _openSession != null && session != _openSession) {
      return;
    }
    final events = payload['events'];
    if (events is! List) {
      return;
    }
    for (final raw in events) {
      if (raw is Map<String, dynamic>) {
        _applyEvent(raw, fromHistory: false);
      }
    }
  }

  /// `session/control` carries queue, jobs and projection increments.
  void _applyControl(Map<String, dynamic>? payload) {
    /*
     * The workspace feed: dsh's authoritative archived-session set, as either a
     * `baseline` or an `archived` increment. The session list omits archived
     * sessions entirely, so this stream is the only place the client can learn
     * which ones they are — and the only way the set survives a restart.
     */
    final archived = payload?['archived'];
    if (archived is Map<String, dynamic>) {
      final value = archived['value'];
      final ids = value is Map<String, dynamic>
          ? value['archivedSessionIds']
          : archived['archivedSessionIds'];
      if (ids is List) {
        archivedSessionIds
          ..clear()
          ..addAll(ids.whereType<String>());
      }
    }

    /*
     * A forwarded waterfall event. `eventId` is what the answer is addressed
     * to; the sender captured the stream's client id from its ready frame.
     */
    final events = payload?['events'];
    if (events is Map<String, dynamic>) {
      final frame = events['type'];
      if (frame == 'waterfall') {
        final eventId = events['eventId'];
        final name = events['event'];
        if (eventId is String) {
          final request = events['request'];
          final entry = HostEvent(
            eventId: eventId,
            name: name is String ? name : 'unknown',
            request: request is Map<String, dynamic>
                ? request
                : const <String, dynamic>{},
          );
          /* One entry per eventId: a redelivery replaces rather than repeats. */
          pendingEvents.removeWhere((item) => item.eventId == eventId);
          pendingEvents.add(entry);
        }
      } else if (frame == 'cancel') {
        final eventId = events['eventId'];
        pendingEvents.removeWhere((item) => item.eventId == eventId);
      }
    }

    final control = payload?['control'];
    if (control is! Map<String, dynamic>) {
      return;
    }
    final type = control['type'];

    if (type == 'queue') {
      final sessionId = control['sessionId'];
      final items = control['items'];
      if (sessionId == _openSession && items is List) {
        queuedItems = items.whereType<Map<String, dynamic>>().toList(
          growable: false,
        );
      }
    } else if (type == 'baseline') {
      final queues = control['queues'];
      final mine = queues is Map<String, dynamic> ? queues[_openSession] : null;
      queuedItems = mine is List
          ? mine.whereType<Map<String, dynamic>>().toList(growable: false)
          : const <Map<String, dynamic>>[];
    }
    /*
     * A `projection` frame is one `{key, value}` pair, not a values block — the
     * control stream publishes finished projection values one at a time as they
     * land. A baseline carries the whole set in one go.
     */
    if (type == 'projection') {
      final key = control['key'];
      if (key is String) {
        _applyProjection(key, control['value']);
      }
    } else if (type == 'baseline') {
      final block = control['projections'] ?? control['value'];
      if (block is Map<String, dynamic>) {
        _applyProjections(block);
      }
    }
  }

  /// Replaces the session list from a `session/list` answer.
  ///
  /// Used by an explicit refresh, where the client asks for the list itself
  /// instead of waiting for the sender's next poll to notice a change.
  void setSessionsFromRpc(Map<String, dynamic> answer) {
    final items = answer['items'];
    if (items is! List) {
      return;
    }
    _sessions
      ..clear()
      ..addAll(items.whereType<Map<String, dynamic>>());
  }

  /// Replaces the transcript with an empty one, keeping the session open.
  ///
  /// An explicit refresh uses this before re-subscribing: the snapshot that
  /// follows rebuilds the transcript, and the session staying open is what
  /// keeps the composer on screen instead of flashing back to the picker.
  void reopenSession() {
    if (_openSession == null) {
      return;
    }
    _resetTranscript();
  }

  /// Drops every mirrored list.
  ///
  /// Called when the relay connection goes away. What the watch holds is a
  /// snapshot of a tunnel that no longer exists, and the sender republishes its
  /// current view as soon as a new one is up — so keeping the old copy only
  /// shows stale rows. Stale rows were also what made an archived session look
  /// like an ungrouped one: the summary needed to place it had already been
  /// replaced by a later list that no longer described it.
  void clearMirror() {
    _sessions.clear();
    archivedSessionIds.clear();
    archivedDigests.clear();
  }

  /// Waterfall events the Host is waiting on this client to answer.
  ///
  /// Approvals and agent questions arrive this way: the Host holds the listener
  /// open until a client replies through `$events/result`, so each entry keeps
  /// the `eventId` the answer has to quote alongside the decoded request.
  final List<HostEvent> pendingEvents = <HostEvent>[];

  /// The open session's pending queue, as the control stream reports it.
  ///
  /// dsh owns this list: every entry carries the `id` that `session/updateQueue`
  /// keys its edit, remove and steer actions on. A locally assembled copy could
  /// never address those entries, which is why the row buttons did nothing when
  /// they were wired to one.
  List<Map<String, dynamic>> queuedItems = const <Map<String, dynamic>>[];

  /// The text of one queued item, flattened out of its content blocks.
  static String queuedText(Map<String, dynamic> item) {
    final message = item['message'];
    final content = message is Map<String, dynamic> ? message['content'] : null;
    if (content is! List) {
      return '';
    }
    final buffer = StringBuffer();
    for (final block in content) {
      if (block is String) {
        buffer.write(block);
      } else if (block is Map<String, dynamic>) {
        final text = block['text'];
        if (text is String) {
          buffer.write(text);
        }
      }
    }
    return buffer.toString();
  }

  /// Workspace views, as published by the workspace feed.
  ///
  /// Grouping is by membership, not by directory: the web UI resolves a
  /// session's workspace through `workspace.sessionIds` and puts whatever is
  /// left under Ungrouped. `cwd` alone cannot answer that question — an
  /// unassigned session still has a directory, and two sessions in one
  /// directory can differ in account.
  List<Map<String, dynamic>> workspaces = const <Map<String, dynamic>>[];

  /// The workspace a session is accounted to, or null when it is unassigned.
  Map<String, dynamic>? workspaceOf(Map<String, dynamic> session) {
    final id = session['sessionId'];
    if (id is! String) {
      return null;
    }
    for (final workspace in workspaces) {
      final ids = workspace['sessionIds'];
      if (ids is List && ids.contains(id)) {
        return workspace;
      }
    }
    return null;
  }

  /// Sessions dsh reports as archived, kept current by the workspace feed.
  final Set<String> archivedSessionIds = <String>{};

  /// Summaries of sessions that have left the session list, keyed by id.
  ///
  /// Supplied by the sender with every list refresh. dsh omits archived
  /// sessions from `session/list`, so without these the archived scope could
  /// only show bare ids — which read as unnamed sessions with no directory.
  final Map<String, Map<String, dynamic>> archivedDigests =
      <String, Map<String, dynamic>>{};

  /// Applies one projection block.
  ///
  /// A baseline arrives as `{asOfSeq, values}` — the Host keeps the projected
  /// keys one level down — so it is unwrapped here and every caller can pass
  /// whatever block it happens to hold. Reading the keys straight off a
  /// baseline found nothing at all, which is why the model, the permission
  /// preset, the goal and the todos stayed unset on sessions that were
  /// reporting every one of them.
  void _applyProjections(Map<String, dynamic> raw) {
    final nested = raw['values'];
    final values = nested is Map<String, dynamic> ? nested : raw;
    for (final entry in values.entries) {
      _applyProjection(entry.key, entry.value);
    }
  }

  /// Applies one named projection value.
  ///
  /// Shared by the baseline, which carries every key at once, and the control
  /// stream's `projection` frames, which carry a single `{key, value}` pair.
  void _applyProjection(String key, dynamic value) {
    switch (key) {
      case 'goal':
        if (value is Map<String, dynamic>) {
          goal = value;
          goalSessionId = _openSession;
          /*
           * The projection nests the goal's own fields one level down:
           * `{goal: {id, revision, objective, phase, …}, roundsStarted, …}`.
           * Reading `objective` off the top level found nothing and left the
           * label empty, so the goal card read 暂无 even with a goal running.
           */
          final body = value['goal'];
          final text = body is Map<String, dynamic>
              ? body['objective']
              : value['objective'];
          goalLabel = text is String && text.isNotEmpty ? text : null;
        } else if (value == null) {
          goal = null;
          goalSessionId = null;
          goalLabel = null;
        }

      case 'todos':
        if (value is List) {
          todos = value.whereType<Map<String, dynamic>>().toList(
            growable: false,
          );
        }

      case 'modelSelection':
        if (value is Map<String, dynamic>) {
          final next = value['next'] ?? value['lastUsed'] ?? value['current'];
          /*
           * Only take a selection the Host actually resolved. Assigning the
           * resolved-to-nothing case would wipe the value the session's own
           * `model/selection` event had already delivered, and that event is
           * not re-sent.
           */
          if (next is Map<String, dynamic>) {
            modelSelection = next;
          }
        }

      case 'permissions':
        if (value is Map<String, dynamic>) {
          final current = value['currentValue'] ?? value['current'];
          if (current is String) {
            permissionPreset = current;
          }
          final options = value['options'];
          if (options is List) {
            permissionOptions = options
                .whereType<Map<String, dynamic>>()
                .toList(growable: false);
          }
        }

      case 'title':
        if (value is String && value.isNotEmpty) {
          title = value;
        }

      case 'agentPreset':
        agentPreset = value is String && value.isNotEmpty ? value : null;

      default:
        /* A projection contributed outside this compilation face: the Host
         * decides which keys exist, so an unknown one is ignored, not dropped
         * from anything this store owns. */
        break;
    }
  }

  /// Unwraps a history record: it may be the event itself or wrap it.
  Map<String, dynamic>? _eventOf(dynamic record) {
    if (record is! Map<String, dynamic>) {
      return null;
    }
    final inner = record['event'];
    if (inner is Map<String, dynamic>) {
      return inner;
    }
    return record['type'] is String ? record : null;
  }

  void _applyEvent(Map<String, dynamic> event, {required bool fromHistory}) {
    final type = event['type'];
    if (type is! String) {
      return;
    }

    final seq = event['seq'];
    final eventSeq = seq is int ? seq : _lastSeq;
    if (eventSeq > _lastSeq) {
      _lastSeq = eventSeq;
    }
    if (eventSeq > _cursor && !fromHistory) {
      _cursor = eventSeq;
    }
    if (_oldestSeq == 0 || eventSeq < _oldestSeq) {
      _oldestSeq = eventSeq;
    }

    final data = event['data'];
    final fields = data is Map<String, dynamic>
        ? data
        : const <String, dynamic>{};

    switch (type) {
      case 'user/message':
        _appendUserMessage(eventSeq, fields);
      case 'assistant/message':
        _appendAssistantMessage(eventSeq, fields);
      case 'assistant/chunk':
        /*
         * Accumulated for history as well as for the live stream. A snapshot's
         * records are the chunk rows themselves — they are not always paired
         * with a settled `assistant/message` — so skipping them here left a
         * freshly opened session with an empty transcript.
         *
         * Duplicates are prevented by [_foldedChunks], which drops a chunk
         * sequence the store has already folded, rather than by refusing
         * history outright.
         */
        _accumulateChunk(eventSeq, fields);
      case 'chunkrow/text-chunks':
        _accumulatePacked(eventSeq, fields, reasoning: false);
      case 'chunkrow/reasoning-chunks':
        _accumulatePacked(eventSeq, fields, reasoning: true);
      case 'tool/call':
        _appendToolCall(eventSeq, fields);
      case 'tool/result':
        _attachToolResult(fields);
      case 'approval/asked':
        _append(_approvalFrom(fields, eventSeq));
      case 'approval/policy':
        _append(
          StatusItem(
            seq: eventSeq,
            label: fields['policy'] == 'never'
                ? 'Auto-approve'
                : 'Ask before tools',
          ),
        );
      case 'permission/preset':
        final preset = fields['preset'];
        if (preset is String) {
          permissionPreset = preset;
        }
      case 'sandbox/mode':
        final mode = fields['mode'];
        if (mode is String) {
          sandboxMode = mode;
        }
      case 'plan/mode':
        planModeActive = fields['active'] == true;
        _append(
          StatusItem(
            seq: eventSeq,
            label: planModeActive ? 'Plan mode on' : 'Plan mode off',
          ),
        );
      case 'goal/change':
        _applyGoalChange(eventSeq, fields);
      case 'todo/write':
        final todos = fields['todos'];
        if (todos is List) {
          this.todos = todos.whereType<Map<String, dynamic>>().toList(
            growable: false,
          );
        }
      case 'model/selection':
        modelSelection = fields;
      case 'session/title':
        final value = fields['title'];
        if (value is String && value.isNotEmpty) {
          title = value;
        }
      case 'turn/end':
        _applyTurnEnd(eventSeq, fields, fromHistory: fromHistory);
      case 'command/done':
        final kind = fields['kind'];
        final text = fields['text'];
        if (kind == 'error' && text is String) {
          _append(
            StatusItem(seq: eventSeq, label: 'Command failed', detail: text),
          );
        }
      case 'turn/start':
        /*
         * A turn is running from here until `turn/end`, which is a wider window
         * than the streaming flag. A tool call closes the streaming row while
         * the turn carries on, so a stop button watching `streaming` vanished
         * exactly when the user most wanted it.
         *
         * Live events set the flag. A history replay does not — a page of older
         * history is full of turns that finished long ago — but it does record
         * where the window ends, because a window that stops after a start is a
         * turn still in flight, and opening that conversation has to show the
         * stop button.
         */
        if (fromHistory) {
          _historyEndsOnOpenTurn = true;
        } else {
          turnRunning = true;
        }
      case 'session/end-seed':
      case 'step/start':
      case 'step/end':
      case 'request/header':
      case 'request/context':
      case 'agent/inbox/spliced':
      case 'chunkrow/tool-call-chunks':
        break;
      default:
        /* Unknown or not surfaced on a watch; ignored on purpose. */
        break;
    }
  }

  /// Chinese label for a non-human `source.kind`.
  static String _sourceLabel(String kind) => switch (kind) {
    'tool' => '工具结果',
    'plugin' => '系统通知',
    'model' => '模型消息',
    _ => '系统',
  };

  void _appendUserMessage(int seq, Map<String, dynamic> fields) {
    final text = _textOfMessage(fields) ?? _textOfMessage(fields['message']);
    if (text == null || text.isEmpty) {
      return;
    }

    /*
     * `role: 'user'` does not mean "the user typed this". dsh records tool
     * results, plugin injections and job notices under that same role and tells
     * them apart by `source.kind` — only 'user' is a person writing. Showing the
     * rest under 你 attributed the harness's own words to the reader, which is
     * exactly what a background-job notice appearing as the user's message was.
     *
     * A missing source stays a user message: older logged events predate the
     * field, and guessing "system" for them would hide real answers.
     */
    final source = fields['source'];
    final kind = source is Map<String, dynamic> ? source['kind'] : null;
    if (kind is String && kind != 'user') {
      _append(StatusItem(seq: seq, label: _sourceLabel(kind), detail: text));
      return;
    }

    _closeStreaming();
    _append(UserMessageItem(seq: seq, text: text));
  }

  void _appendAssistantMessage(int seq, Map<String, dynamic> fields) {
    final message = fields['message'] ?? fields;
    final text = _textOfMessage(fields['message']) ?? _textOfMessage(fields);
    final reasoning = _reasoningOfMessage(message);
    final interrupted = fields['interrupted'] == true;

    final existing = _streamingItem;
    if (existing != null) {
      _replace(
        existing,
        existing.copyWith(
          text: (text == null || text.isEmpty) ? existing.text : text,
          reasoning: reasoning ?? existing.reasoning,
          streaming: false,
          interrupted: interrupted,
        ),
      );
      _streamText = '';
      _streamReasoning = '';
      return;
    }

    if (text == null || text.isEmpty) {
      return;
    }
    _append(
      AssistantMessageItem(
        seq: seq,
        text: text,
        reasoning: reasoning ?? '',
        interrupted: interrupted,
      ),
    );
  }

  void _accumulateChunk(int seq, Map<String, dynamic> fields) {
    /*
     * Sequences are unique per chunk event, and dsh can carry the same chunk on
     * more than one stream. Appending it twice produced text that read like
     * "修复修复修复" — the same fragment repeated as many times as it arrived.
     */
    if (!_foldedChunks.add(seq)) {
      return;
    }
    final chunk = fields['chunk'];
    if (chunk is! Map<String, dynamic>) {
      return;
    }
    final kind = chunk['type'];
    final text = _firstString(chunk, const ['text', 'delta', 'content']);

    if (kind is String && kind.contains('reason')) {
      if (text != null) {
        _streamReasoning += text;
      }
    } else if (text != null) {
      _streamText += text;
    } else {
      return;
    }
    _syncStreaming(seq);
  }

  /// Packed `chunkrow/*` rows carry several chunks at once.
  void _accumulatePacked(
    int seq,
    Map<String, dynamic> fields, {
    required bool reasoning,
  }) {
    /* Same de-duplication as the single-chunk path. */
    if (!_foldedChunks.add(seq)) {
      return;
    }
    final chunks = fields['chunks'];
    if (chunks is! List) {
      return;
    }
    final buffer = StringBuffer();
    for (final chunk in chunks) {
      if (chunk is Map<String, dynamic>) {
        final text = _firstString(chunk, const ['text', 'delta', 'content']);
        if (text != null) {
          buffer.write(text);
        }
      }
    }
    if (buffer.isEmpty) {
      return;
    }
    if (reasoning) {
      _streamReasoning += buffer.toString();
    } else {
      _streamText += buffer.toString();
    }
    _syncStreaming(seq);
  }

  /// Creates or updates the in-flight assistant row from the stream buffers.
  ///
  /// The row is found and replaced in one reverse walk. Going through
  /// [_streamingItem] and then [_replace] walked the list twice per chunk in
  /// opposite directions, and a chunk is the hottest event there is.
  void _syncStreaming(int seq) {
    if (_streamText.isEmpty && _streamReasoning.isEmpty) {
      return;
    }

    for (var i = _items.length - 1; i >= 0; i--) {
      final item = _items[i];
      if (item is AssistantMessageItem && item.streaming) {
        _items[i] = item.copyWith(text: _streamText, reasoning: _streamReasoning);
        return;
      }
      if (item is UserMessageItem) {
        break;
      }
    }

    _append(
      AssistantMessageItem(
        seq: seq,
        text: _streamText,
        reasoning: _streamReasoning,
        streaming: true,
      ),
    );
  }

  void _closeStreaming() {
    final existing = _streamingItem;
    if (existing != null) {
      _replace(existing, existing.copyWith(streaming: false));
    }
    _streamText = '';
    _streamReasoning = '';
  }

  void _appendToolCall(int seq, Map<String, dynamic> fields) {
    /*
     * The streaming row is deliberately left open.
     *
     * A tool call happens in the middle of a turn, not at the end of one: the
     * reply carries on afterwards. Closing the row here cleared its streaming
     * flag, so the settled `assistant/message` arriving later could no longer
     * find it — [_streamingItem] matches on that flag — and appended a second
     * copy of the same answer instead of filling in the row that was already
     * there. That is the duplication users saw.
     */
    final callId = fields['callId'];
    final name = fields['name'];
    if (callId is! String || name is! String) {
      return;
    }
    final arguments = fields['arguments'];
    _append(
      ToolCallItem(
        seq: seq,
        callId: callId,
        name: name,
        arguments: arguments is String ? arguments : jsonEncode(arguments),
      ),
    );
  }

  void _attachToolResult(Map<String, dynamic> fields) {
    final callId = fields['callId'];
    final message = fields['message'];
    final text = _textOfMessage(message) ?? '';

    var target = -1;
    for (var i = _items.length - 1; i >= 0; i--) {
      final item = _items[i];
      if (item is ToolCallItem &&
          item.pending &&
          (callId == null || item.callId == callId)) {
        target = i;
        break;
      }
    }
    if (target < 0) {
      return;
    }

    final call = _items[target] as ToolCallItem;
    _items[target] = call.withResult(
      text.isEmpty ? '(no output)' : text,
      error: fields['error'] != null,
    );
  }

  void _applyGoalChange(int seq, Map<String, dynamic> fields) {
    if (fields['operation'] == 'clear') {
      goalLabel = null;
      _append(StatusItem(seq: seq, label: 'Goal cleared'));
      return;
    }
    final goal = fields['goal'];
    if (goal is Map<String, dynamic>) {
      final objective = goal['objective'] ?? goal['title'];
      if (objective is String) {
        goalLabel = objective;
        _append(StatusItem(seq: seq, label: 'Goal updated', detail: objective));
        return;
      }
    }
    _append(StatusItem(seq: seq, label: 'Goal updated'));
  }

  void _applyTurnEnd(
    int seq,
    Map<String, dynamic> fields, {
    required bool fromHistory,
  }) {
    /*
     * Only a live end clears the flag. Paging older history replays the ends of
     * turns that finished long ago, so honouring them dropped the stop button
     * on a turn that was still running — the same mistake the start event made,
     * in the other direction. History records where the window ends instead.
     */
    if (fromHistory) {
      _historyEndsOnOpenTurn = false;
    } else {
      turnRunning = false;
    }
    _closeStreaming();
    final reason = fields['reason'];
    if (reason is! Map<String, dynamic>) {
      return;
    }
    switch (reason['kind']) {
      case 'aborted':
        _append(StatusItem(seq: seq, label: 'Interrupted'));
      case 'error':
        final error = reason['error'];
        _append(
          StatusItem(
            seq: seq,
            label: 'Turn failed',
            detail: error is Map<String, dynamic>
                ? '${error['message'] ?? error['code'] ?? ''}'
                : '',
          ),
        );
      case 'max-tokens':
        _append(StatusItem(seq: seq, label: 'Token limit reached'));
      case 'blocked':
        _append(StatusItem(seq: seq, label: 'Blocked'));
      default:
        break;
    }
  }

  ApprovalItem _approvalFrom(Map<String, dynamic> fields, int seq) {
    return ApprovalItem(
      seq: seq,
      approvalId: '${fields['id'] ?? ''}',
      toolName: '${fields['toolName'] ?? 'tool'}',
      reason: '${fields['reason'] ?? ''}',
    );
  }

  void _append(ChatItem item) {
    /*
     * Never two items with the same sequence. A re-subscribe replays events the
     * store has already folded — the snapshot and the live stream overlap by
     * design — and appending both copies showed the user their own conversation
     * twice.
     */
    for (final existing in _items) {
      if (existing.seq == item.seq) {
        return;
      }
    }

    /*
     * Sequence numbers are not enough on their own. A reply exists twice while
     * it is being written: the streaming row is created under the sequence of
     * the chunk that started it, and the settled message arrives later under
     * its own `assistant/message` sequence. Those two numbers differ, so the
     * check above cannot see that they are the same reply — and the finished
     * answer was appended beside the row it had just replaced.
     *
     * A finished assistant message that matches the last one exactly, text and
     * reasoning both, is the same reply.
     */
    if (item is AssistantMessageItem && !item.streaming) {
      final last = _items.isEmpty ? null : _items.last;
      if (last is AssistantMessageItem &&
          !last.streaming &&
          last.text == item.text &&
          last.reasoning == item.reasoning) {
        return;
      }
    }

    _items.add(item);
    if (_items.length > maxItems) {
      _items.removeRange(0, _items.length - maxItems);
    }
  }

  void _replace(ChatItem existing, ChatItem replacement) {
    final index = _items.indexOf(existing);
    if (index >= 0) {
      _items[index] = replacement;
    }
  }

  /// Pulls plain text out of a `content: ContentBlock[]` message, or accepts an
  /// already-plain string.
  String? _textOfMessage(dynamic message) {
    if (message is String) {
      return message;
    }
    if (message is! Map<String, dynamic>) {
      return null;
    }
    final content = message['content'];
    if (content is String) {
      return content;
    }
    if (content is! List) {
      final text = message['text'];
      return text is String ? text : null;
    }

    final buffer = StringBuffer();
    for (final block in content) {
      if (block is String) {
        buffer.write(block);
      } else if (block is Map<String, dynamic>) {
        final type = block['type'];
        final text = block['text'];
        if (text is String && (type == null || type == 'text')) {
          buffer.write(text);
        }
      }
    }
    return buffer.isEmpty ? null : buffer.toString();
  }

  String? _firstString(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is String && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  /// Pulls the reasoning out of a message.
  ///
  /// dsh keeps reasoning alongside the answer, either as its own field or as
  /// further blocks in the same `content` list. Missing this is why a reply
  /// loaded from history showed no thinking at all: the streaming path built
  /// reasoning as chunks arrived, but the settled path only ever read the text.
  String? _reasoningOfMessage(dynamic message) {
    if (message is! Map<String, dynamic>) {
      return null;
    }
    final direct = message['reasoning'];
    if (direct is String && direct.isNotEmpty) {
      return direct;
    }
    final content = message['content'];
    if (content is! List) {
      return null;
    }

    final buffer = StringBuffer();
    for (final block in content) {
      if (block is! Map<String, dynamic>) {
        continue;
      }
      final type = block['type'];
      final text = block['text'];
      if (text is! String) {
        continue;
      }
      if (type == 'reasoning' ||
          type == 'thinking' ||
          type == 'reasoning_text') {
        buffer.write(text);
      }
    }
    return buffer.isEmpty ? null : buffer.toString();
  }
}

/// One waterfall event awaiting this client's answer.
class HostEvent {
  HostEvent({required this.eventId, required this.name, required this.request});

  /// The id the answer must quote back.
  final String eventId;

  /// Event name, e.g. `approval/request`.
  final String name;

  /// The request body as the Host built it.
  final Map<String, dynamic> request;

  /// True for an approval, which has a fixed set of decisions.
  bool get isApproval => name.contains('approval');

  /// The tool being asked about, when the request names one.
  String get toolName {
    final value = request['toolName'];
    return value is String ? value : 'tool';
  }

  /// Why the decision is needed.
  String? get reason {
    final value = request['reason'];
    return value is String && value.isNotEmpty ? value : null;
  }

  /// The questions an `ask-user` request carries.
  List<Map<String, dynamic>> get questions {
    final raw = request['questions'];
    if (raw is! List) {
      return const <Map<String, dynamic>>[];
    }
    return raw.whereType<Map<String, dynamic>>().toList(growable: false);
  }
}
