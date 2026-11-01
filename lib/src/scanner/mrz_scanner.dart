import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:logging/logging.dart';

import '../access_key.dart';
import 'mrz_finder.dart';
import 'nv21.dart';

/// What the scanner found.
class MrzScanResult {
  const MrzScanResult(this.key, {required this.elapsed, required this.frames});

  /// The key to read the chip with. Its `documentType` tells what was
  /// scanned, when the MRZ says.
  final AccessKey key;

  /// From the first frame to the result.
  final Duration elapsed;

  /// Frames read by OCR.
  final int frames;
}

/// Which values are found so far, for live hints on your page.
class MrzScanProgress {
  const MrzScanProgress(
      {this.documentNumber = false, this.dates = false, this.frames = 0});

  final bool documentNumber;

  /// Date of birth and date of expiry.
  final bool dates;
  final int frames;
}

/// Finds the [AccessKey] in camera frames of the MRZ (the lines with `<<<`
/// on the back of the ID card or at the bottom of the passport page), with
/// on-device OCR (ML Kit). It shows nothing: feed it the frames of your
/// own camera page. Frames stay in memory; no picture is saved.
///
/// A frame whose whole MRZ passes the composite check digit gives the key
/// at once. Otherwise each value must pass its own check digit and be seen
/// in two frames, so one bad frame cannot give a wrong key.
class MrzScanner {
  MrzScanner();

  static final _log = Logger('dz_id_reader.scanner');
  static TextRecognizer? _ocr;

  static TextRecognizer get _recognizer =>
      _ocr ??= TextRecognizer(script: TextRecognitionScript.latin);

  /// Loads the OCR model (about a second on a mid-range phone), so the
  /// first frame does not wait for it. Call it early, like at app start or
  /// when the user opens the identity step.
  static Future<void> warmUp() async {
    const side = 64;
    final watch = Stopwatch()..start();
    try {
      await _recognizer.processImage(InputImage.fromBytes(
        bytes: Uint8List(side * side * 3 ~/ 2),
        metadata: InputImageMetadata(
          size: const Size(side * 1.0, side * 1.0),
          rotation: InputImageRotation.rotation0deg,
          format: InputImageFormat.nv21,
          bytesPerRow: side,
        ),
      ));
      _log.info('OCR warm-up took ${watch.elapsedMilliseconds} ms');
    } on Object catch (e) {
      _log.warning('OCR warm-up failed: $e');
    }
  }

  /// Frees the OCR model. The next scan loads it again.
  static Future<void> releaseOcr() async {
    final ocr = _ocr;
    _ocr = null;
    await ocr?.close();
  }

  /// The band of an upright picture of [width] × [height] where a card held
  /// in an outline 90 % as wide as the picture is, plus a margin: what most
  /// frames read. Full width, since a line cut at the end fails its check
  /// digits. As fractions of the picture.
  static Rect defaultCardArea(double width, double height) {
    final portrait = width < height ? width / height : height / width;
    final cardHeight = 0.9 * portrait / (85.6 / 54);
    final half = cardHeight / 2 + 0.06;
    return Rect.fromLTRB(
        0, (0.5 - half).clamp(0.0, 1.0), 1, (0.5 + half).clamp(0.0, 1.0));
  }

  var _finder = MrzFinder();
  final _progress = ValueNotifier(const MrzScanProgress());
  final _clock = Stopwatch();
  final _loggedShapes = <String>{};
  var _frames = 0;
  var _busy = false;
  MrzScanResult? _result;

  ValueListenable<MrzScanProgress> get progress => _progress;

  /// The result, once found.
  MrzScanResult? get result => _result;

  /// True while a frame is being read; frames that come meanwhile are
  /// dropped by [addCameraImage] and [addNv21].
  bool get isBusy => _busy;

  /// Starts over, forgetting what was seen.
  void reset() {
    _finder = MrzFinder();
    _frames = 0;
    _result = null;
    _clock
      ..stop()
      ..reset();
    _progress.value = const MrzScanProgress();
  }

  void dispose() => _progress.dispose();

