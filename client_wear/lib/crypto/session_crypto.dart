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
  /// Validation order is the wire contract: magic/version/length first, then
  /// the HMAC, then the sequence, and only then decryption. A tampered frame
  /// must be indistinguishable from random noise, so it can never advance the
  /// replay window.
  OpenedFrame open(List<int> frame) {
    final bytes = frame is Uint8List ? frame : Uint8List.fromList(frame);

    if (bytes.length < DshFrameLayout.minEncryptedLength) {
      throw const DshFrameException(
        DshFrameFailure.malformed,
        'frame is shorter than header + one block + tag',
      );
    }
    final header = _parseHeader(bytes);
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
      bytes.sublist(0, signedLength),
    );
    final actualTag = bytes.sublist(
      signedLength,
      signedLength + DshFrameLayout.tagLength,
    );
    if (!constantTimeEquals(expectedTag, actualTag)) {
      throw const DshFrameException(
        DshFrameFailure.tampered,
        'HMAC mismatch, frame was modified in transit',
      );
    }

    if (header.sequence <= _receiveSequence) {
      throw DshFrameException(
        DshFrameFailure.replay,
        'sequence ${header.sequence} does not advance past $_receiveSequence',
      );
    }

    final Uint8List plain;
    try {
      plain = Aes256Cbc.decrypt(
        key: decryptionKey,
        iv: header.iv,
        ciphertext: bytes.sublist(DshFrameLayout.headerLength, signedLength),
      );
    } on AesPaddingException catch (error) {
      throw DshFrameException(DshFrameFailure.padding, error.message);
    }

    _receiveSequence = header.sequence;
    return OpenedFrame(
      type: header.type,
      sequence: header.sequence,
      payload: plain,
    );
  }

  /// Opens a frame and decodes its payload as UTF-8 JSON text.
  String openText(List<int> frame) => open(frame).text;

  /// Fills [length] bytes from the platform CSPRNG. Used for IVs and nonces.
  Uint8List randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }

  static DshFrameHeader _parseHeader(Uint8List bytes) {
    try {
      return DshFrameHeader.parse(bytes);
    } on DshFrameFormatException catch (error) {
      throw DshFrameException(DshFrameFailure.malformed, error.message);
    }
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
