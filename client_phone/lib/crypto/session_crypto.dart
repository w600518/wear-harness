import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'aes256_cbc.dart';
import 'bytes.dart';
import 'dsh_frame.dart';
import 'hkdf_style.dart';

/// Why a frame was rejected.
///
/// The first four map onto the C return codes of `dsh_wire_open`
/// (`malformed` = -1, `tampered` = -2, `replay` = -1 with an authenticated but
/// stale sequence, `padding` = -3).
enum DshFrameFailure { malformed, tampered, replay, padding }

/// Rejection raised by [SessionCrypto.open].
class DshFrameException implements Exception {
  const DshFrameException(this.failure, this.message);

  final DshFrameFailure failure;
  final String message;

  bool get isTamper => failure == DshFrameFailure.tampered;

  @override
  String toString() => 'DshFrameException(${failure.name}): $message';
}

/// One authenticated, decrypted frame.
class OpenedFrame {
  const OpenedFrame({
    required this.type,
    required this.sequence,
    required this.payload,
  });

  final int type;
  final int sequence;
  final Uint8List payload;

  String get text => utf8.decode(payload);
}

/// One authenticated, decrypted frame, before any session state is touched.
///
/// Produced by [openFrameBytes], which is the whole of [SessionCrypto.open]
/// apart from the replay bookkeeping. Splitting that out is what lets a large
/// frame be opened on a worker isolate without a second copy of the wire rules
/// existing anywhere.
class OpenedFrameBytes {
  const OpenedFrameBytes({
    required this.type,
    required this.sequence,
    required this.payload,
  });

  final int type;
  final int sequence;
  final Uint8List payload;
}

/// Verifies and decrypts one frame, touching nothing but its arguments.
///
/// A session snapshot carries the entire conversation — hundreds of kilobytes —
/// and running the HMAC, the AES pass and then the JSON decode of that inline
/// blocked the main isolate for long enough to drop frames, which is the
/// stutter seen while a conversation opens. This function is pure so the same
/// work can be handed to a worker isolate; small frames stay on the main
/// isolate, where a round trip to a worker would cost more than the work.
///
/// The validation order is the wire contract and is preserved exactly:
/// magic/version/length, then the HMAC, then the sequence, then decryption. A
/// tampered frame must be indistinguishable from noise, so it can never advance
/// the replay window — which is why [receiveSequence] is checked here rather
/// than by the caller after the fact.
OpenedFrameBytes openFrameBytes({
  required Uint8List frame,
  required Uint8List decryptionKey,
  required Uint8List receiveMacKey,
  required int receiveSequence,
}) {
  final bytes = frame;

  if (bytes.length < DshFrameLayout.minEncryptedLength) {
    throw const DshFrameException(
      DshFrameFailure.malformed,
      'frame is shorter than header + one block + tag',
    );
  }
  final header = _parseHeaderStrict(bytes);
  if (header.isPlaintext) {
    throw const DshFrameException(
      DshFrameFailure.malformed,
      'handshake frame arrived on an established channel',
    );
  }

  final cipherLength = header.bodyLength;
  if (cipherLength == 0 || cipherLength % Aes256Cbc.blockSize != 0) {
    throw DshFrameException(
      DshFrameFailure.malformed,
      'ciphertext length $cipherLength is not a positive multiple of 16',
    );
  }
  if (cipherLength !=
      bytes.length - DshFrameLayout.headerLength - DshFrameLayout.tagLength) {
    throw DshFrameException(
      DshFrameFailure.malformed,
      'ciphertext length $cipherLength does not match the frame size',
    );
  }

  final signedLength = DshFrameLayout.headerLength + cipherLength;
  final expectedTag = Digests.hmacSha256(
    receiveMacKey,
    Uint8List.sublistView(bytes, 0, signedLength),
  );
  final actualTag = Uint8List.sublistView(
    bytes,
    signedLength,
    signedLength + DshFrameLayout.tagLength,
  );
  if (!constantTimeEquals(expectedTag, actualTag)) {
    throw const DshFrameException(
      DshFrameFailure.tampered,
      'HMAC mismatch, frame was modified in transit',
    );
  }

  if (header.sequence <= receiveSequence) {
    throw DshFrameException(
      DshFrameFailure.replay,
      'sequence ${header.sequence} does not advance past $receiveSequence',
    );
  }

  final Uint8List plain;
  try {
    plain = Aes256Cbc.decrypt(
      key: decryptionKey,
      iv: header.iv,
      ciphertext: Uint8List.sublistView(
        bytes,
        DshFrameLayout.headerLength,
        signedLength,
      ),
    );
  } on AesPaddingException catch (error) {
    throw DshFrameException(DshFrameFailure.padding, error.message);
  }

  return OpenedFrameBytes(
    type: header.type,
    sequence: header.sequence,
    payload: plain,
  );
}

