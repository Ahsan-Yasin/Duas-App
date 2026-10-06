import 'package:daily_duas/core/local_zone.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(tzdata.initializeTimeZones);

  final now = DateTime.utc(2026, 7, 1, 12);

  test('exact IDs resolve to themselves', () {
    expect(resolveLocation('Asia/Karachi').name, 'Asia/Karachi');
    expect(resolveLocation('Europe/London').name, 'Europe/London');
  });

  test('Android alias IDs resolve to their canonical zone', () {
    expect(resolveLocation('Asia/Calcutta').name, 'Asia/Kolkata');
    expect(resolveLocation('Europe/Kiev').name, 'Europe/Kyiv');
    expect(resolveLocation('Asia/Katmandu').name, 'Asia/Kathmandu');
    expect(resolveLocation('Asia/Saigon').name, 'Asia/Ho_Chi_Minh');
    expect(resolveLocation('America/Buenos_Aires').name,
        'America/Argentina/Buenos_Aires');
  });

  test('every alias target exists in the bundled database', () {
    for (final e in zoneAliases.entries) {
      expect(() => tz.getLocation(e.value), returnsNormally, reason: e.key);
    }
  });

  test('unknown IDs fall back to a zone with the device offsets and DST rules',
      () {
    // Device on UK rules: +1 h in summer, 0 in winter.
    final london = tz.getLocation('Europe/London');
    Duration offsetAt(int ms) => london.timeZone(ms).offset;
    final loc = resolveLocation('Bogus/Zone', offsetAt: offsetAt, now: now);
    for (var m = 0; m < 12; m++) {
      final ms = DateTime.utc(2026, 7 + m, 15).millisecondsSinceEpoch;
      expect(loc.timeZone(ms).offset, london.timeZone(ms).offset,
          reason: '${loc.name} month +$m');
    }
  });

  test('falls back to UTC when no zone has the device offset', () {
    final loc = resolveLocation('',
        offsetAt: (_) => const Duration(hours: 5, minutes: 17), now: now);
    expect(loc, same(tz.UTC));
  });

  test('applyLocalZone sets tz.local', () {
    applyLocalZone('Europe/Kiev');
    expect(tz.local.name, 'Europe/Kyiv');
    applyLocalZone('UTC');
    expect(tz.local.timeZone(now.millisecondsSinceEpoch).offset, Duration.zero);
  });
}
