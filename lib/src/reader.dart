import 'dart:math';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import 'access_key.dart';
import 'chip/apdu.dart';
import 'chip/bac.dart';
import 'chip/chip_session.dart';
import 'chip/secure_messaging.dart';
import 'document.dart';
import 'errors.dart';
import 'info.dart';
import 'lds/build_document.dart';
import 'lds/mrz_text.dart';
import 'lds/tlv.dart';
import 'nfc/android_nfc.dart';
import 'nfc/transport.dart';
import 'progress.dart';
import 'security.dart';

/// Reads ID cards, passports and driving licences over NFC.
///
/// It shows nothing on screen: your app draws its own pages from
/// [ReadProgress] and the returned [IdDocument], and turns each
/// [ReadException] into its own message.
class DocumentReader {
  /// [trustedCountryCertificates] are CSCA certificates (DER). When given,
  /// [Check.dataAuthentic] also checks that the document signer belongs to
  /// one of these countries.
  DocumentReader({
    NfcTransport? transport,
    List<Uint8List> trustedCountryCertificates = const [],
  }) : _nfc = transport ?? const AndroidNfc(),
       _trusted = List.unmodifiable(trustedCountryCertificates);

  static final _log = Logger('dz_id_reader');

  final NfcTransport _nfc;
  final List<Uint8List> _trusted;
  final _random = Random.secure();
  bool _busy = false;
  bool _cancelled = false;

  /// The big-read size that works for each document (by number; 0 when
  /// its chip refuses big reads), so the next read starts with it.
  final _bigReads = <String, int>{};

  Future<NfcState> nfcState() => _nfc.state();

  /// Opens the phone's NFC settings.
  Future<void> openNfcSettings() => _nfc.openSettings();

  /// Call when your read screen opens. Until [releaseNfc], a card that
  /// touches the phone outside a read is ignored, so Android does not show
  /// its own "cannot read this tag" message. It also lets a read start at
  /// once when the card is already on the phone.
  Future<void> holdNfc() => _nfc.hold(true);

  /// Call when your read screen closes.
  Future<void> releaseNfc() => _nfc.hold(false);

  bool get isReading => _busy;

  /// Stops the running read, which then throws [ReadCancelled].
  Future<void> cancel() async {
    if (!_busy) return;
    _cancelled = true;
    await _nfc.cancel();
  }

  /// Waits for the document and reads what [want] asks for, plus the
  /// [checks]. If the card moves away, it waits for it to come back and
  /// goes on where it stopped, until [timeout] runs out.
  ///
  /// Throws a [ReadException].
  Future<IdDocument> read(
    AccessKey key, {
    Set<Info> want = Info.mrzData,
    Set<Check> checks = const {},
    Duration timeout = const Duration(seconds: 30),
    void Function(ReadProgress progress)? onProgress,
    bool keepRawFiles = false,
  }) async {
    if (_busy) throw StateError('A read is already running');
    _busy = true;
    _cancelled = false;
    try {
      return await _ReadJob(
        this,
        key,
        want,
        checks,
        timeout,
        onProgress,
        keepRawFiles,
      ).run();
    } finally {
      _busy = false;
    }
  }
}

/// One file to read, with a size guess for the progress bar until its real
/// size is known.
typedef _PlannedFile = ({int sfi, int guess});

class _ReadJob {
  _ReadJob(
    this.reader,
    this.key,
    this.want,
    this.checks,
    this.timeout,
    this.onProgress,
    this.keepRawFiles,
  );

  final DocumentReader reader;
  final AccessKey key;
  final Set<Info> want;
  final Set<Check> checks;
  final Duration timeout;
  final void Function(ReadProgress)? onProgress;
  final bool keepRawFiles;

  final _clock = Stopwatch();
  final _files = <int, Uint8List>{};
  final _partial = <int, Uint8List>{};
  final _sizes = <int, int>{};
  final _fileTimes = <String, Duration>{};
  final _missing = <int>{};
  List<_PlannedFile> _plan = const [];
  ChipApp? _app;

  /// Connections made, and how many times the card was lost. Progress
  /// shows attempt 1 + lost; a reconnection after a chip error does not
  /// count, since the card did not move.
  var _connections = 0;
  var _lost = 0;
  var _chipRetries = 0;
  var _unlockedOnce = false;
  Uint8List? _challenge;
  Uint8List? _aaSignature;
  Duration? _aaTime;

  Logger get _log => DocumentReader._log;

