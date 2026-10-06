import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../config.dart';

/// sqflite database wrapper. Schema v1.
class AppDatabase {
  AppDatabase._(this.db);

  /// The open sqflite database.
  final Database db;

  static const schemaVersion = 1;

  /// Tables holding user content (wiped by a "replace" backup import).
  static const userTables = <String>[
    'routine_items',
    'translations',
    'session_logs',
    'reminders',
    'routines',
    'duas',
  ];

  /// Opens (creating if needed) the database.
  /// [path] null => `getDatabasesPath()/duas.db`. Tests pass
  /// `inMemoryDatabasePath` and `databaseFactoryFfi`.
  static Future<AppDatabase> open({
    String? path,
    DatabaseFactory? factory,
  }) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), databaseFileName);
    final db = await f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        // Every in-memory open is a fresh database (tests open several).
        singleInstance: dbPath != inMemoryDatabasePath,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) => _createV1(db),
        onUpgrade: (db, from, to) async {
          // Future migrations go here (if (from < 2) {...}).
        },
      ),
    );
    return AppDatabase._(db);
  }

  Future<void> close() => db.close();

  static Future<void> _createV1(Database db) async {
    final batch = db.batch();
    batch.execute('''
      CREATE TABLE duas (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        key TEXT UNIQUE,
        title TEXT NOT NULL,
        arabic TEXT NOT NULL,
        transliteration TEXT NOT NULL DEFAULT '',
        translation TEXT NOT NULL DEFAULT '',
        source TEXT NOT NULL DEFAULT '',
        category TEXT NOT NULL DEFAULT 'General',
        default_repeat INTEGER NOT NULL DEFAULT 1,
        audio_kind TEXT NOT NULL DEFAULT 'none',
        audio_path TEXT,
        quran_surah INTEGER,
        quran_ayah_start INTEGER,
        quran_ayah_end INTEGER,
        ayahs TEXT,
        is_built_in INTEGER NOT NULL DEFAULT 0,
        verification_status TEXT NOT NULL DEFAULT 'unverified',
        verification_note TEXT NOT NULL DEFAULT '',
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL DEFAULT '',
        updated_at TEXT NOT NULL DEFAULT '',
        deleted_at TEXT
      )''');
    batch.execute('''
      CREATE TABLE routines (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        key TEXT UNIQUE,
        name TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL DEFAULT ''
      )''');
    batch.execute('''
      CREATE TABLE routine_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        routine_id INTEGER NOT NULL REFERENCES routines(id) ON DELETE CASCADE,
        dua_id INTEGER NOT NULL REFERENCES duas(id) ON DELETE CASCADE,
        position INTEGER NOT NULL DEFAULT 0,
        repeat_override INTEGER
      )''');
    batch.execute(
        'CREATE INDEX idx_routine_items_routine ON routine_items(routine_id, position)');
    batch.execute('''
      CREATE TABLE reminders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        label TEXT NOT NULL DEFAULT '',
        hour INTEGER NOT NULL,
        minute INTEGER NOT NULL,
        weekdays TEXT NOT NULL DEFAULT '[1,2,3,4,5,6,7]',
        routine_id INTEGER REFERENCES routines(id) ON DELETE SET NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        snooze_minutes INTEGER NOT NULL DEFAULT 5,
        max_snoozes INTEGER NOT NULL DEFAULT 3,
        nag_enabled INTEGER NOT NULL DEFAULT 1,
        nag_every_minutes INTEGER NOT NULL DEFAULT 10,
        nag_max_times INTEGER NOT NULL DEFAULT 3,
        ring_seconds INTEGER NOT NULL DEFAULT 120,
        vibrate INTEGER NOT NULL DEFAULT 1,
        sound TEXT NOT NULL DEFAULT 'default',
        created_at TEXT NOT NULL DEFAULT '',
        updated_at TEXT NOT NULL DEFAULT ''
      )''');
    batch.execute('''
      CREATE TABLE session_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        routine_id INTEGER REFERENCES routines(id) ON DELETE SET NULL,
        started_at TEXT NOT NULL,
        finished_at TEXT,
        completed_dua_ids TEXT NOT NULL DEFAULT '[]',
        skipped_dua_ids TEXT NOT NULL DEFAULT '[]',
        from_alarm INTEGER NOT NULL DEFAULT 0,
        reminder_id INTEGER,
        completed INTEGER NOT NULL DEFAULT 0,
        state_json TEXT
      )''');
    batch.execute(
        'CREATE INDEX idx_session_logs_completed ON session_logs(completed, started_at)');
    batch.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT
      )''');
    batch.execute('''
      CREATE TABLE translations (
        dua_id INTEGER NOT NULL REFERENCES duas(id) ON DELETE CASCADE,
        lang TEXT NOT NULL,
        text TEXT NOT NULL,
        PRIMARY KEY (dua_id, lang)
      )''');
    batch.execute('''
      CREATE TABLE alarm_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        reminder_id INTEGER NOT NULL,
        occurrence_ms INTEGER NOT NULL,
        event TEXT NOT NULL,
        at_ms INTEGER NOT NULL,
        label TEXT NOT NULL DEFAULT '',
        UNIQUE (reminder_id, occurrence_ms, event, at_ms)
      )''');
    batch.execute('CREATE INDEX idx_alarm_events_at ON alarm_events(at_ms)');
    batch.execute('''
      CREATE TABLE chat_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        role TEXT NOT NULL,
        text TEXT NOT NULL,
        payload_json TEXT,
        created_at TEXT NOT NULL DEFAULT ''
      )''');
    await batch.commit(noResult: true);
  }
}
