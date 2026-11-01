import 'dart:math';
import 'dart:ui' as ui;

import 'package:dmrtd/dmrtd.dart';
import 'package:dmrtd/internal.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_nfc_kit/flutter_nfc_kit.dart';
import 'package:dz_id_reader/dz_id_reader.dart';
import 'package:logging/logging.dart';

import 'scan_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // The scanner maps its on-screen card outline to the camera frame, which
  // assumes a portrait screen.
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // FINE logs every chip command: handy in debug, but it slows down a
  // release build. dmrtd keeps keys and card data out of logs unless
  // sensitive logging is turned on, which we never do.
  Logger.root.level = kReleaseMode ? Level.INFO : Level.FINE;
  Logger.root.onRecord.listen(
    (r) => debugPrint('${r.level.name} ${r.loggerName}: ${r.message}'),
  );
  runApp(const App());
  warmUpOcr();
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DZ ID Reader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.green),
      home: const HomePage(),
    );
  }
}

const _dgNames = {
  0x61: 'DG1 (MRZ)',
  0x75: 'DG2 (photo)',
  0x63: 'DG3 (fingerprints)',
  0x76: 'DG4 (iris)',
  0x65: 'DG5',
  0x66: 'DG6',
  0x67: 'DG7 (signature)',
  0x68: 'DG8',
  0x69: 'DG9',
  0x6A: 'DG10',
  0x6B: 'DG11 (personal details)',
  0x6C: 'DG12 (document details)',
  0x6D: 'DG13 (country specific)',
  0x6E: 'DG14 (security)',
  0x6F: 'DG15 (active auth)',
  0x70: 'DG16',
};

