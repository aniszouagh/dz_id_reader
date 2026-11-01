import 'dart:convert';
import 'dart:typed_data';

import '../chip/bytes.dart';
import '../chip/chip_session.dart';
import '../document.dart';
import '../images.dart';
import '../info.dart';
import 'mrz_text.dart';
import 'text.dart';
import 'tlv.dart';

/// Where each value lives, per chip application. File numbers are short
/// file identifiers, which equal the data group numbers.
abstract final class Files {
  static const com = 0x1E;
  static const sod = 0x1D;

  /// The file that holds the Active Authentication key.
  static int aaKey(ChipApp app) => app == ChipApp.licence ? 13 : 15;
  static int photo(ChipApp app) => app == ChipApp.licence ? 4 : 2;
  static int signature(ChipApp app) => app == ChipApp.licence ? 5 : 7;

  /// The text files that hold [info].
  static List<int> textFor(ChipApp app, Info info) => switch (app) {
    ChipApp.icao => switch (info) {
      Info.documentType ||
      Info.documentNumber ||
      Info.names ||
      Info.sex ||
      Info.nationality ||
      Info.dateOfBirth ||
      Info.dateOfExpiry ||
      Info.issuingCountry ||
      Info.mrz => const [1],
      Info.nin ||
      Info.fullName ||
      Info.namesArabic ||
      Info.otherNames ||
      Info.placeOfBirth ||
      Info.placeOfBirthArabic ||
      Info.address ||
      Info.bloodGroup => const [11],
      Info.dateOfIssue || Info.issuingAuthority => const [12],
      Info.otherDetails => const [11, 12],
      Info.licenceCategories || Info.signature || Info.photo => const [],
    },
    ChipApp.licence => switch (info) {
      Info.documentNumber ||
      Info.names ||
      Info.dateOfBirth ||
      Info.dateOfExpiry ||
      Info.dateOfIssue ||
      Info.issuingCountry ||
      Info.issuingAuthority ||
      Info.licenceCategories => const [1],
      Info.sex || Info.placeOfBirth => const [2],
      Info.nin => const [3],
      Info.mrz ||
      Info.nationality ||
      Info.bloodGroup ||
      Info.fullName ||
      Info.namesArabic ||
      Info.placeOfBirthArabic => const [11],
      Info.otherDetails => const [3, 11],
      Info.documentType ||
      Info.otherNames ||
      Info.address ||
      Info.signature ||
      Info.photo => const [],
    },
  };

  static String name(int sfi) => switch (sfi) {
    com => 'EF.COM',
    sod => 'EF.SOD',
    _ => 'DG$sfi',
  };
}

/// ICAO 9303-10 tags in DG11 and DG12 that have a field of their own.
const _dg11Fields = {'5F0E', '5F0F', '5F10', '5F2B', '5F11', '5F42'};
const _dg12Fields = {'5F19', '5F26'};

/// DG11 tags of the Algerian licence with a field of their own, or that
/// only describe the structure (5F35 lists the other tags). 5F3C and 5F3F
/// repeat the Latin names of DG1.
const _licenceDg11Fields = {
  '5F35', '5F36', '5F37', '5F38', '5F39', '5F3C', '5F3D', '5F3F', //
};

/// Tags that describe the structure (tag lists, counts), not data.
const _structureTags = {'5C', '02'};

