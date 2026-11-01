import 'package:camera/camera.dart';
import 'package:dz_id_reader/scanner.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A camera page built on [MrzCamera]: the package runs the camera and the
/// OCR; this page only draws the preview, the card outline and the hints.
/// Pops with the [MrzScanResult].
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _camera = MrzCamera();
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
    _camera.result.then((result) {
      HapticFeedback.mediumImpact();
      if (mounted) Navigator.pop(context, result);
    });
  }

  Future<void> _start() async {
    try {
      await _camera.start();
      if (mounted) setState(() {});
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(
        () => _error = e.code == 'CameraAccessDenied'
            ? 'Camera permission was refused. Allow it in Settings.'
            : 'Camera error: ${e.description ?? e.code}',
      );
    }
  }

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _camera.controller;
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
                  child: Text(
                    _error!,
                    style: white,
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : controller == null
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Expanded(
                    child: Center(
                      child: CameraPreview(
                        controller,
                        child: LayoutBuilder(
                          builder: (context, box) => GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapUp: (d) => _camera.focusAt(
                              Offset(
                                d.localPosition.dx / box.maxWidth,
                                d.localPosition.dy / box.maxHeight,
                              ),
                            ),
                            child: const _CardOutline(),
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
                        ValueListenableBuilder(
                          valueListenable: _camera.progress,
                          builder: (context, progress, _) => Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            alignment: WrapAlignment.center,
                            children: [
                              _Found(
                                'Document number',
                                progress.documentNumber,
                              ),
                              _Found('Birth & expiry dates', progress.dates),
                            ],
                          ),
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

/// ID-1 card outline, 90 % of the preview width and centred: where
/// [MrzCamera.cardArea] says the scanner looks first.
class _CardOutline extends StatelessWidget {
  const _CardOutline();

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
  const _Found(this.label, this.found);

  final String label;
  final bool found;

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
