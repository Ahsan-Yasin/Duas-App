import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/navigation.dart';
import '../../core/net/hadith_client.dart';
import '../../core/net/llm_client.dart';
import '../../core/providers.dart';
import '../../core/theme.dart' show VerificationColors;
import '../../core/util.dart';
import '../../core/widgets/common.dart';
import '../../domain/arabic.dart' show normalizeArabic;
import '../../domain/hadith_ref.dart';
import '../../domain/quran_index.dart';
import '../../domain/verification.dart';
import '../library/dua_editor_screen.dart';
import '../settings/settings_screen.dart';

const quickPrompts = [
  'Dua for anxiety',
  'Morning protection',
  'Before sleep',
  'For parents',
];

const _quranWarning =
    'Could not verify this text against the Quran. Please check with a teacher or a mushaf before relying on it.';
const _hadithWarning =
    'Hadith wording cannot be verified offline — confirm with a reliable source.';

/// Suggestions stored in an assistant message's payload.
List<DuaSuggestion> _suggestionsOf(ChatMessage m) {
  final raw = m.payloadJson;
  if (raw == null || raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    final list = decoded is Map ? decoded['duas'] : null;
    if (list is! List) return const [];
    return [
      for (final e in list)
        if (DuaSuggestion.tryParse(e) case final DuaSuggestion s) s,
    ];
  } catch (_) {
    return const [];
  }
}

/// Text to retry, stored in an error message's payload.
String? _retryTextOf(ChatMessage m) {
  final raw = m.payloadJson;
  if (raw == null) return null;
  try {
    final decoded = jsonDecode(raw);
    final t = decoded is Map ? decoded['retry'] : null;
    return t is String && t.trim().isNotEmpty ? t : null;
  } catch (_) {
    return null;
  }
}

String? _errorKindOf(ChatMessage m) {
  final raw = m.payloadJson;
  if (raw == null) return null;
  try {
    final decoded = jsonDecode(raw);
    final k = decoded is Map ? decoded['kind'] : null;
    return k is String ? k : null;
  } catch (_) {
    return null;
  }
}

String _friendlyError(LlmException e) {
  if (e.kind == 'offline') {
    final base =
        'You seem to be offline. Asking for a dua needs an internet connection — your library, routines and reminders still work offline.';
    return e.details.isEmpty ? base : '$base\n\nDetails:\n${e.details}';
  }
  return e.fullMessage;
}

/// Quran reference to store for a suggestion: the claimed one, else where the
/// verifier found the text.
(int, int, int)? _quranRefFor(DuaSuggestion s, VerificationResult? v) {
  final q = s.quran;
  if (q != null) {
    final surah = asInt(q['surah']);
    final start = asInt(q['ayah_start'] ?? q['ayah']);
    if (surah != null && start != null) {
      final end = asInt(q['ayah_end']) ?? start;
      return (surah, start, end < start ? start : end);
    }
  }
  if (v != null && v.isVerified && v.kind == 'quran') return v.matchedRef;
  if (s.isQuran) return parseQuranRef(s.source);
  return null;
}

