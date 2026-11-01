import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dz_id_reader/src/document.dart';
import 'package:dz_id_reader/src/images.dart';
import 'package:dz_id_reader/src/security.dart';

Uint8List fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

/// Shaped like a page's method: another closure in it captures `this` (as
/// setState callbacks do), so the scope's shared context holds the object
/// and its unsendable Completer. An inline Isolate.run closure here failed
/// on the phone with "object is unsendable".
class _PageLike {
  final pending = Completer<void>();
  SecurityResult? result;

  Future<void> afterRead(Uint8List sod, Map<int, Uint8List> files) async {
    void setStateLike(void Function() f) => f();
    setStateLike(() => result = null);
    result = await verifyInBackground((
      checkChip: false,
      checkData: true,
      aaKeyFile: null,
      aaChallenge: null,
      aaSignature: null,
      sod: sod,
      files: files,
      trusted: const [],
    ));
  }
}

void main() {
  test('checks run on an isolate when called from a page', () async {
    final page = _PageLike();
    await page.afterRead(fixture('sod_rsa.bin'), {
      1: fixture('dg1.bin'),
      2: fixture('dg2.bin'),
    });
    expect(page.result!.dataUnchanged, CheckStatus.passed);
    expect(page.result!.issuerSignature, CheckStatus.passed);
  });

  testWidgets('decodes the JPEG 2000 face and the JPEG signature', (
    tester,
  ) async {
    final face = findImages(fixture('image_dg2.bin')).single;
    final sign = findImages(fixture('image_dg7.bin')).single;
    final images = (await tester.runAsync(
      () => Future.wait([face.decode(), sign.decode()]),
    ))!;
    expect([for (final i in images) (i.width, i.height)], [(40, 30), (40, 30)]);
    for (final i in images) {
      i.dispose();
    }
    final png = (await tester.runAsync(face.toDisplayBytes))!;
    expect(png.sublist(1, 4), 'PNG'.codeUnits);
  });
}
