import 'dart:typed_data';

import 'package:dz_id_reader/dz_id_reader.dart';
import 'package:flutter/material.dart';

import 'main.dart' show formatDate;

/// Shows an [IdDocument]: pictures, values, security checks and timings.
/// Only what the read returned appears.
class DocumentView extends StatelessWidget {
  const DocumentView(this.doc, {super.key});

  final IdDocument doc;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String? date(DateTime? d) => d == null ? null : formatDate(d);
    final fields = <(String, String?)>[
      (
        'Document',
        switch (doc.documentType) {
          DocumentType.idCard => 'ID card',
          DocumentType.passport => 'Passport',
          DocumentType.drivingLicence => 'Driving licence',
          DocumentType.other => 'Other document',
          null => null,
        },
      ),
      ('Document number', doc.documentNumber),
      ('Surname', doc.surname),
      ('Given names', doc.givenNames),
      (
        'Sex',
        switch (doc.sex) {
          Sex.male => 'Male',
          Sex.female => 'Female',
          Sex.unspecified => 'Not specified',
          null => null,
        },
      ),
      ('Nationality', doc.nationality),
      ('Date of birth', date(doc.dateOfBirth)),
      ('Expiry date', date(doc.dateOfExpiry)),
      ('Issuing country', doc.issuingCountry),
      ('NIN', doc.nin),
      ('Full name', doc.fullName),
      ('Other names', doc.otherNames),
      ('Place of birth', doc.placeOfBirth),
      ('Address', doc.address),
      ('Date of issue', date(doc.dateOfIssue)),
      ('Issuing authority', doc.issuingAuthority),
      ('Licence categories', doc.licenceCategories?.join(', ')),
      for (final MapEntry(:key, :value) in doc.otherDetails.entries)
        (key, value),
      ('MRZ', doc.mrz),
    ].where((f) => f.$2 != null && f.$2!.isNotEmpty).toList();
    final pictures = [
      if (doc.photo case final photo?) ('Photo', photo, 200.0),
      if (doc.signature case final sign?) ('Signature', sign, 80.0),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pictures.isNotEmpty)
          Wrap(
            spacing: 16,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              for (final (label, image, height) in pictures)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _Picture(image, height: height),
                    ),
                    const SizedBox(height: 4),
                    Text(label, style: theme.textTheme.labelSmall),
                  ],
                ),
            ],
          ),
        if (fields.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (label, value) in fields)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(label, style: theme.textTheme.labelSmall),
                          SelectableText(
                            value!,
                            style: label == 'MRZ'
                                ? theme.textTheme.bodySmall?.copyWith(
                                    fontFamily: 'monospace',
                                  )
                                : theme.textTheme.bodyLarge,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
        if (doc.security case final security?) ...[
          const SizedBox(height: 12),
          Text('Security', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          _SecurityCard(security),
        ],
        if (doc.timings case final timings?) ...[
          const SizedBox(height: 12),
          Text('Timings', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          _TimingsCard(timings),
        ],
      ],
    );
  }
}

/// Decodes once (JPEG 2000 is converted on a background isolate), then
/// shows the picture.
class _Picture extends StatefulWidget {
  const _Picture(this.image, {required this.height});

  final DocumentImage image;
  final double height;

  @override
  State<_Picture> createState() => _PictureState();
}

class _PictureState extends State<_Picture> {
  late Future<Uint8List> _bytes = widget.image.toDisplayBytes();

  @override
  void didUpdateWidget(_Picture old) {
    super.didUpdateWidget(old);
    if (!identical(old.image, widget.image)) {
      _bytes = widget.image.toDisplayBytes();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _bytes,
      builder: (context, snapshot) => switch (snapshot) {
        AsyncSnapshot(:final data?) => Image.memory(
          data,
          height: widget.height,
          fit: BoxFit.contain,
        ),
        AsyncSnapshot(hasError: true) => SizedBox(
          height: widget.height,
          child: const Center(child: Icon(Icons.broken_image_outlined)),
        ),
        _ => SizedBox.square(
          dimension: widget.height,
          child: const Center(child: CircularProgressIndicator()),
        ),
      },
    );
  }
}

class _SecurityCard extends StatelessWidget {
  const _SecurityCard(this.security);

  final SecurityResult security;

  @override
  Widget build(BuildContext context) {
    final signer = security.documentSigner;
    String day(DateTime d) => formatDate(d);
    final rows = [
      (
        'Chip is genuine',
        security.chipKey == null
            ? 'Active Authentication'
            : 'Signed our random challenge with its ${security.chipKey} key',
        security.chipGenuine,
      ),
      (
        'Data unchanged since issue',
        security.changedFiles.isEmpty
            ? 'The values match the hashes the issuer signed'
            : 'Changed: ${security.changedFiles.join(', ')}',
        security.dataUnchanged,
      ),
      (
        'Signed by the issuer',
        signer == null
            ? 'No signer certificate'
            : '${signer.subject}\nIssued by: ${signer.issuer}\n'
                  'Valid ${day(signer.validFrom)} to ${day(signer.validTo)}, '
                  '${signer.keyDescription}',
        security.issuerSignature,
      ),
      (
        'Country certificate (CSCA)',
        security.countryCertificate == CheckStatus.notChecked
            ? 'Not checked: no country certificate given to the reader'
            : 'The signer belongs to a trusted country certificate',
        security.countryCertificate,
      ),
    ];
    return Card(
      child: Column(
        children: [
          for (final (title, detail, status) in rows)
            ListTile(
              leading: switch (status) {
                CheckStatus.passed => const Icon(
                  Icons.verified,
                  color: Colors.green,
                ),
                CheckStatus.failed => const Icon(
                  Icons.error,
                  color: Colors.red,
                ),
                _ => const Icon(Icons.help_outline, color: Colors.grey),
              },
              title: Text(title),
              subtitle: Text('${_statusText(status)} · $detail'),
            ),
        ],
      ),
    );
  }

  static String _statusText(CheckStatus s) => switch (s) {
    CheckStatus.passed => 'Passed',
    CheckStatus.failed => 'FAILED',
    CheckStatus.notSupported => 'Not possible on this document',
    CheckStatus.notChecked => 'Not checked',
  };
}

class _TimingsCard extends StatelessWidget {
  const _TimingsCard(this.timings);

  final ReadTimings timings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String ms(Duration d) => '${d.inMilliseconds} ms';
    final rows = [
      ('Card held on the phone', ms(timings.onCard)),
      ('Unlock', ms(timings.unlock)),
      for (final MapEntry(:key, :value) in timings.files.entries)
        (key, ms(value)),
      if (timings.activeAuthentication case final aa?)
        ('Active Authentication', ms(aa)),
      ('Checks on the phone', ms(timings.checks)),
      ('Tries', '${timings.attempts}'),
      ('Commands', '${timings.commands}'),
      ('Big reads', timings.bigReads ? 'on' : 'off'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(label, style: theme.textTheme.bodyMedium),
                    ),
                    Text(value, style: theme.textTheme.bodyMedium),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