/// [openFrameBytes] as a worker message.
///
/// `compute` carries a single argument, and every value here is one the
/// platform can move between isolates.
Map<String, Object> openFrameRequest({
  required Uint8List frame,
  required Uint8List decryptionKey,
  required Uint8List receiveMacKey,
  required int receiveSequence,
}) => <String, Object>{
  'frame': frame,
  'decryptionKey': decryptionKey,
  'receiveMacKey': receiveMacKey,
  'receiveSequence': receiveSequence,
};

/// Worker entry point that also decodes the payload's JSON.
///
/// Used for frames big enough to be worth the trip. Decoding is the larger half
/// of the cost — building the object tree from a few hundred kilobytes of text
/// takes longer than the HMAC and the AES pass that produced it — so a snapshot
/// would still stutter if only the decryption were moved off the main isolate.
Map<String, Object?> openJsonInWorker(Map<String, Object> request) {
  final opened = openFrameBytes(
    frame: request['frame']! as Uint8List,
    decryptionKey: request['decryptionKey']! as Uint8List,
    receiveMacKey: request['receiveMacKey']! as Uint8List,
    receiveSequence: request['receiveSequence']! as int,
  );
  return <String, Object?>{
    'type': opened.type,
    'sequence': opened.sequence,
    'value': jsonDecode(utf8.decode(opened.payload)),
  };
}

/// Authenticated encryption state for one relay connection.
///
/// The client and the agent share the same derivation and therefore the same
/// directional key assignment: a client encrypts with `key_c2s` and MACs with
/// `mac_c2s`, while the server mirrors it ([isServer] flips every direction).
///
/// Frames are accepted only in strictly increasing sequence order. Sequence
/// numbers start at 1 on both directions, so the zero-initialized receive
/// counter means "nothing received yet".
class SessionCrypto {
  SessionCrypto({required this.keys, this.isServer = false, Random? random})
    : _random = random ?? Random.secure();

  final SessionKeys keys;
  final bool isServer;
  final Random _random;

  int _sendSequence = 1;
  int _receiveSequence = 0;

  Uint8List get encryptionKey => isServer ? keys.keyS2c : keys.keyC2s;
  Uint8List get decryptionKey => isServer ? keys.keyC2s : keys.keyS2c;
  Uint8List get sendMacKey => isServer ? keys.macS2c : keys.macC2s;
  Uint8List get receiveMacKey => isServer ? keys.macC2s : keys.macS2c;

  /// Sequence the next outgoing frame will carry.
  int get sendSequence => _sendSequence;

  /// Highest accepted incoming sequence, 0 before the first frame.
  int get receiveSequence => _receiveSequence;

  /// Builds a new session for one connection.
  ///
  /// [isServer] follows the C `dsh_crypto_derive` argument: true for the relay
  /// server (Agent side of a client connection), false for the Wear client and
  /// for the Windows sender.
  factory SessionCrypto.derive({
    required String passphrase,
    required List<int> serverSalt,
    required List<int> clientNonce,
    required List<int> serverNonce,
    bool isServer = false,
    Random? random,
    int iterations = SessionKeyDerivation.iterations,
  }) {
    return SessionCrypto(
      keys: SessionKeyDerivation.derive(
        passphrase: passphrase,
        serverSalt: serverSalt,
        clientNonce: clientNonce,
        serverNonce: serverNonce,
        iterations: iterations,
      ),
      isServer: isServer,
      random: random,
    );
  }

  /// Encrypts [payload] into one `DATA` (or `BYE`) frame and returns the full
  /// bytes to put on the wire. The sequence only advances when the frame is
  /// built successfully.
  ///
  /// [iv] is only meant for tests reproducing a fixed vector; production
  /// callers must let the frame draw a fresh random IV.
  Uint8List seal(int type, List<int> payload, {List<int>? iv}) {
    if (payload.length > DshFrameLayout.maxPayload) {
      throw ArgumentError.value(
        payload.length,
        'payload',
        'exceeds the ${DshFrameLayout.maxPayload} byte frame ceiling',
      );
    }

    final frameIv = iv != null
        ? Uint8List.fromList(iv)
        : randomBytes(DshFrameLayout.ivLength);
    if (frameIv.length != DshFrameLayout.ivLength) {
      throw ArgumentError.value(frameIv.length, 'iv', 'must be 16 bytes');
    }

    final ciphertext = Aes256Cbc.encrypt(
      key: encryptionKey,
      iv: frameIv,
      plaintext: payload,
    );
    final header = DshFrameHeader.encode(
      type: type,
      flags: 0,
      sequence: _sendSequence,
      bodyLength: ciphertext.length,
      iv: frameIv,
    );

    final signed = concatBytes([header, ciphertext]);
    final tag = Digests.hmacSha256(sendMacKey, signed);
    _sendSequence++;
    return concatBytes([signed, tag]);
  }

