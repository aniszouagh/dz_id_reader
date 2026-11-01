import 'dart:typed_data';

Uint8List hexToBytes(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList([
    for (var i = 0; i + 1 < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}

String toHex(Iterable<int> bytes) => bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join()
    .toUpperCase();

Uint8List concat(List<List<int>> parts) {
  final out = BytesBuilder(copy: false);
  for (final p in parts) {
    out.add(p);
  }
  return out.takeBytes();
}

/// ISO/IEC 9797-1 padding method 2: 0x80, then zeros up to a multiple of 8.
Uint8List pad(List<int> data) {
  final out = Uint8List((data.length ~/ 8 + 1) * 8);
  out.setRange(0, data.length, data);
  out[data.length] = 0x80;
  return out;
}

/// Removes [pad]'s padding.
Uint8List unpad(Uint8List data) {
  var i = data.length - 1;
  while (i >= 0 && data[i] == 0) {
    i--;
  }
  if (i < 0 || data[i] != 0x80) throw const FormatException('Bad padding');
  return Uint8List.sublistView(data, 0, i);
}

bool sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