// ICAO 9303 part 10 tags inside DG11 and DG12.
const _tagNames = {
  '5F0E': 'full name',
  '5F0F': 'other name',
  '5F10': 'personal number',
  '5F2B': 'full date of birth',
  '5F11': 'place of birth',
  '5F42': 'address',
  '5F12': 'telephone',
  '5F13': 'profession',
  '5F14': 'title',
  '5F15': 'personal summary',
  '5F16': 'proof of citizenship (image)',
  '5F17': 'other travel documents',
  '5F18': 'custody information',
  '5F19': 'issuing authority',
  '5F26': 'date of issue',
  '5F1A': 'other person',
  '5F1B': 'endorsements / observations',
  '5F1C': 'tax / exit requirements',
  '5F1D': 'image of front',
  '5F1E': 'image of rear',
  '5F55': 'personalization date/time',
  '5F56': 'personalization system serial',
};

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _docNumber = TextEditingController();
  final _dob = TextEditingController();
  final _doe = TextEditingController();
  // See MainActivity.holdNfc: stops Android's own "cannot read NFC tag"
  // toast when the card touches the phone outside of a read.
  static const _nfcHold = MethodChannel('dz_id_reader');

  bool _reading = false;
  String _status = '';
  bool _statusIsError = false;
  final _steps = <String>[];
  final _fields = <(String, String)>[];
  final _images = <(String, ui.Image)>[];
  // Security checks: title, detail, passed (null: could not check).
  final _checks = <(String, String, bool?)>[];
  // Bumped by every read, so pictures still decoding from an older read
  // are dropped.
  int _readId = 0;
  final _random = Random.secure();

  @override
  void initState() {
    super.initState();
    _holdNfc();
  }

  Future<void> _holdNfc() async {
    try {
      await _nfcHold.invokeMethod('hold');
    } catch (_) {}
  }

  @override
  void dispose() {
    _clearImages();
    _docNumber.dispose();
    _dob.dispose();
    _doe.dispose();
    super.dispose();
  }

  /// Accepts YYYY.MM.DD (as printed on the card) or DD.MM.YYYY, with
  /// '.', '/', '-' or a space between the parts.
  DateTime? _parseDate(String text) {
    const sep = r'[/.\- ]';
    final s = text.trim();
    int year, month, day;
    final yearFirst =
        RegExp('^(\\d{4})$sep(\\d{1,2})$sep(\\d{1,2})\$').firstMatch(s);
    final dayFirst =
        RegExp('^(\\d{1,2})$sep(\\d{1,2})$sep(\\d{4})\$').firstMatch(s);
    if (yearFirst != null) {
      year = int.parse(yearFirst[1]!);
      month = int.parse(yearFirst[2]!);
      day = int.parse(yearFirst[3]!);
    } else if (dayFirst != null) {
      day = int.parse(dayFirst[1]!);
      month = int.parse(dayFirst[2]!);
      year = int.parse(dayFirst[3]!);
    } else {
      return null;
    }
    final date = DateTime(year, month, day);
    // DateTime rolls 31/02 over to March; reject that.
    if (date.day != day || date.month != month) return null;
    return date;
  }

  String _fmt(DateTime d) =>
      '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';

  void _setStatus(String text, {bool error = false}) {
    setState(() {
      _status = text;
      _statusIsError = error;
    });
  }

  void _clearImages() {
    for (final (_, image) in _images) {
      image.dispose();
    }
    _images.clear();
  }

  /// Empties the results of the previous read (or the previous attempt).
  void _clearResults() {
    _readId++;
    setState(() {
      _fields.clear();
      _checks.clear();
      _clearImages();
    });
  }

  void _step(String text) {
    debugPrint('STEP $text'); // steps hold timings and errors, no card data
    setState(() => _steps.add(text));
  }

  void _field(String label, String? value) {
    if (value == null || value.trim().isEmpty) return;
    setState(() => _fields.add((label, value.trim())));
  }

  String _friendlyError(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('timeout')) return 'No card found. Try again and hold it still.';
    if (cardMovedAway(e)) {
      return 'The card moved away. Keep it still until it says Done.';
    }
    if (s.contains('security status not satisfied')) {
      return 'The chip refused the key. Check the 3 fields.';
    }
    if (s.contains('not found')) {
      return 'This is not an ID card or passport chip. Try Check chip type.';
    }
    return 'Read failed: $e';
  }

  /// Reads an ISO 18013 driving licence whose app is already selected.
  /// This test assumes its BAP key is built like the ICAO BAC key (document
  /// number + birth date + expiry date). Data groups are shown tag by tag
  /// because their layout differs from ID cards; the log gets tags and sizes
  /// only, never values.
  Future<void> _readLicence(MrtdApi api, DBAKey key, Stopwatch watch) async {
    _step('Driving licence app found (ISO 18013-3)');
    try {
      await api.initSessionViaBAC(key);
    } on ICCError catch (e) {
      throw Exception(
          'The licence refused a key made like the ID card key (${e.sw})');
    }
    _step('Unlocked with BAP in ${watch.elapsedMilliseconds} ms');
    final files = FileReader(api, () async {
      api.icc.sm = null;
      await selectLicenceApp(api);
      await api.initSessionViaBAC(key);
    });
    // Every file the licence lets us read. Biometric ones answer "security
    // status not satisfied" (they need government keys).
    final read = <int, Uint8List>{};
    final pictures = <(String, FoundImage)>[];
    Uint8List? sod;
    for (final sfi in [0x1E, for (var dg = 1; dg <= 14; dg++) dg, 0x1D]) {
      final name = switch (sfi) { 0x1E => 'EF.COM', 0x1D => 'EF.SOD', _ => 'DG$sfi' };
      try {
        final data = await files.read(sfi,
            onProgress: (done, total) =>
                _setStatus('Reading $name… ${100 * done ~/ total}%'));
        final images = findImages(data);
        final leaves = tlvLeaves(data);
        debugPrint('LICENCE $name: ${data.length} bytes, '
            'tags ${leaves.map((l) => l.$1).join(' ')}, '
            '${images.length} pictures');
        _step('$name: ${data.length} bytes');
        if (sfi == 0x1D) {
          sod = data;
        } else if (sfi != 0x1E) {
          read[sfi] = data;
          pictures.addAll([for (final image in images) ('$name picture', image)]);
          for (final (tag, value) in leaves) {
            if (images.isEmpty || value.length < 200) _field('$name $tag', value);
          }
        }
      } on ICCError catch (e) {
        debugPrint('LICENCE $name: ${e.sw}');
        _step('$name: not readable (${e.sw})');
      }
    }
    _afterRead(pictures, read, sod, null);
  }

  static const _knownApps = {
    'A0000002471001': 'ID card / passport app (ICAO 9303)',
    'A0000002480200': 'driving licence app (ISO 18013-3)',
    'A00000045645444C2D3031': 'EU driving licence app',
  };

  /// Asks the chip which applications it has, without any key. Used to learn
  /// how the driving licence chip works. Shows only application IDs and
  /// status words, no personal data.
  Future<void> _probe() async {
    setState(() {
      _reading = true;
      _steps.clear();
    });
    _clearResults();
    _setStatus('Hold the document flat on the back of the phone…');
    try {
      final tag = await FlutterNfcKit.poll(
        timeout: const Duration(seconds: 30),
        androidCheckNDEF: false,
        readIso15693: false,
      );
      _setStatus('Card found. Keep it still…');
      _step('Chip: ${tag.standard}, ${tag.type.name}');
      if (tag.type != NFCTagType.iso7816) {
        throw Exception('Not a smart card chip');
      }
      Future<String> send(String apdu) async {
        final r = (await FlutterNfcKit.transceive(apdu)).toUpperCase();
        debugPrint('PROBE $apdu -> $r');
        return r;
      }

      String sw(String r) => r.length >= 4 ? r.substring(r.length - 4) : r;

      await send('00A4000C023F00'); // select the master file
      // EF.DIR (SFI 1E) lists the card's applications. Some cards store it
      // as records instead of a plain file.
      var dir = await send('00B09E0000');
      if (sw(dir) != '9000') {
        final records = StringBuffer();
        for (var i = 1; i <= 8; i++) {
          final r = await send('00B2${i.toRadixString(16).padLeft(2, '0')}F400');
          if (sw(r) != '9000') break;
          records.write(r.substring(0, r.length - 4));
        }
        if (records.isNotEmpty) dir = '${records}9000';
      }
      if (sw(dir) == '9000') {
        final hex = dir.substring(0, dir.length - 4);
        final bytes = [
          for (var i = 0; i + 1 < hex.length; i += 2)
            int.parse(hex.substring(i, i + 2), radix: 16),
        ];
        final aids = <String>[];
        for (var i = 0; i + 1 < bytes.length; i++) {
          final len = bytes[i + 1];
          if (bytes[i] == 0x4F && len >= 5 && i + 2 + len <= bytes.length) {
            aids.add(bytes
                .sublist(i + 2, i + 2 + len)
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join()
                .toUpperCase());
            i += 1 + len;
          }
        }
        _step('EF.DIR lists: ${aids.isEmpty ? 'nothing' : aids.map((a) => _knownApps[a] == null ? a : '$a (${_knownApps[a]})').join(', ')}');
      } else {
        _step('No EF.DIR (${sw(dir)})');
      }

      final access = await send('00B09C0000'); // EF.CardAccess = PACE info
      _step(sw(access) == '9000'
          ? 'EF.CardAccess: yes, PACE supported'
          : 'EF.CardAccess: no (${sw(access)}), so no PACE');

      for (final app in _knownApps.entries) {
        final lc = (app.key.length ~/ 2).toRadixString(16).padLeft(2, '0');
        var r = await send('00A4040C$lc${app.key}');
        // Some chips refuse "no response data" (P2=0C) but accept P2=00.
        if (sw(r) != '9000' && sw(r) != '6A82') {
          r = await send('00A40400$lc${app.key}00');
        }
        final found = sw(r) == '9000' || sw(r).startsWith('61');
        _step('${app.value}: ${found ? 'present' : 'not found (${sw(r)})'}');
      }
      _setStatus('Done. You can remove the card.');
    } catch (e) {
      _step('Error: $e');
      _setStatus(_friendlyError(e), error: true);
    } finally {
      await _holdNfc();
      setState(() => _reading = false);
    }
  }

  Future<void> _scan() async {
    FocusScope.of(context).unfocus();
    final result = await Navigator.push<ScanResult>(
      context,
      MaterialPageRoute(builder: (_) => const ScanPage()),
    );
    if (result == null || !mounted) return;
    _docNumber.text = result.key.documentNumber;
    _dob.text = _fmt(result.key.dateOfBirth);
    _doe.text = _fmt(result.key.dateOfExpiry);
    await _read(scanSummary: result.summary);
  }

  Future<void> _read({String? scanSummary}) async {
    FocusScope.of(context).unfocus();
    final doc = _docNumber.text.trim().toUpperCase();
    final dob = _parseDate(_dob.text);
    final doe = _parseDate(_doe.text);
    if (doc.isEmpty || dob == null || doe == null) {
      final wrong = [
        if (doc.isEmpty) 'document number',
        if (dob == null) 'date of birth',
        if (doe == null) 'expiry date',
      ];
      _setStatus('Check the ${wrong.join(', ')}. Dates as YYYY.MM.DD.',
          error: true);
      return;
    }

    switch (await NfcProvider.nfcStatus) {
      case NfcStatus.notSupported:
        _setStatus('This phone has no NFC.', error: true);
        return;
      case NfcStatus.disabled:
        _setStatus('NFC is off. Turn it on in Settings.', error: true);
        return;
      case NfcStatus.enabled:
        break;
    }

    setState(() {
      _reading = true;
      _steps.clear();
    });
    _clearResults();
    if (scanSummary != null) _step(scanSummary);
    _setStatus('Touch the card to the back of the phone');

    final deadline = DateTime.now().add(const Duration(seconds: 30));
    try {
      // When the card slips off mid-read, wait for it again instead of
      // making the user press Read again.
      for (var attempt = 1;; attempt++) {
        // A fresh provider per attempt, because we never call its
        // disconnect() (see the finally block below).
        final nfc = FastNfcProvider();
        try {
          final left = deadline.difference(DateTime.now());
          if (left <= Duration.zero) throw Exception('timeout');
          await nfc.connect(timeout: left);
          await _readChip(nfc, doc, dob, doe);
          break;
        } catch (e) {
          if (!cardMovedAway(e)) rethrow;
          _step('Attempt $attempt: the card moved away');
          _setStatus('The card moved. Put it back and hold it still');
          _clearResults();
        }
      }
    } catch (e) {
      _step('Error: $e');
      _setStatus(_friendlyError(e), error: true);
    } finally {
      // Hand reader mode straight to the ignoring callback instead of
      // disconnecting: disconnect turns reader mode off, and in the ~100 ms
      // before hold turns it back on Android grabs the card that is still
      // on the phone and shows its "cannot read NFC tag" toast.
      await _holdNfc();
      setState(() => _reading = false);
    }
  }

  /// Reads the chip that is on the phone now. Throws when the card moves
  /// away, so [_read] can wait for it again.
  Future<void> _readChip(
      ComProvider nfc, String doc, DateTime dob, DateTime doe) async {
    final watch = Stopwatch()..start();
    _setStatus('Reading… keep the card still');
    final api = MrtdApi(nfc);
    final bacKey = DBAKey(doc, dob, doe);

    // EF.CardAccess sits in the master file, which is the current file when
    // the chip powers up, so a single command tells whether it offers PACE.
    EfCardAccess? cardAccess;
    try {
      cardAccess =
          EfCardAccess.fromBytes(await api.readFileBySFI(EfCardAccess.SFI));
    } on ComProviderError {
      rethrow;
    } on Exception {
      // No EF.CardAccess: the chip only does BAC.
    }

    Future<void> Function()? reopen;
    var method = 'BAC';
    if (cardAccess != null && cardAccess.isPaceInfoSet) {
      final access = cardAccess;
      final paceKey = DBAKey(doc, dob, doe, paceMode: true);
      Future<void> openWithPace() async {
        api.icc.sm = null;
        await api.selectMasterFile();
        await api.initSessionViaPACE(paceKey, access);
        await api.selectEMrtdApplication();
      }

      try {
        await openWithPace();
        reopen = openWithPace;
        method = 'PACE';
      } on ComProviderError {
        rethrow;
      } on Exception catch (e) {
        _step('PACE failed, trying BAC: $e');
        api.icc.sm = null;
      }
    }
    if (reopen == null) {
      try {
        await api.selectEMrtdApplication();
      } on ICCError {
        if (await selectLicenceApp(api)) {
          await _readLicence(api, bacKey, watch);
          _step('Done in ${watch.elapsedMilliseconds} ms');
          _setStatus('Done. You can remove the card.');
          return;
        }
        throw Exception(
            'This is not an ID card, passport or driving licence chip.');
      }
      await api.initSessionViaBAC(bacKey);
      reopen = () async {
        api.icc.sm = null;
        await api.selectEMrtdApplication();
        await api.initSessionViaBAC(bacKey);
      };
    }
    _step('Unlocked with $method in ${watch.elapsedMilliseconds} ms');
    final files = FileReader(api, reopen);

    final com = EfCOM.fromBytes(await files.read(EfCOM.SFI));
    final tags = com.dgTags.map((t) => t.value).toSet();
    _step('On the chip: ${[
      for (final MapEntry(key: tag, value: name) in _dgNames.entries)
        if (tags.contains(tag)) name,
      for (final tag in tags)
        if (!_dgNames.containsKey(tag)) '0x${tag.toRadixString(16)}',
    ].join(', ')}');
    // Raw bytes of every data group read, by number, for the hash check.
    final read = <int, Uint8List>{};

    if (com.dgTags.contains(EfDG1.TAG)) {
      final dg1 = await files.read(EfDG1.SFI);
      read[1] = dg1;
      final mrz = EfDG1.fromBytes(dg1).mrz;
      _field('Last name', mrz.lastName);
      _field('First name', mrz.firstName);
      _field('Sex', mrz.gender);
      _field('Date of birth', _fmt(mrz.dateOfBirth));
      _field('Nationality', mrz.nationality);
      _field('Document code', mrz.documentCode);
      _field('Document number', mrz.documentNumber);
      _field('Issuing country', mrz.country);
      _field('Expiry date', _fmt(mrz.dateOfExpiry));
      _field('MRZ optional data 1', mrz.optionalData.replaceAll('<', ' '));
      _field('MRZ optional data 2', mrz.optionalData2?.replaceAll('<', ' '));
      _step('DG1 read at ${watch.elapsedMilliseconds} ms');
    }

    // DG11 (extra personal details), DG12 (document details) and DG13
    // (country specific) are shown tag by tag: the library's DG11 and DG12
    // parsers only know some tags and showed nothing for this card.
    for (final (tag, sfi) in [
      (EfDG11.TAG, EfDG11.SFI),
      (EfDG12.TAG, EfDG12.SFI),
      (EfDG13.TAG, EfDG13.SFI),
    ]) {
      if (!com.dgTags.contains(tag)) continue;
      final dg = _dgNames[tag.value]!.split(' ').first;
      try {
        final raw = await files.read(sfi);
        read[sfi] = raw;
        // 5C is the list of tags present, 02 a count; neither is data.
        final leaves =
            tlvLeaves(raw).where((l) => l.$1 != '5C' && l.$1 != '02');
        debugPrint('ID $dg: ${raw.length} bytes, '
            'tags ${leaves.map((l) => l.$1).join(' ')}');
        for (final (t, value) in leaves) {
          _field('$dg ${_tagNames[t] ?? 'tag $t'}', value.replaceAll('<', ' '));
        }
        _step('$dg read at ${watch.elapsedMilliseconds} ms');
      } on ComProviderError {
        rethrow;
      } on Exception catch (e) {
        _step('$dg could not be read: $e');
      }
    }

    // Active Authentication: the chip signs a random challenge with a
    // private key that cannot be copied out of it, so a cloned chip fails.
    (String, String, bool?)? genuine;
    if (com.dgTags.contains(EfDG15.TAG)) {
      try {
        final dg15 = await files.read(EfDG15.SFI);
        read[15] = dg15;
        final key = publicKeyOfDg15(dg15);
        final challenge =
            Uint8List.fromList([for (var i = 0; i < 8; i++) _random.nextInt(256)]);
        final signature = await api.activeAuthenticate(challenge,
            sigLength: key.signatureLength);
        final ok = verifyActiveAuthentication(dg15, challenge, signature);
        genuine = (
          'Chip is genuine (Active Authentication)',
          ok == true
              ? 'The chip signed a random challenge with its ${key.description} key'
              : 'The signature on the challenge did not check out (${key.description} key)',
          ok,
        );
        _step('Active Authentication: ${ok == true ? 'passed' : 'failed'} '
            'at ${watch.elapsedMilliseconds} ms');
      } on ComProviderError {
        rethrow;
      } on Exception catch (e) {
        genuine = ('Chip is genuine (Active Authentication)', 'Not done: $e', null);
        _step('Active Authentication not done: $e');
      }
    }

    // EF.SOD: the issuer's signature over the hash of every data group.
    Uint8List? sod;
    try {
      sod = await files.read(EfSOD.SFI);
      _step('EF.SOD read at ${watch.elapsedMilliseconds} ms (${sod.length} bytes)');
    } on ComProviderError {
      rethrow;
    } on Exception catch (e) {
      _step('EF.SOD could not be read: $e');
    }

    // The pictures last: the photo is the biggest file by far.
    final pictures = <(String, FoundImage)>[];
    for (final (tag, sfi, what) in [
      (EfDG7.TAG, EfDG7.SFI, 'Signature'),
      (EfDG2.TAG, EfDG2.SFI, 'Photo'),
    ]) {
      if (!com.dgTags.contains(tag)) continue;
      try {
        final raw = await files.read(sfi,
            onProgress: (done, total) => _setStatus(
                'Reading the ${what.toLowerCase()}… ${100 * done ~/ total}%'));
        read[sfi] = raw;
        final found = findImages(raw);
        pictures.addAll([for (final image in found) (what, image)]);
        _step('$what read at ${watch.elapsedMilliseconds} ms '
            '(${raw.length} bytes, ${found.map((i) => i.kind.name).join(', ')})');
      } on ComProviderError {
        rethrow;
      } on Exception catch (e) {
        _step('$what could not be read: $e');
      }
    }

    _step('Done in ${watch.elapsedMilliseconds} ms (one-command reads '
        '${files.oneCommandReads ? 'on' : 'refused by this chip'})');
    _setStatus('Done. You can remove the card.');
    _afterRead(pictures, read, sod, genuine);
  }

  /// Work that needs no card: decoding the pictures and checking the
  /// signatures, off the UI thread.
  Future<void> _afterRead(List<(String, FoundImage)> pictures,
      Map<int, Uint8List> files, Uint8List? sod, (String, String, bool?)? genuine) async {
    final id = _readId;
    setState(() {
      if (genuine != null) _checks.add(genuine);
    });
    try {
      final watch = Stopwatch()..start();
      final report = await securityReportInBackground(sod, files);
      if (id != _readId || !mounted) return;
      setState(() => _checks.addAll(report));
      _step('Security checks took ${watch.elapsedMilliseconds} ms');
    } catch (e) {
      _step('Security checks failed: $e');
    }
    for (final (what, picture) in pictures) {
      try {
        final watch = Stopwatch()..start();
        final image = await decodeImage(picture);
        if (id != _readId || !mounted) {
          image.dispose();
          return;
        }
        setState(() => _images.add((what, image)));
        _step('$what decoded in ${watch.elapsedMilliseconds} ms '
            '(${picture.kind.name}, ${image.width}x${image.height})');
      } catch (e) {
        _step('$what could not be decoded: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Algerian ID – NFC test')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Press Scan and show the back of your ID card, or the photo '
              'page of your passport, to the camera. Then hold the document '
              'on the back of the phone.',
              style: theme.textTheme.bodyMedium,
            ),
            if (_reading) ...[
              const SizedBox(height: 16),
              _NfcPrompt(status: _status),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _reading ? null : _scan,
              icon: const Icon(Icons.document_scanner_outlined),
              label: const Text('Scan document'),
            ),
            const SizedBox(height: 24),
            Text('Or type the 3 values', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _docNumber,
              enabled: !_reading,
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Document number',
                hintText: '9 characters',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _dob,
              enabled: !_reading,
              keyboardType: TextInputType.datetime,
              decoration: const InputDecoration(
                labelText: 'Date of birth',
                hintText: 'YYYY.MM.DD',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _doe,
              enabled: !_reading,
              keyboardType: TextInputType.datetime,
              decoration: const InputDecoration(
                labelText: 'Expiry date',
                hintText: 'YYYY.MM.DD',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _reading ? null : _read,
              icon: _reading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.nfc),
              label: Text(_reading ? 'Reading…' : 'Read chip'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _reading ? null : _probe,
              icon: const Icon(Icons.search),
              label: const Text('Check chip type (no key needed)'),
            ),
            if (!_reading && _status.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: _statusIsError ? theme.colorScheme.error : null,
                ),
              ),
            ],
            if (_images.isNotEmpty) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 16,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.end,
                children: [
                  for (final (what, image) in _images)
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: RawImage(
                            image: image,
                            height: what == 'Photo' ? 200 : 80,
                            fit: BoxFit.contain,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(what, style: theme.textTheme.labelSmall),
                      ],
                    ),
                ],
              ),
            ],
            if (_fields.isNotEmpty) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final (label, value) in _fields)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(label, style: theme.textTheme.labelSmall),
                              SelectableText(value,
                                  style: theme.textTheme.bodyLarge),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            if (_checks.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Security', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Card(
                child: Column(
                  children: [
                    for (final (title, detail, passed) in _checks)
                      ListTile(
                        leading: Icon(
                          passed == null
                              ? Icons.help_outline
                              : passed
                                  ? Icons.verified
                                  : Icons.error,
                          color: passed == null
                              ? theme.colorScheme.outline
                              : passed
                                  ? Colors.green
                                  : theme.colorScheme.error,
                        ),
                        title: Text(title),
                        subtitle: Text(detail),
                      ),
                  ],
                ),
              ),
            ],
            if (_steps.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Steps', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              for (final s in _steps)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('• $s', style: theme.textTheme.bodySmall),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Big prompt shown while the app waits for the chip and reads it, so right
/// after the scan the user sees where to put the card.
class _NfcPrompt extends StatelessWidget {
  final String status;

  const _NfcPrompt({required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onPrimaryContainer;
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.contactless_outlined, size: 40, color: color),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(status,
                      style:
                          theme.textTheme.titleMedium?.copyWith(color: color)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Usually near the camera. Keep it still until it says Done.',
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
