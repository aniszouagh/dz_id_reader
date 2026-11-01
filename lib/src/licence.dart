import 'dart:convert';
import 'dart:typed_data';

import 'package:dmrtd/internal.dart';

/// ISO/IEC 18013-3 app on the Algerian biometric driving licence.
final licenceAid =
    Uint8List.fromList([0xA0, 0x00, 0x00, 0x02, 0x48, 0x02, 0x00]);

/// Selects the driving licence app; false when the chip has none.
Future<bool> selectLicenceApp(MrtdApi api) async {
  try {
    await api.icc.selectFileByDFName(dfName: licenceAid, p2: 0x0C);
    return true;
  } on ICCError {
    return false;
  }
}

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
      final tag = _hex(data.sublist(tagStart, i > end ? end : i));
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
      for (final (tag, value) in tlvLeafBytes(data))
        (tag, _printable(value)),
    ];

String _printable(Uint8List value) {
  final text = utf8.decode(value, allowMalformed: true);
  if (text.isNotEmpty &&
      !text.contains('\uFFFD') &&
      text.runes.every((r) => r >= 0x20)) {
    return text;
  }
  return value.length > 24
      ? '${_hex(value.take(24))}… (${value.length} bytes)'
      : _hex(value);
}

String _hex(Iterable<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
