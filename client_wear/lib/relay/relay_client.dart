import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../crypto/bytes.dart';
import '../crypto/dsh_frame.dart';
import '../crypto/hkdf_style.dart';
import '../crypto/session_crypto.dart';

/// Where to reach the relay server and who we claim to be.
class RelayConfig {
  const RelayConfig({
    required this.host,
    required this.port,
    required this.passphrase,
    this.deviceName = 'wear',
  });

  final String host;
  final int port;

  /// Shared secret. Must match the server and every sender on the relay.
  final String passphrase;

  /// Display name reported during the handshake.
  final String deviceName;

  RelayConfig copyWith({
    String? host,
    int? port,
    String? passphrase,
    String? deviceName,
  }) {
    return RelayConfig(
      host: host ?? this.host,
      port: port ?? this.port,
      passphrase: passphrase ?? this.passphrase,
      deviceName: deviceName ?? this.deviceName,
    );
  }
}

/// One relay message: `{"t": kind, "id": correlation, "p": payload}`.
class RelayMessage {
  const RelayMessage({required this.kind, this.id, this.payload});

  final String kind;
  final String? id;
  final Map<String, dynamic>? payload;

  @override
  String toString() => 'RelayMessage($kind${id != null ? ' #$id' : ''})';
}

/// A failure reported by the sender or the server.
///
/// [code] is the original code — `session/not-found` from dsh, or a `relay/*`
/// code from the relay itself — so callers can branch on the condition rather
/// than parse [message].
class RelayException implements Exception {
  const RelayException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// Encrypted relay connection carrying the dsh session vocabulary.
///
/// Owns exactly one socket. Every frame after the handshake is AES-256-CBC and
/// HMAC-SHA256 (encrypt-then-MAC), matching the C sender and server byte for
/// byte; the format lives in `lib/crypto/`.
class RelayClient {
  RelayClient({required this.config, this.role = 2});

  /// 1 = sender, 2 = Wear client.
  final int role;
  final RelayConfig config;

  static const int _helloFrame = 1;
  static const int _helloAckFrame = 2;
  static const int _dataFrame = 3;
  static const int _headerLength = DshFrameLayout.headerLength;
  static const int _tagLength = DshFrameLayout.tagLength;

  final _messages = StreamController<RelayMessage>.broadcast();
  final _status = StreamController<RelayStatusUpdate>.broadcast();
  final _pending = <String, Completer<Object?>>{};

  /*
   * Incoming bytes are held as the chunks the socket delivered, not as one flat
   * list. A session snapshot can be tens of megabytes, and re-copying the whole
   * buffer per arrival would be quadratic; chunks are joined only when a
   * complete frame is cut.
   */
  final List<Uint8List> _chunks = [];
  int _pendingBytes = 0;

  Socket? _socket;
  SessionCrypto? _crypto;
  StreamSubscription<Uint8List>? _subscription;
  Uint8List? _clientNonce;
  int _nextRequestId = 1;

  /*
   * Key derivation runs on a background isolate, so this completes a few
   * seconds after the ACK. Encrypted frames that arrive in the meantime are
   * held here rather than dropped: the server sends its device roster the
   * instant it answers the handshake.
   */
  Completer<void>? _keysReady;
  final List<Uint8List> _heldFrames = [];
  bool _disposed = false;
  bool _closed = false;
  List<Map<String, dynamic>> _devices = const [];

  /// Messages pushed by the relay: `sessions`, `snapshot`, `events`, `state`,
  /// `devices`.
  Stream<RelayMessage> get messages => _messages.stream;

  /// Connection lifecycle, for a status line in the UI.
  Stream<RelayStatusUpdate> get status => _status.stream;

  /// Senders currently online, as last reported by the server.
  List<Map<String, dynamic>> get devices => _devices;

  bool get isConnected => _crypto != null && !_closed;

