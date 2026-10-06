/// Recitation session state machine (counter, skip/back/next, resume JSON).
/// Pure Dart.
library;

import 'dart:convert';
import 'dart:math' as math;

class SessionItem {
  const SessionItem({required this.duaId, required this.title, required this.target});

  final int duaId;
  final String title;

  /// Number of repetitions to recite (always >= 1).
  final int target;

  Map<String, dynamic> toJson() => {'dua_id': duaId, 'title': title, 'target': target};

  factory SessionItem.fromJson(Map<String, dynamic> m) => SessionItem(
        duaId: (m['dua_id'] as num).toInt(),
        title: (m['title'] as String?) ?? '',
        target: math.max(1, ((m['target'] as num?) ?? 1).toInt()),
      );
}

class TapResult {
  const TapResult({
    required this.count,
    required this.target,
    required this.itemDone,
    required this.sessionDone,
    this.counted = true,
  });

  final int count;
  final int target;

  /// The current item has reached its target (now or earlier).
  final bool itemDone;

  /// Every item is completed or skipped.
  final bool sessionDone;

  /// False when the tap was ignored (target already reached / no item).
  final bool counted;
}

class ReciteSession {
  ReciteSession(
    List<SessionItem> items, {
    this.routineId,
    this.fromAlarm = false,
    this.reminderId,
    String? startedAt,
  })  : items = List.unmodifiable([
          for (final i in items)
            i.target < 1 ? SessionItem(duaId: i.duaId, title: i.title, target: 1) : i,
        ]),
        startedAt = startedAt ?? _nowIsoWithOffset();

  final List<SessionItem> items;
  final int? routineId;
  final bool fromAlarm;
  final int? reminderId;
  final String startedAt;

  /// Current position (0-based) in [items].
  int index = 0;

  /// Repetitions done, keyed by position.
  final Map<int, int> counts = {};

  /// Positions whose target was reached.
  final Set<int> completed = {};

  /// Positions skipped by the user.
  final Set<int> skipped = {};

  SessionItem? get current =>
      (index >= 0 && index < items.length) ? items[index] : null;

  int get count => counts[index] ?? 0;
  int get target => current?.target ?? 0;
  int get remaining => math.max(0, target - count);

  /// "Dua 2 of 5".
  String get positionLabel =>
      'Dua ${items.isEmpty ? 0 : index + 1} of ${items.length}';

  /// Overall progress 0..1: completed/skipped items count fully, the others by
  /// their counter.
  double get progress {
    if (items.isEmpty) return 1.0;
    var sum = 0.0;
    for (var i = 0; i < items.length; i++) {
      if (completed.contains(i) || skipped.contains(i)) {
        sum += 1;
      } else {
        sum += math.min(1.0, (counts[i] ?? 0) / items[i].target);
      }
    }
    return sum / items.length;
  }

  bool get isFinished {
    for (var i = 0; i < items.length; i++) {
      if (!completed.contains(i) && !skipped.contains(i)) return false;
    }
    return true;
  }

  bool get isCurrentDone => completed.contains(index);
  bool get isCurrentSkipped => skipped.contains(index);
  bool get isFirst => index <= 0;
  bool get isLast => index >= items.length - 1;

  List<int> get completedDuaIds =>
      [for (final p in completed.toList()..sort()) items[p].duaId];
  List<int> get skippedDuaIds =>
      [for (final p in skipped.toList()..sort()) items[p].duaId];

  /// Counts one repetition of the current item. Never exceeds the target;
  /// reaching it marks the item completed. Tapping a skipped item un-skips it.
  TapResult tap() {
    final item = current;
    if (item == null) {
      return TapResult(
          count: 0, target: 0, itemDone: false, sessionDone: isFinished, counted: false);
    }
    final c = count;
    if (c >= item.target) {
      completed.add(index);
      skipped.remove(index);
      return TapResult(
        count: item.target,
        target: item.target,
        itemDone: true,
        sessionDone: isFinished,
        counted: false,
      );
    }
    skipped.remove(index);
    final n = c + 1;
    counts[index] = n;
    final done = n >= item.target;
    if (done) completed.add(index);
    return TapResult(count: n, target: item.target, itemDone: done, sessionDone: isFinished);
  }

