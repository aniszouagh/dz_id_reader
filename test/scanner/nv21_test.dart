import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:dz_id_reader/src/scanner/nv21.dart';

void main() {
  test('cropNv21 copies the Y rows and the matching VU rows', () {
    // 8x4 frame: Y = y*8 + x, VU plane (2 rows) = 100 + row*8 + x.
    final frame = Uint8List.fromList([
      for (var i = 0; i < 32; i++) i,
      for (var i = 0; i < 16; i++) 100 + i,
    ]);
    final c = cropNv21(frame, 8, 4, const Rect.fromLTRB(0.25, 0.5, 0.75, 1));
    expect((c.width, c.height), (4, 2));
    expect(c.bytes, [18, 19, 20, 21, 26, 27, 28, 29, 110, 111, 112, 113]);
  });

  test('uprightToRaw turns a band across the portrait screen', () {
    const band = Rect.fromLTRB(0, 0.25, 1, 0.75);
    // Back camera (90): the raw frame is landscape, so the band is vertical.
    expect(uprightToRaw(band, 90), const Rect.fromLTRB(0.25, 0, 0.75, 1));
    expect(uprightToRaw(band, 270), const Rect.fromLTRB(0.25, 0, 0.75, 1));
    expect(uprightToRaw(band, 0), band);
    // An off-centre box shows the direction of the turn.
    const topLeft = Rect.fromLTRB(0, 0, 0.5, 0.25);
    expect(uprightToRaw(topLeft, 90), const Rect.fromLTRB(0, 0.5, 0.25, 1));
    expect(uprightToRaw(topLeft, 270), const Rect.fromLTRB(0.75, 0, 1, 0.5));
  });
}