  /// Connects, performs the handshake, and derives the session keys.
  ///
  /// Throws [RelayException] when the server rejects the passphrase and
  /// [SocketException] when it cannot be reached.
  Future<void> connect({Duration timeout = const Duration(seconds: 20)}) async {
    if (_disposed) {
      throw StateError('RelayClient was disposed');
    }
    await _teardown();

    _emitStatus(RelayStatus.connecting);
    _chunks.clear();
    _pendingBytes = 0;
    _closed = false;

    final socket = await Socket.connect(
      config.host,
      config.port,
      timeout: timeout,
    );
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;

    /*
     * Buffer raw bytes and cut frames out of the stream. Frames are not
     * guaranteed to arrive whole, and a big session snapshot spans many TCP
     * segments.
     */
    _subscription = socket.listen(
      (chunk) {
        _appendChunk(chunk);
        _drainFrames();
      },
      onError: (Object error) {
        _fail(RelayException('relay/transport', '$error'));
      },
      onDone: () {
        if (!_disposed && !_closed) {
          _fail(
            const RelayException(
              'relay/closed',
              'the relay closed the connection',
            ),
          );
        }
      },
      cancelOnError: false,
    );

    await _handshake(timeout);
    _emitStatus(RelayStatus.connected);
  }

  /// Exchanges HELLO for HELLO_ACK. Key derivation itself happens in
  /// [_dispatch], on the same tick the ACK frame is decoded.
  Future<void> _handshake(Duration timeout) async {
    final random = Random.secure();
    final clientNonce = Uint8List.fromList(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    _clientNonce = clientNonce;
    final proof = SessionKeyDerivation.handshakeProof(
      config.passphrase,
      clientNonce,
    );

    final hello = jsonEncode({
      'role': role,
      'name': config.deviceName,
      'nonce': Hex.encode(clientNonce),
      'proof': Hex.encode(proof),
    });

    final ackCompleter = Completer<Map<String, dynamic>>();
    _ackCompleter = ackCompleter;

    _writeBytes(DshPlainFrame.seal(_helloFrame, utf8.encode(hello)));

    final ack = await ackCompleter.future.timeout(
      timeout,
      onTimeout: () => throw const RelayException(
        'relay/timeout',
        'the server did not answer the handshake',
      ),
    );
    _ackCompleter = null;

    if (ack['ok'] != true) {
      throw const RelayException(
        'relay/rejected',
        'the server rejected this client',
      );
    }

    /*
     * Key derivation is the slow half of a handshake: 50000 PBKDF2 rounds is
     * fixed by the relay contract, and on a watch CPU that is seconds of solid
     * arithmetic. It runs on a worker isolate, so wait for it here instead of
     * blocking the UI while connect() is still in flight.
     */
    final keysReady = _keysReady;
    if (keysReady != null) {
      await keysReady.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () => throw const RelayException(
          'relay/timeout',
          'key derivation did not finish',
        ),
      );
    }
    if (_crypto == null) {
      throw RelayException(
        'relay/bad-frame',
        _keyError != null
            ? 'key derivation failed: $_keyError'
            : 'HELLO_ACK did not carry usable key material',
      );
    }
  }

  Completer<Map<String, dynamic>>? _ackCompleter;

  /// Why the last key derivation failed, if it did.
  String? _keyError;

  /// Derives the session keys off the UI isolate and releases held frames.
  void _startKeyDerivation(Map<String, dynamic> ack) {
    final saltHex = ack['salt'];
    final nonceHex = ack['nonce'];
    final clientNonce = _clientNonce;
    if (saltHex is! String || nonceHex is! String || clientNonce == null) {
      return;
    }

    final request = KeyDerivationRequest(
      passphrase: config.passphrase,
      salt: Hex.decode(saltHex),
      clientNonce: clientNonce,
      serverNonce: Hex.decode(nonceHex),
    );

    final ready = Completer<void>();
    _keysReady = ready;

    unawaited(
      _deriveWithFallback(request)
          .then((keys) {
            if (_disposed) {
              return;
            }
            _crypto = SessionCrypto(keys: keys);
            _flushHeldFrames();
            if (!ready.isCompleted) {
              ready.complete();
            }
          })
          .catchError((Object error) {
            /*
         * Completion, not completeError: the handshake may already have given
         * up on the timeout, and an unhandled error on an unawaited future
         * would surface as an uncaught exception. The reason is kept so the
         * handshake can report it instead of a generic failure.
         */
            _keyError = '$error';
            if (!ready.isCompleted) {
              ready.complete();
            }
          }),
    );
  }

