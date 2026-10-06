import 'dart:convert';

import 'package:daily_duas/core/backup/backup_service.dart';
import 'package:daily_duas/core/db/app_database.dart';
import 'package:daily_duas/core/db/seed.dart';
import 'package:daily_duas/core/models/models.dart';
import 'package:daily_duas/core/repos/repositories.dart';
import 'package:daily_duas/core/util.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_db.dart';

const _secret = 'secret-gemini-key-123';
const _secret2 = 'secret-anthropic-key-456';

/// Seeds [db] and adds user data; returns the user routine id.
Future<int> _populate(AppDatabase db) async {
  await seedIfEmpty(db, loadAssetFromDisk);
  final duas = DuaRepository(db);
  final routines = RoutineRepository(db);
  final user = await duas.add(const Dua(
    title: 'My dua',
    arabic: 'رَبِّ زِدْنِي عِلْمًا',
    translation: 'My Lord, increase me in knowledge',
    category: 'General',
    defaultRepeat: 7,
  ));
  final kursi = (await duas.getByKey('ayat_al_kursi'))!;
  final r = await routines.add('Study');
  await routines.addDua(r.id!, user.id!);
  await routines.addDua(r.id!, kursi.id!, repeatOverride: 2);
  final rem = await ReminderRepository(db).add(Reminder(
      label: 'Study time',
      hour: 20,
      minute: 15,
      weekdays: const [2, 4],
      routineId: r.id));
  await SessionRepository(db).add(SessionLog(
    routineId: r.id,
    startedAt: isoWithOffset(DateTime(2026, 3, 1, 20, 15)),
    finishedAt: isoWithOffset(DateTime(2026, 3, 1, 20, 20)),
    completedDuaIds: [user.id!, kursi.id!],
    completed: true,
    fromAlarm: true,
    reminderId: rem.id,
  ));
  // Unfinished session: exported but not restored.
  await SessionRepository(db).add(SessionLog(
      routineId: r.id,
      startedAt: isoWithOffset(DateTime(2026, 3, 2, 8)),
      stateJson: '{}'));
  await TranslationRepository(db).put(user.id!, 'Urdu', 'اردو ترجمہ');
  final settings = SettingsRepository(db);
  await settings.save((await settings.load()).copyWith(
    geminiApiKey: _secret,
    anthropicApiKey: _secret2,
    arabicFontSize: 44,
    defaultRoutineId: r.id,
  ));
  return r.id!;
}

