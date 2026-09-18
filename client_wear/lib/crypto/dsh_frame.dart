import 'dart:typed_data';

import 'bytes.dart';

/// Wire-visible frame types. Values mirror the `DSH_FRAME_*` enum in
/// `common/wire/dsh_wire.h` and must stay stable.
abstract final class DshFrameType {
  static const int hello = 1;
  static const int helloAck = 2;
  static const int data = 3;
  static const int bye = 4;

  static const Map<int, String> names = <int, String>{
    hello: 'HELLO',
    helloAck: 'HELLO_ACK',
    data: 'DATA',
    bye: 'BYE',
  };

  static String nameOf(int type) => names[type] ?? 'UNKNOWN($type)';
}

/// Handshake roles carried in the HELLO payload.
abstract final class DshRole {
  static const int agent = 1;
  static const int client = 2;

  static const int sender = agent;
}

/// Fixed layout of one `DSHX` frame.
///
/// ```text
/// offset  size  field
/// 0       4     magic "DSHX"
/// 4       1     version (1)
/// 5       1     type
/// 6       1     flags
/// 7       1     reserved (0)
/// 8       4     sequence, big endian
/// 12      4     body length, big endian
/// 16      16    IV
/// 32      N     AES-256-CBC ciphertext
/// 32+N    32    HMAC-SHA256 over bytes [0, 32+N)
/// ```
///
/// Plaintext handshake frames reuse the header but set [flagPlaintext], keep a
/// zero IV and a zero sequence, store the *plaintext* length at offset 12 and
/// carry no trailing tag, so the total is `32 + payloadLength`.
abstract final class DshFrameLayout {
  static const int headerLength = 32;
  static const int tagLength = 32;
  static const int ivLength = 16;
  static const int version = 1;
  static const int flagPlaintext = 0x01;
  static const int maxPayload = 8 * 1024 * 1024;
  static const List<int> magic = <int>[0x44, 0x53, 0x48, 0x58]; // "DSHX"

  /// Smallest possible encrypted frame: header, one cipher block, one tag.
  static const int minEncryptedLength = headerLength + ivLength + tagLength;
}

/// Thrown when raw bytes do not form a structurally valid frame.
class DshFrameFormatException implements Exception {
  const DshFrameFormatException(this.message);

  final String message;

  @override
  String toString() => 'DshFrameFormatException: $message';
}

/// Parsed 32-byte frame header.
class DshFrameHeader {
  const DshFrameHeader({
    required this.type,
    required this.flags,
    required this.sequence,
    required this.bodyLength,
    required this.iv,
  });

  final int type;
  final int flags;
  final int sequence;

  /// Ciphertext length for an encrypted frame, plaintext length for a
  /// handshake frame.
  final int bodyLength;
  final Uint8List iv;

  bool get isPlaintext => (flags & DshFrameLayout.flagPlaintext) != 0;

  /// Validates magic, version and length, then reads the header.
  factory DshFrameHeader.parse(List<int> raw) {
    if (raw.length < DshFrameLayout.headerLength) {
      throw const DshFrameFormatException(
        'frame shorter than the 32 byte header',
      );
    }
    for (var i = 0; i < DshFrameLayout.magic.length; i++) {
      if (raw[i] != DshFrameLayout.magic[i]) {
        throw const DshFrameFormatException('bad magic, expected "DSHX"');
      }
    }
    if (raw[4] != DshFrameLayout.version) {
      throw DshFrameFormatException('unsupported version ${raw[4]}');
    }
    return DshFrameHeader(
      type: raw[5],
      flags: raw[6],
      sequence: readUint32Be(raw, 8),
      bodyLength: readUint32Be(raw, 12),
      iv: Uint8List.fromList(raw.sublist(16, 32)),
    );
  }

  /// Serializes a header. [bodyLength] is the ciphertext length for encrypted
  /// frames and the plaintext length for handshake frames.
  static Uint8List encode({
    required int type,
    required int flags,
    required int sequence,
    required int bodyLength,
    required List<int> iv,
  }) {
    if (iv.length != DshFrameLayout.ivLength) {
      throw ArgumentError.value(iv.length, 'iv', 'must be 16 bytes');
    }
    final out = Uint8List(DshFrameLayout.headerLength);
    out.setRange(0, 4, DshFrameLayout.magic);
    out[4] = DshFrameLayout.version;
    out[5] = type & 0xff;
    out[6] = flags & 0xff;
    out[7] = 0;
    writeUint32Be(out, 8, sequence);
    writeUint32Be(out, 12, bodyLength);
    out.setRange(16, 32, iv);
    return out;
  }
}

/// A plaintext handshake frame (`HELLO` / `HELLO_ACK`), used before any key
/// exists. No encryption and no tag; the header marks it with flag bit 0.
class DshPlainFrame {
  const DshPlainFrame({required this.type, required this.payload});

  final int type;
  final Uint8List payload;

  static Uint8List seal(int type, List<int> payload) {
    if (payload.length > DshFrameLayout.maxPayload) {
      throw ArgumentError.value(
        payload.length,
        'payload',
        'exceeds the frame ceiling',
      );
    }
    final header = DshFrameHeader.encode(
      type: type,
      flags: DshFrameLayout.flagPlaintext,
      sequence: 0,
      bodyLength: payload.length,
      iv: Uint8List(DshFrameLayout.ivLength),
    );
    return concatBytes([header, payload]);
  }

  /// Parses a handshake frame, enforcing the flag, a zero body offset and an
  /// exact total length.
  static DshPlainFrame parse(List<int> raw) {
    final header = DshFrameHeader.parse(raw);
    if (!header.isPlaintext) {
      throw const DshFrameFormatException(
        'frame is not flagged as a handshake frame',
      );
    }
    if (header.bodyLength != raw.length - DshFrameLayout.headerLength) {
      throw DshFrameFormatException(
        'declared body length ${header.bodyLength} does not match '
        '${raw.length - DshFrameLayout.headerLength} available bytes',
      );
    }
    return DshPlainFrame(
      type: header.type,
      payload: Uint8List.fromList(raw.sublist(DshFrameLayout.headerLength)),
    );
  }
}
