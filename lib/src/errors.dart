/// Why a read failed. The reader never shows text to the user: catch these
/// and show your own message, in your own language.
sealed class ReadException implements Exception {
  const ReadException();
}

/// This phone has no NFC.
final class NfcNotSupported extends ReadException {
  const NfcNotSupported();

  @override
  String toString() => 'NfcNotSupported';
}

/// NFC is turned off. `DocumentReader.openNfcSettings` opens the setting.
final class NfcOff extends ReadException {
  const NfcOff();

  @override
  String toString() => 'NfcOff';
}

/// No card touched the phone in time.
final class NoCardFound extends ReadException {
  const NoCardFound();

  @override
  String toString() => 'NoCardFound';
}

/// The card left the phone and did not come back in time.
final class CardMoved extends ReadException {
  const CardMoved();

  @override
  String toString() => 'CardMoved';
}

/// The three values do not unlock this chip: one of them is wrong, or this
/// is another document.
final class WrongKey extends ReadException {
  const WrongKey();

  @override
  String toString() => 'WrongKey';
}

/// The chip is not an ID card, passport or driving licence chip.
final class UnsupportedDocument extends ReadException {
  const UnsupportedDocument();

  @override
  String toString() => 'UnsupportedDocument';
}

/// `DocumentReader.cancel` stopped the read.
final class ReadCancelled extends ReadException {
  const ReadCancelled();

  @override
  String toString() => 'ReadCancelled';
}

/// The chip answered with an error the reader cannot get past.
final class ChipError extends ReadException {
  const ChipError(this.statusWord, this.during);

  /// ISO 7816 status word, like 0x6A82.
  final int statusWord;

  /// The step that failed, for logs (English, not for users).
  final String during;

  @override
  String toString() =>
      'ChipError(${statusWord.toRadixString(16).toUpperCase()}, $during)';
}
