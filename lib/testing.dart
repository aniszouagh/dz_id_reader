/// Reading without a card: a fake chip for tests and demos, and the
/// transport interface to plug in your own.
///
/// ```dart
/// final reader = DocumentReader(transport: FakeNfc(FakeCard.demo()));
/// final doc = await reader.read(demoKey, want: Info.everything);
/// ```
library;

export 'src/nfc/transport.dart';
export 'src/testing/demo_files.dart' show demoCountryCertificate;
export 'src/testing/demo_licence.dart' show demoLicenceKey;
export 'src/testing/fake_card.dart';
