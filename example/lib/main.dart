import 'package:dz_id_reader/dz_id_reader.dart';
import 'package:dz_id_reader/scanner.dart';
import 'package:dz_id_reader/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import 'document_view.dart';
import 'scan_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // The scan page draws its card outline for a portrait screen.
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // The package logs steps and timings, never card data.
  Logger.root.level = kReleaseMode ? Level.INFO : Level.FINE;
  Logger.root.onRecord.listen(
    (r) => debugPrint('${r.loggerName}: ${r.message}'),
  );
  runApp(const App());
  MrzScanner.warmUp();
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DZ ID Reader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.green),
      home: const HomePage(),
    );
  }
}

/// Groups of values the user can pick, mapped to what the package reads.
enum Part {
  main('Main data', {...Info.mrzData, Info.mrz, Info.licenceCategories}),
  personal('Personal details', Info.personalDetails),
  document('Document details', Info.documentDetails),
  other('Other values', {Info.otherDetails}),
  signature('Signature', {Info.signature}),
  photo('Photo', {Info.photo});

  const Part(this.label, this.infos);
  final String label;
  final Set<Info> infos;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _reader = DocumentReader();
  final _docNumber = TextEditingController();
  final _dob = TextEditingController();
  final _doe = TextEditingController();
  final _parts = Part.values.toSet();
  final _checks = Check.values.toSet();
  DocumentReader? _running;
  ReadProgress? _progress;
  IdDocument? _doc;
  String? _message;
  bool _messageIsError = false;
  bool _messageIsNeutral = false;
  String? _scanInfo;
  final _resultsKey = GlobalKey();
  bool _shownResults = false;

  bool get _reading => _running != null;

  @override
  void initState() {
    super.initState();
    _reader.holdNfc(); // no Android "cannot read tag" message on this page
  }

  @override
  void dispose() {
    _reader.releaseNfc();
    _docNumber.dispose();
    _dob.dispose();
    _doe.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    FocusScope.of(context).unfocus();
    final result = await Navigator.push<MrzScanResult>(
      context,
      MaterialPageRoute(builder: (_) => const ScanPage()),
    );
    if (result == null || !mounted) return;
    _fill(result.key);
    _scanInfo =
        'Scanned in ${_seconds(result.elapsed)} '
        '(${result.frames} frames)';
    await _read(result.key, _reader);
  }

  void _fill(AccessKey key) {
    _docNumber.text = key.documentNumber;
    _dob.text = formatDate(key.dateOfBirth);
    _doe.text = formatDate(key.dateOfExpiry);
  }

  Future<void> _readTyped() async {
    FocusScope.of(context).unfocus();
    _scanInfo = null;
    final key = _keyFromForm();
    if (key != null) await _read(key, _reader);
  }

  /// The made-up demo cards: they work on any phone, no NFC needed.
  Future<void> _readDemo({required bool licence}) async {
    FocusScope.of(context).unfocus();
    final key = licence ? demoLicenceKey : demoKey;
    _fill(key);
    _scanInfo = 'Demo ${licence ? 'licence' : 'ID card'}: made-up data, no NFC';
    final demo = DocumentReader(
      transport: FakeNfc(
        licence ? FakeCard.demoLicence() : FakeCard.demo(),
        commandDelay: const Duration(milliseconds: 25),
      ),
      trustedCountryCertificates: [demoCountryCertificate],
    );
    await _read(key, demo);
  }

  AccessKey? _keyFromForm() {
    final number = AccessKey.normalize(_docNumber.text);
    final dob = parseDate(_dob.text);
    final doe = parseDate(_doe.text);
    final problem = number.isEmpty
        ? 'Type the document number.'
        : !RegExp(r'^[A-Z0-9]+$').hasMatch(number)
        ? 'The document number has letters and digits only.'
        : dob == null
        ? 'Date of birth: write it as YYYY.MM.DD.'
        : doe == null
        ? 'Expiry date: write it as YYYY.MM.DD.'
        : null;
    if (problem != null) {
      setState(() {
        _message = problem;
        _messageIsError = true;
        _messageIsNeutral = false;
      });
      return null;
    }
    return AccessKey(
      documentNumber: number,
      dateOfBirth: dob!,
      dateOfExpiry: doe!,
    );
  }

