import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:dz_id_reader/src/lds/code_pages.dart';
import 'package:dz_id_reader/src/lds/text.dart';

/// [text] in a one-byte code page ([table] maps bytes 0x80-0xFF).
List<int> encode(String text, List<int> table) {
  final reverse = {for (var i = 0; i < 128; i++) table[i]: 0x80 + i};
  return [for (final c in text.runes) c < 0x80 ? c : reverse[c]!];
}

void main() {
  // Made-up values in the Algerian ID card's layout.
  const values = ['SPECIMEN<عينة', 'DEMO<تجربة', 'ALGER<الجزائر', 'F<أنثى<O+'];

  for (final (name, table, expected) in [
    ('ISO-8859-6', iso88596, TextEncoding.iso88596),
    ('Windows-1256', cp1256, TextEncoding.cp1256),
  ]) {
    test('Arabic in $name is found and decoded', () {
      final encoded = [for (final v in values) encode(v, table)];
      expect(detectEncoding(encoded), expected);
      expect([for (final v in encoded) decodeText(v, expected)], values);
    });
  }

  test('valid UTF-8 stays UTF-8 (the licence)', () {
    final encoded = [for (final v in values) utf8.encode(v)];
    expect(detectEncoding(encoded), TextEncoding.utf8);
    expect(decodeText(encoded.first, TextEncoding.utf8), values.first);
  });

  test('one short word is enough when it has a telling letter', () {
    // ي is EA in ISO-8859-6 but ED in Windows-1256.
    expect(detectEncoding([encode('دي', iso88596)]), TextEncoding.iso88596);
    expect(detectEncoding([encode('دي', cp1256)]), TextEncoding.cp1256);
  });
}
