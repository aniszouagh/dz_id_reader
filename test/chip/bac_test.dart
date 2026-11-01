import 'package:flutter_test/flutter_test.dart';

import 'package:dz_id_reader/src/chip/apdu.dart';
import 'package:dz_id_reader/src/chip/bac.dart';
import 'package:dz_id_reader/src/chip/bytes.dart';
import 'package:dz_id_reader/src/chip/secure_messaging.dart';
import 'package:dz_id_reader/src/lds/mrz_text.dart';

// The worked example of ICAO Doc 9303 part 11, appendix D: document
// L898902C<, born 1969-08-06, expires 1994-06-23.
void main() {
  test('check digits', () {
    expect(checkDigit('L898902C<'), 3);
    expect(checkDigit('690806'), 1);
    expect(checkDigit('940623'), 6);
  });

  test('BAC keys (D.2)', () {
    final key = BacKey('L898902C', '690806', '940623');
    expect(toHex(key.seed), '239AB9CB282DAF66231DC5A4DF6BFBAE');
    expect(toHex(key.enc), 'AB94FDECF2674FDFB9B391F85D7F76F2');
    expect(toHex(key.mac), '7962D9ECE03D1ACD4C76089DCE131543');
  });

  test('mutual authentication gives the session of D.3', () async {
    final sent = <String>[];
    Future<ResponseApdu> chip(CommandApdu command) async {
      sent.add(toHex(command.encode()));
      return command.ins == 0x84
          ? ResponseApdu(hexToBytes('4608F91988702212'), Sw.ok)
          : ResponseApdu(
              hexToBytes(
                '46B9342A41396CD7386BF5803104D7CEDC122B9132139BAF'
                '2EEDC94EE178534F2F2D235D074D7449',
              ),
              Sw.ok,
            );
    }

    final sm = await bacAuthenticate(
      chip,
      BacKey('L898902C', '690806', '940623'),
      rndIfd: hexToBytes('781723860C06C226'),
      kIfd: hexToBytes('0B795240CB7049B01C19B33E32804F0B'),
    );
    expect(sent, [
      '0084000008',
      '008200002872C29C2371CC9BDB65B779B8E8D37B29ECC154AA56A8799FAE2F498F76'
          'ED92F25F1448EEA8AD90A728',
    ]);
    expect(toHex(sm.ssc), '887022120C06C226');
    // The session keys are right if the first protected command of D.4
    // comes out byte for byte.
    expect(
      toHex(
        sm.wrap(CommandApdu(0x00, 0xA4, 0x02, 0x0C, data: hexToBytes('011E'))),
      ),
      '0CA4020C158709016375432908C044F68E08BF8B92D635FF24F800',
    );
  });

  test('a wrong key is refused', () async {
    Future<ResponseApdu> chip(CommandApdu command) async => command.ins == 0x84
        ? ResponseApdu(hexToBytes('4608F91988702212'), Sw.ok)
        : ResponseApdu(hexToBytes(''), Sw.authenticationFailed);
    await expectLater(
      bacAuthenticate(chip, BacKey('L898902C', '690806', '940624')),
      throwsA(isA<AccessDeniedException>()),
    );
  });

  group('secure messaging (D.4)', () {
    SecureMessaging session() => SecureMessaging(
      hexToBytes('979EC13B1CBFE9DCD01AB0FED307EAE5'),
      hexToBytes('F1CB1F1FB5ADF208806B89DC579DC1F8'),
      hexToBytes('887022120C06C226'),
    );

    test('select EF.COM, read 4 bytes, read the other 18', () {
      final sm = session();
      expect(
        toHex(
          sm.wrap(
            CommandApdu(0x00, 0xA4, 0x02, 0x0C, data: hexToBytes('011E')),
          ),
        ),
        '0CA4020C158709016375432908C044F68E08BF8B92D635FF24F800',
      );
      var r = sm.unwrap(hexToBytes('990290008E08FA855A5D4C50A8ED9000'));
      expect(r.sw, Sw.ok);
      expect(r.data, isEmpty);

      expect(
        toHex(sm.wrap(const CommandApdu(0x00, 0xB0, 0x00, 0x00, ne: 4))),
        '0CB000000D9701048E08ED6705417E96BA5500',
      );
      r = sm.unwrap(
        hexToBytes('8709019FF0EC34F9922651990290008E08AD55CC17140B2DED9000'),
      );
      expect(toHex(r.data), '60145F01');

      expect(
        toHex(sm.wrap(const CommandApdu(0x00, 0xB0, 0x00, 0x04, ne: 0x12))),
        '0CB000040D9701128E082EA28A70F3C7B53500',
      );
      r = sm.unwrap(
        hexToBytes(
          '871901FB9235F4E4037F2327DCC8964F1F9B8C30F42C'
          '8E2FFF224A990290008E08C8B2787EAEA07D749000',
        ),
      );
      expect(toHex(r.data), '04303130365F36063034303030305C026175');
      expect(toHex(sm.ssc), '887022120C06C22C');
    });

    test('a changed response fails its MAC', () {
      final sm = session();
      sm.wrap(CommandApdu(0x00, 0xA4, 0x02, 0x0C, data: hexToBytes('011E')));
      expect(
        () => sm.unwrap(hexToBytes('990290018E08FA855A5D4C50A8ED9000')),
        throwsA(isA<SecureMessagingException>()),
      );
      expect(sm.broken, isTrue);
    });

    test('a bare status word marks the session broken', () {
      final sm = session();
      sm.wrap(const CommandApdu(0x00, 0xB0, 0x00, 0x00, ne: 4));
      final r = sm.unwrap(hexToBytes('6988'));
      expect((r.sw, sm.broken), (Sw.smDataIncorrect, true));
    });
  });

  group('command encoding', () {
    String hex(CommandApdu c) => toHex(c.encode());

    test('short forms', () {
      expect(
        hex(const CommandApdu(0x00, 0x84, 0x00, 0x00, ne: 8)),
        '0084000008',
      );
      expect(
        hex(const CommandApdu(0x00, 0xB0, 0x00, 0x00, ne: 256)),
        '00B0000000',
      );
      expect(
        hex(
          CommandApdu(
            0x00,
            0xA4,
            0x04,
            0x0C,
            data: hexToBytes('A0000002471001'),
          ),
        ),
        '00A4040C07A0000002471001',
      );
    });

    test('extended forms', () {
      expect(
        hex(const CommandApdu(0x00, 0xB0, 0x00, 0x00, ne: 0x800)),
        '00B00000000800',
      );
      expect(
        hex(const CommandApdu(0x00, 0xB0, 0x00, 0x00, ne: 65536)),
        '00B00000000000',
      );
      expect(
        hex(
          CommandApdu(
            0x0C,
            0xB0,
            0x00,
            0x00,
            data: hexToBytes('970208008E080102030405060708'),
            ne: 65536,
          ),
        ),
        '0CB0000000000E970208008E0801020304050607080000',
      );
    });
  });
}
