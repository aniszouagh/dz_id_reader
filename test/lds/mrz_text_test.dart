import 'package:flutter_test/flutter_test.dart';

import 'package:dz_id_reader/src/lds/mrz_text.dart';

void main() {
  test('TD1 (ID card)', () {
    final mrz = MrzFields.parse(
      'I<UTOD231458907<<<<<<<<<<<<<<<'
      '7408122F1204159UTO<<<<<<<<<<<6'
      'ERIKSSON<<ANNA<MARIA<<<<<<<<<<',
    )!;
    expect(mrz.documentCode, 'I');
    expect(mrz.issuingState, 'UTO');
    expect(mrz.documentNumber, 'D23145890');
    expect(mrz.surname, 'ERIKSSON');
    expect(mrz.givenNames, 'ANNA MARIA');
    expect(mrz.nationality, 'UTO');
    expect((mrz.birth, mrz.sex, mrz.expiry), ('740812', 'F', '120415'));
    expect(mrz.text.split('\n'), hasLength(3));
  });

  test('TD1 with a document number longer than 9 characters', () {
    final mrz = MrzFields.parse(
      'I<UTOD23145890<7349<<<<<<<<<<<'
      '3407127M9507122UTO<<<<<<<<<<<2'
      'STEVENSON<<PETER<JOHN<<<<<<<<<',
    )!;
    expect(mrz.documentNumber, 'D23145890734');
    expect(mrz.optionalData, '');
  });

  test('TD3 (passport)', () {
    final mrz = MrzFields.parse(
      'P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<\n'
      'L898902C36UTO7408122F1204159ZE184226B<<<<<10',
    )!;
    expect(mrz.documentCode, 'P');
    expect(mrz.documentNumber, 'L898902C3');
    expect(mrz.surname, 'ERIKSSON');
    expect(mrz.givenNames, 'ANNA MARIA');
    expect((mrz.birth, mrz.sex, mrz.expiry), ('740812', 'F', '120415'));
    expect(mrz.optionalData, 'ZE184226B');
  });

  test('YYMMDD dates', () {
    final now = DateTime.now().year;
    expect(parseYYMMDD('900101', past: true), DateTime(1990, 1, 1));
    expect(parseYYMMDD('350101', past: false), DateTime(2035, 1, 1));
    expect(
      parseYYMMDD(
        '${(now % 100 + 1).toString().padLeft(2, '0')}0101',
        past: true,
      )!.year,
      now + 1 - 100,
    );
    expect(parseYYMMDD('900231', past: true), isNull);
    expect(toYYMMDD(DateTime(2035, 1, 9)), '350109');
  });
}
