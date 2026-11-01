import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../access_key.dart';
import '../chip/apdu.dart';
import '../chip/bac.dart';
import '../chip/bytes.dart';
import '../chip/chip_session.dart';
import '../chip/des.dart';
import '../document.dart';
import '../lds/mrz_text.dart';
import '../nfc/transport.dart';
import 'demo_files.dart';
import 'demo_licence.dart';

/// The key of [FakeCard.demo].
final demoKey = AccessKey(
  documentNumber: demoNumber,
  dateOfBirth: demoBirth,
  dateOfExpiry: demoExpiry,
);

/// A document chip simulated in Dart. It answers the reader's commands the
/// way a real chip does: BAC, secure messaging, READ BINARY by short file
/// identifier and offset (short and extended), and Active Authentication.
/// For tests, and for demos without a card.
class FakeCard {
  /// [files] are the chip files by short file identifier (data group
  /// number; 0x1D for EF.SOD). [aaModulus] and [aaPrivateExponent] are the
  /// RSA key behind DG15, if the chip does Active Authentication.
  FakeCard({
    required AccessKey key,
    required Map<int, Uint8List> files,
    DocumentType type = DocumentType.idCard,
    this.aaModulus,
    this.aaPrivateExponent,
    this.extendedLength = true,
    this.maxResponse = 0x10000,
    this.stuckAfterRefusal = false,
    Random? random,
  }) : _key = BacKey(
         key.documentNumber,
         toYYMMDD(key.dateOfBirth),
         toYYMMDD(key.dateOfExpiry),
       ),
       _files = Map.unmodifiable(files),
       _aid =
           (type == DocumentType.drivingLicence
                   ? ChipApp.licence
                   : ChipApp.icao)
               .aid,
       _random = random ?? Random();

  /// A made-up ID card of the fictional state UTO ("SPECIMEN DEMO"), with
  /// photo, signature, details, Active Authentication and an EF.SOD signed
  /// under [demoCountryCertificate]. Unlocks with [demoKey].
  factory FakeCard.demo({
    bool extendedLength = true,
    int maxResponse = 0x10000,
    bool stuckAfterRefusal = false,
  }) => FakeCard(
    key: demoKey,
    files: demoFiles,
    aaModulus: demoAaModulus,
    aaPrivateExponent: demoAaPrivateExponent,
    extendedLength: extendedLength,
    maxResponse: maxResponse,
    stuckAfterRefusal: stuckAfterRefusal,
  );

  /// A made-up driving licence with the layout of the Algerian one.
  /// Unlocks with [demoLicenceKey].
  factory FakeCard.demoLicence() => FakeCard(
    key: demoLicenceKey,
    files: demoLicenceFiles(),
    type: DocumentType.drivingLicence,
  );

  final BacKey _key;
  final Map<int, Uint8List> _files;
  final List<int> _aid;
  final Random _random;
  final BigInt? aaModulus;
  final BigInt? aaPrivateExponent;

  /// Whether the chip takes extended-length commands. One that does not
  /// answers them in clear with 6700 and drops its session, like real
  /// chips do.
  final bool extendedLength;

  /// The most data the chip returns in one answer. Asked for more, it
  /// answers 6700 (protected) and forgets its current file.
  final int maxResponse;

  /// After refusing an extended-length command, the chip answers nothing
  /// but 6985 until it is powered again (the next connection).
  final bool stuckAfterRefusal;

  /// What reached the chip, one short line per command, like
  /// `READ DG2 @223 2048`. Tests use it to check what was read.
  final List<String> log = [];

  /// When set, the card leaves the phone after this many more commands.
  int? loseAfter;

  // Chip state, reset when the card is powered again.
  bool _selected = false;
  Uint8List? _rndIc;
  TripleDes? _enc, _mac;
  Uint8List? _ssc;
  int? _current;
  bool _stuck = false;

  void _powerOn() {
    _stuck = false;
    _selected = false;
    _rndIc = null;
    _enc = _mac = null;
    _ssc = null;
    _current = null;
  }

