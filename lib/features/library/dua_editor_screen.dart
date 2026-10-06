import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/audio/dua_player.dart';
import '../../core/models/models.dart';
import '../../core/net/hadith_client.dart';
import '../../core/net/llm_client.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/util.dart';
import '../../core/widgets/common.dart';
import '../../domain/arabic.dart';
import '../../domain/hadith_ref.dart';
import '../../domain/quran_index.dart';
import '../../domain/verification.dart';
import 'library_screen.dart';

/// Opens [url] (quran.com / sunnah.com) in the browser; shows a SnackBar when
/// no app can open it.
Future<void> openSourceLink(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  var ok = false;
  try {
    ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    ok = false;
  }
  if (!ok) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Could not open the link.')));
  }
}

/// Add or edit a dua. Pass [duaId] to edit, [initial] to prefill a new dua
/// (e.g. from a chat suggestion).
class DuaEditorScreen extends ConsumerStatefulWidget {
  const DuaEditorScreen({super.key, this.duaId, this.initial});

  final int? duaId;
  final DuaSuggestion? initial;

  @override
  ConsumerState<DuaEditorScreen> createState() => _DuaEditorScreenState();
}

class _DuaEditorScreenState extends ConsumerState<DuaEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _arabic = TextEditingController();
  final _transliteration = TextEditingController();
  final _translation = TextEditingController();
  final _source = TextEditingController();
  final _category = TextEditingController();
  final _surah = TextEditingController();
  final _ayahStart = TextEditingController();
  final _ayahEnd = TextEditingController();

  Dua? _original;
  bool _loading = false;
  String? _loadError;
  bool _saving = false;
  bool _dirty = false;
  bool _filling = false;

  int _repeat = 1;
  AudioKind _audioKind = AudioKind.none;
  String? _audioPath;

  AudioRecorder? _recorder;
  bool _recording = false;
  Timer? _recTimer;
  Duration _recElapsed = Duration.zero;
  bool _previewing = false;
  DuaPlayer? _previewPlayer;
  StreamSubscription<int>? _previewSub;

  String? _translated;
  bool _translating = false;
  String? _translateError;

  /// Result of "Check source online", valid for [_hadithCheckedFor].
  HadithVerification? _hadithResult;
  String? _hadithCheckedFor;
  bool _checkingHadith = false;

  bool get _isNew => widget.duaId == null;

  String get _hadithKey => '${_arabic.text.trim()}\n${_source.text.trim()}';

  /// The online hadith check for the current Arabic + source, if any.
  HadithVerification? get _currentHadith =>
      _hadithCheckedFor == _hadithKey ? _hadithResult : null;

  /// Non-Quran dua with a source: the hadith check applies.
  bool get _canCheckHadith =>
      _source.text.trim().isNotEmpty &&
      !_hasQuranRef &&
      parseQuranRef(_source.text) == null;

  void _onTextChanged() {
    if (_filling || !mounted) return;
    setState(() {});
  }

  Future<void> _checkHadith() async {
    final key = _hadithKey;
    setState(() => _checkingHadith = true);
    final result = await ref.read(hadithClientProvider).verify(
          arabic: _arabic.text.trim(),
          source: _source.text.trim(),
        );
    if (!mounted) return;
    setState(() {
      _checkingHadith = false;
      _hadithResult = result;
      _hadithCheckedFor = key;
      _dirty = true;
    });
  }

  List<TextEditingController> get _controllers => [
        _title,
        _arabic,
        _transliteration,
        _translation,
        _source,
        _category,
        _surah,
        _ayahStart,
        _ayahEnd,
      ];

  @override
  void initState() {
    super.initState();
    for (final c in _controllers) {
      c.addListener(_markDirty);
    }
    _source.addListener(_autofillQuranRef);
    for (final c in [_source, _arabic, _surah]) {
      c.addListener(_onTextChanged);
    }
    if (widget.duaId != null) {
      _load(widget.duaId!);
    } else {
      _prefill(widget.initial);
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    _recTimer?.cancel();
    _previewSub?.cancel();
    if (_previewing) _previewPlayer?.stop().catchError((_) {});
    final rec = _recorder;
    if (rec != null) {
      if (_recording) {
        rec.cancel().catchError((_) {});
        WakelockPlus.disable().catchError((_) {});
      }
      rec.dispose().catchError((_) {});
    }
    super.dispose();
  }

  void _markDirty() {
    if (_filling || _dirty) return;
    setState(() => _dirty = true);
  }

  void _fill(void Function() body) {
    _filling = true;
    try {
      body();
    } finally {
      _filling = false;
    }
  }

  void _prefill(DuaSuggestion? s) {
    _fill(() {
      _category.text = 'General';
      if (s == null) return;
      _title.text = s.title;
      _arabic.text = s.arabic;
      _transliteration.text = s.transliteration;
      _translation.text = s.translation;
      _source.text = s.source;
      _category.text = s.category.trim().isEmpty ? 'General' : s.category;
      _repeat = s.repeat.clamp(1, 100);
      final q = s.quran;
      if (q != null) {
        final surah = asInt(q['surah']);
        final start = asInt(q['ayah_start'] ?? q['ayahStart']);
        final end = asInt(q['ayah_end'] ?? q['ayahEnd']);
        if (surah != null) _surah.text = '$surah';
        if (start != null) _ayahStart.text = '$start';
        if (end != null) _ayahEnd.text = '$end';
      } else {
        _autofillQuranRef();
      }
      if (s.isQuran && _surah.text.isNotEmpty) _audioKind = AudioKind.quran;
    });
    // A suggestion counts as unsaved work.
    _dirty = s != null;
  }

  Future<void> _load(int id) async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final dua = await ref.read(duaRepoProvider).get(id);
      if (!mounted) return;
      if (dua == null) {
        setState(() {
          _loading = false;
          _loadError = 'This dua no longer exists.';
        });
        return;
      }
      _fill(() {
        _original = dua;
        _title.text = dua.title;
        _arabic.text = dua.arabic;
        _transliteration.text = dua.transliteration;
        _translation.text = dua.translation;
        _source.text = dua.source;
        _category.text = dua.category;
        _surah.text = dua.quranSurah?.toString() ?? '';
        _ayahStart.text = dua.quranAyahStart?.toString() ?? '';
        _ayahEnd.text = dua.quranAyahEnd?.toString() ?? '';
        _repeat = dua.defaultRepeat.clamp(1, 100);
        _audioKind = dua.audioKind;
        _audioPath = dua.audioPath;
      });
      setState(() {
        _loading = false;
        _dirty = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'Could not load this dua.\n$e';
      });
    }
  }

  /// Fills the Quran reference from the source text ("Quran 2:255") when the
  /// reference fields are still empty.
  void _autofillQuranRef() {
    if (_surah.text.trim().isNotEmpty) return;
    final parsed = parseQuranRef(_source.text);
    if (parsed == null) return;
    final (s, a, e) = parsed;
    var end = e;
    if (end <= 0) {
      end = ref.read(quranIndexProvider).value?.ayahCount(s) ?? 0;
    }
    _surah.text = '$s';
    _ayahStart.text = '$a';
    _ayahEnd.text = end > 0 ? '$end' : '';
  }

  // ---------------------------------------------------------------------------
  // Quran reference
  // ---------------------------------------------------------------------------

  bool get _hasQuranRef =>
      _surah.text.trim().isNotEmpty ||
      _ayahStart.text.trim().isNotEmpty ||
      _ayahEnd.text.trim().isNotEmpty;

  /// Parsed reference, or null when the fields are empty. Validation is done
  /// by the form validators.
  (int, int, int)? _quranRef() {
    if (!_hasQuranRef) return null;
    final s = int.tryParse(_surah.text.trim());
    final a = int.tryParse(_ayahStart.text.trim()) ?? 1;
    final e = int.tryParse(_ayahEnd.text.trim()) ?? a;
    if (s == null) return null;
    return (s, a, e);
  }

  String? _validateSurah(String? v) {
    if (!_hasQuranRef) return null;
    final s = int.tryParse((v ?? '').trim());
    if (s == null || s < 1 || s > 114) return 'Surah 1–114';
    return null;
  }

  String? _validateAyahStart(String? v) {
    if (!_hasQuranRef) return null;
    final text = (v ?? '').trim();
    if (text.isEmpty) return 'Required';
    final a = int.tryParse(text);
    if (a == null || a < 1) return 'From 1';
    final s = int.tryParse(_surah.text.trim());
    final count = s == null ? 0 : (ref.read(quranIndexProvider).value?.ayahCount(s) ?? 0);
    if (count > 0 && a > count) return 'Max $count';
    return null;
  }

  String? _validateAyahEnd(String? v) {
    if (!_hasQuranRef) return null;
    final text = (v ?? '').trim();
    if (text.isEmpty) return null; // same as start
    final e = int.tryParse(text);
    final a = int.tryParse(_ayahStart.text.trim()) ?? 1;
    if (e == null || e < a) return '≥ start';
    final s = int.tryParse(_surah.text.trim());
    final count = s == null ? 0 : (ref.read(quranIndexProvider).value?.ayahCount(s) ?? 0);
    if (count > 0 && e > count) return 'Max $count';
    return null;
  }

  // ---------------------------------------------------------------------------
  // Audio
  // ---------------------------------------------------------------------------

  Future<Directory> _userAudioDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'user_audio'));
    await dir.create(recursive: true);
    return dir;
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickAudio() async {
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.audio,
        dialogTitle: 'Choose an audio file',
      );
      if (picked == null) return;
      final dir = await _userAudioDir();
      final ext = (picked.extension ?? 'mp3').toLowerCase();
      final dest = File(
        p.join(dir.path, 'audio_${DateTime.now().millisecondsSinceEpoch}.$ext'),
      );
      final srcPath = picked.path;
      if (srcPath != null && File(srcPath).existsSync()) {
        await File(srcPath).copy(dest.path);
      } else {
        final sink = dest.openWrite();
        await sink.addStream(picked.readAsByteStream());
        await sink.close();
      }
      if (!mounted) return;
      setState(() {
        _audioPath = dest.path;
        _audioKind = AudioKind.file;
        _dirty = true;
      });
    } catch (e) {
      _snack('Could not use that file. Please try another one.');
    }
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      await _stopRecording();
      return;
    }
    try {
      final rec = _recorder ??= AudioRecorder();
      if (!await rec.hasPermission()) {
        _snack('Microphone permission is needed to record. '
            'You can allow it in the app settings.');
        return;
      }
      final dir = await _userAudioDir();
      final path = p.join(
        dir.path,
        'recording_${DateTime.now().millisecondsSinceEpoch}.m4a',
      );
      await rec.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: path,
      );
      unawaited(WakelockPlus.enable().catchError((_) {}));
      final started = DateTime.now();
      _recTimer?.cancel();
      _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recElapsed = DateTime.now().difference(started));
      });
      if (!mounted) return;
      setState(() {
        _recording = true;
        _recElapsed = Duration.zero;
      });
    } catch (e) {
      _snack('Could not start recording: $e');
    }
  }

  Future<void> _stopRecording() async {
    _recTimer?.cancel();
    _recTimer = null;
    String? path;
    try {
      path = await _recorder?.stop();
    } catch (e) {
      _snack('Recording failed: $e');
    }
    unawaited(WakelockPlus.disable().catchError((_) {}));
    if (!mounted) return;
    setState(() {
      _recording = false;
      if (path != null) {
        _audioPath = path;
        _audioKind = AudioKind.file;
        _dirty = true;
      }
    });
  }

  Future<void> _togglePreview() async {
    final player = ref.read(duaPlayerProvider);
    if (_previewing) {
      await _stopPreview();
      return;
    }
    final path = _audioPath;
    if (path == null || !File(path).existsSync()) {
      _snack('The audio file is missing. Pick or record it again.');
      return;
    }
    _previewPlayer = player;
    await _previewSub?.cancel();
    _previewSub = player.passCompletedStream.listen((_) {
      _previewSub?.cancel();
      _previewSub = null;
      if (mounted) setState(() => _previewing = false);
    });
    setState(() => _previewing = true);
    try {
      await player.playFiles([path], title: _title.text.trim(), subtitle: 'Preview');
    } catch (e) {
      _snack('Could not play this file.');
      await _stopPreview();
    }
  }

  Future<void> _stopPreview() async {
    await _previewSub?.cancel();
    _previewSub = null;
    try {
      await _previewPlayer?.stop();
    } catch (_) {
      // Already stopped.
    }
    if (mounted) setState(() => _previewing = false);
  }

  // ---------------------------------------------------------------------------
  // Translate
  // ---------------------------------------------------------------------------

  Future<void> _translate({bool refresh = false}) async {
    final dua = _original;
    final id = dua?.id;
    if (dua == null || id == null) return;
    final lang = ref.read(settingsProvider).translationLanguage;
    setState(() {
      _translating = true;
      _translateError = null;
    });
    try {
      final repo = ref.read(translationRepoProvider);
      String? text = refresh ? null : await repo.get(id, lang);
      if (text == null) {
        text = await ref.read(llmClientProvider).translate(dua.arabic, lang);
        await repo.put(id, lang, text);
      }
      if (!mounted) return;
      setState(() => _translated = text);
    } on LlmException catch (e) {
      if (mounted) setState(() => _translateError = e.userMessage);
    } catch (_) {
      if (mounted) {
        setState(() => _translateError =
            'Translation needs an internet connection. Please check it and try again.');
      }
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Save / delete
  // ---------------------------------------------------------------------------

  Future<void> _save() async {
    if (_saving || _recording) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final quranRef = _quranRef();
    if (_audioKind == AudioKind.quran && quranRef == null) {
      _snack('Add the surah and ayah numbers to use Quran audio.');
      return;
    }
    if (_audioKind == AudioKind.file && _audioPath == null) {
      _snack('Pick or record an audio file, or choose another audio option.');
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(duaRepoProvider);
      final orig = _original;
      final arabic = _arabic.text.trim();
      final source = _source.text.trim();
      final arabicChanged = orig == null || orig.arabic.trim() != arabic;
      final refChanged = orig == null ||
          orig.quranSurah != quranRef?.$1 ||
          orig.quranAyahStart != quranRef?.$2 ||
          orig.quranAyahEnd != quranRef?.$3;

      var status = orig?.verificationStatus ?? VerificationStatus.unverified;
      var note = orig?.verificationNote ?? '';
      var quranVerified = false;
      if (arabicChanged || refChanged) {
        try {
          final index = await ref.read(quranIndexProvider.future);
          final result = verifyDua(
            arabic: arabic,
            source: source,
            quran: index,
            claimedQuran: quranRef == null
                ? null
                : {
                    'surah': quranRef.$1,
                    'ayah_start': quranRef.$2,
                    'ayah_end': quranRef.$3,
                  },
          );
          status = result.status;
          note = result.note;
          quranVerified = result.isVerified && result.kind == 'quran';
        } catch (e) {
          status = VerificationStatus.unverified;
          note = 'Could not check the text. Confirm it with a reliable source.';
        }
      }
      // The online hadith check (when run for this exact text and source)
      // replaces the offline "hadith wording" note.
      final hadith = _currentHadith;
      if (hadith != null && quranRef == null && !quranVerified) {
        status = hadith.status;
        note = hadith.note;
      }
      if (!mounted) return;

      final now = nowIso();
      final category = _category.text.trim();
      final keepAyahs = !arabicChanged && !refChanged;
      final dua = (orig ?? Dua(title: '', arabic: '', createdAt: now)).copyWith(
        title: _title.text.trim(),
        arabic: arabic,
        transliteration: _transliteration.text.trim(),
        translation: _translation.text.trim(),
        source: source,
        category: category.isEmpty ? 'General' : category,
        defaultRepeat: _repeat.clamp(1, 100),
        audioKind: _audioKind,
        audioPath: _audioKind == AudioKind.file ? _audioPath : null,
        quranSurah: quranRef?.$1,
        quranAyahStart: quranRef?.$2,
        quranAyahEnd: quranRef?.$3,
        ayahs: keepAyahs ? orig.ayahs : null,
        verificationStatus: status,
        verificationNote: note,
        updatedAt: now,
      );

      if (orig == null) {
        final dup = await repo.findDuplicate(arabic);
        if (!mounted) return;
        if (dup != null) {
          final again = await confirmDialog(
            context,
            title: 'Already in your library',
            message: 'A dua with the same Arabic text is saved as "${dup.title}". '
                'Save another copy?',
            confirmLabel: 'Save copy',
          );
          if (!again) return;
        }
        await repo.add(dua);
      } else {
        await repo.update(dua);
      }
      if (!mounted) return;
      invalidateData(ref);
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              (arabicChanged || refChanged) &&
                      quranRef != null &&
                      status == VerificationStatus.unverified
                  ? 'Saved. $note'
                  : 'Saved',
            ),
          ),
        );
    } catch (e) {
      _snack('Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final dua = _original;
    if (dua == null) return;
    final nav = Navigator.of(context);
    try {
      await deleteDuaWithUndo(context, dua);
      nav.pop(false);
    } catch (e) {
      _snack('Could not delete: $e');
    }
  }

  Future<void> _confirmDiscard() async {
    final discard = await confirmDialog(
      context,
      title: 'Discard changes?',
      message: 'Your edits to this dua will be lost.',
      confirmLabel: 'Discard',
      destructive: true,
    );
    if (discard && mounted) Navigator.of(context).pop();
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final title = _isNew ? 'Add dua' : 'Edit dua';
    Widget body;
    if (_loading) {
      body = const LoadingState();
    } else if (_loadError != null) {
      body = ErrorState(
        message: _loadError!,
        onRetry: widget.duaId == null ? null : () => _load(widget.duaId!),
      );
    } else {
      body = _form(context);
    }
    final canSave = !_loading && _loadError == null && !_saving && !_recording;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmDiscard();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          actions: [
            if (_original != null)
              IconButton(
                tooltip: 'Delete dua',
                icon: const Icon(Icons.delete_outline),
                onPressed: _saving ? null : _delete,
              ),
            IconButton(
              tooltip: 'Save',
              icon: const Icon(Icons.check),
              onPressed: canSave ? _save : null,
            ),
          ],
        ),
        body: body,
        bottomNavigationBar: (_loading || _loadError != null)
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: FilledButton.icon(
                    onPressed: canSave ? _save : null,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(_saving ? 'Saving…' : 'Save'),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _form(BuildContext context) {
    final theme = Theme.of(context);
    final fontSize = ref.watch(settingsProvider.select((s) => s.arabicFontSize)).toDouble();
    final categories = ref.watch(categoriesProvider).value ?? const <String>[];
    final entries = {'General', ...categories}.toList();
    final orig = _original;

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (widget.initial != null)
            Card(
              color: theme.colorScheme.tertiaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Suggested by the assistant. Check the Arabic carefully '
                  'with a mushaf or a teacher before relying on it.',
                  style: TextStyle(color: theme.colorScheme.onTertiaryContainer),
                ),
              ),
            ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Title *'),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Please enter a title' : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _arabic,
            textDirection: TextDirection.rtl,
            textAlign: TextAlign.right,
            minLines: 3,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            style: TextStyle(
              fontFamily: arabicFontFamily,
              fontSize: fontSize.clamp(20, 40),
              height: 1.9,
            ),
            decoration: const InputDecoration(
              labelText: 'Arabic *',
              alignLabelWithHint: true,
            ),
            validator: (v) {
              final text = (v ?? '').trim();
              if (text.isEmpty) return 'Please enter the Arabic text';
              if (!isArabic(text)) return 'This does not look like Arabic text';
              return null;
            },
          ),
          if (orig != null) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                VerificationChip(
                  status: orig.verificationStatus,
                  note: orig.verificationNote,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    orig.verificationNote,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          TextFormField(
            controller: _transliteration,
            minLines: 1,
            maxLines: null,
            decoration: const InputDecoration(labelText: 'Transliteration'),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _translation,
            minLines: 2,
            maxLines: null,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Translation',
              alignLabelWithHint: true,
            ),
          ),
          if (orig != null) _translateSection(theme),
          const SizedBox(height: 16),
          TextFormField(
            controller: _source,
            decoration: const InputDecoration(
              labelText: 'Source',
              hintText: 'e.g. Quran 2:201 or Sahih Muslim 2723',
            ),
          ),
          _sourceActions(theme),
          const SizedBox(height: 16),
          DropdownMenu<String>(
            controller: _category,
            expandedInsets: EdgeInsets.zero,
            requestFocusOnTap: true,
            enableFilter: true,
            label: const Text('Category'),
            helperText: 'Pick one or type a new category',
            dropdownMenuEntries: [
              for (final c in entries) DropdownMenuEntry<String>(value: c, label: c),
            ],
          ),
          const SizedBox(height: 16),
          _repeatSection(theme),
          const SectionTitle('Quran reference (optional)'),
          _quranFields(),
          const SectionTitle('Audio'),
          _audioSection(theme),
        ],
      ),
    );
  }

  Widget _sourceActions(ThemeData theme) {
    final url = sourceUrl(_source.text.trim());
    final canCheck = _canCheckHadith;
    final result = _currentHadith;
    if (url == null && !canCheck) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (url != null)
                TextButton.icon(
                  onPressed: () => openSourceLink(context, url),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('View source'),
                ),
              if (canCheck)
                OutlinedButton.icon(
                  onPressed: _checkingHadith ? null : _checkHadith,
                  icon: _checkingHadith
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.travel_explore),
                  label: Text(_checkingHadith
                      ? 'Checking source online…'
                      : 'Check source online'),
                ),
            ],
          ),
          if (canCheck && result != null) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                VerificationChip(status: result.status, note: result.note),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    result.note,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _translateSection(ThemeData theme) {
    final lang = ref.watch(settingsProvider.select((s) => s.translationLanguage));
    final result = _translated;
    final rtl = result != null && isArabic(result);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _translating ? null : () => _translate(),
                icon: _translating
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.translate),
                label: Text('Translate to $lang'),
              ),
              if (result != null)
                IconButton(
                  tooltip: 'Translate again',
                  onPressed: _translating ? null : () => _translate(refresh: true),
                  icon: const Icon(Icons.refresh),
                ),
            ],
          ),
          if (_translateError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _translateError!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          if (result != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '$lang (machine translation)',
                      style: theme.textTheme.labelMedium,
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      result,
                      textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
                      style: theme.textTheme.bodyLarge?.copyWith(height: rtl ? 1.8 : null),
                    ),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: result));
                          _snack('Copied');
                        },
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('Copy'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _repeatSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Repeat count', style: theme.textTheme.titleSmall)),
            NumberStepper(
              value: _repeat,
              onChanged: (v) => setState(() {
                _repeat = v;
                _dirty = true;
              }),
            ),
          ],
        ),
        Slider(
          value: _repeat.toDouble(),
          min: 1,
          max: 100,
          divisions: 99,
          label: '$_repeat',
          semanticFormatterCallback: (v) => 'Repeat ${v.round()} times',
          onChanged: (v) => setState(() {
            _repeat = v.round();
            _dirty = true;
          }),
        ),
      ],
    );
  }

  Widget _quranFields() {
    InputDecoration deco(String label) => InputDecoration(labelText: label);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextFormField(
            controller: _surah,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: deco('Surah'),
            validator: _validateSurah,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextFormField(
            controller: _ayahStart,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: deco('From ayah'),
            validator: _validateAyahStart,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextFormField(
            controller: _ayahEnd,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: deco('To ayah'),
            validator: _validateAyahEnd,
          ),
        ),
      ],
    );
  }

  Widget _audioSection(ThemeData theme) {
    const options = <(AudioKind, String, IconData)>[
      (AudioKind.none, 'None', Icons.volume_off_outlined),
      (AudioKind.quran, 'Quran recitation', Icons.menu_book_outlined),
      (AudioKind.file, 'My recording or file', Icons.mic_none),
      (AudioKind.tts, 'Device voice', Icons.record_voice_over_outlined),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final (kind, label, icon) in options)
              ChoiceChip(
                avatar: Icon(icon, size: 18),
                label: Text(label),
                selected: _audioKind == kind,
                onSelected: _recording
                    ? null
                    : (_) => setState(() {
                          _audioKind = kind;
                          _dirty = true;
                          if (kind == AudioKind.quran) _autofillQuranRef();
                        }),
              ),
          ],
        ),
        const SizedBox(height: 8),
        switch (_audioKind) {
          AudioKind.none => const SizedBox.shrink(),
          AudioKind.quran => Text(
              _hasQuranRef
                  ? 'Plays a recitation of the ayat above (downloaded once, then offline).'
                  : 'Enter the surah and ayah numbers above to use Quran audio.',
              style: theme.textTheme.bodySmall,
            ),
          AudioKind.tts => Text(
              'Your phone\'s text-to-speech voice reads the Arabic. '
              'Not a reciter — pronunciation may be imperfect.',
              style: theme.textTheme.bodySmall,
            ),
          AudioKind.file => _fileAudio(theme),
        },
      ],
    );
  }

  Widget _fileAudio(ThemeData theme) {
    final path = _audioPath;
    final name = path == null ? null : p.basename(path);
    final elapsed =
        '${_recElapsed.inMinutes}:${(_recElapsed.inSeconds % 60).toString().padLeft(2, '0')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_recording)
          Semantics(
            liveRegion: true,
            child: Row(
              children: [
                Icon(Icons.fiber_manual_record, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Text('Recording… $elapsed'),
              ],
            ),
          )
        else
          Row(
            children: [
              Expanded(
                child: Text(
                  name == null ? 'No audio chosen yet.' : 'Audio: $name',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (path != null)
                IconButton(
                  tooltip: _previewing ? 'Stop preview' : 'Play preview',
                  onPressed: _togglePreview,
                  icon: Icon(_previewing ? Icons.stop : Icons.play_arrow),
                ),
            ],
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _recording ? null : _pickAudio,
              icon: const Icon(Icons.audio_file_outlined),
              label: const Text('Choose file'),
            ),
            FilledButton.tonalIcon(
              onPressed: _toggleRecording,
              icon: Icon(_recording ? Icons.stop : Icons.mic),
              label: Text(_recording ? 'Stop recording' : 'Record'),
            ),
          ],
        ),
      ],
    );
  }
}