/// Whether a suggestion that the Quran check did not verify should be checked
/// against the online hadith collections: hadith (or unknown) suggestions, and
/// "Quran" suggestions whose source is actually a hadith reference.
bool _needsHadithCheck(DuaSuggestion s, VerificationResult? v) {
  if (v != null && v.isVerified) return false;
  final isQuran = s.isQuran || v?.kind == 'quran';
  return !isQuran || parseHadithRef(s.source) != null;
}

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<ChatMessage> _messages = [];
  bool _loading = true;
  Object? _loadError;
  bool _sending = false;

  /// Card key -> library dua id, for suggestions already in the library.
  final Map<String, int> _added = {};
  final Map<String, VerificationResult> _verified = {};
  QuranIndex? _verifiedWith;

  /// Card key -> online hadith check (started once per card) and its result.
  final Map<String, Future<HadithVerification>> _hadithChecks = {};
  final Map<String, HadithVerification> _hadithResults = {};

  Future<HadithVerification> _hadithFor(String key, DuaSuggestion s) {
    return _hadithChecks[key] ??= ref
        .read(hadithClientProvider)
        .verify(arabic: s.arabic, source: s.source)
        .then((r) {
      if (mounted && _hadithChecks.containsKey(key)) {
        setState(() => _hadithResults[key] = r);
      }
      return r;
    });
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final list = await ref.read(chatRepoProvider).list();
      if (!mounted) return;
      setState(() {
        _messages = list;
        _loading = false;
      });
      _scrollToEnd();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loading = false;
      });
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut);
      }
    });
  }

  void _snack(String text, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), action: action));
  }

  Future<ChatMessage> _persist(ChatMessage m) async {
    try {
      return await ref.read(chatRepoProvider).add(m);
    } catch (_) {
      return m; // Still show it, even if it could not be saved.
    }
  }

  Future<void> _send(String raw, {bool isRetry = false}) async {
    final text = raw.trim();
    if (text.isEmpty || _sending) return;
    final history = _messages.where((m) => m.role != 'error').toList();
    if (isRetry &&
        history.isNotEmpty &&
        history.last.role == 'user' &&
        history.last.text == text) {
      history.removeLast();
    }
    setState(() => _sending = true);
    if (!isRetry) {
      _input.clear();
      final userMsg = await _persist(
          ChatMessage(role: 'user', text: text, createdAt: nowIso()));
      if (!mounted) return;
      setState(() => _messages = [..._messages, userMsg]);
    }
    _scrollToEnd();

    ChatMessage reply;
    try {
      final r = await ref.read(llmClientProvider).suggestDuas(text, history);
      reply = ChatMessage(
        role: 'assistant',
        text: r.reply,
        payloadJson: r.duas.isEmpty
            ? null
            : jsonEncode({'duas': [for (final d in r.duas) d.toJson()]}),
        createdAt: nowIso(),
      );
    } on LlmException catch (e) {
      reply = ChatMessage(
        role: 'error',
        text: _friendlyError(e),
        payloadJson: jsonEncode({'retry': text, 'kind': e.kind}),
        createdAt: nowIso(),
      );
    } catch (_) {
      reply = ChatMessage(
        role: 'error',
        text: 'Something went wrong. Please try again.',
        payloadJson: jsonEncode({'retry': text}),
        createdAt: nowIso(),
      );
    }
    final saved = await _persist(reply);
    if (!mounted) return;
    setState(() {
      _messages = [..._messages, saved];
      _sending = false;
    });
    _scrollToEnd();
  }

  Future<void> _clear() async {
    final ok = await confirmDialog(
      context,
      title: 'Clear chat?',
      message:
          'All messages will be deleted. Duas you added to your library stay there.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (!ok) return;
    try {
      await ref.read(chatRepoProvider).clear();
    } catch (e) {
      _snack('Could not clear the chat: $e');
      return;
    }
    if (!mounted) return;
    setState(() {
      _messages = [];
      _added.clear();
      _verified.clear();
      _hadithChecks.clear();
      _hadithResults.clear();
    });
  }

  VerificationResult? _verify(String key, DuaSuggestion s, QuranIndex? index) {
    if (index == null) return null;
    if (!identical(index, _verifiedWith)) {
      _verified.clear();
      _verifiedWith = index;
    }
    return _verified[key] ??= verifyDua(
      arabic: s.arabic,
      source: s.source,
      quran: index,
      claimedQuran: s.quran,
    );
  }

  Future<void> _addToLibrary(
      String key, DuaSuggestion s, VerificationResult? v) async {
    final repo = ref.read(duaRepoProvider);
    try {
      final dup = await repo.findDuplicate(s.arabic);
      if (dup != null) {
        if (!mounted) return;
        if (dup.id != null) setState(() => _added[key] = dup.id!);
        _snack('Already in your library as "${dup.title}"');
        return;
      }
      final index = ref.read(quranIndexProvider).value;
      final result = v ??
          (index == null
              ? null
              : verifyDua(
                  arabic: s.arabic,
                  source: s.source,
                  quran: index,
                  claimedQuran: s.quran));
      final qref = _quranRefFor(s, result);
      List<String>? ayahs;
      if (qref != null && index != null && result != null && result.isVerified) {
        try {
          final (sura, a, e) = qref;
          if (normalizeArabic(s.arabic) == index.normalizedRange(sura, a, e)) {
            ayahs = index.ayahs(sura, a, e);
          }
        } catch (_) {
          ayahs = null;
        }
      }
      var status = result?.status ?? VerificationStatus.unverified;
      var note = result?.note ??
          'Not checked — confirm with a reliable source or teacher.';
      if (_needsHadithCheck(s, result)) {
        // Hadith (or a Quran claim that did not match): use the online check.
        final h = _hadithResults[key] ?? await _hadithFor(key, s);
        status = h.status;
        note = h.note;
      }
      if (!mounted) return;
      final now = nowIso();
      final saved = await repo.add(Dua(
        title: s.title.trim().isEmpty ? 'Dua' : s.title.trim(),
        arabic: s.arabic.trim(),
        transliteration: s.transliteration.trim(),
        translation: s.translation.trim(),
        source: s.source.trim(),
        category: s.category.trim().isEmpty ? 'General' : s.category.trim(),
        defaultRepeat: clampInt(s.repeat, 1, 100),
        audioKind: qref != null ? AudioKind.quran : AudioKind.none,
        quranSurah: qref?.$1,
        quranAyahStart: qref?.$2,
        quranAyahEnd: qref?.$3,
        ayahs: ayahs,
        isBuiltIn: false,
        verificationStatus: status,
        verificationNote: note,
        createdAt: now,
        updatedAt: now,
      ));
      if (!mounted) return;
      invalidateData(ref);
      final id = saved.id;
      if (id != null) setState(() => _added[key] = id);
      _snack('Added "${saved.title}" to your library',
          action: id == null
              ? null
              : SnackBarAction(
                  label: 'Add to routine', onPressed: () => _addToRoutine(id)));
    } catch (e) {
      _snack('Could not add the dua: $e');
    }
  }

  Future<void> _addToRoutine(int duaId) async {
    final routineRepo = ref.read(routineRepoProvider);
    List<Routine> routines;
    try {
      routines = await routineRepo.list();
    } catch (e) {
      _snack('Could not load routines: $e');
      return;
    }
    if (!mounted) return;
    final chosen = await showModalBottomSheet<Routine>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('Add to a routine',
                    style: Theme.of(ctx).textTheme.titleMedium),
              ),
              if (routines.isEmpty)
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('No routines yet'),
                  subtitle: Text('Create one in the Routines tab first.'),
                ),
              for (final r in routines)
                ListTile(
                  leading: const Icon(Icons.playlist_add),
                  title: Text(r.name),
                  subtitle: Text(
                      '${r.items.length} ${r.items.length == 1 ? 'dua' : 'duas'}'),
                  onTap: () => Navigator.pop(ctx, r),
                ),
            ],
          ),
        ),
      ),
    );
    final routineId = chosen?.id;
    if (chosen == null || routineId == null) return;
    if (chosen.items.any((i) => i.duaId == duaId)) {
      _snack('Already in ${chosen.name}');
      return;
    }
    try {
      await routineRepo.addDua(routineId, duaId);
    } catch (e) {
      _snack('Could not add to ${chosen.name}: $e');
      return;
    }
    if (!mounted) return;
    invalidateData(ref);
    _snack('Added to ${chosen.name}');
  }

  @override
  Widget build(BuildContext context) {
    final indexAsync = ref.watch(quranIndexProvider);
    final index = indexAsync.value;
    final indexFailed = indexAsync.hasError && index == null;

    Widget body;
    if (_loading) {
      body = const LoadingState();
    } else if (_loadError != null) {
      body = ErrorState(
          message: 'Could not load the chat.\n$_loadError', onRetry: _load);
    } else if (_messages.isEmpty && !_sending) {
      body = _EmptyChat(onPrompt: (p) => _send(p));
    } else {
      final itemCount = _messages.length + (_sending ? 1 : 0);
      body = ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        itemCount: itemCount,
        itemBuilder: (context, i) {
          if (i >= _messages.length) return const _TypingBubble();
          final m = _messages[i];
          final isLast = i == _messages.length - 1;
          return switch (m.role) {
            'user' => _Bubble(text: m.text, fromUser: true),
            'error' => _ErrorBubble(
                text: m.text,
                showSettings: const {'bad_key', 'no_key', 'denied'}
                    .contains(_errorKindOf(m)),
                onRetry: isLast && !_sending && _retryTextOf(m) != null
                    ? () => _send(_retryTextOf(m)!, isRetry: true)
                    : null,
              ),
            _ => _assistant(context, m, i, index, indexFailed),
          };
        },
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ask for a dua'),
        actions: [
          IconButton(
            tooltip: 'AI settings and API key',
            icon: const Icon(Icons.key_outlined),
            onPressed: () => pushScreen<void>(
                const SettingsScreen(initialSection: SettingsSection.ai)),
          ),
          IconButton(
            tooltip: 'Clear chat',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _messages.isEmpty || _sending ? null : _clear,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: body),
          _InputBar(
            controller: _input,
            sending: _sending,
            onSend: () => _send(_input.text),
          ),
        ],
      ),
    );
  }

  Widget _assistant(BuildContext context, ChatMessage m, int i,
      QuranIndex? index, bool indexFailed) {
    final suggestions = _suggestionsOf(m);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (m.text.trim().isNotEmpty) _Bubble(text: m.text, fromUser: false),
        for (var j = 0; j < suggestions.length; j++)
          Builder(builder: (context) {
            final key = '${m.id ?? 'm$i'}-$j';
            final s = suggestions[j];
            final v = _verify(key, s, index);
            final addedId = _added[key];
            final checking = index == null && !indexFailed;
            final hadithCheck = !checking && _needsHadithCheck(s, v);
            if (hadithCheck) unawaited(_hadithFor(key, s));
            final link = sourceUrl(s.source);
            return _SuggestionCard(
              suggestion: s,
              verification: v,
              checking: checking,
              hadithCheck: hadithCheck,
              hadith: _hadithResults[key],
              onViewSource:
                  link == null ? null : () => openSourceLink(context, link),
              addedId: addedId,
              onEdit: () => pushScreen<void>(DuaEditorScreen(initial: s)),
              onAdd: () => _addToLibrary(key, s, v),
              onAddToRoutine:
                  addedId == null ? null : () => _addToRoutine(addedId),
            );
          }),
      ],
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.onPrompt});

  final ValueChanged<String> onPrompt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome_outlined,
                size: 56, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('Ask for a dua for any situation',
                style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'Describe what you are going through. You get duas from the Quran and Sunnah to preview, check and add to your library.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in quickPrompts)
                  ActionChip(
                    avatar: const Icon(Icons.lightbulb_outline, size: 18),
                    label: Text(p),
                    onPressed: () => onPrompt(p),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.text, required this.fromUser});

  final String text;
  final bool fromUser;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment:
          fromUser ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.85),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: fromUser
                ? scheme.primaryContainer
                : scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(fromUser ? 16 : 4),
              bottomRight: Radius.circular(fromUser ? 4 : 16),
            ),
          ),
          child: SelectableText(
            text,
            style: TextStyle(
                color: fromUser
                    ? scheme.onPrimaryContainer
                    : scheme.onSurface),
          ),
        ),
      ),
    );
  }
}

