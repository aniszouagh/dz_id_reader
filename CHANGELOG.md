## Unreleased

* Public API: `DocumentReader`, `AccessKey`, `Info`, `Check`, `IdDocument`,
  `ReadProgress`, typed `ReadException`s. Reads only the chip files that
  hold what was asked for.
* Own NFC transport (Kotlin) and own BAC/BAP with 3DES secure messaging,
  tested against the ICAO 9303-11 worked example. `dmrtd` and
  `flutter_nfc_kit` are no longer used.
* Big (extended-length) reads when the phone and chip allow them, with
  fallback; reading goes on where it stopped after the card moves.
* Security checks return a `SecurityResult`; optional CSCA check with
  `trustedCountryCertificates`.
* `scanner.dart`: `MrzScanner` (no UI) and the `MrzCamera` helper.
* `testing.dart`: `FakeCard` / `FakeNfc` and a demo card.
* Fixed: the security checks crashed on the phone ("object is unsendable").

## 0.0.1

* Code moved from the dz_id_nfc test app; the test app is now `example/`.
