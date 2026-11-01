/// Gets the [AccessKey] from the camera: the MRZ on the back of the ID card
/// or at the bottom of the passport page, read by on-device OCR.
///
/// [MrzScanner] has no UI and takes frames from any camera code;
/// [MrzCamera] is an optional helper that runs the `camera` package with
/// the right settings for your own preview page.
library;

export 'dz_id_reader.dart' show AccessKey, DocumentType;
export 'src/scanner/mrz_camera.dart';
export 'src/scanner/mrz_scanner.dart';
