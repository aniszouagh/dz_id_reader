import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha1;
import 'package:pointycastle/block/des_base.dart';

/// Two-key triple DES (K1, K2, K1) as BAC and its secure messaging use it
/// (ICAO 9303-11, 9.8): CBC with a zero IV for encryption, and ISO/IEC
/// 9797-1 MAC algorithm 3 (the "retail MAC") for integrity.
class TripleDes {
  TripleDes(Uint8List key) {
    if (key.length != 16) throw ArgumentError('3DES key must be 16 bytes');
    final k1 = Uint8List.sublistView(key, 0, 8);
    final k2 = Uint8List.sublistView(key, 8, 16);
    _e1 = _des.generateWorkingKey(true, k1);
    _d1 = _des.generateWorkingKey(false, k1);
    _e2 = _des.generateWorkingKey(true, k2);
    _d2 = _des.generateWorkingKey(false, k2);
  }

  static final _des = DesBase();
  late final List<int> _e1, _d1, _e2, _d2;
  final _block = Uint8List(8);

  /// CBC encryption of [data], whose length must be a multiple of 8.
  Uint8List encrypt(List<int> data) {
    final out = Uint8List(data.length);
    final chain = Uint8List(8);
    for (var i = 0; i < data.length; i += 8) {
      for (var j = 0; j < 8; j++) {
        _block[j] = data[i + j] ^ chain[j];
      }
      _des.desFunc(_e1, _block, 0, _block, 0);
      _des.desFunc(_d2, _block, 0, _block, 0);
      _des.desFunc(_e1, _block, 0, out, i);
      chain.setRange(0, 8, out, i);
    }
    return out;
  }

  /// CBC decryption of [data], whose length must be a multiple of 8.
  Uint8List decrypt(List<int> data) {
    final input = data is Uint8List ? data : Uint8List.fromList(data);
    final out = Uint8List(data.length);
    final chain = Uint8List(8);
    for (var i = 0; i < input.length; i += 8) {
      _des.desFunc(_d1, input, i, _block, 0);
      _des.desFunc(_e2, _block, 0, _block, 0);
      _des.desFunc(_d1, _block, 0, _block, 0);
      for (var j = 0; j < 8; j++) {
        out[i + j] = _block[j] ^ chain[j];
      }
      chain.setRange(0, 8, input, i);
    }
    return out;
  }

  /// Retail MAC of [padded] (already padded to a multiple of 8): single DES
  /// with K1 over every block, then DES-decrypt with K2 and encrypt with K1.
  Uint8List mac(List<int> padded) {
    final h = Uint8List(8);
    for (var i = 0; i < padded.length; i += 8) {
      for (var j = 0; j < 8; j++) {
        h[j] ^= padded[i + j];
      }
      _des.desFunc(_e1, h, 0, h, 0);
    }
    _des.desFunc(_d2, h, 0, h, 0);
    _des.desFunc(_e1, h, 0, h, 0);
    return h;
  }
}

/// ICAO 9303-11, 9.7.1: a 3DES key from [seed] and a counter (1 for
/// encryption, 2 for MAC), with DES parity bits set.
Uint8List deriveKey(List<int> seed, int counter) {
  final hash = sha1.convert([...seed, 0, 0, 0, counter]).bytes;
  final key = Uint8List.fromList(hash.sublist(0, 16));
  for (var i = 0; i < key.length; i++) {
    final b = key[i] & 0xFE;
    var ones = 0;
    for (var x = b; x != 0; x >>= 1) {
      ones += x & 1;
    }
    key[i] = b | (ones.isEven ? 1 : 0);
  }
  return key;
}

/// SHA-1 of [data], the hash BAC uses for its key seed.
Uint8List sha1Of(List<int> data) =>
    Uint8List.fromList(sha1.convert(data).bytes);

/// [a] XOR [b], both of the same length.
Uint8List xorBytes(List<int> a, List<int> b) =>
    Uint8List.fromList([for (var i = 0; i < a.length; i++) a[i] ^ b[i]]);
