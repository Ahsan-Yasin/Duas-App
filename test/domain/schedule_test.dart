import 'package:daily_duas/core/models/models.dart' show Reminder;
import 'package:daily_duas/domain/schedule.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  late tz.Location ny;
  late tz.Location london;

  setUpAll(() {
    tzdata.initializeTimeZones();
    ny = tz.getLocation('America/New_York');
    london = tz.getLocation('Europe/London');
  });

  tz.TZDateTime at(tz.Location l, int y, int m, int d, [int h = 0, int min = 0, int s = 0]) =>
      tz.TZDateTime(l, y, m, d, h, min, s);

  const all = [1, 2, 3, 4, 5, 6, 7];

  // 2026-10-06 is a Tuesday.
  group('nextOccurrence basics', () {
    test('same day later time', () {
      final r = nextOccurrence(9, 0, all, at(ny, 2026, 10, 6, 8, 0))!;
      expect(r, at(ny, 2026, 10, 6, 9, 0));
      expect(r.location, ny);
    });

    test('already passed today moves to tomorrow', () {
      expect(nextOccurrence(7, 0, all, at(ny, 2026, 10, 6, 8, 0)), at(ny, 2026, 10, 7, 7, 0));
    });

    test('exactly now is not "after"', () {
      expect(nextOccurrence(7, 0, all, at(ny, 2026, 10, 6, 7, 0)), at(ny, 2026, 10, 7, 7, 0));
      expect(nextOccurrence(7, 0, all, at(ny, 2026, 10, 6, 6, 59, 59)), at(ny, 2026, 10, 6, 7, 0));
    });

    test('weekday selection (Mon/Wed/Fri)', () {
      expect(nextOccurrence(7, 0, [1, 3, 5], at(ny, 2026, 10, 6, 8)), at(ny, 2026, 10, 7, 7, 0));
      expect(nextOccurrence(7, 0, [5], at(ny, 2026, 10, 6, 8)), at(ny, 2026, 10, 9, 7, 0));
    });

    test('midnight 00:00 and 23:59 crossing', () {
      expect(nextOccurrence(0, 0, all, at(ny, 2026, 10, 6, 23, 59, 30)), at(ny, 2026, 10, 7, 0, 0));
      expect(nextOccurrence(23, 59, all, at(ny, 2026, 10, 6, 23, 58)), at(ny, 2026, 10, 6, 23, 59));
      expect(nextOccurrence(23, 59, all, at(ny, 2026, 10, 6, 23, 59)), at(ny, 2026, 10, 7, 23, 59));
      // Only Wednesday at 00:00, asked late on Tuesday.
      expect(nextOccurrence(0, 0, [3], at(ny, 2026, 10, 6, 23, 0)), at(ny, 2026, 10, 7, 0, 0));
    });

    test('Sunday -> Monday wrap', () {
      // 2026-10-11 is a Sunday.
      expect(nextOccurrence(7, 0, [1], at(ny, 2026, 10, 11, 20)), at(ny, 2026, 10, 12, 7, 0));
    });

    test('single weekday already passed today -> next week', () {
      expect(nextOccurrence(7, 0, [2], at(ny, 2026, 10, 6, 8)), at(ny, 2026, 10, 13, 7, 0));
    });

    test('all 7 days', () {
      final start = at(ny, 2026, 10, 6, 12);
      var t = start;
      for (var i = 0; i < 7; i++) {
        t = nextOccurrence(6, 30, all, t)!;
        expect(t, at(ny, 2026, 10, 7 + i, 6, 30));
      }
    });

    test('invalid input', () {
      expect(nextOccurrence(7, 0, const [], at(ny, 2026, 10, 6)), isNull);
      expect(nextOccurrence(7, 0, const [0, 8], at(ny, 2026, 10, 6)), isNull);
      expect(nextOccurrence(24, 0, all, at(ny, 2026, 10, 6)), isNull);
    });
  });

  group('DST (java.time semantics)', () {
    test('New York spring-forward gap 02:30 -> 03:30 EDT', () {
      final r = nextOccurrence(2, 30, all, at(ny, 2026, 3, 8, 0, 0))!;
      expect(r.toUtc(), DateTime.utc(2026, 3, 8, 7, 30));
      expect(r.hour, 3);
      expect(r.minute, 30);
      expect(r.timeZoneOffset, const Duration(hours: -4));
      // Next day is a normal 02:30 EDT.
      expect(nextOccurrence(2, 30, all, r), at(ny, 2026, 3, 9, 2, 30));
    });

    test('New York fall-back overlap 01:30 -> earlier instant (EDT)', () {
      final r = nextOccurrence(1, 30, all, at(ny, 2026, 11, 1, 0, 0))!;
      expect(r.toUtc(), DateTime.utc(2026, 11, 1, 5, 30));
      expect(r.timeZoneOffset, const Duration(hours: -4));
      // After the first 01:30 has passed the next one is tomorrow, not the
      // repeated 01:30 EST an hour later.
      expect(nextOccurrence(1, 30, all, r), at(ny, 2026, 11, 2, 1, 30));
    });

    test('Europe/London gap and overlap', () {
      final spring = nextOccurrence(1, 30, all, at(london, 2026, 3, 29, 0, 0))!;
      expect(spring.toUtc(), DateTime.utc(2026, 3, 29, 1, 30)); // 02:30 BST
      expect(spring.hour, 2);
      final autumn = nextOccurrence(1, 30, all, at(london, 2026, 10, 25, 0, 0))!;
      expect(autumn.toUtc(), DateTime.utc(2026, 10, 25, 0, 30)); // 01:30 BST
      final winter = nextOccurrence(7, 0, all, at(london, 2026, 12, 1, 8))!;
      expect(winter.toUtc(), DateTime.utc(2026, 12, 2, 7, 0));
    });

    test('resolveLocalDateTime handles normal times', () {
      final r = resolveLocalDateTime(ny, 2026, 7, 4, 12, 0);
      expect(r.toUtc(), DateTime.utc(2026, 7, 4, 16, 0));
    });
  });

  test('time zone change: same wall time, different instants', () {
    final instant = DateTime.utc(2026, 10, 6, 0, 0);
    final karachi = tz.getLocation('Asia/Karachi');
    final berlin = tz.getLocation('Europe/Berlin');
    final a = nextOccurrence(7, 0, all, tz.TZDateTime.from(instant, karachi))!;
    final b = nextOccurrence(7, 0, all, tz.TZDateTime.from(instant, berlin))!;
    expect(a.hour, 7);
    expect(b.hour, 7);
    expect(a.toUtc(), DateTime.utc(2026, 10, 6, 2, 0));
    expect(b.toUtc(), DateTime.utc(2026, 10, 6, 5, 0));
    expect(a.isAtSameMomentAs(b), isFalse);
  });

  group('upcoming / nextAlarm', () {
    const morning = Reminder(id: 1, label: 'Morning', hour: 7, minute: 0);
    const evening = Reminder(id: 2, label: 'Evening', hour: 18, minute: 30);
    const off = Reminder(id: 3, label: 'Off', hour: 9, minute: 0, enabled: false);
    const friday = Reminder(id: 4, label: 'Kahf', hour: 10, minute: 0, weekdays: [5]);

    test('enabled only, sorted, limited', () {
      final now = at(ny, 2026, 10, 6, 12);
      final list = upcoming([morning, evening, off, friday], now);
      expect(list.map((e) => e.$1.id), [2, 1, 4]);
      expect(list.first.$2, at(ny, 2026, 10, 6, 18, 30));
      expect(upcoming([morning, evening, friday], now, limit: 2), hasLength(2));
      expect(upcoming(const [], now), isEmpty);
    });

    test('nextAlarm', () {
      final now = at(ny, 2026, 10, 6, 12);
      final n = nextAlarm([morning, evening, off], now)!;
      expect(n.$1.id, 2);
      expect(nextAlarm([off], now), isNull);
    });
  });

  test('formatCountdown', () {
    expect(formatCountdown(const Duration(hours: 6, minutes: 12, seconds: 40)), 'in 6 h 12 min');
    expect(formatCountdown(const Duration(minutes: 45)), 'in 45 min');
    expect(formatCountdown(const Duration(seconds: 59)), 'in less than a minute');
    expect(formatCountdown(Duration.zero), 'in less than a minute');
    expect(formatCountdown(const Duration(seconds: -5)), 'in less than a minute');
    expect(formatCountdown(const Duration(hours: 2)), 'in 2 h');
    expect(formatCountdown(const Duration(days: 2, hours: 3, minutes: 10)), 'in 2 d 3 h');
    expect(formatCountdown(const Duration(days: 1)), 'in 1 d');
  });
}
