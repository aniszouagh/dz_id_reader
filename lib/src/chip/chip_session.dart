import 'dart:math';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../nfc/transport.dart';
import 'apdu.dart';
import 'bac.dart';
import 'secure_messaging.dart';

/// The chip applications the reader knows.
enum ChipApp {
  /// ICAO 9303 eMRTD: ID cards and passports.
  icao([0xA0, 0x00, 0x00, 0x02, 0x47, 0x10, 0x01]),

  /// ISO/IEC 18013-3: the driving licence.
  licence([0xA0, 0x00, 0x00, 0x02, 0x48, 0x02, 0x00]);

  const ChipApp(this.aid);
  final List<int> aid;
}

/// The file is not on this chip (6A82).
class FileMissingException implements Exception {
  const FileMissingException();
}

/// The chip keeps this file for terminals with government keys (6982),
/// like fingerprints.
class FileLockedException implements Exception {
  const FileLockedException();
}

/// Total size of the BER-TLV object [head] starts, or null when [head] is
/// too short to tell.
int? tlvTotalLength(List<int> head) {
  var i = 0;
  if (head.isEmpty) return null;
  if (head[i++] & 0x1F == 0x1F) {
    while (i < head.length && head[i] & 0x80 != 0) {
      i++;
    }
    i++;
  }
  if (i >= head.length) return null;
  final first = head[i++];
  if (first < 0x80) return i + first;
  final n = first & 0x7F;
  if (n == 0 || n > 3 || i + n > head.length) return null;
  var length = 0;
  for (var k = 0; k < n; k++) {
    length = length << 8 | head[i++];
  }
  return i + length;
}

/// One connection to the chip: select the app, unlock it, read files.
class ChipSession {
  /// [bigChunk] is the big-read size to use (0 for none); it only applies
  /// when the phone sends extended-length commands.
  ChipSession(this._link, {required int bigChunk})
    : _bigChunk = _link.extendedLength ? bigChunk : 0;

  static final _log = Logger('dz_id_reader');

  final CardLink _link;
  SecureMessaging? _sm;
  ChipApp? _app;
  BacKey? _key;
  int _bigChunk;

  /// Commands sent, for the timing report.
  int commands = 0;

  /// Short reads: 223 bytes is the most a short answer holds after secure
  /// messaging adds its padding, status and MAC.
  static const shortChunk = 0xDF;

  /// Big reads, when the phone and the chip both take extended-length
  /// commands: 2 KB, or 960 bytes (a 1 KB answer with secure messaging)
  /// when the chip refuses 2 KB.
  static const bigChunk = 0x800;
  static const mediumChunk = 0x3C0;

  /// The big-read size this session ended with, 0 when big reads are off.
  /// The reader keeps it for the next reads of the same document.
  int get bigReadSize => _bigChunk;

  Future<ResponseApdu> send(CommandApdu command) async {
    commands++;
    final sm = _sm;
    final raw = await _link.transceive(
      sm == null ? command.encode() : sm.wrap(command),
    );
    return sm == null ? ResponseApdu.parse(raw) : sm.unwrap(raw);
  }

  /// Selects the first of [apps] the chip has. Null when it has none.
  Future<ChipApp?> selectApp(List<ChipApp> apps) async {
    for (final app in apps) {
      final r = await send(
        CommandApdu(0x00, 0xA4, 0x04, 0x0C, data: Uint8List.fromList(app.aid)),
      );
      if (r.sw == Sw.ok) return _app = app;
    }
    return null;
  }

  /// BAC (BAP on the licence). Throws [AccessDeniedException] for a wrong
  /// key.
  Future<void> unlock(BacKey key) async {
    _sm = null;
    _key = key;
    _sm = await bacAuthenticate(send, key);
  }

  /// After the chip dropped secure messaging (it answers some errors that
  /// way), select and unlock again.
  Future<void> _reopen() async {
    _sm = null;
    if (await selectApp([_app!]) == null) {
      throw ChipStatusException(Sw.fileNotFound, 'SELECT again');
    }
    await unlock(_key!);
  }

  /// Reads the file with short file identifier [sfi]. [have] holds the
  /// start of the file from an interrupted try; reading goes on from there.
  /// [onBytes] gets the bytes read so far and the file size.
  Future<Uint8List> readFile(
    int sfi, {
    Uint8List? have,
    void Function(Uint8List soFar, int total)? onBytes,
  }) async {
    final out = BytesBuilder(copy: false);
    final known = have == null ? null : tlvTotalLength(have);
    int total;
    if (known != null) {
      // Make it the current file again (a READ BINARY by SFI does that).
      await _readBinary(0x80 | sfi, 0, 1);
      out.add(have!);
      total = known;
    } else {
      final first = await _readBinary(0x80 | sfi, 0, shortChunk);
      total =
          tlvTotalLength(first) ??
          (throw ChipStatusException(
            Sw.wrongData,
            'file ${_sfiName(sfi)} header',
          ));
      out.add(first);
    }
    while (out.length < total) {
      onBytes?.call(out.toBytes(), total);
      final offset = out.length;
      final left = total - offset;
      Uint8List data;
      try {
        data = await _readAt(offset, left);
      } on _Reselect {
        // After a refused command the chip may have dropped the session or
        // forgotten the current file.
        if (_sm?.broken ?? true) await _reopen();
        await _readBinary(0x80 | sfi, 0, 1);
        continue;
      }
      if (data.isEmpty) {
        throw ChipStatusException(
          Sw.offsetOutsideFile,
          'READ BINARY at $offset',
        );
      }
      out.add(data.length > left ? Uint8List.sublistView(data, 0, left) : data);
    }
    final bytes = out.takeBytes();
    return bytes.length > total
        ? Uint8List.sublistView(bytes, 0, total)
        : bytes;
  }