  /// Derives on a worker isolate, falling back to this isolate.
  ///
  /// 50000 PBKDF2 rounds take seconds on a watch CPU, and running them on the
  /// UI isolate freezes the app — that is why a worker is tried first. The
  /// fallback keeps the client usable on any platform where handing work to a
  /// worker fails, at the cost of a brief stall.
  static Future<SessionKeys> _deriveWithFallback(
    KeyDerivationRequest request,
  ) async {
    try {
      return await compute(deriveKeysInWorker, request);
    } on Object {
      return deriveKeysInWorker(request);
    }
  }

  /// Replays frames that arrived while the keys were still being derived.
  void _flushHeldFrames() {
    if (_heldFrames.isEmpty) {
      return;
    }
    final held = List<Uint8List>.from(_heldFrames);
    _heldFrames.clear();
    for (final frame in held) {
      _enqueue(frame, false);
    }
  }

  /// Frames whose size makes them worth opening off the main isolate.
  ///
  /// A session snapshot carries the whole conversation — hundreds of kilobytes
  /// — and the HMAC, the AES pass and the JSON decode of that inline blocked
  /// the main isolate for long enough to drop frames: the stutter seen while a
  /// conversation opens. Streaming chunks are a few hundred bytes each and
  /// arrive constantly, and for those a round trip to a worker would cost more
  /// than the work itself, so they stay here.
  static const int _workerFrameThreshold = 32 * 1024;

  /// Serialises frame handling.
  ///
  /// Frames are only valid in strictly increasing sequence order, so opening
  /// one off the main isolate must not let the next overtake it. Every frame
  /// goes through this chain, and each waits for the one before it to finish —
  /// including its state update — before it starts.
  Future<void> _dispatchChain = Future<void>.value();

  void _enqueue(Uint8List frame, bool plain) {
    _dispatchChain = _dispatchChain
        .then((_) => _dispatch(frame, plain))
        .catchError((Object _) {
          /* _dispatch reports its own failures; this only keeps the chain
           * alive so one bad frame cannot stop every frame after it. */
        });
  }

  /// Opens a frame, on a worker isolate when it is large enough to matter.
  ///
  /// Returns the decoded JSON alongside the frame's own fields, because the
  /// decode is the expensive half and belongs on the worker with the rest.
  Future<Map<String, Object?>> _openJson(Uint8List frame) async {
    final crypto = _crypto;
    if (crypto == null) {
      throw StateError('no session keys');
    }
    if (frame.length < _workerFrameThreshold) {
      final opened = crypto.open(frame);
      return <String, Object?>{
        'type': opened.type,
        'sequence': opened.sequence,
        'value': jsonDecode(opened.text),
      };
    }

    final result = await compute(
      openJsonInWorker,
      openFrameRequest(
        frame: frame,
        decryptionKey: crypto.decryptionKey,
        receiveMacKey: crypto.receiveMacKey,
        receiveSequence: crypto.receiveSequence,
      ),
    );

    /*
     * The worker verified the MAC and checked the sequence against the counter
     * it was given; advancing the live counter stays here, in arrival order,
     * because this is the only place that owns it.
     */
    crypto.acceptReceiveSequence(result['sequence']! as int);
    return result;
  }

