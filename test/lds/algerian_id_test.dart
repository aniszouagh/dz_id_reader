import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dz_id_reader/dz_id_reader.dart';
import 'package:dz_id_reader/src/chip/chip_session.dart';
import 'package:dz_id_reader/src/lds/build_document.dart';
import 'package:dz_id_reader/src/lds/code_pages.dart';

Uint8List tlv(List<int> tag, List<int> value) => Uint8List.fromList([
  ...tag,
  if (value.length < 0x80) value.length else ...[0x81, value.length],
  ...value,
]);

List<int> encode(String text, List<int> table) {
  final reverse = {for (var i = 0; i < 128; i++) table[i]: 0x80 + i};
  return [for (final c in text.runes) c < 0x80 ? c : reverse[c]!];
}

/// DG11 laid out like the Algerian ID card's, with made-up values: Latin
/// then Arabic, the sex and blood group in 5F42, an empty 5F16.
Uint8List dg11(List<int> table) => tlv(
  [0x6B],
  [
    ...tlv(
      [0x5C],
      [0x5F, 0x0E, 0x5F, 0x0F, 0x5F, 0x10, 0x5F, 0x11, 0x5F, 0x42, 0x5F, 0x16],
    ),
    ...tlv([0x5F, 0x0E], encode('SPECIMEN<عينة', table)),
    ...tlv([0x5F, 0x0F], encode('DEMO<تجربة', table)),
    ...tlv([0x5F, 0x10], '100000000000000017'.codeUnits),
    ...tlv([0x5F, 0x2B], '19900101'.codeUnits),
    ...tlv([0x5F, 0x11], encode('ALGER<الجزائر', table)),
    ...tlv([0x5F, 0x42], encode('F<أنثى<O+', table)),
    ...tlv([0x5F, 0x16], '<<'.codeUnits),
  ],
);

void main() {
  for (final (name, table) in [
    ('ISO-8859-6', iso88596),
    ('Windows-1256', cp1256),
  ]) {
    test('Algerian ID card layout, Arabic in $name', () {
      final doc = buildDocument(ChipApp.icao, Info.everything, {
        11: dg11(table),
      });
      expect(doc.surnameArabic, 'عينة');
      expect(doc.givenNamesArabic, 'تجربة');
      expect(doc.fullName, 'عينة تجربة');
      expect(doc.otherNames, isNull); // 5F0F holds the given names here
      expect(doc.placeOfBirth, 'ALGER');
      expect(doc.placeOfBirthArabic, 'الجزائر');
      expect(doc.bloodGroup, 'O+');
      expect(doc.address, isNull); // 5F42 holds sex and blood group here
      expect(doc.nin, '100000000000000017');
      expect(doc.dateOfBirth, DateTime(1990, 1, 1));
      expect(doc.otherDetails, isEmpty); // 5F16 "<<" is empty
    });

    test('Algerian ID card DG12, Arabic in $name', () {
      final dg12 = tlv(
        [0x6C],
        [
          ...tlv([0x5F, 0x19], encode('DEMO AUTHORITY<سلطة تجريبية', table)),
          ...tlv([0x5F, 0x26], '20250101'.codeUnits),
          ...tlv([0x5F, 0x1B], '20350101'.codeUnits),
        ],
      );
      final doc = buildDocument(ChipApp.icao, Info.everything, {12: dg12});
      expect(doc.issuingAuthority, 'DEMO AUTHORITY');
      expect(doc.issuingAuthorityArabic, 'سلطة تجريبية');
      expect(doc.dateOfIssue, DateTime(2025, 1, 1));
      expect(doc.otherDetails, isEmpty); // 5F1B: the expiry date in full
    });
  }

  test('ICAO layout (a full name and an address) is read as ICAO', () {
    final file = tlv(
      [0x6B],
      [
        ...tlv([0x5F, 0x0E], 'SPECIMEN<<DEMO'.codeUnits),
        ...tlv([0x5F, 0x11], 'DEMO CITY<UTOPIA'.codeUnits),
        ...tlv([0x5F, 0x42], '1 DEMO STREET<DEMO CITY'.codeUnits),
      ],
    );
    final doc = buildDocument(ChipApp.icao, Info.everything, {11: file});
    expect(doc.fullName, 'SPECIMEN DEMO');
    expect(doc.surnameArabic, isNull);
    expect(doc.placeOfBirth, 'DEMO CITY, UTOPIA');
    expect(doc.address, '1 DEMO STREET, DEMO CITY');
    expect(doc.bloodGroup, isNull);
  });
}
