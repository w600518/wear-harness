import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../relay/relay_client.dart';
import '../relay/session_store.dart';

/*
 * Pages hold a RelaySession, not a RelayClient, so the status and error types a
 * page renders are re-exported here. Without this every page would import the
 * transport layer just to name a status.
 */
export '../relay/relay_client.dart'
    show RelayException, RelayStatus, RelayStatusUpdate;

/// Connection settings the user edits on the watch.
///
/// Values are persisted, so a watch that is taken off and put back on does not
/// ask for the relay address and passphrase again.
class SettingsStore extends ChangeNotifier {
  static const String _kHost = 'relay.host';
  static const String _kPort = 'relay.port';
  static const String _kPassphrase = 'relay.passphrase';
  static const String _kDeviceName = 'relay.deviceName';

  /*
   * Empty on purpose: nothing here is a deployment fact the app could know.
   * A prefilled address sent a first-run connection to somebody else's host,
   * and a prefilled port hid the fact that it is the user's own relay to
   * describe. The fields start blank and the connection stays refused until
   * they are filled in — `isComplete` is what gates it.
   */
  String _host = '';
  int _port = 0;
  String _passphrase = '';
  String _deviceName = '';

  /// True once [load] has finished, successfully or not.
  bool get isLoaded => _loaded;
  bool _loaded = false;

  /// Reads whatever was saved. Call once at startup, before the UI needs it.
  ///
  /// A failure here is not fatal: the app still runs on the built-in defaults,
  /// it just will not remember anything.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _host = prefs.getString(_kHost) ?? _host;
      _port = prefs.getInt(_kPort) ?? _port;
      _passphrase = prefs.getString(_kPassphrase) ?? _passphrase;
      _deviceName = prefs.getString(_kDeviceName) ?? _deviceName;
    } on Object {
      /* Fall through to the defaults already in the fields. */
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kHost, _host);
      await prefs.setInt(_kPort, _port);
      await prefs.setString(_kPassphrase, _passphrase);
      await prefs.setString(_kDeviceName, _deviceName);
    } on Object {
      /* Best effort: the in-memory value still applies for this session. */
    }
  }

  String get host => _host;
  int get port => _port;
  String get passphrase => _passphrase;
  String get deviceName => _deviceName;

  set host(String value) {
    _host = value.trim();
    notifyListeners();
    unawaited(_persist());
  }

  set port(int value) {
    _port = value;
    notifyListeners();
    unawaited(_persist());
  }

  set passphrase(String value) {
    _passphrase = value;
    notifyListeners();
    unawaited(_persist());
  }

  set deviceName(String value) {
    _deviceName = value.trim();
    notifyListeners();
    unawaited(_persist());
  }

  RelayConfig toConfig() => RelayConfig(
    host: _host,
    port: _port,
    passphrase: _passphrase,
    deviceName: _deviceName.isEmpty ? 'wear' : _deviceName,
  );

  /// True when enough is filled in to attempt a connection.
  bool get isComplete =>
      _host.isNotEmpty && _port > 0 && _passphrase.length >= 8;
}

/// One interjection sent from this watch.
///
/// Mutable on purpose: the list is a small scratch pad the user can edit and
/// send again from, not an append-only log.
class Interjection {
  Interjection({required this.text});

  String text;
  final DateTime sentAt = DateTime.now();

  /// Stable identity for list keys, independent of the text.
  final String id = DateTime.now().microsecondsSinceEpoch.toString();
}

/// Owns the relay connection and the mirrored state for the whole app.
///
/// A single instance lives above the widget tree so navigation between pages
/// does not drop the socket or the folded transcript.
class RelaySession extends ChangeNotifier {
  RelaySession({required this.settings});

  final SettingsStore settings;

  RelayClient? _client;
  StreamSubscription<RelayMessage>? _messageSubscription;
  StreamSubscription<RelayStatusUpdate>? _statusSubscription;
  Timer? _reconnectTimer;

  /// Pings the relay, and notices when a ping goes unanswered.
  Timer? _pingTimer;

  /// True between sending a ping and seeing its pong come back.
  bool _awaitingPong = false;

  /// How often the watch pings the relay.
  ///
  /// The sender has always kept its own link warm every 25 seconds, but nothing
  /// kept the watch's: an idle TCP connection is the first thing NAT tables,
  /// carrier gateways and routers drop, and a connection dropped from the
  /// middle produces no FIN and no error. The socket stays open as far as the
  /// app can tell, so it reported "connected" while receiving nothing — which
  /// is the intermittent disconnect this heartbeat exists to fix. The same
  /// cadence as the sender keeps the mapping warm on both halves.
  static const Duration _pingInterval = Duration(seconds: 25);

  final store = SessionStore();

  RelayStatus _status = RelayStatus.disconnected;
  String? _lastError;
  String? _selectedDevice;
  bool _reconnectWanted = false;

  RelayStatus get status => _status;
  String? get lastError => _lastError;
  bool get isConnected => _status == RelayStatus.connected;

  /// True whenever there is a live connection, in either direction.
  ///
  /// This is about the socket, not about work: a connected watch with nothing
  /// running is [isBusy] but not [isTurnRunning].
  bool get isBusy =>
      _status == RelayStatus.connecting || _status == RelayStatus.connected;

  /// True while a turn is actually running and can be interrupted.
  ///
  /// Read from the turn markers rather than the streaming flag: a turn spends
  /// most of its life running tools, during which nothing streams but the turn
  /// is in progress and interruptible. Watching `streaming` made the stop
  /// button disappear exactly when there was a tool call to stop.
  bool get isTurnRunning => store.turnRunning;

  List<Map<String, dynamic>> get devices => _client?.devices ?? const [];
  String? get selectedDevice => _selectedDevice;

  /// The sender that answers requests: the user's pick, or the only one online.
  String? get activeDevice {
    if (_selectedDevice != null &&
        devices.any((device) => device['id'] == _selectedDevice)) {
      return _selectedDevice;
    }
    return devices.length == 1 ? devices.first['id'] as String? : null;
  }

  void selectDevice(String? deviceId) {
    _selectedDevice = deviceId;
    notifyListeners();
  }

  /// Connects, keeping the socket open until [disconnect] is called.
  Future<void> connect() async {
    _reconnectWanted = true;
    await _open();
  }

  /// True while a connection attempt is in flight.
  bool _opening = false;

  Future<void> _open() async {
    /*
     * One attempt at a time. [_open] starts by tearing down whatever socket is
     * already there, so two overlapping calls each close the connection the
     * other has just established — which the sender logs as a link that is
     * established and closed again within the same millisecond, repeating.
     */
    if (_opening) {
      return;
    }
    _opening = true;
    try {
      await _openOnce();
    } finally {
      _opening = false;
    }
  }

