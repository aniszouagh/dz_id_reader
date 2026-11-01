/// What a read can return. The reader reads only the chip files that hold
/// what you ask for, and returns only what you asked for.
///
/// On ID cards and passports (ICAO 9303) the values come from these files:
/// - DG1 (fast, about 0.1 s): [documentType] to [mrz];
/// - DG11 (fast): [nin], [fullName], [otherNames], [placeOfBirth],
///   [address];
/// - DG12 (fast): [dateOfIssue], [issuingAuthority];
/// - DG7 (about 1.5 s): [signature];
/// - DG2 (about 4 s): [photo].
///
/// On the driving licence (ISO/IEC 18013): DG1 for the names, dates,
/// issuing country and authority, number and categories; DG2 for sex and
/// place of birth; DG3 for the NIN; DG11 for the MRZ, nationality and
/// blood group; DG5 the signature; DG4 the photo.
///
/// [otherDetails] gives the values of those files that have no field of
/// their own, by tag.
enum Info {
  documentType,
  documentNumber,

  /// Surname and given names, as in the MRZ (Latin letters).
  names,
  sex,
  nationality,
  dateOfBirth,
  dateOfExpiry,
  issuingCountry,

  /// The MRZ text itself.
  mrz,

  /// The national identification number (NIN).
  nin,

  /// The full name in national characters.
  fullName,
  otherNames,
  placeOfBirth,
  address,
  dateOfIssue,
  issuingAuthority,

  /// Driving licence categories (B, C…).
  licenceCategories,

  /// On the driving licence.
  bloodGroup,

  /// Values with no field of their own, by file and tag.
  otherDetails,
  signature,
  photo;

  /// What the MRZ holds (DG1 alone): fast.
  static const Set<Info> mrzData = {
    documentType,
    documentNumber,
    names,
    sex,
    nationality,
    dateOfBirth,
    dateOfExpiry,
    issuingCountry,
  };

  /// The extra personal details (DG11).
  static const Set<Info> personalDetails = {
    nin,
    fullName,
    otherNames,
    placeOfBirth,
    address,
  };

  /// Details about the document itself (DG12).
  static const Set<Info> documentDetails = {dateOfIssue, issuingAuthority};

  /// Everything except the pictures: still fast.
  static const Set<Info> allText = {
    ...mrzData,
    mrz,
    ...personalDetails,
    ...documentDetails,
    licenceCategories,
    bloodGroup,
    otherDetails,
  };

  /// Everything the chip lets us read.
  static const Set<Info> everything = {...allText, signature, photo};
}

/// Security checks a read can do.
enum Check {
  /// The chip proves it is the original and not a copy: it signs a random
  /// challenge with a private key that cannot be read out of it (Active
  /// Authentication, needs DG15). About 0.2 s.
  chipGenuine,

  /// The values read are exactly what the issuer signed (passive
  /// authentication): their hashes match the signed list in EF.SOD, and
  /// the signature is valid. About 0.4 s, plus checking on the phone.
  dataAuthentic,
}