  Future<IdDocument> run() async {
    final state = await reader._nfc.state();
    if (state == NfcState.notSupported) throw const NfcNotSupported();
    if (state == NfcState.off) throw const NfcOff();
    final bac = BacKey(
      key.documentNumber,
      toYYMMDD(key.dateOfBirth),
      toYYMMDD(key.dateOfExpiry),
    );
    _clock.start();
    var bigChunk = reader._bigReads[key.documentNumber] ?? ChipSession.bigChunk;
    late Duration waiting, onCard, unlock;
    late int commands;
    while (true) {
      _connections++;
      _checkCancelled();
      _emit(ReadStage.waitingForCard);
      final left = timeout - _clock.elapsed;
      final waited = Stopwatch()..start();
      final CardLink link;
      try {
        if (left <= Duration.zero) throw const NoCardException();
        link = await reader._nfc.connect(
          timeout: left,
          commandTimeout: const Duration(seconds: 5),
        );
      } on NoCardException {
        throw _connections == 1 ? const NoCardFound() : const CardMoved();
      } on ConnectCancelledException {
        throw const ReadCancelled();
      } on NfcUnavailableException catch (e) {
        throw e.state == NfcState.off
            ? const NfcOff()
            : const NfcNotSupported();
      }
      waiting = waited.elapsed;
      final onThisCard = Stopwatch()..start();
      final session = ChipSession(link, bigChunk: bigChunk);
      try {
        _emit(ReadStage.unlocking);
        final app = await session.selectApp(
          _app != null
              ? [_app!]
              : key.documentType == DocumentType.drivingLicence
              ? const [ChipApp.licence, ChipApp.icao]
              : const [ChipApp.icao, ChipApp.licence],
        );
        if (app == null) throw const UnsupportedDocument();
        if (_app == null) {
          _app = app;
          _plan = _planFor(app);
        }
        await session.unlock(bac);
        _unlockedOnce = true;
        unlock = onThisCard.elapsed;
        _log.info(
          'Connection $_connections: ${app.name} unlocked in '
          '${unlock.inMilliseconds} ms',
        );
        await _readFiles(session);
        onCard = onThisCard.elapsed;
        commands = session.commands;
        break;
      } on CardLostException catch (e) {
        _lost++;
        _log.info(
          'Connection $_connections: card lost after '
          '${onThisCard.elapsedMilliseconds} ms ($e)',
        );
      } on AccessDeniedException catch (e) {
        // Refused at the first unlock: the key is wrong. Refused later,
        // after the same key worked: the chip is in a bad state.
        if (!_unlockedOnce) throw const WrongKey();
        _retryChipError(ChipStatusException(e.sw, 'unlock again'));
      } on SecureMessagingException catch (e) {
        _retryChipError(ChipStatusException(Sw.smDataIncorrect, '$e'));
      } on ChipStatusException catch (e) {
        _retryChipError(e);
      } finally {
        bigChunk = session.bigReadSize;
        reader._bigReads[key.documentNumber] = bigChunk;
        try {
          await link.close();
        } on Object catch (e) {
          _log.fine('Close failed: $e');
        }
      }
    }

    _emit(ReadStage.checking, partial: _build());
    final checking = Stopwatch()..start();
    SecurityResult? security;
    if (checks.isNotEmpty) {
      final app = _app!;
      security = await verifyInBackground((
        checkChip: checks.contains(Check.chipGenuine),
        checkData: checks.contains(Check.dataAuthentic),
        aaKeyFile: _files[Files.aaKey(app)],
        aaChallenge: _challenge,
        aaSignature: _aaSignature,
        sod: _files[Files.sod],
        files: {
          for (final e in _files.entries)
            if (e.key != Files.sod && e.key != Files.com) e.key: e.value,
        },
        trusted: reader._trusted,
      ));
    }
    final timings = ReadTimings(
      waiting: waiting,
      onCard: onCard,
      unlock: unlock,
      files: Map.unmodifiable(_fileTimes),
      activeAuthentication: _aaTime,
      checks: checking.elapsed,
      attempts: _connections,
      commands: commands,
      bigReads: bigChunk > 0,
    );
    _log.info(
      'Read done: ${onCard.inMilliseconds} ms on the card, '
      '$commands commands, checks ${checking.elapsedMilliseconds} ms, '
      'big reads ${bigChunk > 0 ? '$bigChunk bytes' : 'off'}',
    );
    final doc = _build(security: security, timings: timings)!;
    _emit(ReadStage.done, partial: doc);
    return doc;
  }

  /// The files to read, small text files first and the photo last, so a
  /// card that moves loses as little as possible.
  List<_PlannedFile> _planFor(ChipApp app) {
    final text = <int>{
      for (final info in want) ...Files.textFor(app, info),
    }.toList()..sort();
    return [
      for (final sfi in text) (sfi: sfi, guess: 150),
      if (checks.contains(Check.chipGenuine))
        (sfi: Files.aaKey(app), guess: 200),
      if (checks.contains(Check.dataAuthentic)) (sfi: Files.sod, guess: 1800),
      if (want.contains(Info.signature))
        (sfi: Files.signature(app), guess: 5000),
      if (want.contains(Info.photo)) (sfi: Files.photo(app), guess: 15000),
    ];
  }

