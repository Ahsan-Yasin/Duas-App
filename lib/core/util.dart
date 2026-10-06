import 'dart:convert';

/// ISO-8601 string of [dt] in local time *with* the UTC offset,
/// e.g. `2026-10-06T07:05:00.000+05:00`.
String isoWithOffset(DateTime dt) {
  final local = dt.toLocal();
  final trimmed = DateTime(local.year, local.month, local.day, local.hour,
      local.minute, local.second, local.millisecond);
  final off = local.timeZoneOffset;
  final sign = off.isNegative ? '-' : '+';
  final abs = off.abs();
  final hh = abs.inHours.toString().padLeft(2, '0');
  final mm = (abs.inMinutes % 60).toString().padLeft(2, '0');
  return '${trimmed.toIso8601String()}$sign$hh:$mm';
}

/// Current local time as ISO-8601 with offset. Use for every DB timestamp.
String nowIso() => isoWithOffset(DateTime.now());

/// Parses an ISO-8601 string (with or without offset) into local time.
/// Returns null for null/empty/invalid input.
DateTime? parseIso(String? s) {
  if (s == null || s.trim().isEmpty) return null;
  return DateTime.tryParse(s.trim())?.toLocal();
}

/// Lenient int conversion (int, double, numeric string, bool); null otherwise.
int? asInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is bool) return v ? 1 : 0;
  if (v is String) return int.tryParse(v.trim()) ?? double.tryParse(v.trim())?.toInt();
  return null;
}

/// Lenient double conversion; null when not numeric.
double? asDouble(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

/// Lenient bool conversion (bool, 0/1, "true"/"false"); [fallback] otherwise.
bool asBool(Object? v, {bool fallback = false}) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final t = v.trim().toLowerCase();
    if (t == 'true' || t == '1') return true;
    if (t == 'false' || t == '0') return false;
  }
  return fallback;
}

/// Non-null string conversion; [fallback] for null.
String asString(Object? v, {String fallback = ''}) {
  if (v == null) return fallback;
  return v is String ? v : v.toString();
}

/// Nullable string; empty strings stay empty, null stays null.
String? asStringOrNull(Object? v) => v == null ? null : asString(v);

/// Encodes a list as a JSON string (for TEXT columns).
String encodeJsonList(List<Object?> list) => jsonEncode(list);

/// Decodes a JSON list stored as String (or already a List) into ints.
/// Invalid input yields an empty list; non-numeric entries are dropped.
List<int> jsonIntList(Object? v) {
  final raw = _rawList(v);
  if (raw == null) return <int>[];
  return [
    for (final e in raw)
      if (asInt(e) case final int i) i,
  ];
}

/// Decodes a JSON list stored as String (or a List) into strings.
/// Returns null when [v] is null/invalid (not a list).
List<String>? jsonStringList(Object? v) {
  final raw = _rawList(v);
  if (raw == null) return null;
  return [for (final e in raw) if (e != null) asString(e)];
}

List<Object?>? _rawList(Object? v) {
  if (v == null) return null;
  if (v is List) return v.cast<Object?>();
  if (v is String) {
    if (v.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(v);
      if (decoded is List) return decoded.cast<Object?>();
    } on FormatException {
      return null;
    }
  }
  return null;
}

/// Decodes a JSON object string into a map; null when invalid.
Map<String, dynamic>? jsonMap(Object? v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return v.map((k, val) => MapEntry(k.toString(), val));
  if (v is String && v.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(v);
      if (decoded is Map) return decoded.map((k, val) => MapEntry(k.toString(), val));
    } on FormatException {
      return null;
    }
  }
  return null;
}

/// Clamps [v] into [min]..[max].
int clampInt(int v, int min, int max) => v < min ? min : (v > max ? max : v);
