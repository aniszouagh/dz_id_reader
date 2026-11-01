import 'dart:typed_data';

/// What the phone's NFC can do right now.
enum NfcState {
  /// The phone has no NFC.
  notSupported,

  /// NFC is turned off in the phone's settings.
  off,

  /// Ready to read.
  on,
}

/// The way to the card: Android's NFC on a phone, a fake card in tests.
abstract interface class NfcTransport {
  Future<NfcState> state();

  Future<void> openSettings();

  /// While on, cards that touch the phone between reads are ignored, so
  /// Android does not show its own "cannot read this tag" message.
  Future<void> hold(bool on);

  /// Waits up to [timeout] for a card and connects to it. Throws
  /// [NoCardException] on timeout and [ConnectCancelledException] after
  /// [cancel].
  Future<CardLink> connect(
      {required Duration timeout, required Duration commandTimeout});

  /// Ends a pending [connect].
  Future<void> cancel();
}

/// A connected card.
abstract interface class CardLink {
  /// Whether the phone can send extended-length commands (more than 256
  /// bytes back in one answer).
  bool get extendedLength;

  /// Sends one command and returns the raw answer. Throws
  /// [CardLostException] when the card is gone or stops answering.
  Future<Uint8List> transceive(Uint8List command);

  Future<void> close();
}

/// No card came within the time given to [NfcTransport.connect].
class NoCardException implements Exception {
  const NoCardException();
}

/// [NfcTransport.cancel] ended the wait.
class ConnectCancelledException implements Exception {
  const ConnectCancelledException();
}

/// NFC is off or missing.
class NfcUnavailableException implements Exception {
  const NfcUnavailableException(this.state);
  final NfcState state;
}

/// The card left the phone, or stopped answering, during a command.
/// [lost] is true when Android saw the card go; false for other I/O errors
/// (a command the chip or phone could not handle, a timeout).
class CardLostException implements Exception {
  const CardLostException({required this.lost, this.detail});
  final bool lost;
  final String? detail;

  @override
  String toString() => lost ? 'Card lost' : 'Card I/O error ($detail)';
}
