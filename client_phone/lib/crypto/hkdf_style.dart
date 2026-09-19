import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'bytes.dart';

/// Hash primitives used by the relay contract, matching `dsh_sha256.h`.
abstract final class Digests {
  static const int sha256Length = 32;
  static const int sha256BlockLength = 64;

  static Uint8List sha256(List<int> data) {
    final digest = SHA256Digest();
    return digest.process(Uint8List.fromList(data));
  }

  static Uint8List hmacSha256(List<int> key, List<int> data) {
    final mac = HMac(SHA256Digest(), sha256BlockLength)
      ..init(KeyParameter(Uint8List.fromList(key)));
    return mac.process(Uint8List.fromList(data));
  }

  /// RFC 8018 PBKDF2 with HMAC-SHA256 as the PRF.
  static Uint8List pbkdf2HmacSha256({
    required List<int> password,
    required List<int> salt,
    required int iterations,
    required int derivedKeyLength,
  }) {
    if (iterations < 1) {
      throw ArgumentError.value(iterations, 'iterations', 'must be >= 1');
    }
    final derivator =
        PBKDF2KeyDerivator(HMac(SHA256Digest(), sha256BlockLength))..init(
          Pbkdf2Parameters(
            Uint8List.fromList(salt),
            iterations,
            derivedKeyLength,
          ),
        );
    return derivator.process(Uint8List.fromList(password));
  }
}

/// The four directional secrets plus the master key of one session.
///
/// This is exactly the material `dsh_crypto_derive` computes; the wire only
/// ever uses [keyC2s], [keyS2c], [macC2s] and [macS2c].
class SessionKeys {
  SessionKeys({
    required this.master,
    required this.keyC2s,
    required this.keyS2c,
    required this.macC2s,
    required this.macS2c,
  });

  static const int idLength = 16;

  final Uint8List master;
  final Uint8List keyC2s;
  final Uint8List keyS2c;
  final Uint8List macC2s;
  final Uint8List macS2c;
}

/// Session key derivation for the `dsh-relay/v1` protocol.
///
/// ```text
/// mixed  = serverSalt(16) || clientNonce(16) || serverNonce(16)
/// master = PBKDF2-HMAC-SHA256(passphrase, mixed, 50000, 64)
/// keyX   = HMAC-SHA256(master, label)
/// ```
///
/// Labels are raw bytes, not text: `"c2s\0"` and `"s2c\0"` carry a trailing
/// NUL, `"mc2s"` and `"ms2c"` do not. Both sides must agree byte for byte.
abstract final class SessionKeyDerivation {
  /// PBKDF2 round count fixed by the wire contract.
  static const int iterations = 50000;

  /// Master key length in bytes.
  static const int masterLength = 64;

  /// `"dsh-relay/v1"`, the handshake proof context string.
  static const String proofContext = 'dsh-relay/v1';

  static final Uint8List _labelC2s = Uint8List.fromList(const [
    0x63,
    0x32,
    0x73,
    0x00,
  ]);
  static final Uint8List _labelS2c = Uint8List.fromList(const [
    0x73,
    0x32,
    0x63,
    0x00,
  ]);
  static final Uint8List _labelMacC2s = Uint8List.fromList(const [
    0x6d,
    0x63,
    0x32,
    0x73,
  ]);
  static final Uint8List _labelMacS2c = Uint8List.fromList(const [
    0x6d,
    0x73,
    0x32,
    0x63,
  ]);

  /// `HMAC-SHA256(key = UTF8(passphrase), data = "dsh-relay/v1" || nonce)`.
  ///
  /// Carried in the plaintext HELLO so the server can reject a wrong passphrase
  /// before any encrypted frame is processed. The passphrase itself never
  /// crosses the wire.
  static Uint8List handshakeProof(String passphrase, List<int> nonce) {
    if (nonce.length != SessionKeys.idLength) {
      throw ArgumentError.value(nonce.length, 'nonce', 'must be 16 bytes');
    }
    return Digests.hmacSha256(
      utf8.encode(passphrase),
      concatBytes([utf8.encode(proofContext), nonce]),
    );
  }

  /// Derives the four directional keys from the shared passphrase and the
  /// three handshake values.
  static SessionKeys derive({
    required String passphrase,
    required List<int> serverSalt,
    required List<int> clientNonce,
    required List<int> serverNonce,
    int iterations = SessionKeyDerivation.iterations,
  }) {
    _checkId(serverSalt, 'serverSalt');
    _checkId(clientNonce, 'clientNonce');
    _checkId(serverNonce, 'serverNonce');

    final mixed = concatBytes([serverSalt, clientNonce, serverNonce]);
    final master = Digests.pbkdf2HmacSha256(
      password: utf8.encode(passphrase),
      salt: mixed,
      iterations: iterations,
      derivedKeyLength: masterLength,
    );

    return SessionKeys(
      master: master,
      keyC2s: Digests.hmacSha256(master, _labelC2s),
      keyS2c: Digests.hmacSha256(master, _labelS2c),
      macC2s: Digests.hmacSha256(master, _labelMacC2s),
      macS2c: Digests.hmacSha256(master, _labelMacS2c),
    );
  }

  static void _checkId(List<int> value, String name) {
    if (value.length != SessionKeys.idLength) {
      throw ArgumentError.value(value.length, name, 'must be 16 bytes');
    }
  }
}
