import 'dart:typed_data';

/// Hex helpers. The wire contract uses lowercase hex everywhere, which is what
/// the C side emits from `dsh_hex_encode`.
abstract final class Hex {
  static const String _digits = '0123456789abcdef';

  static String encode(List<int> bytes) {
    final out = StringBuffer();
    for (final b in bytes) {
      out.write(_digits[(b >> 4) & 0x0f]);
      out.write(_digits[b & 0x0f]);
    }
    return out.toString();
  }

  /// Decodes [hex], accepting either case. Throws [FormatException] on odd
  /// length or a non-hex digit, mirroring `dsh_hex_decode` returning -1.
  static Uint8List decode(String hex) {
    if (hex.length.isOdd) {
      throw FormatException('hex string must have an even length', hex);
    }
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final hi = _digit(hex.codeUnitAt(i * 2));
      final lo = _digit(hex.codeUnitAt(i * 2 + 1));
      out[i] = (hi << 4) | lo;
    }
    return out;
  }

  static int _digit(int code) {
    if (code >= 0x30 && code <= 0x39) return code - 0x30;
    if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10;
    if (code >= 0x41 && code <= 0x46) return code - 0x41 + 10;
    throw FormatException('not a hex digit: ${String.fromCharCode(code)}');
  }
}

/// Byte-level equality that does not short-circuit, mirroring `dsh_ct_equal`.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Concatenates byte sequences into one buffer.
Uint8List concatBytes(List<List<int>> parts) {
  var total = 0;
  for (final p in parts) {
    total += p.length;
  }
  final out = Uint8List(total);
  var offset = 0;
  for (final p in parts) {
    out.setRange(offset, offset + p.length, p);
    offset += p.length;
  }
  return out;
}

/// Big-endian uint32 read used by the frame header.
int readUint32Be(List<int> data, int offset) =>
    (data[offset] << 24) |
    (data[offset + 1] << 16) |
    (data[offset + 2] << 8) |
    data[offset + 3];

/// Big-endian uint32 write used by the frame header.
void writeUint32Be(Uint8List out, int offset, int value) {
  out[offset] = (value >> 24) & 0xff;
  out[offset + 1] = (value >> 16) & 0xff;
  out[offset + 2] = (value >> 8) & 0xff;
  out[offset + 3] = value & 0xff;
}
