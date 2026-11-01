/// Reads Algerian ID cards, passports and driving licences over NFC.
///
/// No screens: [DocumentReader] reads what you ask for and returns an
/// [IdDocument]; your app draws its own pages. The MRZ scanner that gets
/// the [AccessKey] from the camera is in `scanner.dart`.
library;

export 'src/access_key.dart';
export 'src/document.dart';
export 'src/errors.dart';
export 'src/images.dart' show DocumentImage, ImageFormat;
export 'src/info.dart';
export 'src/nfc/transport.dart' show NfcState;
export 'src/progress.dart';
export 'src/reader.dart';
