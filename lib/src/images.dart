import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:jpeg2000/jpeg2000.dart';

import 'lds/tlv.dart';

enum ImageFormat { jpeg, jpeg2000 }

/// A picture from the chip: the face photo or the signature.
class DocumentImage {
  const DocumentImage(this.format, this.bytes);

  final ImageFormat format;

  /// The picture file as stored on the chip.
  final Uint8List bytes;

  /// Decodes the picture for drawing (RawImage, a CustomPainter…). JPEG
  /// 2000, which Android cannot decode, is decoded on a background isolate.
  Future<ui.Image> decode() async {
    if (format == ImageFormat.jpeg) {
      final codec = await ui.instantiateImageCodec(bytes);
      return (await codec.getNextFrame()).image;
    }
    final rgba = await _decodeJpeg2000InBackground(bytes);
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba.pixels,
      rgba.width,
      rgba.height,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    return done.future;
  }

  /// Bytes that `Image.memory` can show: the JPEG as it is, or the JPEG
  /// 2000 converted to PNG.
  Future<Uint8List> toDisplayBytes() async {
    if (format == ImageFormat.jpeg) return bytes;
    final image = await decode();
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      return png!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }
}

const _starts = [
  // JP2 file signature box, JPEG 2000 codestream (SOC + SIZ), JPEG (SOI).
  (
    [0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A],
    ImageFormat.jpeg2000,
  ),
  ([0xFF, 0x4F, 0xFF, 0x51], ImageFormat.jpeg2000),
  ([0xFF, 0xD8, 0xFF], ImageFormat.jpeg),
];

/// Pictures stored in a data group: the face in DG2, the signature in DG7
/// (DG4 and DG5 on the licence). They sit behind biometric headers whose
/// layout varies between countries, so this looks for where a JPEG or
/// JPEG 2000 file starts in each value instead of parsing the headers.
List<DocumentImage> findImages(Uint8List dataGroup) {
  final out = <DocumentImage>[];
  for (final (_, value) in tlvLeafBytes(dataGroup)) {
    (int, ImageFormat)? first;
    for (final (start, format) in _starts) {
      final at = _indexOf(value, start);
      if (at >= 0 && (first == null || at < first.$1)) first = (at, format);
    }
    if (first != null) {
      out.add(DocumentImage(first.$2, Uint8List.sublistView(value, first.$1)));
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

/// Not async and not inline in [DocumentImage.decode], so the closure sent
/// to the isolate carries only [bytes]: a closure takes its scope's whole
/// context along.
Future<({Uint8List pixels, int width, int height})> _decodeJpeg2000InBackground(
  Uint8List bytes,
) => Isolate.run(() => decodeJpeg2000(bytes));

/// JPEG 2000 to one RGBA buffer (the decoder returns RGBA tiles).
({Uint8List pixels, int width, int height}) decodeJpeg2000(Uint8List bytes) {
  final jpx = JpxImage()..parse(bytes);
  final width = jpx.width, height = jpx.height;
  final pixels = Uint8List(width * height * 4);
  for (final tile in jpx.tiles) {
    for (var y = 0; y < tile.height; y++) {
      final to = ((tile.top + y) * width + tile.left) * 4;
      pixels.setRange(to, to + tile.width * 4, tile.items, y * tile.width * 4);
    }
  }
  return (pixels: pixels, width: width, height: height);
}
