import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../config.dart';
import '../models/models.dart';
import '../repos/repositories.dart';
import '../util.dart';
import 'app_database.dart';

const seedDuasAsset = 'assets/data/seed_duas.json';
const seedRoutinesAsset = 'assets/data/seed_routines.json';

/// Key of the routine used as the default (settings.defaultRoutineId).
const defaultRoutineKey = 'morning';

/// Key of the dua shown on the finish screen.
const acceptanceDuaKey = 'acceptance';

/// Inserts the built-in duas and routines from the bundled JSON assets when no
/// built-in dua exists yet, then points settings.defaultRoutineId at the
/// 'morning' routine (if unset). Idempotent; runs in one transaction.
///
/// [loadAsset] is `rootBundle.loadString` in the app, or a file reader in tests.
Future<void> seedIfEmpty(
  AppDatabase db,
  Future<String> Function(String assetPath) loadAsset,
) async {
  final existing = await db.db
      .rawQuery('SELECT COUNT(*) AS c FROM duas WHERE is_built_in = 1');
  if ((asInt(existing.first['c']) ?? 0) > 0) return;

  final duaJson = jsonDecode(await loadAsset(seedDuasAsset));
  final routineJson = jsonDecode(await loadAsset(seedRoutinesAsset));
  if (duaJson is! List) {
    throw const FormatException('seed_duas.json must be a JSON list');
  }
  final routineList = routineJson is List ? routineJson : const [];

  await db.db.transaction((txn) async {
    // Re-check inside the transaction (guards concurrent callers).
    final again = await txn
        .rawQuery('SELECT COUNT(*) AS c FROM duas WHERE is_built_in = 1');
    if ((asInt(again.first['c']) ?? 0) > 0) return;

    final now = nowIso();
    final idByKey = <String, int>{};
    final repeatByKey = <String, int>{};
    var sort = await _maxSort(txn, 'duas');

    for (final raw in duaJson) {
      final m = jsonMap(raw);
      if (m == null) continue;
      final dua = seedDuaFromJson(m, sortOrder: ++sort, now: now);
      if (dua == null) continue;
      final key = dua.key!;
      // A user dua may already own this key (e.g. restored backup): reuse it.
      final clash =
          await txn.query('duas', where: 'key = ?', whereArgs: [key], limit: 1);
      final int id;
      if (clash.isNotEmpty) {
        id = asInt(clash.first['id'])!;
      } else {
        id = await txn.insert('duas', dua.toMap());
      }
      idByKey[key] = id;
      repeatByKey[key] = dua.defaultRepeat;
    }

    var routineSort = await _maxSort(txn, 'routines');
    int? defaultRoutineId;
    for (final raw in routineList) {
      final m = jsonMap(raw);
      if (m == null) continue;
      final key = asStringOrNull(m['key']);
      final name = asString(m['name']).trim();
      if (name.isEmpty) continue;
      if (key != null) {
        final clash = await txn.query('routines',
            where: 'key = ?', whereArgs: [key], limit: 1);
        if (clash.isNotEmpty) {
          if (key == defaultRoutineKey) {
            defaultRoutineId = asInt(clash.first['id']);
          }
          continue;
        }
      }
      final routineId = await txn.insert(
        'routines',
        Routine(key: key, name: name, sortOrder: ++routineSort, createdAt: now)
            .toMap(),
      );
      if (key == defaultRoutineKey) defaultRoutineId = routineId;

      final items = m['items'];
      if (items is! List) continue;
      var position = 0;
      for (final rawItem in items) {
        final im = jsonMap(rawItem);
        if (im == null) continue;
        final duaKey = asStringOrNull(im['dua_key']);
        final duaId = duaKey == null ? null : idByKey[duaKey];
        if (duaId == null) continue;
        final repeat = asInt(im['repeat']);
        final override = (repeat == null || repeat == repeatByKey[duaKey])
            ? null
            : clampInt(repeat, minRepeat, maxRepeat);
        await txn.insert(
          'routine_items',
          RoutineItem(
            routineId: routineId,
            duaId: duaId,
            position: ++position,
            repeatOverride: override,
          ).toMap(),
        );
      }
    }

    if (defaultRoutineId != null) {
      final s = await SettingsRepository.loadWith(txn);
      if (s.defaultRoutineId == null) {
        await SettingsRepository.saveWith(
            txn, s.copyWith(defaultRoutineId: defaultRoutineId));
      }
    }
  });
}

/// Converts one seed_duas.json entry into a built-in [Dua]; null if invalid.
/// Fields: key,title,arabic,ayahs,transliteration,translation,source,category,
/// default_repeat,quran{surah,ayah_start,ayah_end}|null,verification_status,notes.
Dua? seedDuaFromJson(Map<String, dynamic> m,
    {int sortOrder = 0, String? now}) {
  final key = asStringOrNull(m['key'])?.trim();
  final title = asString(m['title']).trim();
  final arabic = asString(m['arabic']).trim();
  if (key == null || key.isEmpty || title.isEmpty || arabic.isEmpty) {
    return null;
  }
  final quran = jsonMap(m['quran']);
  final surah = asInt(quran?['surah']);
  final start = asInt(quran?['ayah_start']);
  final end = asInt(quran?['ayah_end']) ?? start;
  final isQuran = surah != null && start != null;
  final status = asString(m['verification_status']) == 'verified'
      ? VerificationStatus.verified
      : VerificationStatus.unverified;
  final ts = now ?? nowIso();
  final category = asString(m['category']).trim();
  return Dua(
    key: key,
    title: title,
    arabic: arabic,
    transliteration: asString(m['transliteration']),
    translation: asString(m['translation']),
    source: asString(m['source']),
    category: category.isEmpty ? 'General' : category,
    defaultRepeat:
        clampInt(asInt(m['default_repeat']) ?? 1, minRepeat, maxRepeat),
    audioKind: isQuran ? AudioKind.quran : AudioKind.none,
    quranSurah: isQuran ? surah : null,
    quranAyahStart: isQuran ? start : null,
    quranAyahEnd: isQuran ? end : null,
    ayahs: jsonStringList(m['ayahs']),
    isBuiltIn: true,
    verificationStatus: status,
    verificationNote: asString(m['notes']),
    sortOrder: sortOrder,
    createdAt: ts,
    updatedAt: ts,
  );
}

Future<int> _maxSort(DatabaseExecutor e, String table) async {
  final rows = await e.rawQuery('SELECT MAX(sort_order) AS m FROM $table');
  return asInt(rows.first['m']) ?? 0;
}
