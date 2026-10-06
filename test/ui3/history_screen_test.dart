import 'package:daily_duas/core/models/models.dart';
import 'package:daily_duas/core/providers.dart';
import 'package:daily_duas/core/util.dart';
import 'package:daily_duas/features/history/history_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui3_fakes.dart';

SessionLog _log(int id, DateTime start, {bool fromAlarm = false}) =>
    SessionLog(
      id: id,
      routineId: 1,
      startedAt: isoWithOffset(start),
      finishedAt: isoWithOffset(start.add(const Duration(minutes: 5))),
      completedDuaIds: const [1, 2, 3],
      fromAlarm: fromAlarm,
      completed: true,
    );

void main() {
  testWidgets('shows streaks, marks completed days and lists a day\'s sessions',
      (tester) async {
    useTallWindow(tester);
    final semantics = tester.ensureSemantics();
    final logs = [
      _log(1, DateTime(2026, 10, 6, 7), fromAlarm: true),
      _log(2, DateTime(2026, 10, 5, 7)),
      _log(3, DateTime(2026, 10, 4, 7)),
      _log(4, DateTime(2026, 9, 20, 7)),
    ];
    await tester.pumpWidget(testApp(const HistoryScreen(), [
      completedLogsProvider.overrideWith((ref) async => logs),
      routinesProvider.overrideWith(
          (ref) async => const [Routine(id: 1, name: 'Morning adhkar')]),
      nowProvider.overrideWithValue(() => DateTime(2026, 10, 6, 20)),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('3 days'), findsOneWidget); // current streak
    expect(find.text('Longest: 3 days'), findsOneWidget);
    expect(find.text('October 2026'), findsOneWidget);
    expect(find.bySemanticsLabel('October 6, completed, today'), findsOneWidget);
    expect(find.bySemanticsLabel('October 5, completed'), findsOneWidget);
    expect(find.bySemanticsLabel('October 7, not completed'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('October 6, completed, today'));
    await tester.pumpAndSettle();
    expect(find.text('Morning adhkar'), findsOneWidget);
    expect(find.textContaining('3 duas · from alarm'), findsOneWidget);

    await tester.tap(find.byTooltip('Previous month'));
    await tester.pumpAndSettle();
    expect(find.text('September 2026'), findsOneWidget);
    expect(find.bySemanticsLabel('September 20, completed'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('empty history shows the empty state and a zero streak',
      (tester) async {
    useTallWindow(tester);
    await tester.pumpWidget(testApp(const HistoryScreen(), [
      completedLogsProvider.overrideWith((ref) async => const <SessionLog>[]),
      routinesProvider.overrideWith((ref) async => const <Routine>[]),
      nowProvider.overrideWithValue(() => DateTime(2026, 10, 6, 20)),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('0 days'), findsOneWidget);
    expect(find.textContaining('No completed sessions yet'), findsOneWidget);
  });
}
