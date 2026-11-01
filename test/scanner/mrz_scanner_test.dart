import 'package:flutter_test/flutter_test.dart';

import 'package:dz_id_reader/scanner.dart';

void main() {
  test('text lines from any OCR give the key and the document type', () {
    final scanner = MrzScanner();
    final updates = <MrzScanProgress>[];
    scanner.progress.addListener(() => updates.add(scanner.progress.value));
    final result = scanner.addTextLines([
      'I<UTOD231458907<<<<<<<<<<<<<<<',
      '7408122F1204159UTO<<<<<<<<<<<6',
      'ERIKSSON<<ANNA<MARIA<<<<<<<<<<',
    ])!;
    expect(result.key.documentNumber, 'D23145890');
    expect(result.key.dateOfBirth, DateTime(1974, 8, 12));
    expect(result.key.documentType, DocumentType.idCard);
    expect(result.frames, 1);
    expect(updates.last.documentNumber && updates.last.dates, isTrue);
  });

  test('a passport MRZ is typed as a passport', () {
    final result = MrzScanner().addTextLines([
      'P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<',
      'L898902C36UTO7408122F1204159ZE184226B<<<<<10',
    ])!;
    expect(result.key.documentType, DocumentType.passport);
  });

  test('half a document gives progress, not a key', () {
    final scanner = MrzScanner();
    expect(scanner.addTextLines(['I<UTOD231458907<<<<<<<<<<<<<<<']), isNull);
    expect(scanner.addTextLines(['I<UTOD231458907<<<<<<<<<<<<<<<']), isNull);
    expect(scanner.progress.value.documentNumber, isTrue);
    expect(scanner.progress.value.dates, isFalse);
    scanner.reset();
    expect(scanner.progress.value.documentNumber, isFalse);
  });

  test('the card area is a centred band across the whole width', () {
    final area = MrzScanner.defaultCardArea(1080, 1920);
    expect((area.left, area.right), (0, 1));
    expect(area.center.dy, closeTo(0.5, 1e-9));
    // A 0.9-wide card of ratio 85.6:54 on a 9:16 screen, plus margins.
    expect(area.height, closeTo(0.9 * 9 / 16 / (85.6 / 54) + 0.12, 1e-9));
  });
}
