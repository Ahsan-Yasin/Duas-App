import 'dart:async';

import 'package:daily_duas/core/audio/dua_player.dart';
import 'package:daily_duas/core/db/app_database.dart';
import 'package:daily_duas/core/models/models.dart';
import 'package:daily_duas/core/repos/repositories.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// In-memory DB for widget tests. The no-isolate ffi factory completes its
/// futures via microtasks, so DB calls made by widgets finish inside the
/// fake-async zone of `testWidgets`.
Future<AppDatabase> openUi2TestDb() {
  sqfliteFfiInit();
  return AppDatabase.open(
    path: inMemoryDatabasePath,
    factory: databaseFactoryFfiNoIsolate,
  );
}

/// Seeded data used by the recite tests.
class SeededRoutine {
  SeededRoutine(this.routineId, this.duas, this.acceptance);

  final int routineId;
  final List<Dua> duas;
  final Dua acceptance;
}

/// Inserts three duas (repeat 3, 1, 1) in a routine plus the acceptance dua.
Future<SeededRoutine> seedRoutine(AppDatabase db) async {
  final duaRepo = DuaRepository(db);
  final routineRepo = RoutineRepository(db);
  final d1 = await duaRepo.add(const Dua(
    title: 'Morning remembrance',
    arabic: 'أَصْبَحْنَا وَأَصْبَحَ الْمُلْكُ لِلَّهِ',
    transliteration: 'Asbahna wa asbahal-mulku lillah',
    translation: 'We have reached the morning and the dominion belongs to Allah.',
    source: 'Muslim 2723',
    defaultRepeat: 3,
  ));
  final d2 = await duaRepo.add(const Dua(
    title: 'Seeking forgiveness',
    arabic: 'أَسْتَغْفِرُ اللَّهَ',
    translation: 'I seek the forgiveness of Allah.',
    source: 'Bukhari 6307',
  ));
  final d3 = await duaRepo.add(const Dua(
    title: 'Sufficiency',
    arabic: 'حَسْبِيَ اللَّهُ',
    translation: 'Allah is sufficient for me.',
    source: 'Abu Dawud 5081',
  ));
  final acceptance = await duaRepo.add(const Dua(
    key: 'acceptance',
    title: 'Acceptance',
    arabic: 'رَبَّنَا تَقَبَّلْ مِنَّا',
    translation: 'Our Lord, accept this from us.',
    source: 'Quran 2:127',
  ));
  final routine = await routineRepo.add('Morning');
  for (final d in [d1, d2, d3]) {
    await routineRepo.addDua(routine.id!, d.id!);
  }
  return SeededRoutine(routine.id!, [d1, d2, d3], acceptance);
}

/// Pumps frames (letting real async work complete in between) until
/// [finder] matches or [maxTries] is reached.
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxTries = 50,
}) async {
  for (var i = 0; i < maxTries; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
}

/// [DuaPlayer] that never touches a platform channel and records calls.
class FakeDuaPlayer implements DuaPlayer {
  final _index = StreamController<int?>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _pass = StreamController<int>.broadcast();
  final List<String> calls = [];
  List<String> lastPaths = const [];
  int lastRepeat = 0;

  @override
  Stream<int?> get currentIndexStream => _index.stream;

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<int> get passCompletedStream => _pass.stream;

  /// Simulates the end of a full pass.
  void completePass(int pass) => _pass.add(pass);

  @override
  Future<void> playFiles(
    List<String> paths, {
    int repeat = 1,
    double speed = 1.0,
    String title = '',
    String? subtitle,
  }) async {
    calls.add('play');
    lastPaths = paths;
    lastRepeat = repeat;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    _playing.add(false);
  }

  @override
  Future<void> resume() async {
    calls.add('resume');
    _playing.add(true);
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    _playing.add(false);
  }

  @override
  Future<void> setSpeed(double s) async => calls.add('speed:$s');

  @override
  Future<void> dispose() async {
    await _index.close();
    await _playing.close();
    await _pass.close();
  }
}