class _ErrorBubble extends StatelessWidget {
  const _ErrorBubble({
    required this.text,
    required this.onRetry,
    required this.showSettings,
  });

  final String text;
  final VoidCallback? onRetry;
  final bool showSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 4),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline, color: scheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(text,
                    style: TextStyle(color: scheme.onErrorContainer)),
              ),
            ],
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            children: [
              if (showSettings)
                TextButton(
                  onPressed: () => pushScreen<void>(const SettingsScreen(
                      initialSection: SettingsSection.ai)),
                  child: const Text('AI settings'),
                ),
              if (onRetry != null)
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TypingBubble extends StatefulWidget {
  const _TypingBubble();

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1200))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Semantics(
        label: 'Looking for duas',
        liveRegion: true,
        excludeSemantics: true,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedBuilder(
                animation: _c,
                builder: (context, _) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < 3; i++)
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: scheme.primary.withValues(
                              alpha: 0.3 +
                                  0.7 *
                                      (((_c.value * 3 - i) % 3) < 1
                                          ? 1 - ((_c.value * 3 - i) % 3)
                                          : 0)),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text('Looking for duas…',
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    required this.suggestion,
    required this.verification,
    required this.checking,
    required this.hadithCheck,
    required this.hadith,
    required this.onViewSource,
    required this.addedId,
    required this.onEdit,
    required this.onAdd,
    required this.onAddToRoutine,
  });

  final DuaSuggestion suggestion;
  final VerificationResult? verification;
  final bool checking;

  /// The online hadith check applies to this card; [hadith] is its result
  /// (null while it runs).
  final bool hadithCheck;
  final HadithVerification? hadith;
  final VoidCallback? onViewSource;
  final int? addedId;
  final VoidCallback onEdit;
  final VoidCallback onAdd;
  final VoidCallback? onAddToRoutine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = suggestion;
    final v = verification;
    final isQuran = s.isQuran || v?.kind == 'quran';
    final verified = v?.isVerified ?? false;
    final h = hadith;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(s.title, style: theme.textTheme.titleMedium),
                ),
                const SizedBox(width: 8),
                _KindChip(isQuran: isQuran),
              ],
            ),
            const SizedBox(height: 8),
            ArabicText(s.arabic),
            if (s.transliteration.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(s.transliteration,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontStyle: FontStyle.italic)),
            ],
            if (s.translation.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(s.translation, style: theme.textTheme.bodyLarge),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (s.source.trim().isNotEmpty)
                  Text('Source: ${s.source}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                if (s.repeat > 1) RepeatBadge(s.repeat),
                if (checking)
                  Text('Checking…', style: theme.textTheme.bodySmall)
                else if (hadithCheck && h == null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 6),
                      Text('Checking source online…',
                          style: theme.textTheme.bodySmall),
                    ],
                  )
                else if (hadithCheck && h != null)
                  VerificationChip(status: h.status, note: h.note)
                else
                  VerificationChip(
                    status: v?.status ?? VerificationStatus.unverified,
                    note: v?.note ?? 'Could not load the Quran text to check.',
                  ),
              ],
            ),
            if (hadithCheck && h != null) ...[
              const SizedBox(height: 6),
              if (h.status == VerificationStatus.verified) ...[
                Text(h.note,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
                if (h.grades.isNotEmpty && !h.note.contains(h.grades.first))
                  Text('Grade: ${h.grades.join(', ')}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
              ] else
                _WarningBox(
                  text: h.note,
                  detail: h.grades.isEmpty
                      ? null
                      : 'Grade: ${h.grades.join(', ')}',
                ),
            ],
            if (!checking && !hadithCheck && !verified) ...[
              const SizedBox(height: 10),
              _WarningBox(
                text: isQuran ? _quranWarning : _hadithWarning,
                detail: isQuran ? v?.note : null,
              ),
            ],
            if (verified && v != null) ...[
              const SizedBox(height: 6),
              Text(v.note,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                if (onViewSource != null)
                  TextButton.icon(
                    onPressed: onViewSource,
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('View source'),
                  ),
                TextButton.icon(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Edit'),
                ),
                if (addedId == null)
                  FilledButton.icon(
                    onPressed: onAdd,
                    icon: const Icon(Icons.library_add_outlined),
                    label: const Text('Add to my library'),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: onAddToRoutine,
                    icon: const Icon(Icons.playlist_add),
                    label: const Text('Add to a routine'),
                  ),
              ],
            ),
            if (addedId != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Icon(Icons.check, size: 16, color: scheme.primary),
                    const SizedBox(width: 4),
                    Text('In your library',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.primary)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _KindChip extends StatelessWidget {
  const _KindChip({required this.isQuran});

  final bool isQuran;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        isQuran ? 'Quran' : 'Hadith',
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: scheme.onTertiaryContainer),
      ),
    );
  }
}

class _WarningBox extends StatelessWidget {
  const _WarningBox({required this.text, this.detail});

  final String text;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final bg = VerificationColors.unverifiedBackground(b);
    final fg = VerificationColors.unverifiedForeground(b);
    final extra = detail?.trim() ?? '';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: fg.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: TextStyle(color: fg)),
                if (extra.isNotEmpty && extra != text) ...[
                  const SizedBox(height: 4),
                  Text(extra,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: fg)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 3,
      color: theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => onSend(),
                      decoration: const InputDecoration(
                        hintText: 'Ask for a dua…',
                        border: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.all(Radius.circular(24))),
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'Send',
                    onPressed: sending ? null : onSend,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Needs internet. Suggestions come from an AI model — always verify.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
