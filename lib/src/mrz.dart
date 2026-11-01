import 'package:dmrtd/dmrtd.dart' show MRZ;

/// The three MRZ values needed to unlock the chip (the BAC key).
class MrzKey {
  final String documentNumber;
  final DateTime dateOfBirth;
  final DateTime dateOfExpiry;

  const MrzKey(this.documentNumber, this.dateOfBirth, this.dateOfExpiry);
}

/// Finds the BAC key in OCR text of an ID card (TD1) or passport (TD3) MRZ.
///
/// TD1 line 1: `I` + type + issuing state(3) + document number(9) + check.
/// TD1 line 2: birth date(6) + check + sex + expiry date(6) + check + nationality(3).
/// TD3 line 2: document number(9) + check + nationality(3) + birth date(6) +
/// check + sex + expiry date(6) + check + ...
/// A frame where the whole MRZ reads cleanly is accepted at once when the
/// composite check digit (the last one, covering all the key fields) passes.
/// Otherwise every value must pass its own check digit and be seen in two
/// frames, so one bad OCR frame cannot produce a wrong key.
class MrzFinder {
  static const _digitLike = '0-9OQDUILZSBG';
  // `.{0,2}?` skips a stray character or two that OCR picks up from the
  // card edge before the line starts.
  // The document code is `I?` on ID cards and something else (e.g. `D?`)
  // on the driving licence, so any letter is accepted. Names never contain
  // digits, so a document number needs at least 5 real digits; that keeps
  // the names line from being read as line 1.
  static final _td1Line1 = RegExp(
      '^.{0,2}?[A-Z][A-Z<][A-Z<]{3}([A-Z0-9<]{9})([$_digitLike])');
  static final _td1Line2 = RegExp('^.{0,2}?([$_digitLike]{6})([$_digitLike])'
      '([MF<])([$_digitLike]{6})([$_digitLike])[A-Z<]{3}');
  static final _td3Line2 = RegExp(
      '^.{0,2}?([A-Z0-9<]{9})([$_digitLike])[A-Z<]{3}'
      '([$_digitLike]{6})([$_digitLike])([MF<])([$_digitLike]{6})([$_digitLike])');

  // Whole lines, for the composite check digit. The optional data fields
  // are captured loosely because OCR often gets the number of `<` wrong.
  static final _td1Full1 = RegExp(
      '^.{0,2}?[A-Z][A-Z<][A-Z<]{3}([A-Z0-9<]{9})([$_digitLike])([A-Z0-9<]*)\$');
  static final _td1Full2 = RegExp('^.{0,2}?([$_digitLike]{6})([$_digitLike])'
      '[MF<]([$_digitLike]{6})([$_digitLike])[A-Z<]{3}([A-Z0-9<]*)'
      '([$_digitLike])\$');
  static final _td3Full2 = RegExp(
      '^.{0,2}?([A-Z0-9<]{9})([$_digitLike])[A-Z<]{3}([$_digitLike]{6})'
      '([$_digitLike])[MF<]([$_digitLike]{6})([$_digitLike])([A-Z0-9<]*)'
      '([$_digitLike<])([$_digitLike])\$');

  final _seenDocNumbers = <String, int>{};
  final _seenDates = <String, int>{};
  String? _docNumber;
  (DateTime, DateTime)? _dates;

  bool get hasDocumentNumber => _docNumber != null;
  bool get hasDates => _dates != null;

  MrzKey? get key => _docNumber != null && _dates != null
      ? MrzKey(_docNumber!, _dates!.$1, _dates!.$2)
      : null;

  /// Feeds the lines ML Kit recognized in one camera frame.
  void addFrame(Iterable<String> rawLines) {
    final lines = [for (final raw in rawLines) normalize(raw)];
    if (_acceptWithCompositeCheck(lines)) return;
    final docsThisFrame = <String>{};
    final datesThisFrame = <String>{};
    for (final line in lines) {
      final id1 = _td1Line1.firstMatch(line);
      if (id1 != null) {
        final doc = _checkedDocNumber(id1[1]!, _digit(id1[2]!));
        if (doc != null) docsThisFrame.add(doc);
      }
      final id2 = _td1Line2.firstMatch(line);
      if (id2 != null) {
        final dates = _checkedDates(id2[1]!, id2[2]!, id2[4]!, id2[5]!);
        if (dates != null) datesThisFrame.add(dates);
      }
      final pp = _td3Line2.firstMatch(line);
      if (pp != null) {
        final doc = _checkedDocNumber(pp[1]!, _digit(pp[2]!));
        final dates = _checkedDates(pp[3]!, pp[4]!, pp[6]!, pp[7]!);
        if (doc != null && dates != null) {
          docsThisFrame.add(doc);
          datesThisFrame.add(dates);
        }
      }
    }
    for (final d in docsThisFrame) {
      if ((_seenDocNumbers[d] = (_seenDocNumbers[d] ?? 0) + 1) >= 2) {
        _docNumber = d;
      }
    }
    for (final d in datesThisFrame) {
      if ((_seenDates[d] = (_seenDates[d] ?? 0) + 1) >= 2) {
        _dates = (
          _parseYYMMDD(d.substring(0, 6), past: true)!,
          _parseYYMMDD(d.substring(6), past: false)!,
        );
      }
    }
  }

