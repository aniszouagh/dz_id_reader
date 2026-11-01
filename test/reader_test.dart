import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dz_id_reader/dz_id_reader.dart';
import 'package:dz_id_reader/src/testing/demo_files.dart';
import 'package:dz_id_reader/testing.dart';

/// Lines of the fake chip's log for reads of [file] (like `DG2`).
Iterable<String> readsOf(FakeCard card, String file) =>
    card.log.where((l) => l.startsWith('READ $file '));

void main() {
  test('the default read takes the MRZ file only', () async {
    final card = FakeCard.demo();
    final doc = await DocumentReader(transport: FakeNfc(card)).read(demoKey);
    expect(doc.documentType, DocumentType.idCard);
    expect(doc.documentNumber, '100000017');
    expect((doc.surname, doc.givenNames), ('SPECIMEN', 'DEMO'));
    expect(doc.sex, Sex.female);
    expect(doc.nationality, 'UTO');
    expect(doc.dateOfBirth, DateTime(1990, 1, 1));
    expect(doc.dateOfExpiry, DateTime(2035, 1, 1));
    // Not asked for, so neither read nor returned.
    expect((doc.nin, doc.photo, doc.security), (null, null, null));
    expect(card.log.where((l) => l.startsWith('READ')).map((l) => l.split(' ')[1]).toSet(),
        {'DG1'});
  });

  test('asking for the NIN reads DG11 only and returns only the NIN', () async {
    final card = FakeCard.demo();
    final doc = await DocumentReader(transport: FakeNfc(card))
        .read(demoKey, want: {Info.nin});
    expect(doc.nin, '100000000000000017');
    expect((doc.surname, doc.address, doc.documentNumber), (null, null, null));
    expect(card.log.where((l) => l.startsWith('READ')).map((l) => l.split(' ')[1]).toSet(),
        {'DG11'});
  });

  test('everything, with all checks passing', () async {
    final reader = DocumentReader(
        transport: FakeNfc(FakeCard.demo()),
        trustedCountryCertificates: [demoCountryCertificate]);
    final doc = await reader.read(demoKey,
        want: Info.everything, checks: Check.values.toSet());
    expect(doc.fullName, 'SPECIMEN DEMO');
    expect(doc.otherNames, 'عينة تجريبية');
    expect(doc.placeOfBirth, 'DEMO CITY, UTOPIA');
    expect(doc.address, '1 DEMO STREET, DEMO CITY');
    expect(doc.dateOfIssue, DateTime(2025, 1, 1));
    expect(doc.issuingAuthority, 'DEMO AUTHORITY');
    expect(doc.mrz!.split('\n'), hasLength(3));
    expect(doc.photo!.format, ImageFormat.jpeg);
    expect(doc.signature!.format, ImageFormat.jpeg);
    final s = doc.security!;
    expect(
        [s.chipGenuine, s.dataUnchanged, s.issuerSignature, s.countryCertificate],
        everyElement(CheckStatus.passed));
    expect(s.chipKey, 'RSA 1024-bit');
    expect(s.documentSigner!.subject, contains('Demo Document Signer'));
    expect(doc.timings!.attempts, 1);
  });

  test('without country certificates that check is not done', () async {
    final doc = await DocumentReader(transport: FakeNfc(FakeCard.demo()))
        .read(demoKey, checks: {Check.dataAuthentic});
    expect(doc.security!.issuerSignature, CheckStatus.passed);
    expect(doc.security!.countryCertificate, CheckStatus.notChecked);
    expect(doc.security!.chipGenuine, CheckStatus.notChecked);
  });

  test('a changed file fails the hash check', () async {
    final files = Map.of(demoFiles);
    files[11] = Uint8List.fromList(files[11]!)..[files[11]!.length - 1] ^= 1;
    final card = FakeCard(
        key: demoKey,
        files: files,
        aaModulus: demoAaModulus,
        aaPrivateExponent: demoAaPrivateExponent);
    final doc = await DocumentReader(transport: FakeNfc(card))
        .read(demoKey, want: {Info.nin}, checks: {Check.dataAuthentic});
    expect(doc.security!.dataUnchanged, CheckStatus.failed);
    expect(doc.security!.changedFiles, ['DG11']);
  });

  test('a copied chip (another private key) fails Active Authentication',
      () async {
    final card = FakeCard(
        key: demoKey,
        files: demoFiles,
        aaModulus: demoAaModulus,
        aaPrivateExponent: demoAaPrivateExponent - BigInt.two);
    final doc = await DocumentReader(transport: FakeNfc(card))
        .read(demoKey, want: const {}, checks: {Check.chipGenuine});
    expect(doc.security!.chipGenuine, CheckStatus.failed);
    expect(card.log.where((l) => l.startsWith('READ')).map((l) => l.split(' ')[1]).toSet(),
        {'DG15'});
  });

  group('big reads', () {
    test('the photo comes in a few big commands when both sides can',
        () async {
      final card = FakeCard.demo();
      final doc = await DocumentReader(transport: FakeNfc(card))
          .read(demoKey, want: {Info.photo});
      final size = demoFiles[2]!.length;
      expect(readsOf(card, 'DG2'), hasLength(1 + ((size - 223) / 2048).ceil()));
      expect(doc.photo!.bytes.length, greaterThan(1000));
      expect(doc.timings!.bigReads, isTrue);
    });

    test('a phone without them reads in short commands', () async {
      final card = FakeCard.demo();
      await DocumentReader(transport: FakeNfc(card, phoneExtendedLength: false))
          .read(demoKey, want: {Info.photo});
      expect(readsOf(card, 'DG2'), hasLength((demoFiles[2]!.length / 223).ceil()));
    });

    test('a chip that refuses them gets short ones, also next time', () async {
      final card = FakeCard.demo(maxResponse: 256);
      final reader = DocumentReader(transport: FakeNfc(card));
      final first = await reader.read(demoKey, want: {Info.photo});
      expect(card.log, contains(startsWith('REFUSED')));
      expect(first.photo!.bytes, isNotEmpty);
      expect(first.timings!.bigReads, isFalse);
      card.log.clear();
      await reader.read(demoKey, want: {Info.photo});
      expect(card.log, isNot(contains(startsWith('REFUSED'))));
    });
  });

  test('a card that moves during the photo is read on from where it stopped',
      () async {
    final card = FakeCard.demo(maxResponse: 256)..loseAfter = 20;
    final events = <ReadProgress>[];
    final doc = await DocumentReader(
            transport: FakeNfc(card, phoneExtendedLength: false))
        .read(demoKey, want: Info.everything, onProgress: events.add);
    expect(doc.timings!.attempts, 2);
    expect(events.map((e) => e.attempt).toSet(), {1, 2});
    final photo = demoFiles[2]!;
    // The photo starts once; after the break only a one-byte read selects
    // the file again.
    expect(readsOf(card, 'DG2').where((l) => l.endsWith('@0 223')), hasLength(1));
    expect(readsOf(card, 'DG2').where((l) => l.endsWith('@0 1')), hasLength(1));
    expect(doc.photo!.bytes.length, lessThan(photo.length));
    expect(doc.nin, isNotNull);
  });

  test('progress: stages in order, names before the photo', () async {
    final events = <ReadProgress>[];
    await DocumentReader(transport: FakeNfc(FakeCard.demo(), phoneExtendedLength: false))
        .read(demoKey, want: {Info.names, Info.photo}, onProgress: events.add);
    final stages = events.map((e) => e.stage).toList();
    expect(stages.first, ReadStage.waitingForCard);
    expect(stages.indexOf(ReadStage.unlocking),
        lessThan(stages.indexOf(ReadStage.reading)));
    expect(stages.last, ReadStage.done);
    final namesFirst = events.firstWhere((e) => e.partial?.surname != null);
    expect(namesFirst.partial!.photo, isNull);
    expect(namesFirst.fraction, lessThan(0.2));
    final fractions = events.map((e) => e.fraction).toList();
    for (var i = 1; i < fractions.length; i++) {
      expect(fractions[i], greaterThanOrEqualTo(fractions[i - 1]));
    }
  });

  group('errors', () {
    test('wrong key', () async {
      final key = AccessKey(
          documentNumber: '100000017',
          dateOfBirth: DateTime(1990, 1, 2),
          dateOfExpiry: DateTime(2035, 1, 1));
      await expectLater(DocumentReader(transport: FakeNfc(FakeCard.demo())).read(key),
          throwsA(isA<WrongKey>()));
    });

    test('no card', () async {
      await expectLater(
          DocumentReader(transport: FakeNfc(null))
              .read(demoKey, timeout: const Duration(milliseconds: 50)),
          throwsA(isA<NoCardFound>()));
    });

    test('NFC off', () async {
      await expectLater(
          DocumentReader(transport: FakeNfc(null, nfcState: NfcState.off)).read(demoKey),
          throwsA(isA<NfcOff>()));
    });

    test('cancel while waiting', () async {
      final reader = DocumentReader(transport: FakeNfc(null));
      final read =
          expectLater(reader.read(demoKey), throwsA(isA<ReadCancelled>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await reader.cancel();
      await read;
      expect(reader.isReading, isFalse);
    });

    test('one read at a time', () async {
      final reader = DocumentReader(transport: FakeNfc(null));
      final first = reader.read(demoKey, timeout: const Duration(milliseconds: 50));
      expect(() => reader.read(demoKey), throwsStateError);
      await expectLater(first, throwsA(isA<NoCardFound>()));
    });
  });

  test('keys never print their values', () {
    expect('$demoKey', isNot(contains('100000017')));
  });
}
