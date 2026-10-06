import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/navigation.dart';
import '../../core/providers.dart';
import '../../core/widgets/common.dart' show confirmDialog;
import '../../domain/schedule.dart' show formatCountdown;
import '../reliability/reliability_screen.dart';
import 'reminder_editor_screen.dart';

const _dayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Short summary of ISO weekdays (Mon=1..Sun=7):
/// 'Every day', 'Mon–Fri', 'Weekends', 'Mon, Wed, Fri'.
String weekdaySummary(Iterable<int> weekdays) {
  final days = weekdays.where((d) => d >= 1 && d <= 7).toSet().toList()
    ..sort();
  if (days.isEmpty) return 'No days';
  if (days.length == 7) return 'Every day';
  if (days.length == 2 && days.first == 6 && days.last == 7) {
    return 'Weekends';
  }
  final contiguous = days.last - days.first == days.length - 1;
  if (contiguous && days.length >= 3) {
    return '${_dayShort[days.first - 1]}–${_dayShort[days.last - 1]}';
  }
  return days.map((d) => _dayShort[d - 1]).join(', ');
}

/// Next local occurrence strictly after [now] on one of [weekdays].
/// Used for countdown labels only (the native engine does the real scheduling).
DateTime? nextLocalOccurrence(
    int hour, int minute, Iterable<int> weekdays, DateTime now) {
  final allowed = weekdays.toSet();
  if (allowed.isEmpty) return null;
  for (var i = 0; i <= 7; i++) {
    final c = DateTime(now.year, now.month, now.day + i, hour, minute);
    if (c.isAfter(now) && allowed.contains(c.weekday)) return c;
  }
  return null;
}

/// Schedules the native 10-second test alarm and explains how to test it.
Future<void> runTestAlarm(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  final bridge = ref.read(nativeBridgeProvider);
  final routineId = ref.read(settingsProvider).defaultRoutineId;
  try {
    await bridge.scheduleTest(
        seconds: 10, label: 'Test alarm', routineId: routineId);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text(
            'Alarm will ring in 10 seconds — lock your phone to test the full-screen alarm'),
        duration: Duration(seconds: 8),
      ));
  } catch (e) {
    messenger.showSnackBar(
        SnackBar(content: Text('Could not schedule the test alarm: $e')));
  }
}

class RemindersScreen extends ConsumerStatefulWidget {
  const RemindersScreen({super.key});

  @override
  ConsumerState<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends ConsumerState<RemindersScreen> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Keep "rings in …" countdowns fresh.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _openEditor([int? id]) async {
    await pushScreen<void>(ReminderEditorScreen(reminderId: id));
    if (mounted) ref.invalidate(remindersProvider);
  }

  Future<void> _openReliability() async {
    await pushScreen<void>(const ReliabilityScreen());
    if (mounted) ref.invalidate(nativeStatusProvider);
  }

  Future<void> _sync() async {
    try {
      await ref.read(alarmServiceProvider).sync('edit');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Saved, but alarms could not be updated yet: $e')));
    }
  }

  Future<void> _setEnabled(Reminder r, bool enabled) async {
    final id = r.id;
    if (id == null) return;
    try {
      await ref.read(reminderRepoProvider).setEnabled(id, enabled);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not update: $e')));
      return;
    }
    if (!mounted) return;
    invalidateData(ref);
    await _sync();
  }

