import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dz_id_reader/src/images.dart';
import 'package:dz_id_reader/src/security.dart';

Uint8List fixture(String name) =>
    File('test/fixtures/$name').readAsBytesSync();

/// Shaped like the home page's _afterRead: another closure in the method
/// captures `this` (as setState callbacks do), so the scope's shared
/// context holds the object and its unsendable Completer. An inline
/// Isolate.run closure here failed on the phone with "object is
/// unsendable".
class _PageLike {
  final pending = Completer<void>();
  final rows = <(String, String, bool?)>[];

  Future<void> afterRead(Uint8List sod, Map<int, Uint8List> files) async {
    void setStateLike(void Function() f) => f();
    setStateLike(() => rows.clear());
    rows.addAll(await securityReportInBackground(sod, files));
  }
}

void main() {
  test('security checks run on an isolate when called from a page', () async {
    final files = {1: fixture('dg1.bin'), 2: fixture('dg2.bin')};
    final sod = fixture('sod_rsa.bin');
    final page = _PageLike();
    await page.afterRead(sod, files);
    expect(page.rows, securityReport(sod, files));
    expect(page.rows.take(2).map((row) => row.$3), [true, true]);
  });

  testWidgets('decodes the JPEG 2000 face and the JPEG signature',
      (tester) async {
    final face = findImages(fixture('image_dg2.bin')).single;
    final sign = findImages(fixture('image_dg7.bin')).single;
    final images = (await tester.runAsync(
        () => Future.wait([decodeImage(face), decodeImage(sign)])))!;
    expect([for (final i in images) (i.width, i.height)], [(40, 30), (40, 30)]);
    for (final i in images) {
      i.dispose();
    }
  });
}
