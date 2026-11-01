import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dz_id_reader/src/licence.dart';

void main() {
  test('tlvLeaves opens nested tags and shows text or hex', () {
    // 61 { 5F04 "ALI", 7F63 { 87 "B;2020" }, 5F07 19 90 01 01 }
    final data = Uint8List.fromList([
      0x61, 0x18, //
      0x5F, 0x04, 0x03, 0x41, 0x4C, 0x49,
      0x7F, 0x63, 0x08, 0x87, 0x06, 0x42, 0x3B, 0x32, 0x30, 0x32, 0x30,
      0x5F, 0x07, 0x04, 0x19, 0x90, 0x01, 0x01,
    ]);
    expect(tlvLeaves(data), [
      ('5F04', 'ALI'),
      ('87', 'B;2020'),
      ('5F07', '19900101'),
    ]);
  });
}
