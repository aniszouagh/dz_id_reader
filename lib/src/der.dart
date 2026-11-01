import 'dart:convert';
import 'dart:typed_data';

/// One DER (ASN.1) element: just enough to read the certificate and
/// signature structures in EF.SOD and DG15. Only single-byte tags, which is
/// all that X.509 and CMS use.
class Der {
  Der._(this._bytes, this.start, this.tag, this.valueStart, this.end);

  /// Parses the element at [offset], which must end before [limit].
  factory Der.parse(Uint8List bytes, [int offset = 0, int? limit]) {
    final max = limit ?? bytes.length;
    if (offset + 2 > max) throw const FormatException('DER: truncated');
    final tag = bytes[offset];
    if (tag & 0x1F == 0x1F) {
      throw FormatException('DER: multi-byte tag at $offset');
    }
    var i = offset + 1;
    var length = bytes[i++];
    if (length & 0x80 != 0) {
      final n = length & 0x7F;
      if (n == 0 || n > 4 || i + n > max) {
        throw FormatException('DER: bad length at $offset');
      }
      length = 0;
      for (var k = 0; k < n; k++) {
        length = (length << 8) | bytes[i++];
      }
    }
    if (i + length > max) throw FormatException('DER: too long at $offset');
    return Der._(bytes, offset, tag, i, i + length);
  }

  final Uint8List _bytes;
  final int start;
  final int tag;
  final int valueStart;
  final int end;

  Uint8List get value => Uint8List.sublistView(_bytes, valueStart, end);

  /// The whole element: tag, length and value.
  Uint8List get encoded => Uint8List.sublistView(_bytes, start, end);

  List<Der> get children {
    final out = <Der>[];
    for (var i = valueStart; i < end;) {
      final child = Der.parse(_bytes, i, end);
      out.add(child);
      i = child.end;
    }
    return out;
  }

  Der operator [](int i) => children[i];

  String get oid {
    final v = value;
    final parts = <int>[v[0] ~/ 40, v[0] % 40];
    var n = 0;
    for (final b in v.skip(1)) {
      n = (n << 7) | (b & 0x7F);
      if (b & 0x80 == 0) {
        parts.add(n);
        n = 0;
      }
    }
    return parts.join('.');
  }

  /// INTEGER as a non-negative number (all the integers we read are).
  BigInt get integer => bytesToBigInt(value);

  /// BIT STRING content without its "unused bits" byte.
  Uint8List get bits => Uint8List.sublistView(_bytes, valueStart + 1, end);

  String get text => switch (tag) {
        0x0C => utf8.decode(value), // UTF8String
        0x1E => String.fromCharCodes([
            // BMPString: UTF-16 big-endian
            for (var i = 0; i + 1 < value.length; i += 2)
              value[i] << 8 | value[i + 1],
          ]),
        _ => latin1.decode(value),
      };

  /// UTCTime (YYMMDDHHMMSSZ) or GeneralizedTime (YYYYMMDDHHMMSSZ).
  DateTime get time {
    final s = latin1.decode(value);
    final full = tag == 0x18 ? s : '${int.parse(s.substring(0, 2)) < 50 ? '20' : '19'}$s';
    return DateTime.utc(
      int.parse(full.substring(0, 4)),
      int.parse(full.substring(4, 6)),
      int.parse(full.substring(6, 8)),
      int.parse(full.substring(8, 10)),
      int.parse(full.substring(10, 12)),
      int.parse(full.substring(12, 14)),
    );
  }
}

BigInt bytesToBigInt(List<int> bytes) {
  var n = BigInt.zero;
  for (final b in bytes) {
    n = (n << 8) | BigInt.from(b);
  }
  return n;
}

/// [n] as exactly [length] big-endian bytes.
Uint8List bigIntToBytes(BigInt n, int length) {
  final out = Uint8List(length);
  for (var i = length - 1; i >= 0 && n > BigInt.zero; i--) {
    out[i] = (n & BigInt.from(0xFF)).toInt();
    n = n >> 8;
  }
  return out;
}
