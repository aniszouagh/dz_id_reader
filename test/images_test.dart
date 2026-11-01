import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dz_id_reader/src/images.dart';

void main() {
  test('finds and decodes a JPEG 2000 face behind a DG2 header', () {
    final found = findImages(File('test/fixtures/image_dg2.bin').readAsBytesSync());
    expect(found, hasLength(1));
    expect(found.single.format, ImageFormat.jpeg2000);
    final image = decodeJpeg2000(found.single.bytes);
    expect((image.width, image.height), (40, 30));
    expect(image.pixels.length, 40 * 30 * 4);
    // testsrc draws colours, so the picture is not all one value.
    expect(image.pixels.toSet().length, greaterThan(10));
  });

  test('finds a JPEG signature in DG7', () {
    final found = findImages(File('test/fixtures/image_dg7.bin').readAsBytesSync());
    expect(found.single.format, ImageFormat.jpeg);
    expect(found.single.bytes.sublist(0, 3), [0xFF, 0xD8, 0xFF]);
  });
}
