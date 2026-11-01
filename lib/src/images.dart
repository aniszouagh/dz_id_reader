import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:jpeg2000/jpeg2000.dart';

import 'licence.dart' show tlvLeafBytes;

enum ImageKind { jpeg, jpeg2000 }

class FoundImage {
  const FoundImage(this.kind, this.bytes);

  final ImageKind kind;
  final Uint8List bytes;
}

const _starts = [
  // JP2 file signature box, JPEG 2000 codestream (SOC + SIZ), JPEG (SOI).
  ([0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A],
      ImageKind.jpeg2000),
  ([0xFF, 0x4F, 0xFF, 0x51], ImageKind.jpeg2000),
  ([0xFF, 0xD8, 0xFF], ImageKind.jpeg),
];

/// Pictures stored in a data group: the face in DG2, the signature in DG7.
/// They sit behind biometric headers whose layout varies between
/// countries, so this looks for where a JPEG or JPEG 2000 file starts in
/// each value instead of parsing the headers.
List<FoundImage> findImages(Uint8List dataGroup) {
  final out = <FoundImage>[];
  for (final (_, value) in tlvLeafBytes(dataGroup)) {
    (int, ImageKind)? first;
    for (final (start, kind) in _starts) {
      final at = _indexOf(value, start);
      if (at >= 0 && (first == null || at < first.$1)) first = (at, kind);
    }
    if (first != null) {
      out.add(FoundImage(first.$2, Uint8List.sublistView(value, first.$1)));
    }
  }
  return out;
}

int _indexOf(Uint8List data, List<int> pattern) {
  outer:
  for (var i = 0; i + pattern.length <= data.length; i++) {
    for (var j = 0; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// Decodes a found picture for display. JPEG goes to the engine's decoder.
/// JPEG 2000, which Android cannot decode, is decoded in pure Dart on a
/// background isolate so the screen does not freeze.
Future<ui.Image> decodeImage(FoundImage image) async {
  if (image.kind == ImageKind.jpeg) {
    final codec = await ui.instantiateImageCodec(image.bytes);
    return (await codec.getNextFrame()).image;
  }
  final rgba = await _decodeJpeg2000InBackground(Uint8List.fromList(image.bytes));
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba.pixels, rgba.width, rgba.height,
      ui.PixelFormat.rgba8888, done.complete);
  return done.future;
}

/// Not async and not inline in [decodeImage], so the closure sent to the
/// isolate carries only [bytes] (see securityReportInBackground).
Future<({Uint8List pixels, int width, int height})> _decodeJpeg2000InBackground(
        Uint8List bytes) =>
    Isolate.run(() => decodeJpeg2000(bytes));

/// JPEG 2000 to one RGBA buffer (the decoder returns RGBA tiles).
({Uint8List pixels, int width, int height}) decodeJpeg2000(Uint8List bytes) {
  final jpx = JpxImage()..parse(bytes);
  final width = jpx.width, height = jpx.height;
  final pixels = Uint8List(width * height * 4);
  for (final tile in jpx.tiles) {
    for (var y = 0; y < tile.height; y++) {
      final to = ((tile.top + y) * width + tile.left) * 4;
      pixels.setRange(
          to, to + tile.width * 4, tile.items, y * tile.width * 4);
    }
  }
  return (pixels: pixels, width: width, height: height);
}
