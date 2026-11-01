/// The machine readable zone printed on documents and stored in DG1
/// (ICAO 9303 parts 4 to 6).
library;

/// ICAO 9303 check digit: weights 7, 3, 1 over digits (their value),
/// letters (A=10 … Z=35) and `<` (0).
int checkDigit(String value) {
  const weights = [7, 3, 1];
  var sum = 0;
  for (var i = 0; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    final v = c >= 0x30 && c <= 0x39
        ? c - 0x30
        : c >= 0x41 && c <= 0x5A
        ? c - 0x41 + 10
        : 0;
    sum += v * weights[i % 3];
  }
  return sum % 10;
}

/// The fields of a complete MRZ: TD1 (ID cards, 3 × 30), TD2 (2 × 36) or
/// TD3 (passports, 2 × 44).
class MrzFields {
  MrzFields._({
    required this.text,
    required this.documentCode,
    required this.issuingState,
    required this.documentNumber,
    required this.surname,
    required this.givenNames,
    required this.nationality,
    required this.birth,
    required this.sex,
    required this.expiry,
    required this.optionalData,
  });

  /// [mrz] is the MRZ with or without line breaks. Null when its length
  /// matches no format.
  static MrzFields? parse(String mrz) {
    final s = mrz.replaceAll(RegExp(r'\s'), '');
    String at(int start, int end) => s.substring(start, end);
    switch (s.length) {
      case 90: // TD1
        var number = at(5, 14);
        var optional1 = at(15, 30);
        if (at(14, 15) == '<' && optional1.startsWith(RegExp('[A-Z0-9]'))) {
          // Long number: it goes on in the optional data, ending with its
          // check digit before the first `<`.
          final rest = optional1.split('<').first;
          number += rest.substring(0, rest.length - 1);
          optional1 = optional1.substring(rest.length);
        }
        final (surname, given) = _names(at(60, 90));
        return MrzFields._(
          text: '${at(0, 30)}\n${at(30, 60)}\n${at(60, 90)}',
          documentCode: _clean(at(0, 2)),
          issuingState: _clean(at(2, 5)),
          documentNumber: _clean(number),
          surname: surname,
          givenNames: given,
          nationality: _clean(at(45, 48)),
          birth: at(30, 36),
          sex: at(37, 38),
          expiry: at(38, 44),
          optionalData: [
            _clean(optional1),
            _clean(at(48, 59)),
          ].where((o) => o.isNotEmpty).join(' '),
        );
      case 72 || 88: // TD2, TD3
        final width = s.length ~/ 2;
        final (surname, given) = _names(at(5, width));
        final line2 = s.substring(width);
        return MrzFields._(
          text: '${at(0, width)}\n$line2',
          documentCode: _clean(at(0, 2)),
          issuingState: _clean(at(2, 5)),
          documentNumber: _clean(line2.substring(0, 9)),
          surname: surname,
          givenNames: given,
          nationality: _clean(line2.substring(10, 13)),
          birth: line2.substring(13, 19),
          sex: line2.substring(20, 21),
          expiry: line2.substring(21, 27),
          optionalData: _clean(line2.substring(28, width == 44 ? 42 : 35)),
        );
    }
    return null;
  }

  final String text;
  final String documentCode;
  final String issuingState;
  final String documentNumber;
  final String surname;
  final String givenNames;
  final String nationality;

  /// YYMMDD as printed.
  final String birth;
  final String sex;
  final String expiry;
  final String optionalData;

  static (String, String) _names(String field) {
    final parts = field.split('<<');
    final surname = _clean(parts.first);
    final given = _clean(parts.skip(1).join(' '));
    return (surname, given);
  }

  static String _clean(String s) =>
      s.replaceAll('<', ' ').replaceAll(RegExp(' +'), ' ').trim();
}

/// A YYMMDD date. Birth dates are in the past; for other dates the year is
/// taken in this century unless that puts it more than 50 years ahead.
DateTime? parseYYMMDD(String s, {required bool past}) {
  if (!RegExp(r'^\d{6}$').hasMatch(s)) return null;
  final yy = int.parse(s.substring(0, 2));
  final mm = int.parse(s.substring(2, 4));
  final dd = int.parse(s.substring(4, 6));
  final now = DateTime.now().year;
  var year = 2000 + yy;
  if (past ? year > now : year > now + 50) year -= 100;
  final date = DateTime(year, mm, dd);
  return date.month == mm && date.day == dd ? date : null;
}

/// YYMMDD for [date].
String toYYMMDD(DateTime date) =>
    '${(date.year % 100).toString().padLeft(2, '0')}'
    '${date.month.toString().padLeft(2, '0')}'
    '${date.day.toString().padLeft(2, '0')}';