  Uint8List _answer(Uint8List apdu) {
    if (_stuck) return _sw(Sw.conditionsNotSatisfied);
    final c = _Parsed(apdu);
    if (c.extended && !extendedLength) {
      log.add('REFUSED extended command');
      _enc = _mac = null;
      _current = null;
      _stuck = stuckAfterRefusal;
      return _sw(Sw.wrongLength);
    }
    if (c.cla & 0x0C == 0x0C) {
      if (_enc == null) return _sw(Sw.smDataMissing);
      return _protected(c);
    }
    return switch (c.ins) {
      0xA4 when c.p1 == 0x04 => _select(c.data),
      0x84 => _getChallenge(),
      0x82 => _externalAuthenticate(c.data),
      _ => _sw(Sw.securityNotSatisfied),
    };
  }

  Uint8List _select(Uint8List aid) {
    _powerOn();
    _selected = sameBytes(aid, _aid);
    log.add('SELECT ${_selected ? 'ok' : 'other app'}');
    return _sw(_selected ? Sw.ok : Sw.fileNotFound);
  }

  Uint8List _getChallenge() {
    log.add('GET CHALLENGE');
    _rndIc = _randomBytes(8);
    return concat([_rndIc!, _swBytes(Sw.ok)]);
  }

  Uint8List _externalAuthenticate(Uint8List data) {
    log.add('EXTERNAL AUTHENTICATE');
    final rndIc = _rndIc;
    if (!_selected || rndIc == null || data.length != 40) {
      return _sw(Sw.conditionsNotSatisfied);
    }
    final enc = TripleDes(_key.enc), mac = TripleDes(_key.mac);
    final eIfd = data.sublist(0, 32);
    if (!sameBytes(mac.mac(pad(eIfd)), data.sublist(32))) {
      return _sw(Sw.authenticationFailed);
    }
    final s = enc.decrypt(eIfd);
    final rndIfd = s.sublist(0, 8);
    if (!sameBytes(s.sublist(8, 16), rndIc)) {
      return _sw(Sw.authenticationFailed);
    }
    final kIc = _randomBytes(16);
    final eIc = enc.encrypt(concat([rndIc, rndIfd, kIc]));
    final seed = xorBytes(s.sublist(16, 32), kIc);
    _enc = TripleDes(deriveKey(seed, 1));
    _mac = TripleDes(deriveKey(seed, 2));
    _ssc = concat([rndIc.sublist(4, 8), rndIfd.sublist(4, 8)]);
    return concat([eIc, mac.mac(pad(eIc)), _swBytes(Sw.ok)]);
  }

  Uint8List _protected(_Parsed c) {
    final dos = _dataObjects(c.data);
    _incrementSsc();
    final header = pad([c.cla, c.ins, c.p1, c.p2]);
    final covered = concat([
      _ssc!,
      header,
      dos[0x87]?.whole ?? dos[0x85]?.whole ?? const [],
      dos[0x97]?.whole ?? const [],
    ]);
    final mac = dos[0x8E]?.value;
    if (mac == null || !sameBytes(_mac!.mac(pad(covered)), mac)) {
      _enc = _mac = null; // a real chip drops the session keys
      return _sw(Sw.smDataIncorrect);
    }
    var data = Uint8List(0);
    if (dos[0x87] case final d?) {
      data = unpad(_enc!.decrypt(d.value.sublist(1)));
    } else if (dos[0x85] case final d?) {
      data = _enc!.decrypt(d.value);
    }
    var ne = 0;
    if (dos[0x97] case final d?) {
      final v = d.value;
      ne = v.length == 1
          ? (v[0] == 0 ? 256 : v[0])
          : ((v[0] << 8 | v[1]) == 0 ? 65536 : v[0] << 8 | v[1]);
    }
    final (out, sw) = _run(c, data, ne);
    _incrementSsc();
    final dataDo = out.isEmpty
        ? Uint8List(0)
        : _tlv(0x87, [0x01, ..._enc!.encrypt(pad(out))]);
    final statusDo = _tlv(0x99, [sw >> 8, sw & 0xFF]);
    final responseMac = _mac!.mac(pad(concat([_ssc!, dataDo, statusDo])));
    return concat([dataDo, statusDo, _tlv(0x8E, responseMac), _swBytes(Sw.ok)]);
  }

