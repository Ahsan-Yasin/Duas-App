import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/audio/quran_audio.dart' show reciters;
import '../../core/backup/backup_service.dart';
import '../../core/config.dart';
import '../../core/db/seed.dart' show seedIfEmpty;
import '../../core/models/models.dart';
import '../../core/navigation.dart';
import '../../core/net/llm_client.dart' show LlmException;
import '../../core/providers.dart';
import '../../core/widgets/common.dart';
import '../onboarding/onboarding_screen.dart';
import '../reliability/reliability_screen.dart';
import 'more_screen.dart' show showAppAbout;

/// Sections [SettingsScreen] can scroll to when opened.
enum SettingsSection { ai, backup }

const bismillahPreview = 'بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ';

const _languageSuggestions = [
  'Urdu',
  'English',
  'Arabic',
  'French',
  'Indonesian',
  'Turkish',
  'Bengali',
  'Malay',
  'Hindi',
];

const _customModel = '\u0000custom';

String _audioModeLabel(AudioMode m) => switch (m) {
      AudioMode.off => 'Off (read only)',
      AudioMode.listen => 'Listen',
      AudioMode.listenThenRecite => 'Listen, then recite',
      AudioMode.followAlong => 'Follow along',
    };

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _backupFileName() =>
    'daily_duas_backup_${DateFormat('yyyy-MM-dd').format(DateTime.now())}.json';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, this.initialSection});

  /// Scrolls to this section after opening.
  final SettingsSection? initialSection;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _geminiKey;
  late final TextEditingController _anthropicKey;
  late final TextEditingController _language;
  final _aiSectionKey = GlobalKey();
  final _backupSectionKey = GlobalKey();

  bool _obscureKey = true;
  bool _testing = false;
  (bool, String)? _testResult;
  bool _busy = false;
  Future<int>? _cacheSize;

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsProvider);
    _geminiKey = TextEditingController(text: s.geminiApiKey);
    _anthropicKey = TextEditingController(text: s.anthropicApiKey);
    _language = TextEditingController(text: s.translationLanguage);
    _cacheSize = _loadCacheSize();
    final section = widget.initialSection;
    if (section != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final key =
            section == SettingsSection.ai ? _aiSectionKey : _backupSectionKey;
        final ctx = key.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(ctx,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut);
        }
      });
    }
  }

  @override
  void dispose() {
    _geminiKey.dispose();
    _anthropicKey.dispose();
    _language.dispose();
    super.dispose();
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Applies and persists a settings change immediately.
  Future<void> _set(AppSettings Function(AppSettings s) change) async {
    try {
      await ref.read(settingsProvider.notifier).update(change);
    } catch (e) {
      _snack('Could not save the setting: $e');
    }
  }

  Future<int> _loadCacheSize() async {
    try {
      return await ref.read(quranAudioProvider).cacheSizeBytes();
    } catch (_) {
      return 0;
    }
  }

  void _refreshCacheSize() => setState(() => _cacheSize = _loadCacheSize());

  // ---------------------------------------------------------------------------
  // Audio downloads
  // ---------------------------------------------------------------------------

  Future<void> _downloadAudio() async {
    final reciter = ref.read(settingsProvider).reciter;
    final routineRepo = ref.read(routineRepoProvider);
    final cache = ref.read(quranAudioProvider);

    final ranges = <(int, int, int)>{};
    try {
      for (final r in await routineRepo.list()) {
        final id = r.id;
        if (id == null) continue;
        for (final (dua, _) in await routineRepo.resolvedItems(id)) {
          final s = dua.quranSurah;
          if (s == null) continue;
          final a = dua.quranAyahStart ?? 1;
          final e = dua.quranAyahEnd ?? a;
          ranges.add((s, a, e < a ? a : e));
        }
      }
    } catch (e) {
      _snack('Could not read your routines: $e');
      return;
    }
    if (ranges.isEmpty) {
      _snack('Your routines have no Quran duas with audio to download.');
      return;
    }
    if (!mounted) return;

    final total = ranges.fold<int>(0, (n, r) => n + r.$3 - r.$2 + 1);
    final progress = ValueNotifier<int>(0);
    var cancelled = false;
    var dialogOpen = true;
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Downloading audio'),
          content: ValueListenableBuilder<int>(
            valueListenable: progress,
            builder: (_, done, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: total == 0 ? null : done / total),
                const SizedBox(height: 12),
                Text('$done of $total verses'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancelled = true;
                dialogOpen = false;
                Navigator.of(ctx).pop();
              },
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );

    var base = 0;
    String? error;
    for (final (s, a, e) in ranges) {
      if (cancelled) break;
      try {
        await cache.ensureAyahs(reciter, s, a, e,
            onProgress: (done, _) => progress.value = base + done);
      } catch (err) {
        error = '$err';
        break;
      }
      base += e - a + 1;
      progress.value = base;
    }
    if (dialogOpen) {
      dialogOpen = false;
      navigator.pop();
    }
    progress.dispose();
    if (!mounted) return;
    _refreshCacheSize();
    if (error != null) {
      _snack('Download stopped. Check your internet connection and try again.');
    } else if (cancelled) {
      _snack('Download cancelled. Verses already saved stay offline.');
    } else {
      _snack('Audio for $total verses is saved for offline use.');
    }
  }

  Future<void> _clearCache() async {
    final ok = await confirmDialog(
      context,
      title: 'Delete downloaded audio?',
      message:
          'Quran recitations will download again the next time you play them.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    try {
      await ref.read(quranAudioProvider).clear();
      _snack('Downloaded audio deleted.');
    } catch (e) {
      _snack('Could not delete audio: $e');
    }
    if (mounted) _refreshCacheSize();
  }

  // ---------------------------------------------------------------------------
  // AI
  // ---------------------------------------------------------------------------

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    (bool, String) result;
    try {
      final msg = await ref.read(llmClientProvider).testConnection();
      result = (true, msg.trim().isEmpty ? 'Connected.' : msg);
    } on LlmException catch (e) {
      result = (false, e.fullMessage);
    } catch (e) {
      result = (false, 'Connection failed: $e');
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = result;
    });
  }

  Future<void> _pickModel(String value, bool gemini, String current) async {
    var model = value;
    if (value == _customModel) {
      final typed = await textPromptDialog(
        context,
        title: 'Custom model',
        initial: current,
        label: 'Model ID',
        confirmLabel: 'Use model',
      );
      if (typed == null) return;
      model = typed;
    }
    await _set((s) =>
        gemini ? s.copyWith(geminiModel: model) : s.copyWith(anthropicModel: model));
    if (mounted) setState(() => _testResult = null);
  }

  // ---------------------------------------------------------------------------
  // Backup
  // ---------------------------------------------------------------------------

  Future<void> _shareBackup() async {
    setState(() => _busy = true);
    try {
      final json = await ref.read(backupServiceProvider).exportJson();
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, _backupFileName()));
      await file.writeAsString(json, flush: true);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'application/json')],
        subject: 'Daily Duas backup',
      ));
    } catch (e) {
      _snack('Export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveBackup() async {
    setState(() => _busy = true);
    try {
      final json = await ref.read(backupServiceProvider).exportJson();
      final uri = await FilePicker.saveFile(
        fileName: _backupFileName(),
        bytes: Uint8List.fromList(utf8.encode(json)),
        mimeType: 'application/json',
        dialogTitle: 'Save Daily Duas backup',
      );
      if (uri != null) _snack('Backup saved.');
    } catch (e) {
      _snack('Could not save the backup: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importBackup() async {
    final PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(
          type: FileType.any, dialogTitle: 'Choose a Daily Duas backup');
    } catch (e) {
      _snack('Could not open the file picker: $e');
      return;
    }
    if (picked == null) return;

    Map<String, dynamic> data;
    try {
      final bytes = await picked.readAsBytes();
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic> || decoded['app'] != backupAppId) {
        throw const FormatException('not a backup');
      }
      data = decoded;
    } catch (_) {
      _snack('This file is not a Daily Duas backup.');
      return;
    }
    if (!mounted) return;

    final replace = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import backup'),
        content: const Text(
            'Merge adds the duas, routines, reminders and history from the backup to what you already have (duplicates are skipped).\n\n'
            'Replace deletes your current data first.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Replace')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Merge')),
        ],
      ),
    );
    if (replace == null || !mounted) return;
    if (replace) {
      final sure = await confirmDialog(
        context,
        title: 'Replace all data?',
        message:
            'Your current duas, routines, reminders and history will be deleted and replaced by the backup. This cannot be undone.',
        confirmLabel: 'Replace',
        destructive: true,
      );
      if (!sure || !mounted) return;
    }

    setState(() => _busy = true);
    ImportReport report;
    try {
      report =
          await ref.read(backupServiceProvider).import(data, replace: replace);
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      _snack('Import failed: $e');
      return;
    }
    if (!mounted) return;
    if (replace) {
      // Bring back the built-in duas if the backup did not contain them.
      try {
        await seedIfEmpty(ref.read(databaseProvider), rootBundle.loadString);
      } catch (_) {
        // The imported data is still usable without the built-ins.
      }
      if (!mounted) return;
    }
    invalidateData(ref);
    try {
      final fresh = await ref.read(settingsRepoProvider).load();
      await ref.read(settingsProvider.notifier).update((_) => fresh);
      _geminiKey.text = fresh.geminiApiKey;
      _anthropicKey.text = fresh.anthropicApiKey;
      _language.text = fresh.translationLanguage;
    } catch (_) {
      // Keep current settings.
    }
    try {
      await ref.read(alarmServiceProvider).sync('import');
    } catch (_) {
      // Retried on next resume.
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(report.hasErrors ? 'Import finished with problems' : 'Import finished'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Duas added: ${report.duasAdded}'
                  '${report.duasSkipped > 0 ? ' (${report.duasSkipped} already in your library)' : ''}'),
              Text('Routines added: ${report.routinesAdded}'),
              Text('Reminders added: ${report.remindersAdded}'),
              Text('History entries added: ${report.logsAdded}'),
              if (report.hasErrors) ...[
                const SizedBox(height: 12),
                Text('Problems:', style: Theme.of(ctx).textTheme.titleSmall),
                for (final e in report.errors.take(10)) Text('• $e'),
                if (report.errors.length > 10)
                  Text('…and ${report.errors.length - 10} more'),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final theme = Theme.of(context);
    final routines = ref.watch(routinesProvider).value ?? const <Routine>[];

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_busy) const LinearProgressIndicator(),
            // ---------------- Appearance
            const _Header('Appearance'),
            _Padded(
              child: SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('System'),
                      icon: Icon(Icons.brightness_auto)),
                  ButtonSegment(
                      value: ThemeMode.light,
                      label: Text('Light'),
                      icon: Icon(Icons.light_mode_outlined)),
                  ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text('Dark'),
                      icon: Icon(Icons.dark_mode_outlined)),
                ],
                selected: {s.themeMode},
                onSelectionChanged: (v) =>
                    _set((x) => x.copyWith(themeMode: v.first)),
              ),
            ),
            // ---------------- Reading
            const _Header('Reading'),
            _Padded(
              child: Text('Arabic text size: ${s.arabicFontSize}',
                  style: theme.textTheme.bodyLarge),
            ),
            Slider(
              value: s.arabicFontSize
                  .clamp(minArabicFontSize, maxArabicFontSize)
                  .toDouble(),
              min: minArabicFontSize.toDouble(),
              max: maxArabicFontSize.toDouble(),
              divisions: maxArabicFontSize - minArabicFontSize,
              label: '${s.arabicFontSize}',
              semanticFormatterCallback: (v) => 'Arabic text size ${v.round()}',
              onChanged: (v) =>
                  _set((x) => x.copyWith(arabicFontSize: v.round())),
            ),
            _Padded(
              child: Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: ArabicText(
                    bismillahPreview,
                    key: const ValueKey('arabicFontPreview'),
                    size: s.arabicFontSize.toDouble(),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
            SwitchListTile(
              title: const Text('Show transliteration'),
              value: s.showTransliteration,
              onChanged: (v) =>
                  _set((x) => x.copyWith(showTransliteration: v)),
            ),
            SwitchListTile(
              title: const Text('Show translation'),
              value: s.showTranslation,
              onChanged: (v) => _set((x) => x.copyWith(showTranslation: v)),
            ),
            _Padded(
              child: TextField(
                controller: _language,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Translation language',
                  helperText:
                      'Used when you ask the AI to translate a dua (needs internet).',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) {
                  final t = v.trim();
                  if (t.isNotEmpty) {
                    _set((x) => x.copyWith(translationLanguage: t));
                  }
                },
              ),
            ),
            _Padded(
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final lang in _languageSuggestions)
                    ChoiceChip(
                      label: Text(lang),
                      selected: s.translationLanguage.toLowerCase() ==
                          lang.toLowerCase(),
                      onSelected: (_) {
                        _language.text = lang;
                        _set((x) => x.copyWith(translationLanguage: lang));
                      },
                    ),
                ],
              ),
            ),
            // ---------------- Reciting
            const _Header('Reciting'),
            SwitchListTile(
              title: const Text('Haptic feedback'),
              subtitle: const Text('Vibrate lightly on each count'),
              value: s.haptics,
              onChanged: (v) => _set((x) => x.copyWith(haptics: v)),
            ),
            _Padded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Counter', style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 8),
                  SegmentedButton<CounterMode>(
                    segments: const [
                      ButtonSegment(
                          value: CounterMode.countUp,
                          label: Text('Count up'),
                          icon: Icon(Icons.arrow_upward)),
                      ButtonSegment(
                          value: CounterMode.countDown,
                          label: Text('Count down'),
                          icon: Icon(Icons.arrow_downward)),
                    ],
                    selected: {s.counterMode},
                    onSelectionChanged: (v) =>
                        _set((x) => x.copyWith(counterMode: v.first)),
                  ),
                ],
              ),
            ),
            SwitchListTile(
              title: const Text('Auto-advance'),
              subtitle:
                  const Text('Move to the next dua when the count is reached'),
              value: s.autoAdvance,
              onChanged: (v) => _set((x) => x.copyWith(autoAdvance: v)),
            ),
            // ---------------- Audio
            const _Header('Audio'),
            _Padded(
              child: _Dropdown<AudioMode>(
                label: 'Default audio mode',
                value: s.audioMode,
                items: {
                  for (final m in AudioMode.values) m: _audioModeLabel(m),
                },
                onChanged: (m) => _set((x) => x.copyWith(audioMode: m)),
              ),
            ),
            _Padded(
              child: _Dropdown<String>(
                label: 'Quran reciter',
                value: s.reciter,
                items: {
                  for (final (folder, name) in reciters) folder: name,
                  if (!reciters.any((r) => r.$1 == s.reciter))
                    s.reciter: s.reciter,
                },
                onChanged: (r) => _set((x) => x.copyWith(reciter: r)),
              ),
            ),
            _Padded(
              child: Text(
                  'Playback speed: ${s.playbackRate.toStringAsFixed(2)}×',
                  style: theme.textTheme.bodyLarge),
            ),
            Slider(
              value: s.playbackRate.clamp(0.75, 1.25),
              min: 0.75,
              max: 1.25,
              divisions: 10,
              label: '${s.playbackRate.toStringAsFixed(2)}×',
              semanticFormatterCallback: (v) =>
                  'Playback speed ${v.toStringAsFixed(2)}',
              onChanged: (v) => _set((x) =>
                  x.copyWith(playbackRate: double.parse(v.toStringAsFixed(2)))),
            ),
            ListTile(
              leading: const Icon(Icons.download_for_offline_outlined),
              title: const Text('Download audio for my routines'),
              subtitle: const Text(
                  'Saves the Quran recitations used in your routines for offline use.'),
              onTap: _busy ? null : _downloadAudio,
            ),
            FutureBuilder<int>(
              future: _cacheSize,
              builder: (context, snap) => ListTile(
                leading: const Icon(Icons.sd_storage_outlined),
                title: const Text('Downloaded audio'),
                subtitle: Text(snap.hasData
                    ? _formatBytes(snap.data!)
                    : 'Calculating…'),
                trailing: TextButton(
                  onPressed: (snap.data ?? 0) > 0 ? _clearCache : null,
                  child: const Text('Clear'),
                ),
              ),
            ),
            // ---------------- AI
            _Header('AI assistant', key: _aiSectionKey),
            ..._aiSection(context, s),
            // ---------------- Reminders
            const _Header('Reminders'),
            _Padded(
              child: Row(
                children: [
                  Expanded(
                    child: Text('Default snooze',
                        style: theme.textTheme.bodyLarge),
                  ),
                  NumberStepper(
                    value: s.defaultSnoozeMinutes.clamp(1, 30),
                    min: 1,
                    max: 30,
                    label: 'Snooze minutes',
                    onChanged: (v) =>
                        _set((x) => x.copyWith(defaultSnoozeMinutes: v)),
                  ),
                  const Text('min'),
                ],
              ),
            ),
            _Padded(
              child: routines.isEmpty
                  ? const Text('Create a routine to choose a default.')
                  : _Dropdown<int>(
                      label: 'Default routine',
                      helper: 'Used for new reminders and the test alarm.',
                      value: routines.any((r) => r.id == s.defaultRoutineId)
                          ? s.defaultRoutineId
                          : null,
                      items: {
                        for (final r in routines)
                          if (r.id != null) r.id!: r.name,
                      },
                      onChanged: (id) =>
                          _set((x) => x.copyWith(defaultRoutineId: id)),
                    ),
            ),
            ListTile(
              leading: const Icon(Icons.health_and_safety_outlined),
              title: const Text('Alarm reliability'),
              subtitle: const Text('Check permissions and battery settings'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => pushScreen<void>(const ReliabilityScreen()),
            ),
            // ---------------- Backup
            _Header('Backup & restore', key: _backupSectionKey),
            _Padded(
              child: Text(
                'Backups contain your duas, routines, reminders, history and settings. API keys are never included.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Export and share'),
              subtitle: const Text('Send the backup to Drive, email or a chat'),
              onTap: _busy ? null : _shareBackup,
            ),
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('Save to device'),
              subtitle: const Text('Choose a folder for the backup file'),
              onTap: _busy ? null : _saveBackup,
            ),
            ListTile(
              leading: const Icon(Icons.restore),
              title: const Text('Import a backup'),
              subtitle: const Text('Merge with or replace your current data'),
              onTap: _busy ? null : _importBackup,
            ),
            // ---------------- Other
            const _Header('Other'),
            ListTile(
              leading: const Icon(Icons.school_outlined),
              title: const Text('Show onboarding again'),
              onTap: () => pushScreen<void>(
                OnboardingScreen(
                    onDone: () => navigatorKey.currentState?.maybePop()),
                fullscreenDialog: true,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('About'),
              subtitle: Text('$appName $appVersion'),
              onTap: () => showAppAbout(context, s.reciter),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _aiSection(BuildContext context, AppSettings s) {
    final theme = Theme.of(context);
    final gemini = s.llmProvider != 'anthropic';
    final controller = gemini ? _geminiKey : _anthropicKey;
    final keyEmpty = controller.text.trim().isEmpty;
    final models = gemini ? defaultGeminiModels : anthropicModels;
    final current = gemini ? s.geminiModel : s.anthropicModel;
    final String helper;
    if (gemini) {
      helper = keyEmpty
          ? 'Using built-in key'
          : 'Your own key, stored only on this device.';
    } else {
      helper = keyEmpty
          ? 'Required for Anthropic. Stored only on this device.'
          : 'Stored only on this device.';
    }

    return [
      _Padded(
        child: Text(
          'Used by "Ask for a dua" and translations. Needs internet. AI can make mistakes — always verify.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
      _Padded(
        child: SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'gemini', label: Text('Gemini')),
            ButtonSegment(value: 'anthropic', label: Text('Anthropic')),
          ],
          selected: {gemini ? 'gemini' : 'anthropic'},
          onSelectionChanged: (v) {
            setState(() => _testResult = null);
            _set((x) => x.copyWith(llmProvider: v.first));
          },
        ),
      ),
      _Padded(
        child: TextField(
          key: ValueKey('api-key-${gemini ? 'gemini' : 'anthropic'}'),
          controller: controller,
          obscureText: _obscureKey,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          decoration: InputDecoration(
            labelText: gemini ? 'Gemini API key' : 'Anthropic API key',
            helperText: helper,
            border: const OutlineInputBorder(),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: _obscureKey ? 'Show key' : 'Hide key',
                  icon: Icon(_obscureKey
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscureKey = !_obscureKey),
                ),
                if (!keyEmpty)
                  IconButton(
                    tooltip: gemini
                        ? 'Clear key and use the built-in key'
                        : 'Clear key',
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      controller.clear();
                      setState(() => _testResult = null);
                      _set((x) => gemini
                          ? x.copyWith(geminiApiKey: '')
                          : x.copyWith(anthropicApiKey: ''));
                    },
                  ),
              ],
            ),
          ),
          onChanged: (v) {
            setState(() => _testResult = null);
            final key = v.trim();
            _set((x) => gemini
                ? x.copyWith(geminiApiKey: key)
                : x.copyWith(anthropicApiKey: key));
          },
        ),
      ),
      _Padded(
        child: _Dropdown<String>(
          label: 'Model',
          value: current,
          items: {
            for (final m in models) m: m,
            if (!models.contains(current)) current: '$current (custom)',
            _customModel: 'Custom model…',
          },
          onChanged: (v) => _pickModel(v, gemini, current),
        ),
      ),
      _Padded(
        child: Row(
          children: [
            OutlinedButton.icon(
              onPressed: _testing ? null : _testConnection,
              icon: _testing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_tethering),
              label: const Text('Test connection'),
            ),
          ],
        ),
      ),
      if (_testResult != null)
        _Padded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _testResult!.$1 ? Icons.check_circle : Icons.error_outline,
                color: _testResult!.$1
                    ? theme.colorScheme.primary
                    : theme.colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(child: SelectableText(_testResult!.$2)),
            ],
          ),
        ),
    ];
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

class _Padded extends StatelessWidget {
  const _Padded({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: child,
      );
}

/// Outlined dropdown with a label; [items] maps values to display text.
class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.helper,
  });

  final String label;
  final String? helper;
  final T? value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        border: const OutlineInputBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          isExpanded: true,
          value: items.containsKey(value) ? value : null,
          hint: const Text('Choose'),
          items: [
            for (final e in items.entries)
              DropdownMenuItem<T>(
                value: e.key,
                child: Text(e.value, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}