  Future<void> _readFiles(ChipSession session) async {
    final app = _app!;
    _emit(ReadStage.reading);
    for (final file in _plan) {
      _checkCancelled();
      final sfi = file.sfi;
      if (!_files.containsKey(sfi) && !_missing.contains(sfi)) {
        final watch = Stopwatch()..start();
        final name = Files.name(sfi);
        try {
          _files[sfi] = await session.readFile(
            sfi,
            have: _partial[sfi],
            onBytes: (soFar, total) {
              _sizes[sfi] = total;
              if (total > ChipSession.shortChunk) _partial[sfi] = soFar;
              _emit(ReadStage.reading);
            },
          );
          _sizes[sfi] = _files[sfi]!.length;
          if (app == ChipApp.licence) _logShapes(sfi);
        } on FileMissingException {
          _missing.add(sfi);
        } on FileLockedException {
          _missing.add(sfi);
        } finally {
          _fileTimes[name] =
              (_fileTimes[name] ?? Duration.zero) + watch.elapsed;
          if (_files.containsKey(sfi)) _partial.remove(sfi);
        }
        _log.info(
          '$name: ${_files.containsKey(sfi) ? '${_files[sfi]!.length} bytes' : 'not on the chip'} '
          'in ${watch.elapsedMilliseconds} ms',
        );
        _emit(ReadStage.reading, partial: _build());
      }
      if (sfi == Files.aaKey(app) && _aaSignature == null) {
        await _activeAuthentication(session);
      }
    }
    final check = app == ChipApp.licence
        ? licenceSelfCheck(_files)
        : icaoSelfCheck(_files);
    if (check != null) _log.info('${app.name.toUpperCase()} $check');
  }

  Future<void> _activeAuthentication(ChipSession session) async {
    final keyFile = _files[Files.aaKey(_app!)];
    if (keyFile == null) return;
    final int length;
    try {
      length = publicKeyOfDg15(keyFile).signatureLength;
    } on Object catch (e) {
      _log.info('Active Authentication key not usable: $e');
      return;
    }
    final watch = Stopwatch()..start();
    _challenge = Uint8List.fromList([
      for (var i = 0; i < 8; i++) reader._random.nextInt(256),
    ]);
    try {
      _aaSignature = await session.internalAuthenticate(_challenge!, length);
    } on ChipStatusException catch (e) {
      _log.info('Active Authentication refused: $e');
      _aaSignature = Uint8List(0);
    }
    _aaTime = watch.elapsed;
  }

  /// For mapping the licence: the layout of each value, content hidden.
  void _logShapes(int sfi) {
    if (sfi == Files.photo(ChipApp.licence) ||
        sfi == Files.signature(ChipApp.licence) ||
        sfi == Files.sod) {
      return;
    }
    for (final (tag, value) in tlvLeafBytes(_files[sfi]!)) {
      _log.fine('LICENCE DG$sfi $tag (${value.length}): ${shapeOf(value)}');
    }
  }

  /// A chip error: a new connection resets the chip's state, so try again
  /// (twice at most) before giving up.
  void _retryChipError(ChipStatusException e) {
    _log.info('Connection $_connections: chip error ($e)');
    if (_chipRetries++ >= 2) throw ChipError(e.sw, e.during);
  }

  void _checkCancelled() {
    if (reader._cancelled) throw const ReadCancelled();
  }

  IdDocument? _build({SecurityResult? security, ReadTimings? timings}) {
    final app = _app;
    if (app == null) return null;
    return buildDocument(
      app,
      want,
      _files,
      security: security,
      timings: timings,
      keepRawFiles: keepRawFiles,
    );
  }

  void _emit(ReadStage stage, {IdDocument? partial}) {
    final listener = onProgress;
    if (listener == null) return;
    var planned = 0, done = 0;
    for (final f in _plan) {
      final size = _sizes[f.sfi] ?? f.guess;
      planned += size;
      done += _files.containsKey(f.sfi) || _missing.contains(f.sfi)
          ? size
          : _partial[f.sfi]?.length ?? 0;
    }
    listener(
      ReadProgress(
        stage,
        attempt: 1 + _lost,
        fraction: stage == ReadStage.checking || stage == ReadStage.done
            ? 1
            : planned == 0
            ? 0
            : done / planned,
        partial: partial,
      ),
    );
  }
}
