import 'dart:convert';

import 'package:daily_duas/domain/arabic.dart';
import 'package:sqflite/sqflite.dart';

import '../config.dart';
import '../db/app_database.dart';
import '../models/models.dart';
import '../util.dart';

// ---------------------------------------------------------------------------
// Duas
// ---------------------------------------------------------------------------

class DuaRepository {
  DuaRepository(this._adb);
  final AppDatabase _adb;
  Database get _db => _adb.db;

  /// Ordered by sort_order, id. [search] matches title / translation /
  /// transliteration (case-insensitive) and Arabic (normalized).
  Future<List<Dua>> list({
    bool includeDeleted = false,
    String search = '',
    String? category,
  }) async {
    final where = <String>[];
    final args = <Object?>[];
    if (!includeDeleted) where.add('deleted_at IS NULL');
    if (category != null && category.isNotEmpty) {
      where.add('category = ?');
      args.add(category);
    }
    final rows = await _db.query(
      'duas',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'sort_order ASC, id ASC',
    );
    final duas = rows.map(Dua.fromMap).toList();
    final q = search.trim();
    if (q.isEmpty) return duas;
    final lower = q.toLowerCase();
    final normQ = normalizeArabic(q);
    return duas.where((d) {
      if (d.title.toLowerCase().contains(lower) ||
          d.translation.toLowerCase().contains(lower) ||
          d.transliteration.toLowerCase().contains(lower)) {
        return true;
      }
      return normQ.isNotEmpty && normalizeArabic(d.arabic).contains(normQ);
    }).toList();
  }