  Future<void> _openOnce() async {
    if (!settings.isComplete) {
      _lastError =
          'Fill in host, port and a passphrase of at least 8 characters.';
      _status = RelayStatus.failed;
      notifyListeners();
      return;
    }

    await _teardown();
    _status = RelayStatus.connecting;
    _lastError = null;
    notifyListeners();

    final client = RelayClient(config: settings.toConfig());
    _client = client;

    _messageSubscription = client.messages.listen((message) {
      /*
       * A pong is the relay proving the link is still there. It is consumed
       * here rather than forwarded to the store: it is transport bookkeeping,
       * not something the transcript has any use for.
       */
      if (message.kind == 'pong') {
        _awaitingPong = false;
        return;
      }

      /*
       * The model this session runs on arrives with the projections, some time
       * after the session opens. When it changes, the reasoning control has to
       * be re-derived: it exists only if that model takes a reasoning setting.
       * The provider counts as part of that identity — two providers can carry
       * the same model id under different reasoning ladders.
       */
      final before = _modelIdentity();
      final wasRunning = store.turnRunning;
      store.applyMessage(message);

      /*
       * A snapshot brings the whole conversation with it. Fold the first slice
       * now; the rest follows one slice per frame, so the transcript builds up
       * under the mask instead of landing in one stalled pass.
       */
      if (store.isFoldingSnapshot) {
        /*
         * Once per opening, not once per message. The folding window stays open
         * across every message that arrives while the history is being folded.
         */
        _hadSnapshot = true;
        _pumpSnapshot();
      } else if (store.hasSnapshot && !_hadSnapshot) {
        _hadSnapshot = true;
        _holdShieldForLayout();
      }
      final after = _modelIdentity();
      if (after != before) {
        unawaited(refreshModelCapabilities());
      }
      /*
       * A turn that just ended is the moment the account figure has moved, so
       * it is the moment to re-read it. Watching the falling edge rather than
       * every frame keeps this to one request per reply instead of one per
       * streamed chunk.
       */
      if (wasRunning && !store.turnRunning) {
        unawaited(refreshBalance());
      }
      _notifySoon();
    });

    _statusSubscription = client.status.listen((update) {
      _status = update.status;
      if (update.error != null) {
        _lastError = '${update.error!.code}: ${update.error!.message}';
      }
      /* A dropped connection retries on its own so a watch left on a wrist
       * recovers without the user reopening the app. */
      if (update.status == RelayStatus.failed && _reconnectWanted) {
        _scheduleReconnect();
      }
      notifyListeners();
    });

    try {
      await client.connect();
      _lastError = null;
      /* The link is up, so start proving it stays up. */
      _startHeartbeat();
      /*
       * An empty session browser has two very different causes — the sender
       * cannot reach its dsh at all, or its dsh simply has no sessions — and
       * only the sender can tell them apart. Ask it right after connecting.
       */
      await _refreshRelayStatus();

      /*
       * Re-subscribe whatever session is open. Opening the app goes straight to
       * the last session, and that happens before the connection finishes: the
       * subscribe had no client to go through, and nothing retried it once the
       * relay came up.
       */
      final open = store.openSessionId;
      if (open != null) {
        await _subscribeTo(open);
      }
    } on RelayException catch (error) {
      _status = RelayStatus.failed;
      _lastError = '${error.code}: ${error.message}';
      if (_reconnectWanted) {
        _scheduleReconnect();
      }
    } on Object catch (error) {
      _status = RelayStatus.failed;
      _lastError = '$error';
      if (_reconnectWanted) {
        _scheduleReconnect();
      }
    }

    notifyListeners();
  }

  /// The last `relay/status` answer from the sender, or null if unknown.
  Map<String, dynamic>? relayStatus;

  /// True when the sender reported a working link to its local dsh.
  bool get senderDshReachable => relayStatus?['dshReachable'] == true;

  /// Asks the active sender about itself: dsh reachability, event mux, follows.
  Future<void> _refreshRelayStatus() async {
    final client = _client;
    if (client == null) {
      return;
    }
    try {
      /*
       * `request` already returns the value carried by the result envelope, so
       * this is the status object itself. Unwrapping a second `value` key here
       * produced null every time, which is why the browser sat on "正在询问发送端
       * 状态" even though the sender had answered.
       */
      relayStatus = await client.request('relay/status', device: activeDevice);
    } on RelayException {
      relayStatus = null;
    }
  }

  /// Reasoning efforts the current model accepts, empty when it takes none.
  ///
  /// Read from the model catalog: a model that supports reasoning carries a
  /// `reasoning` object listing its efforts. The composer offers its control
  /// only while this is non-empty.
  List<Map<String, dynamic>> reasoningEfforts = const <Map<String, dynamic>>[];

  /// The effort in force, as reported by the model-selection projection.
  String? get currentReasoningEffort {
    final selection = store.modelSelection;
    final effort = selection?['reasoningEffort'];
    return effort is String ? effort : null;
  }

  /// True when the session's model takes a reasoning setting.
  bool get supportsReasoning => reasoningEfforts.isNotEmpty;

  /// The provider/model pair the reasoning control is derived from.
  ///
  /// Used to notice a switch: the control has to be re-read whenever either
  /// half changes, not only when the model id does.
  String? _modelIdentity() {
    final selection = store.modelSelection;
    final provider = selection?['provider'];
    final model = selection?['model'];
    if (model is! String || model.isEmpty) {
      return null;
    }
    return provider is String ? '$provider/$model' : model;
  }

  /// Finds the catalog entry for the session's current model.
  ///
  /// The catalog is a tree of provider groups, so this walks it rather than
  /// assuming a flat list. The provider decides which group to look in first:
  /// two providers can expose the same model id with different reasoning
  /// ladders, and taking the first id match would then offer the wrong levels.
  Map<String, dynamic>? _catalogEntryFor(
    Map<String, dynamic> catalog,
    String? provider,
    String? model,
  ) {
    if (model == null) {
      return null;
    }
    final groups = catalog['groups'] ?? catalog['items'];
    if (groups is! List) {
      return null;
    }
    Map<String, dynamic>? fallback;
    for (final group in groups) {
      if (group is! Map<String, dynamic>) {
        continue;
      }
      final models = group['models'] ?? group['items'];
      if (models is! List) {
        continue;
      }
      for (final entry in models) {
        if (entry is! Map<String, dynamic> || entry['id'] != model) {
          continue;
        }
        if (provider != null && group['id'] == provider) {
          return entry;
        }
        fallback ??= entry;
      }
    }
    return fallback;
  }

  /// The label to show for one reasoning effort.
  ///
  /// Each model names its own levels and different providers name them
  /// differently, so the host's own name always wins — the control follows
  /// whatever the selected model calls its levels. Only when the catalog
  /// leaves a level unnamed does the id get a readable label instead of a bare
  /// `low` on screen.
  String reasoningLabel(Map<String, dynamic> effort) {
    final name = effort['name'];
    if (name is String && name.isNotEmpty) {
      return name;
    }
    return switch ('${effort['id']}') {
      'off' => '关闭',
      'low' => '低',
      'medium' => '中',
      'high' => '高',
      'max' => '最高',
      final other => other,
    };
  }

  Timer? _capabilityRetry;

  /// Re-reads what the session's model can be configured with.
  ///
  /// Called when a session is opened, so the composer knows whether to offer a
  /// reasoning control at all. The model-selection projection may not have
  /// arrived yet at that point, in which case the catalog's own default names
  /// the model — without that fallback the control was simply never offered.
  ///
  /// The catalog is served over the same mux the session stream uses, so a read
  /// that lands before that mux comes up returns nothing at all. Retrying is
  /// what stops the control from being decided by whichever of the two won that
  /// race.
  Future<void> refreshModelCapabilities({int attempt = 0}) async {
    final catalog = await modelCatalog();
    if (catalog == null) {
      if (attempt >= 4) {
        return;
      }
      _capabilityRetry?.cancel();
      _capabilityRetry = Timer(Duration(milliseconds: 900 * (attempt + 1)), () {
        unawaited(refreshModelCapabilities(attempt: attempt + 1));
      });
      return;
    }

    _applyCatalog(catalog);
  }

