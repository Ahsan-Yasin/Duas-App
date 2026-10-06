import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/models/models.dart';
import '../../core/net/llm_client.dart';
import '../../core/providers.dart';
import '../../core/repos/repositories.dart';
import '../../core/util.dart';
import '../../core/widgets/common.dart';
import '../../domain/session.dart';
import '../../domain/stats.dart';
import '../shell/root_shell.dart';
import 'finish_view.dart';
import 'recite_audio.dart';
import 'recite_audio_panel.dart';
import 'recite_widgets.dart';

/// Full-screen guided recitation of a routine: one dua at a time with a big
/// tap counter, optional audio, and a "Session complete" view at the end.
class ReciteScreen extends ConsumerStatefulWidget {
  const ReciteScreen({
    super.key,
    required this.routineId,
    this.fromAlarm = false,
    this.reminderId,
    this.resumeLogId,
  });

  final int? routineId;
  final bool fromAlarm;
  final int? reminderId;

  /// Resume an unfinished [SessionLog] (its `stateJson`).
  final int? resumeLogId;

  @override
  ConsumerState<ReciteScreen> createState() => _ReciteScreenState();
}

enum _CloseChoice { save, discard }

/// How long the success check mark shows before auto-advancing.
const _successDelay = Duration(milliseconds: 700);

class _FinishInfo {
  const _FinishInfo({
    required this.completed,
    required this.skipped,
    this.saving = true,
    this.acceptance,
    this.streak,
    this.error,
  });

  final int completed;
  final int skipped;
  final bool saving;
  final Dua? acceptance;
  final int? streak;
  final String? error;
}

class _ReciteScreenState extends ConsumerState<ReciteScreen> {
  late final SessionRepository _sessionRepo;
  late final RoutineRepository _routineRepo;
  late final DuaRepository _duaRepo;
  late final TranslationRepository _translationRepo;
  late final ReciteAudioController _audio;

  bool _loading = true;
  Object? _loadError;
  String? _emptyMessage;
  ReciteSession? _session;
  SessionLog? _log;
  final Map<int, Dua> _duas = {};
  final Set<int> _missingDuas = {};

  bool _celebrating = false;
  Timer? _advanceTimer;
  _FinishInfo? _finish;
  bool _closing = false;
  Future<void> _saveChain = Future<void>.value();

  String? _translationLang;
  final Map<int, String?> _translations = {};
  final Set<int> _translating = {};

  @override
  void initState() {
    super.initState();
    _sessionRepo = ref.read(sessionRepoProvider);
    _routineRepo = ref.read(routineRepoProvider);
    _duaRepo = ref.read(duaRepoProvider);
    _translationRepo = ref.read(translationRepoProvider);
    _audio = ReciteAudioController(
      player: ref.read(duaPlayerProvider),
      quranAudio: ref.read(quranAudioProvider),
    )..onPass = _onFollowAlongPass;
    _setWakelock(true);
    _load();
  }

  @override
  void dispose() {
    _advanceTimer?.cancel();
    _audio.dispose();
    _setWakelock(false);
    super.dispose();
  }