  /// Accepts the key straight away when one frame holds a complete MRZ whose
  /// composite check digit passes.
  bool _acceptWithCompositeCheck(List<String> lines) {
    for (final line in lines) {
      final pp = _td3Full2.firstMatch(line);
      if (pp == null) continue;
      final docField = _checkedDocField(pp[1]!, _digit(pp[2]!));
      final dates = _checkedDates(pp[3]!, pp[4]!, pp[5]!, pp[6]!);
      final personal = _fixedFiller(pp[7]!, 14);
      if (docField == null || dates == null || personal == null) continue;
      final covered = '$docField${_digit(pp[2]!)}${dates.substring(0, 6)}'
          '${_digit(pp[4]!)}${dates.substring(6)}${_digit(pp[6]!)}'
          '$personal${pp[8]}';
      if (_check(covered, _digit(pp[9]!))) return _accept(docField, dates);
    }
    for (final first in lines) {
      final l1 = _td1Full1.firstMatch(first);
      if (l1 == null) continue;
      final docField = _checkedDocField(l1[1]!, _digit(l1[2]!));
      final optional1 = _fixedFiller(l1[3]!, 15);
      if (docField == null || optional1 == null) continue;
      for (final second in lines) {
        final l2 = _td1Full2.firstMatch(second);
        if (l2 == null) continue;
        final dates = _checkedDates(l2[1]!, l2[2]!, l2[3]!, l2[4]!);
        final optional2 = _fixedFiller(l2[5]!, 11);
        if (dates == null || optional2 == null) continue;
        final covered = '$docField${_digit(l1[2]!)}$optional1'
            '${dates.substring(0, 6)}${_digit(l2[2]!)}'
            '${dates.substring(6)}${_digit(l2[4]!)}$optional2';
        if (_check(covered, _digit(l2[6]!))) return _accept(docField, dates);
      }
    }
    return false;
  }

  bool _accept(String docField, String dates) {
    _docNumber = docField.replaceAll('<', '');
    _dates = (
      _parseYYMMDD(dates.substring(0, 6), past: true)!,
      _parseYYMMDD(dates.substring(6), past: false)!,
    );
    return true;
  }

  /// An optional data field of [length] characters. A field of only `<` is
  /// rebuilt at the right length, since `<` counts as zero in check digits
  /// and OCR often reads one too many or too few. A field with data must
  /// already have the right length.
  static String? _fixedFiller(String field, int length) {
    if (RegExp(r'^<*$').hasMatch(field)) return '<' * length;
    return field.length == length ? field : null;
  }

  /// The layout of an MRZ-looking line with the data hidden, for logs: every
  /// digit becomes `9` and every letter `A`, except the document code and
  /// country at the start of line 1. A line without digits (the names line)
  /// is masked completely.
  static String shapeOf(String raw) {
    final line = normalize(raw);
    String mask(String s) => s
        .replaceAll(RegExp(r'\d'), '9')
        .replaceAll(RegExp('[A-Z]'), 'A');
    if (RegExp(r'\d').allMatches(line).length < 5 || line.length <= 5) {
      return mask(line);
    }
    return line.substring(0, 5).replaceAll(RegExp(r'\d'), '9') +
        mask(line.substring(5));
  }

  /// Uppercases, drops spaces and maps the shapes OCR uses for `<`.
  static String normalize(String s) => s
      .toUpperCase()
      .replaceAll(RegExp(r'\s'), '')
      .replaceAll('«', '<<')
      .replaceAll(RegExp('[‹〈＜]'), '<');

  /// Tries the document number as read, then with letters that look like
  /// digits turned into digits (Algerian numbers are all digits).
  static String? _checkedDocNumber(String raw, String check) =>
      _checkedDocField(raw, check)?.replaceAll('<', '');

  /// Like [_checkedDocNumber] but keeps the 9-character field with its `<`.
  static String? _checkedDocField(String raw, String check) {
    if (RegExp(r'\d').allMatches(raw).length < 5) return null;
    for (final candidate in {raw, _digits(raw)}) {
      if (_check(candidate, check)) return candidate;
    }
    return null;
  }

  /// Returns birth date + expiry date as 12 digits when both pass.
  static String? _checkedDates(
      String dobRaw, String dobCheck, String doeRaw, String doeCheck) {
    final dob = _digits(dobRaw), doe = _digits(doeRaw);
    if (_check(dob, _digit(dobCheck)) &&
        _check(doe, _digit(doeCheck)) &&
        _parseYYMMDD(dob, past: true) != null &&
        _parseYYMMDD(doe, past: false) != null) {
      return '$dob$doe';
    }
    return null;
  }

  static bool _check(String value, String check) =>
      RegExp(r'^\d$').hasMatch(check) &&
      MRZ.calculateCheckDigit(value) == int.parse(check);

  static const _toDigit = {
    'O': '0', 'Q': '0', 'D': '0', 'U': '0', 'I': '1', 'L': '1', //
    'Z': '2', 'S': '5', 'B': '8', 'G': '6',
  };
  static String _digit(String c) => _toDigit[c] ?? c;
  static String _digits(String s) => s.split('').map(_digit).join();

  static DateTime? _parseYYMMDD(String s, {required bool past}) {
    final yy = int.parse(s.substring(0, 2));
    final mm = int.parse(s.substring(2, 4));
    final dd = int.parse(s.substring(4, 6));
    final nowYY = DateTime.now().year % 100;
    final year = past && yy > nowYY ? 1900 + yy : 2000 + yy;
    final date = DateTime(year, mm, dd);
    if (date.month != mm || date.day != dd) return null;
    return date;
  }
}
