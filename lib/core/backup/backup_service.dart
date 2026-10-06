import 'dart:convert';

import 'package:daily_duas/domain/arabic.dart';
import 'package:sqflite/sqflite.dart';

import '../config.dart';
import '../db/app_database.dart';
import '../models/models.dart';
import '../repos/repositories.dart';
import '../util.dart';

/// Result of a backup import. Bad items are reported in [errors] and skipped.
class ImportReport {
  ImportReport({
    this.duasAdded = 0,
    this.duasSkipped = 0,
    this.routinesAdded = 0,
    this.remindersAdded = 0,
    this.logsAdded = 0,
    List<String>? errors,
  }) : errors = errors ?? <String>[];

  int duasAdded;
  int duasSkipped;
  int routinesAdded;
  int remindersAdded;
  int logsAdded;
  final List<String> errors;

  bool get hasErrors => errors.isNotEmpty;

  /// Nothing was written (e.g. invalid file or rolled-back import).
  bool get isEmpty =>
      duasAdded == 0 &&
      routinesAdded == 0 &&
      remindersAdded == 0 &&
      logsAdded == 0;

  /// Human readable one-line summary.
  String get summary {
    String n(int c, String one, String many) => '$c ${c == 1 ? one : many}';
    final parts = <String>[
      n(duasAdded, 'dua', 'duas'),
      n(routinesAdded, 'routine', 'routines'),
      n(remindersAdded, 'reminder', 'reminders'),
      n(logsAdded, 'session', 'sessions'),
    ];
    final skipped =
        duasSkipped > 0 ? ' ($duasSkipped duplicate duas skipped)' : '';
    final errs = errors.isEmpty
        ? ''
        : ' ${errors.length} ${errors.length == 1 ? 'problem' : 'problems'}.';
    return 'Imported ${parts.join(', ')}$skipped.$errs';
  }

  @override
  String toString() => summary;
}

/// Exports / imports all user data as JSON (API keys are never exported).
///
/// Format: `{"app":"daily_duas","format":1,"exported_at":..,"duas":[..],
/// "routines":[{..,"items":[..]}],"reminders":[..],"session_logs":[..],
/// "translations":[..],"settings":{..}}`.
class BackupService {
  BackupService(this._adb);
  final AppDatabase _adb;
  Database get _db => _adb.db;

  Future<Map<String, dynamic>> export() async {
    final duaRows = await _db.query('duas', orderBy: 'sort_order ASC, id ASC');
    final duas = duaRows.map(Dua.fromMap).toList();
    final keyById = {
      for (final d in duas)
        if (d.key != null) d.id!: d.key!,
    };
    final routines = await RoutineRepository(_adb).list();
    final reminders = await ReminderRepository(_adb).list();
    final logRows = await _db.query('session_logs', orderBy: 'id ASC');
    final translations = await _db.query('translations');
    final settings = await SettingsRepository(_adb).load();

    return {
      'app': backupAppId,
      'format': backupFormat,
      'app_version': appVersion,
      'exported_at': nowIso(),
      'duas': [for (final d in duas) d.toJson()],
      'routines': [
        for (final r in routines)
          {
            ...r.toJson(),
            'items': [
              for (final i in r.items)
                {
                  ...i.toJson(),
                  if (keyById[i.duaId] != null) 'dua_key': keyById[i.duaId],
                },
            ],
          },
      ],
      'reminders': [for (final r in reminders) r.toJson()],
      'session_logs': [
        for (final row in logRows) SessionLog.fromMap(row).toJson(),
      ],
      'translations': [
        for (final t in translations)
          {'dua_id': t['dua_id'], 'lang': t['lang'], 'text': t['text']},
      ],
      'settings': settings.toJson()
        ..removeWhere((k, _) => AppSettings.secretKeys.contains(k)),
    };
  }

  Future<String> exportJson() async =>
      const JsonEncoder.withIndent('  ').convert(await export());