  void _setWakelock(bool on) {
    try {
      final f = on ? WakelockPlus.enable() : WakelockPlus.disable();
      f.catchError((Object e) => debugPrint('Wakelock unavailable: $e'));
    } catch (e) {
      debugPrint('Wakelock unavailable: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Loading
  // ---------------------------------------------------------------------------

  void _retry() {
    setState(() {
      _loading = true;
      _loadError = null;
      _emptyMessage = null;
    });
    _load();
  }

  Future<void> _load() async {
    try {
      final settings = ref.read(settingsProvider);
      ReciteSession? session;
      SessionLog? log;
      var routineId = widget.routineId;

      final resumeId = widget.resumeLogId;
      if (resumeId != null) {
        final existing = await _sessionRepo.get(resumeId);
        final json = existing?.stateJson;
        if (existing != null && !existing.completed && json != null) {
          try {
            session = ReciteSession.fromJson(json);
            log = existing;
            routineId = existing.routineId ?? session.routineId ?? routineId;
          } on FormatException catch (e) {
            debugPrint('Cannot resume session $resumeId: $e');
          }
        }
      }
      routineId ??= settings.defaultRoutineId;

      if (session == null) {
        if (routineId == null) {
          _setEmpty('No routine selected. Choose a routine to recite first.');
          return;
        }
        final items = await _routineRepo.resolvedItems(routineId);
        if (items.isEmpty) {
          _setEmpty('This routine has no duas yet. Add some duas to it first.');
          return;
        }
        for (final (dua, _) in items) {
          if (dua.id != null) _duas[dua.id!] = dua;
        }
        session = ReciteSession(
          [
            for (final (dua, repeat) in items)
              if (dua.id != null)
                SessionItem(duaId: dua.id!, title: dua.title, target: repeat),
          ],
          routineId: routineId,
          fromAlarm: widget.fromAlarm,
          reminderId: widget.reminderId,
          startedAt: nowIso(),
        );
      } else if (routineId != null) {
        for (final (dua, _) in await _routineRepo.resolvedItems(routineId)) {
          if (dua.id != null) _duas[dua.id!] = dua;
        }
      }

      if (session.items.isEmpty) {
        _setEmpty('This routine has no duas yet. Add some duas to it first.');
        return;
      }
      if (!session.isFinished &&
          (session.isCurrentDone || session.isCurrentSkipped)) {
        session.goTo(session.firstUnfinished ?? session.index);
      }

      if (!mounted) return;
      log ??= await _sessionRepo.add(SessionLog(
        routineId: routineId,
        startedAt: session.startedAt,
        fromAlarm: widget.fromAlarm,
        reminderId: widget.reminderId,
        completedDuaIds: session.completedDuaIds,
        skippedDuaIds: session.skippedDuaIds,
        stateJson: session.toJson(),
      ));
      if (!mounted) return;
      setState(() {
        _session = session;
        _log = log;
        _loading = false;
      });
      if (session.isFinished) {
        unawaited(_finishSession());
      } else {
        unawaited(_onItemShown());
      }
    } catch (e, st) {
      debugPrint('Recite load failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = e;
      });
    }
  }

  void _setEmpty(String message) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _emptyMessage = message;
    });
  }

  /// Called whenever the current item changes: loads its dua, cached
  /// translation, and starts audio for the "auto" audio modes.
  Future<void> _onItemShown() async {
    final s = _session;
    final item = s?.current;
    if (s == null || item == null) return;
    _advanceTimer?.cancel();
    final position = s.index;

    var dua = _duas[item.duaId];
    if (dua == null && !_missingDuas.contains(item.duaId)) {
      Dua? fetched;
      try {
        fetched = await _duaRepo.get(item.duaId);
      } catch (e) {
        debugPrint('Dua ${item.duaId} failed to load: $e');
      }
      if (!mounted) return;
      final found = (fetched != null && !fetched.isDeleted) ? fetched : null;
      setState(() {
        if (found != null) {
          _duas[item.duaId] = found;
        } else {
          _missingDuas.add(item.duaId);
        }
      });
      dua = found;
    }
    if (s.index != position || _finish != null) return;

    await _audio.select(dua);
    if (!mounted || s.index != position || dua == null) return;
    unawaited(_loadTranslation(dua));

    final mode = ref.read(settingsProvider).audioMode;
    if (!s.isCurrentDone &&
        _audio.hasRecording &&
        (mode == AudioMode.listenThenRecite || mode == AudioMode.followAlong)) {
      unawaited(_startAudio());
    }
  }

  // ---------------------------------------------------------------------------
  // Counting & navigation
  // ---------------------------------------------------------------------------

  void _haptic(Future<void> Function() feedback) {
    if (!ref.read(settingsProvider).haptics) return;
    feedback().catchError((Object _) {});
  }

  void _onCounterTap() {
    final s = _session;
    if (s == null || _celebrating || s.current == null || s.isCurrentDone) {
      return;
    }
    _haptic(HapticFeedback.lightImpact);
    _countOne();
  }

  void _countOne() {
    final s = _session!;
    final r = s.tap();
    setState(() {});
    _persist();
    if (r.itemDone && r.counted) _onItemDone();
  }

  void _onFollowAlongPass(int pass) {
    final s = _session;
    if (!mounted || s == null || _celebrating || _finish != null) return;
    if (s.current == null || s.isCurrentDone) return;
    if (ref.read(settingsProvider).audioMode != AudioMode.followAlong) return;
    _countOne();
  }

  void _onItemDone() {
    _haptic(HapticFeedback.mediumImpact);
    setState(() => _celebrating = true);
    _advanceTimer?.cancel();
    _advanceTimer = Timer(_successDelay, () {
      if (!mounted) return;
      setState(() => _celebrating = false);
      final s = _session!;
      if (!ref.read(settingsProvider).autoAdvance) return;
      if (s.isFinished) {
        _finishSession();
      } else {
        _goNext();
      }
    });
  }

  /// Moves to the next unfinished item (wrapping to earlier unfinished ones
  /// at the end), or finishes the session.
  void _goNext() {
    final s = _session;
    if (s == null) return;
    if (s.isFinished) {
      _finishSession();
      return;
    }
    if (!s.next()) s.goTo(s.firstUnfinished ?? s.index);
    _afterMove();
  }

  void _goBack() {
    final s = _session;
    if (s == null || !s.back()) return;
    _afterMove();
  }

  void _skip() {
    final s = _session;
    if (s == null || s.current == null) return;
    if (s.isCurrentDone) {
      _goNext();
      return;
    }
    final before = s.index;
    s.skip();
    if (s.isFinished) {
      _persist();
      _finishSession();
      return;
    }
    if (s.index == before) s.goTo(s.firstUnfinished ?? before);
    _afterMove();
  }

  void _afterMove() {
    _advanceTimer?.cancel();
    setState(() => _celebrating = false);
    _persist();
    _onItemShown();
  }

  /// Saves progress (state_json) so the session can be resumed.
  void _persist() {
    final s = _session;
    final log = _log;
    if (s == null || log == null || _finish != null) return;
    final updated = log.copyWith(
      completedDuaIds: s.completedDuaIds,
      skippedDuaIds: s.skippedDuaIds,
      stateJson: s.toJson(),
    );
    _log = updated;
    _saveChain = _saveChain
        .then((_) => _sessionRepo.update(updated))
        .catchError((Object e) => debugPrint('Session save failed: $e'));
  }

  // ---------------------------------------------------------------------------
  // Audio
  // ---------------------------------------------------------------------------

  Future<void> _startAudio() async {
    final s = _session;
    if (s == null) return;
    final settings = ref.read(settingsProvider);
    final follow = settings.audioMode == AudioMode.followAlong;
    await _audio.play(
      repeat: follow ? math.max(1, s.remaining) : 1,
      reciter: settings.reciter,
      speed: settings.playbackRate,
    );
  }

  void _speak() {
    final dua = _currentDua;
    if (dua == null) return;
    _audio.speak(dua.arabic, ref.read(settingsProvider).playbackRate);
  }

  void _onAudioModeChanged(AudioMode mode) {
    final s = _session;
    if (s == null || _finish != null) return;
    _audio.stop().then((_) {
      if (!mounted) return;
      if (mode == AudioMode.followAlong &&
          !s.isCurrentDone &&
          _audio.hasRecording) {
        _startAudio();
      }
    });
  }

  void _updateSettings(AppSettings Function(AppSettings) change) {
    ref.read(settingsProvider.notifier).update(change).catchError(
          (Object e) => debugPrint('Settings save failed: $e'),
        );
  }

  void _openAudioOptions() {
    final settings = ref.read(settingsProvider);
    showAudioOptionsSheet(
      context,
      mode: settings.audioMode,
      speed: settings.playbackRate,
      reciter: settings.reciter,
      onMode: (m) => _updateSettings((s) => s.copyWith(audioMode: m)),
      onSpeed: (v) => _updateSettings((s) => s.copyWith(playbackRate: v)),
    );
  }

  // ---------------------------------------------------------------------------
  // Translation
  // ---------------------------------------------------------------------------

  static bool _isEnglish(String lang) =>
      lang.trim().isEmpty || lang.trim().toLowerCase().startsWith('english');

  Future<void> _loadTranslation(Dua dua) async {
    final id = dua.id;
    final lang = ref.read(settingsProvider).translationLanguage;
    if (id == null || _isEnglish(lang)) return;
    if (_translationLang != lang) {
      _translations.clear();
      _translationLang = lang;
    }
    if (_translations.containsKey(id)) return;
    try {
      final text = await _translationRepo.get(id, lang);
      if (!mounted || _translationLang != lang) return;
      setState(() => _translations[id] = text);
    } catch (e) {
      debugPrint('Translation cache read failed: $e');
    }
  }

  Future<void> _translate(Dua dua) async {
    final id = dua.id;
    if (id == null || _translating.contains(id)) return;
    final lang = ref.read(settingsProvider).translationLanguage;
    final client = ref.read(llmClientProvider);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _translating.add(id));
    try {
      final input =
          dua.translation.trim().isNotEmpty ? dua.translation : dua.arabic;
      final text = (await client.translate(input, lang)).trim();
      if (text.isEmpty) throw const FormatException('empty translation');
      await _translationRepo.put(id, lang, text);
      if (!mounted) return;
      setState(() {
        _translationLang = lang;
        _translations[id] = text;
      });
    } on LlmException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
    } catch (e) {
      debugPrint('Translate failed: $e');
      messenger.showSnackBar(
        const SnackBar(content: Text('Translation failed. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _translating.remove(id));
    }
  }

  // ---------------------------------------------------------------------------
  // Finish & close
  // ---------------------------------------------------------------------------

  Future<void> _finishSession() async {
    final s = _session;
    if (s == null || _finish != null) return;
    _advanceTimer?.cancel();
    unawaited(_audio.stop());
    setState(() {
      _celebrating = false;
      _finish = _FinishInfo(
        completed: s.completedDuaIds.length,
        skipped: s.skippedDuaIds.length,
      );
    });
    String? error;
    try {
      final log = _log;
      if (log != null) {
        final done = log.copyWith(
          finishedAt: nowIso(),
          completed: true,
          completedDuaIds: s.completedDuaIds,
          skippedDuaIds: s.skippedDuaIds,
          stateJson: null,
        );
        _log = done;
        await _saveChain;
        await _sessionRepo.update(done);
      }
    } catch (e) {
      debugPrint('Finishing session failed: $e');
      error = 'Could not save this session.';
    }
    if (!mounted) return;
    invalidateData(ref);

    Dua? acceptance;
    int? streak;
    try {
      acceptance = await _duaRepo.getByKey('acceptance');
    } catch (e) {
      debugPrint('Acceptance dua failed to load: $e');
    }
    if (!mounted) return;
    try {
      final today = ref.read(nowProvider)();
      final logs = await ref.read(completedLogsProvider.future);
      streak = currentStreak(completedDays(logs), today);
    } catch (e) {
      debugPrint('Streak failed: $e');
    }
    if (!mounted) return;
    setState(() {
      _finish = _FinishInfo(
        completed: s.completedDuaIds.length,
        skipped: s.skippedDuaIds.length,
        saving: false,
        acceptance: acceptance,
        streak: streak,
        error: error,
      );
    });
  }

  Future<void> _handleClose() async {
    if (_closing) return;
    if (_finish != null) {
      if (!_finish!.saving) _done();
      return;
    }
    if (_session == null || _log == null) {
      _exit();
      return;
    }
    final choice = await showDialog<_CloseChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save progress?'),
        content: const Text(
          'Save to continue this session later, or discard it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_CloseChoice.discard),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_CloseChoice.save),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    _closing = true;
    _advanceTimer?.cancel();
    await _audio.stop();
    try {
      if (choice == _CloseChoice.save) {
        _persist();
        await _saveChain;
      } else {
        await _saveChain;
        final id = _log?.id;
        if (id != null) await _sessionRepo.delete(id);
      }
    } catch (e) {
      debugPrint('Closing session failed: $e');
    }
    if (!mounted) return;
    invalidateData(ref);
    _exit();
  }

  void _exit() {
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
    } else {
      nav.pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const RootShell()),
      );
    }
  }

  void _done() {
    final nav = Navigator.of(context);
    final isFirst = ModalRoute.of(context)?.isFirst ?? true;
    if (isFirst || !nav.canPop()) {
      nav.pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const RootShell()),
      );
    } else {
      nav.popUntil((r) => r.isFirst);
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  Dua? get _currentDua {
    final item = _session?.current;
    return item == null ? null : _duas[item.duaId];
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AudioMode>(
      settingsProvider.select((s) => s.audioMode),
      (prev, next) {
        if (prev != next) _onAudioModeChanged(next);
      },
    );
    ref.listen<double>(
      settingsProvider.select((s) => s.playbackRate),
      (prev, next) {
        if (prev != next) _audio.setSpeed(next);
      },
    );
    final settings = ref.watch(settingsProvider);

    final Widget body;
    if (_loading) {
      body = const LoadingState(message: 'Preparing your duas…');
    } else if (_loadError != null) {
      body = ErrorState(
        message: 'Could not load this routine.',
        onRetry: _retry,
      );
    } else if (_emptyMessage != null) {
      body = EmptyState(
        icon: Icons.playlist_add_outlined,
        title: 'Nothing to recite',
        message: _emptyMessage!,
        action: FilledButton(onPressed: _exit, child: const Text('Go back')),
      );
    } else if (_finish != null) {
      final f = _finish!;
      body = FinishView(
        completedCount: f.completed,
        skippedCount: f.skipped,
        saving: f.saving,
        acceptance: f.acceptance,
        streak: f.streak,
        saveError: f.error,
        onDone: _done,
      );
    } else {
      body = ListenableBuilder(
        listenable: _audio,
        builder: (context, _) => _buildSession(context, settings),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_loading || _loadError != null || _emptyMessage != null) {
          _exit();
        } else {
          _handleClose();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: (_loadError != null || _emptyMessage != null)
              ? Column(
                  children: [
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: IconButton(
                        tooltip: 'Close',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: _exit,
                      ),
                    ),
                    Expanded(child: body),
                  ],
                )
              : body,
        ),
      ),
    );
  }

  Widget _buildSession(BuildContext context, AppSettings settings) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = _session!;
    final item = s.current!;
    final dua = _duas[item.duaId];
    final done = s.isCurrentDone;
    final showHighlight = _audio.playing &&
        _audio.source == ReciteAudioSource.reciter &&
        _audio.ayahIndex != null;

    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(
          value: s.progress,
          minHeight: 6,
          semanticsLabel: 'Session progress',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  s.positionLabel,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: scheme.primary),
                ),
              ),
              IconButton(
                tooltip: 'Audio options',
                onPressed: _openAudioOptions,
                icon: Icon(settings.audioMode == AudioMode.off
                    ? Icons.headset_off_outlined
                    : Icons.headphones_rounded),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Semantics(
            header: true,
            child: Text(
              dua?.title ?? item.title,
              style: theme.textTheme.titleLarge,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );

    final lang = settings.translationLanguage;
    final id = dua?.id;
    final Widget? extra = (dua == null ||
            id == null ||
            _isEnglish(lang) ||
            _translationLang != lang ||
            !_translations.containsKey(id))
        ? null
        : ExtraTranslation(
            language: lang,
            text: _translations[id],
            busy: _translating.contains(id),
            onTranslate: () => _translate(dua),
          );

    final content = <Widget>[
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          FilterChip(
            label: const Text('Transliteration'),
            selected: settings.showTransliteration,
            onSelected: (v) =>
                _updateSettings((st) => st.copyWith(showTransliteration: v)),
          ),
          FilterChip(
            label: const Text('Translation'),
            selected: settings.showTranslation,
            onSelected: (v) =>
                _updateSettings((st) => st.copyWith(showTranslation: v)),
          ),
        ],
      ),
      const SizedBox(height: 12),
      if (dua != null)
        DuaTextCard(
          dua: dua,
          showTransliteration: settings.showTransliteration,
          showTranslation: settings.showTranslation,
          highlightAyah: showHighlight ? _audio.ayahIndex : null,
          extraTranslation: extra,
        )
      else if (_missingDuas.contains(item.duaId))
        Card(
          elevation: 0,
          color: scheme.surfaceContainerLow,
          margin: EdgeInsets.zero,
          child: const Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              'This dua is no longer in your library. Tap Skip to continue.',
              textAlign: TextAlign.center,
            ),
          ),
        )
      else
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      if (dua != null)
        ReciteAudioPanel(
          audio: _audio,
          mode: settings.audioMode,
          speed: settings.playbackRate,
          onPlay: _startAudio,
          onSpeak: _speak,
          onSpeed: (v) =>
              _updateSettings((st) => st.copyWith(playbackRate: v)),
        ),
    ];

    final controls = Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: ReciteControls(
        onBack: s.isFirst ? null : _goBack,
        onPause: _audio.canPause
            ? () {
                if (_audio.speaking) {
                  _audio.pause();
                } else {
                  _audio.togglePause();
                }
              }
            : null,
        paused: _audio.isPaused,
        onSkip: _skip,
        onClose: _handleClose,
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final tall = constraints.maxHeight >= 560;
        final counterSize = constraints.maxHeight >= 720 ? 188.0 : 164.0;
        final counter = _buildCounter(context, settings, s, done, counterSize);
        if (tall) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: content,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: counter,
              ),
              controls,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [...content, const SizedBox(height: 16), counter],
                ),
              ),
            ),
            controls,
          ],
        );
      },
    );
  }

  Widget _buildCounter(
    BuildContext context,
    AppSettings settings,
    ReciteSession s,
    bool done,
    double size,
  ) {
    final showNext = done && !_celebrating;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Center(
          child: CounterButton(
            count: s.count,
            target: s.target,
            mode: settings.counterMode,
            done: done,
            size: size,
            onTap: (done || _celebrating) ? null : _onCounterTap,
          ),
        ),
        AnimatedSize(
          duration: MediaQuery.of(context).disableAnimations
              ? Duration.zero
              : const Duration(milliseconds: 200),
          child: showNext
              ? Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: FilledButton.icon(
                    onPressed: _goNext,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(160, 52),
                    ),
                    icon: Icon(s.isFinished
                        ? Icons.done_all_rounded
                        : Icons.arrow_forward_rounded),
                    label: Text(s.isFinished ? 'Finish' : 'Next'),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
