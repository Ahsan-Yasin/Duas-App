// Keeps the native alarm engine in sync with the reminders table, imports the
// native event log and derives the "missed" banner.
//
// Constructor (explicit dependencies, wired in lib/core/providers.dart):
//
//   final alarmServiceProvider = Provider<AlarmService>((ref) => AlarmService(
//         bridge: ref.watch(nativeBridgeProvider),
//         reminders: ref.watch(reminderRepoProvider),
//         routines: ref.watch(routineRepoProvider),
//         events: ref.watch(alarmEventRepoProvider),
//       ));
//
// Optional `now` overrides the clock (tests).

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../native/native_bridge.dart';
import '../repos/repositories.dart';

class SyncResult {
  const SyncResult({
    required this.ok,
    required this.expected,
    required this.scheduled,
    required this.mismatches,
    required this.at,
    this.reason = '',
  });

  /// Every enabled reminder x weekday has a live alarm at the right time.
  final bool ok;

  /// Number of (enabled reminder, weekday) alarms that should exist.
  final int expected;

  /// Number of those that are scheduled correctly.
  final int scheduled;

  /// Human-readable problems (empty when [ok]).
  final List<String> mismatches;
  final DateTime at;
  final String reason;

  @override
  String toString() => 'SyncResult(ok: $ok, $scheduled/$expected, reason: $reason, mismatches: $mismatches)';
}

class MissedAlarm {
  const MissedAlarm({
    required this.reminderId,
    required this.occurrenceMs,
    required this.label,
    this.routineId,
  });

  final int reminderId;
  final int occurrenceMs;
  final String label;
  final int? routineId;

  @override
  String toString() => 'MissedAlarm($reminderId@$occurrenceMs "$label" routine=$routineId)';
}

