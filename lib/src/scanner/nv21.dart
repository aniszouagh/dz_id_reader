import 'dart:typed_data';
import 'dart:ui';

/// Maps a region of the upright picture (fractions of its width and height)
/// to the raw camera frame, which arrives turned by [rotation] degrees (the
/// clockwise turn that makes it upright).
Rect uprightToRaw(Rect r, int rotation) => switch (rotation) {
      90 => Rect.fromLTRB(r.top, 1 - r.right, r.bottom, 1 - r.left),
      180 => Rect.fromLTRB(1 - r.right, 1 - r.bottom, 1 - r.left, 1 - r.top),
      270 => Rect.fromLTRB(1 - r.bottom, r.left, 1 - r.top, r.right),
      _ => r,
    };

/// Copies [region] (fractions of the frame) out of a [width] x [height]
/// NV21 frame. NV21 is a full-size Y plane followed by a half-height plane
/// of interleaved V and U bytes, so the crop is rounded to even pixels.
({Uint8List bytes, int width, int height}) cropNv21(
    Uint8List frame, int width, int height, Rect region) {
  int even(double fraction, int size) =>
      ((fraction * size).round() ~/ 2 * 2).clamp(0, size);
  final x0 = even(region.left, width), x1 = even(region.right, width);
  final y0 = even(region.top, height), y1 = even(region.bottom, height);
  final w = x1 - x0, h = y1 - y0;
  final out = Uint8List(w * h * 3 ~/ 2);
  for (var row = 0; row < h; row++) {
    out.setRange(row * w, (row + 1) * w, frame, (y0 + row) * width + x0);
  }
  final frameVu = width * height, outVu = w * h;
  for (var row = 0; row < h ~/ 2; row++) {
    out.setRange(outVu + row * w, outVu + (row + 1) * w, frame,
        frameVu + (y0 ~/ 2 + row) * width + x0);
  }
  return (bytes: out, width: w, height: h);
}
