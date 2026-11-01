import 'dart:typed_data';

import 'bytes.dart';

/// Status words the reader acts on (ISO/IEC 7816-4).
abstract final class Sw {
  static const ok = 0x9000;
  static const endOfFile = 0x6282; // fewer bytes than asked: the file ended
  static const authenticationFailed = 0x6300;
  static const wrongLength = 0x6700;
  static const securityNotSatisfied = 0x6982;
  static const conditionsNotSatisfied = 0x6985;
  static const smDataMissing = 0x6987;
  static const smDataIncorrect = 0x6988;
  static const wrongData = 0x6A80;
  static const functionNotSupported = 0x6A81;
  static const fileNotFound = 0x6A82;
  static const wrongP1P2 = 0x6A86;
  static const offsetOutsideFile = 0x6B00;
  static const insNotSupported = 0x6D00;
  static const claNotSupported = 0x6E00;

  static String name(int sw) =>
      sw.toRadixString(16).padLeft(4, '0').toUpperCase();
}

/// An ISO/IEC 7816-4 command.
class CommandApdu {
  const CommandApdu(
    this.cla,
    this.ins,
    this.p1,
    this.p2, {
    this.data,
    this.ne = 0,
  });

  final int cla, ins, p1, p2;
  final Uint8List? data;

  /// Bytes expected back: 0 for none, up to 256 in a short command (256 is
  /// sent as Le 00), up to 65536 in an extended one (65536 is Le 0000).
  final int ne;

  int get lc => data?.length ?? 0;

  bool get isExtended => lc > 255 || ne > 256;

  Uint8List encode() {
    final out = BytesBuilder(copy: false)..add([cla, ins, p1, p2]);
    final extended = isExtended;
    if (lc > 0) {
      out.add(extended ? [0, lc >> 8, lc & 0xFF] : [lc]);
      out.add(data!);
    }
    if (ne > 0) {
      if (extended) {
        final le = ne == 65536 ? 0 : ne;
        if (lc == 0) out.addByte(0);
        out.add([le >> 8, le & 0xFF]);
      } else {
        out.addByte(ne == 256 ? 0 : ne);
      }
    }
    return out.takeBytes();
  }

  /// Header and lengths only, never the data, for logs.
  String describe() =>
      '${toHex([cla, ins, p1, p2])} lc=$lc ne=$ne${isExtended ? ' ext' : ''}';
}

/// A response: data and the status word.
class ResponseApdu {
  ResponseApdu(this.data, this.sw);

  factory ResponseApdu.parse(Uint8List raw) {
    if (raw.length < 2) throw const FormatException('Response without status');
    final n = raw.length - 2;
    return ResponseApdu(
      Uint8List.sublistView(raw, 0, n),
      raw[n] << 8 | raw[n + 1],
    );
  }

  final Uint8List data;
  final int sw;
}