  /// Folds a model catalog into the reasoning control's state.
  ///
  /// Split out of [refreshModelCapabilities] because the catalog now arrives
  /// two ways: on its own, and packed into the bundle the relay answers when a
  /// conversation is opened.
  void _applyCatalog(Map<String, dynamic> catalog) {
    final selection = store.modelSelection;
    final fromSelection = selection?['model'];
    Object? model = fromSelection;
    Object? provider = selection?['provider'];
    if (model is! String || model.isEmpty) {
      final fallback = catalog['default'];
      if (fallback is Map<String, dynamic>) {
        model = fallback['model'];
        provider = fallback['provider'];
      }
    }

    final entry = _catalogEntryFor(
      catalog,
      provider is String ? provider : null,
      model is String ? model : null,
    );
    final reasoning = entry?['reasoning'];
    final efforts = reasoning is Map<String, dynamic>
        ? reasoning['efforts']
        : null;
    final listed = efforts is List
        ? efforts.whereType<Map<String, dynamic>>().toList()
        : <Map<String, dynamic>>[];

    /*
     * dsh returns efforts in whatever order the adapter declares. The watch
     * shows one ladder — Off, Low, High, Max — so the order is normalised
     * rather than inherited: Off belongs at the left end, where it reads as
     * the bottom of the same scale instead of an afterthought behind Max.
     * Anything unrecognised keeps its host order, after the known ids.
     */
    const strength = <String>['off', 'low', 'medium', 'high', 'max'];
    listed.sort((a, b) {
      final left = strength.indexOf('${a['id']}');
      final right = strength.indexOf('${b['id']}');
      return (left < 0 ? strength.length : left).compareTo(
        right < 0 ? strength.length : right,
      );
    });

    reasoningEfforts = List<Map<String, dynamic>>.unmodifiable(listed);
    notifyListeners();
  }

  /// One round trip for everything opening a conversation needs.
  ///
  /// Called once, when a conversation is tapped. The model catalog used to be a
  /// request of its own fired straight after the subscribe, and each reply
  /// rebuilt the page separately; the relay now answers the opening state in
  /// one message, so the composer settles after a single round trip. Only the
  /// catalog is asked for — the session list is already held, and the balance
  /// belongs to the config page — which keeps the reply small rather than
  /// shipping state this page has no use for.
  Future<void> _refreshOpenBundle() async {
    final client = _client;
    if (client == null) {
      return;
    }
    try {
      final bundle = await client.request(
        'relay/bundle',
        device: activeDevice,
        payload: const <String, dynamic>{
          'sessions': false,
          'catalog': true,
          'balance': false,
        },
      );
      if (bundle.isEmpty) {
        return;
      }
      final catalog = bundle['catalog'];
      if (catalog is Map<String, dynamic>) {
        _applyCatalog(catalog);
      }
      final errors = bundle['errors'];
      if (errors is Map<String, dynamic> && errors.containsKey('catalog')) {
        /* The session still opens; only the reasoning control goes without. */
        _lastError = 'relay/catalog: ${errors['catalog']}';
        notifyListeners();
      }
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
    }
  }

  /// Switches the reasoning effort of the session's current model.
  Future<void> setReasoningEffort(String effort) async {
    final selection = store.modelSelection;
    final provider = selection?['provider'];
    final model = selection?['model'];
    if (provider is! String || model is! String) {
      return;
    }
    await selectModel(provider, model, reasoningEffort: effort);
    notifyListeners();
  }

  /// Re-pulls the list until [sessionId] appears in it, or the retries run out.
  ///
  /// Backs off a little each time: the first few attempts cover the gap between
  /// a create committing and the list being rebuilt, and the last couple cover
  /// a slow round trip. The poll timer is the backstop if all of them miss.
  void _refreshUntilVisible(String sessionId, {int attempt = 0}) {
    if (attempt >= 5 || _disposed) {
      return;
    }
    Timer(Duration(milliseconds: 350 * (attempt + 1)), () async {
      if (_disposed) {
        return;
      }
      final present = store.sessions.any(
        (session) => session['sessionId'] == sessionId,
      );
      if (!present) {
        await refreshSessions();
      }
      _refreshUntilVisible(sessionId, attempt: attempt + 1);
    });
  }

  /// Re-reads the session list from the sender.
  ///
  /// Called after any operation that changes what the browser shows — rename,
  /// archive, fork, create, delete — so the page reflects it at once instead of
  /// waiting for the sender's next poll to notice the difference.
  ///
  /// Also called as the browser comes into view, which is what keeps the
  /// archived set honest: archiving happens in the workspace registry, and a
  /// session archived from another client (or from the web UI) leaves no trace
  /// on this watch until the list — and the `archivedSessionIds` that travel
  /// with it — are read again. Without that the session stayed under its
  /// workspace heading, and opening it worked, despite being archived.
  Future<void> refreshSessions() async {
    final client = _client;
    if (client == null) {
      return;
    }
    try {
      final answer = await client.request(
        'sessions/list',
        device: activeDevice,
      );
      store.setSessionsFromRpc(answer);
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
    }
    notifyListeners();
  }

  /// Re-reads everything the watch mirrors from the sender.
  ///
  /// For when a page looks stale and the user would rather force it than wait
  /// for the next poll. This is the one place that pulls every source the watch
  /// keeps, so it covers what the individual refresh paths each do on their own
  /// triggers: the sender's status, the session list, the open session's
  /// subscription and transcript, the account balance, the open model's
  /// capabilities, and the approvals or questions the Host is holding.
  Future<void> refreshAll() async {
    final client = _client;
    if (client == null) {
      return;
    }

    await _refreshRelayStatus();

    try {
      final answer = await client.request(
        'sessions/list',
        device: activeDevice,
      );
      store.setSessionsFromRpc(answer);
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
    }

    /*
     * Re-subscribing is what brings a fresh snapshot. The session stays open —
     * only its transcript is dropped — so the composer does not flicker back to
     * the picker while the reply is on its way.
     */
    final open = store.openSessionId;
    if (open != null) {
      store.reopenSession();
      _armSnapshotDeadline();
      await _subscribeTo(open);
    }

    /*
     * The rest of the mirrored state, in parallel: none of these depends on the
     * others, and a stale page is exactly the case where waiting on each in
     * turn would be felt.
     */
    await Future.wait(<Future<void>>[
      refreshBalance(),
      refreshModelCapabilities(),
      /* Forced: the throttle exists to stop a burst of session switches from
       * churning the event stream, and an explicit refresh is not a burst. */
      refreshPendingEvents(force: true),
    ]);

    notifyListeners();
  }

  /// Waterfall events the Host is waiting on this client to answer.
  List<HostEvent> get pendingEvents => store.pendingEvents;

  /// When the forwarded-event stream was last re-opened.
  DateTime? _lastEventRefresh;

  /// How long two re-opens have to be apart.
  ///
  /// Re-opening drops the sender's current event client and registers a new
  /// one, and an answer sent inside that window names a client the gateway has
  /// already forgotten. A conversation is opened far more often than the window
  /// is worth re-entering, so the throttle keeps a burst of session switches
  /// from churning the stream.
  static const Duration _eventRefreshInterval = Duration(seconds: 5);

  /// Asks the sender to re-open the forwarded-event stream.
  ///
  /// The Host replays every pending waterfall to a client at the moment its
  /// `$events` stream registers, and that replay is the only one it offers: a
  /// frame delivered while nothing was listening is never sent again. So a
  /// watch that opens a conversation after the ask was raised has no record of
  /// it at all, and re-subscribing is the one way to be told. This is what
  /// makes an approval or a question raised before the conversation was opened
  /// answerable instead of invisible.
  Future<void> refreshPendingEvents({bool force = false}) async {
    final client = _client;
    if (client == null) {
      return;
    }
    final now = DateTime.now();
    final last = _lastEventRefresh;
    if (!force &&
        last != null &&
        now.difference(last) < _eventRefreshInterval) {
      return;
    }
    _lastEventRefresh = now;
    try {
      await client.request('events/refresh', device: activeDevice);
    } on RelayException catch (error) {
      /* Not fatal: the stream the sender already holds keeps working, so a
         failed refresh only means the replay did not happen this time. */
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
    }
  }