/// Builds the result from the files read ([files] by number), keeping only
/// what [want] asks for.
IdDocument buildDocument(
  ChipApp app,
  Set<Info> want,
  Map<int, Uint8List> files, {
  SecurityResult? security,
  ReadTimings? timings,
  bool keepRawFiles = false,
}) {
  bool w(Info i) => want.contains(i);
  final raw = keepRawFiles
      ? {for (final e in files.entries) Files.name(e.key): e.value}
      : const <String, Uint8List>{};
  final photoFile = files[Files.photo(app)];
  final signatureFile = files[Files.signature(app)];
  final photo = w(Info.photo) && photoFile != null
      ? _first(findImages(photoFile))
      : null;
  final signature = w(Info.signature) && signatureFile != null
      ? _first(findImages(signatureFile))
      : null;
  if (app == ChipApp.licence) {
    return _licence(want, files, photo, signature, security, timings, raw);
  }

  final dg1 = files[1];
  final mrz = dg1 == null ? null : _mrzOf(dg1);
  final dg11 = _TextFile(files[11]);
  final dg12 = _TextFile(files[12]);
  // The Algerian ID card writes names and place of birth in Latin, then
  // Arabic (`SURNAME<لقب`), and keeps the sex and blood group where ICAO
  // puts the address (`M<ذكر<B+`).
  final surname = dg11.bilingual('5F0E');
  final given = dg11.bilingual('5F0F');
  final place = dg11.bilingual('5F11');
  final blood = _bloodGroupOf(dg11.parts('5F42'));
  final bilingualNames = surname != null || given != null;
  return IdDocument(
    documentType: w(Info.documentType) && mrz != null
        ? _typeOf(mrz.documentCode)
        : null,
    documentNumber: w(Info.documentNumber) ? mrz?.documentNumber : null,
    surname: w(Info.names) ? mrz?.surname : null,
    givenNames: w(Info.names) ? mrz?.givenNames : null,
    sex: w(Info.sex) && mrz != null ? _sex(mrz.sex) : null,
    nationality: w(Info.nationality) ? mrz?.nationality : null,
    dateOfBirth: w(Info.dateOfBirth)
        ? _date(dg11['5F2B']) ??
              (mrz == null ? null : parseYYMMDD(mrz.birth, past: true))
        : null,
    dateOfExpiry: w(Info.dateOfExpiry) && mrz != null
        ? parseYYMMDD(mrz.expiry, past: false)
        : null,
    issuingCountry: w(Info.issuingCountry) ? mrz?.issuingState : null,
    mrz: w(Info.mrz) ? mrz?.text : null,
    nin: w(Info.nin) ? dg11.text('5F10') : null,
    fullName: w(Info.fullName)
        ? (bilingualNames ? _join([surname?.$2, given?.$2]) : dg11.text('5F0E'))
        : null,
    surnameArabic: w(Info.namesArabic) ? surname?.$2 : null,
    givenNamesArabic: w(Info.namesArabic) ? given?.$2 : null,
    otherNames: w(Info.otherNames) && given == null ? dg11.text('5F0F') : null,
    placeOfBirth: w(Info.placeOfBirth)
        ? place?.$1 ?? dg11.text('5F11', ', ')
        : null,
    placeOfBirthArabic: w(Info.placeOfBirthArabic) ? place?.$2 : null,
    address: w(Info.address) && blood == null ? dg11.text('5F42', ', ') : null,
    bloodGroup: w(Info.bloodGroup) ? blood : null,
    dateOfIssue: w(Info.dateOfIssue) ? _date(dg12['5F26']) : null,
    issuingAuthority: w(Info.issuingAuthority) ? dg12.text('5F19') : null,
    otherDetails: w(Info.otherDetails)
        ? {
            ...dg11.others('DG11', _dg11Fields),
            ...dg12.others('DG12', _dg12Fields),
          }
        : const {},
    photo: photo,
    signature: signature,
    security: security,
    rawFiles: raw,
    timings: timings,
  );
}

