import 'dart:convert';

import 'code_pages.dart';

/// How the text of a chip file is encoded. ICAO says UTF-8, and the
/// licence uses it; the Algerian ID card stores Arabic in a one-byte code
/// page instead.
enum TextEncoding { utf8, iso88596, cp1256 }

/// The encoding of the text [values] of one file: UTF-8 when they all are
/// valid UTF-8, otherwise the Arabic code page that turns their bytes into
/// the most Arabic letters. Deciding per file, over all its values, leaves
/// little doubt: the two code pages share only part of the alphabet.
TextEncoding detectEncoding(Iterable<List<int>> values) {
  final other = [
    for (final v in values)
      if (!_isUtf8(v)) v,
  ];
  if (other.isEmpty) return TextEncoding.utf8;
  final iso = _score(other, iso88596), win = _score(other, cp1256);
  return win > iso ? TextEncoding.cp1256 : TextEncoding.iso88596;
}

String decodeText(List<int> bytes, TextEncoding encoding) => switch (encoding) {
  TextEncoding.utf8 => utf8.decode(bytes, allowMalformed: true),
  TextEncoding.iso88596 => _decode(bytes, iso88596),
  TextEncoding.cp1256 => _decode(bytes, cp1256),
};

/// Whether [s] has Arabic letters.
bool hasArabic(String s) => s.runes.any(_isArabicLetter);

bool _isUtf8(List<int> bytes) {
  try {
    utf8.decode(bytes);
    return true;
  } on FormatException {
    return false;
  }
}

String _decode(List<int> bytes, List<int> table) => String.fromCharCodes([
  for (final b in bytes) b < 0x80 ? b : table[b - 0x80],
]);

/// Arabic letters count for a code page; anything else above ASCII (Latin
/// accents, vowel marks, controls, undefined bytes) counts against it.
int _score(List<List<int>> values, List<int> table) {
  var score = 0;
  for (final v in values) {
    for (final b in v) {
      if (b < 0x80) continue;
      score += _isArabicLetter(table[b - 0x80]) ? 1 : -2;
    }
  }
  return score;
}

bool _isArabicLetter(int c) =>
    (c >= 0x0621 && c <= 0x063A) || (c >= 0x0641 && c <= 0x064A);
