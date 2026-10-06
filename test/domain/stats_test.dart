import 'package:daily_duas/core/models/models.dart' show SessionLog;
import 'package:daily_duas/domain/stats.dart';
import 'package:flutter_test/flutter_test.dart';

SessionLog log(
  DateTime finished, {
  bool completed = true,
  int? routineId,
  List<int> duas = const [1, 2],
}) {
  final iso = finished.toIso8601String();
  return SessionLog(
    startedAt: iso,
    finishedAt: completed ? iso : null,
    completed: completed,
    routineId: routineId,
    completedDuaIds: duas,
  );
}

void main() {
  final today = DateTime(2026, 10, 6, 15, 30);
  DateTime day(int offset, [int hour = 8]) => DateTime(2026, 10, 6 + offset, hour);

  test('completedDays uses local date-only values and ignores unfinished logs', () {
    final days = completedDays([
      log(day(0)),
      log(day(0, 20)),
      log(day(-1)),
      log(day(-3), completed: false),
    ]);
    expect(days, {DateTime(2026, 10, 6), DateTime(2026, 10, 5)});
  });

  test('completedDays parses ISO strings with offsets to local dates', () {
    const l = SessionLog(
      startedAt: '2026-10-06T12:00:00.000Z',
      finishedAt: '2026-10-06T12:00:00.000+00:00',
      completed: true,
    );
    final local = DateTime.utc(2026, 10, 6, 12).toLocal();
    expect(completedDays([l]), {DateTime(local.year, local.month, local.day)});
  });

  test('current streak from today', () {
    final days = {for (final o in [0, -1, -2]) DateTime(2026, 10, 6 + o)};
    expect(currentStreak(days, today), 3);
  });

  test('current streak from yesterday when today is missing', () {
    final days = {for (final o in [-1, -2, -3, -4]) DateTime(2026, 10, 6 + o)};
    expect(currentStreak(days, today), 4);
  });

  test('gaps break the streak', () {
    expect(currentStreak({DateTime(2026, 10, 4), DateTime(2026, 10, 3)}, today), 0);
    expect(currentStreak({DateTime(2026, 10, 6), DateTime(2026, 10, 4)}, today), 1);
    expect(currentStreak(const {}, today), 0);
  });

  test('streak across a month boundary', () {
    final days = {DateTime(2026, 10, 1), DateTime(2026, 9, 30), DateTime(2026, 9, 29)};
    expect(currentStreak(days, DateTime(2026, 10, 1, 23)), 3);
  });

  test('longest streak', () {
    final days = {
      DateTime(2026, 9, 1),
      DateTime(2026, 9, 2),
      DateTime(2026, 9, 3),
      DateTime(2026, 9, 4),
      DateTime(2026, 9, 10),
      DateTime(2026, 9, 11),
      DateTime(2026, 10, 6),
    };
    expect(longestStreak(days), 4);
    expect(longestStreak(const {}), 0);
    expect(longestStreak({DateTime(2026, 1, 1)}), 1);
  });

  test('totals', () {
    final t = totals([
      log(day(0), duas: [1, 2, 3]),
      log(day(0), duas: [4]),
      log(day(-2), duas: [1]),
      log(day(-1), completed: false, duas: [9, 9]),
    ]);
    expect(t.sessions, 3);
    expect(t.duas, 5);
    expect(t.days, 2);
  });

  test('todaySummary', () {
    final s = todaySummary([
      log(day(0), routineId: 1, duas: [1, 2]),
      log(day(0, 21), routineId: 2, duas: [3]),
      log(day(0), duas: [4]),
      log(day(-1), routineId: 3),
      log(day(0), completed: false, routineId: 4),
    ], today);
    expect(s.sessions, 3);
    expect(s.duas, 4);
    expect(s.routineIds, {1, 2});
  });
}