IdDocument _licence(
  Set<Info> want,
  Map<int, Uint8List> files,
  DocumentImage? photo,
  DocumentImage? signature,
  SecurityResult? security,
  ReadTimings? timings,
  Map<String, Uint8List> raw,
) {
  bool w(Info i) => want.contains(i);
  final dg1 = files[1] == null ? null : licenceDemographics(files[1]!);
  final dg2 = _TextFile(files[2]);
  final dg3 = _TextFile(files[3]);
  final dg11 = _TextFile(files[11]);
  final mrzBytes = dg11['5F3D'];
  final mrz = mrzBytes == null
      ? null
      : MrzFields.parse(latin1.decode(mrzBytes));
  final categories = files[1] == null ? null : licenceCategories(files[1]!);
  return IdDocument(
    documentType: w(Info.documentType) ? DocumentType.drivingLicence : null,
    documentNumber: w(Info.documentNumber) ? dg1?.number : null,
    surname: w(Info.names) ? dg1?.surname : null,
    givenNames: w(Info.names) ? dg1?.givenNames : null,
    sex: w(Info.sex) ? _sex5218(dg2['5F35']) : null,
    nationality: w(Info.nationality) ? mrz?.nationality : null,
    dateOfBirth: w(Info.dateOfBirth) ? dg1?.birth : null,
    dateOfIssue: w(Info.dateOfIssue) ? dg1?.issue : null,
    dateOfExpiry: w(Info.dateOfExpiry) ? dg1?.expiry : null,
    issuingCountry: w(Info.issuingCountry) ? dg1?.country : null,
    issuingAuthority: w(Info.issuingAuthority) ? dg1?.authority : null,
    licenceCategories: w(Info.licenceCategories) ? categories : null,
    fullName: w(Info.fullName)
        ? _join([dg11.text('5F37'), dg11.text('5F38')])
        : null,
    surnameArabic: w(Info.namesArabic) ? dg11.text('5F37') : null,
    givenNamesArabic: w(Info.namesArabic) ? dg11.text('5F38') : null,
    placeOfBirth: w(Info.placeOfBirth) ? dg2.text('5F11', ', ', ';') : null,
    placeOfBirthArabic: w(Info.placeOfBirthArabic) ? dg11.text('5F39') : null,
    nin: w(Info.nin) ? dg3.text('5F68') : null,
    mrz: w(Info.mrz) ? mrz?.text : null,
    bloodGroup: w(Info.bloodGroup) ? dg11.text('5F36') : null,
    otherDetails: w(Info.otherDetails)
        ? {
            // DG1 normally parses; if its layout is ever different, show
            // it raw.
            if (files[1] != null && dg1 == null)
              for (final (tag, value) in tlvLeafBytes(files[1]!))
                if (!_structureTags.contains(tag)) 'DG1/$tag': printable(value),
            ...dg3.others('DG3', const {'5F68'}),
            ...dg11.others('DG11', _licenceDg11Fields),
          }
        : const {},
    photo: photo,
    signature: signature,
    security: security,
    rawFiles: raw,
    timings: timings,
  );
}

/// The values of one data group by tag, with the file's text encoding.
class _TextFile {
  _TextFile(Uint8List? file) : tags = _tags(file) {
    encoding = detectEncoding(tags.values);
  }

  final Map<String, Uint8List> tags;
  late final TextEncoding encoding;

  Uint8List? operator [](String tag) => tags[tag];

  /// The parts of [tag], split on [splitOn] (`<` in ICAO text), without
  /// empty ones.
  List<String> parts(String tag, [String splitOn = '<']) {
    final value = tags[tag];
    if (value == null) return const [];
    return decodeText(
      value,
      encoding,
    ).split(splitOn).map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
  }

  /// The text of [tag], its parts joined by [separator].
  String? text(String tag, [String separator = ' ', String splitOn = '<']) {
    final p = parts(tag, splitOn);
    return p.isEmpty ? null : p.join(separator);
  }

  /// A value written in Latin then Arabic: (latin, arabic). Null for
  /// other values.
  (String, String)? bilingual(String tag) {
    final p = parts(tag);
    if (p.length < 2 || hasArabic(p.first) || !hasArabic(p[1])) return null;
    return (p.first, p.sublist(1).join(' '));
  }

  /// The values without a field of their own, for `otherDetails`: text
  /// when it reads as text, hex otherwise; empty ones left out.
  Map<String, String> others(String file, Set<String> named) => {
    for (final MapEntry(:key, :value) in tags.entries)
      if (!named.contains(key)) '$file/$key': ?_display(value),
  };

  String? _display(Uint8List value) {
    final text = decodeText(value, encoding);
    if (text.runes.every((r) => r >= 0x20 && r != 0xFFFD)) {
      final clean = text
          .split('<')
          .map((p) => p.trim())
          .where((p) => p.isNotEmpty);
      return clean.isEmpty ? null : clean.join(' ');
    }
    return printable(value);
  }
}