  /// Convenience wrapper that seals a UTF-8 JSON payload as a `DATA` frame.
  Uint8List sealText(int type, String text) => seal(type, utf8.encode(text));

  /// Verifies and decrypts a complete frame.
  ///
  /// Delegates to [openFrameBytes] so the wire rules exist once, and keeps the
  /// replay window here: the check needs the live counter, and advancing it is
  /// this object's, not a worker's, to do.
  OpenedFrame open(List<int> frame) {
    final bytes = frame is Uint8List ? frame : Uint8List.fromList(frame);
    final opened = openFrameBytes(
      frame: bytes,
      decryptionKey: decryptionKey,
      receiveMacKey: receiveMacKey,
      receiveSequence: _receiveSequence,
    );
    _receiveSequence = opened.sequence;
    return OpenedFrame(
      type: opened.type,
      sequence: opened.sequence,
      payload: opened.payload,
    );
  }

  /// Advances the replay window to a sequence a worker already validated.
  ///
  /// The worker checks the sequence against the counter it was handed and
  /// refuses anything stale, but only this object may move the counter; the
  /// caller moves it in arrival order.
  void acceptReceiveSequence(int sequence) {
    if (sequence > _receiveSequence) {
      _receiveSequence = sequence;
    }
  }

  /// Fills [length] bytes from the platform CSPRNG. Used for IVs and nonces.
  Uint8List randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }
}

/// Parses a header, reporting a format problem as the frame failure callers
/// catch.
///
/// [DshFrameHeader.parse] raises its own format exception, and every frame path
/// handles only [DshFrameException], so a malformed header would otherwise
/// escape as an unhandled error.
DshFrameHeader _parseHeaderStrict(Uint8List bytes) {
  try {
    return DshFrameHeader.parse(bytes);
  } on DshFrameFormatException catch (error) {
    throw DshFrameException(DshFrameFailure.malformed, error.message);
  }
}


/// The plaintext HELLO a client sends before keys exist.
class DshHello {
  const DshHello({
    required this.role,
    required this.name,
    required this.nonce,
    required this.proof,
  });

  final int role;
  final String name;
  final Uint8List nonce;
  final Uint8List proof;

  /// Builds a HELLO from a shared passphrase and a fresh 16 byte nonce.
  factory DshHello.create({
    required int role,
    required String name,
    required String passphrase,
    required Uint8List nonce,
  }) {
    if (role != DshRole.agent && role != DshRole.client) {
      throw ArgumentError.value(
        role,
        'role',
        'must be ${DshRole.agent} (agent) or ${DshRole.client} (client)',
      );
    }
    if (nonce.length != SessionKeys.idLength) {
      throw ArgumentError.value(nonce.length, 'nonce', 'must be 16 bytes');
    }
    return DshHello(
      role: role,
      name: name,
      nonce: nonce,
      proof: SessionKeyDerivation.handshakeProof(passphrase, nonce),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'role': role,
    'name': name,
    'nonce': Hex.encode(nonce),
    'proof': Hex.encode(proof),
  };

  String encode() => jsonEncode(toJson());

  /// Parses a HELLO body, rejecting malformed hex before any crypto runs.
  factory DshHello.parse(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const FormatException('HELLO payload is not a JSON object');
    }
    final role = decoded['role'];
    if (role is! int) {
      throw const FormatException('HELLO payload has no integer role');
    }
    return DshHello(
      role: role,
      name: decoded['name'] as String? ?? '',
      nonce: Hex.decode(decoded['nonce'] as String? ?? ''),
      proof: Hex.decode(decoded['proof'] as String? ?? ''),
    );
  }

  /// Constant-time check of the proof against a locally derived one.
  bool matchesPassphrase(String passphrase) => constantTimeEquals(
    proof,
    SessionKeyDerivation.handshakeProof(passphrase, nonce),
  );
}

/// The server's plaintext reply, carrying the salt for the session KDF.
class DshHelloAck {
  const DshHelloAck({
    required this.ok,
    required this.server,
    required this.version,
    required this.salt,
    required this.nonce,
  });

  final bool ok;
  final String server;
  final String version;
  final Uint8List salt;
  final Uint8List nonce;

  Map<String, Object?> toJson() => <String, Object?>{
    'ok': ok,
    'server': server,
    'version': version,
    'salt': Hex.encode(salt),
    'nonce': Hex.encode(nonce),
  };

  String encode() => jsonEncode(toJson());

  factory DshHelloAck.parse(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const FormatException('HELLO_ACK payload is not a JSON object');
    }
    return DshHelloAck(
      ok: decoded['ok'] as bool? ?? false,
      server: decoded['server'] as String? ?? '',
      version: decoded['version'] as String? ?? '',
      salt: Hex.decode(decoded['salt'] as String? ?? ''),
      nonce: Hex.decode(decoded['nonce'] as String? ?? ''),
    );
  }
}
