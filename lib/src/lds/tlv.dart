import 'dart:convert';
import 'dart:typed_data';

import '../chip/bytes.dart';

/// Flattens BER-TLV data into (tag, raw value) pairs: constructed tags are
/// opened, primitive ones listed.
List<(String, Uint8List)> tlvLeafBytes(Uint8List data) {
  final out = <(String, Uint8List)>[];
  void walk(int start, int end) {
    var i = start;
    while (i < end) {
      if (data[i] == 0x00 || data[i] == 0xFF) {
        i++; // padding between objects
        continue;
      }
      final tagStart = i;
      final constructed = data[i] & 0x20 != 0;
      if (data[i] & 0x1F == 0x1F) {
        i++;
        while (i < end && data[i] & 0x80 != 0) {
          i++;
        }
      }
      i++;
      final tag = toHex(data.sublist(tagStart, i > end ? end : i));
      if (i >= end) return;
      var len = data[i++];
      if (len & 0x80 != 0) {
        final n = len & 0x7F;
        len = 0;
        for (var k = 0; k < n && i < end; k++) {
          len = (len << 8) | data[i++];
        }
      }
      final valueEnd = i + len > end ? end : i + len;
      if (constructed) {
        walk(i, valueEnd);
      } else {
        out.add((tag, Uint8List.sublistView(data, i, valueEnd)));
      }
      i = valueEnd;
    }
  }

  walk(0, data.length);
  return out;
}

/// [tlvLeafBytes] for display: a value is shown as text when it is
/// printable, otherwise as hex (dates in ISO 18013 are BCD, so they read
/// fine as hex).
List<(String, String)> tlvLeaves(Uint8List data) => [
  for (final (tag, value) in tlvLeafBytes(data)) (tag, printable(value)),
];

/// [value] as text when it is printable UTF-8, otherwise as hex.
String printable(Uint8List value) {
  final text = utf8.decode(value, allowMalformed: true);
  if (text.isNotEmpty &&
      !text.contains('�') &&
      text.runes.every((r) => r >= 0x20)) {
    return text;
  }
  return value.length > 24
      ? '${toHex(value.take(24))}… (${value.length} bytes)'
      : toHex(value);
}

/// The layout of a value with its content hidden, for logs while working
/// out an unknown format: letters become `A`, digits `9`, other bytes of
/// UTF-8 text `U`, binary bytes `#`; spaces and punctuation stay.
String shapeOf(Uint8List value) {
  final out = StringBuffer();
  for (final b in value) {
    if (b >= 0x41 && b <= 0x5A || b >= 0x61 && b <= 0x7A) {
      out.write('A');
    } else if (b >= 0x30 && b <= 0x39) {
      out.write('9');
    } else if (b >= 0x80) {
      out.write('U');
    } else if (b >= 0x20 && b < 0x7F) {
      out.writeCharCode(b);
    } else {
      out.write('#');
    }
  }
  return out.toString();
}