  /// Reads one frame of the `camera` package's image stream (start the
  /// controller with `ImageFormatGroup.nv21`). [sensorOrientation] is
  /// `controller.description.sensorOrientation`; [deviceOrientation] is
  /// `controller.value.deviceOrientation` when your page is not locked to
  /// portrait. [cardArea] is where your page shows the card, as fractions
  /// of the upright picture ([defaultCardArea] if not given).
  Future<MrzScanResult?> addCameraImage(
    CameraImage image, {
    required int sensorOrientation,
    DeviceOrientation deviceOrientation = DeviceOrientation.portraitUp,
    Rect? cardArea,
  }) {
    if (image.planes.length != 1 ||
        image.format.group != ImageFormatGroup.nv21) {
      throw ArgumentError('Start the camera with ImageFormatGroup.nv21');
    }
    final plane = image.planes.first;
    return addNv21(
      plane.bytes,
      width: image.width,
      height: image.height,
      bytesPerRow: plane.bytesPerRow,
      rotation: (sensorOrientation - _turn[deviceOrientation]! + 360) % 360,
      cardArea: cardArea,
    );
  }

  static const _turn = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  /// Reads one NV21 frame from any camera code. [rotation] (0, 90, 180 or
  /// 270) turns the raw frame upright. [cardArea] as in [addCameraImage].
  Future<MrzScanResult?> addNv21(
    Uint8List bytes, {
    required int width,
    required int height,
    required int rotation,
    int? bytesPerRow,
    Rect? cardArea,
  }) async {
    if (_result != null) return _result;
    if (_busy) return null;
    _busy = true;
    _clock.start();
    final started = _clock.elapsedMilliseconds;
    try {
      _frames++;
      // Most frames read only the card area, which is faster. Every third
      // one reads the whole picture, in case the card is held elsewhere.
      final whole = _frames % 3 == 0;
      var frame = bytes, w = width, h = height, rowBytes = bytesPerRow ?? width;
      if (!whole && rowBytes == width) {
        final upright = rotation % 180 == 0
            ? defaultCardArea(width * 1.0, height * 1.0)
            : defaultCardArea(height * 1.0, width * 1.0);
        final cropped = cropNv21(bytes, width, height,
            uprightToRaw(cardArea ?? upright, rotation));
        frame = cropped.bytes;
        w = rowBytes = cropped.width;
        h = cropped.height;
      }
      final text = await _recognizer.processImage(InputImage.fromBytes(
        bytes: frame,
        metadata: InputImageMetadata(
          size: Size(w * 1.0, h * 1.0),
          rotation: InputImageRotationValue.fromRawValue(rotation) ??
              InputImageRotation.rotation0deg,
          format: InputImageFormat.nv21,
          bytesPerRow: rowBytes,
        ),
      ));
      final lines = [
        for (final block in text.blocks)
          for (final line in block.lines) line.text,
      ];
      _log.fine('Frame $_frames: ${_clock.elapsedMilliseconds - started} ms, '
          '${whole ? 'whole' : 'card area'} ${w}x$h, ${lines.length} lines');
      return _addLines(lines);
    } finally {
      _busy = false;
    }
  }

  /// Takes the text lines of one frame from any OCR.
  MrzScanResult? addTextLines(Iterable<String> lines) {
    if (_result != null) return _result;
    _clock.start();
    _frames++;
    return _addLines(lines.toList());
  }

  MrzScanResult? _addLines(List<String> lines) {
    // The layout (not the data) of each new MRZ-looking line, to learn the
    // format of documents we do not know yet.
    for (final line in lines) {
      if (MrzFinder.normalize(line).contains('<')) {
        final shape = MrzFinder.shapeOf(line);
        if (_loggedShapes.add(shape)) _log.fine('MRZ shape $shape');
      }
    }
    _finder.addFrame(lines);
    _progress.value = MrzScanProgress(
      documentNumber: _finder.hasDocumentNumber,
      dates: _finder.hasDates,
      frames: _frames,
    );
    final key = _finder.key;
    if (key == null) return null;
    _clock.stop();
    _log.info('MRZ found in ${_clock.elapsedMilliseconds} ms, $_frames frames');
    return _result =
        MrzScanResult(key, elapsed: _clock.elapsed, frames: _frames);
  }
}
