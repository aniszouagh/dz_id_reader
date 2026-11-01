import 'package:flutter_test/flutter_test.dart';

import 'package:dz_id_reader/src/scanner/mrz_finder.dart';

// ICAO 9303 part 5 TD1 specimen.
const specimen = [
  'I<UTOD231458907<<<<<<<<<<<<<<<',
  '7408122F1204159UTO<<<<<<<<<<<6',
  'ERIKSSON<<ANNA<MARIA<<<<<<<<<<',
];

// Made-up Algerian card: number 123456789, born 1990.01.01, expires 2030.01.01.
const algerian = [
  'IDDZA1234567897<<<<<<<<<<<<<<<',
  '9001011M3001019DZA<<<<<<<<<<<2',
  'NOM<<PRENOM<<<<<<<<<<<<<<<<<<<',
];

// ICAO 9303 part 4 TD3 (passport) specimen.
const passport = [
  'P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<',
  'L898902C36UTO7408122F1204159ZE184226B<<<<<10',
];

void main() {
  test('accepts the ICAO specimen in one frame (composite check)', () {
    final f = MrzFinder()..addFrame(specimen);
    expect(f.key!.documentNumber, 'D23145890');
    expect(f.key!.dateOfBirth, DateTime(1974, 8, 12));
    expect(f.key!.dateOfExpiry, DateTime(2012, 4, 15));
  });

  test('reads an Algerian-style MRZ', () {
    final f = MrzFinder()
      ..addFrame(algerian)
      ..addFrame(algerian);
    expect(f.key!.documentNumber, '123456789');
    expect(f.key!.dateOfBirth, DateTime(1990, 1, 1));
    expect(f.key!.dateOfExpiry, DateTime(2030, 1, 1));
  });

  test('fixes common OCR mistakes', () {
    const noisy = ['| IDDZA12345678 97««<<<<', '9OO1O11M3OO1O19DZA<<<'];
    final f = MrzFinder()
      ..addFrame(noisy)
      ..addFrame(noisy);
    expect(f.key!.documentNumber, '123456789');
    expect(f.key!.dateOfBirth, DateTime(1990, 1, 1));
  });

  test('rejects a wrong check digit', () {
    const bad = [
      'IDDZA1234567890<<<<<<<<<<<<<<<',
      '9001012M3001019DZA<<<<<<<<<<<0',
    ];
    final f = MrzFinder()
      ..addFrame(bad)
      ..addFrame(bad);
    expect(f.hasDocumentNumber, isFalse);
    expect(f.hasDates, isFalse);
  });

  test('ignores the names line', () {
    final f = MrzFinder()
      ..addFrame([specimen[2], algerian[2]])
      ..addFrame([specimen[2], algerian[2]]);
    expect(f.hasDocumentNumber, isFalse);
    expect(f.hasDates, isFalse);
  });

  test('reads a passport MRZ', () {
    final f = MrzFinder()
      ..addFrame(passport)
      ..addFrame(passport);
    expect(f.key!.documentNumber, 'L898902C3');
    expect(f.key!.dateOfBirth, DateTime(1974, 8, 12));
    expect(f.key!.dateOfExpiry, DateTime(2012, 4, 15));
  });

  test('reads an Algerian-style passport MRZ with OCR noise', () {
    // Number 123456789, born 1990.01.01, expires 2030.01.01.
    const noisy = ['1234567897DZA9OO1O11M3001019 <<<<<<<<<<<<<<<<'];
    final f = MrzFinder()
      ..addFrame(noisy)
      ..addFrame(noisy);
    expect(f.key!.documentNumber, '123456789');
    expect(f.key!.dateOfBirth, DateTime(1990, 1, 1));
    expect(f.key!.dateOfExpiry, DateTime(2030, 1, 1));
  });

  test('ID card lines are not read as a passport line', () {
    final f = MrzFinder()
      ..addFrame([algerian[0]])
      ..addFrame([algerian[0]]);
    expect(f.hasDates, isFalse);
  });

  test('reads line 1 when the document code is not I (driving licence)', () {
    const licence = [
      'DLDZA1234567897<<<<<<<<<<<<<<<',
      '9001011M3001019DZA<<<<<<<<<<<0',
    ];
    final f = MrzFinder()
      ..addFrame(licence)
      ..addFrame(licence);
    expect(f.key!.documentNumber, '123456789');
  });

  test('passport names line is not read as a document number', () {
    final f = MrzFinder()
      ..addFrame([passport[0]])
      ..addFrame([passport[0]]);
    expect(f.hasDocumentNumber, isFalse);
  });

  test('shapeOf hides the data', () {
    expect(MrzFinder.shapeOf(algerian[0]), 'IDDZA9999999999<<<<<<<<<<<<<<<');
    expect(MrzFinder.shapeOf(algerian[1]), '9999999A9999999AAA<<<<<<<<<<<9');
    expect(MrzFinder.shapeOf(algerian[2]), 'AAA<<AAAAAA<<<<<<<<<<<<<<<<<<<');
  });

  test('accepts a clean Algerian ID frame at once', () {
    final f = MrzFinder()..addFrame(algerian);
    expect(f.key!.documentNumber, '123456789');
    expect(f.key!.dateOfExpiry, DateTime(2030, 1, 1));
  });

  test('needs two frames when the composite check fails', () {
    final wrong = [algerian[0], algerian[1].replaceRange(29, 30, '0')];
    final f = MrzFinder()..addFrame(wrong);
    expect(f.key, isNull, reason: 'composite fails, so wait for a 2nd frame');
    f.addFrame(wrong);
    expect(f.key!.documentNumber, '123456789');
  });

  test('composite check ignores a wrong number of filler <', () {
    final f = MrzFinder()
      ..addFrame([
        'IDDZA1234567897<<<<<<<<<<<<',
        '9001011M3001019DZA<<<<<<<<<<<<<<2',
      ]);
    expect(f.key!.documentNumber, '123456789');
  });

  test('accepts the ICAO passport specimen in one frame', () {
    final f = MrzFinder()..addFrame(passport);
    expect(f.key!.documentNumber, 'L898902C3');
    expect(f.key!.dateOfExpiry, DateTime(2012, 4, 15));
  });
}