  /// Parses [text] and imports it; invalid JSON is reported, never thrown.
  Future<ImportReport> importJson(String text, {required bool replace}) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return ImportReport(errors: ['This file is not valid JSON.']);
    }
    final map = jsonMap(decoded);
    if (map == null) {
      return ImportReport(errors: ['This file is not a Daily Duas backup.']);
    }
    return import(map, replace: replace);
  }

  /// Imports a backup. [replace] wipes duas, routines, reminders, session logs
  /// and translations first (in the same transaction). Merge mode skips
  /// duplicate duas (same key or normalized Arabic), routines with the same
  /// name and logs with the same startedAt; ids are remapped.
  /// API keys in the current settings are always kept.
  Future<ImportReport> import(Map<String, dynamic> data,
      {required bool replace}) async {
    final report = ImportReport();
    if (data['app'] != backupAppId) {
      report.errors.add('This file is not a Daily Duas backup.');
      return report;
    }
    final format = asInt(data['format']);
    if (format == null || format < 1) {
      report.errors.add('The backup format is missing or invalid.');
      return report;
    }
    if (format > backupFormat) {
      report.errors.add(
          'This backup was made by a newer version of the app. Please update the app first.');
      return report;
    }

    final duas = _list(data, 'duas', report);
    final routines = _list(data, 'routines', report);
    final reminders = _list(data, 'reminders', report);
    final logs = _list(data, 'session_logs', report);
    final translations = _list(data, 'translations', report);
    final settingsJson = jsonMap(data['settings']);

    try {
      await _db.transaction((txn) async {
        if (replace) {
          for (final t in AppDatabase.userTables) {
            await txn.delete(t);
          }
        }
        final now = nowIso();
        final duaIdMap = await _importDuas(txn, duas, report, replace, now);
        await _importTranslations(txn, translations, duaIdMap.byOldId, replace);
        final routineIdMap = await _importRoutines(
            txn, routines, duaIdMap, report, replace, now);
        final reminderIdMap =
            await _importReminders(txn, reminders, routineIdMap, report, now);
        await _importLogs(
            txn, logs, duaIdMap.byOldId, routineIdMap, reminderIdMap, report);
        await _importSettings(txn, settingsJson, routineIdMap, replace);
      });
    } catch (e) {
      return ImportReport(errors: [
        ...report.errors,
        'Import failed and nothing was changed: $e',
      ]);
    }
    return report;
  }

  // -------------------------------------------------------------------------

  List<Object?> _list(
      Map<String, dynamic> data, String key, ImportReport report) {
    final v = data[key];
    if (v == null) return const [];
    if (v is List) return v;
    report.errors.add('"$key" is not a list and was ignored.');
    return const [];
  }

  Future<_DuaIds> _importDuas(Transaction txn, List<Object?> items,
      ImportReport report, bool replace, String now) async {
    final ids = _DuaIds();
    final byNorm = <String, int>{};
    for (final row in await txn
        .query('duas', columns: ['id', 'key', 'arabic', 'deleted_at'])) {
      final id = asInt(row['id'])!;
      // Keys match even soft-deleted duas (the key column is UNIQUE).
      final key = asStringOrNull(row['key']);
      if (key != null) ids.byKey[key] = id;
      if (row['deleted_at'] != null) continue;
      final norm = normalizeArabic(asString(row['arabic']));
      if (norm.isNotEmpty) byNorm.putIfAbsent(norm, () => id);
    }
    var sort = await _maxSort(txn, 'duas');

    for (var i = 0; i < items.length; i++) {
      final m = jsonMap(items[i]);
      if (m == null) {
        report.errors.add('Dua ${i + 1}: not a valid entry.');
        continue;
      }
      final Dua d;
      try {
        d = Dua.fromJson(m);
      } on FormatException catch (e) {
        final title = asString(m['title']).trim();
        report.errors.add(
            'Dua ${i + 1}${title.isEmpty ? '' : ' "$title"'}: ${e.message}.');
        continue;
      }
      final oldId = d.id;
      final norm = normalizeArabic(d.arabic);
      final existing = (d.key != null ? ids.byKey[d.key] : null) ??
          (norm.isEmpty ? null : byNorm[norm]);
      if (existing != null) {
        if (oldId != null) ids.byOldId[oldId] = existing;
        report.duasSkipped++;
        continue;
      }
      final key = d.key;
      final toInsert = d.copyWith(
        id: null,
        sortOrder: replace && d.sortOrder > 0 ? d.sortOrder : ++sort,
        createdAt: d.createdAt.isEmpty ? now : d.createdAt,
        updatedAt: d.updatedAt.isEmpty ? now : d.updatedAt,
      );
      final newId = await txn.insert('duas', toInsert.toMap());
      if (replace && toInsert.sortOrder > sort) sort = toInsert.sortOrder;
      if (oldId != null) ids.byOldId[oldId] = newId;
      if (key != null) ids.byKey[key] = newId;
      if (norm.isNotEmpty && toInsert.deletedAt == null) {
        byNorm.putIfAbsent(norm, () => newId);
      }
      report.duasAdded++;
    }
    return ids;
  }

  Future<void> _importTranslations(Transaction txn, List<Object?> items,
      Map<int, int> duaIdMap, bool replace) async {
    for (final raw in items) {
      final m = jsonMap(raw);
      if (m == null) continue;
      final duaId = duaIdMap[asInt(m['dua_id'])];
      final lang = asString(m['lang']).trim();
      final text = asString(m['text']);
      if (duaId == null || lang.isEmpty || text.isEmpty) continue;
      await txn.insert(
          'translations', {'dua_id': duaId, 'lang': lang, 'text': text},
          conflictAlgorithm:
              replace ? ConflictAlgorithm.replace : ConflictAlgorithm.ignore);
    }
  }

  Future<Map<int, int>> _importRoutines(Transaction txn, List<Object?> items,
      _DuaIds duaIds, ImportReport report, bool replace, String now) async {
    final map = <int, int>{};
    final byName = <String, int>{};
    final takenKeys = <String>{};
    for (final row in await txn.query('routines', columns: ['id', 'name', 'key'])) {
      byName.putIfAbsent(
          asString(row['name']).trim().toLowerCase(), () => asInt(row['id'])!);
      final key = asStringOrNull(row['key']);
      if (key != null) takenKeys.add(key);
    }
    var sort = await _maxSort(txn, 'routines');

    for (var i = 0; i < items.length; i++) {
      final m = jsonMap(items[i]);
      if (m == null) {
        report.errors.add('Routine ${i + 1}: not a valid entry.');
        continue;
      }
      final Routine r;
      try {
        r = Routine.fromJson(m);
      } on FormatException catch (e) {
        report.errors.add('Routine ${i + 1}: ${e.message}.');
        continue;
      }
      final oldId = r.id;
      final existing = byName[r.name.toLowerCase()];
      if (existing != null) {
        if (oldId != null) map[oldId] = existing;
        continue;
      }
      final key = (r.key != null && takenKeys.contains(r.key)) ? null : r.key;
      final routineId = await txn.insert(
        'routines',
        r
            .copyWith(
              id: null,
              key: key,
              sortOrder: replace && r.sortOrder > 0 ? r.sortOrder : ++sort,
              createdAt: r.createdAt.isEmpty ? now : r.createdAt,
            )
            .toMap(),
      );
      if (replace && r.sortOrder > sort) sort = r.sortOrder;
      if (oldId != null) map[oldId] = routineId;
      if (key != null) takenKeys.add(key);
      byName[r.name.toLowerCase()] = routineId;
      report.routinesAdded++;

      // Items: resolve dua by remapped id, falling back to dua_key.
      final rawItems = m['items'] is List ? m['items'] as List : const [];
      final parsed = <(int position, int duaId, int? repeat)>[];
      for (var j = 0; j < rawItems.length; j++) {
        final im = jsonMap(rawItems[j]);
        if (im == null) {
          report.errors.add('Routine "${r.name}": item ${j + 1} is invalid.');
          continue;
        }
        final duaKey = asStringOrNull(im['dua_key']);
        final duaId = duaIds.byOldId[asInt(im['dua_id'])] ??
            (duaKey == null ? null : duaIds.byKey[duaKey]);
        if (duaId == null) {
          report.errors.add(
              'Routine "${r.name}": item ${j + 1} refers to a dua that is not in the backup.');
          continue;
        }
        final repeat = asInt(im['repeat_override']);
        parsed.add((
          asInt(im['position']) ?? j + 1,
          duaId,
          repeat == null ? null : clampInt(repeat, minRepeat, maxRepeat),
        ));
      }
      parsed.sort((a, b) => a.$1.compareTo(b.$1));
      for (var k = 0; k < parsed.length; k++) {
        await txn.insert(
          'routine_items',
          RoutineItem(
            routineId: routineId,
            duaId: parsed[k].$2,
            position: k + 1,
            repeatOverride: parsed[k].$3,
          ).toMap(),
        );
      }
    }
    return map;
  }

  Future<Map<int, int>> _importReminders(Transaction txn, List<Object?> items,
      Map<int, int> routineIdMap, ImportReport report, String now) async {
    String sig(Reminder r) =>
        '${r.label.trim().toLowerCase()}|${r.hour}|${r.minute}|${r.weekdays.join(',')}|${r.routineId}';
    final existing = <String, int>{
      for (final row in await txn.query('reminders'))
        sig(Reminder.fromMap(row)): asInt(row['id'])!,
    };
    final map = <int, int>{};
    for (var i = 0; i < items.length; i++) {
      final m = jsonMap(items[i]);
      if (m == null) {
        report.errors.add('Reminder ${i + 1}: not a valid entry.');
        continue;
      }
      final Reminder parsed;
      try {
        parsed = Reminder.fromJson(m);
      } on FormatException catch (e) {
        report.errors.add('Reminder ${i + 1}: ${e.message}.');
        continue;
      }
      final oldId = parsed.id;
      final r = parsed.copyWith(
        id: null,
        routineId:
            parsed.routineId == null ? null : routineIdMap[parsed.routineId],
        createdAt: parsed.createdAt.isEmpty ? now : parsed.createdAt,
        updatedAt: now,
      );
      final dup = existing[sig(r)];
      if (dup != null) {
        if (oldId != null) map[oldId] = dup;
        continue;
      }
      final newId = await txn.insert('reminders', r.toMap());
      existing[sig(r)] = newId;
      if (oldId != null) map[oldId] = newId;
      report.remindersAdded++;
    }
    return map;
  }

  Future<void> _importLogs(
    Transaction txn,
    List<Object?> items,
    Map<int, int> duaIdMap,
    Map<int, int> routineIdMap,
    Map<int, int> reminderIdMap,
    ImportReport report,
  ) async {
    final started = {
      for (final row in await txn.query('session_logs', columns: ['started_at']))
        asString(row['started_at']),
    };
    List<int> remap(List<int> ids) => [
          for (final id in ids)
            if (duaIdMap[id] != null) duaIdMap[id]!,
        ];

    for (var i = 0; i < items.length; i++) {
      final m = jsonMap(items[i]);
      if (m == null) {
        report.errors.add('Session ${i + 1}: not a valid entry.');
        continue;
      }
      final SessionLog l;
      try {
        l = SessionLog.fromJson(m);
      } on FormatException catch (e) {
        report.errors.add('Session ${i + 1}: ${e.message}.');
        continue;
      }
      // In-progress sessions hold device-specific state; not restored.
      if (!l.completed && l.finishedAt == null) continue;
      if (started.contains(l.startedAt)) continue;
      final log = l.copyWith(
        id: null,
        routineId: l.routineId == null ? null : routineIdMap[l.routineId],
        reminderId: l.reminderId == null ? null : reminderIdMap[l.reminderId],
        completedDuaIds: remap(l.completedDuaIds),
        skippedDuaIds: remap(l.skippedDuaIds),
        stateJson: null,
      );
      await txn.insert('session_logs', log.toMap());
      started.add(l.startedAt);
      report.logsAdded++;
    }
  }

  Future<void> _importSettings(Transaction txn, Map<String, dynamic>? json,
      Map<int, int> routineIdMap, bool replace) async {
    final current = await SettingsRepository.loadWith(txn);
    var next = current;
    final oldDefault = asInt(json?['defaultRoutineId']);
    final mappedDefault = oldDefault == null ? null : routineIdMap[oldDefault];

    if (replace && json != null) {
      final merged = <String, dynamic>{
        ...current.toJson(),
        ...json,
        // Keys and device-local state always come from this device.
        'geminiApiKey': current.geminiApiKey,
        'anthropicApiKey': current.anthropicApiKey,
        'onboardingDone': current.onboardingDone,
        'defaultRoutineId': mappedDefault,
      };
      next = AppSettings.fromJson(merged);
    } else if (mappedDefault != null) {
      final cur = current.defaultRoutineId;
      final exists = cur != null &&
          (await txn.query('routines', where: 'id = ?', whereArgs: [cur]))
              .isNotEmpty;
      if (!exists) next = current.copyWith(defaultRoutineId: mappedDefault);
    }

    // Never leave the default routine pointing at a deleted routine.
    final def = next.defaultRoutineId;
    if (def != null &&
        (await txn.query('routines', where: 'id = ?', whereArgs: [def]))
            .isEmpty) {
      next = next.copyWith(defaultRoutineId: null);
    }
    if (next != current) await SettingsRepository.saveWith(txn, next);
  }

  Future<int> _maxSort(DatabaseExecutor e, String table) async {
    final rows = await e.rawQuery('SELECT MAX(sort_order) AS m FROM $table');
    return asInt(rows.first['m']) ?? 0;
  }
}

class _DuaIds {
  final byOldId = <int, int>{};
  final byKey = <String, int>{};
}
