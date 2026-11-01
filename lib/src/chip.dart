import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dmrtd/dmrtd.dart';
import 'package:dmrtd/internal.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_nfc_kit/flutter_nfc_kit.dart';
import 'package:logging/logging.dart';

/// dmrtd's NfcProvider with two changes: Android is told to skip its NDEF
/// check on the card (about 150 ms on every read, and it can never succeed
/// on an ID chip), and disconnect() leaves reader mode alone, because
/// HomePage hands reader mode to its ignoring callback instead (see
/// MainActivity.holdNfc).
class FastNfcProvider extends ComProvider {
  FastNfcProvider() : super(Logger('nfc.fast'));

  static const _timeout = Duration(seconds: 10);
  NFCTag? _tag;

  @override
  Future<void> connect({Duration timeout = _timeout}) async {
    if (_tag != null) return;
    final NFCTag tag;
    try {
      tag = await FlutterNfcKit.poll(
        timeout: timeout,
        androidCheckNDEF: false,
        readIso15693: false,
      );
    } on Exception catch (e) {
      throw ComProviderError(e.toString());
    }
    if (tag.type != NFCTagType.iso7816) {
      throw ComProviderError('That is not an ID chip (${tag.type.name}).');
    }
    _tag = tag;
  }

  @override
  Future<void> disconnect() async => _tag = null;

  @override
  bool isConnected() => _tag != null;

  @override
  Future<Uint8List> transceive(Uint8List data) async {
    try {
      return await FlutterNfcKit.transceive(data, timeout: _timeout);
    } on Exception catch (e) {
      throw ComProviderError(e.toString());
    }
  }
}

/// True when [error] means the card left the phone in the middle of a read.
bool cardMovedAway(Object error) {
  final s = error.toString().toLowerCase();
  return s.contains('communication error') ||
      s.contains('tag was lost') ||
      s.contains('tag already removed') ||
      s.contains('tag connection lost');
}

/// Reads files from an unlocked chip.
///
/// dmrtd reads every file in at least two commands: 8 bytes to learn the
/// length, then the rest in 112-byte chunks. This reads a file in one
/// command of up to 223 bytes (what still fits a short APDU response after
/// secure messaging), which covers EF.COM, DG1, DG11 and DG12; bigger
/// files like the photo take one command per 223 bytes. A chip that refuses
/// that gets the session reopened with [reopen] and dmrtd's way from then
/// on.
class FileReader {
  FileReader(this.api, this.reopen);

  final MrtdApi api;

  /// Selects the app and unlocks it again, for when an error may have
  /// broken secure messaging.
  final Future<void> Function() reopen;

  /// Turned off for this session once the chip refuses a big read.
  bool oneCommandReads = true;
  static const _chunk = 0xDF;

  /// [onProgress] gets bytes read so far and the file size, for big files.
  Future<Uint8List> read(int sfi,
      {void Function(int done, int total)? onProgress}) async {
    try {
      return oneCommandReads
          ? await _readWhole(sfi, onProgress)
          : await api.readFileBySFI(sfi);
    } on ComProviderError {
      rethrow; // the card moved away: HomePage waits for it again
    } on ICCError catch (e) {
      // Normal answers, sent under secure messaging, so the session goes on.
      if (e.sw == StatusWord.fileNotFound ||
          e.sw == StatusWord.securityStatusNotSatisfied) {
        rethrow;
      }
      return _recover(sfi, e);
    } on Exception catch (e) {
      return _recover(sfi, e);
    }
  }

  Future<Uint8List> _recover(int sfi, Exception error) async {
    debugPrint('READ sfi=$sfi failed ($error), reopening the session');
    oneCommandReads = false;
    await reopen();
    return api.readFileBySFI(sfi);
  }

  Future<Uint8List> _readWhole(
      int sfi, void Function(int done, int total)? onProgress) async {
    final first =
        await api.icc.readBinaryBySFI(sfi: 0x80 | sfi, offset: 0, ne: _chunk);
    final head = first.data!;
    final header = TLV.decodeTagAndLength(head);
    final total = header.encodedLen + header.length.value;
    final out = BytesBuilder(copy: false)
      ..add(head.length > total ? head.sublist(0, total) : head);
    while (out.length < total) {
      onProgress?.call(out.length, total);
      final offset = out.length;
      final ne = math.min(total - offset, _chunk);
      // Plain READ BINARY offsets stop at 32766 (dmrtd's limit) and a read
      // may not cross 0x7FFF; past that the odd-INS variant carries the
      // offset in its data.
      final next = offset > 32766
          ? await api.icc.readBinaryExt(offset: offset, ne: ne)
          : await api.icc.readBinary(
              offset: offset, ne: math.min(ne, 0x7FFF - offset));
      final data = next.data;
      if (data == null || data.isEmpty) {
        throw MrtdApiError('Empty read at offset ${out.length}');
      }
      out.add(data);
    }
    final bytes = out.takeBytes();
    return bytes.length > total ? bytes.sublist(0, total) : bytes;
  }
}
