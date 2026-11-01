import 'dart:typed_data';

import 'apdu.dart';
import 'bytes.dart';
import 'des.dart';

/// Thrown when a protected response fails its MAC or lacks its data
/// objects. The session keys can no longer be trusted.
class SecureMessagingException implements Exception {
  SecureMessagingException(this.message);
  final String message;

  @override
  String toString() => 'Secure messaging: $message';
}

/// 3DES secure messaging after BAC (ICAO 9303-11, 9.8): every command and
/// response is encrypted and MACed with the session keys, and a send
/// sequence counter (SSC) makes each message unique.
class SecureMessaging {
  SecureMessaging(Uint8List ksEnc, Uint8List ksMac, Uint8List ssc)
    : _enc = TripleDes(ksEnc),
      _mac = TripleDes(ksMac),
      _ssc = Uint8List.fromList(ssc);

  final TripleDes _enc;
  final TripleDes _mac;
  final Uint8List _ssc;

  /// Set when the chip answered without protection (an SM error such as
  /// 6987/6988, after which the chip drops the session keys).
  bool broken = false;

  Uint8List get ssc => Uint8List.fromList(_ssc);

  void _incrementSsc() {
    for (var i = _ssc.length - 1; i >= 0; i--) {
      _ssc[i] = (_ssc[i] + 1) & 0xFF;
      if (_ssc[i] != 0) break;
    }
  }

  /// The protected form of [command], ready to send.
  Uint8List wrap(CommandApdu command) {
    final cla = command.cla | 0x0C;
    final header = [cla, command.ins, command.p1, command.p2];
    final dataDo = BytesBuilder(copy: false);
    final data = command.data;
    if (data != null && data.isNotEmpty) {
      final encrypted = _enc.encrypt(pad(data));
      // Odd INS (READ BINARY B1) carries its data in DO85, without the
      // padding-indicator byte DO87 has.
      if (command.ins.isOdd) {
        dataDo.add(_tlv(0x85, encrypted));
      } else {
        dataDo.add(_tlv(0x87, [0x01, ...encrypted]));
      }
    }
    final le = <int>[];
    if (command.ne > 0) {
      if (command.isExtended) {
        final n = command.ne == 65536 ? 0 : command.ne;
        le.addAll(_tlv(0x97, [n >> 8, n & 0xFF]));
      } else {
        le.addAll(_tlv(0x97, [command.ne == 256 ? 0 : command.ne]));
      }
    }
    final dos = concat([dataDo.takeBytes(), le]);
    _incrementSsc();
    final mac = _mac.mac(pad([..._ssc, ...pad(header), ...dos]));
    final body = concat([dos, _tlv(0x8E, mac)]);
    return CommandApdu(
      cla,
      command.ins,
      command.p1,
      command.p2,
      data: body,
      ne: command.isExtended ? 65536 : 256,
    ).encode();
  }

  /// Checks and decrypts a protected response.
  ResponseApdu unwrap(Uint8List raw) {
    final plain = ResponseApdu.parse(raw);
    if (plain.data.isEmpty) {
      // No data objects: the chip did not protect this answer.
      broken = true;
      return plain;
    }
    Uint8List? dataDo, statusDo, macValue;
    var encrypted = Uint8List(0);
    var withIndicator = false;
    final body = plain.data;
    for (var i = 0; i < body.length;) {
      final start = i;
      final tag = body[i++];
      var length = body[i++];
      if (length == 0x81) {
        length = body[i++];
      } else if (length == 0x82) {
        length = body[i] << 8 | body[i + 1];
        i += 2;
      } else if (length > 0x82) {
        throw SecureMessagingException('length form ${toHex([length])}');
      }
      if (i + length > body.length) {
        throw SecureMessagingException('truncated data object');
      }
      final whole = Uint8List.sublistView(body, start, i + length);
      final value = Uint8List.sublistView(body, i, i + length);
      switch (tag) {
        case 0x87:
          dataDo = whole;
          encrypted = Uint8List.sublistView(value, 1);
          withIndicator = true;
        case 0x85:
          dataDo = whole;
          encrypted = value;
        case 0x99:
          statusDo = whole;
        case 0x8E:
          macValue = value;
      }
      i += length;
    }
    if (macValue == null) {
      broken = true;
      throw SecureMessagingException('no MAC in the response');
    }
    _incrementSsc();
    final covered = concat([_ssc, dataDo ?? const [], statusDo ?? const []]);
    if (!sameBytes(_mac.mac(pad(covered)), macValue)) {
      broken = true;
      throw SecureMessagingException('wrong MAC in the response');
    }
    var data = Uint8List(0);
    if (encrypted.isNotEmpty) {
      final decrypted = _enc.decrypt(encrypted);
      data = withIndicator ? unpad(decrypted) : decrypted;
    }
    final sw = statusDo != null && statusDo.length == 4
        ? statusDo[2] << 8 | statusDo[3]
        : plain.sw;
    return ResponseApdu(data, sw);
  }

  static Uint8List _tlv(int tag, List<int> value) {
    final n = value.length;
    final length = n < 0x80
        ? [n]
        : n < 0x100
        ? [0x81, n]
        : [0x82, n >> 8, n & 0xFF];
    return Uint8List.fromList([tag, ...length, ...value]);
  }
}
