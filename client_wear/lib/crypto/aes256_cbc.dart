import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Raised when a decrypted buffer does not carry valid PKCS#7 padding.
/// The C side reports the same condition as `dsh_aes256_cbc_decrypt` != 0,
/// which `dsh_wire_open` surfaces as -3.
class AesPaddingException implements Exception {
  const AesPaddingException(this.message);

  final String message;

  @override
  String toString() => 'AesPaddingException: $message';
}

/// AES-256-CBC with PKCS#7 padding, byte-compatible with
/// `common/crypto/dsh_aes.c` (`dsh_aes256_cbc_encrypt` / `dsh_aes256_cbc_decrypt`).
///
/// Padding is applied here instead of through pointycastle's
/// `PaddedBlockCipher` so the block count matches the C contract exactly:
/// `cipherLength = (plainLength ~/ 16 + 1) * 16`, meaning a plaintext that is
/// already block aligned still grows by one full padding block.
abstract final class Aes256Cbc {
  static const int blockSize = 16;
  static const int keySize = 32;
  static const int ivSize = 16;

  /// Encrypts [plaintext] and returns `padding(plaintext)` encrypted in CBC
  /// mode. [key] must be 32 bytes, [iv] 16 bytes.
  static Uint8List encrypt({
    required List<int> key,
    required List<int> iv,
    required List<int> plaintext,
  }) {
    _checkKey(key);
    _checkIv(iv);

    final padded = pkcs7Pad(plaintext);
    final cipher = CBCBlockCipher(AESEngine())
      ..init(
        true,
        ParametersWithIV<KeyParameter>(
          KeyParameter(Uint8List.fromList(key)),
          Uint8List.fromList(iv),
        ),
      );

    final out = Uint8List(padded.length);
    for (var offset = 0; offset < padded.length; offset += blockSize) {
      cipher.processBlock(padded, offset, out, offset);
    }
    return out;
  }

  /// Decrypts [ciphertext] and strips PKCS#7 padding. Throws
  /// [AesPaddingException] when the padding is malformed.
  static Uint8List decrypt({
    required List<int> key,
    required List<int> iv,
    required List<int> ciphertext,
  }) {
    _checkKey(key);
    _checkIv(iv);
    if (ciphertext.isEmpty || ciphertext.length % blockSize != 0) {
      throw const AesPaddingException(
        'ciphertext length must be a positive multiple of 16',
      );
    }

    final cipher = CBCBlockCipher(AESEngine())
      ..init(
        false,
        ParametersWithIV<KeyParameter>(
          KeyParameter(Uint8List.fromList(key)),
          Uint8List.fromList(iv),
        ),
      );

    final out = Uint8List(ciphertext.length);
    final input = Uint8List.fromList(ciphertext);
    for (var offset = 0; offset < out.length; offset += blockSize) {
      cipher.processBlock(input, offset, out, offset);
    }
    return pkcs7Unpad(out);
  }

  /// Single block AES-256 encryption, the primitive the CBC chain wraps.
  /// Exposed so the FIPS-197 conformance vectors can be checked directly.
  static Uint8List encryptBlock(List<int> key, List<int> block) {
    _checkKey(key);
    if (block.length != blockSize) {
      throw ArgumentError.value(block.length, 'block', 'must be 16 bytes');
    }
    final engine = AESEngine()
      ..init(true, KeyParameter(Uint8List.fromList(key)));
    final out = Uint8List(blockSize);
    engine.processBlock(Uint8List.fromList(block), 0, out, 0);
    return out;
  }

  /// Single block AES-256 decryption.
  static Uint8List decryptBlock(List<int> key, List<int> block) {
    _checkKey(key);
    if (block.length != blockSize) {
      throw ArgumentError.value(block.length, 'block', 'must be 16 bytes');
    }
    final engine = AESEngine()
      ..init(false, KeyParameter(Uint8List.fromList(key)));
    final out = Uint8List(blockSize);
    engine.processBlock(Uint8List.fromList(block), 0, out, 0);
    return out;
  }

  /// Appends `16 - (len % 16)` bytes of value `16 - (len % 16)`; a block
  /// aligned input therefore gains a full 16-byte block.
  static Uint8List pkcs7Pad(List<int> data) {
    final pad = blockSize - (data.length % blockSize);
    final out = Uint8List(data.length + pad);
    out.setRange(0, data.length, data);
    out.fillRange(data.length, out.length, pad);
    return out;
  }

  /// Validates and removes PKCS#7 padding.
  static Uint8List pkcs7Unpad(List<int> data) {
    if (data.isEmpty || data.length % blockSize != 0) {
      throw const AesPaddingException(
        'padded length must be a positive multiple of 16',
      );
    }
    final pad = data[data.length - 1];
    if (pad == 0 || pad > blockSize || pad > data.length) {
      throw AesPaddingException('invalid padding byte $pad');
    }
    for (var i = 0; i < pad; i++) {
      if (data[data.length - 1 - i] != pad) {
        throw const AesPaddingException('padding bytes are inconsistent');
      }
    }
    return Uint8List.fromList(data.sublist(0, data.length - pad));
  }

  /// Ciphertext length for a plaintext of [plainLength] bytes.
  static int cipherLength(int plainLength) =>
      (plainLength ~/ blockSize + 1) * blockSize;

  static void _checkKey(List<int> key) {
    if (key.length != keySize) {
      throw ArgumentError.value(key.length, 'key', 'AES-256 needs 32 bytes');
    }
  }

  static void _checkIv(List<int> iv) {
    if (iv.length != ivSize) {
      throw ArgumentError.value(iv.length, 'iv', 'CBC needs a 16 byte IV');
    }
  }
}