  (Uint8List, int) _run(_Parsed c, Uint8List data, int ne) {
    if (ne > maxResponse) {
      log.add('REFUSED ne=$ne');
      _current = null;
      return (Uint8List(0), Sw.wrongLength);
    }
    switch (c.ins) {
      case 0xB0:
        int offset;
        if (c.p1 & 0x80 != 0) {
          _current = c.p1 & 0x1F;
          offset = c.p2;
        } else {
          offset = (c.p1 & 0x7F) << 8 | c.p2;
        }
        return _readBinary(offset, ne);
      case 0xB1:
        final offset = data.length >= 3 && data[0] == 0x54
            ? data.sublist(2, 2 + data[1]).fold<int>(0, (n, b) => n << 8 | b)
            : 0;
        final (bytes, sw) = _readBinary(offset, ne - 4);
        return (bytes.isEmpty ? bytes : _tlv(0x53, bytes), sw);
      case 0x88:
        log.add('INTERNAL AUTHENTICATE');
        return _internalAuthenticate(data);
      case 0xA4 when c.p1 == 0x02 && data.length == 2 && data[0] == 0x01:
        _current = data[1];
        log.add('SELECT FILE ${_name(data[1])}');
        return (
          Uint8List(0),
          _files.containsKey(data[1]) ? Sw.ok : Sw.fileNotFound,
        );
    }
    return (Uint8List(0), Sw.insNotSupported);
  }

  (Uint8List, int) _readBinary(int offset, int ne) {
    final sfi = _current;
    final file = sfi == null ? null : _files[sfi];
    log.add('READ ${sfi == null ? '?' : _name(sfi)} @$offset $ne');
    if (file == null) return (Uint8List(0), Sw.fileNotFound);
    if (offset > file.length) return (Uint8List(0), Sw.offsetOutsideFile);
    final n = min(ne, file.length - offset);
    return (
      Uint8List.sublistView(file, offset, offset + n),
      n < ne ? Sw.endOfFile : Sw.ok,
    );
  }

  (Uint8List, int) _internalAuthenticate(Uint8List challenge) {
    final n = aaModulus, d = aaPrivateExponent;
    if (n == null || d == null) return (Uint8List(0), Sw.insNotSupported);
    // ISO/IEC 9796-2 scheme 1 with SHA-1: 6A ‖ M1 ‖ SHA-1(M1 ‖ challenge) ‖ BC.
    final k = (n.bitLength + 7) ~/ 8;
    final m1 = _randomBytes(k - 22);
    final f = concat([
      [0x6A],
      m1,
      sha1Of(concat([m1, challenge])),
      [0xBC],
    ]);
    final s = _toBigInt(f).modPow(d, n);
    return (_fromBigInt(s, k), Sw.ok);
  }

  void _incrementSsc() {
    final ssc = _ssc!;
    for (var i = ssc.length - 1; i >= 0; i--) {
      ssc[i] = (ssc[i] + 1) & 0xFF;
      if (ssc[i] != 0) break;
    }
  }

  Uint8List _randomBytes(int n) =>
      Uint8List.fromList([for (var i = 0; i < n; i++) _random.nextInt(256)]);

  static String _name(int sfi) => switch (sfi) {
    0x1D => 'EF.SOD',
    0x1E => 'EF.COM',
    _ => 'DG$sfi',
  };

  static Uint8List _sw(int sw) => _swBytes(sw);
  static Uint8List _swBytes(int sw) => Uint8List.fromList([sw >> 8, sw & 0xFF]);

  static Uint8List _tlv(int tag, List<int> value) {
    final n = value.length;
    return Uint8List.fromList([
      tag,
      if (n < 0x80)
        n
      else if (n < 0x100) ...[
        0x81,
        n,
      ] else ...[
        0x82,
        n >> 8,
        n & 0xFF,
      ],
      ...value,
    ]);
  }

