import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../core/alarm/alarm_service.dart';
import '../../core/models/models.dart';
import '../../core/navigation.dart';
import '../../core/providers.dart';
import '../../core/widgets/common.dart';
import '../../domain/schedule.dart';
import '../../domain/session.dart';
import '../../domain/stats.dart';
import '../chat/chat_screen.dart';
import '../history/history_screen.dart';

/// Latest missed alarm (rang or auto-stopped without being started or
/// dismissed in the last 90 minutes), or null.
final missedAlarmProvider = FutureProvider<MissedAlarm?>((ref) {
  final now = ref.watch(nowProvider)();
  return ref.watch(alarmServiceProvider).missedBanner(now);
});

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  Timer? _ticker;
  final Set<String> _hiddenMissed = {};

  @override
  void initState() {
    super.initState();
    // Keeps the countdown and "today" figures fresh while the screen is open.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    ref.invalidate(remindersProvider);
    ref.invalidate(routinesProvider);
    ref.invalidate(completedLogsProvider);
    ref.invalidate(unfinishedSessionProvider);
    ref.invalidate(missedAlarmProvider);
    try {
      await ref.read(remindersProvider.future);
    } catch (_) {
      // Errors are shown by the cards themselves.
    }
  }

  Future<void> _startMissed(MissedAlarm missed) async {
    setState(() => _hiddenMissed.add(_missedKey(missed)));
    await _logMissedAction('start', missed);
    openRecite(
      routineId: missed.routineId,
      fromAlarm: true,
      reminderId: missed.reminderId,
    );
  }

  Future<void> _dismissMissed(MissedAlarm missed) async {
    setState(() => _hiddenMissed.add(_missedKey(missed)));
    await _logMissedAction('dismiss', missed);
  }

  Future<void> _logMissedAction(String action, MissedAlarm missed) async {
    final service = ref.read(alarmServiceProvider);
    try {
      await ref
          .read(nativeBridgeProvider)
          .alarmAction(action, missed.reminderId, missed.occurrenceMs);
      await service.ingestEvents();
    } catch (e) {
      debugPrint('Missed alarm action failed: $e');
    }
    if (mounted) ref.invalidate(missedAlarmProvider);
  }

  static String _missedKey(MissedAlarm m) => '${m.reminderId}:${m.occurrenceMs}';

  @override
  Widget build(BuildContext context) {
    final now = ref.watch(nowProvider)();
    final missed = ref.watch(missedAlarmProvider).value;
    final showMissed = missed != null && !_hiddenMissed.contains(_missedKey(missed));

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              if (showMissed)
                _MissedBanner(
                  missed: missed,
                  onStart: () => _startMissed(missed),
                  onDismiss: () => _dismissMissed(missed),
                ),
              _Greeting(now: now),
              const _ResumeCard(),
              const _StartNowCard(),
              _NextAlarmCard(now: now),
              _TodayCard(now: now),
              const _QuickLinks(),
            ],
          ),
        ),
      ),
    );
  }
}

class _MissedBanner extends StatelessWidget {
  const _MissedBanner({
    required this.missed,
    required this.onStart,
    required this.onDismiss,
  });

