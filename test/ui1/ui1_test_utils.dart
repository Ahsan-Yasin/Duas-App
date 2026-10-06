import 'dart:io';

import 'package:daily_duas/core/db/app_database.dart';
import 'package:daily_duas/core/db/seed.dart';
import 'package:daily_duas/core/native/native_bridge.dart';
import 'package:daily_duas/core/providers.dart';
import 'package:daily_duas/core/repos/repositories.dart';
import 'package:daily_duas/core/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Opens an in-memory DB seeded with the bundled duas and routines.
///
/// Uses the no-isolate ffi factory so DB futures complete via microtasks
/// inside the fake-async zone of `testWidgets`.
Future<AppDatabase> openSeededTestDb() async {
  sqfliteFfiInit();
  final db = await AppDatabase.open(
    path: inMemoryDatabasePath,
    factory: databaseFactoryFfiNoIsolate,
  );
  await seedIfEmpty(db, (path) => File(path).readAsString());
  return db;
}

/// Wraps [child] in a ProviderScope backed by [db] and a fake native bridge.
Future<Widget> testApp(AppDatabase db, Widget child) async {
  final settings = await SettingsRepository(db).load();
  return ProviderScope(
    retry: (_, _) => null,
    overrides: [
      databaseProvider.overrideWithValue(db),
      initialSettingsProvider.overrideWithValue(settings),
      nativeBridgeProvider.overrideWithValue(FakeNativeBridge()),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: child),
  );
}

/// Pumps frames until [finder] matches (or fails after [maxTries]).
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxTries = 60,
}) async {
  for (var i = 0; i < maxTries; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsWidgets, reason: 'Timed out waiting for $finder');
}

/// Pumps frames until [finder] no longer matches.
Future<void> pumpUntilGone(
  WidgetTester tester,
  Finder finder, {
  int maxTries = 60,
}) async {
  for (var i = 0; i < maxTries; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isEmpty) return;
  }
  expect(finder, findsNothing, reason: 'Timed out waiting for $finder to go');
}
