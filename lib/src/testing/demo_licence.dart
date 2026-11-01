import 'dart:convert';
import 'dart:typed_data';

import '../access_key.dart';
import '../chip/bytes.dart';
import '../document.dart';
import '../lds/mrz_text.dart';
import 'demo_files.dart';

const _number = 'A12345678';

/// The key of the demo licence (see `FakeCard.demoLicence`).
final demoLicenceKey = AccessKey(
  documentNumber: _number,
  dateOfBirth: DateTime(2000, 1, 1),
  dateOfExpiry: DateTime(2029, 1, 14),
  documentType: DocumentType.drivingLicence,
);

/// A made-up driving licence with the layout of the Algerian one: DG1
/// demographic data and categories, DG2 sex and place of birth, DG3 the
/// NIN, DG11 blood group, names and place of birth in Arabic, a wilaya in
/// Arabic and Latin, and the MRZ, DG4 photo, DG5 signature. No EF.SOD and
/// no Active Authentication key.
Map<int, Uint8List> demoLicenceFiles() {
  final line1 = 'DLUTO$_number${checkDigit(_number)}'.padRight(30, '<');
  var line2 = '000101${checkDigit('000101')}F290114${checkDigit('290114')}UTO'
      .padRight(29, '<');
  line2 +=
      '${checkDigit(line1.substring(5) + line2.substring(0, 7) + line2.substring(8, 15) + line2.substring(18, 29))}';
  final line3 = 'SPECIMEN<<DEMO'.padRight(30, '<');
  return {
    1: _tlv(
      [0x61],
      [
        ..._tlv(
          [0x5F, 0x1F],
          [
            ..._lengthPrefixed('SPECIMEN'),
            ..._lengthPrefixed('DEMO'),
            ...hexToBytes('20000101'),
            ...hexToBytes('20190115'),
            ...hexToBytes('20290114'),
            ...'UTO'.codeUnits,
            ..._lengthPrefixed('DEMO AUTHORITY'),
            ..._lengthPrefixed(_number),
          ],
        ),
        ..._tlv(
          [0x7F, 0x63],
          [
            ..._tlv([0x02], [1]),
            ..._tlv(
              [0x87],
              [
                ...'B;'.codeUnits,
                ...hexToBytes('20190115'),
                0x3B,
                ...hexToBytes('20290114'),
                ...';;;'.codeUnits,
              ],
            ),
          ],
        ),
      ],
    ),
    2: _tlv(
      [0x6B],
      [
        ..._tlv([0x5C], [0x5F, 0x35, 0x5F, 0x11]),
        ..._tlv([0x5F, 0x35], [2]),
        ..._tlv([0x5F, 0x11], 'DEMO CITY;;'.codeUnits),
      ],
    ),
    3: _tlv(
      [0x6C],
      [
        ..._tlv([0x5C], [0x5F, 0x68, 0x5F, 0x6A]),
        ..._tlv([0x5F, 0x68], '100000000000000017'.codeUnits),
        ..._tlv([0x5F, 0x6A], [0x20, 0x19, 0x01]),
      ],
    ),
    11: _tlv(
      [0x6D],
      [
        ..._tlv([0x02], [10]),
        ..._tlv(
          [0x5F, 0x35],
          [
            for (var t = 0x36; t <= 0x3F; t++) ...[0x5F, t],
          ],
        ),
        ..._tlv([0x5F, 0x36], 'O+'.codeUnits),
        ..._tlv([0x5F, 0x37], utf8.encode('عينة')),
        ..._tlv([0x5F, 0x38], utf8.encode('تجربة')),
        ..._tlv([0x5F, 0x39], utf8.encode('بلدية الجزائر - الجزائر')),
        ..._tlv([0x5F, 0x3A], utf8.encode('الجزائر')),
        ..._tlv([0x5F, 0x3B], const []),
        ..._tlv([0x5F, 0x3C], 'SPECIMEN'.codeUnits),
        ..._tlv([0x5F, 0x3D], (line1 + line2 + line3).codeUnits),
        ..._tlv([0x5F, 0x3E], 'ALGER'.codeUnits),
        ..._tlv([0x5F, 0x3F], 'DEMO'.codeUnits),
      ],
    ),
    4: _tlv([0x65], _tlv([0x5F, 0x40], _jpegIn(demoFiles[2]!))),
    5: _tlv([0x67], _tlv([0x5F, 0x43], _jpegIn(demoFiles[7]!))),
  };
}

Uint8List _tlv(List<int> tag, List<int> value) {
  final n = value.length;
  return Uint8List.fromList([
    ...tag,
    if (n < 0x80)
      n
    else if (n < 0x100) ...[
      0x81,
      n,
    ] else ...[
      0x82,
      n >> 8,
      n & 0xFF,
    ],
    ...value,
  ]);
}

/// A value after its length, as in DG1 of the licence.
List<int> _lengthPrefixed(String s) => [
  utf8.encode(s).length,
  ...utf8.encode(s),
];

/// The JPEG inside a demo card file.
List<int> _jpegIn(Uint8List file) {
  for (var i = 0; i + 2 < file.length; i++) {
    if (file[i] == 0xFF && file[i + 1] == 0xD8 && file[i + 2] == 0xFF) {
      return file.sublist(i);
    }
  }
  throw StateError('No JPEG');
}
