import 'package:daily_duas/core/config.dart';
import 'package:daily_duas/core/db/app_database.dart';
import 'package:daily_duas/core/models/models.dart';
import 'package:daily_duas/core/repos/repositories.dart';
import 'package:daily_duas/core/util.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';

import 'test_db.dart';

Dua _dua(
  String title, {
  String arabic = 'بِسْمِ اللَّهِ',
  String category = 'General',
  int repeat = 1,
  String translation = '',
  String transliteration = '',
}) =>
    Dua(
      title: title,
      arabic: arabic,
      category: category,
      defaultRepeat: repeat,
      translation: translation,
      transliteration: transliteration,
    );

void main() {
  late AppDatabase db;
  late DuaRepository duas;
  late RoutineRepository routines;

  setUp(() async {
    db = await openTestDb();
    duas = DuaRepository(db);
    routines = RoutineRepository(db);
  });
  tearDown(() => db.close());

  group('util', () {
    test('nowIso includes a UTC offset and parses back', () {
      final s = nowIso();
      expect(RegExp(r'[+-]\d\d:\d\d$').hasMatch(s), isTrue, reason: s);
      final parsed = parseIso(s)!;
      expect(DateTime.now().difference(parsed).inSeconds.abs() < 5, isTrue);
      expect(parseIso('nope'), isNull);
      expect(jsonIntList('[1,"2",3.0,"x"]'), [1, 2, 3]);
      expect(jsonStringList(null), isNull);
    });
  });

  group('DuaRepository', () {
    test('CRUD, ordering and timestamps', () async {
      final a = await duas.add(_dua('Alpha', repeat: 3));
      final b = await duas.add(_dua('Beta', repeat: 500));
      expect(a.id, isNotNull);
      expect(a.createdAt, isNotEmpty);
      expect(b.sortOrder, greaterThan(a.sortOrder));
      expect(b.defaultRepeat, 100, reason: 'clamped to 1..100');

      final got = (await duas.get(a.id!))!;
      expect(got.title, 'Alpha');
      expect(got.defaultRepeat, 3);

      final upd = await duas.update(got.copyWith(
        title: 'Alpha 2',
        ayahs: ['x', 'y'],
        audioKind: AudioKind.file,
        audioPath: '/a.mp3',
      ));
      final again = (await duas.get(a.id!))!;
      expect(again.title, 'Alpha 2');
      expect(again.ayahs, ['x', 'y']);
      expect(again.audioKind, AudioKind.file);
      expect(again.audioPath, '/a.mp3');
      expect(upd.updatedAt, isNotEmpty);

      final cleared = await duas.update(again.copyWith(audioPath: null));
      expect(cleared.audioPath, isNull);
      expect((await duas.get(a.id!))!.audioPath, isNull);

      expect((await duas.list()).map((d) => d.title), ['Alpha 2', 'Beta']);
    });

    test('soft delete and restore', () async {
      final a = await duas.add(_dua('A'));
      await duas.add(_dua('B'));
      await duas.softDelete(a.id!);
      expect((await duas.list()).map((d) => d.title), ['B']);
      final all = await duas.list(includeDeleted: true);
      expect(all, hasLength(2));
      expect(all.first.deletedAt, isNotNull);
      expect((await duas.get(a.id!))!.isDeleted, isTrue);
      await duas.restore(a.id!);
      expect((await duas.list()).map((d) => d.title), ['A', 'B']);
    });

    test('reorder writes sort_order', () async {
      final a = await duas.add(_dua('A'));
      final b = await duas.add(_dua('B'));
      final c = await duas.add(_dua('C'));
      await duas.reorder([c.id!, a.id!, b.id!]);
      expect((await duas.list()).map((d) => d.title), ['C', 'A', 'B']);
    });

    test('search, category filter, categories and duplicates', () async {
      await duas.add(_dua(
        'Surah Al-Ikhlas',
        arabic: 'قُلْ هُوَ اللَّهُ أَحَدٌ',
        category: 'Protection',
        translation: 'Say: He is Allah, the One',
        transliteration: 'Qul huwa Allahu ahad',
      ));
      await duas.add(_dua(
        'Morning praise',
        arabic: 'أَصْبَحْنَا وَأَصْبَحَ الْمُلْكُ لِلَّهِ',
        category: 'Morning',
      ));
      await duas.add(_dua('Custom one', category: 'Zeta custom'));
      final deleted = await duas.add(_dua('Deleted', category: 'Sleep'));
      await duas.softDelete(deleted.id!);

      expect(
          (await duas.list(search: 'ikhlas')).single.title, 'Surah Al-Ikhlas');
      expect(
          (await duas.list(search: 'THE ONE')).single.title, 'Surah Al-Ikhlas');
      expect((await duas.list(search: 'QUL HUWA')).single.title,
          'Surah Al-Ikhlas');
      // Arabic search ignores diacritics / hamza forms.
      expect((await duas.list(search: 'هو الله احد')).single.title,
          'Surah Al-Ikhlas');
      expect(await duas.list(search: 'nothing-matches'), isEmpty);
      expect((await duas.list(category: 'Morning')).single.title,
          'Morning praise');

      expect(await duas.categories(), ['Protection', 'Morning', 'Zeta custom']);

      final dup = await duas.findDuplicate('قل هو الله احد');
      expect(dup?.title, 'Surah Al-Ikhlas');
      expect(await duas.findDuplicate('سبحان الله'), isNull);
      expect(await duas.findDuplicate(''), isNull);
    });

    test('getByKey and setVerification', () async {
      final d = await duas.add(_dua('Keyed').copyWith(key: 'k1'));
      expect((await duas.getByKey('k1'))!.id, d.id);
      expect(await duas.getByKey('missing'), isNull);
      await duas.setVerification(
          d.id!, VerificationStatus.verified, 'Matches Quran 1:1');
      final v = (await duas.get(d.id!))!;
      expect(v.verificationStatus, VerificationStatus.verified);
      expect(v.verificationNote, 'Matches Quran 1:1');
    });
  });

  group('RoutineRepository', () {
    test('items, overrides, reorder and resolvedItems', () async {
      final a = await duas.add(_dua('A', repeat: 3));
      final b = await duas.add(_dua('B', repeat: 7));
      final c = await duas.add(_dua('C', repeat: 1));
      final r = await routines.add('  Evening  ');
      expect(r.name, 'Evening');

      await routines.addDua(r.id!, a.id!);
      await routines.addDua(r.id!, b.id!, repeatOverride: 33);
      await routines.addDua(r.id!, c.id!);

      var resolved = await routines.resolvedItems(r.id!);
      expect(resolved.map((e) => (e.$1.title, e.$2)).toList(),
          [('A', 3), ('B', 33), ('C', 1)]);

      final loaded = (await routines.get(r.id!))!;
      expect(loaded.items, hasLength(3));
      final ids = loaded.items.map((i) => i.id!).toList();
      await routines.reorderItems(r.id!, [ids[2], ids[0], ids[1]]);
      await routines.setRepeat(ids[1], null);
      await routines.setRepeat(ids[0], 5);
      resolved = await routines.resolvedItems(r.id!);
      expect(resolved.map((e) => (e.$1.title, e.$2)).toList(),
          [('C', 1), ('A', 5), ('B', 7)]);

      // Soft-deleted duas are skipped; restored ones come back.
      await duas.softDelete(a.id!);
      resolved = await routines.resolvedItems(r.id!);
      expect(resolved.map((e) => e.$1.title), ['C', 'B']);
      await duas.restore(a.id!);
      expect(await routines.resolvedItems(r.id!), hasLength(3));

      await routines.removeItem(ids[2]);
      expect((await routines.get(r.id!))!.items, hasLength(2));
    });

    test('list, rename, delete clears references', () async {
      final r1 = await routines.add('One');
      final r2 = await routines.add('Two');
      final d = await duas.add(_dua('A'));
      await routines.addDua(r1.id!, d.id!);
      await routines.rename(r2.id!, 'Second');
      final list = await routines.list();
      expect(list.map((r) => r.name), ['One', 'Second']);
      expect(list.first.items.single.duaId, d.id);

      final settings = SettingsRepository(db);
      await settings
          .save(const AppSettings().copyWith(defaultRoutineId: r1.id));
      final reminders = ReminderRepository(db);
      final rem = await reminders
          .add(Reminder(label: 'x', hour: 6, minute: 0, routineId: r1.id));

      await routines.delete(r1.id!);
      expect(await routines.get(r1.id!), isNull);
      expect((await settings.load()).defaultRoutineId, isNull);
      expect((await reminders.get(rem.id!))!.routineId, isNull);
      expect(await db.db.query('routine_items'), isEmpty);
    });
  });

  group('ReminderRepository', () {
    test('CRUD, ordering, enable and native json', () async {
      final repo = ReminderRepository(db);
      final r = await routines.add('Morning');
      final late =
          await repo.add(const Reminder(label: 'Late', hour: 21, minute: 5));
      final early = await repo.add(Reminder(
        label: 'Fajr',
        hour: 5,
        minute: 30,
        weekdays: const [1, 3, 5],
        routineId: r.id,
        nagEnabled: false,
      ));
      expect((await repo.list()).map((x) => x.label), ['Fajr', 'Late']);
      expect(early.timeLabel, '05:30');
      expect(late.timeLabel, '21:05');

      final loaded = (await repo.get(early.id!))!;
      expect(loaded.weekdays, [1, 3, 5]);
      expect(loaded.nagEnabled, isFalse);
      expect(loaded.snoozeMinutes, 5);

      await repo.update(loaded.copyWith(hour: 6, routineId: null));
      final upd = (await repo.get(early.id!))!;
      expect(upd.hour, 6);
      expect(upd.routineId, isNull);

      await repo.setEnabled(early.id!, false);
      expect((await repo.get(early.id!))!.enabled, isFalse);

      final native = upd.toNativeJson(routineName: 'Morning');
      expect(native.keys.toSet(), {
        'id',
        'label',
        'hour',
        'minute',
        'weekdays',
        'enabled',
        'routine_id',
        'routine_name',
        'snooze_minutes',
        'max_snoozes',
        'nag_enabled',
        'nag_every_minutes',
        'nag_max_times',
        'ring_seconds',
        'vibrate',
        'sound',
      });
      expect(native['weekdays'], [1, 3, 5]);
      expect(native['routine_name'], 'Morning');
      expect(native['enabled'], isTrue);
      expect(native['ring_seconds'], 120);

      await repo.delete(late.id!);
      expect(await repo.list(), hasLength(1));
    });
  });

  group('SessionRepository', () {
    test('unfinished, completed and delete', () async {
      final repo = SessionRepository(db);
      final s1 = await repo.add(SessionLog(
        startedAt: isoWithOffset(DateTime(2026, 1, 1, 7)),
        finishedAt: isoWithOffset(DateTime(2026, 1, 1, 7, 10)),
        completedDuaIds: const [1, 2],
        completed: true,
      ));
      final s2 = await repo.add(SessionLog(
        startedAt: isoWithOffset(DateTime(2026, 1, 2, 7)),
        stateJson: '{"index":1}',
      ));
      expect((await repo.unfinishedLatest())!.id, s2.id);
      expect((await repo.unfinishedLatest())!.stateJson, '{"index":1}');

      await repo.update(s2.copyWith(
        completed: true,
        finishedAt: nowIso(),
        stateJson: null,
        skippedDuaIds: [3],
      ));
      expect(await repo.unfinishedLatest(), isNull);
      final done = await repo.completedLogs();
      expect(done.map((l) => l.id), [s2.id, s1.id], reason: 'newest first');
      expect(done.first.skippedDuaIds, [3]);
      expect(done.first.stateJson, isNull);
      expect(done.last.completedDuaIds, [1, 2]);

      await repo.delete(s1.id!);
      expect(await repo.get(s1.id!), isNull);
    });
  });

  group('SettingsRepository', () {
    test('defaults, save and load round trip', () async {
      final repo = SettingsRepository(db);
      final def = await repo.load();
      expect(def, const AppSettings());
      // No own key: falls back to the build-time key (empty in tests).
      expect(def.effectiveGeminiKey, defaultGeminiApiKey);

      final s = def.copyWith(
        themeMode: ThemeMode.dark,
        arabicFontSize: 40,
        counterMode: CounterMode.countDown,
        audioMode: AudioMode.followAlong,
        playbackRate: 1.25,
        geminiApiKey: ' my-key ',
        llmProvider: 'anthropic',
        defaultRoutineId: 7,
        onboardingDone: true,
        translationLanguage: 'Indonesian',
      );
      await repo.save(s);
      final loaded = await repo.load();
      expect(loaded, s);
      expect(loaded.effectiveGeminiKey, 'my-key');
      expect(loaded.toString().contains('my-key'), isFalse);

      await repo.save(loaded.copyWith(defaultRoutineId: null));
      expect((await repo.load()).defaultRoutineId, isNull);
    });

    test('fromJson clamps and tolerates junk', () {
      final s = AppSettings.fromJson({
        'arabicFontSize': 999,
        'playbackRate': 0.1,
        'themeMode': 'purple',
        'llmProvider': 'other',
        'haptics': 'false',
      });
      expect(s.arabicFontSize, 56);
      expect(s.playbackRate, 0.75);
      expect(s.themeMode, ThemeMode.system);
      expect(s.llmProvider, 'gemini');
      expect(s.haptics, isFalse);
    });
  });

  group('Translations, alarm events, chat', () {
    test('translations put/get/replace', () async {
      final repo = TranslationRepository(db);
      final d = await duas.add(_dua('A'));
      expect(await repo.get(d.id!, 'Urdu'), isNull);
      await repo.put(d.id!, 'Urdu', 'one');
      await repo.put(d.id!, 'Urdu', 'two');
      expect(await repo.get(d.id!, 'Urdu'), 'two');
    });

    test('alarm events dedupe, since, lastAtMs', () async {
      final repo = AlarmEventRepository(db);
      expect(await repo.lastAtMs(), 0);
      const e1 = AlarmEvent(
          reminderId: 1,
          occurrenceMs: 1000,
          event: 'rang',
          atMs: 1000,
          label: 'Fajr');
      const e2 = AlarmEvent(
          reminderId: 1, occurrenceMs: 1000, event: 'dismissed', atMs: 2000);
      await repo.addAll([e1, e2]);
      await repo.addAll([e1, e2]);
      expect(await repo.since(0), hasLength(2));
      expect((await repo.since(1500)).single.event, 'dismissed');
      expect(await repo.lastAtMs(), 2000);
      final fromNative = AlarmEvent.fromMap({
        'reminder_id': 2,
        'occurrence_ms': 5,
        'event': 'rang',
        'at_ms': 6.0,
        'label': 'n',
      });
      expect(fromNative.atMs, 6);
    });

    test('chat add/list/clear', () async {
      final repo = ChatRepository(db);
      for (var i = 0; i < 5; i++) {
        await repo.add(
            ChatMessage(role: i.isEven ? 'user' : 'assistant', text: 'm$i'));
      }
      final last3 = await repo.list(limit: 3);
      expect(last3.map((m) => m.text), ['m2', 'm3', 'm4']);
      expect(last3.first.createdAt, isNotEmpty);
      await repo.clear();
      expect(await repo.list(), isEmpty);
    });
  });
}