  /// Answers one pending waterfall event, releasing the Host's listener.
  ///
  /// `outcome` is the value the Host waterfall listener resolves with: the
  /// decision string for an approval, or `{answers: [...]}` for a question. It
  /// travels unmodified, because the Host hands it straight to the plugin that
  /// raised the request. The sender forwards it to `$events/result` with the
  /// client id the event stream reported.
  ///
  /// Returns whether the Host took the answer. A caller that keeps the question
  /// on screen needs that: the Host holds the turn paused until some client
  /// answers, so silently dropping a failure would look exactly like a decision
  /// that had been made.
  Future<bool> respondToEvent(
    String eventId,
    Object outcome, {
    String kind = 'result',
  }) async {
    final client = _client;
    if (client == null) {
      _lastError = 'relay/not-connected: the relay is not connected';
      notifyListeners();
      return false;
    }
    try {
      await client.request(
        'events/respond',
        payload: {'eventId': eventId, 'kind': kind, 'value': outcome},
        device: activeDevice,
      );
      /* The Host will drop it from the stream; this keeps the UI immediate. */
      store.pendingEvents.removeWhere((item) => item.eventId == eventId);
      _lastError = null;
      notifyListeners();
      return true;
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
      return false;
    }
  }

  /// Approves or refuses the pending approval, if any.
  ///
  /// The Host listener resolves with a bare `ApprovalDecision`, so `decision`
  /// travels as the value itself rather than wrapped in a record.
  Future<bool> answerApproval(HostEvent event, String decision) =>
      respondToEvent(event.eventId, decision);

  /// Answers one question with a single option label or a custom answer.
  ///
  /// The Host reads `selected` as the labels it offered and `custom` as the
  /// user's own words; a custom answer carries no selection, mirroring the Web
  /// client's single-select rule.
  Future<bool> answerQuestion(
    HostEvent event,
    String questionId,
    String value, {
    bool custom = false,
  }) => respondToEvent(event.eventId, {
    'answers': [
      if (custom)
        {'id': questionId, 'selected': const <String>[], 'custom': value}
      else
        {
          'id': questionId,
          'selected': <String>[value],
        },
    ],
  });

  /// Answers every question of one request at once.
  ///
  /// The Host asked them together and is waiting on a single reply, so the
  /// answers travel as one list keyed by question id. `answers` is built by the
  /// caller, which is the only layer that knows whether each choice is one of
  /// the offered labels or a custom answer.
  Future<bool> answerQuestions(
    HostEvent event,
    List<Map<String, dynamic>> answers,
  ) => respondToEvent(event.eventId, {'answers': answers});

