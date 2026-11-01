import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../lds/mrz_text.dart';
import 'apdu.dart';
import 'bytes.dart';
import 'des.dart';
import 'secure_messaging.dart';

/// The chip refused the key: the three values do not match the document.
class AccessDeniedException implements Exception {
  AccessDeniedException(this.sw);
  final int sw;

  @override
  String toString() => 'Access denied (${Sw.name(sw)})';
}

/// The chip answered a command with an error status.
class ChipStatusException implements Exception {
  ChipStatusException(this.sw, this.during);
  final int sw;
  final String during;

  @override
  String toString() => '$during: ${Sw.name(sw)}';
}

/// The BAC keys of a document (ICAO 9303-11, 9.7.1). The driving licence's
/// BAP derives them the same way from the same three values.
class BacKey {
  factory BacKey(String documentNumber, String birthYYMMDD, String expiryYYMMDD) {
    final number =
        documentNumber.length < 9 ? documentNumber.padRight(9, '<') : documentNumber;
    final info = '$number${checkDigit(number)}'
        '$birthYYMMDD${checkDigit(birthYYMMDD)}'
        '$expiryYYMMDD${checkDigit(expiryYYMMDD)}';
    final seed = Uint8List.sublistView(sha1Of(ascii.encode(info)), 0, 16);
    return BacKey._(seed, deriveKey(seed, 1), deriveKey(seed, 2));
  }

  BacKey._(this.seed, this.enc, this.mac);

  final Uint8List seed;
  final Uint8List enc;
  final Uint8List mac;
}

typedef SendPlain = Future<ResponseApdu> Function(CommandApdu command);

/// Terminal side of BAC (ICAO 9303-11, 9.7.2): proves both sides know the
/// key and agrees on session keys. [rndIfd] and [kIfd] are random unless a
/// test fixes them.
Future<SecureMessaging> bacAuthenticate(SendPlain send, BacKey key,
    {Random? random, Uint8List? rndIfd, Uint8List? kIfd}) async {
  final challenge = await send(const CommandApdu(0x00, 0x84, 0x00, 0x00, ne: 8));
  if (challenge.sw != Sw.ok || challenge.data.length != 8) {
    throw ChipStatusException(challenge.sw, 'GET CHALLENGE');
  }
  final rndIc = challenge.data;
  final rng = random ?? Random.secure();
  Uint8List randomBytes(int n) =>
      Uint8List.fromList([for (var i = 0; i < n; i++) rng.nextInt(256)]);
  final ourRnd = rndIfd ?? randomBytes(8);
  final ourK = kIfd ?? randomBytes(16);

  final enc = TripleDes(key.enc);
  final mac = TripleDes(key.mac);
  final eIfd = enc.encrypt(concat([ourRnd, rndIc, ourK]));
  final mIfd = mac.mac(pad(eIfd));
  final answer = await send(CommandApdu(0x00, 0x82, 0x00, 0x00,
      data: concat([eIfd, mIfd]), ne: 40));
  if (answer.sw != Sw.ok) throw AccessDeniedException(answer.sw);
  final r = answer.data;
  if (r.length != 40) throw ChipStatusException(answer.sw, 'EXTERNAL AUTHENTICATE');
  final eIc = Uint8List.sublistView(r, 0, 32);
  if (!sameBytes(mac.mac(pad(eIc)), Uint8List.sublistView(r, 32, 40))) {
    throw ChipStatusException(answer.sw, 'EXTERNAL AUTHENTICATE (MAC)');
  }
  final plain = enc.decrypt(eIc);
  if (!sameBytes(plain.sublist(0, 8), rndIc) ||
      !sameBytes(plain.sublist(8, 16), ourRnd)) {
    throw ChipStatusException(answer.sw, 'EXTERNAL AUTHENTICATE (nonces)');
  }
  final seed = xorBytes(ourK, plain.sublist(16, 32));
  return SecureMessaging(deriveKey(seed, 1), deriveKey(seed, 2),
      concat([rndIc.sublist(4, 8), ourRnd.sublist(4, 8)]));
}