  /// Sends `request` and resolves with the sender's `value`.
  ///
  /// [device] selects which sender answers; when omitted the server picks the
  /// only connected one. Throws [RelayException] carrying the original error
  /// code when either side refuses.
  ///
  /// The value is narrowed to an object, which is what most endpoints answer
  /// with. Endpoints that return a bare array — the provider directory among
  /// them — need [requestValue] instead, because narrowing those to an object
  /// would silently hand back an empty map.
  Future<Map<String, dynamic>> request(
    String method, {
    Map<String, dynamic>? payload,
    String? device,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final value = await requestValue(
      method,
      payload: payload,
      device: device,
      timeout: timeout,
    );
    return value is Map<String, dynamic> ? value : const <String, dynamic>{};
  }

  /// Sends `request` and resolves with the sender's value unmodified.
  Future<Object?> requestValue(
    String method, {
    Map<String, dynamic>? payload,
    String? device,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final crypto = _crypto;
    if (crypto == null || _closed) {
      throw const RelayException(
        'relay/not-connected',
        'connect before sending a request',
      );
    }

    final id = 'w${_nextRequestId++}';
    final completer = Completer<Object?>();
    _pending[id] = completer;

    final envelope = jsonEncode({
      't': 'request',
      'id': id,
      'p': {
        'device': ?device,
        'method': method,
        'payload': payload ?? const <String, dynamic>{},
      },
    });

    _writeBytes(crypto.sealText(_dataFrame, envelope));

    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      throw RelayException('relay/timeout', '$method did not answer in time');
    }
  }

  /// Runs a dsh slash command in `sessionId`.
  ///
  /// Permission presets, plan exit and the other session switches are commands
  /// in dsh rather than RPC fields, so a command is how the watch changes them.
  Future<void> executeCommand(
    String sessionId,
    String line, {
    String? device,
  }) async {
    await request(
      'commands/execute',
      payload: {'agent': sessionId, 'line': line, 'images': const <Object>[]},
      device: device,
    );
  }

  /// Subscribes to a session's history and live events.
  ///
  /// The sender answers the request, then pushes a `snapshot` message followed
  /// by `events` messages.
  Future<void> subscribe(String sessionId, {String? device}) {
    return request(
      'session/subscribe',
      payload: {'sessionId': sessionId},
      device: device,
    );
  }

  /// Stops receiving live events for a session.
  Future<void> unsubscribe(String sessionId, {String? device}) {
    return request(
      'session/unsubscribe',
      payload: {'sessionId': sessionId},
      device: device,
    );
  }

  /// Sends a user prompt to a session.
  Future<void> prompt(
    String sessionId,
    String text, {
    String mode = 'queue',
    String? device,
  }) {
    return request(
      'session/prompt',
      payload: {'sessionId': sessionId, 'text': text, 'mode': mode},
      device: device,
    );
  }

  /// Interrupts the running turn of a session.
  Future<void> cancel(String sessionId, {String? device}) {
    return request(
      'session/cancel',
      payload: {'sessionId': sessionId},
      device: device,
    );
  }

  /// Loads one page of history. Requires an active subscription for [sessionId]
  /// because dsh pages relative to the follow cursor.
  Future<Map<String, dynamic>> page(
    String sessionId, {
    int? throughSeq,
    int? beforeSeq,
    int maxMessages = 40,
    String? device,
  }) {
    return request(
      'session/page',
      payload: {
        'sessionId': sessionId,
        'throughSeq': ?throughSeq,
        'beforeSeq': ?beforeSeq,
        'maxMessages': maxMessages,
      },
      device: device,
    );
  }

  /// Sends a heartbeat. A live relay answers with `pong`.
  Future<void> ping() async {
    final crypto = _crypto;
    if (crypto == null || _closed) {
      return;
    }
    _writeBytes(crypto.sealText(_dataFrame, jsonEncode({'t': 'ping'})));
  }

  /// Closes the connection. Safe to call more than once.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _teardown();
    await _messages.close();
    await _status.close();
  }

