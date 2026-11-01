import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dz_id_reader/src/security.dart';

// Fixtures come from tool/make_test_fixtures.py (generated keys, no real
// document data).
Uint8List fixture(String name) =>
    File('test/fixtures/$name').readAsBytesSync();

void main() {
  final files = {1: fixture('dg1.bin'), 2: fixture('dg2.bin')};

  for (final name in ['rsa', 'rsa_pss', 'ec_named', 'ec_explicit']) {
    group('EF.SOD signed with $name', () {
      final sod = Sod.parse(fixture('sod_$name.bin'));

      test('lists the data group hashes', () {
        expect(sod.hashAlgorithm, 'SHA-256');
        expect(sod.hashes.keys, [1, 2]);
        expect(sod.checkHashes(files), {1: true, 2: true});
      });

      test('notices a changed data group', () {
        final changed = Uint8List.fromList(files[2]!)..[10] ^= 1;
        expect(sod.checkHashes({1: files[1]!, 2: changed}), {1: true, 2: false});
      });

      test('verifies the signer certificate signature', () {
        expect(sod.signer!.subject,
            'C=UT, O=Test State, CN=Test Document Signer');
        expect(sod.signer!.notAfter.isAfter(sod.signer!.notBefore), isTrue);
        expect(sod.signatureValid(), isTrue);
      });

      test('rejects a changed signature', () {
        final bytes = fixture('sod_$name.bin');
        // Flip a bit near the end, inside the signature value.
        final broken = Sod.parse(Uint8List.fromList(bytes)..[bytes.length - 3] ^= 1);
        expect(broken.signatureValid(), isFalse);
      });
    });
  }

  group('Active Authentication', () {
    final challenge = fixture('aa_challenge.bin');

    test('RSA with SHA-1 (trailer BC)', () {
      final dg15 = fixture('aa_rsa_dg15.bin');
      expect(publicKeyOfDg15(dg15).description, 'RSA 1024-bit');
      expect(verifyActiveAuthentication(
          dg15, challenge, fixture('aa_rsa_sha1_sig.bin')), isTrue);
    });

    test('RSA with SHA-256 (trailer 34CC)', () {
      expect(verifyActiveAuthentication(fixture('aa_rsa_dg15.bin'), challenge,
          fixture('aa_rsa_sha256_sig.bin')), isTrue);
    });

    test('RSA fails for another challenge', () {
      final other = Uint8List.fromList(challenge)..[0] ^= 1;
      expect(verifyActiveAuthentication(fixture('aa_rsa_dg15.bin'), other,
          fixture('aa_rsa_sha1_sig.bin')), isFalse);
    });

    test('ECDSA', () {
      final dg15 = fixture('aa_ec_dg15.bin');
      expect(publicKeyOfDg15(dg15).signatureLength, 64);
      expect(verifyActiveAuthentication(
          dg15, challenge, fixture('aa_ec_sig.bin')), isTrue);
      final other = Uint8List.fromList(challenge)..[0] ^= 1;
      expect(verifyActiveAuthentication(
          dg15, other, fixture('aa_ec_sig.bin')), isFalse);
    });
  });
}
