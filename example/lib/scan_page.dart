import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'package:dz_id_reader/dz_id_reader.dart';

/// One OCR engine for the whole app. [warmUpOcr] runs it once at start-up,
/// so the first camera frame does not wait for the model to load.
final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

Future<void> warmUpOcr() async {
  const side = 64;
  final watch = Stopwatch()..start();
  try {
    await textRecognizer.processImage(InputImage.fromBytes(
      bytes: Uint8List(side * side * 3 ~/ 2),
      metadata: InputImageMetadata(
        size: const Size(side * 1.0, side * 1.0),
        rotation: InputImageRotation.rotation0deg,
        format: InputImageFormat.nv21,
        bytesPerRow: side,
      ),
    ));
    debugPrint('OCR warm-up took ${watch.elapsedMilliseconds} ms');
  } catch (e) {
    debugPrint('OCR warm-up failed: $e');
  }
}

/// What the scan found, plus a line about how long it took.
class ScanResult {
  final MrzKey key;
  final String summary;

  const ScanResult(this.key, this.summary);
}

/// Camera screen that reads the MRZ on the back of the card and pops with a
/// [ScanResult]. Frames are read in memory by on-device OCR and dropped; no
/// picture is taken or saved.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  static const _deviceTurn = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  final _finder = MrzFinder();
  final _loggedShapes = <String>{};
  final _clock = Stopwatch()..start();
  CameraController? _camera;
  bool _busy = false;
  bool _done = false;
  String? _error;
  int _frames = 0;
  int _ocrMs = 0;
  int? _firstFrameMs;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _camera?.dispose(); // textRecognizer stays open for the next scan
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first);
      final camera = CameraController(
        back,
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      await camera.initialize();
      if (!mounted) {
        await camera.dispose();
        return;
      }
      setState(() => _camera = camera);
      await camera.startImageStream(_onFrame);
    } on CameraException catch (e) {
      setState(() => _error = e.code == 'CameraAccessDenied'
          ? 'Camera permission was refused. Allow it in Settings.'
          : 'Camera error: ${e.description ?? e.code}');
    }
  }

  Future<void> _onFrame(CameraImage image) async {
    final camera = _camera;
    if (_busy || _done || camera == null) return;
    _busy = true;
    final started = _clock.elapsedMilliseconds;
    _firstFrameMs ??= started;
    try {
      _frames++;
      // Most frames only read the card area. Every third frame reads the
      // whole picture, in case the card is held outside the frame.
      final whole = _frames % 3 == 0;
      final input = _toInputImage(image, camera, crop: !whole);
      if (input == null) return;
      final text = await textRecognizer.processImage(input);
      final ms = _clock.elapsedMilliseconds - started;
      _ocrMs += ms;
      final lines = [
        for (final block in text.blocks)
          for (final line in block.lines) line.text,
      ];
      debugPrint('OCR frame $_frames: $ms ms, '
          '${whole ? 'whole' : 'card area'} '
          '${input.metadata!.size.width.toInt()}x'
          '${input.metadata!.size.height.toInt()}, ${lines.length} lines');
      // Log the layout (not the data) of each new MRZ-looking line, to learn
      // the format of documents we do not know yet.
      for (final line in lines) {
        if (MrzFinder.normalize(line).contains('<')) {
          final shape = MrzFinder.shapeOf(line);
          if (_loggedShapes.add(shape)) debugPrint('MRZSHAPE $shape');
        }
      }
      _finder.addFrame(lines);
      final key = _finder.key;
      if (key != null && !_done) {
        _done = true;
        final summary = 'Scan: ${_seconds(_clock.elapsedMilliseconds)} after '
            'opening the camera (first frame at ${_seconds(_firstFrameMs!)}, '
            '$_frames frames of ~${_ocrMs ~/ _frames} ms OCR)';
        debugPrint(summary);
        HapticFeedback.mediumImpact();
        await camera.stopImageStream();
        if (mounted) Navigator.pop(context, ScanResult(key, summary));
      } else if (mounted) {
        setState(() {}); // refresh the found / not found chips
      }
    } catch (e) {
      debugPrint('MRZ frame skipped: $e');
    } finally {
      _busy = false;
    }
  }

  static String _seconds(int ms) => '${(ms / 1000).toStringAsFixed(1)} s';

  /// The card outline drawn by [_CardFrame], as fractions of the upright
  /// picture, with a margin above and below. Full width: the analysis frame
  /// can be wider than the preview, and a cut line end would fail the check
  /// digits.
  Rect _cardArea(CameraController camera, CameraImage image) {
    final preview = camera.value.previewSize ??
        Size(image.width.toDouble(), image.height.toDouble());
    final portraitRatio = preview.shortestSide / preview.longestSide;
    final cardHeight = 0.9 * portraitRatio / (85.6 / 54);
    final half = cardHeight / 2 + 0.06;
    return Rect.fromLTRB(
        0, (0.5 - half).clamp(0, 1), 1, (0.5 + half).clamp(0, 1));
  }

  InputImage? _toInputImage(CameraImage image, CameraController camera,
      {required bool crop}) {
    final sensor = camera.description.sensorOrientation;
    final turn = _deviceTurn[camera.value.deviceOrientation] ?? 0;
    final rotation =
        InputImageRotationValue.fromRawValue((sensor - turn + 360) % 360);
    final format = InputImageFormatValue.fromRawValue(image.format.raw as int);
    if (rotation == null ||
        format != InputImageFormat.nv21 ||
        image.planes.length != 1) {
      return null;
    }
    final plane = image.planes.first;
    var bytes = plane.bytes;
    var width = image.width, height = image.height;
    if (crop &&
        plane.bytesPerRow == width &&
        bytes.length >= width * height * 3 ~/ 2) {
      // The screen is locked to portrait, so the outline on screen maps to
      // the raw frame through the sensor's own turn.
      final area = uprightToRaw(_cardArea(camera, image), sensor);
      final cropped = cropNv21(bytes, width, height, area);
      bytes = cropped.bytes;
      width = cropped.width;
      height = cropped.height;
    }
    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(width.toDouble(), height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: width,
      ),
    );
  }

  void _focusAt(Offset point, Size size) {
    final camera = _camera;
    if (camera == null) return;
    final p = Offset(point.dx / size.width, point.dy / size.height);
    camera.setFocusPoint(p).catchError((_) {});
    camera.setExposurePoint(p).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    const white = TextStyle(color: Colors.white);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan the document'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_error!,
                      style: white, textAlign: TextAlign.center),
                ),
              )
            : camera == null
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    children: [
                      Expanded(
                        child: Center(
                          child: CameraPreview(
                            camera,
                            child: LayoutBuilder(
                              builder: (context, box) => GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapUp: (d) =>
                                    _focusAt(d.localPosition, box.biggest),
                                child: const _CardFrame(),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                        child: Column(
                          children: [
                            const Text(
                              'Show the lines with <<<: the back of the ID '
                              'card, or the bottom of the passport photo page. '
                              'They must be sharp. Tap to focus.',
                              style: white,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              alignment: WrapAlignment.center,
                              children: [
                                _Found('Document number',
                                    _finder.hasDocumentNumber),
                                _Found('Birth & expiry dates',
                                    _finder.hasDates),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}

/// ID-1 card outline drawn over the preview.
class _CardFrame extends StatelessWidget {
  const _CardFrame();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FractionallySizedBox(
        widthFactor: 0.9,
        child: AspectRatio(
          aspectRatio: 85.6 / 54,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 2),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
    );
  }
}

class _Found extends StatelessWidget {
  final String label;
  final bool found;

  const _Found(this.label, this.found);

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(
        found ? Icons.check_circle : Icons.radio_button_unchecked,
        color: found ? Colors.green : Colors.grey,
      ),
      label: Text(label),
    );
  }
}
