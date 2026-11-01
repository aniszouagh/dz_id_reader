import 'document.dart';

/// The three printed values that unlock a document's chip: the document
/// number, the date of birth and the date of expiry. Typed by the user, or
/// read from the MRZ by `MrzScanner`.
class AccessKey {
  /// Spaces and `<` in [documentNumber] are dropped and letters made
  /// upper case. Throws [ArgumentError] when anything but letters and
  /// digits is left.
  AccessKey({
    required String documentNumber,
    required this.dateOfBirth,
    required this.dateOfExpiry,
    this.documentType,
  }) : documentNumber = normalize(documentNumber) {
    if (!RegExp(r'^[A-Z0-9]{1,22}$').hasMatch(this.documentNumber)) {
      throw ArgumentError.value(
        documentNumber,
        'documentNumber',
        'letters and digits only',
      );
    }
  }

  final String documentNumber;
  final DateTime dateOfBirth;
  final DateTime dateOfExpiry;

  /// Which document this key is for, when known (the scanner tells). The
  /// reader then asks the chip for the right application first.
  final DocumentType? documentType;

  /// [documentNumber] as the key uses it.
  static String normalize(String documentNumber) =>
      documentNumber.toUpperCase().replaceAll(RegExp(r'[\s<]'), '');

  @override
  bool operator ==(Object other) =>
      other is AccessKey &&
      other.documentNumber == documentNumber &&
      _sameDay(other.dateOfBirth, dateOfBirth) &&
      _sameDay(other.dateOfExpiry, dateOfExpiry);

  @override
  int get hashCode => Object.hash(
    documentNumber,
    dateOfBirth.year,
    dateOfBirth.month,
    dateOfBirth.day,
    dateOfExpiry.year,
    dateOfExpiry.month,
    dateOfExpiry.day,
  );

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Never prints the values: they are personal data.
  @override
  String toString() => 'AccessKey(…)';
}
