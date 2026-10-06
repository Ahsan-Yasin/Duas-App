// Sets timezone's tz.local from the device zone ID reported by Kotlin.
//
// Android reports ZoneId.systemDefault() as stored by the system, which can be
// an old alias (Europe/Kiev in Ukraine, Asia/Calcutta on some devices) that the
// bundled default database (timezone/data/latest.dart) leaves out. Resolution
// order: exact ID, known alias, a zone matching the device's UTC offsets, UTC.

import 'package:timezone/timezone.dart' as tz;

/// Backward-link IDs Android may report, mapped to their canonical IANA names.
const Map<String, String> zoneAliases = {
  'Asia/Calcutta': 'Asia/Kolkata',
  'Europe/Kiev': 'Europe/Kyiv',
  'Europe/Uzhgorod': 'Europe/Kyiv',
  'Europe/Zaporozhye': 'Europe/Kyiv',
  'Asia/Katmandu': 'Asia/Kathmandu',
  'Asia/Saigon': 'Asia/Ho_Chi_Minh',
  'Asia/Rangoon': 'Asia/Yangon',
  'Asia/Dacca': 'Asia/Dhaka',
  'Asia/Thimbu': 'Asia/Thimphu',
  'Asia/Ulan_Bator': 'Asia/Ulaanbaatar',
  'Asia/Chongqing': 'Asia/Shanghai',
  'Asia/Chungking': 'Asia/Shanghai',
  'Asia/Harbin': 'Asia/Shanghai',
  'Asia/Kashgar': 'Asia/Urumqi',
  'Asia/Macao': 'Asia/Macau',
  'Asia/Ujung_Pandang': 'Asia/Makassar',
  'Asia/Tel_Aviv': 'Asia/Jerusalem',
  'Asia/Istanbul': 'Europe/Istanbul',
  'Asia/Ashkhabad': 'Asia/Ashgabat',
  // Current IDs that tzdata keeps only as links (absent from the default DB).
  'Asia/Kuwait': 'Asia/Riyadh',
  'Asia/Aden': 'Asia/Riyadh',
  'Asia/Muscat': 'Asia/Dubai',
  'Asia/Bahrain': 'Asia/Qatar',
  'Asia/Kuala_Lumpur': 'Asia/Singapore',
  'Asia/Brunei': 'Asia/Kuching',
  'Africa/Addis_Ababa': 'Africa/Nairobi',
  'Africa/Asmara': 'Africa/Nairobi',
  'Africa/Asmera': 'Africa/Nairobi',
  'Africa/Dar_es_Salaam': 'Africa/Nairobi',
  'Africa/Djibouti': 'Africa/Nairobi',
  'Africa/Kampala': 'Africa/Nairobi',
  'Africa/Mogadishu': 'Africa/Nairobi',
  'Indian/Comoro': 'Africa/Nairobi',
  'Atlantic/Faeroe': 'Atlantic/Faroe',
  'America/Godthab': 'America/Nuuk',
  'America/Buenos_Aires': 'America/Argentina/Buenos_Aires',
  'America/Catamarca': 'America/Argentina/Catamarca',
  'America/Cordoba': 'America/Argentina/Cordoba',
  'America/Jujuy': 'America/Argentina/Jujuy',
  'America/Mendoza': 'America/Argentina/Mendoza',
  'America/Indianapolis': 'America/Indiana/Indianapolis',
  'America/Fort_Wayne': 'America/Indiana/Indianapolis',
  'America/Louisville': 'America/Kentucky/Louisville',
  'Pacific/Truk': 'Pacific/Port_Moresby',
  'Pacific/Yap': 'Pacific/Port_Moresby',
  'Pacific/Chuuk': 'Pacific/Port_Moresby',
  'Pacific/Ponape': 'Pacific/Guadalcanal',
  'Pacific/Pohnpei': 'Pacific/Guadalcanal',
  'Pacific/Enderbury': 'Pacific/Kanton',
  'Australia/ACT': 'Australia/Sydney',
  'Australia/Canberra': 'Australia/Sydney',
  'Australia/NSW': 'Australia/Sydney',
  'US/Eastern': 'America/New_York',
  'US/Central': 'America/Chicago',
  'US/Mountain': 'America/Denver',
  'US/Pacific': 'America/Los_Angeles',
  'US/Alaska': 'America/Anchorage',
  'US/Hawaii': 'Pacific/Honolulu',
  'US/Arizona': 'America/Phoenix',
  'GMT': 'Etc/UTC',
  'UTC': 'Etc/UTC',
  'Etc/GMT': 'Etc/UTC',
  'Universal': 'Etc/UTC',
  'Zulu': 'Etc/UTC',
};

/// The device's UTC offset at an instant (epoch ms).
typedef OffsetAt = Duration Function(int millisecondsSinceEpoch);

Duration _deviceOffsetAt(int ms) => DateTime.fromMillisecondsSinceEpoch(ms).timeZoneOffset;

tz.Location? _tryGet(String id) {
  if (id.isEmpty) return null;
  try {
    return tz.getLocation(id);
  } catch (_) {
    return null;
  }
}

/// Resolves [id] to a location: exact ID, then [zoneAliases], then the zone
/// whose offsets best match the device's over the next year (weekly samples,
/// so DST rules match too) among those with the device's current offset,
/// finally UTC. Local times only depend on offsets, so a same-profile zone
/// shows the same times as the real one. The database must be initialized.
tz.Location resolveLocation(String id, {OffsetAt? offsetAt, DateTime? now}) {
  final key = id.trim();
  final exact = _tryGet(key) ?? _tryGet(zoneAliases[key] ?? '');
  if (exact != null) return exact;

  final offsetOf = offsetAt ?? _deviceOffsetAt;
  final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  const week = 7 * 24 * 60 * 60 * 1000;
  final samples = [for (var i = 0; i <= 52; i++) nowMs + i * week];
  final device = [for (final ms in samples) offsetOf(ms)];

  tz.Location? best;
  var bestScore = 0;
  for (final loc in tz.timeZoneDatabase.locations.values) {
    if (loc.timeZone(nowMs).offset != device.first) continue;
    var score = 1;
    for (var i = 1; i < samples.length; i++) {
      if (loc.timeZone(samples[i]).offset == device[i]) score++;
    }
    if (score > bestScore) {
      best = loc;
      bestScore = score;
      if (score == samples.length) break;
    }
  }
  return best ?? tz.UTC;
}

/// Sets tz.local for the device zone [id] (see [resolveLocation]).
tz.Location applyLocalZone(String id, {OffsetAt? offsetAt, DateTime? now}) {
  final loc = resolveLocation(id, offsetAt: offsetAt, now: now);
  tz.setLocalLocation(loc);
  return loc;
}
