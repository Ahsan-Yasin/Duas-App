import 'dart:io';

import 'package:daily_duas/core/db/app_database.dart';
import 'package:daily_duas/core/models/models.dart';
import 'package:daily_duas/core/native/native_bridge.dart';
import 'package:daily_duas/core/providers.dart';
import 'package:daily_duas/core/repos/repositories.dart';
import 'package:daily_duas/features/recite/recite_screen.dart';
import 'package:daily_duas/features/recite/recite_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui2_test_utils.dart';

void main() {
  late AppDatabase db;
  late SeededRoutine seeded;
  late FakeDuaPlayer player;

  setUp(() async {
    db = await openUi2TestDb();
    seeded = await seedRoutine(db);
    player = FakeDuaPlayer();
  });

  tearDown(() async {
    await db.close();
  });

  Widget app({AppSettings? settings}) {
    final s = settings ??
        AppSettings(
          haptics: false,
          translationLanguage: 'English',
          defaultRoutineId: seeded.routineId,
        );
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        initialSettingsProvider.overrideWithValue(s),
        nativeBridgeProvider.overrideWithValue(FakeNativeBridge()),
        duaPlayerProvider.overrideWithValue(player),
      ],
      child: MaterialApp(
        home: ReciteScreen(routineId: seeded.routineId),
      ),
    );
  }

  Future<void> tapCounter(WidgetTester tester, int times) async {
    for (var i = 0; i < times; i++) {
      await tester.tap(find.byKey(reciteCounterKey));
      await tester.pump();
    }
  }

  /// Lets the success animation run and the screen auto-advance.
  Future<void> settleAdvance(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('shows the first dua with its Arabic text', (tester) async {
    await tester.pumpWidget(app());
    await pumpUntilFound(tester, find.text('Dua 1 of 3'));

    expect(find.text('Dua 1 of 3'), findsOneWidget);
    expect(find.text(seeded.duas.first.arabic), findsOneWidget);
    expect(find.text('Morning remembrance'), findsWidgets);
    expect(find.text('0 / 3'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Count, 0 of 3, tap after each recitation'),
      findsOneWidget,
    );

    // A session log was created for resuming.
    final logs = await tester.runAsync(
      () => SessionRepository(db).unfinishedLatest(),
    );
    expect(logs, isNotNull);
    expect(logs!.completed, isFalse);
  });

  testWidgets('counter reaches target and auto-advances', (tester) async {
    await tester.pumpWidget(app());
    await pumpUntilFound(tester, find.text('Dua 1 of 3'));

    await tapCounter(tester, 2);
    expect(find.text('2 / 3'), findsOneWidget);
    expect(find.text('Dua 1 of 3'), findsOneWidget);

    await tapCounter(tester, 1);
    // Success check shows before advancing.
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);

    await settleAdvance(tester);
    await pumpUntilFound(tester, find.text('Dua 2 of 3'));
    expect(find.text('Dua 2 of 3'), findsOneWidget);
    expect(find.text(seeded.duas[1].arabic), findsOneWidget);
    expect(find.text('0 / 1'), findsOneWidget);
  });

  testWidgets('Skip advances to the next dua', (tester) async {
    await tester.pumpWidget(app());
    await pumpUntilFound(tester, find.text('Dua 1 of 3'));

    await tester.tap(find.text('Skip'));
    await tester.pump();
    await pumpUntilFound(tester, find.text('Dua 2 of 3'));
    expect(find.text('Dua 2 of 3'), findsOneWidget);
  });

  testWidgets('finishing all duas shows the finish view', (tester) async {
    await tester.pumpWidget(app());
    await pumpUntilFound(tester, find.text('Dua 1 of 3'));

    await tapCounter(tester, 3);
    await settleAdvance(tester);
    await pumpUntilFound(tester, find.text('Dua 2 of 3'));

    await tapCounter(tester, 1);
    await settleAdvance(tester);
    await pumpUntilFound(tester, find.text('Dua 3 of 3'));

    await tapCounter(tester, 1);
    await settleAdvance(tester);
    await pumpUntilFound(tester, find.text(seeded.acceptance.arabic));

    expect(find.text('Session complete'), findsOneWidget);
    expect(find.text('3 duas completed'), findsOneWidget);
    expect(find.text(seeded.acceptance.arabic), findsOneWidget);
    expect(find.text(seeded.acceptance.translation), findsOneWidget);
    expect(find.text('Current streak: 1 day'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);

    final logs = await tester.runAsync(() => SessionRepository(db).completedLogs());
    expect(logs, hasLength(1));
    expect(logs!.single.completed, isTrue);
    expect(logs.single.stateJson, isNull);
    expect(logs.single.finishedAt, isNotNull);
    expect(logs.single.completedDuaIds, [for (final d in seeded.duas) d.id]);
  });

  testWidgets('Close asks to save progress', (tester) async {
    await tester.pumpWidget(app());
    await pumpUntilFound(tester, find.text('Dua 1 of 3'));

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Save progress?'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Discard'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Save progress?'), findsNothing);
    expect(find.text('Dua 1 of 3'), findsOneWidget);
  });

  testWidgets('without auto-advance a Next button appears', (tester) async {
    await tester.pumpWidget(app(
      settings: AppSettings(
        haptics: false,
        autoAdvance: false,
        translationLanguage: 'English',
        defaultRoutineId: seeded.routineId,
      ),
    ));
    await pumpUntilFound(tester, find.text('Dua 1 of 3'));

    await tapCounter(tester, 3);
    await settleAdvance(tester);
    expect(find.text('Dua 1 of 3'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);

    await tester.tap(find.text('Next'));
    await tester.pump();
    await pumpUntilFound(tester, find.text('Dua 2 of 3'));
    expect(find.text('Dua 2 of 3'), findsOneWidget);
  });

  testWidgets('follow-along counts one repetition per audio pass',
      (tester) async {
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('ui2_audio'),
    ))!;
    final file = File('${dir.path}/dua.mp3');
    await tester.runAsync(() => file.writeAsBytes(const [0, 1, 2, 3]));
    final first = seeded.duas.first;
    await tester.runAsync(() => DuaRepository(db).update(
          first.copyWith(audioKind: AudioKind.file, audioPath: file.path),
        ));

    await tester.pumpWidget(app(
      settings: AppSettings(
        haptics: false,
        audioMode: AudioMode.followAlong,
        translationLanguage: 'English',
        defaultRoutineId: seeded.routineId,
      ),
    ));
    await pumpUntilFound(tester, find.text('Dua 1 of 3'));
    for (var i = 0; i < 20 && !player.calls.contains('play'); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(player.calls, contains('play'));
    expect(player.lastPaths, [file.path]);
    expect(player.lastRepeat, 3);

    player.completePass(1);
    await tester.pump();
    expect(find.text('1 / 3'), findsOneWidget);
    player.completePass(2);
    player.completePass(3);
    await tester.pump();
    await settleAdvance(tester);
    await pumpUntilFound(tester, find.text('Dua 2 of 3'));
    expect(find.text('Dua 2 of 3'), findsOneWidget);
    // The second dua has no audio: the device-voice fallback is offered.
    expect(find.text('No recitation audio'), findsOneWidget);
    expect(find.text('Read aloud (device voice — not a reciter)'), findsOneWidget);

    await tester.runAsync(() => dir.delete(recursive: true));
  });
}
