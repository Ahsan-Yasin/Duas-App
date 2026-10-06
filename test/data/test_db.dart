import 'dart:io';

import 'package:daily_duas/core/db/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Opens a fresh in-memory database (close it in tearDown).
Future<AppDatabase> openTestDb() {
  sqfliteFfiInit();
  return AppDatabase.open(
      path: inMemoryDatabasePath, factory: databaseFactoryFfi);
}

/// Reads a bundled asset from disk (tests run from the project root).
Future<String> loadAssetFromDisk(String path) => File(path).readAsString();