  Future<void> _teardown() async {
    _closed = true;
    _crypto = null;
    _heldFrames.clear();

    final ready = _keysReady;
    _keysReady = null;
    if (ready != null && !ready.isCompleted) {
      ready.complete();
    }

    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const RelayException('relay/closed', 'the connection went away'),
        );
      }
    }
    _pending.clear();

    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();

    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        await socket.close();
      } on Object {
        /* Already gone; nothing left to close. */
      }
    }

    if (!_disposed) {
      _emitStatus(RelayStatus.disconnected);
    }
  }

  void _fail(RelayException error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    _pending.clear();
    _emitStatus(RelayStatus.failed, error);
    unawaited(_teardown());
  }

  void _writeBytes(List<int> bytes) {
    final socket = _socket;
    if (socket == null || _closed) {
      return;
    }
    try {
      socket.add(bytes);
    } on Object catch (error) {
      _fail(RelayException('relay/transport', '$error'));
    }
  }

  void _emitStatus(RelayStatus status, [RelayException? error]) {
    if (!_status.isClosed) {
      _status.add(RelayStatusUpdate(status, error));
    }
  }

  /// Buffers one socket chunk without joining it to the previous ones.
  void _appendChunk(Uint8List chunk) {
    if (chunk.isEmpty) {
      return;
    }
    _chunks.add(chunk);
    _pendingBytes += chunk.length;
  }

  /// Returns the first [count] buffered bytes without consuming them, or null
  /// when fewer are available.
  Uint8List? _peek(int count) {
    if (_pendingBytes < count) {
      return null;
    }
    if (_chunks.length == 1) {
      return Uint8List.sublistView(_chunks.first, 0, count);
    }
    final out = Uint8List(count);
    var written = 0;
    for (final chunk in _chunks) {
      if (written >= count) {
        break;
      }
      final take = min(chunk.length, count - written);
      out.setRange(written, written + take, chunk);
      written += take;
    }
    return out;
  }

  /// Drops the first [count] buffered bytes.
  void _consume(int count) {
    var remaining = count;
    while (remaining > 0 && _chunks.isNotEmpty) {
      final head = _chunks.first;
      if (head.length <= remaining) {
        remaining -= head.length;
        _pendingBytes -= head.length;
        _chunks.removeAt(0);
      } else {
        _chunks[0] = Uint8List.sublistView(head, remaining);
        _pendingBytes -= remaining;
        remaining = 0;
      }
    }
  }

  /// Cuts as many complete frames as the buffer holds and dispatches each.
  void _drainFrames() {
    while (true) {
      final headerBytes = _peek(_headerLength);
      if (headerBytes == null) {
        return;
      }

      bool plain;
      int bodyLength;
      try {
        // Parsing needs only the header, so a partial body is fine here.
        final header = DshFrameHeader.parse(headerBytes);
        plain = header.isPlaintext;
        bodyLength = header.bodyLength;
      } on DshFrameFormatException catch (error) {
        _fail(RelayException('relay/bad-frame', error.message));
        return;
      }

      final total = _headerLength + bodyLength + (plain ? 0 : _tagLength);
      final frame = _peek(total);
      if (frame == null) {
        return;
      }
      _consume(total);
      _enqueue(frame, plain);
    }
  }

  Future<void> _dispatch(Uint8List frame, bool plain) async {
    if (plain) {
      final ackCompleter = _ackCompleter;
      if (ackCompleter == null || ackCompleter.isCompleted) {
        /* A handshake frame on an established channel is never legitimate. */
        _fail(
          const RelayException(
            'relay/bad-frame',
            'unexpected plaintext frame after the handshake',
          ),
        );
        return;
      }
      try {
        final parsed = DshPlainFrame.parse(frame);
        if (parsed.type != _helloAckFrame) {
          _fail(
            RelayException(
              'relay/bad-frame',
              'expected HELLO_ACK, got frame type ${parsed.type}',
            ),
          );
          return;
        }
        final body = jsonDecode(utf8.decode(parsed.payload));
        if (body is! Map<String, dynamic>) {
          _fail(
            const RelayException(
              'relay/bad-frame',
              'HELLO_ACK is not a JSON object',
            ),
          );
          return;
        }

        /*
         * Derive the session keys on a worker isolate rather than in the
         * awaiting caller. The server sends its first encrypted frame
         * immediately after the ACK, and derivation takes seconds on a watch;
         * frames that arrive in the meantime are held, not dropped.
         */
        if (body['ok'] == true) {
          _startKeyDerivation(body);
        }

        ackCompleter.complete(body);
      } on Object catch (error) {
        _fail(RelayException('relay/bad-frame', '$error'));
      }
      return;
    }

    final crypto = _crypto;
    if (crypto == null) {
      /* The ACK arrived but the worker isolate is still deriving the keys;
       * hold the frame so the flush replay can decode it in order. */
      _heldFrames.add(frame);
      return;
    }

    final Map<String, Object?> opened;
    try {
      opened = await _openJson(frame);
    } on DshFrameException catch (error) {
      /*
       * A replayed or tampered frame is dropped rather than fatal: the counter
       * already rejects the replay, and tearing down the socket would let a
       * network glitch end the session.
       */
      _emitStatus(
        RelayStatus.frameRejected,
        RelayException('relay/${error.failure.name}', error.message),
      );
      return;
    } on FormatException {
      /* The payload was not JSON. Nothing to report: the frame itself was
       * authentic, there is simply no message in it. */
      return;
    }

    final decoded = opened['value'];
    if (decoded is! Map<String, dynamic>) {
      return;
    }

    final kind = decoded['t'];
    if (kind is! String) {
      return;
    }

    final id = decoded['id'];
    final rawPayload = decoded['p'];
    final payload = rawPayload is Map<String, dynamic>
        ? rawPayload
        : const <String, dynamic>{};

    if (kind == 'result' || kind == 'error') {
      final completer = _pending.remove(id);
      if (completer == null || completer.isCompleted) {
        return;
      }
      if (kind == 'result') {
        /* The value crosses as it arrived; [request] is the narrowing seat. */
        completer.complete(payload['value']);
      } else {
        final code = payload['code'];
        final message = payload['message'];
        completer.completeError(
          RelayException(
            code is String ? code : 'relay/unknown',
            message is String ? message : 'the sender reported a failure',
          ),
        );
      }
      return;
    }

    if (kind == 'devices') {
      final list = payload['devices'];
      if (list is List) {
        _devices = list.whereType<Map<String, dynamic>>().toList(
          growable: false,
        );
      }
    }

    if (!_messages.isClosed) {
      _messages.add(
        RelayMessage(
          kind: kind,
          id: id is String ? id : null,
          payload: payload,
        ),
      );
    }
  }
}

enum RelayStatus { disconnected, connecting, connected, frameRejected, failed }

class RelayStatusUpdate {
  const RelayStatusUpdate(this.status, [this.error]);

  final RelayStatus status;
  final RelayException? error;
}

/// Argument bundle for the worker-isolate key derivation.
///
/// A worker cannot receive a closure, so the work is expressed as a plain
/// object passed to a top-level function.
@immutable
class KeyDerivationRequest {
  const KeyDerivationRequest({
    required this.passphrase,
    required this.salt,
    required this.clientNonce,
    required this.serverNonce,
  });

  final String passphrase;
  final Uint8List salt;
  final Uint8List clientNonce;
  final Uint8List serverNonce;
}

/// Runs the PBKDF2 expansion on a worker isolate.
///
/// Top level on purpose: this is the entry point a worker calls, so it must not
/// capture anything from the isolate that spawned it.
SessionKeys deriveKeysInWorker(KeyDerivationRequest request) {
  return SessionKeyDerivation.derive(
    passphrase: request.passphrase,
    serverSalt: request.salt,
    clientNonce: request.clientNonce,
    serverNonce: request.serverNonce,
  );
}
