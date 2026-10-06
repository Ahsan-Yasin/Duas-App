import 'package:daily_duas/core/alarm/alarm_service.dart';
import 'package:daily_duas/core/models/models.dart';
import 'package:daily_duas/core/native/native_bridge.dart';
import 'package:daily_duas/core/repos/repositories.dart';
import 'package:flutter_test/flutter_test.dart';

class _Reminders implements ReminderRepository {
  _Reminders(this.items);
  final List<Reminder> items;

  @override
  Future<List<Reminder>> list() async => List.of(items);

  @override
  Future<Reminder?> get(int id) async {
    for (final r in items) {
      if (r.id == id) return r;
    }
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Routines implements RoutineRepository {
  _Routines(this.items);
  final List<Routine> items;

  @override
  Future<List<Routine>> list() async => List.of(items);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Events implements AlarmEventRepository {
  final List<AlarmEvent> items = [];

  @override
  Future<void> addAll(List<AlarmEvent> e) async {
    for (final ev in e) {
      final dup = items.any((x) =>
          x.reminderId == ev.reminderId &&
          x.occurrenceMs == ev.occurrenceMs &&
          x.event == ev.event &&
          x.atMs == ev.atMs);
      if (!dup) items.add(ev);
    }
  }

  @override
  Future<List<AlarmEvent>> since(int ms) async =>
      items.where((e) => e.atMs >= ms).toList()..sort((a, b) => a.atMs.compareTo(b.atMs));

  @override
  Future<int> lastAtMs() async =>
      items.isEmpty ? 0 : items.map((e) => e.atMs).reduce((a, b) => a > b ? a : b);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final now = DateTime(2026, 10, 6, 12, 0); // a Tuesday, local time
  late FakeNativeBridge bridge;
  late _Reminders reminders;
  late _Events events;
  late AlarmService service;

  const morning = Reminder(id: 1, label: 'Morning', hour: 7, minute: 0, routineId: 10, weekdays: [1, 2, 3]);
  const evening = Reminder(id: 2, label: 'Evening', hour: 18, minute: 30, routineId: 11);
  const off = Reminder(id: 3, label: 'Off', hour: 9, minute: 0, enabled: false);

  setUp(() {
    bridge = FakeNativeBridge(now: () => now);
    reminders = _Reminders([morning, evening, off]);
    events = _Events();
    service = AlarmService(
      bridge: bridge,
      reminders: reminders,
      routines: _Routines(const [Routine(id: 10, name: 'Morning adhkar'), Routine(id: 11, name: 'Evening adhkar')]),
      events: events,
      now: () => now,
    );
  });

  tearDown(() => bridge.dispose());

  AlarmEvent ev(int reminderId, DateTime occurrence, String event, Duration after, {String label = 'Morning'}) =>
      AlarmEvent(
        reminderId: reminderId,
        occurrenceMs: occurrence.millisecondsSinceEpoch,
        event: event,
        atMs: occurrence.add(after).millisecondsSinceEpoch,
        label: label,
      );

  group('sync', () {
    test('pushes reminder dicts with routine names and verifies every weekday', () async {
      final result = await service.sync('test');
      expect(result.ok, isTrue, reason: '${result.mismatches}');
      expect(result.expected, 3 + 7);
      expect(result.scheduled, 10);
      expect(result.reason, 'test');
      expect(service.lastSync, same(result));
      expect(bridge.syncCalls, 1);
      expect(bridge.reminders, hasLength(3));
      final first = bridge.reminders.firstWhere((r) => r['id'] == 1);
      expect(first['routine_name'], 'Morning adhkar');
      expect(first['weekdays'], [1, 2, 3]);
      expect(first['ring_seconds'], 120);
    });

    test('detects alarms missing from the system and re-syncs once', () async {
      bridge.missingReminderIds.add(2);
      final result = await service.sync('resume');
      expect(result.ok, isFalse);
      expect(bridge.syncCalls, 2);
      expect(result.expected, 10);
      expect(result.scheduled, 3);
      expect(result.mismatches, hasLength(7));
      expect(result.mismatches.first, contains('Evening'));
      expect(result.mismatches.first, contains('missing'));
    });

    test('a successful repair re-sync reports ok', () async {
      bridge
        ..missingReminderIds.add(1)
        ..healOnResync = true;
      final result = await service.sync('resume');
      expect(bridge.syncCalls, 2);
      expect(result.ok, isTrue);
      expect(result.scheduled, 10);
    });

    test('native errors become a failed result instead of throwing', () async {
      final failing = AlarmService(
        bridge: _ThrowingBridge(),
        reminders: reminders,
        routines: _Routines(const []),
        events: events,
        now: () => now,
      );
      final result = await failing.sync('app_start');
      expect(result.ok, isFalse);
      expect(result.mismatches.single, contains('Could not sync alarms'));
    });

    test('compareScheduled flags wrong times and leftovers', () {
      final tue7 = DateTime(2026, 10, 13, 7, 0).millisecondsSinceEpoch; // next Tuesday 07:00
      final wrong = DateTime(2026, 10, 7, 8, 15).millisecondsSinceEpoch; // Wednesday 08:15
      final check = AlarmService.compareScheduled(
        const [Reminder(id: 1, label: 'Morning', hour: 7, minute: 0, weekdays: [2, 3])],
        [
          ScheduledAlarm(reminderId: 1, weekday: 2, kind: 'main', triggerAtMs: tue7, exists: true),
          ScheduledAlarm(reminderId: 1, weekday: 3, kind: 'main', triggerAtMs: wrong, exists: true),
          ScheduledAlarm(reminderId: 9, weekday: 5, kind: 'main', triggerAtMs: tue7, exists: true),
          ScheduledAlarm(reminderId: 1, weekday: 0, kind: 'snooze', triggerAtMs: tue7, exists: true),
        ],
        now,
      );
      expect(check.expected, 2);
      expect(check.scheduled, 1);
      expect(check.mismatches, hasLength(2));
      expect(check.mismatches[0], contains('08:15'));
      expect(check.mismatches[1], contains('#9'));
    });
  });

  group('missedBanner', () {
    final occurrence = DateTime(2026, 10, 6, 11, 0); // 60 min before now

    test('returns an unanswered occurrence within 90 minutes', () async {
      await events.addAll([
        ev(1, occurrence, 'rang', Duration.zero),
        ev(1, occurrence, 'auto_stopped', const Duration(minutes: 2)),
        ev(1, occurrence, 'nag_rang', const Duration(minutes: 12)),
      ]);
      final missed = await service.missedBanner(now);
      expect(missed, isNotNull);
      expect(missed!.reminderId, 1);
      expect(missed.occurrenceMs, occurrence.millisecondsSinceEpoch);
      expect(missed.routineId, 10);
      expect(missed.label, 'Morning');
    });

    test('is cleared once the occurrence was started', () async {
      await events.addAll([
        ev(1, occurrence, 'rang', Duration.zero),
        ev(1, occurrence, 'auto_stopped', const Duration(minutes: 2)),
        ev(1, occurrence, 'started', const Duration(minutes: 20)),
      ]);
      expect(await service.missedBanner(now), isNull);
    });

    test('is cleared once the occurrence was dismissed', () async {
      await events.addAll([
        ev(1, occurrence, 'rang', Duration.zero),
        ev(1, occurrence, 'dismissed', const Duration(minutes: 1)),
      ]);
      expect(await service.missedBanner(now), isNull);
    });

    test('ignores occurrences older than 90 minutes', () async {
      final old = now.subtract(const Duration(minutes: 91));
      await events.addAll([
        ev(1, old, 'rang', Duration.zero),
        ev(1, old, 'auto_stopped', const Duration(minutes: 2)),
      ]);
      expect(await service.missedBanner(now), isNull);
    });

    test('ignores pending snoozes, test alarms and deleted reminders', () async {
      await events.addAll([
        ev(1, occurrence, 'rang', Duration.zero),
        ev(1, occurrence, 'snoozed', const Duration(minutes: 1)),
        ev(-1, occurrence, 'test_rang', Duration.zero),
        ev(-1, occurrence, 'auto_stopped', const Duration(minutes: 2)),
        ev(42, occurrence, 'rang', Duration.zero),
      ]);
      expect(await service.missedBanner(now), isNull);
    });

    test('picks the latest unanswered occurrence', () async {
      final earlier = DateTime(2026, 10, 6, 10, 45);
      await events.addAll([
        ev(1, earlier, 'rang', Duration.zero),
        ev(1, earlier, 'auto_stopped', const Duration(minutes: 2)),
        ev(2, occurrence, 'rang', Duration.zero, label: 'Evening'),
        ev(2, occurrence, 'auto_stopped', const Duration(minutes: 2), label: 'Evening'),
      ]);
      final missed = await service.missedBanner(now);
      expect(missed?.reminderId, 2);
      expect(missed?.routineId, 11);
      expect(missed?.label, 'Evening');
    });
  });

  test('ingestEvents copies only new native events', () async {
    final occurrence = DateTime(2026, 10, 6, 11, 0);
    bridge.eventLog.addAll([
      ev(1, occurrence, 'rang', Duration.zero),
      ev(1, occurrence, 'auto_stopped', const Duration(minutes: 2)),
    ]);
    expect(await service.ingestEvents(), hasLength(2));
    expect(events.items, hasLength(2));

    bridge.eventLog.add(ev(1, occurrence, 'started', const Duration(minutes: 5)));
    await service.ingestEvents();
    expect(events.items.map((e) => e.event), ['rang', 'auto_stopped', 'started']);
    expect(await service.missedBanner(now), isNull);
  });

  test('ingestEvents imports events logged after the clock moved backwards', () async {
    final occurrence = DateTime(2026, 10, 6, 11, 0);
    // Logged while the clock was a day ahead (at_ms = tomorrow), then corrected.
    final early = DateTime(2026, 10, 6, 6, 0);
    bridge.eventLog.add(ev(2, early, 'rang', const Duration(days: 1, hours: 6), label: 'Evening'));
    await service.ingestEvents();
    bridge.eventLog.addAll([
      ev(1, occurrence, 'rang', Duration.zero),
      ev(1, occurrence, 'auto_stopped', const Duration(minutes: 2)),
    ]);
    await service.ingestEvents();
    expect(events.items, hasLength(3));
    expect((await service.missedBanner(now))?.reminderId, 1);
  });
}

class _ThrowingBridge extends FakeNativeBridge {
  @override
  Future<List<ScheduledAlarm>> syncReminders(List<Map<String, dynamic>> reminders) =>
      Future.error(StateError('engine gone'));
}