class AlarmService {
  AlarmService({
    required this.bridge,
    required this.reminders,
    required this.routines,
    required this.events,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final NativeBridge bridge;
  final ReminderRepository reminders;
  final RoutineRepository routines;
  final AlarmEventRepository events;
  final DateTime Function() _now;

  /// How long after an unanswered occurrence the home screen offers to start it.
  static const missedWindow = Duration(minutes: 90);

  static const _ringEvents = {'rang', 'auto_stopped', 'nag_rang'};
  static const _answeredEvents = {'started', 'dismissed'};
  static const _dayNames = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  SyncResult? _lastSync;
  Future<void> _queue = Future<void>.value();

  SyncResult? get lastSync => _lastSync;

  /// Pushes all reminders to the native engine, verifies what AlarmManager holds
  /// and re-syncs once when something is missing. Calls are serialized.
  Future<SyncResult> sync(String reason) {
    final run = _queue.then((_) => _sync(reason));
    _queue = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<SyncResult> _sync(String reason) async {
    SyncResult result;
    try {
      final rems = await reminders.list();
      final routineList = await routines.list();
      final names = <int, String>{
        for (final r in routineList)
          if (r.id != null) r.id!: r.name,
      };
      final dicts = [
        for (final r in rems)
          if (r.id != null) r.toNativeJson(routineName: names[r.routineId] ?? ''),
      ];
      await bridge.syncReminders(dicts);
      var check = compareScheduled(rems, await bridge.getScheduled(), _now());
      if (check.mismatches.isNotEmpty) {
        // Repair once: the full desired state is idempotent on the native side.
        await bridge.syncReminders(dicts);
        check = compareScheduled(rems, await bridge.getScheduled(), _now());
      }
      result = SyncResult(
        ok: check.mismatches.isEmpty,
        expected: check.expected,
        scheduled: check.scheduled,
        mismatches: check.mismatches,
        at: _now(),
        reason: reason,
      );
    } catch (e) {
      result = SyncResult(
        ok: false,
        expected: 0,
        scheduled: 0,
        mismatches: ['Could not sync alarms: $e'],
        at: _now(),
        reason: reason,
      );
    }
    if (!result.ok) debugPrint('Alarm sync ($reason): $result');
    _lastSync = result;
    return result;
  }

  /// Compares native alarms with what the reminders require: one live `main`
  /// alarm per enabled reminder x weekday, in the future (at most ~8 days ahead),
  /// on that weekday at hour:minute local time (a DST gap may push it later by
  /// up to an hour, as in schedule.dart), and no leftovers for other reminders.
  @visibleForTesting
  static ({int expected, int scheduled, List<String> mismatches}) compareScheduled(
    List<Reminder> rems,
    List<ScheduledAlarm> native,
    DateTime now,
  ) {
    final mismatches = <String>[];
    var expected = 0;
    var scheduled = 0;
    final wanted = <(int, int)>{};
    final main = <(int, int), ScheduledAlarm>{
      for (final s in native)
        if (s.kind == 'main') (s.reminderId, s.weekday): s,
    };
    final earliest = now.subtract(const Duration(minutes: 1));
    final latest = now.add(const Duration(days: 8));

    for (final r in rems) {
      final id = r.id;
      if (id == null || !r.enabled) continue;
      final name = r.label.trim().isEmpty ? 'Reminder ${r.timeLabel}' : '${r.label.trim()} (${r.timeLabel})';
      for (final day in r.weekdays.where((d) => d >= 1 && d <= 7).toSet()) {
        expected++;
        wanted.add((id, day));
        final s = main[(id, day)];
        final where = '$name on ${_dayNames[day]}';
        if (s == null) {
          mismatches.add('$where: not scheduled');
          continue;
        }
        if (!s.exists) {
          mismatches.add('$where: alarm missing from the system');
          continue;
        }
        final t = DateTime.fromMillisecondsSinceEpoch(s.triggerAtMs);
        final shift = (t.hour * 60 + t.minute) - (r.hour * 60 + r.minute);
        if (t.isBefore(earliest) || t.isAfter(latest)) {
          mismatches.add('$where: scheduled for a wrong date');
        } else if (t.weekday != day || shift < 0 || shift > 60) {
          final hh = t.hour.toString().padLeft(2, '0');
          final mm = t.minute.toString().padLeft(2, '0');
          mismatches.add('$where: scheduled for ${_dayNames[t.weekday]} $hh:$mm');
        } else {
          scheduled++;
        }
      }
    }
    for (final s in native) {
      if (s.kind == 'main' && s.exists && !wanted.contains((s.reminderId, s.weekday))) {
        mismatches.add('Leftover alarm for reminder #${s.reminderId} on ${_dayNames[s.weekday.clamp(0, 7)]}');
      }
    }
    return (expected: expected, scheduled: scheduled, mismatches: mismatches);
  }

  /// Copies the native log into the DB and returns what native reported.
  ///
  /// Re-reads the whole log (Kotlin caps it at 500 entries) instead of using
  /// MAX(at_ms) as a watermark: at_ms is wall-clock time, so events logged
  /// after the clock moved backwards would sort below the watermark and never
  /// be imported. Rows already stored are dropped by the repository's unique
  /// (reminder, occurrence, event, at_ms) dedupe.
  Future<List<AlarmEvent>> ingestEvents() async {
    final all = await bridge.getEvents(0);
    if (all.isNotEmpty) await events.addAll(all);
    return all;
  }

  /// The latest real occurrence within [missedWindow] that rang (or nagged / auto-stopped)
  /// but was neither started nor dismissed, and is not waiting on a snooze.
  Future<MissedAlarm?> missedBanner(DateTime now) async {
    final nowMs = now.millisecondsSinceEpoch;
    final fromMs = now.subtract(missedWindow).millisecondsSinceEpoch;
    final list = await events.since(fromMs);
    final byOccurrence = <(int, int), List<AlarmEvent>>{};
    for (final e in list) {
      if (e.reminderId < 0 || e.occurrenceMs < fromMs || e.occurrenceMs > nowMs) continue;
      byOccurrence.putIfAbsent((e.reminderId, e.occurrenceMs), () => []).add(e);
    }
    final keys = byOccurrence.keys.toList()..sort((a, b) => b.$2.compareTo(a.$2));
    for (final key in keys) {
      final evs = byOccurrence[key]!..sort((a, b) => a.atMs.compareTo(b.atMs));
      if (!evs.any((e) => _ringEvents.contains(e.event))) continue;
      if (evs.any((e) => _answeredEvents.contains(e.event))) continue;
      if (evs.last.event == 'snoozed') continue;
      final reminder = await reminders.get(key.$1);
      if (reminder == null) continue;
      final label = evs.lastWhere((e) => e.label.trim().isNotEmpty, orElse: () => evs.last).label;
      return MissedAlarm(
        reminderId: key.$1,
        occurrenceMs: key.$2,
        label: label.trim().isEmpty ? reminder.label : label,
        routineId: reminder.routineId,
      );
    }
    return null;
  }
}