  Future<void> _read(AccessKey key, DocumentReader reader) async {
    setState(() {
      _running = reader;
      _doc = null;
      _message = null;
      _shownResults = false;
      _progress = const ReadProgress(ReadStage.waitingForCard);
    });
    try {
      final doc = await reader.read(
        key,
        want: {for (final part in _parts) ...part.infos},
        checks: _checks,
        onProgress: (p) {
          if (p.stage == ReadStage.unlocking) HapticFeedback.selectionClick();
          setState(() {
            _progress = p;
            if (p.partial != null) _doc = p.partial;
          });
          if (p.partial != null) _showResults();
        },
      );
      HapticFeedback.mediumImpact();
      setState(() {
        _doc = doc;
        _message = 'Done. You can remove the card.';
        _messageIsError = false;
      });
    } on ReadException catch (e) {
      setState(() {
        _message = describeError(e);
        _messageIsError = true;
        _messageIsNeutral = e is ReadCancelled;
      });
    } finally {
      if (mounted) {
        setState(() {
          _running = null;
          _progress = null;
        });
      }
    }
  }

  /// Scrolls the first values into view, once per read: the name shows up
  /// while the photo still loads.
  void _showResults() {
    if (_shownResults) return;
    _shownResults = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _resultsKey.currentContext;
      if (target != null && target.mounted) {
        Scrollable.ensureVisible(
          target,
          duration: const Duration(milliseconds: 300),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = _progress;
    final doc = _doc;
    return Scaffold(
      appBar: AppBar(title: const Text('DZ ID Reader')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'Scan the back of the ID card or the bottom of the passport '
                    'page, then hold the document on the back of the phone.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _reading ? null : _scan,
                    icon: const Icon(Icons.document_scanner_outlined),
                    label: const Text('Scan document'),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Or type the 3 values',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  _field(
                    _docNumber,
                    'Document number',
                    '9 characters',
                    caps: true,
                  ),
                  const SizedBox(height: 12),
                  _field(_dob, 'Date of birth', 'YYYY.MM.DD', date: true),
                  const SizedBox(height: 12),
                  _field(_doe, 'Expiry date', 'YYYY.MM.DD', date: true),
                  const SizedBox(height: 16),
                  Text('What to read', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final part in Part.values)
                        FilterChip(
                          label: Text(part.label),
                          selected: _parts.contains(part),
                          onSelected: _reading
                              ? null
                              : (on) => setState(
                                  () => on
                                      ? _parts.add(part)
                                      : _parts.remove(part),
                                ),
                        ),
                      for (final (check, label) in const [
                        (Check.chipGenuine, 'Chip is genuine'),
                        (Check.dataAuthentic, 'Data is authentic'),
                      ])
                        FilterChip(
                          avatar: const Icon(Icons.shield_outlined, size: 18),
                          label: Text(label),
                          selected: _checks.contains(check),
                          onSelected: _reading
                              ? null
                              : (on) => setState(
                                  () => on
                                      ? _checks.add(check)
                                      : _checks.remove(check),
                                ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _reading ? null : _readTyped,
                    icon: const Icon(Icons.nfc),
                    label: const Text('Read chip'),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton.icon(
                          onPressed: _reading
                              ? null
                              : () => _readDemo(licence: false),
                          icon: const Icon(Icons.science_outlined),
                          label: const Text('Demo ID card'),
                        ),
                      ),
                      Expanded(
                        child: TextButton.icon(
                          onPressed: _reading
                              ? null
                              : () => _readDemo(licence: true),
                          icon: const Icon(Icons.science_outlined),
                          label: const Text('Demo licence'),
                        ),
                      ),
                    ],
                  ),
                  Column(
                    key: _resultsKey,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!_reading &&
                          _message != null &&
                          !_messageIsError) ...[
                        const SizedBox(height: 8),
                        Text(
                          _message!,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium,
                        ),
                      ],
                      if (_scanInfo != null && doc != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          _scanInfo!,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                      if (doc != null) ...[
                        const SizedBox(height: 16),
                        DocumentView(doc),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            // Pinned under the list, so they show wherever the list is.
            if (progress != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: NfcPrompt(
                  progress: progress,
                  onCancel: () => _running?.cancel(),
                ),
              )
            else if (_message != null && _messageIsError)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: _Banner(
                  _message!,
                  neutral: _messageIsNeutral,
                  onClose: () => setState(() => _message = null),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    String hint, {
    bool caps = false,
    bool date = false,
  }) {
    return TextField(
      controller: controller,
      enabled: !_reading,
      autocorrect: false,
      textCapitalization: caps
          ? TextCapitalization.characters
          : TextCapitalization.none,
      keyboardType: date ? TextInputType.datetime : TextInputType.text,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
    );
  }
}

/// A message pinned under the list: errors in red, others neutral.
class _Banner extends StatelessWidget {
  const _Banner(this.text, {required this.neutral, required this.onClose});

  final String text;
  final bool neutral;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = neutral ? colors.onSurface : colors.onErrorContainer;
    return Card(
      color: neutral ? colors.surfaceContainerHighest : colors.errorContainer,
      child: ListTile(
        leading: Icon(
          neutral ? Icons.info_outline : Icons.error_outline,
          color: foreground,
        ),
        title: Text(text, style: TextStyle(color: foreground)),
        trailing: IconButton(
          tooltip: 'Close',
          icon: Icon(Icons.close, color: foreground),
          onPressed: onClose,
        ),
      ),
    );
  }
}

/// The "touch the card" panel, drawn from [ReadProgress].
class NfcPrompt extends StatelessWidget {
  const NfcPrompt({super.key, required this.progress, required this.onCancel});

  final ReadProgress progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final waiting = progress.stage == ReadStage.waitingForCard;
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          children: [
            Icon(
              Icons.contactless_outlined,
              size: 40,
              color: theme.colorScheme.onPrimaryContainer,
            ),
            const SizedBox(height: 8),
            Text(
              describeProgress(progress),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              waiting
                  ? 'Usually near the camera. Keep it still until it says Done.'
                  : 'Keep the card still.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: waiting ? null : progress.fraction),
            TextButton(onPressed: onCancel, child: const Text('Cancel')),
          ],
        ),
      ),
    );
  }
}

/// The package returns stages and error types; the app writes the words.
String describeProgress(ReadProgress p) => switch (p.stage) {
  ReadStage.waitingForCard =>
    p.attempt == 1
        ? 'Touch the document to the back of the phone'
        : 'The card moved. Put it back and hold it still',
  ReadStage.unlocking => 'Card found. Keep it still…',
  ReadStage.reading => 'Reading… ${(p.fraction * 100).round()}%',
  ReadStage.checking => 'Checking signatures…',
  ReadStage.done => 'Done',
};

String describeError(ReadException e) => switch (e) {
  NfcNotSupported() => 'This phone has no NFC.',
  NfcOff() => 'NFC is off. Turn it on in the phone settings.',
  NoCardFound() =>
    'No card found. Hold the document on the back of '
        'the phone and try again.',
  CardMoved() =>
    'The card moved away for too long. Try again and keep '
        'it still.',
  WrongKey() =>
    'The chip refused the 3 values. Check the document '
        'number and the dates.',
  UnsupportedDocument() =>
    'This chip is not an ID card, passport or driving licence.',
  ReadCancelled() => 'Cancelled.',
  ChipError(:final statusWord, :final during) =>
    'The chip refused ($during, ${statusWord.toRadixString(16)}).',
};

String _seconds(Duration d) =>
    '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';

String formatDate(DateTime d) =>
    '${d.year}.'
    '${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';

/// YYYY.MM.DD or DD.MM.YYYY, with `.`, `/`, `-` or spaces.
DateTime? parseDate(String text) {
  final parts = text.trim().split(RegExp(r'[./\-\s]+'));
  if (parts.length != 3 || parts.any((p) => int.tryParse(p) == null)) {
    return null;
  }
  final n = parts.map(int.parse).toList();
  final (y, m, d) = parts[0].length == 4
      ? (n[0], n[1], n[2])
      : (n[2], n[1], n[0]);
  if (y < 1900 || y > 2100) return null;
  final date = DateTime(y, m, d);
  return date.month == m && date.day == d ? date : null;
}
