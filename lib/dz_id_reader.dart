/// Reads Algerian ID cards, passports and driving licences over NFC.
///
/// For now this exports the code moved from the dz_id_nfc test app as it
/// was. The public API (key, request, result, errors) replaces it next.
library;

export 'src/chip.dart';
export 'src/der.dart';
export 'src/images.dart';
export 'src/licence.dart';
export 'src/mrz.dart';
export 'src/nv21.dart';
export 'src/security.dart';
