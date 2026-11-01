import 'dart:convert';
import 'dart:typed_data';

import '../chip/bytes.dart';
import '../chip/chip_session.dart';
import '../document.dart';
import '../images.dart';
import '../info.dart';
import 'mrz_text.dart';
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

  /// The text files that hold [info]. On the licence the layout is still
  /// being mapped, so the details come from every text file it has.
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
            Info.mrz =>
              const [1],
            Info.nin ||
            Info.fullName ||
            Info.otherNames ||
            Info.placeOfBirth ||
            Info.address =>
              const [11],
            Info.dateOfIssue || Info.issuingAuthority => const [12],
            Info.otherDetails => const [11, 12],
            Info.licenceCategories || Info.signature || Info.photo => const [],
          },
        ChipApp.licence => switch (info) {
            Info.documentType || Info.signature || Info.photo => const [],
            Info.documentNumber ||
            Info.names ||
            Info.dateOfBirth ||
            Info.dateOfExpiry ||
            Info.dateOfIssue ||
            Info.issuingCountry ||
            Info.licenceCategories ||
            Info.mrz =>
              const [1],
            Info.sex || Info.placeOfBirth || Info.nationality => const [2],
            Info.issuingAuthority => const [1, 3],
            Info.nin ||
            Info.fullName ||
            Info.otherNames ||
            Info.address ||
            Info.otherDetails =>
              const [2, 3, 11],
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
  final dg11 = _tags(files[11]);
  final dg12 = _tags(files[12]);
  final fullBirth = _date(dg11['5F2B']);
  final other = <String, String>{
    if (w(Info.otherDetails)) ...{
      for (final MapEntry(:key, :value) in dg11.entries)
        if (!_dg11Fields.contains(key)) 'DG11/$key': printable(value),
      for (final MapEntry(:key, :value) in dg12.entries)
        if (!_dg12Fields.contains(key)) 'DG12/$key': printable(value),
    },
  };
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
        ? fullBirth ??
            (mrz == null ? null : parseYYMMDD(mrz.birth, past: true))
        : null,
    dateOfExpiry: w(Info.dateOfExpiry) && mrz != null
        ? parseYYMMDD(mrz.expiry, past: false)
        : null,
    issuingCountry: w(Info.issuingCountry) ? mrz?.issuingState : null,
    mrz: w(Info.mrz) ? mrz?.text : null,
    nin: w(Info.nin) ? _text(dg11['5F10']) : null,
    fullName: w(Info.fullName) ? _text(dg11['5F0E']) : null,
    otherNames: w(Info.otherNames) ? _text(dg11['5F0F']) : null,
    placeOfBirth: w(Info.placeOfBirth) ? _text(dg11['5F11'], ', ') : null,
    address: w(Info.address) ? _text(dg11['5F42'], ', ') : null,
    dateOfIssue: w(Info.dateOfIssue) ? _date(dg12['5F26']) : null,
    issuingAuthority: w(Info.issuingAuthority) ? _text(dg12['5F19']) : null,
    otherDetails: other,
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
  // Until the licence layout is mapped (ISO/IEC 18013-2 plus Algerian
  // fields in DG11), its values are given by file and tag.
  final other = <String, String>{
    if (want.any((i) => Files.textFor(ChipApp.licence, i).isNotEmpty))
      for (final sfi in const [1, 2, 3, 11])
        for (final (tag, value) in tlvLeafBytes(files[sfi] ?? Uint8List(0)))
          if (!_structureTags.contains(tag)) 'DG$sfi/$tag': printable(value),
  };
  return IdDocument(
    documentType:
        want.contains(Info.documentType) ? DocumentType.drivingLicence : null,
    otherDetails: other,
    photo: photo,
    signature: signature,
    security: security,
    rawFiles: raw,
    timings: timings,
  );
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

/// ICAO text: `<` separates parts. [separator] goes between them.
String? _text(Uint8List? value, [String separator = ' ']) {
  if (value == null) return null;
  final text = utf8.decode(value, allowMalformed: true);
  final parts = text.split('<').map((p) => p.trim()).where((p) => p.isNotEmpty);
  final out = parts.join(separator);
  return out.isEmpty ? null : out;
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
