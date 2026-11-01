import 'dart:typed_data';

import 'images.dart';

/// The kind of document.
enum DocumentType { idCard, passport, drivingLicence, other }

enum Sex { male, female, unspecified }

/// What a read returned. A value is null when it was not asked for, or when
/// this document does not have it.
class IdDocument {
  const IdDocument({
    this.documentType,
    this.documentNumber,
    this.surname,
    this.givenNames,
    this.sex,
    this.nationality,
    this.dateOfBirth,
    this.dateOfExpiry,
    this.issuingCountry,
    this.mrz,
    this.nin,
    this.fullName,
    this.surnameArabic,
    this.givenNamesArabic,
    this.otherNames,
    this.placeOfBirth,
    this.placeOfBirthArabic,
    this.address,
    this.dateOfIssue,
    this.issuingAuthority,
    this.licenceCategories,
    this.bloodGroup,
    this.otherDetails = const {},
    this.signature,
    this.photo,
    this.security,
    this.rawFiles = const {},
    this.timings,
  });

  final DocumentType? documentType;
  final String? documentNumber;
  final String? surname;
  final String? givenNames;
  final Sex? sex;

  /// Three-letter code, like DZA.
  final String? nationality;
  final DateTime? dateOfBirth;
  final DateTime? dateOfExpiry;

  /// Three-letter code of the issuing state.
  final String? issuingCountry;

  /// The MRZ lines, separated by line breaks.
  final String? mrz;

  /// National identification number.
  final String? nin;

  /// Full name in national characters: in Arabic on Algerian documents
  /// (surname, then given names).
  final String? fullName;
  final String? surnameArabic;
  final String? givenNamesArabic;
  final String? otherNames;
  final String? placeOfBirth;
  final String? placeOfBirthArabic;
  final String? address;
  final DateTime? dateOfIssue;
  final String? issuingAuthority;

  /// Vehicle categories of a driving licence.
  final List<LicenceCategory>? licenceCategories;

  /// On the driving licence, like `A+`.
  final String? bloodGroup;

  /// Values without a field of their own, keyed by file and tag, like
  /// `DG11/5F16`. Text when printable, hex otherwise.
  final Map<String, String> otherDetails;
  final DocumentImage? signature;
  final DocumentImage? photo;

  /// The checks asked for; null when none were.
  final SecurityResult? security;

  /// The chip files as read, by name (`DG1`, `EF.SOD`…), only when the
  /// read was asked to keep them.
  final Map<String, Uint8List> rawFiles;

  /// How long each part took. Null in the partial documents sent with
  /// progress.
  final ReadTimings? timings;

  /// Never prints the values: they are personal data.
  @override
  String toString() => 'IdDocument(…)';
}

/// A vehicle category of a driving licence (ISO/IEC 18013-2).
class LicenceCategory {
  const LicenceCategory(
    this.code, {
    this.dateOfIssue,
    this.dateOfExpiry,
    this.conditions,
  });

  /// Like `B`, `C1` or `D`.
  final String code;
  final DateTime? dateOfIssue;
  final DateTime? dateOfExpiry;

  /// Restriction codes, when the category has any.
  final String? conditions;
}

/// The result of a check.
enum CheckStatus {
  passed,
  failed,

  /// The document cannot do this check (no Active Authentication key, an
  /// unknown signature algorithm…).
  notSupported,

  /// Not asked for, or nothing to check against (see
  /// [SecurityResult.countryCertificate]).
  notChecked,
}

/// The X.509 certificate of the document signer: who signed the data.
class CertificateInfo {
  const CertificateInfo({
    required this.subject,
    required this.issuer,
    required this.serialNumber,
    required this.validFrom,
    required this.validTo,
    required this.keyDescription,
  });

  final String subject;
  final String issuer;
  final String serialNumber;
  final DateTime validFrom;
  final DateTime validTo;

  /// Like `RSA 2048-bit` or `ECDSA 256-bit`.
  final String keyDescription;
}

/// What the security checks found.
class SecurityResult {
  const SecurityResult({
    this.chipGenuine = CheckStatus.notChecked,
    this.dataUnchanged = CheckStatus.notChecked,
    this.issuerSignature = CheckStatus.notChecked,
    this.countryCertificate = CheckStatus.notChecked,
    this.documentSigner,
    this.changedFiles = const [],
    this.chipKey,
  });

  /// [Check.chipGenuine]: the chip signed a random challenge with its
  /// private key, so it is not a copy.
  final CheckStatus chipGenuine;

  /// [Check.dataAuthentic], part 1: every file read matches the hash the
  /// issuer signed.
  final CheckStatus dataUnchanged;

  /// [Check.dataAuthentic], part 2: the document signer's signature over
  /// those hashes is valid.
  final CheckStatus issuerSignature;

  /// [Check.dataAuthentic], part 3: the document signer's certificate is
  /// signed by one of the country certificates (CSCA) given to the
  /// reader. [CheckStatus.notChecked] when none were given.
  final CheckStatus countryCertificate;

  final CertificateInfo? documentSigner;

  /// Files whose hash does not match, like `DG2`.
  final List<String> changedFiles;

  /// The chip's Active Authentication key, like `RSA 1024-bit`.
  final String? chipKey;
}

/// Where the time went in a read.
class ReadTimings {
  const ReadTimings({
    required this.waiting,
    required this.onCard,
    required this.unlock,
    required this.files,
    required this.activeAuthentication,
    required this.checks,
    required this.attempts,
    required this.commands,
    required this.bigReads,
  });

  /// From the read call until the card touched the phone (last try).
  final Duration waiting;

  /// From the card touching the phone until reading ended (last try): how
  /// long the card had to stay still.
  final Duration onCard;

  /// Selecting the application and unlocking the chip (last try).
  final Duration unlock;

  /// Reading time of each file, by name.
  final Map<String, Duration> files;
  final Duration? activeAuthentication;

  /// Checking signatures on the phone, after the card left.
  final Duration checks;

  /// 1, or more when the card moved and came back.
  final int attempts;

  /// Commands sent to the chip (last try).
  final int commands;

  /// Whether big files were read with extended-length commands.
  final bool bigReads;
}
