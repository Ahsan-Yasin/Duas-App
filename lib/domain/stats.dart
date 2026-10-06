/// Streaks and totals from session logs. Pure Dart.
///
/// A day counts when at least one completed session finished on it (local
/// date of `finishedAt`, falling back to `startedAt`).
library;

import 'package:daily_duas/core/models/models.dart' show SessionLog;

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime? _logDay(SessionLog l) {
  final raw = l.finishedAt ?? l.startedAt;
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) return null;
  return _dateOnly(parsed.toLocal());
}

/// Local calendar days (time 00:00) with at least one completed session.
Set<DateTime> completedDays(List<SessionLog> logs) {
  final days = <DateTime>{};
  for (final l in logs) {
    if (!l.completed) continue;
    final d = _logDay(l);
    if (d != null) days.add(d);
  }
  return days;
}

/// Consecutive days ending today, or ending yesterday when today has no
/// session yet (the streak is still alive). 0 otherwise.
int currentStreak(Set<DateTime> days, DateTime today) {
  final set = days.map(_dateOnly).toSet();
  var day = _dateOnly(today);
  if (!set.contains(day)) {
    day = DateTime(day.year, day.month, day.day - 1);
    if (!set.contains(day)) return 0;
  }
  var streak = 0;
  while (set.contains(day)) {
    streak++;
    day = DateTime(day.year, day.month, day.day - 1);
  }
  return streak;
}

/// Longest run of consecutive days.
int longestStreak(Set<DateTime> days) {
  if (days.isEmpty) return 0;
  final sorted = days.map(_dateOnly).toSet().toList()..sort();
  var best = 1, run = 1;
  for (var i = 1; i < sorted.length; i++) {
    final prev = sorted[i - 1];
    final expected = DateTime(prev.year, prev.month, prev.day + 1);
    run = sorted[i] == expected ? run + 1 : 1;
    if (run > best) best = run;
  }
  return best;
}

/// Completed sessions, duas recited in them and distinct active days.
({int sessions, int duas, int days}) totals(List<SessionLog> logs) {
  var sessions = 0, duas = 0;
  for (final l in logs) {
    if (!l.completed) continue;
    sessions++;
    duas += l.completedDuaIds.length;
  }
  return (sessions: sessions, duas: duas, days: completedDays(logs).length);
}

/// Completed sessions on [today]'s local date.
({int sessions, int duas, Set<int> routineIds}) todaySummary(
  List<SessionLog> logs,
  DateTime today,
) {
  final day = _dateOnly(today);
  var sessions = 0, duas = 0;
  final routineIds = <int>{};
  for (final l in logs) {
    if (!l.completed || _logDay(l) != day) continue;
    sessions++;
    duas += l.completedDuaIds.length;
    final r = l.routineId;
    if (r != null) routineIds.add(r);
  }
  return (sessions: sessions, duas: duas, routineIds: routineIds);
}