/// On the Algerian ID card, DG11 5F42 holds `M<ذكر<B+`: the sex in Latin
/// and Arabic, then the blood group. Null when it holds something else
/// (an address, as ICAO 9303 means it).
String? _bloodGroupOf(List<String> parts) =>
    parts.length == 3 &&
        RegExp(r'^[MFX]$').hasMatch(parts[0]) &&
        RegExp(r'^(A|B|AB|O)[+-]$').hasMatch(parts[2])
    ? parts[2]
    : null;

String? _join(List<String?> parts) {
  final p = [
    for (final s in parts)
      if (s != null && s.isNotEmpty) s,
  ];
  return p.isEmpty ? null : p.join(' ');
}

/// For the logs, without any value: the text encoding of DG11 and DG12,
/// and whether DG12 5F1B (a date on the Algerian ID card) is the expiry
/// date of the MRZ.
String? icaoSelfCheck(Map<int, Uint8List> files) {
  final out = <String>[];
  for (final dg in const [11, 12]) {
    final file = files[dg];
    if (file != null) {
      out.add('DG$dg text ${detectEncoding(_tags(file).values).name}');
    }
  }
  final dg1 = files[1], dg12 = files[12];
  final mrz = dg1 == null ? null : _mrzOf(dg1);
  final date = dg12 == null ? null : _date(_tags(dg12)['5F1B']);
  if (mrz != null && date != null) {
    out.add(
      'DG12/5F1B vs MRZ expiry: '
      '${toYYMMDD(date) == mrz.expiry ? 'same' : 'DIFFERENT'}',
    );
  }
  return out.isEmpty ? null : out.join(', ');
}

/// Compares DG1 of the licence with the MRZ in its DG11, without showing
/// any value: proves on a real card that DG1 is read the right way.
String? licenceSelfCheck(Map<int, Uint8List> files) {
  final dg1 = files[1], dg11 = files[11];
  if (dg1 == null || dg11 == null) return null;
  final demo = licenceDemographics(dg1);
  final mrzBytes = _tags(dg11)['5F3D'];
  final mrz = mrzBytes == null
      ? null
      : MrzFields.parse(latin1.decode(mrzBytes));
  if (demo == null || mrz == null) {
    return 'DG1 layout ${demo == null ? 'unknown' : 'ok'}, '
        'MRZ ${mrz == null ? 'not found' : 'ok'}';
  }
  String same(bool b) => b ? 'same' : 'DIFFERENT';
  String? yymmdd(DateTime? d) => d == null ? null : toYYMMDD(d);
  return 'DG1 vs MRZ: number ${same(demo.number == mrz.documentNumber)}, '
      'surname ${same(demo.surname == mrz.surname)}, '
      'birth ${same(yymmdd(demo.birth) == mrz.birth)}, '
      'expiry ${same(yymmdd(demo.expiry) == mrz.expiry)}';
}

/// The demographic data in DG1 of the licence (tag 5F1F, ISO/IEC 18013-2):
/// surname and given names, each after its length; the dates of birth,
/// issue and expiry, 4 BCD bytes each (YYYYMMDD); the issuing country (3
/// letters); then the issuing authority and the licence number, each after
/// its length. Null when the layout does not match.
({
  String surname,
  String givenNames,
  DateTime? birth,
  DateTime? issue,
  DateTime? expiry,
  String country,
  String authority,
  String number,
})?
licenceDemographics(Uint8List dg1) {
  Uint8List? data;
  for (final (tag, value) in tlvLeafBytes(dg1)) {
    if (tag == '5F1F') data = value;
  }
  final v = data;
  if (v == null) return null;
  var i = 0;
  String? text() {
    if (i >= v.length || i + 1 + v[i] > v.length) return null;
    final n = v[i++];
    final out = utf8.decode(v.sublist(i, i + n), allowMalformed: true).trim();
    i += n;
    return out;
  }

  DateTime? date() {
    if (i + 4 > v.length) return null;
    final out = _date(v.sublist(i, i + 4));
    i += 4;
    return out;
  }

  final surname = text(), givenNames = text();
  final birth = date(), issue = date(), expiry = date();
  if (surname == null || givenNames == null || i + 3 > v.length) return null;
  final country = latin1.decode(v.sublist(i, i + 3));
  i += 3;
  final authority = text(), number = text();
  if (authority == null || number == null) return null;
  return (
    surname: surname,
    givenNames: givenNames,
    birth: birth,
    issue: issue,
    expiry: expiry,
    country: country,
    authority: authority,
    number: number,
  );
}

