import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/ecc/ecc_fp.dart' as fp;
import 'package:pointycastle/export.dart' as pc;

import 'der.dart';
import 'document.dart';

/// Checks on the chip's security data (ICAO 9303 part 11):
/// - EF.SOD holds a hash of every data group, signed by the issuing
///   country's Document Signer certificate (passive authentication);
/// - DG15 holds the public key of a private key that never leaves the chip,
///   which signs a random challenge (active authentication), so a copied
///   chip cannot pass.

const _hashOids = {
  '1.3.14.3.2.26': 'SHA-1',
  '2.16.840.1.101.3.4.2.4': 'SHA-224',
  '2.16.840.1.101.3.4.2.1': 'SHA-256',
  '2.16.840.1.101.3.4.2.2': 'SHA-384',
  '2.16.840.1.101.3.4.2.3': 'SHA-512',
};

Uint8List digest(String hash, List<int> data) {
  final h = switch (hash) {
    'SHA-1' => crypto.sha1,
    'SHA-224' => crypto.sha224,
    'SHA-256' => crypto.sha256,
    'SHA-384' => crypto.sha384,
    'SHA-512' => crypto.sha512,
    _ => throw UnsupportedError('Hash $hash'),
  };
  return Uint8List.fromList(h.convert(data).bytes);
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// A SubjectPublicKeyInfo: the public key in a certificate or in DG15.
class PublicKey {
  PublicKey.parse(Der spki)
      : algorithm = spki[0][0].oid,
        params = spki[0].children.length > 1 ? spki[0][1] : null,
        keyBits = spki[1].bits;

  static const rsaOid = '1.2.840.113549.1.1.1';
  static const ecOid = '1.2.840.10045.2.1';

  final String algorithm;
  final Der? params;
  final Uint8List keyBits;

  bool get isRsa => algorithm == rsaOid;
  bool get isEc => algorithm == ecOid;

  /// Modulus and public exponent.
  (BigInt, BigInt) get rsa {
    final key = Der.parse(keyBits);
    return (key[0].integer, key[1].integer);
  }

  pc.ECDomainParameters get ecParams {
    final p = params!;
    if (p.tag == 0x06) {
      final curve = _namedCurves[p.oid];
      if (curve == null) throw UnsupportedError('Curve ${p.oid}');
      return curve();
    }
    // Explicit parameters, common in passport certificates: version,
    // fieldID {prime-field, p}, curve {a, b}, base point, order, cofactor.
    final items = p.children;
    final curve = fp.ECCurve(items[1][1].integer,
        bytesToBigInt(items[2][0].value), bytesToBigInt(items[2][1].value));
    return pc.ECDomainParametersImpl('explicit', curve,
        curve.decodePoint(items[3].value)!, items[4].integer,
        items.length > 5 ? items[5].integer : null);
  }

  /// Length of a signature made with this key, in bytes.
  int get signatureLength => isRsa
      ? (rsa.$1.bitLength + 7) ~/ 8
      : 2 * ((ecParams.n.bitLength + 7) ~/ 8);

  String get description => isRsa
      ? 'RSA ${rsa.$1.bitLength}-bit'
      : isEc
          ? 'ECDSA ${ecParams.n.bitLength}-bit'
          : algorithm;
}

final _namedCurves = <String, pc.ECDomainParameters Function()>{
  '1.2.840.10045.3.1.7': () => pc.ECCurve_prime256v1(),
  '1.3.132.0.33': () => pc.ECCurve_secp224r1(),
  '1.3.132.0.34': () => pc.ECCurve_secp384r1(),
  '1.3.132.0.35': () => pc.ECCurve_secp521r1(),
  '1.3.36.3.3.2.8.1.1.5': () => pc.ECCurve_brainpoolp224r1(),
  '1.3.36.3.3.2.8.1.1.7': () => pc.ECCurve_brainpoolp256r1(),
  '1.3.36.3.3.2.8.1.1.9': () => pc.ECCurve_brainpoolp320r1(),
  '1.3.36.3.3.2.8.1.1.11': () => pc.ECCurve_brainpoolp384r1(),
  '1.3.36.3.3.2.8.1.1.13': () => pc.ECCurve_brainpoolp512r1(),
};

/// An X.509 certificate, reduced to what we show and use.
class Certificate {
  factory Certificate.parse(Der cert) {
    final tbs = cert[0].children;
    var i = tbs[0].tag == 0xA0 ? 1 : 0; // optional version
    final serial = tbs[i++]
        .value
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    i++; // signature algorithm, repeated after the signed part
    final issuer = tbs[i++];
    final validity = tbs[i++];
    final subject = tbs[i++];
    return Certificate._(
      serial: serial,
      issuer: _name(issuer),
      subject: _name(subject),
      notBefore: validity[0].time,
      notAfter: validity[1].time,
      publicKey: PublicKey.parse(tbs[i]),
      issuerDer: issuer.encoded,
      subjectDer: subject.encoded,
      signed: cert[0].encoded,
      signatureAlgorithm: cert[1],
      signatureValue: cert[2].bits,
    );
  }

  Certificate._({
    required this.serial,
    required this.issuer,
    required this.subject,
    required this.notBefore,
    required this.notAfter,
    required this.publicKey,
    required this.issuerDer,
    required this.subjectDer,
    required this.signed,
    required this.signatureAlgorithm,
    required this.signatureValue,
  });

  final String serial;
  final String issuer;
  final String subject;
  final DateTime notBefore;
  final DateTime notAfter;
  final PublicKey publicKey;

  /// Encoded names, compared byte for byte to match a certificate to its
  /// issuer.
  final Uint8List issuerDer;
  final Uint8List subjectDer;

  /// The signed part (tbsCertificate) and its signature.
  final Uint8List signed;
  final Der signatureAlgorithm;
  final Uint8List signatureValue;

  /// Whether [issuerCert] issued and signed this certificate. Null when
  /// the algorithm is not supported here.
  bool? isSignedBy(Certificate issuerCert) {
    if (!_same(issuerDer, issuerCert.subjectDer)) return false;
    return verifySignature(issuerCert.publicKey, signatureAlgorithm, 'SHA-256',
        signed, signatureValue);
  }
}

const _nameParts = {
  '2.5.4.3': 'CN',
  '2.5.4.5': 'SERIALNUMBER',
  '2.5.4.6': 'C',
  '2.5.4.7': 'L',
  '2.5.4.8': 'ST',
  '2.5.4.10': 'O',
  '2.5.4.11': 'OU',
  '1.2.840.113549.1.9.1': 'E',
};

String _name(Der name) => [
      for (final rdn in name.children)
        for (final part in rdn.children)
          '${_nameParts[part[0].oid] ?? part[0].oid}=${part[1].text}',
    ].join(', ');

/// EF.SOD: the signed list of data group hashes (a CMS SignedData).
class Sod {
  factory Sod.parse(Uint8List bytes) {
    var root = Der.parse(bytes);
    if (root.tag == 0x77) root = Der.parse(root.value); // ICAO wrapper
    final signedData = root[1][0].children;
    final content = signedData[2][1][0].value; // [0] EXPLICIT OCTET STRING
    Certificate? signer;
    Der? signerInfos;
    for (final item in signedData.skip(3)) {
      if (item.tag == 0xA0) signer = Certificate.parse(item[0]);
      if (item.tag == 0x31) signerInfos = item;
    }
    final info = signerInfos![0].children;
    var i = 2; // after version and signer id
    final digestAlgorithm = _hashOids[info[i++][0].oid] ?? 'unknown';
    final attributes = info[i].tag == 0xA0 ? info[i++] : null;
    final signatureAlgorithm = info[i++];
    final signature = info[i].value;

    final lds = Der.parse(content).children; // LDSSecurityObject
    return Sod._(
      hashAlgorithm: _hashOids[lds[1][0].oid] ?? 'unknown',
      hashes: {for (final h in lds[2].children) h[0].integer.toInt(): h[1].value},
      signer: signer,
      digestAlgorithm: digestAlgorithm,
      attributes: attributes,
      signatureAlgorithm: signatureAlgorithm,
      signature: signature,
      content: content,
    );
  }

  Sod._({
    required this.hashAlgorithm,
    required this.hashes,
    required this.signer,
    required this.digestAlgorithm,
    required this.attributes,
    required this.signatureAlgorithm,
    required this.signature,
    required this.content,
  });

  /// Hash used for the data groups, and the hash of each data group by
  /// number.
  final String hashAlgorithm;
  final Map<int, Uint8List> hashes;

  /// The Document Signer certificate, when EF.SOD carries it.
  final Certificate? signer;
  final String digestAlgorithm;
  final Der? attributes;
  final Der signatureAlgorithm;
  final Uint8List signature;

  /// The signed LDS security object.
  final Uint8List content;

  /// For each data group read (by number), whether its hash matches.
  Map<int, bool> checkHashes(Map<int, Uint8List> files) => {
        for (final MapEntry(key: dg, value: bytes) in files.entries)
          if (hashes.containsKey(dg))
            dg: _same(digest(hashAlgorithm, bytes), hashes[dg]!),
      };

  /// Whether [signer] really signed the hashes. Null when there is no
  /// signer certificate or its algorithm is not supported here.
  bool? signatureValid() {
    final key = signer?.publicKey;
    if (key == null) return null;
    var signed = content;
    final attrs = attributes;
    if (attrs != null) {
      // The signature covers the attributes, and their messageDigest
      // covers the content.
      final md = _attribute(attrs, '1.2.840.113549.1.9.4');
      if (md == null || !_same(md.value, digest(digestAlgorithm, content))) {
        return false;
      }
      // Signed as a SET (tag 31), not with the [0] tag it is stored under.
      signed = Uint8List.fromList(attrs.encoded)..[0] = 0x31;
    }
    return verifySignature(
        key, signatureAlgorithm, digestAlgorithm, signed, signature);
  }

  static Der? _attribute(Der attrs, String oid) {
    for (final a in attrs.children) {
      if (a[0].oid == oid) return a[1][0];
    }
    return null;
  }
}

const _rsaHashes = {
  '1.2.840.113549.1.1.5': 'SHA-1',
  '1.2.840.113549.1.1.14': 'SHA-224',
  '1.2.840.113549.1.1.11': 'SHA-256',
  '1.2.840.113549.1.1.12': 'SHA-384',
  '1.2.840.113549.1.1.13': 'SHA-512',
};
const _ecdsaHashes = {
  '1.2.840.10045.4.1': 'SHA-1',
  '1.2.840.10045.4.3.1': 'SHA-224',
  '1.2.840.10045.4.3.2': 'SHA-256',
  '1.2.840.10045.4.3.3': 'SHA-384',
  '1.2.840.10045.4.3.4': 'SHA-512',
};
const _rsaPssOid = '1.2.840.113549.1.1.10';

/// Checks [signature] over [data]. [algorithm] is the AlgorithmIdentifier;
/// plain rsaEncryption uses [fallbackHash]. Null when the algorithm is not
/// supported here.
bool? verifySignature(PublicKey key, Der algorithm, String fallbackHash,
    Uint8List data, Uint8List signature) {
  final oid = algorithm[0].oid;
  if (key.isRsa) {
    final (n, e) = key.rsa;
    if (oid == _rsaPssOid) {
      var hash = 'SHA-1';
      var saltLength = 20;
      // RSASSA-PSS-params: [0] hash, [1] mask generation, [2] salt length.
      final params = algorithm.children.length > 1 ? algorithm[1] : null;
      for (final p in params?.children ?? const <Der>[]) {
        if (p.tag == 0xA0) hash = _hashOids[p[0][0].oid] ?? hash;
        if (p.tag == 0xA2) saltLength = p[0].integer.toInt();
      }
      return _rsaPss(n, e, hash, saltLength, data, signature);
    }
    final hash = oid == PublicKey.rsaOid ? fallbackHash : _rsaHashes[oid];
    if (hash == null) return null;
    return _rsaPkcs1(n, e, hash, data, signature);
  }
  if (key.isEc) {
    final hash = _ecdsaHashes[oid];
    if (hash == null) return null;
    final rs = Der.parse(signature);
    return _ecdsa(key, digest(hash, data), rs[0].integer, rs[1].integer);
  }
  return null;
}

/// RSASSA-PKCS1-v1_5: 00 01 FF…FF 00 DigestInfo(hash).
bool _rsaPkcs1(
    BigInt n, BigInt e, String hash, Uint8List data, Uint8List signature) {
  final k = (n.bitLength + 7) ~/ 8;
  final em = bigIntToBytes(bytesToBigInt(signature).modPow(e, n), k);
  if (em[0] != 0 || em[1] != 1) return false;
  var i = 2;
  while (i < k && em[i] == 0xFF) {
    i++;
  }
  if (i < 10 || i >= k || em[i] != 0) return false;
  final info = Der.parse(em, i + 1);
  return info.end == k &&
      _hashOids[info[0][0].oid] == hash &&
      _same(info[1].value, digest(hash, data));
}

/// RSASSA-PSS (RFC 8017, 9.1.2), with MGF1 on the same hash.
bool _rsaPss(BigInt n, BigInt e, String hash, int saltLength, Uint8List data,
    Uint8List signature) {
  final emBits = n.bitLength - 1;
  final emLen = (emBits + 7) ~/ 8;
  final hLen = digest(hash, const []).length;
  final m = bytesToBigInt(signature).modPow(e, n);
  if (m.bitLength > emBits) return false;
  final em = bigIntToBytes(m, emLen);
  if (emLen < hLen + saltLength + 2 || em.last != 0xBC) return false;
  final dbLen = emLen - hLen - 1;
  final h = em.sublist(dbLen, dbLen + hLen);
  final zeroBits = 8 * emLen - emBits;
  if (em[0] & (0xFF << (8 - zeroBits)) & 0xFF != 0) return false;
  final mask = _mgf1(hash, h, dbLen);
  final db = Uint8List(dbLen);
  for (var i = 0; i < dbLen; i++) {
    db[i] = em[i] ^ mask[i];
  }
  db[0] &= 0xFF >> zeroBits;
  final padding = emLen - hLen - saltLength - 2;
  for (var i = 0; i < padding; i++) {
    if (db[i] != 0) return false;
  }
  if (db[padding] != 1) return false;
  final salt = db.sublist(dbLen - saltLength);
  return _same(h, digest(hash, [...Uint8List(8), ...digest(hash, data), ...salt]));
}

Uint8List _mgf1(String hash, List<int> seed, int length) {
  final out = BytesBuilder();
  for (var c = 0; out.length < length; c++) {
    out.add(digest(hash,
        [...seed, c >> 24 & 0xFF, c >> 16 & 0xFF, c >> 8 & 0xFF, c & 0xFF]));
  }
  return out.takeBytes().sublist(0, length);
}

bool _ecdsa(PublicKey key, Uint8List hash, BigInt r, BigInt s) {
  final params = key.ecParams;
  final q = params.curve.decodePoint(key.keyBits);
  if (q == null) return false;
  final signer = pc.ECDSASigner() // no digest: we pass the hash
    ..init(false, pc.PublicKeyParameter<pc.ECPublicKey>(pc.ECPublicKey(q, params)));
  return signer.verifySignature(hash, pc.ECSignature(r, s));
}

/// The Active Authentication key in DG15.
PublicKey publicKeyOfDg15(Uint8List dg15) {
  var root = Der.parse(dg15);
  if (root.tag == 0x6F) root = Der.parse(root.value);
  return PublicKey.parse(root);
}

const _trailerHashes = {
  0x33: 'SHA-1',
  0x34: 'SHA-256',
  0x35: 'SHA-512',
  0x36: 'SHA-384',
  0x38: 'SHA-224',
};

/// Checks the chip's answer to INTERNAL AUTHENTICATE with [challenge]. RSA
/// chips sign with ISO/IEC 9796-2 scheme 1 (6A ‖ M1 ‖ hash(M1 ‖ challenge)
/// ‖ trailer), EC chips with plain ECDSA (r ‖ s). Null when unsupported.
bool? verifyActiveAuthentication(
    Uint8List dg15, Uint8List challenge, Uint8List signature) {
  final key = publicKeyOfDg15(dg15);
  if (key.isRsa) {
    final (n, e) = key.rsa;
    final k = (n.bitLength + 7) ~/ 8;
    var f = bigIntToBytes(bytesToBigInt(signature).modPow(e, n), k);
    var start = 0;
    while (start < f.length && f[start] == 0) {
      start++;
    }
    f = f.sublist(start);
    if (f.length < 3 || f[0] != 0x6A) return false;
    final String hash;
    final int trailer;
    if (f.last == 0xBC) {
      hash = 'SHA-1';
      trailer = 1;
    } else if (f.last == 0xCC) {
      final named = _trailerHashes[f[f.length - 2]];
      if (named == null) return null;
      hash = named;
      trailer = 2;
    } else {
      return false;
    }
    final dEnd = f.length - trailer;
    final dStart = dEnd - digest(hash, const []).length;
    if (dStart < 1) return false;
    final m1 = f.sublist(1, dStart);
    return _same(
        f.sublist(dStart, dEnd), digest(hash, [...m1, ...challenge]));
  }
  if (key.isEc) {
    // The hash is named in DG14, which not every chip has; a valid
    // signature under any standard hash proves the same thing.
    final half = signature.length ~/ 2;
    final r = bytesToBigInt(signature.sublist(0, half));
    final s = bytesToBigInt(signature.sublist(half));
    for (final hash in ['SHA-1', 'SHA-224', 'SHA-256', 'SHA-384', 'SHA-512']) {
      if (_ecdsa(key, digest(hash, challenge), r, s)) return true;
    }
    return false;
  }
  return null;
}

/// What the checks need, all sendable to an isolate.
typedef VerifyInput = ({
  bool checkChip,
  bool checkData,
  Uint8List? aaKeyFile,
  Uint8List? aaChallenge,
  Uint8List? aaSignature,
  Uint8List? sod,
  Map<int, Uint8List> files,
  List<Uint8List> trusted,
});

/// [verifyDocument] on a background isolate. The closure is made here and
/// not in the caller: a closure sent to an isolate takes its scope's whole
/// context along, and in a widget method that context holds the State
/// (unsendable).
Future<SecurityResult> verifyInBackground(VerifyInput input) =>
    Isolate.run(() => verifyDocument(input));

/// Runs the checks asked for in [input]. [VerifyInput.files] are the data
/// groups read, by number.
SecurityResult verifyDocument(VerifyInput input) {
  var chipGenuine = CheckStatus.notChecked;
  String? chipKey;
  if (input.checkChip) {
    final keyFile = input.aaKeyFile;
    final signature = input.aaSignature;
    if (keyFile == null) {
      chipGenuine = CheckStatus.notSupported;
    } else {
      try {
        chipKey = publicKeyOfDg15(keyFile).description;
        final ok = signature == null
            ? false
            : verifyActiveAuthentication(keyFile, input.aaChallenge!, signature);
        chipGenuine = switch (ok) {
          true => CheckStatus.passed,
          false => CheckStatus.failed,
          null => CheckStatus.notSupported,
        };
      } on Object {
        chipGenuine = CheckStatus.failed;
      }
    }
  }
  if (!input.checkData) {
    return SecurityResult(chipGenuine: chipGenuine, chipKey: chipKey);
  }
  final sodBytes = input.sod;
  if (sodBytes == null) {
    return SecurityResult(
      chipGenuine: chipGenuine,
      chipKey: chipKey,
      dataUnchanged: CheckStatus.notSupported,
      issuerSignature: CheckStatus.notSupported,
      countryCertificate: CheckStatus.notSupported,
    );
  }
  final sod = Sod.parse(sodBytes);
  final hashes = sod.checkHashes(input.files);
  final changed = [
    for (final dg in hashes.keys.toList()..sort())
      if (!hashes[dg]!) 'DG$dg',
  ];
  final signer = sod.signer;
  var country = CheckStatus.notChecked;
  if (signer == null) {
    country = CheckStatus.notSupported;
  } else if (input.trusted.isNotEmpty) {
    country = CheckStatus.failed;
    for (final der in input.trusted) {
      final Certificate csca;
      try {
        csca = Certificate.parse(Der.parse(der));
      } on Object {
        continue;
      }
      final ok = signer.isSignedBy(csca);
      if (ok == true) {
        country = CheckStatus.passed;
        break;
      }
      if (ok == null) country = CheckStatus.notSupported;
    }
  }
  return SecurityResult(
    chipGenuine: chipGenuine,
    chipKey: chipKey,
    dataUnchanged: hashes.isEmpty
        ? CheckStatus.notSupported
        : changed.isEmpty
            ? CheckStatus.passed
            : CheckStatus.failed,
    changedFiles: changed,
    issuerSignature: switch (sod.signatureValid()) {
      true => CheckStatus.passed,
      false => CheckStatus.failed,
      null => CheckStatus.notSupported,
    },
    countryCertificate: country,
    documentSigner: signer == null
        ? null
        : CertificateInfo(
            subject: signer.subject,
            issuer: signer.issuer,
            serialNumber: signer.serial,
            validFrom: signer.notBefore,
            validTo: signer.notAfter,
            keyDescription: signer.publicKey.description,
          ),
  );
}