  Future<Uint8List> _readAt(int offset, int left) async {
    final big = _bigChunk > 0 && left > shortChunk;
    final ne = big ? min(left, _bigChunk) : min(left, shortChunk);
    try {
      if (offset <= 0x7FFF) {
        return await _readBinary(offset >> 8, offset & 0xFF, ne);
      }
      return await _readBinaryOdd(offset, ne);
    } on ChipStatusException catch (e) {
      if (!big) rethrow;
      // A chip that answers in clear and drops the session cannot parse
      // extended-length commands at all: short reads from now on. One that
      // answers properly may only refuse the size: try a smaller one.
      final dropped = _sm?.broken ?? true;
      _bigChunk = !dropped && _bigChunk > mediumChunk ? mediumChunk : 0;
      _log.info(
        'Big read of $ne bytes refused (${Sw.name(e.sw)}, session '
        '${dropped ? 'dropped' : 'kept'}); '
        '${_bigChunk > 0 ? 'trying $_bigChunk bytes' : 'short reads'} now',
      );
      throw const _Reselect();
    } on SecureMessagingException catch (e) {
      if (!big) rethrow;
      _bigChunk = 0;
      _log.info('Big read of $ne bytes failed ($e); short reads now');
      throw const _Reselect();
    } on CardLostException {
      // Maybe the card moved, maybe the phone or the chip choked on the big
      // command. The next connection reads without big reads.
      if (big) _bigChunk = 0;
      rethrow;
    }
  }

  Future<Uint8List> _readBinary(int p1, int p2, int ne) async {
    final r = await send(CommandApdu(0x00, 0xB0, p1, p2, ne: ne));
    if (r.sw >> 8 == 0x6C && ne <= 256) {
      // Wrong length; the chip says how many bytes it has.
      final n = r.sw & 0xFF;
      return _readBinary(p1, p2, n == 0 ? 256 : n);
    }
    return _data(r, 'READ BINARY');
  }

  /// READ BINARY with odd INS, for offsets past 32767: the offset goes in
  /// a data object and the answer comes wrapped in DO53.
  Future<Uint8List> _readBinaryOdd(int offset, int ne) async {
    final offsetBytes = [
      if (offset > 0xFFFF) offset >> 16 & 0xFF,
      offset >> 8 & 0xFF,
      offset & 0xFF,
    ];
    final r = await send(
      CommandApdu(
        0x00,
        0xB1,
        0x00,
        0x00,
        data: Uint8List.fromList([0x54, offsetBytes.length, ...offsetBytes]),
        ne: ne + 4,
      ),
    );
    final data = _data(r, 'READ BINARY (odd)');
    if (data.isEmpty || data[0] != 0x53) return data;
    final end = tlvTotalLength(data) ?? data.length;
    final header = end - _tlvValueLength(data);
    return Uint8List.sublistView(data, header, min(end, data.length));
  }

  static int _tlvValueLength(List<int> tlv) {
    final b = tlv[1];
    if (b < 0x80) return b;
    var n = 0;
    for (var k = 0; k < (b & 0x7F); k++) {
      n = n << 8 | tlv[2 + k];
    }
    return n;
  }

  Uint8List _data(ResponseApdu r, String what) {
    switch (r.sw) {
      case Sw.ok || Sw.endOfFile:
        return r.data;
      case Sw.fileNotFound:
        throw const FileMissingException();
      case Sw.securityNotSatisfied:
        throw const FileLockedException();
    }
    throw ChipStatusException(r.sw, what);
  }

  /// Active Authentication: the chip signs [challenge] with its private
  /// key. [signatureLength] comes from the public key in DG15.
  Future<Uint8List> internalAuthenticate(
    Uint8List challenge,
    int signatureLength,
  ) async {
    final ne = signatureLength > shortChunk && _bigChunk > 0
        ? signatureLength
        : 256;
    final r = await send(
      CommandApdu(0x00, 0x88, 0x00, 0x00, data: challenge, ne: ne),
    );
    if (r.sw != Sw.ok) throw ChipStatusException(r.sw, 'INTERNAL AUTHENTICATE');
    return r.data;
  }

  static String _sfiName(int sfi) => switch (sfi) {
    0x1D => 'EF.SOD',
    0x1E => 'EF.COM',
    _ => 'DG$sfi',
  };
}

class _Reselect implements Exception {
  const _Reselect();
}
