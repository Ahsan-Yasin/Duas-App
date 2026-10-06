import 'package:daily_duas/core/db/app_database.dart';
import 'package:daily_duas/core/models/models.dart';
import 'package:daily_duas/core/native/native_bridge.dart';
import 'package:daily_duas/core/navigation.dart' as nav;
import 'package:daily_duas/core/providers.dart';
import 'package:daily_duas/features/alarm/alarm_ring_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui2_test_utils.dart';

void main() {
  late AppDatabase db;
  late SeededRoutine seeded;
  late FakeNativeBridge bridge;

  setUp(() async {
    db = await openUi2TestDb();
    seeded = await seedRoutine(db);
    bridge = FakeNativeBridge();
  });

  tearDown(() async {
    await db.close();
  });

  RingingAlarm alarm({int snoozesUsed = 0, int maxSnoozes = 3}) => RingingAlarm(
        reminderId: 7,
        occurrenceMs: 1767225600000,
        routineId: seeded.routineId,
        label: 'Fajr adhkar',
        kind: 'main',
        snoozesUsed: snoozesUsed,
        maxSnoozes: maxSnoozes,
        startedMs: 1767225600000,
      );

  /// Hosts the alarm screen on top of a home route so it can be popped.
  Widget app(RingingAlarm a) {
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        initialSettingsProvider.overrideWithValue(
          AppSettings(haptics: false, defaultRoutineId: seeded.routineId),
        ),
        nativeBridgeProvider.overrideWithValue(bridge),
        duaPlayerProvider.overrideWithValue(FakeDuaPlayer()),
        nowProvider.overrideWithValue(() => DateTime(2026, 10, 6, 5, 7)),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AlarmRingScreen(alarm: a),
                  ),
                ),
                child: const Text('open alarm'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openAlarm(WidgetTester tester, RingingAlarm a) async {
    await tester.pumpWidget(app(a));
    await tester.tap(find.text('open alarm'));
    await tester.pumpAndSettle();
    await pumpUntilFound(tester, find.text('Morning'));
  }

  testWidgets('shows time, label, routine and the three actions',
      (tester) async {
    await openAlarm(tester, alarm());

    expect(find.text('05:07'), findsOneWidget);
    expect(find.text('Fajr adhkar'), findsOneWidget);
    expect(find.text('Morning'), findsOneWidget);
    expect(find.text('Start reciting'), findsOneWidget);
    expect(find.text('Snooze 5 min (3 left)'), findsOneWidget);
    expect(find.text('Dismiss'), findsOneWidget);
  });

  testWidgets('Dismiss calls alarmAction and closes the screen',
      (tester) async {
    await openAlarm(tester, alarm());

    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();

    expect(bridge.actions, [('dismiss', 7, 1767225600000)]);
    expect(find.byType(AlarmRingScreen), findsNothing);
    expect(find.text('open alarm'), findsOneWidget);
  });

  testWidgets('Snooze is hidden when no snoozes are left', (tester) async {
    await openAlarm(tester, alarm(snoozesUsed: 3, maxSnoozes: 3));

    expect(find.textContaining('Snooze'), findsNothing);
    expect(find.text('No snoozes left'), findsOneWidget);
    expect(find.text('Start reciting'), findsOneWidget);
  });

  testWidgets('stopped event keeps Start and shows a hint', (tester) async {
    await openAlarm(tester, alarm());

    bridge.emit({'type': 'stopped', 'reminder_id': 7, 'reason': 'timeout'});
    await tester.pump();
    await tester.pump();

    expect(find.text('Alarm stopped — start when you are ready'), findsOneWidget);
    expect(find.text('Start reciting'), findsOneWidget);
  });

  testWidgets('Start reciting opens the recite screen', (tester) async {
    await openAlarm(tester, alarm());

    await tester.tap(find.text('Start reciting'));
    await tester.pump();
    await pumpUntilFound(tester, find.text('Dua 1 of 3'));
    await tester.pumpAndSettle();

    expect(bridge.actions.single.$1, 'start');
    expect(find.byType(AlarmRingScreen), findsNothing);
    expect(find.text('Dua 1 of 3'), findsOneWidget);
  });

  testWidgets('a snooze from the notification closes the screen',
      (tester) async {
    await openAlarm(tester, alarm());

    bridge.emit({
      'type': 'stopped',
      'reminder_id': 7,
      'occurrence_ms': 1767225600000,
      'reason': 'snoozed',
    });
    await tester.pumpAndSettle();

    expect(find.byType(AlarmRingScreen), findsNothing);
    expect(find.text('open alarm'), findsOneWidget);
    expect(bridge.actions, isEmpty);
  });

  testWidgets('a stop for another occurrence is ignored', (tester) async {
    await openAlarm(tester, alarm());

    bridge.emit({
      'type': 'stopped',
      'reminder_id': 7,
      'occurrence_ms': 1,
      'reason': 'dismissed',
    });
    await tester.pumpAndSettle();

    expect(find.byType(AlarmRingScreen), findsOneWidget);
  });

  testWidgets('a dismiss from the notification removes the screen below '
      'another route', (tester) async {
    await openAlarm(tester, alarm());
    tester.state<NavigatorState>(find.byType(Navigator)).push(
          MaterialPageRoute<void>(builder: (_) => const Text('on top')),
        );
    await tester.pumpAndSettle();

    bridge.emit({'type': 'stopped', 'reminder_id': 7, 'reason': 'dismissed'});
    await tester.pumpAndSettle();

    expect(find.text('on top'), findsOneWidget);
    expect(find.byType(AlarmRingScreen, skipOffstage: false), findsNothing);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.text('open alarm'), findsOneWidget);
  });

  testWidgets('a refused snooze keeps the screen open', (tester) async {
    // The engine has no snoozes left although this (stale) screen offers one.
    bridge.ringing = alarm(maxSnoozes: 0);
    await openAlarm(tester, alarm());

    await tester.tap(find.text('Snooze 5 min (3 left)'));
    await tester.pumpAndSettle();

    expect(bridge.actions.single.$1, 'snooze');
    expect(find.byType(AlarmRingScreen), findsOneWidget);
    expect(find.text('No snoozes left'), findsWidgets);
    expect(find.textContaining('Snooze 5 min'), findsNothing);
  });

  group('alarm routing', () {
    Widget routedApp() => ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            initialSettingsProvider.overrideWithValue(
              AppSettings(haptics: false, defaultRoutineId: seeded.routineId),
            ),
            nativeBridgeProvider.overrideWithValue(bridge),
            duaPlayerProvider.overrideWithValue(FakeDuaPlayer()),
            nowProvider.overrideWithValue(() => DateTime(2026, 10, 6, 5, 7)),
          ],
          child: MaterialApp(
            navigatorKey: nav.navigatorKey,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: const Scaffold(body: Text('home')),
          ),
        );

    RingingAlarm reRing(RingingAlarm a, {required int startedMs}) =>
        RingingAlarm(
          reminderId: a.reminderId,
          occurrenceMs: a.occurrenceMs,
          routineId: a.routineId,
          label: a.label,
          kind: 'snooze',
          snoozesUsed: a.snoozesUsed + 1,
          maxSnoozes: a.maxSnoozes,
          startedMs: startedMs,
        );

    testWidgets('a re-ring of the same occurrence refreshes a stale screen',
        (tester) async {
      await tester.pumpWidget(routedApp());
      final first = alarm();
      nav.showRingingAlarm(first);
      await tester.pumpAndSettle();
      bridge.emit({'type': 'stopped', 'reminder_id': 7, 'reason': 'auto_stopped'});
      await tester.pumpAndSettle();
      expect(find.text('Alarm stopped — start when you are ready'),
          findsOneWidget);

      // The same ring again (e.g. replayed ringing event): no new screen.
      nav.showRingingAlarm(first);
      await tester.pumpAndSettle();
      expect(find.text('Alarm stopped — start when you are ready'),
          findsOneWidget);

      nav.showRingingAlarm(reRing(first, startedMs: first.startedMs + 600000));
      await tester.pumpAndSettle();
      expect(find.byType(AlarmRingScreen), findsOneWidget);
      expect(find.text('Alarm stopped — start when you are ready'),
          findsNothing);
      expect(find.text('Snooze 5 min (2 left)'), findsOneWidget);
    });

    testWidgets('closeAlarm removes only the matching reminder',
        (tester) async {
      await tester.pumpWidget(routedApp());
      nav.showRingingAlarm(alarm());
      await tester.pumpAndSettle();

      nav.closeAlarm(reminderId: 8);
      await tester.pumpAndSettle();
      expect(nav.isShowingAlarm(), isTrue);

      nav.closeAlarm(reminderId: 7);
      await tester.pumpAndSettle();
      expect(nav.isShowingAlarm(), isFalse);
      expect(find.byType(AlarmRingScreen), findsNothing);
      expect(find.text('home'), findsOneWidget);
    });
  });
}