  /// Returns the dua even when soft-deleted.
  Future<Dua?> get(int id) async {
    final rows = await _db.query('duas', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Dua.fromMap(rows.first);
  }

  Future<Dua?> getByKey(String key) async {
    final rows = await _db.query('duas', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : Dua.fromMap(rows.first);
  }

  /// Inserts [d] (its id is ignored). Empty timestamps are filled; a
  /// sortOrder <= 0 places the dua at the end of the list.
  Future<Dua> add(Dua d) async {
    final now = nowIso();
    var sort = d.sortOrder;
    if (sort <= 0) sort = await _nextSort(_db, 'duas');
    final toInsert = d.copyWith(
      id: null,
      defaultRepeat: clampInt(d.defaultRepeat, minRepeat, maxRepeat),
      sortOrder: sort,
      createdAt: d.createdAt.isEmpty ? now : d.createdAt,
      updatedAt: d.updatedAt.isEmpty ? now : d.updatedAt,
    );
    final id = await _db.insert('duas', toInsert.toMap());
    return toInsert.copyWith(id: id);
  }

  /// Updates every column of [d] (requires id) and bumps updatedAt.
  Future<Dua> update(Dua d) async {
    final id = d.id;
    if (id == null) throw ArgumentError('Dua.id is required for update');
    final updated = d.copyWith(
      defaultRepeat: clampInt(d.defaultRepeat, minRepeat, maxRepeat),
      updatedAt: nowIso(),
    );
    final map = updated.toMap()..remove('id');
    await _db.update('duas', map, where: 'id = ?', whereArgs: [id]);
    return updated;
  }

  Future<void> softDelete(int id) async {
    final now = nowIso();
    await _db.update('duas', {'deleted_at': now, 'updated_at': now},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> restore(int id) async {
    await _db.update('duas', {'deleted_at': null, 'updated_at': nowIso()},
        where: 'id = ?', whereArgs: [id]);
  }

  /// Writes sort_order = position (1-based) for [orderedIds].
  Future<void> reorder(List<int> orderedIds) async {
    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (var i = 0; i < orderedIds.length; i++) {
        batch.update('duas', {'sort_order': i + 1},
            where: 'id = ?', whereArgs: [orderedIds[i]]);
      }
      await batch.commit(noResult: true);
    });
  }

  /// Distinct categories of non-deleted duas, in [categories] (config) order
  /// first, then any custom categories alphabetically.
  Future<List<String>> categories() async {
    final rows = await _db.rawQuery(
        'SELECT DISTINCT category FROM duas WHERE deleted_at IS NULL');
    final found = {
      for (final r in rows)
        if (asString(r['category']).trim().isNotEmpty) asString(r['category']),
    };
    return sortCategories(found);
  }

  /// First non-deleted dua whose normalized Arabic equals [arabic]'s.
  Future<Dua?> findDuplicate(String arabic) async {
    final target = normalizeArabic(arabic);
    if (target.isEmpty) return null;
    for (final d in await list()) {
      if (normalizeArabic(d.arabic) == target) return d;
    }
    return null;
  }

  Future<void> setVerification(
      int id, VerificationStatus s, String note) async {
    await _db.update(
      'duas',
      {
        'verification_status': s.name,
        'verification_note': note,
        'updated_at': nowIso(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}

/// Orders category names: config [categories] order first, then others A-Z.
List<String> sortCategories(Iterable<String> names) {
  final set = names.toSet();
  return [
    for (final c in categories)
      if (set.contains(c)) c,
    ...(set.where((c) => !categories.contains(c)).toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()))),
  ];
}

Future<int> _nextSort(DatabaseExecutor e, String table,
    {String column = 'sort_order', String? where, List<Object?>? args}) async {
  final rows = await e.rawQuery(
    'SELECT MAX($column) AS m FROM $table${where == null ? '' : ' WHERE $where'}',
    args,
  );
  return (asInt(rows.first['m']) ?? 0) + 1;
}

// ---------------------------------------------------------------------------
// Routines
// ---------------------------------------------------------------------------

class RoutineRepository {
  RoutineRepository(this._adb);
  final AppDatabase _adb;
  Database get _db => _adb.db;

  Future<List<Routine>> list() async {
    final rows = await _db.query('routines', orderBy: 'sort_order ASC, id ASC');
    final itemRows =
        await _db.query('routine_items', orderBy: 'position ASC, id ASC');
    final byRoutine = <int, List<RoutineItem>>{};
    for (final r in itemRows) {
      final item = RoutineItem.fromMap(r);
      (byRoutine[item.routineId] ??= []).add(item);
    }
    return [
      for (final r in rows)
        Routine.fromMap(r, items: byRoutine[asInt(r['id'])] ?? const []),
    ];
  }

  Future<Routine?> get(int id) async {
    final rows = await _db.query('routines', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Routine.fromMap(rows.first, items: await _items(id));
  }

  Future<List<RoutineItem>> _items(int routineId) async {
    final rows = await _db.query('routine_items',
        where: 'routine_id = ?',
        whereArgs: [routineId],
        orderBy: 'position ASC, id ASC');
    return rows.map(RoutineItem.fromMap).toList();
  }

  Future<Routine> add(String name) async {
    final sort = await _nextSort(_db, 'routines');
    final r = Routine(name: name.trim(), sortOrder: sort, createdAt: nowIso());
    final id = await _db.insert('routines', r.toMap());
    return r.copyWith(id: id);
  }

  Future<void> rename(int id, String name) async {
    await _db.update('routines', {'name': name.trim()},
        where: 'id = ?', whereArgs: [id]);
  }

  /// Deletes the routine and its items; reminders/logs keep a null routine.
  /// Clears settings.defaultRoutineId if it pointed here.
  Future<void> delete(int id) async {
    await _db.transaction((txn) async {
      await txn.delete('routine_items', where: 'routine_id = ?', whereArgs: [id]);
      await txn.delete('routines', where: 'id = ?', whereArgs: [id]);
      final s = await SettingsRepository.loadWith(txn);
      if (s.defaultRoutineId == id) {
        await SettingsRepository.saveWith(
            txn, s.copyWith(defaultRoutineId: null));
      }
    });
  }

  Future<void> addDua(int routineId, int duaId, {int? repeatOverride}) async {
    final pos = await _nextSort(_db, 'routine_items',
        column: 'position', where: 'routine_id = ?', args: [routineId]);
    await _db.insert(
      'routine_items',
      RoutineItem(
        routineId: routineId,
        duaId: duaId,
        position: pos,
        repeatOverride: repeatOverride == null
            ? null
            : clampInt(repeatOverride, minRepeat, maxRepeat),
      ).toMap(),
    );
  }

  Future<void> removeItem(int itemId) async {
    await _db.delete('routine_items', where: 'id = ?', whereArgs: [itemId]);
  }

  /// Writes position = index (1-based) for [orderedItemIds] of [routineId].
  Future<void> reorderItems(int routineId, List<int> orderedItemIds) async {
    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (var i = 0; i < orderedItemIds.length; i++) {
        batch.update('routine_items', {'position': i + 1},
            where: 'id = ? AND routine_id = ?',
            whereArgs: [orderedItemIds[i], routineId]);
      }
      await batch.commit(noResult: true);
    });
  }

  /// null resets to the dua's default repeat.
  Future<void> setRepeat(int itemId, int? repeatOverride) async {
    await _db.update(
      'routine_items',
      {
        'repeat_override': repeatOverride == null
            ? null
            : clampInt(repeatOverride, minRepeat, maxRepeat),
      },
      where: 'id = ?',
      whereArgs: [itemId],
    );
  }

  /// (dua, effective repeat) in routine order; skips soft-deleted duas.
  Future<List<(Dua, int)>> resolvedItems(int routineId) async {
    final rows = await _db.rawQuery('''
      SELECT d.*, ri.repeat_override AS _repeat_override
      FROM routine_items ri JOIN duas d ON d.id = ri.dua_id
      WHERE ri.routine_id = ? AND d.deleted_at IS NULL
      ORDER BY ri.position ASC, ri.id ASC''', [routineId]);
    final result = <(Dua, int)>[];
    for (final r in rows) {
      final d = Dua.fromMap(r);
      final repeat = asInt(r['_repeat_override']) ?? d.defaultRepeat;
      result.add((d, clampInt(repeat, minRepeat, maxRepeat)));
    }
    return result;
  }
}

// ---------------------------------------------------------------------------
// Reminders
// ---------------------------------------------------------------------------

class ReminderRepository {
  ReminderRepository(this._adb);
  final AppDatabase _adb;
  Database get _db => _adb.db;

  /// Ordered by time of day.
  Future<List<Reminder>> list() async {
    final rows =
        await _db.query('reminders', orderBy: 'hour ASC, minute ASC, id ASC');
    return rows.map(Reminder.fromMap).toList();
  }

  Future<Reminder?> get(int id) async {
    final rows = await _db.query('reminders', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Reminder.fromMap(rows.first);
  }

  Future<Reminder> add(Reminder r) async {
    final now = nowIso();
    final toInsert = r.copyWith(
      id: null,
      createdAt: r.createdAt.isEmpty ? now : r.createdAt,
      updatedAt: now,
    );
    final id = await _db.insert('reminders', toInsert.toMap());
    return toInsert.copyWith(id: id);
  }

  Future<Reminder> update(Reminder r) async {
    final id = r.id;
    if (id == null) throw ArgumentError('Reminder.id is required for update');
    final updated = r.copyWith(updatedAt: nowIso());
    await _db.update('reminders', updated.toMap()..remove('id'),
        where: 'id = ?', whereArgs: [id]);
    return updated;
  }

  Future<void> delete(int id) async {
    await _db.delete('reminders', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setEnabled(int id, bool enabled) async {
    await _db.update(
        'reminders', {'enabled': enabled ? 1 : 0, 'updated_at': nowIso()},
        where: 'id = ?', whereArgs: [id]);
  }
}

// ---------------------------------------------------------------------------
// Session logs
// ---------------------------------------------------------------------------

class SessionRepository {
  SessionRepository(this._adb);
  final AppDatabase _adb;
  Database get _db => _adb.db;

  Future<SessionLog> add(SessionLog l) async {
    final toInsert = l.copyWith(
        id: null, startedAt: l.startedAt.isEmpty ? nowIso() : l.startedAt);
    final id = await _db.insert('session_logs', toInsert.toMap());
    return toInsert.copyWith(id: id);
  }

  Future<void> update(SessionLog l) async {
    final id = l.id;
    if (id == null) throw ArgumentError('SessionLog.id is required for update');
    await _db.update('session_logs', l.toMap()..remove('id'),
        where: 'id = ?', whereArgs: [id]);
  }

  Future<SessionLog?> get(int id) async {
    final rows =
        await _db.query('session_logs', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : SessionLog.fromMap(rows.first);
  }

  /// Most recent session that is neither completed nor finished.
  Future<SessionLog?> unfinishedLatest() async {
    final rows = await _db.query('session_logs',
        where: 'completed = 0 AND finished_at IS NULL',
        orderBy: 'id DESC',
        limit: 1);
    return rows.isEmpty ? null : SessionLog.fromMap(rows.first);
  }

  /// Completed sessions, newest first.
  Future<List<SessionLog>> completedLogs() async {
    final rows =
        await _db.query('session_logs', where: 'completed = 1', orderBy: 'id DESC');
    final logs = rows.map(SessionLog.fromMap).toList();
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    logs.sort((a, b) => (parseIso(b.startedAt) ?? epoch)
        .compareTo(parseIso(a.startedAt) ?? epoch));
    return logs;
  }

  Future<void> delete(int id) async {
    await _db.delete('session_logs', where: 'id = ?', whereArgs: [id]);
  }
}

// ---------------------------------------------------------------------------
// Settings (one row per AppSettings field: key -> JSON value)
// ---------------------------------------------------------------------------

class SettingsRepository {
  SettingsRepository(this._adb);
  final AppDatabase _adb;

  Future<AppSettings> load() => loadWith(_adb.db);

  Future<void> save(AppSettings s) =>
      _adb.db.transaction((txn) => saveWith(txn, s));

  /// Loads settings through any executor (database or transaction).
  static Future<AppSettings> loadWith(DatabaseExecutor e) async {
    final rows = await e.query('settings');
    final map = <String, dynamic>{};
    for (final r in rows) {
      final k = asString(r['key']);
      final v = r['value'];
      if (v is! String) continue;
      try {
        map[k] = jsonDecode(v);
      } on FormatException {
        // Ignore a corrupt value; the default is used instead.
      }
    }
    return AppSettings.fromJson(map);
  }

  /// Saves settings through any executor (database or transaction).
  static Future<void> saveWith(DatabaseExecutor e, AppSettings s) async {
    final batch = e.batch();
    s.toJson().forEach((k, v) {
      batch.insert('settings', {'key': k, 'value': jsonEncode(v)},
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
    await batch.commit(noResult: true);
  }
}

// ---------------------------------------------------------------------------
// Translations (LLM translations cache)
// ---------------------------------------------------------------------------

class TranslationRepository {
  TranslationRepository(this._adb);
  final AppDatabase _adb;
  Database get _db => _adb.db;

  Future<String?> get(int duaId, String lang) async {
    final rows = await _db.query('translations',
        columns: ['text'],
        where: 'dua_id = ? AND lang = ?',
        whereArgs: [duaId, lang]);
    return rows.isEmpty ? null : asStringOrNull(rows.first['text']);
  }

  Future<void> put(int duaId, String lang, String text) async {
    await _db.insert(
        'translations', {'dua_id': duaId, 'lang': lang, 'text': text},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

// ---------------------------------------------------------------------------
// Alarm events (ingested from the native event log)
// ---------------------------------------------------------------------------

class AlarmEventRepository {
  AlarmEventRepository(this._adb);
  final AppDatabase _adb;
  Database get _db => _adb.db;

  /// Inserts events, ignoring duplicates (reminderId+occurrenceMs+event+atMs).
  Future<void> addAll(List<AlarmEvent> e) async {
    if (e.isEmpty) return;
    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (final ev in e) {
        batch.insert('alarm_events', ev.toMap()..remove('id'),
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await batch.commit(noResult: true);
    });
  }

  /// Events with at_ms >= [ms], oldest first.
  Future<List<AlarmEvent>> since(int ms) async {
    final rows = await _db.query('alarm_events',
        where: 'at_ms >= ?', whereArgs: [ms], orderBy: 'at_ms ASC, id ASC');
    return rows.map(AlarmEvent.fromMap).toList();
  }

  /// Latest stored at_ms, or 0 when empty.
  Future<int> lastAtMs() async {
    final rows = await _db.rawQuery('SELECT MAX(at_ms) AS m FROM alarm_events');
    return asInt(rows.first['m']) ?? 0;
  }
}

// ---------------------------------------------------------------------------
// Chat
// ---------------------------------------------------------------------------

class ChatRepository {
  ChatRepository(this._adb);
  final AppDatabase _adb;
  Database get _db => _adb.db;

  Future<ChatMessage> add(ChatMessage m) async {
    final toInsert = m.copyWith(
        id: null, createdAt: m.createdAt.isEmpty ? nowIso() : m.createdAt);
    final id = await _db.insert('chat_messages', toInsert.toMap());
    return toInsert.copyWith(id: id);
  }

  /// Latest [limit] messages in chronological order (oldest first).
  Future<List<ChatMessage>> list({int limit = 200}) async {
    final rows =
        await _db.query('chat_messages', orderBy: 'id DESC', limit: limit);
    return rows.map(ChatMessage.fromMap).toList().reversed.toList();
  }

  Future<void> clear() async {
    await _db.delete('chat_messages');
  }
}