  final MissedAlarm missed;
  final VoidCallback onStart;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final time = DateFormat.jm()
        .format(DateTime.fromMillisecondsSinceEpoch(missed.occurrenceMs));
    final what = missed.label.trim().isEmpty ? 'routine' : missed.label.trim();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: MaterialBanner(
          backgroundColor: scheme.errorContainer,
          leading: Icon(Icons.alarm_off, color: scheme.onErrorContainer),
          content: Text(
            'You missed the $time $what. Start now?',
            style: TextStyle(color: scheme.onErrorContainer),
          ),
          actions: [
            TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
            FilledButton(onPressed: onStart, child: const Text('Start')),
          ],
        ),
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({required this.now});

  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final h = now.hour;
    final part = h < 12
        ? 'Good morning'
        : h < 17
            ? 'Good afternoon'
            : 'Good evening';
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text('Assalamu alaikum', style: theme.textTheme.headlineSmall),
          ),
          const SizedBox(height: 4),
          Text(
            '$part · ${DateFormat.yMMMMEEEEd().format(now)}',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _ResumeCard extends ConsumerWidget {
  const _ResumeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final log = ref.watch(unfinishedSessionProvider).value;
    if (log == null || log.id == null) return const SizedBox.shrink();
    final routines = ref.watch(routinesProvider).value ?? const <Routine>[];
    final routineName = routines
            .where((r) => r.id == log.routineId)
            .map((r) => r.name)
            .firstOrNull ??
        'session';
    String? position;
    final json = log.stateJson;
    if (json != null && json.isNotEmpty) {
      try {
        position = ReciteSession.fromJson(json).positionLabel;
      } catch (_) {
        position = null;
      }
    }
    final title =
        position == null ? 'Resume $routineName' : 'Resume $routineName — $position';
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history_toggle_off, color: theme.colorScheme.onSecondaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: theme.colorScheme.onSecondaryContainer),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () async {
                    await ref.read(sessionRepoProvider).delete(log.id!);
                    ref.invalidate(unfinishedSessionProvider);
                  },
                  child: const Text('Discard'),
                ),
                FilledButton.icon(
                  onPressed: () => openRecite(
                    routineId: log.routineId,
                    fromAlarm: log.fromAlarm,
                    reminderId: log.reminderId,
                    resumeLogId: log.id,
                  ),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Resume'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StartNowCard extends ConsumerWidget {
  const _StartNowCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final defaultId = ref.watch(settingsProvider.select((s) => s.defaultRoutineId));
    final routinesAsync = ref.watch(routinesProvider);
    final routines = routinesAsync.value;

    if (routines == null) {
      if (routinesAsync.hasError) {
        return Card(
          child: ListTile(
            leading: const Icon(Icons.error_outline),
            title: const Text('Could not load routines'),
            trailing: TextButton(
              onPressed: () => ref.invalidate(routinesProvider),
              child: const Text('Retry'),
            ),
          ),
        );
      }
      return const Card(
        child: SizedBox(height: 120, child: LoadingState()),
      );
    }

    final routine = routines.where((r) => r.id == defaultId).firstOrNull ??
        routines.firstOrNull;

    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              routine == null ? 'No routines yet' : routine.name,
              style: theme.textTheme.titleLarge
                  ?.copyWith(color: theme.colorScheme.onPrimaryContainer),
            ),
            const SizedBox(height: 2),
            Text(
              routine == null
                  ? 'Create a routine to start reciting.'
                  : '${routine.items.length} ${routine.items.length == 1 ? 'dua' : 'duas'}'
                      '${routine.id == defaultId ? ' · your default routine' : ''}',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onPrimaryContainer),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(64),
                textStyle: theme.textTheme.titleMedium,
              ),
              onPressed: routine == null
                  ? () => goToTab(ref, ShellTab.routines)
                  : () => openRecite(routineId: routine.id),
              icon: Icon(routine == null ? Icons.add : Icons.play_arrow, size: 28),
              label: Text(routine == null ? 'Create a routine' : 'Start now'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NextAlarmCard extends ConsumerWidget {
  const _NextAlarmCard({required this.now});

  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final remindersAsync = ref.watch(remindersProvider);
    final routines = ref.watch(routinesProvider).value ?? const <Routine>[];

    void openReminders() => goToTab(ref, ShellTab.reminders);

    return remindersAsync.when(
      loading: () => const Card(child: SizedBox(height: 72, child: LoadingState())),
      error: (e, _) => Card(
        child: ListTile(
          leading: const Icon(Icons.error_outline),
          title: const Text('Could not load reminders'),
          trailing: TextButton(
            onPressed: () => ref.invalidate(remindersProvider),
            child: const Text('Retry'),
          ),
        ),
      ),
      data: (reminders) {
        final at = tz.TZDateTime.from(now, tz.local);
        final next = nextAlarm(reminders, at);
        if (next == null) {
          final message = reminders.isEmpty
              ? 'No reminders yet — add one'
              : 'All reminders are turned off';
          return Card(
            child: ListTile(
              minVerticalPadding: 12,
              leading: const Icon(Icons.alarm_add_outlined),
              title: Text(message),
              subtitle: const Text('Get a daily alarm for your routine'),
              trailing: const Icon(Icons.chevron_right),
              onTap: openReminders,
            ),
          );
        }
        final (reminder, nextAt) = next;
        final time = DateFormat.jm().format(nextAt);
        final today = DateTime(at.year, at.month, at.day);
        final day = DateTime(nextAt.year, nextAt.month, nextAt.day);
        final dayDiff = day.difference(today).inDays;
        final dayLabel = dayDiff == 0
            ? 'Today'
            : dayDiff == 1
                ? 'Tomorrow'
                : DateFormat.EEEE().format(nextAt);
        final routineName =
            routines.where((r) => r.id == reminder.routineId).map((r) => r.name).firstOrNull;
        final label = reminder.label.trim().isNotEmpty
            ? reminder.label.trim()
            : (routineName ?? 'Reminder');
        final countdown = formatCountdown(nextAt.difference(at));
        return Card(
          child: InkWell(
            onTap: openReminders,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.alarm, size: 32, color: theme.colorScheme.primary),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Next reminder', style: theme.textTheme.labelMedium),
                        Text(
                          '$dayLabel, $time',
                          style: theme.textTheme.titleLarge,
                        ),
                        Text(
                          [
                            label,
                            if (routineName != null && routineName != label) routineName,
                            countdown,
                          ].join(' · '),
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TodayCard extends ConsumerWidget {
  const _TodayCard({required this.now});

  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final logsAsync = ref.watch(completedLogsProvider);
    final routines = ref.watch(routinesProvider).value ?? const <Routine>[];
    final logs = logsAsync.value;
    if (logs == null) {
      if (logsAsync.hasError) {
        return Card(
          child: ListTile(
            leading: const Icon(Icons.error_outline),
            title: const Text('Could not load your progress'),
            trailing: TextButton(
              onPressed: () => ref.invalidate(completedLogsProvider),
              child: const Text('Retry'),
            ),
          ),
        );
      }
      return const SizedBox.shrink();
    }
    final today = DateTime(now.year, now.month, now.day);
    final summary = todaySummary(logs, today);
    final streak = currentStreak(completedDays(logs), today);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Today', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _Stat(
                  icon: Icons.local_fire_department_outlined,
                  value: '$streak',
                  label: streak == 1 ? 'day streak' : 'days streak',
                ),
                _Stat(
                  icon: Icons.task_alt,
                  value: '${summary.sessions}',
                  label: summary.sessions == 1 ? 'session' : 'sessions',
                ),
                _Stat(
                  icon: Icons.auto_stories_outlined,
                  value: '${summary.duas}',
                  label: summary.duas == 1 ? 'dua' : 'duas',
                ),
              ],
            ),
            if (routines.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final r in routines)
                Semantics(
                  label: '${r.name}: ${summary.routineIds.contains(r.id) ? 'done today' : 'not done yet'}',
                  excludeSemantics: true,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(
                          summary.routineIds.contains(r.id)
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          color: summary.routineIds.contains(r.id)
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outline,
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Text(r.name)),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.value, required this.label});

  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 96),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: theme.textTheme.titleLarge),
              Text(label, style: theme.textTheme.labelSmall),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuickLinks extends StatelessWidget {
  const _QuickLinks();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('Quick links'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.chat_bubble_outline),
                title: const Text('Chat to add duas'),
                subtitle: const Text('Describe what you need and get suggestions'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => pushScreen<void>(const ChatScreen()),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.insights_outlined),
                title: const Text('History'),
                subtitle: const Text('Past sessions and streaks'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => pushScreen<void>(const HistoryScreen()),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
