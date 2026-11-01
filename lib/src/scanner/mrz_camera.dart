import 'dart:async';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import 'mrz_scanner.dart';

/// Optional helper: opens the back camera with the settings the scanner
/// works best with (high resolution, NV21 frames, no audio) and feeds it
/// the frames. Your page shows [controller] with `CameraPreview` and draws
/// whatever it wants around it.
///
/// ```dart
/// final camera = MrzCamera();
/// await camera.start();                 // CameraException if refused
/// // build: CameraPreview(camera.controller!, child: yourOverlay)
/// final result = await camera.result;   // the AccessKey is result.key
/// await camera.dispose();
/// ```
class MrzCamera {
  MrzCamera({MrzScanner? scanner, this.resolution = ResolutionPreset.veryHigh})
      : scanner = scanner ?? MrzScanner();

  final MrzScanner scanner;
  final ResolutionPreset resolution;
  final _result = Completer<MrzScanResult>();
  CameraController? _controller;
  bool _disposed = false;

  /// Null until [start] is done.
  CameraController? get controller => _controller;

  /// Completes when the MRZ is read.
  Future<MrzScanResult> get result => _result.future;

  ValueListenable<MrzScanProgress> get progress => scanner.progress;

  /// Where the scanner looks first, as fractions of the upright preview:
  /// draw your card outline over this band (centred, 90 % of the width).
  Rect get cardArea {
    final size = _controller?.value.previewSize;
    if (size == null) return MrzScanner.defaultCardArea(3, 4);
    return MrzScanner.defaultCardArea(size.shortestSide, size.longestSide);
  }

  /// Opens the back camera and starts reading frames. Throws
  /// `CameraException` (code `CameraAccessDenied` when the user refuses).
  Future<void> start() async {
    final cameras = await availableCameras();
    final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first);
    final controller = CameraController(back, resolution,
        enableAudio: false, imageFormatGroup: ImageFormatGroup.nv21);
    await controller.initialize();
    if (_disposed) {
      await controller.dispose();
      return;
    }
    _controller = controller;
    await controller.startImageStream(_onFrame);
  }

  Future<void> _onFrame(CameraImage image) async {
    final controller = _controller;
    if (controller == null || _result.isCompleted || scanner.isBusy) return;
    try {
      final found = await scanner.addCameraImage(image,
          sensorOrientation: controller.description.sensorOrientation,
          deviceOrientation: controller.value.deviceOrientation);
      if (found != null && !_result.isCompleted) {
        _result.complete(found);
        await controller.stopImageStream();
      }
    } on Object {
      // A frame that fails is skipped; the next one comes in milliseconds.
    }
  }

  /// Focuses and meters at [point], given as fractions of the preview
  /// (what a tap on your preview gives, divided by its size).
  Future<void> focusAt(Offset point) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.setFocusPoint(point);
      await controller.setExposurePoint(point);
    } on CameraException {
      // Not every camera can.
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    final controller = _controller;
    _controller = null;
    await controller?.dispose();
    scanner.dispose();
  }
}