  static Map<int, ({Uint8List whole, Uint8List value})> _dataObjects(
    Uint8List body,
  ) {
    final out = <int, ({Uint8List whole, Uint8List value})>{};
    for (var i = 0; i < body.length;) {
      final start = i;
      final tag = body[i++];
      var length = body[i++];
      if (length == 0x81) {
        length = body[i++];
      } else if (length == 0x82) {
        length = body[i] << 8 | body[i + 1];
        i += 2;
      }
      out[tag] = (
        whole: Uint8List.sublistView(body, start, i + length),
        value: Uint8List.sublistView(body, i, i + length),
      );
      i += length;
    }
    return out;
  }

  static BigInt _toBigInt(List<int> bytes) =>
      bytes.fold(BigInt.zero, (n, b) => n << 8 | BigInt.from(b));

  static Uint8List _fromBigInt(BigInt n, int length) {
    final out = Uint8List(length);
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (n & BigInt.from(0xFF)).toInt();
      n = n >> 8;
    }
    return out;
  }
}

/// A command split into its parts.
class _Parsed {
  factory _Parsed(Uint8List a) {
    var data = Uint8List(0);
    if (a.length > 5 && a[4] == 0) {
      // Extended: 00 Lc1 Lc2 data [Le1 Le2], or 00 Le1 Le2.
      if (a.length > 7) {
        final lc = a[5] << 8 | a[6];
        data = Uint8List.sublistView(a, 7, 7 + lc);
      }
    } else if (a.length > 5) {
      data = Uint8List.sublistView(a, 5, 5 + a[4]);
    }
    return _Parsed._(a[0], a[1], a[2], a[3], data, a.length > 5 && a[4] == 0);
  }

  _Parsed._(this.cla, this.ins, this.p1, this.p2, this.data, this.extended);

  final int cla, ins, p1, p2;
  final Uint8List data;

  /// Extended-length format.
  final bool extended;
}

/// An [NfcTransport] with a [FakeCard] on it, or with no card.
class FakeNfc implements NfcTransport {
  FakeNfc(
    this.card, {
    this.nfcState = NfcState.on,
    this.phoneExtendedLength = true,
    this.commandDelay = Duration.zero,
  });

  final FakeCard? card;
  NfcState nfcState;

  /// Whether the phone sends extended-length commands.
  final bool phoneExtendedLength;

  /// Time each command takes, to make a demo look real.
  final Duration commandDelay;
  bool holding = false;
  Completer<void>? _cancel;

  @override
  Future<NfcState> state() async => nfcState;

  @override
  Future<void> openSettings() async {}

  @override
  Future<void> hold(bool on) async => holding = on;

  @override
  Future<CardLink> connect({
    required Duration timeout,
    required Duration commandTimeout,
  }) async {
    final card = this.card;
    if (card == null) {
      final cancel = _cancel = Completer<void>();
      final cancelled = await Future.any([
        cancel.future.then((_) => true),
        Future<bool>.delayed(timeout, () => false),
      ]);
      throw cancelled
          ? const ConnectCancelledException()
          : const NoCardException();
    }
    card._powerOn();
    return _FakeLink(this, card);
  }

  @override
  Future<void> cancel() async => _cancel?.complete();
}

class _FakeLink implements CardLink {
  _FakeLink(this._nfc, this._card);

  final FakeNfc _nfc;
  final FakeCard _card;
  bool _gone = false;

  @override
  bool get extendedLength => _nfc.phoneExtendedLength;

  @override
  Future<Uint8List> transceive(Uint8List command) async {
    if (_nfc.commandDelay > Duration.zero) {
      await Future<void>.delayed(_nfc.commandDelay);
    }
    final left = _card.loseAfter;
    if (_gone || left != null && left <= 0) {
      _gone = true;
      _card.loseAfter = null; // back on the phone for the next connect
      throw const CardLostException(lost: true);
    }
    if (left != null) _card.loseAfter = left - 1;
    return _card._answer(command);
  }

  @override
  Future<void> close() async {}
}
