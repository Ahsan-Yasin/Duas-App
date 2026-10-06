import 'package:daily_duas/core/db/app_database.dart';
import 'package:daily_duas/core/db/seed.dart';
import 'package:daily_duas/core/models/models.dart';
import 'package:daily_duas/core/repos/repositories.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_db.dart';

void main() {
  late AppDatabase db;

  setUp(() async => db = await openTestDb());
  tearDown(() => db.close());

  test('seedIfEmpty inserts built-in duas, routines and default routine',
      () async {
    await seedIfEmpty(db, loadAssetFromDisk);
    final duas = DuaRepository(db);
    final routines = RoutineRepository(db);

    final all = await duas.list();
    expect(all, hasLength(6));
    expect(all.every((d) => d.isBuiltIn && d.key != null), isTrue);
    expect(all.map((d) => d.key),
        containsAll(['al_ikhlas', 'ayat_al_kursi', 'acceptance']));

    final ikhlas = (await duas.getByKey('al_ikhlas'))!;
    expect(ikhlas.isQuran, isTrue);
    expect(ikhlas.audioKind, AudioKind.quran);
    expect((ikhlas.quranSurah, ikhlas.quranAyahStart, ikhlas.quranAyahEnd),
        (112, 1, 4));
    expect(ikhlas.ayahs, hasLength(4));
    expect(ikhlas.defaultRepeat, 3);
    expect(ikhlas.verificationStatus, VerificationStatus.verified);
    expect(ikhlas.verificationNote, contains('Tanzil'));

    final tammah = (await duas.getByKey('kalimat_tammah'))!;
    expect(tammah.isQuran, isFalse);
    expect(tammah.audioKind, AudioKind.none);
    expect(tammah.category, 'Evil eye');

    final acceptance = (await duas.getByKey('acceptance'))!;
    expect(acceptance.category, 'Acceptance');

    final list = await routines.list();
    expect(list.map((r) => r.key), ['morning', 'evil_eye']);
    final morning = list.first;
    final resolved = await routines.resolvedItems(morning.id!);
    expect(resolved.map((e) => e.$1.key),
        ['ayat_al_kursi', 'al_ikhlas', 'al_falaq', 'an_nas']);
    expect(resolved.map((e) => e.$2), [1, 3, 3, 3]);

    final settings = await SettingsRepository(db).load();
    expect(settings.defaultRoutineId, morning.id);
  });

  test('seedIfEmpty is idempotent', () async {
    await seedIfEmpty(db, loadAssetFromDisk);
    final settingsRepo = SettingsRepository(db);
    await settingsRepo.save(
        (await settingsRepo.load()).copyWith(onboardingDone: true));
    // A soft-deleted built-in still counts: no re-seed.
    final ikhlas = (await DuaRepository(db).getByKey('al_ikhlas'))!;
    await DuaRepository(db).softDelete(ikhlas.id!);

    await seedIfEmpty(db, loadAssetFromDisk);
    await seedIfEmpty(db, loadAssetFromDisk);

    expect(await DuaRepository(db).list(includeDeleted: true), hasLength(6));
    expect(await RoutineRepository(db).list(), hasLength(2));
    expect(await db.db.query('routine_items'), hasLength(7));
    expect((await settingsRepo.load()).onboardingDone, isTrue);
  });
}