  /// Moves to the next item. Returns false when already at the last one.
  bool next() {
    if (index >= items.length - 1) return false;
    index++;
    return true;
  }

  /// Moves to the previous item. Returns false when already at the first one.
  bool back() {
    if (index <= 0) return false;
    index--;
    return true;
  }

  /// Jumps to [position]. Returns false when out of range.
  bool goTo(int position) {
    if (position < 0 || position >= items.length) return false;
    index = position;
    return true;
  }

  /// Marks the current item skipped (unless already completed) and advances.
  void skip() {
    if (current == null) return;
    if (!completed.contains(index)) skipped.add(index);
    next();
  }

  /// Resets the counter of the current item (clears completed/skipped).
  void resetCurrent() {
    if (current == null) return;
    counts.remove(index);
    completed.remove(index);
    skipped.remove(index);
  }

  /// Position of the first item that is neither completed nor skipped.
  int? get firstUnfinished {
    for (var i = 0; i < items.length; i++) {
      if (!completed.contains(i) && !skipped.contains(i)) return i;
    }
    return null;
  }

  String toJson() => jsonEncode({
        'v': 1,
        'items': [for (final i in items) i.toJson()],
        'routine_id': routineId,
        'from_alarm': fromAlarm,
        'reminder_id': reminderId,
        'started_at': startedAt,
        'index': index,
        'counts': {for (final e in counts.entries) '${e.key}': e.value},
        'completed': completed.toList()..sort(),
        'skipped': skipped.toList()..sort(),
      });

  /// Restores a session saved with [toJson]. Out-of-range values are clamped
  /// or dropped. Throws [FormatException] for text that is not a session.
  factory ReciteSession.fromJson(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic> || decoded['items'] is! List) {
      throw const FormatException('Not a saved recitation session');
    }
    final items = [
      for (final e in decoded['items'] as List)
        if (e is Map<String, dynamic>) SessionItem.fromJson(e),
    ];
    final s = ReciteSession(
      items,
      routineId: (decoded['routine_id'] as num?)?.toInt(),
      fromAlarm: decoded['from_alarm'] == true,
      reminderId: (decoded['reminder_id'] as num?)?.toInt(),
      startedAt: decoded['started_at'] as String?,
    );
    bool inRange(int p) => p >= 0 && p < s.items.length;
    final counts = decoded['counts'];
    if (counts is Map) {
      counts.forEach((k, v) {
        final p = int.tryParse('$k');
        if (p != null && inRange(p) && v is num) {
          s.counts[p] = v.toInt().clamp(0, s.items[p].target);
        }
      });
    }
    for (final v in (decoded['completed'] as List?) ?? const []) {
      if (v is num && inRange(v.toInt())) s.completed.add(v.toInt());
    }
    for (final v in (decoded['skipped'] as List?) ?? const []) {
      if (v is num && inRange(v.toInt()) && !s.completed.contains(v.toInt())) {
        s.skipped.add(v.toInt());
      }
    }
    final idx = (decoded['index'] as num?)?.toInt() ?? 0;
    s.index = s.items.isEmpty ? 0 : idx.clamp(0, s.items.length - 1);
    return s;
  }
}

String _nowIsoWithOffset() {
  final now = DateTime.now();
  final off = now.timeZoneOffset;
  final sign = off.isNegative ? '-' : '+';
  final abs = off.abs();
  String two(int n) => n.toString().padLeft(2, '0');
  final base = now.toIso8601String();
  return '$base$sign${two(abs.inHours)}:${two(abs.inMinutes % 60)}';
}
