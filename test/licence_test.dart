import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dz_id_reader/dz_id_reader.dart';
import 'package:dz_id_reader/src/lds/build_document.dart';
import 'package:dz_id_reader/src/testing/demo_licence.dart';
import 'package:dz_id_reader/testing.dart';

const number = 'A12345678';
final licenceKey = demoLicenceKey;
Map<int, Uint8List> licenceFiles() => demoLicenceFiles();
FakeCard licenceCard() => FakeCard.demoLicence();

void main() {
  test('every licence value gets its field', () async {
    final card = licenceCard();
    // A typed key (no document type): the ID card app is tried first.
    final typed = AccessKey(
      documentNumber: number,
      dateOfBirth: licenceKey.dateOfBirth,
      dateOfExpiry: licenceKey.dateOfExpiry,
    );
    final doc = await DocumentReader(
      transport: FakeNfc(card),
    ).read(typed, want: Info.everything);
    expect(card.log.take(2), ['SELECT other app', 'SELECT ok']);
    expect(doc.documentType, DocumentType.drivingLicence);
    expect(doc.documentNumber, number);
    expect((doc.surname, doc.givenNames), ('SPECIMEN', 'DEMO'));
    expect(doc.sex, Sex.female);
    expect(doc.nationality, 'UTO');
    expect(doc.dateOfBirth, DateTime(2000, 1, 1));
    expect(doc.dateOfIssue, DateTime(2019, 1, 15));
    expect(doc.dateOfExpiry, DateTime(2029, 1, 14));
    expect(doc.issuingCountry, 'UTO');
    expect(doc.issuingAuthority, 'DEMO AUTHORITY');
    expect(doc.placeOfBirth, 'DEMO CITY');
    expect(doc.nin, '100000000000000017');
    expect(doc.bloodGroup, 'O+');
    expect(doc.mrz!.split('\n'), hasLength(3));
    final category = doc.licenceCategories!.single;
    expect(category.code, 'B');
    expect(category.dateOfIssue, DateTime(2019, 1, 15));
    expect(category.dateOfExpiry, DateTime(2029, 1, 14));
    expect(category.conditions, isNull);
    expect(doc.surnameArabic, 'عينة');
    expect(doc.givenNamesArabic, 'تجربة');
    expect(doc.fullName, 'عينة تجربة');
    expect(doc.placeOfBirthArabic, 'بلدية الجزائر - الجزائر');
    // Not mapped (the wilaya: of issue or of birth?), by tag; the Latin
    // names that repeat DG1, the tag list and empty values left out.
    expect(doc.otherDetails, {
      'DG3/5F6A': '201901',
      'DG11/5F3A': 'الجزائر',
      'DG11/5F3E': 'ALGER',
    });
    expect(doc.photo!.format, ImageFormat.jpeg);
    expect(doc.signature!.format, ImageFormat.jpeg);
  });

  test('a scanned licence key selects the licence app first', () async {
    final card = licenceCard();
    await DocumentReader(
      transport: FakeNfc(card),
    ).read(licenceKey, want: {Info.nin});
    expect(card.log.first, 'SELECT ok');
    expect(
      card.log
          .where((l) => l.startsWith('READ'))
          .map((l) => l.split(' ')[1])
          .toSet(),
      {'DG3'},
    );
  });

  test('the self-check compares DG1 with the MRZ, showing no value', () {
    final check = licenceSelfCheck(licenceFiles())!;
    expect(
      check,
      'DG1 vs MRZ: number same, surname same, birth same, '
      'expiry same',
    );
    expect(check, isNot(contains(number)));
  });
}