void main() {
  late AppDatabase src;
  late AppDatabase dst;

  setUp(() async {
    src = await openTestDb();
  });
  tearDown(() async {
    await src.close();
  });

  test('export contains everything except API keys', () async {
    await _populate(src);
    final json = await BackupService(src).exportJson();
    expect(json.contains(_secret), isFalse);
    expect(json.contains(_secret2), isFalse);
    final data = jsonDecode(json) as Map<String, dynamic>;
    expect(data['app'], 'daily_duas');
    expect(data['format'], 1);
    expect(data['exported_at'], isA<String>());
    expect(data['duas'], hasLength(7));
    expect(data['routines'], hasLength(3));
    expect(data['reminders'], hasLength(1));
    expect(data['session_logs'], hasLength(2));
    final settings = data['settings'] as Map<String, dynamic>;
    expect(settings.containsKey('geminiApiKey'), isFalse);
    expect(settings.containsKey('anthropicApiKey'), isFalse);
    expect(settings['arabicFontSize'], 44);
  });

  test('merge into the same database skips everything', () async {
    await _populate(src);
    final svc = BackupService(src);
    final report = await svc.import(await svc.export(), replace: false);
    expect(report.errors, isEmpty);
    expect(report.duasAdded, 0);
    expect(report.duasSkipped, 7);
    expect(report.routinesAdded, 0);
    expect(report.remindersAdded, 0);
    expect(report.logsAdded, 0);
    expect(await DuaRepository(src).list(), hasLength(7));
  });

  test('merge round trip into a fresh seeded database remaps ids', () async {
    final oldRoutineId = await _populate(src);
    final data = await BackupService(src).export();

    dst = await openTestDb();
    addTearDown(dst.close);
    await seedIfEmpty(dst, loadAssetFromDisk);
    // Shift ids so remapping is actually exercised.
    final filler = await DuaRepository(dst)
        .add(const Dua(title: 'Filler', arabic: 'سُبْحَانَ اللَّهِ'));
    await RoutineRepository(dst).add('Filler routine');
    final dstSettings = SettingsRepository(dst);
    await dstSettings
        .save((await dstSettings.load()).copyWith(geminiApiKey: 'dst-key'));

    final report = await BackupService(dst)
        .importJson(jsonEncode(data), replace: false);
    expect(report.errors, isEmpty);
    expect(report.duasAdded, 1);
    expect(report.duasSkipped, 6);
    expect(report.routinesAdded, 1, reason: 'Morning/Evil eye exist by name');
    expect(report.remindersAdded, 1);
    expect(report.logsAdded, 1, reason: 'unfinished session not restored');
    expect(report.summary, contains('1 dua'));

    final duas = DuaRepository(dst);
    expect(await duas.list(), hasLength(8));
    final myDua = (await duas.list(search: 'increase me')).single;
    expect(myDua.defaultRepeat, 7);
    expect(myDua.id, isNot(filler.id));
    expect(await TranslationRepository(dst).get(myDua.id!, 'Urdu'),
        'اردو ترجمہ');

    final study = (await RoutineRepository(dst).list())
        .firstWhere((r) => r.name == 'Study');
    final resolved = await RoutineRepository(dst).resolvedItems(study.id!);
    expect(resolved.map((e) => (e.$1.key, e.$2)).toList(),
        [(null, 7), ('ayat_al_kursi', 2)]);
    expect(resolved.first.$1.id, myDua.id);

    final rem = (await ReminderRepository(dst).list()).single;
    expect(rem.routineId, study.id);
    expect(rem.weekdays, [2, 4]);

    final log = (await SessionRepository(dst).completedLogs()).single;
    expect(log.routineId, study.id);
    expect(log.reminderId, rem.id);
    expect(log.completedDuaIds, [myDua.id, resolved[1].$1.id]);

    final s = await dstSettings.load();
    expect(s.geminiApiKey, 'dst-key', reason: 'keys never imported');
    expect(s.arabicFontSize, 30, reason: 'merge keeps current settings');
    expect(s.defaultRoutineId, isNotNull);
    expect(oldRoutineId, isPositive);

    // Importing the same backup again adds nothing.
    final again = await BackupService(dst).import(data, replace: false);
    expect(again.duasAdded + again.routinesAdded + again.remindersAdded,
        0);
    expect(again.logsAdded, 0);
  });

  test('replace wipes user tables and restores the backup', () async {
    await _populate(src);
    final data = await BackupService(src).export();

    dst = await openTestDb();
    addTearDown(dst.close);
    await seedIfEmpty(dst, loadAssetFromDisk);
    await DuaRepository(dst)
        .add(const Dua(title: 'Will vanish', arabic: 'لَا حَوْلَ'));
    await RoutineRepository(dst).add('Will vanish too');
    await ReminderRepository(dst)
        .add(const Reminder(label: 'gone', hour: 1, minute: 1));
    final dstSettings = SettingsRepository(dst);
    await dstSettings.save((await dstSettings.load())
        .copyWith(geminiApiKey: 'dst-key', onboardingDone: true));

    final report = await BackupService(dst).import(data, replace: true);
    expect(report.errors, isEmpty);
    expect(report.duasAdded, 7);
    expect(report.duasSkipped, 0);
    expect(report.routinesAdded, 3);
    expect(report.remindersAdded, 1);
    expect(report.logsAdded, 1);

    final duas = await DuaRepository(dst).list();
    expect(duas.map((d) => d.title), isNot(contains('Will vanish')));
    expect(duas.where((d) => d.isBuiltIn), hasLength(6));
    final routines = await RoutineRepository(dst).list();
    expect(routines.map((r) => r.name), ['Morning', 'Evil eye protection', 'Study']);
    expect(routines.first.items, hasLength(4));
    final reminders = await ReminderRepository(dst).list();
    expect(reminders.single.label, 'Study time');
    expect(reminders.single.routineId, routines.last.id);

    final s = await dstSettings.load();
    expect(s.arabicFontSize, 44, reason: 'replace restores settings');
    expect(s.geminiApiKey, 'dst-key');
    expect(s.onboardingDone, isTrue);
    expect(s.defaultRoutineId, routines.last.id);
  });

  test('invalid input is reported, not thrown', () async {
    final svc = BackupService(src);
    expect((await svc.importJson('{not json', replace: false)).errors,
        isNotEmpty);
    expect((await svc.import({'app': 'other'}, replace: true)).errors,
        isNotEmpty);
    expect(
        (await svc.import({'app': 'daily_duas', 'format': 99}, replace: true))
            .errors
            .single,
        contains('newer version'));

    await seedIfEmpty(src, loadAssetFromDisk);
    final report = await svc.import({
      'app': 'daily_duas',
      'format': 1,
      'duas': [
        'junk',
        {'id': 50, 'title': '', 'arabic': 'x'},
        {'id': 51, 'title': 'No arabic'},
        {'id': 52, 'title': 'Good', 'arabic': 'حَسْبِيَ اللَّهُ'},
      ],
      'routines': [
        {'name': ''},
        {
          'id': 9,
          'name': 'Imported',
          'items': [
            {'dua_id': 52, 'position': 1},
            {'dua_id': 999, 'position': 2},
          ],
        },
      ],
      'reminders': [
        {'label': 'bad', 'hour': 30, 'minute': 0},
        {'label': 'ok', 'hour': 6, 'minute': 0, 'routine_id': 9},
      ],
      'session_logs': [
        {'started_at': 'not a date', 'completed': true},
      ],
      'settings': 'nope',
    }, replace: false);
    expect(report.duasAdded, 1);
    expect(report.routinesAdded, 1);
    expect(report.remindersAdded, 1);
    expect(report.logsAdded, 0);
    expect(report.errors.length, 7, reason: report.errors.join('\n'));

    final imported = (await RoutineRepository(src).list())
        .firstWhere((r) => r.name == 'Imported');
    expect(imported.items, hasLength(1));
    final rem = (await ReminderRepository(src).list()).single;
    expect(rem.routineId, imported.id);
    // Built-ins untouched.
    expect(await DuaRepository(src).list(), hasLength(7));
  });
}
