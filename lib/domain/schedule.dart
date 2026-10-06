/// Next-occurrence maths for weekly reminders. Pure Dart, mirrored by the
/// Kotlin alarm engine (java.time).
///
/// DST rules follow `ZonedDateTime.of(localDate, localTime, zone)`:
/// * gap (wall time does not exist): the time is shifted forward by the length
///   of the gap, e.g. 02:30 on a spring-forward day in New York → 03:30 EDT;
/// * overlap (wall time happens twice): the earlier instant (the offset in
///   force before the transition) is used.
library;

import 'package:daily_duas/core/models/models.dart' show Reminder;
import 'package:timezone/timezone.dart' as tz;

const int _hourMs = 3600 * 1000;

int _offsetAt(tz.Location location, int instantMs) =>
    location.timeZone(instantMs).offset.inMilliseconds;

/// The instant of the local wall time `year-month-day hour:minute` in
/// [location], with java.time gap/overlap semantics.
tz.TZDateTime resolveLocalDateTime(
  tz.Location location,
  int year,
  int month,
  int day,
  int hour,
  int minute,
) {
  // Wall-clock milliseconds as if the wall time were UTC. DateTime.utc
  // normalizes out-of-range days (e.g. day 32).
  final wallMs = DateTime.utc(year, month, day, hour, minute).millisecondsSinceEpoch;
  // Every real offset lies in [-12h, +14h], so the instants of interest are in
  // [wall - 14h, wall + 12h]. Offsets just outside that window are the offsets
  // before and after any transition inside it.
  final before = _offsetAt(location, wallMs - 15 * _hourMs);
  final after = _offsetAt(location, wallMs + 13 * _hourMs);

  final valid = <int>[];
  for (final off in {before, after}) {
    final candidate = wallMs - off;
    if (_offsetAt(location, candidate) == off) valid.add(candidate);
  }
  int instant;
  if (valid.isEmpty) {
    // Gap: interpret with the offset before the transition, which moves the
    // wall time forward by the gap length.
    instant = wallMs - before;
  } else {
    // Overlap → earliest instant; normal → the single valid instant.
    valid.sort();
    instant = valid.first;
  }
  return tz.TZDateTime.fromMillisecondsSinceEpoch(location, instant);
}

/// The smallest instant strictly after [after] that falls on one of
/// [weekdays] (ISO, Mon=1..Sun=7) at local [hour]:[minute] in
/// `after.location`. Returns null when [weekdays] contains no valid day or the
/// time is invalid.
tz.TZDateTime? nextOccurrence(
  int hour,
  int minute,
  Iterable<int> weekdays,
  tz.TZDateTime after,
) {
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  final allowed = weekdays.where((d) => d >= 1 && d <= 7).toSet();
  if (allowed.isEmpty) return null;
  final loc = after.location;
  // Calendar arithmetic on a UTC date so DST never shifts the day.
  final base = DateTime.utc(after.year, after.month, after.day);
  for (var i = 0; i <= 14; i++) {
    final date = DateTime.utc(base.year, base.month, base.day + i);
    if (!allowed.contains(date.weekday)) continue;
    final candidate =
        resolveLocalDateTime(loc, date.year, date.month, date.day, hour, minute);
    if (candidate.isAfter(after)) return candidate;
  }
  return null;
}

/// The next occurrence of every enabled reminder (one entry per reminder),
/// sorted by time then reminder id, at most [limit] entries.
List<(Reminder, tz.TZDateTime)> upcoming(
  List<Reminder> reminders,
  tz.TZDateTime after, {
  int limit = 10,
}) {
  final out = <(Reminder, tz.TZDateTime)>[];
  for (final r in reminders) {
    if (!r.enabled) continue;
    final next = nextOccurrence(r.hour, r.minute, r.weekdays, after);
    if (next != null) out.add((r, next));
  }
  out.sort((x, y) {
    final c = x.$2.compareTo(y.$2);
    if (c != 0) return c;
    return (x.$1.id ?? 0).compareTo(y.$1.id ?? 0);
  });
  if (limit >= 0 && out.length > limit) return out.sublist(0, limit);
  return out;
}

/// The soonest enabled reminder occurrence after [after], or null.
(Reminder, tz.TZDateTime)? nextAlarm(List<Reminder> reminders, tz.TZDateTime after) {
  final list = upcoming(reminders, after, limit: 1);
  return list.isEmpty ? null : list.first;
}

/// "in 6 h 12 min", "in 45 min", "in 2 d 3 h", "in less than a minute".
/// Minutes are truncated; negative durations count as less than a minute.
String formatCountdown(Duration d) {
  final totalMinutes = d.inMinutes;
  if (totalMinutes < 1) return 'in less than a minute';
  if (totalMinutes < 60) return 'in $totalMinutes min';
  final days = totalMinutes ~/ (24 * 60);
  final hours = (totalMinutes % (24 * 60)) ~/ 60;
  final minutes = totalMinutes % 60;
  if (days > 0) {
    return hours > 0 ? 'in $days d $hours h' : 'in $days d';
  }
  return minutes > 0 ? 'in $hours h $minutes min' : 'in $hours h';
}