  Future<void> _delete(Reminder r) async {
    final id = r.id;
    if (id == null) return;
    final ok = await confirmDialog(
      context,
      title: 'Delete reminder?',
      message:
          'The ${r.timeLabel} reminder "${_title(r)}" will stop ringing and be removed.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      await ref.read(reminderRepoProvider).delete(id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not delete: $e')));
      return;
    }
    if (!mounted) return;
    invalidateData(ref);
    await _sync();
  }

  @override
  Widget build(BuildContext context) {
    final remindersAsync = ref.watch(remindersProvider);
    final routines = ref.watch(routinesProvider).value ?? const <Routine>[];
    final status = ref.watch(nativeStatusProvider).value;
    final now = ref.watch(nowProvider)();
    final needsFix = status != null &&
        status.isAndroid &&
        (!status.notificationsEnabled || !status.exactAlarmsAllowed);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reminders'),
        actions: [
          IconButton(
            tooltip: 'Alarm reliability',
            icon: const Icon(Icons.health_and_safety_outlined),
            onPressed: _openReliability,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add_alarm),
        label: const Text('Add reminder'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(nativeStatusProvider);
          invalidateData(ref);
          await ref.read(remindersProvider.future);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            if (needsFix)
              _PermissionWarning(
                notifications: status.notificationsEnabled,
                exact: status.exactAlarmsAllowed,
                onFix: _openReliability,
              ),
            _TestAlarmCard(onTest: () => runTestAlarm(context, ref)),
            const SizedBox(height: 8),
            ...remindersAsync.when(
              loading: () => const [
                Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
              error: (e, _) => [
                _ErrorBox(
                  message: 'Could not load reminders.\n$e',
                  onRetry: () => ref.invalidate(remindersProvider),
                ),
              ],
              data: (list) {
                if (list.isEmpty) {
                  return [_EmptyReminders(onAdd: () => _openEditor())];
                }
                final sorted = [...list]..sort((a, b) =>
                    (a.hour * 60 + a.minute).compareTo(b.hour * 60 + b.minute));
                return [
                  for (final r in sorted)
                    _ReminderCard(
                      reminder: r,
                      routineName: _routineName(routines, r.routineId),
                      next: r.enabled
                          ? nextLocalOccurrence(
                              r.hour, r.minute, r.weekdays, now)
                          : null,
                      now: now,
                      onTap: () => _openEditor(r.id),
                      onToggle: (v) => _setEnabled(r, v),
                      onDelete: () => _delete(r),
                    ),
                ];
              },
            ),
          ],
        ),
      ),
    );
  }
}

String _title(Reminder r) => r.label.trim().isEmpty ? 'Reminder' : r.label;

String _routineName(List<Routine> routines, int? id) {
  if (id == null) return 'No routine';
  for (final r in routines) {
    if (r.id == id) return r.name;
  }
  return 'Routine missing';
}

class _ReminderCard extends StatelessWidget {
  const _ReminderCard({
    required this.reminder,
    required this.routineName,
    required this.next,
    required this.now,
    required this.onTap,
    required this.onToggle,
    required this.onDelete,
  });

  final Reminder reminder;
  final String routineName;
  final DateTime? next;
  final DateTime now;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final r = reminder;
    final time =
        TimeOfDay(hour: r.hour, minute: r.minute).format(context);
    final muted = r.enabled ? null : scheme.onSurfaceVariant;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      time,
                      style: theme.textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: muted,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(_title(r),
                        style: theme.textTheme.titleMedium
                            ?.copyWith(color: muted)),
                    const SizedBox(height: 4),
                    Text(
                      '${weekdaySummary(r.weekdays)} · $routineName',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 4),
                    if (r.enabled && next != null)
                      Row(
                        children: [
                          Icon(Icons.alarm, size: 16, color: scheme.primary),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              'Rings ${formatCountdown(next!.difference(now))}',
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: scheme.primary),
                            ),
                          ),
                        ],
                      )
                    else
                      Text('Off',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              Column(
                children: [
                  Semantics(
                    label: '${_title(r)} at $time',
                    child: Switch(value: r.enabled, onChanged: onToggle),
                  ),
                  IconButton(
                    tooltip: 'Delete reminder',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: onDelete,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TestAlarmCard extends StatelessWidget {
  const _TestAlarmCard({required this.onTest});

  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.secondaryContainer,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Make sure alarms ring',
                style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer)),
            const SizedBox(height: 4),
            Text(
              'Schedule a test alarm, then lock your phone and wait.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSecondaryContainer),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onTest,
              icon: const Icon(Icons.alarm_on),
              label: const Text('Test alarm in 10 seconds'),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48)),
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionWarning extends StatelessWidget {
  const _PermissionWarning({
    required this.notifications,
    required this.exact,
    required this.onFix,
  });

  final bool notifications;
  final bool exact;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final problems = [
      if (!notifications) 'notifications are blocked',
      if (!exact) 'exact alarms are not allowed',
    ];
    return Card(
      color: scheme.errorContainer,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    color: scheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Reminders may not ring',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(color: scheme.onErrorContainer),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Android says ${problems.join(' and ')}. Fix this so your duas reminders ring on time.',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.tonal(
                onPressed: onFix,
                child: const Text('Fix alarm settings'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyReminders extends StatelessWidget {
  const _EmptyReminders({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
      child: Column(
        children: [
          Icon(Icons.alarm_add_outlined,
              size: 64, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text('No reminders yet',
              style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            'Add a reminder and an alarm will ring at that time to start your routine — even when your phone is locked.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_alarm),
            label: const Text('Add your first reminder'),
          ),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Icon(Icons.error_outline,
              size: 48, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