  /// Re-reads the sender status on demand, e.g. when a page becomes visible.
  Future<void> refreshRelayStatus() async {
    await _refreshRelayStatus();
    notifyListeners();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 6), () {
      if (_reconnectWanted && _status != RelayStatus.connected) {
        unawaited(_open());
      }
    });
  }

  /// Starts pinging the relay on a fixed cadence.
  void _startHeartbeat() {
    _pingTimer?.cancel();
    _awaitingPong = false;
    _pingTimer = Timer.periodic(_pingInterval, (_) => _heartbeat());
  }

  void _stopHeartbeat() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _awaitingPong = false;
  }

  void _heartbeat() {
    final client = _client;
    if (client == null || _disposed) {
      return;
    }
    if (_status != RelayStatus.connected) {
      return;
    }

    if (_awaitingPong) {
      /*
       * The previous ping was never answered, so this link is dead even though
       * the socket still looks open. Nothing else would notice: there is no
       * close, no error, and on an idle watch no traffic either. Drop it and
       * let the reconnect path run, rather than leaving the app on a link that
       * reports connected and delivers nothing.
       */
      _dropDeadLink();
      return;
    }

    _awaitingPong = true;
    unawaited(client.ping());
  }

  /// Tears down a link that stopped answering, and reconnects if the user
  /// still wants to be connected.
  void _dropDeadLink() {
    _stopHeartbeat();
    _status = RelayStatus.failed;
    _lastError = 'relay/keepalive: 连接已失效，正在重连';
    unawaited(_teardown());
    notifyListeners();
    if (_reconnectWanted) {
      _scheduleReconnect();
    }
  }

  /// Closes the connection and stops reconnecting.
  Future<void> disconnect() async {
    _reconnectWanted = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _teardown();
    _status = RelayStatus.disconnected;
    notifyListeners();
  }

  Future<void> _teardown() async {
    /*
     * The mirrored lists belong to the tunnel being closed. The sender
     * republishes them on the next connection, so clearing here is what keeps
     * a reconnect from showing rows that describe a state dsh has moved past.
     */
    store.clearMirror();
    _snapshotTimer?.cancel();
    _subscribeTimer?.cancel();
    _stopHeartbeat();
    /* A shield held for a layout that is no longer coming would never lift. */
    _shieldHeld = false;

    await _messageSubscription?.cancel();
    _messageSubscription = null;
    await _statusSubscription?.cancel();
    _statusSubscription = null;

    final client = _client;
    _client = null;
    await client?.dispose();
  }

  /// Opens a session and subscribes to its history and live events.
  Future<void> openSession(String sessionId) async {
    final client = _client;
    if (client == null) {
      return;
    }

    /*
     * Release the stream the previous session was using. The sender caps how
     * many it can follow at once, and leaving the old one open spent a slot for
     * a session nobody is looking at — enough switching and new sessions could
     * no longer be followed at all.
     */
    final previous = store.openSessionId;
    if (previous != null && previous != sessionId) {
      unawaited(
        client
            .unsubscribe(previous, device: activeDevice)
            .catchError((Object _) => null),
      );
    }

    store.openSession(sessionId);
    /* Each conversation gets its own snapshot moment to wait for. */
    _hadSnapshot = false;
    _shieldHeld = false;
    _armSnapshotDeadline();
    notifyListeners();
    await _subscribeTo(sessionId);

    /*
     * A question or an approval raised while this conversation was not on
     * screen was delivered to nobody, and the Host never re-sends it. Re-opening
     * the forwarded-event stream makes it replay everything it is still
     * holding, so walking into a conversation shows what is waiting in it.
     */
    unawaited(refreshPendingEvents());

    /*
     * The model's capabilities belong to the session that just opened: which
     * reasoning efforts exist is a property of the selected model, so it has to
     * be re-read rather than carried over from the previous session. It comes
     * back on the opening bundle, so this is one round trip rather than two.
     */
    await _refreshOpenBundle();
  }

  Timer? _subscribeTimer;

  /// True while a subscribe attempt is outstanding, including the wait between
  /// two retries.
  ///
  /// The opening snapshot cannot arrive before dsh accepts the stream, so a
  /// conversation whose subscribe is still being retried has no transcript yet
  /// — and is not an empty one either. A purely time-based deadline cannot tell
  /// those apart, which is what put 没有消息 over conversations that were
  /// seconds away from loading.
  bool _subscribing = false;

  /// Subscribes to a session, retrying while the sender's mux comes up.
  ///
  /// The sender's dsh event mux connects a moment after the relay does, and a
  /// subscribe arriving inside that window is refused outright. Retrying covers
  /// the gap — without it, opening the app straight into a session left the
  /// transcript empty on an error the user had no way to clear, while sending a
  /// message worked fine because that path does not need the mux.
  Future<void> _subscribeTo(String sessionId, {int attempt = 0}) async {
    final client = _client;
    if (client == null || _disposed) {
      return;
    }
    _subscribing = true;
    try {
      await client.subscribe(sessionId, device: activeDevice);
      _subscribing = false;
      if (store.openSessionId == sessionId) {
        /*
         * The wait for the snapshot starts here, not when the session was
         * opened.
         *
         * A subscribe that took a few seconds — or went through retries while
         * the sender's mux was still coming up — had already spent the window,
         * so the shield dropped the instant the stream opened and the page sat
         * on "这个会话还没有消息" until the records landed: the few seconds of
         * nothing between the mask disappearing and the conversation appearing.
         * Re-arming measures the wait that actually matters, from an open
         * stream to its first snapshot, and stays bounded because the deadline
         * re-subscribes when it lapses.
         */
        if (!store.hasSnapshot) {
          _armSnapshotDeadline();
        }
        /* The refusal never reached dsh, so nothing else would clear it. */
        _lastError = null;
        notifyListeners();
      }
    } on RelayException catch (error) {
      if (attempt >= 6) {
        /* Out of attempts: nothing is coming, so stop reporting a load and let
           the empty state through. */
        _subscribing = false;
      }
      if (store.openSessionId == sessionId) {
        _lastError = '${error.code}: ${error.message}';
        notifyListeners();
      }
      if (attempt >= 6) {
        return;
      }
      _subscribeTimer?.cancel();
      _subscribeTimer = Timer(Duration(milliseconds: 1200 * (attempt + 1)), () {
        _subscribeTo(sessionId, attempt: attempt + 1);
      });
    }
  }

  /// True while the open session's opening snapshot has not arrived yet.
  ///
  /// Subscribe returning only means dsh accepted the stream; the transcript
  /// itself arrives with the snapshot just after, so the loading shield waits
  /// for that rather than for the request.
  ///
  /// Bounded, because the wait is not guaranteed to end: if the sender drops or
  /// the session was archived from another client, no snapshot is coming and an
  /// unbounded wait leaves the shield up over a page the user can do nothing
  /// with. After the window lapses the transcript is shown empty instead, which
  /// at least leaves the retry and the session list reachable.
  ///
  /// While a subscribe is still being retried that window does not apply: the
  /// stream is not open yet, so "no snapshot" says nothing about the
  /// conversation, and the retry itself is proof that more is on the way.
  bool get isLoadingSession =>
      store.openSessionId != null &&
      (_shieldHeld ||
          store.isFoldingSnapshot ||
          (!store.hasSnapshot &&
              (_subscribing ||
                  DateTime.now().difference(_sessionOpenedAt) <
                      _snapshotDeadline)));

  /// True while the snapshot is being folded into the transcript, one slice
  /// per frame.
  bool _pumpingSnapshot = false;

  /// Folds the rest of the opening snapshot in, a slice at a time.
  ///
  /// The transcript is grown under the loading mask rather than in one stalled
  /// pass: each frame folds a slice, the list below rebuilds around it, and the
  /// mask only comes off once the last slice is in. That is what makes opening
  /// a long conversation show a mask over records that are already rendered,
  /// instead of a pause followed by everything appearing at once.
  void _pumpSnapshot() {
    if (_pumpingSnapshot || _disposed) {
      return;
    }
    _pumpingSnapshot = true;

    void step() {
      if (_disposed) {
        _pumpingSnapshot = false;
        return;
      }
      final more = store.foldSnapshotSlice();
      notifyListeners();
      if (!more) {
        _pumpingSnapshot = false;
        /* Everything is in. Hold the mask for the layout the last slice needs,
         * then let it go. */
        _holdShieldForLayout();
        return;
      }

      /*
       * The next slice waits for this frame to finish — not merely for its
       * callbacks, which run before the frame is done. `endOfFrame` completes
       * once the slice just folded has been built, laid out and painted, so the
       * records are rendered before the next batch is folded in. It also makes
       * sure a frame is actually scheduled, so the pump cannot stall waiting on
       * one that nobody asked for.
       */
      SchedulerBinding.instance.endOfFrame.then((_) => step());
    }

    step();
  }

  /// True while the transcript is being built behind the shield.
  bool _shieldHeld = false;

  /// Whether the open session has reported its snapshot yet, so the moment it
  /// arrives can be noticed exactly once.
  bool _hadSnapshot = false;

  static const Duration _snapshotDeadline = Duration(seconds: 8);

  DateTime _sessionOpenedAt = DateTime.fromMillisecondsSinceEpoch(0);

  Timer? _snapshotTimer;

  /// Keeps the shield up for a couple of frames after the snapshot lands.
  ///
  /// The records are folded synchronously, so by the time the store reports a
  /// snapshot the transcript has everything it needs — but the list below is
  /// still empty as far as the frame is concerned: it has to be built and
  /// measured for the first time before it can be drawn. Dropping the shield on
  /// that same frame revealed the work instead of the result, so the page went
  /// from the mask straight to an empty conversation and filled in a moment
  /// later. Holding it for two frames lets the records load and lay out behind
  /// the mask, and what the mask uncovers is already drawn.
  void _holdShieldForLayout({int frames = 2}) {
    _shieldHeld = true;
    void tick(int remaining) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed) {
          return;
        }
        if (remaining > 0) {
          tick(remaining - 1);
          return;
        }
        _shieldHeld = false;
        notifyListeners();
      });
    }

    tick(frames);
  }

  /// Arms the deadline for an opening snapshot.
  ///
  /// The timer exists to deliver exactly one notification when the window
  /// lapses — [isLoadingSession] is time-based, so something has to tell the UI
  /// to look at it again.
  void _armSnapshotDeadline() {
    _sessionOpenedAt = DateTime.now();
    _snapshotTimer?.cancel();
    _snapshotTimer = Timer(_snapshotDeadline, () {
      if (_disposed) {
        return;
      }
      /*
       * Nothing arrived for the session on screen. Re-subscribing is how the
       * snapshot is asked for again — the sender re-opens the follow stream and
       * its opening records come with it — so one lost delivery recovers on its
       * own instead of leaving the conversation, its model and its permission
       * preset blank until the user leaves and opens it a second time.
       */
      final open = store.openSessionId;
      if (open != null && !store.hasSnapshot) {
        unawaited(_subscribeTo(open));
      }
      notifyListeners();
    });
  }

  /// How many older records one page request asks for.
  static const int olderPageSize = 30;

  bool _loadingOlder = false;

  /// True while older history is still available behind the loaded window.
  bool get hasMoreHistory => store.hasMoreHistory;

  /// True while a page request is in flight.
  bool get isLoadingOlder => _loadingOlder;

  /// Pulls one page of older history in front of the transcript.
  ///
  /// Driven by the user reaching the very top of the list, not by opening the
  /// session: the opening snapshot is a window on purpose, and folding a whole
  /// long transcript up front would stall the first paint.
  Future<void> loadOlder() async {
    final client = _client;
    final sessionId = store.openSessionId;
    if (client == null || sessionId == null) {
      return;
    }
    /*
     * Guarded on having a window at all rather than on `hasMoreHistory`: dsh
     * reports `hasMore` only on some snapshots, so requiring it meant the
     * button did nothing whenever the flag happened to be absent. If there is
     * nothing older, the request comes back with no new records and the page
     * simply stays as it is.
     */
    if (_loadingOlder || store.oldestSeq <= 0) {
      return;
    }

    _loadingOlder = true;
    notifyListeners();

    try {
      /*
       * `request` returns the value from the result envelope, so this is the
       * page itself. Unwrapping a second `value` key here produced null every
       * time, which is why the button appeared to do nothing.
       */
      final page = await client.request(
        'session/page',
        payload: {
          'sessionId': sessionId,
          'beforeSeq': store.oldestSeq,
          'maxMessages': olderPageSize,
        },
        device: activeDevice,
      );
      store.prependHistory(page);
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
    } finally {
      _loadingOlder = false;
      notifyListeners();
    }
  }

  /// Sends a user prompt to the open session.
  ///
  /// Always queued, never injected. dsh holds the message until the running
  /// turn finishes, which is what keeps a watch message from cutting into work
  /// already under way.
  Future<void> sendPrompt(String text) async {
    final client = _client;
    final sessionId = store.openSessionId;
    if (client == null || sessionId == null || text.trim().isEmpty) {
      return;
    }

    try {
      await client.prompt(sessionId, text, device: activeDevice);
      /*
       * Nothing is recorded locally: the control stream reports the queue as
       * dsh holds it, a moment later, and that copy is the one the row actions
       * can address.
       */
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
    }
    notifyListeners();
  }

  /// The open session's pending queue, as dsh reports it.
  List<Map<String, dynamic>> get queuedItems => store.queuedItems;

  /// Text of one queued item.
  static String queuedText(Map<String, dynamic> item) =>
      SessionStore.queuedText(item);

  /// Issues one queue mutation through dsh.
  ///
  /// The queue belongs to dsh: only it can edit, drop or promote an entry, and
  /// only it knows the `itemId` each action is addressed to. A local list could
  /// show the rows but never change them, which is why the row buttons had no
  /// effect.
  Future<void> _queueAction(String itemId, Map<String, dynamic> action) async {
    final client = _client;
    final sessionId = store.openSessionId;
    if (client == null || sessionId == null) {
      return;
    }
    try {
      await client.request(
        'session/updateQueue',
        payload: {'sessionId': sessionId, 'itemId': itemId, 'action': action},
        device: activeDevice,
      );
      notifyListeners();
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
    }
  }

  /// Rewrites one queued message.
  Future<void> editQueuedItem(String itemId, String text) =>
      _queueAction(itemId, {
        'kind': 'edit',
        'content': [
          {'type': 'text', 'text': text},
        ],
      });

  /// Drops one queued message.
  Future<void> removeQueuedItem(String itemId) =>
      _queueAction(itemId, {'kind': 'remove'});

  /// Sends one queued message into the running turn straight away.
  Future<void> sendQueuedItemNow(String itemId) =>
      _queueAction(itemId, {'kind': 'steer'});

  /// Renames a session.
  Future<void> renameSession(String sessionId, String title) async {
    final client = _client;
    if (client == null || title.trim().isEmpty) {
      return;
    }
    try {
      await client.request(
        'session/rename',
        payload: {'sessionId': sessionId, 'title': title.trim()},
        device: activeDevice,
      );
      await refreshSessions();
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
    }
  }

  /// Summaries of archived sessions, as last reported by the sender.
  Map<String, Map<String, dynamic>> get archivedDigests =>
      store.archivedDigests;

  /// Sessions archived from this watch.
  ///
  /// Rebuilt from dsh's own answer rather than accumulated locally: the
  /// workspace controller keeps the authoritative set and returns all of it on
  /// every mutation, so a reinstall or restart can recover the state instead of
  /// losing everything it archived before.
  final Set<String> _archivedLocally = <String>{};

  /// True when a session is archived.
  ///
  /// dsh's session list carries no archive flag — archiving lives in the
  /// workspace registry, not the session controller — so the set has to come
  /// from the workspace side. The sender forwards it with every list, so this
  /// holds even for a client that connected after the feed's baseline.
  bool isArchived(Map<String, dynamic> session) {
    final reported = session['archived'];
    if (reported is bool) {
      return reported;
    }
    final id = session['sessionId'];
    return id is String && store.archivedSessionIds.contains(id);
  }

  /// Replaces the archived set from a `WorkspaceArchiveValue`.
  void _applyArchivedIds(Map<String, dynamic> value) {
    final ids = value['archivedSessionIds'];
    if (ids is! List) {
      return;
    }
    _archivedLocally
      ..clear()
      ..addAll(ids.whereType<String>());
  }

  /// Archives a session, taking it out of the browser.
  Future<void> archiveSession(String sessionId) async {
    final client = _client;
    if (client == null) {
      return;
    }

    try {
      final result = await client.request(
        'workspace/archiveSession',
        payload: {'sessionId': sessionId},
        device: activeDevice,
      );
      /*
       * The answer carries the complete archived set, not just the id that was
       * just archived. Folding all of it in means the watch agrees with dsh
       * even when other sessions were archived elsewhere.
       */
      _applyArchivedIds(result);
      _archivedLocally.add(sessionId);
      await refreshSessions();
      /*
       * Only when the user is reading the session they just archived. Opening
       * an already-archived session on purpose is allowed and leaves them where
       * they are.
       */
      if (store.openSessionId == sessionId) {
        store.closeSession();
        _subscribeTimer?.cancel();
      }
      notifyListeners();
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
    }
  }

  /// Interrupts the running turn.
  ///
  /// A goal keeps the agent fed: the round driver continues an active goal the
  /// moment the agent goes idle, so cancelling a goal-sourced round on its own
  /// ended one round and began the next, and the stop button was back before
  /// the user could lift their finger. The driver only continues a goal whose
  /// phase is still active at that idle point, so pausing first — while the
  /// round is still in flight — is what actually stops the work. The cancel
  /// then ends that round.
  ///
  /// Only a goal-sourced turn pauses the goal. A turn the user started is their
  /// own message, and the goal behind it is not what they asked to stop.
  ///
  /// The flag is retired from the acknowledgement rather than from `turn/end`:
  /// the dsh event mux reopens by itself, and an end published while it was down
  /// never reached the client, leaving the button on screen after the work had
  /// already stopped.
  Future<void> cancelTurn() async {
    final client = _client;
    final sessionId = store.openSessionId;
    if (client == null || sessionId == null) {
      return;
    }
    if (store.turnGoalDriven && hasGoal && goalPhase == 'active') {
      await pauseGoal();
    }
    try {
      await client.cancel(sessionId, device: activeDevice);
      store.markTurnStopped();
      notifyListeners();
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
    }
  }

  /// True when the session on screen has a goal.
  ///
  /// Ownership is checked, not just presence: a goal reported for a session the
  /// user has since left must not appear under the new one.
  bool get hasGoal =>
      _goalBody != null && store.goalSessionId == store.openSessionId;

  /// The goal's own fields.
  ///
  /// The `goal` projection nests them one level down — the value is
  /// `{goal: {id, revision, objective, phase, …}, roundsStarted, createdAt,
  /// updatedAt}` — while the `goal/changed` event carries a flat view. Reading
  /// the projection's fields off the top level found nothing, so the phase and
  /// the objective were permanently absent, the mutation reference could never
  /// be built, and every goal action returned without doing anything.
  Map<String, dynamic>? get _goalBody {
    final body = store.goal?['goal'];
    return body is Map<String, dynamic> ? body : null;
  }

  /// The goal's phase: active, paused, blocked or complete.
  String? get goalPhase {
    final phase = _goalBody?['phase'];
    return phase is String ? phase : null;
  }

  /// The goal's objective, as the user wrote it.
  String? get goalObjective {
    final text = _goalBody?['objective'];
    if (text is String && text.isNotEmpty) {
      return text;
    }
    return store.goalLabel;
  }

  /// The `{id, revision}` every goal mutation is keyed by.
  ///
  /// Assembled from the projection's own fields rather than looked up as a
  /// nested `ref`: the projection carries `id` and `revision` flat inside its
  /// `goal` object, and only the event view has a `ref`.
  Map<String, dynamic>? get _goalRef {
    final body = _goalBody;
    final id = body?['id'];
    final revision = body?['revision'];
    if (id is! String || id.isEmpty || revision is! int) {
      return null;
    }
    return <String, dynamic>{'id': id, 'revision': revision};
  }

  /// Runs one goal mutation, keeping the caller free of the ref plumbing.
  ///
  /// The agent field is `agentId`, not `agent`: dsh's descriptor for these
  /// endpoints declares `wire: 'agentId'` for the agent lookup, and a call
  /// carrying `agent` instead is refused outright — "missing \"agentId\"" —
  /// which is why every goal button did nothing. `session/prompt` names the
  /// same thing `agent`, so the two are not interchangeable.
  Future<void> _goalCall(String method, {Map<String, dynamic>? body}) async {
    final client = _client;
    final sessionId = store.openSessionId;
    final ref = _goalRef;
    if (client == null || sessionId == null || ref == null) {
      return;
    }
    try {
      await client.request(
        method,
        payload: {'agentId': sessionId, 'ref': ref, ...?body},
        device: activeDevice,
      );
      notifyListeners();
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
    }
  }

  /// Starts a goal for the open session.
  ///
  /// The one goal operation that does not need a reference, because it is what
  /// produces the first revision. Without it the goal page was unreachable for
  /// any session that had none: the card only opened when a goal already
  /// existed, so a goal could never be created from the watch at all.
  Future<void> createGoal(String objective) async {
    final client = _client;
    final sessionId = store.openSessionId;
    if (client == null || sessionId == null || objective.trim().isEmpty) {
      return;
    }
    try {
      await client.request(
        'goals/create',
        payload: <String, dynamic>{
          'agentId': sessionId,
          'request': <String, dynamic>{'objective': objective.trim()},
        },
        device: activeDevice,
      );
      notifyListeners();
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
    }
  }

  /// Suspends the goal so the agent stops continuing it.
  Future<void> pauseGoal() => _goalCall('goals/pause');

  /// Puts a paused goal back to work.
  Future<void> resumeGoal() => _goalCall('goals/resume');

  /// Rewrites the goal's objective.
  Future<void> editGoal(String objective) => _goalCall(
    'goals/edit',
    body: {
      'request': {'objective': objective},
    },
  );

  /// Clears the goal entirely.
  Future<void> clearGoal() => _goalCall('goals/clear');

  /// Switches the session's permission preset, e.g. `read-only` or `yolo`.
  ///
  /// This goes through dsh's command channel because a preset is a command
  /// there, not a settable field; the projection that follows updates the view.
  Future<void> setPermission(String preset) async {
    final client = _client;
    final sessionId = store.openSessionId;
    if (client == null || sessionId == null) {
      return;
    }
    try {
      await client.executeCommand(
        sessionId,
        '/permission $preset',
        device: activeDevice,
      );
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
      return;
    }
    notifyListeners();
  }

  /// Switches the model used by the open session.
  Future<void> selectModel(
    String provider,
    String model, {
    String? reasoningEffort,
  }) async {
    final client = _client;
    final sessionId = store.openSessionId;
    if (client == null || sessionId == null) {
      return;
    }
    try {
      await client.request(
        'session/selectModel',
        payload: {
          'sessionId': sessionId,
          'provider': provider,
          'model': model,
          'reasoningEffort': ?reasoningEffort,
        },
        device: activeDevice,
      );
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
    }
  }

  /// Working directory of sessions this watch created.
  ///
  /// `cwd` is optional on dsh's session summary and only appears once the
  /// sender has rebuilt its session list, so a session created a moment ago
  /// carries none and fell into the ungrouped bucket. Remembering the directory
  /// it was created in keeps it under the right heading from the first frame.
  final Map<String, String> _createdIn = <String, String>{};

  /// The directory a session belongs to, preferring what dsh reports.
  String? cwdOf(Map<String, dynamic> session) {
    final reported = session['cwd'];
    if (reported is String && reported.isNotEmpty) {
      return reported;
    }
    final id = session['sessionId'];
    return id is String ? _createdIn[id] : null;
  }

  /// Resolves a directory to the id dsh registered it under.
  ///
  /// The browser only knows a group's directory, while every workspace
  /// mutation is keyed by an opaque id. `workspace/create` resolves a path to
  /// its workspace — returning the existing registration rather than making a
  /// second — so the id comes from there. The field is `workspaceId`, not `id`.
  Future<String?> _workspaceIdFor(String path) async {
    final client = _client;
    if (client == null || path.isEmpty) {
      return null;
    }
    final created = await client.request(
      'workspace/create',
      payload: {'path': path},
      device: activeDevice,
    );
    final workspace = created['workspace'];
    final id = workspace is Map<String, dynamic>
        ? workspace['workspaceId']
        : null;
    if (id is! String || id.isEmpty) {
      _lastError = 'workspace/create did not return a workspaceId';
      notifyListeners();
      return null;
    }
    return id;
  }

  /// Removes a workspace registration, by its directory.
  ///
  /// Only the registration goes; the directory and its sessions are untouched.
  Future<void> deleteWorkspace(String path) async {
    final client = _client;
    if (client == null) {
      return;
    }
    try {
      final id = await _workspaceIdFor(path);
      if (id == null) {
        return;
      }
      await client.request(
        'workspace/delete',
        payload: {'workspaceId': id},
        device: activeDevice,
      );
      await refreshSessions();
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
    }
  }

  /// Renames a workspace, by its directory.
  Future<void> renameWorkspace(String path, String title) async {
    final client = _client;
    if (client == null || title.trim().isEmpty) {
      return;
    }
    try {
      final id = await _workspaceIdFor(path);
      if (id == null) {
        return;
      }
      await client.request(
        'workspace/rename',
        payload: {'workspaceId': id, 'title': title.trim()},
        device: activeDevice,
      );
      await refreshSessions();
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
    }
  }

  /// Starts a new session in a working directory and opens it.
  ///
  /// `cwd` is what ties the session to a workspace: dsh derives the workspace
  /// from the directory rather than taking a workspace id here.
  Future<void> createSession(String cwd) async {
    final client = _client;
    if (client == null) {
      return;
    }
    try {
      final result = await client.request(
        'session/create',
        payload: {'cwd': cwd},
        device: activeDevice,
      );

      /*
       * dsh answers with the new session's id, sometimes at the top level and
       * sometimes under the key the sender wrapped the request in. Without it
       * there is nothing to remember the directory against and nothing to open,
       * so the session would exist but show up ungrouped.
       */
      Object? sessionId = result['sessionId'];
      if (sessionId is! String || sessionId.isEmpty) {
        final inner = result['request'];
        if (inner is Map<String, dynamic>) {
          sessionId = inner['sessionId'];
        }
      }

      if (sessionId is! String || sessionId.isEmpty) {
        _lastError = 'session/create did not return a session id';
        notifyListeners();
        return;
      }

      _createdIn[sessionId] = cwd;

      /*
       * A session dsh has just created does not necessarily appear in its own
       * list yet: the list is built by a separate pass over the session store,
       * and the create may not have been committed to it by the time the first
       * pull returns. Pulling once here would miss it, which is why a new
       * session could be created and opened while never showing up in the
       * browser. The pull is retried until it lands.
       */
      await refreshSessions();
      _refreshUntilVisible(sessionId);
      await openSession(sessionId);
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
    }
  }

  /// Forks a session, opening the copy.
  ///
  /// The fork inherits the original's directory, so it lands in the same group
  /// even before dsh reports a `cwd` for it.
  Future<void> forkSession(String sessionId, {String? cwd}) async {
    final client = _client;
    if (client == null) {
      return;
    }
    try {
      final result = await client.request(
        'session/fork',
        payload: {'sessionId': sessionId},
        device: activeDevice,
      );
      final forked = result['sessionId'];
      if (forked is String && forked.isNotEmpty) {
        if (cwd != null && cwd.isNotEmpty) {
          _createdIn[forked] = cwd;
        }
        await refreshSessions();
        await openSession(forked);
      }
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
    }
  }

  /// Loads the model catalog from the sender.
  Future<Map<String, dynamic>?> modelCatalog() async {
    final client = _client;
    if (client == null) {
      return null;
    }
    try {
      return await client.request('session/modelCatalog', device: activeDevice);
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
      return null;
    }
  }

  /// The Agent presets this deployment offers.
  ///
  /// A preset decides what an agent is composed of — its tools, plugins and
  /// prompt — so it is the coarsest setting the watch exposes, and the one that
  /// has to be chosen before a conversation starts rather than during it.
  Future<Map<String, dynamic>?> agentPresetRoster() async {
    final client = _client;
    if (client == null) {
      return null;
    }
    try {
      return await client.request('agentPresets/list', device: activeDevice);
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
      return null;
    }
  }

  /// The Host's settings document: every namespace's schema, values and layers.
  ///
  /// The model providers live in here as plain settings, which is what makes a
  /// provider editable at all — dsh keeps no separate registry for them.
  Future<Map<String, dynamic>?> settingsDescribe() async {
    final client = _client;
    if (client == null) {
      return null;
    }
    try {
      return await client.request('settings/describe', device: activeDevice);
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
      return null;
    }
  }

  /// Every provider the Host could be configured to talk to.
  ///
  /// Each row names the settings namespace and path its configuration belongs
  /// at, so a row is also the address of the edit that would create it.
  Future<List<Map<String, dynamic>>> configurableProviders() async {
    final client = _client;
    if (client == null) {
      return const <Map<String, dynamic>>[];
    }
    try {
      /* A bare array, which is why this goes through `requestValue`: the
       * object-narrowing path would turn the whole directory into `{}`. */
      final value = await client.requestValue(
        'llm/listConfigurableProviders',
        device: activeDevice,
      );
      return value is List
          ? value.whereType<Map<String, dynamic>>().toList(growable: false)
          : const <Map<String, dynamic>>[];
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
      return const <Map<String, dynamic>>[];
    }
  }

  /// The last DeepSeek balance the sender reported.
  ///
  /// Held here rather than inside a page: a turn ending has to refresh it
  /// whether or not the settings list happens to be on screen, and the value
  /// outlives any one view.
  Map<String, dynamic>? _balance;

  Map<String, dynamic>? get balance => _balance;

  /// Reads the balance the whale-widget plugin publishes, through the sender.
  ///
  /// Called on demand and at the end of every turn: the account figure moves
  /// when a reply finishes, so that is the moment worth re-reading.
  Future<void> refreshBalance() async {
    final client = _client;
    if (client == null) {
      return;
    }
    try {
      final value = await client.request('balance/get', device: activeDevice);
      _balance = value;
      notifyListeners();
    } on RelayException catch (error) {
      /* A failed read keeps the last figure — a momentary wobble is not a
       * reason to blank the number the user is watching. */
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
    }
  }

  /// Asks a provider which models it serves.
  ///
  /// The Host performs the request itself — it calls `{baseURL}/models` for an
  /// OpenAI-compatible route — so the key never has to be stored before the
  /// list can be fetched. A refusal carries the provider's own words (a 401
  /// says to check the key), which is more useful than an empty list.
  Future<List<Map<String, dynamic>>> discoverModels(
    String settingsNs, {
    required String baseURL,
    required String api,
    String apiKey = '',
  }) async {
    final client = _client;
    if (client == null || baseURL.isEmpty) {
      return const <Map<String, dynamic>>[];
    }
    try {
      /* A bare array, like the provider directory, so this goes through the
       * value-preserving path. */
      final value = await client.requestValue(
        'llm/discoverModels',
        payload: {
          'settingsNs': settingsNs,
          'request': {
            'baseURL': baseURL,
            'api': api,
            if (apiKey.isNotEmpty) 'apiKey': apiKey,
          },
        },
        device: activeDevice,
        timeout: const Duration(seconds: 60),
      );
      if (value is List) {
        return value.whereType<Map<String, dynamic>>().toList(growable: false);
      }
      final models = value is Map<String, dynamic> ? value['models'] : null;
      return models is List
          ? models.whereType<Map<String, dynamic>>().toList(growable: false)
          : const <Map<String, dynamic>>[];
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
      return const <Map<String, dynamic>>[];
    }
  }

  /// Whether each credential reference currently resolves to a stored secret.
  Future<Map<String, dynamic>> credentialsDescribe(List<String> refs) async {
    final client = _client;
    if (client == null || refs.isEmpty) {
      return const <String, dynamic>{};
    }
    try {
      final answer = await client.request(
        'credentials/describe',
        payload: {'refs': refs},
        device: activeDevice,
      );
      return answer;
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
      return const <String, dynamic>{};
    }
  }

  /// Stores one credential.
  Future<bool> setCredential(String ref, String value) async {
    final client = _client;
    if (client == null || ref.isEmpty) {
      return false;
    }
    try {
      await client.request(
        'credentials/set',
        payload: {'ref': ref, 'value': value},
        device: activeDevice,
      );
      _lastError = null;
      notifyListeners();
      return true;
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
      return false;
    }
  }

  /// Merges a patch into one settings namespace.
  ///
  /// This is the global layer: it has no session, no path and no revision
  /// argument, and it is what a deployment-wide default is written through —
  /// the Agent preset a new session is composed from, for one.
  Future<bool> updateSettings(String ns, Map<String, dynamic> patch) async {
    final client = _client;
    if (client == null) {
      return false;
    }
    try {
      await client.request(
        'settings/update',
        payload: {'ns': ns, 'patch': patch},
        device: activeDevice,
      );
      _lastError = null;
      notifyListeners();
      return true;
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
      return false;
    }
  }

  /// Applies path-addressed writes to one settings namespace.
  ///
  /// `expectedRevision` is what the Host compares against, so a write built
  /// from a stale read is refused rather than silently overwriting someone
  /// else's edit — the caller reads, edits, and writes the revision it saw.
  Future<bool> mutateSettings(
    String ns,
    List<Map<String, dynamic>> ops,
    int expectedRevision,
  ) async {
    final client = _client;
    if (client == null) {
      return false;
    }
    try {
      await client.request(
        'settings/mutate',
        payload: {'ns': ns, 'ops': ops, 'expectedRevision': expectedRevision},
        device: activeDevice,
      );
      _lastError = null;
      notifyListeners();
      return true;
    } on RelayException catch (error) {
      _lastError = '${error.code}: ${error.message}';
      notifyListeners();
      return false;
    }
  }

  void clearError() {
    _lastError = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _snapshotTimer?.cancel();
    _subscribeTimer?.cancel();
    _notifyThrottle?.cancel();
    _disposed = true;
    unawaited(_teardown());
    super.dispose();
  }

  /// True once the session has been torn down, so pending frame callbacks stop.
  bool _disposed = false;

  /// The trailing rebuild queued while the stream is being throttled.
  Timer? _notifyThrottle;
  DateTime? _notifiedAt;

  /// Shortest gap between two stream-driven rebuilds.
  ///
  /// One rebuild per frame was still too often while a long reply was arriving.
  /// Each rebuild re-runs the grouping pass, reconstructs every bubble and lets
  /// the scaling list re-measure, and the row that actually changed is a single
  /// Text whose content grew by one chunk — on a watch CPU that does not fit in
  /// a frame, so the whole transcript stuttered. Roughly fifteen rebuilds a
  /// second is past the point where the eye can tell the text is growing, and
  /// it leaves the frame budget to the scroll and the animations instead.
  static const Duration _notifyInterval = Duration(milliseconds: 66);

  /// Coalesces a burst of relay messages into a bounded number of rebuilds.
  ///
  /// A streaming reply arrives as dozens of chunks per second. Notifying per
  /// message rebuilt the whole transcript each time — the grouping pass, every
  /// bubble, and the scaling list's measurement — which is what made the
  /// conversation stutter while the model was writing.
  ///
  /// The trailing rebuild is held rather than dropped: only one is ever
  /// pending, so the final chunk of a burst still reaches the screen once the
  /// interval passes.
  void _notifySoon() {
    if (_disposed) {
      return;
    }

    final last = _notifiedAt;
    final elapsed = last == null
        ? _notifyInterval
        : DateTime.now().difference(last);
    if (elapsed >= _notifyInterval) {
      _flushNotify();
      return;
    }
    _notifyThrottle ??= Timer(_notifyInterval - elapsed, _flushNotify);
  }

  void _flushNotify() {
    _notifyThrottle?.cancel();
    _notifyThrottle = null;
    if (_disposed) {
      return;
    }
    _notifiedAt = DateTime.now();
    notifyListeners();
  }
}
