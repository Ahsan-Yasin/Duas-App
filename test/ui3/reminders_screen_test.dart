import 'package:daily_duas/core/models/models.dart';
import 'package:daily_duas/core/native/native_bridge.dart';
import 'package:daily_duas/core/providers.dart';
import 'package:daily_duas/features/reminders/reminders_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui3_fakes.dart';

void main() {
  group('weekdaySummary', () {
    test('summarises common patterns', () {
      expect(weekdaySummary([1, 2, 3, 4, 5, 6, 7]), 'Every day');
      expect(weekdaySummary([1, 2, 3, 4, 5]), 'Mon–Fri');
      expect(weekdaySummary([7, 6]), 'Weekends');
      expect(weekdaySummary([1, 3, 5]), 'Mon, Wed, Fri');
    });
  });

  test('nextLocalOccurrence skips disallowed days and past times', () {
    final now = DateTime(2026, 10, 6, 12); // Tuesday
    expect(nextLocalOccurrence(7, 0, [2], now), DateTime(2026, 10, 13, 7));
    expect(nextLocalOccurrence(13, 0, [2], now), DateTime(2026, 10, 6, 13));
    expect(nextLocalOccurrence(7, 0, [3], now), DateTime(2026, 10, 7, 7));
    expect(nextLocalOccurrence(7, 0, const [], now), isNull);
  });

  testWidgets('empty state; test alarm button schedules a native test alarm',
      (tester) async {
    final bridge = RecordingBridge();
    await tester.pumpWidget(testApp(const RemindersScreen(), [
      initialSettingsProvider
          .overrideWithValue(const AppSettings(defaultRoutineId: 7)),
      settingsRepoProvider.overrideWithValue(MemSettingsRepository()),
      nativeBridgeProvider.overrideWithValue(bridge),
      remindersProvider.overrideWith((ref) async => const <Reminder>[]),
      routinesProvider.overrideWith((ref) async => const <Routine>[]),
      nowProvider.overrideWithValue(() => DateTime(2026, 10, 6, 12)),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('No reminders yet'), findsOneWidget);
    expect(find.text('Reminders may not ring'), findsNothing);

    await tester.tap(find.text('Test alarm in 10 seconds'));
    await tester.pump();

    expect(bridge.testCalls, [(10, 'Test alarm', 7)]);
    expect(find.textContaining('Alarm will ring in 10 seconds'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('lists reminders and warns when exact alarms are blocked',
      (tester) async {
    useTallWindow(tester);
    final bridge = RecordingBridge()
      ..status = const NativeStatus(
        notificationsEnabled: true,
        exactAlarmsAllowed: false,
        fullScreenAllowed: true,
        ignoringBatteryOptimizations: true,
        manufacturer: 'samsung',
        model: 'SM-A556',
        timezone: 'UTC',
        sdkInt: 35,
        isAndroid: true,
      );
    await tester.pumpWidget(testApp(const RemindersScreen(), [
      initialSettingsProvider.overrideWithValue(const AppSettings()),
      settingsRepoProvider.overrideWithValue(MemSettingsRepository()),
      nativeBridgeProvider.overrideWithValue(bridge),
      remindersProvider.overrideWith((ref) async => const [
            Reminder(
                id: 1,
                label: 'Morning adhkar',
                hour: 13,
                minute: 30,
                weekdays: [1, 2, 3, 4, 5],
                routineId: 3),
          ]),
      routinesProvider.overrideWith(
          (ref) async => const [Routine(id: 3, name: 'Morning')]),
      nowProvider.overrideWithValue(() => DateTime(2026, 10, 6, 12)),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Reminders may not ring'), findsOneWidget);
    expect(find.text('Morning adhkar'), findsOneWidget);
    expect(find.text('Mon–Fri · Morning'), findsOneWidget);
    expect(find.textContaining('Rings in 1 h 30 min'), findsOneWidget);
  });
}
