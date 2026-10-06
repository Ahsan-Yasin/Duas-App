import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'app.dart';
import 'core/db/app_database.dart';
import 'core/db/seed.dart';
import 'core/local_zone.dart';
import 'core/native/native_bridge.dart';
import 'core/providers.dart';
import 'core/repos/repositories.dart';
import 'core/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Background audio (lock-screen controls). Must run before any AudioPlayer
  // is created; tolerate platforms where it is unavailable.
  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.dailyduas.audio',
      androidNotificationChannelName: 'Recitation audio',
      androidNotificationOngoing: true,
    );
  } catch (e) {
    debugPrint('Background audio unavailable: $e');
  }
  try {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
  } catch (e) {
    debugPrint('Audio session not configured: $e');
  }

  try {
    final db = await AppDatabase.open();
    await seedIfEmpty(db, rootBundle.loadString);
    final settings = await SettingsRepository(db).load();

    // Falls back to an in-memory bridge on platforms without the Kotlin side.
    final NativeBridge bridge = MethodChannelNativeBridge();

    tzdata.initializeTimeZones();
    var zone = ''; // unknown: resolved from the device's UTC offsets
    try {
      zone = await bridge.getTimezone();
    } catch (e) {
      // e.g. an engine started headless by audio_service; app.dart re-reads it on resume.
      debugPrint('Timezone lookup failed: $e');
    }
    applyLocalZone(zone);

    runApp(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          initialSettingsProvider.overrideWithValue(settings),
          nativeBridgeProvider.overrideWithValue(bridge),
        ],
        child: const DailyDuasApp(),
      ),
    );
  } catch (e, st) {
    debugPrint('Startup failed: $e\n$st');
    runApp(_StartupErrorApp(error: e));
  }
}

/// Shown only when the database cannot be opened at all.
class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 56),
                const SizedBox(height: 16),
                const Text(
                  'Daily Duas could not start.',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Please close and reopen the app. If this keeps happening, '
                  'reinstalling may help.\n\n$error',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