/// The categories in DG1 of the licence: one tag 87 each, holding
/// `code;issue;expiry;code;sign;value` with the dates as 4 BCD bytes.
List<LicenceCategory> licenceCategories(Uint8List dg1) => [
  for (final (tag, value) in tlvLeafBytes(dg1))
    if (tag == '87') _category(value),
];

LicenceCategory _category(Uint8List value) {
  // BCD bytes never contain 0x3B (`;`), so splitting on it is safe.
  final parts = <Uint8List>[];
  var start = 0;
  for (var i = 0; i <= value.length; i++) {
    if (i == value.length || value[i] == 0x3B) {
      parts.add(Uint8List.sublistView(value, start, i));
      start = i + 1;
    }
  }
  String part(int i) => i < parts.length ? latin1.decode(parts[i]).trim() : '';
  final conditions = [
    for (var i = 3; i < parts.length; i++) part(i),
  ].where((p) => p.isNotEmpty).join(' ');
  return LicenceCategory(
    part(0),
    dateOfIssue: parts.length > 1 ? _date(parts[1]) : null,
    dateOfExpiry: parts.length > 2 ? _date(parts[2]) : null,
    conditions: conditions.isEmpty ? null : conditions,
  );
}

/// ISO/IEC 5218: 1 male, 2 female.
Sex? _sex5218(Uint8List? value) {
  if (value == null || value.isEmpty) return null;
  final code = value.length == 1
      ? value[0]
      : int.tryParse(latin1.decode(value));
  return switch (code) {
    1 => Sex.male,
    2 => Sex.female,
    _ => Sex.unspecified,
  };
}

DocumentImage? _first(List<DocumentImage> images) =>
    images.isEmpty ? null : images.first;

MrzFields? _mrzOf(Uint8List dg1) {
  for (final (tag, value) in tlvLeafBytes(dg1)) {
    if (tag == '5F1F') return MrzFields.parse(latin1.decode(value));
  }
  return null;
}

/// The leaves of a data group by tag. A tag found more than once (other
/// names) keeps all values, joined by `<<` like name parts.
Map<String, Uint8List> _tags(Uint8List? file) {
  final out = <String, Uint8List>{};
  if (file == null) return out;
  for (final (tag, value) in tlvLeafBytes(file)) {
    if (_structureTags.contains(tag)) continue;
    final before = out[tag];
    out[tag] = before == null ? value : concat([before, '<<'.codeUnits, value]);
  }
  return out;
}

/// YYYYMMDD as 8 ASCII digits, or as 4 BCD bytes.
DateTime? _date(Uint8List? value) {
  if (value == null) return null;
  String digits;
  if (value.length == 4) {
    digits = toHex(value);
  } else {
    digits = latin1.decode(value).replaceAll(RegExp(r'\D'), '');
  }
  if (digits.length != 8) return null;
  final y = int.parse(digits.substring(0, 4));
  final m = int.parse(digits.substring(4, 6));
  final d = int.parse(digits.substring(6, 8));
  final date = DateTime(y, m, d);
  return date.month == m && date.day == d ? date : null;
}

DocumentType _typeOf(String code) => switch (code.isEmpty ? '' : code[0]) {
  'P' => DocumentType.passport,
  'I' || 'A' || 'C' => DocumentType.idCard,
  _ => DocumentType.other,
};

Sex _sex(String s) => switch (s) {
  'M' => Sex.male,
  'F' => Sex.female,
  _ => Sex.unspecified,
};
