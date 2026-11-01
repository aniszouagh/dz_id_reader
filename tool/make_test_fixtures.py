"""Builds the files in test/fixtures/ used by the security and image tests,
and lib/src/testing/demo_files.dart, the demo document of FakeCard.demo().
Nothing here comes from a real document: the keys, certificates, values and
pictures are made up on the spot (a "SPECIMEN DEMO" of the fictional state
UTO).

Needs openssl, ffmpeg and the Python `cryptography` package.
Run from the project root:  python3 -I tool/make_test_fixtures.py
"""

import base64
import hashlib
import os
import subprocess
import tempfile

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

OUT = os.path.join('test', 'fixtures')


def tlv(tag: bytes, content: bytes) -> bytes:
    n = len(content)
    if n < 0x80:
        length = bytes([n])
    else:
        b = n.to_bytes((n.bit_length() + 7) // 8, 'big')
        length = bytes([0x80 | len(b)]) + b
    return tag + length + content


def seq(*items: bytes) -> bytes:
    return tlv(b'\x30', b''.join(items))


def integer(v: int) -> bytes:
    return tlv(b'\x02', v.to_bytes(v.bit_length() // 8 + 1, 'big'))


def oid(dotted: str) -> bytes:
    arcs = [int(a) for a in dotted.split('.')]
    body = bytes([arcs[0] * 40 + arcs[1]])
    for arc in arcs[2:]:
        chunk = [arc & 0x7F]
        arc >>= 7
        while arc:
            chunk.insert(0, 0x80 | (arc & 0x7F))
            arc >>= 7
        body += bytes(chunk)
    return tlv(b'\x06', body)


def write(name: str, data: bytes) -> None:
    with open(os.path.join(OUT, name), 'wb') as f:
        f.write(data)


def run(*args: str) -> None:
    subprocess.run(args, check=True, capture_output=True)


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    tmp = tempfile.mkdtemp()

    # Two data groups and the LDS security object that lists their hashes.
    dg1 = tlv(b'\x61', tlv(b'\x5f\x1f', b'I<UTOD231458907<<<<<<<<<<<<<<<'
                                        b'7408122F1204159UTO<<<<<<<<<<<6'
                                        b'ERIKSSON<<ANNA<MARIA<<<<<<<<<<'))
    dg2 = tlv(b'\x75', bytes(range(256)) * 2)
    write('dg1.bin', dg1)
    write('dg2.bin', dg2)
    lds = seq(integer(0),
              seq(oid('2.16.840.1.101.3.4.2.1'), b'\x05\x00'),
              seq(seq(integer(1), tlv(b'\x04', hashlib.sha256(dg1).digest())),
                  seq(integer(2), tlv(b'\x04', hashlib.sha256(dg2).digest()))))
    lds_path = os.path.join(tmp, 'lds.der')
    with open(lds_path, 'wb') as f:
        f.write(lds)

    subject = '/C=UT/O=Test State/CN=Test Document Signer'
    keys = {
        'rsa': ['openssl', 'genpkey', '-algorithm', 'RSA',
                '-pkeyopt', 'rsa_keygen_bits:2048'],
        'ec_named': ['openssl', 'ecparam', '-name', 'prime256v1', '-genkey',
                     '-noout'],
        'ec_explicit': ['openssl', 'ecparam', '-name', 'brainpoolP256r1',
                        '-param_enc', 'explicit', '-genkey', '-noout'],
    }
    for name, command in keys.items():
        key = os.path.join(tmp, f'{name}.key')
        cert = os.path.join(tmp, f'{name}.pem')
        run(*command, '-out', key)
        run('openssl', 'req', '-x509', '-key', key, '-out', cert, '-days',
            '3650', '-subj', subject)
        variants = {name: []}
        if name == 'rsa':
            variants['rsa_pss'] = ['-keyopt', 'rsa_padding_mode:pss',
                                   '-keyopt', 'rsa_pss_saltlen:32']
        for variant, extra in variants.items():
            sod = os.path.join(tmp, f'{variant}.der')
            run('openssl', 'cms', '-sign', '-binary', '-nodetach', '-outform',
                'DER', '-in', lds_path, '-signer', cert, '-inkey', key, '-md',
                'sha256', '-econtent_type', '2.23.136.1.1.1', *extra,
                '-out', sod)
            with open(sod, 'rb') as f:
                write(f'sod_{variant}.bin', tlv(b'\x77', f.read()))

    # Active Authentication: the chip signs an 8-byte challenge.
    challenge = bytes(range(1, 9))
    write('aa_challenge.bin', challenge)
    key = rsa.generate_private_key(public_exponent=65537, key_size=1024)
    n, d = key.public_key().public_numbers().n, key.private_numbers().d
    write('aa_rsa_dg15.bin', tlv(b'\x6f', key.public_key().public_bytes(
        serialization.Encoding.DER,
        serialization.PublicFormat.SubjectPublicKeyInfo)))
    k = 128
    for hash_name, h, trailer in [('sha1', hashlib.sha1, b'\xbc'),
                                  ('sha256', hashlib.sha256, b'\x34\xcc')]:
        m1 = os.urandom(k - h().digest_size - 1 - len(trailer))
        f = b'\x6a' + m1 + h(m1 + challenge).digest() + trailer
        signature = pow(int.from_bytes(f, 'big'), d, n).to_bytes(k, 'big')
        write(f'aa_rsa_{hash_name}_sig.bin', signature)

    ec_key = ec.generate_private_key(ec.SECP256R1())
    write('aa_ec_dg15.bin', tlv(b'\x6f', ec_key.public_key().public_bytes(
        serialization.Encoding.DER,
        serialization.PublicFormat.SubjectPublicKeyInfo)))
    r, s = decode_dss_signature(
        ec_key.sign(challenge, ec.ECDSA(hashes.SHA256())))
    write('aa_ec_sig.bin', r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))

    # A 40x30 test picture as JPEG 2000 and JPEG, wrapped like DG2 (behind
    # an ISO 19794-5 style header) and DG7.
    jp2 = os.path.join(tmp, 'face.jp2')
    jpg = os.path.join(tmp, 'sign.jpg')
    source = ['ffmpeg', '-y', '-f', 'lavfi', '-i', 'testsrc=size=40x30:rate=1',
              '-frames:v', '1']
    run(*source, '-c:v', 'jpeg2000', '-format', 'jp2', jp2)
    run(*source, jpg)
    with open(jp2, 'rb') as f:
        face = f.read()
    with open(jpg, 'rb') as f:
        sign = f.read()
    header = b'FAC\x00010\x00' + bytes(24)
    write('image_dg2.bin', tlv(b'\x75', tlv(b'\x7f\x61', tlv(b'\x02', b'\x01') +
        tlv(b'\x7f\x60', tlv(b'\xa1', tlv(b'\x80', b'\x01\x01')) +
            tlv(b'\x5f\x2e', header + face)))))
    write('image_dg7.bin', tlv(b'\x67', tlv(b'\x02', b'\x01') +
                               tlv(b'\x5f\x43', sign)))


def check_digit(value: str) -> str:
    total = 0
    for i, c in enumerate(value):
        v = int(c) if c.isdigit() else ord(c) - 55 if c.isalpha() else 0
        total += v * (7, 3, 1)[i % 3]
    return str(total % 10)


def demo() -> None:
    """A complete fake ID card: TD1 MRZ, photo, signature, details, Active
    Authentication key, and EF.SOD signed by a document signer whose
    certificate a fake country CSCA issued."""
    tmp = tempfile.mkdtemp()
    number, birth, expiry = '100000017', '900101', '350101'
    line1 = f'IDUTO{number}{check_digit(number)}'.ljust(30, '<')
    line2 = (f'{birth}{check_digit(birth)}F{expiry}{check_digit(expiry)}UTO'
             .ljust(29, '<'))
    line2 += check_digit(line1[5:30] + line2[0:7] + line2[8:15] + line2[18:29])
    line3 = 'SPECIMEN<<DEMO'.ljust(30, '<')
    dg1 = tlv(b'\x61', tlv(b'\x5f\x1f', (line1 + line2 + line3).encode()))

    def picture(name: str, size: str, expr: str, quality: str) -> bytes:
        path = os.path.join(tmp, name)
        run('ffmpeg', '-y', '-f', 'lavfi', '-i', f'color=c=gray:s={size}',
            '-vf', f"geq=lum='{expr}':cb=128:cr=128", '-frames:v', '1',
            '-q:v', quality, path)
        with open(path, 'rb') as f:
            return f.read()

    # A grey silhouette: head and shoulders.
    face = picture('face.jpg', '240x320',
                   'if(lt(pow(X-W/2,2)+pow(Y-H*0.36,2),pow(W*0.21,2))+'
                   'lt(pow((X-W/2)/(W*0.44),2)+pow((Y-H)/(H*0.36),2),1),'
                   '95,215)', '6')
    sign = picture('sign.jpg', '300x100',
                   'if(lt(abs(Y-(H/2+H*0.28*sin(X/W*9)*cos(X/W*2))),2.5),'
                   '25,250)', '8')
    header = b'FAC\x00010\x00' + bytes(24)
    dg2 = tlv(b'\x75', tlv(b'\x7f\x61', tlv(b'\x02', b'\x01') +
        tlv(b'\x7f\x60', tlv(b'\xa1', tlv(b'\x80', b'\x01\x01')) +
            tlv(b'\x5f\x2e', header + face))))
    dg7 = tlv(b'\x67', tlv(b'\x02', b'\x01') + tlv(b'\x5f\x43', sign))
    details = [(b'\x5f\x0e', 'SPECIMEN<<DEMO'),
               (b'\x5f\x0f', 'عينة<<تجريبية'),
               (b'\x5f\x10', '100000000000000017'),
               (b'\x5f\x2b', '19900101'),
               (b'\x5f\x11', 'DEMO CITY<UTOPIA'),
               (b'\x5f\x42', '1 DEMO STREET<DEMO CITY')]
    dg11 = tlv(b'\x6b', tlv(b'\x5c', b''.join(t for t, _ in details)) +
               b''.join(tlv(t, v.encode()) for t, v in details))
    dg12 = tlv(b'\x6c', tlv(b'\x5c', b'\x5f\x19\x5f\x26') +
               tlv(b'\x5f\x19', b'DEMO AUTHORITY') +
               tlv(b'\x5f\x26', b'20250101'))
    aa = rsa.generate_private_key(public_exponent=65537, key_size=1024)
    dg15 = tlv(b'\x6f', aa.public_key().public_bytes(
        serialization.Encoding.DER,
        serialization.PublicFormat.SubjectPublicKeyInfo))
    groups = {1: dg1, 2: dg2, 7: dg7, 11: dg11, 12: dg12, 15: dg15}
    lds = seq(integer(0),
              seq(oid('2.16.840.1.101.3.4.2.1'), b'\x05\x00'),
              seq(*[seq(integer(n), tlv(b'\x04', hashlib.sha256(v).digest()))
                    for n, v in groups.items()]))
    lds_path = os.path.join(tmp, 'lds.der')
    with open(lds_path, 'wb') as f:
        f.write(lds)

    def path(name: str) -> str:
        return os.path.join(tmp, name)

    run('openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt',
        'rsa_keygen_bits:2048', '-out', path('csca.key'))
    run('openssl', 'req', '-x509', '-key', path('csca.key'), '-out',
        path('csca.pem'), '-days', '7300', '-subj',
        '/C=UT/O=Demo State/CN=Demo CSCA')
    run('openssl', 'ecparam', '-name', 'prime256v1', '-genkey', '-noout',
        '-out', path('ds.key'))
    run('openssl', 'req', '-new', '-key', path('ds.key'), '-out',
        path('ds.csr'), '-subj', '/C=UT/O=Demo State/CN=Demo Document Signer')
    run('openssl', 'x509', '-req', '-in', path('ds.csr'), '-CA',
        path('csca.pem'), '-CAkey', path('csca.key'), '-CAcreateserial',
        '-days', '3650', '-sha256', '-out', path('ds.pem'))
    run('openssl', 'cms', '-sign', '-binary', '-nodetach', '-outform', 'DER',
        '-in', lds_path, '-signer', path('ds.pem'), '-inkey', path('ds.key'),
        '-md', 'sha256', '-econtent_type', '2.23.136.1.1.1', '-out',
        path('sod.der'))
    run('openssl', 'x509', '-in', path('csca.pem'), '-outform', 'DER',
        '-out', path('csca.der'))
    with open(path('sod.der'), 'rb') as f:
        sod = tlv(b'\x77', f.read())
    with open(path('csca.der'), 'rb') as f:
        csca = f.read()

    def b64(data: bytes) -> str:
        text = base64.b64encode(data).decode()
        lines = [text[i:i + 72] for i in range(0, len(text), 72)]
        return '\n'.join(f"    '{line}'" for line in lines)

    files = {1: dg1, 2: dg2, 7: dg7, 11: dg11, 12: dg12, 15: dg15, 0x1D: sod}
    numbers = aa.private_numbers()
    out = ['// Generated by tool/make_test_fixtures.py. Made-up data: a',
           '// "SPECIMEN DEMO" ID card of the fictional state UTO.',
           '// ignore_for_file: lines_longer_than_80_chars',
           '',
           "import 'dart:convert';",
           "import 'dart:typed_data';",
           '',
           "const demoNumber = '%s';" % number,
           'final demoBirth = DateTime(1990, 1, 1);',
           'final demoExpiry = DateTime(2035, 1, 1);',
           "final demoAaModulus = BigInt.parse('%x', radix: 16);" %
           numbers.public_numbers.n,
           "final demoAaPrivateExponent = BigInt.parse('%x', radix: 16);" %
           numbers.d,
           '',
           '/// The chip files by short file identifier.',
           'final Map<int, Uint8List> demoFiles = {']
    for n, data in files.items():
        out.append(f'  0x{n:02X}: base64Decode(')
        out.append(b64(data) + ',')
        out.append('  ),')
    out.append('};')
    out.append('')
    out.append("/// The demo state's CSCA certificate (DER).")
    out.append('final Uint8List demoCountryCertificate = base64Decode(')
    out.append(b64(csca) + ',')
    out.append(');')
    with open(os.path.join('lib', 'src', 'testing', 'demo_files.dart'),
              'w') as f:
        f.write('\n'.join(out) + '\n')


if __name__ == '__main__':
    main()
    demo()
