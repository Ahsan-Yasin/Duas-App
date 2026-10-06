import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/quran_index.dart';
import 'alarm/alarm_service.dart';
import 'audio/dua_player.dart';
import 'audio/quran_audio.dart';
import 'backup/backup_service.dart';
import 'db/app_database.dart';
import 'models/models.dart';
import 'native/native_bridge.dart';
import 'net/hadith_client.dart';
import 'net/llm_client.dart';
import 'repos/repositories.dart';

// ---------------------------------------------------------------------------
// Database + repositories
// ---------------------------------------------------------------------------

/// Overridden in main() and in tests with an opened [AppDatabase].
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('databaseProvider must be overridden'),
);

final duaRepoProvider =
    Provider<DuaRepository>((ref) => DuaRepository(ref.watch(databaseProvider)));

final routineRepoProvider = Provider<RoutineRepository>(
  (ref) => RoutineRepository(ref.watch(databaseProvider)),
);

final reminderRepoProvider = Provider<ReminderRepository>(
  (ref) => ReminderRepository(ref.watch(databaseProvider)),
);

final sessionRepoProvider = Provider<SessionRepository>(
  (ref) => SessionRepository(ref.watch(databaseProvider)),
);

final settingsRepoProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(databaseProvider)),
);

final translationRepoProvider = Provider<TranslationRepository>(
  (ref) => TranslationRepository(ref.watch(databaseProvider)),
);

final alarmEventRepoProvider = Provider<AlarmEventRepository>(
  (ref) => AlarmEventRepository(ref.watch(databaseProvider)),
);

final chatRepoProvider =
    Provider<ChatRepository>((ref) => ChatRepository(ref.watch(databaseProvider)));

final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(ref.watch(databaseProvider)),
);

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

/// Settings loaded in main() before runApp; overridden there and in tests.
final initialSettingsProvider = Provider<AppSettings>(
  (ref) => throw UnimplementedError('initialSettingsProvider must be overridden'),
);

final settingsProvider =
    NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(initialSettingsProvider);

  /// Applies [change] to the current settings, updates listeners immediately
  /// and persists the result.
  Future<void> update(AppSettings Function(AppSettings current) change) async {
    final next = change(state);
    state = next;
    await ref.read(settingsRepoProvider).save(next);
  }
}

// ---------------------------------------------------------------------------
// Data queries
// ---------------------------------------------------------------------------

final duasProvider =
    FutureProvider<List<Dua>>((ref) => ref.watch(duaRepoProvider).list());

final categoriesProvider = FutureProvider<List<String>>(
  (ref) => ref.watch(duaRepoProvider).categories(),
);

final routinesProvider =
    FutureProvider<List<Routine>>((ref) => ref.watch(routineRepoProvider).list());

final remindersProvider = FutureProvider<List<Reminder>>(
  (ref) => ref.watch(reminderRepoProvider).list(),
);

final completedLogsProvider = FutureProvider<List<SessionLog>>(
  (ref) => ref.watch(sessionRepoProvider).completedLogs(),
);

final unfinishedSessionProvider = FutureProvider<SessionLog?>(
  (ref) => ref.watch(sessionRepoProvider).unfinishedLatest(),
);

/// The bundled Tanzil Quran text, parsed once and kept for the app lifetime.
final quranIndexProvider = FutureProvider<QuranIndex>((ref) async {
  final text = await rootBundle.loadString('assets/quran/quran-simple.txt');
  return QuranIndex.parse(text);
});

// ---------------------------------------------------------------------------
// Platform services
// ---------------------------------------------------------------------------

final nativeBridgeProvider =
    Provider<NativeBridge>((ref) => MethodChannelNativeBridge());

final alarmServiceProvider = Provider<AlarmService>(
  (ref) => AlarmService(
    bridge: ref.watch(nativeBridgeProvider),
    reminders: ref.watch(reminderRepoProvider),
    routines: ref.watch(routineRepoProvider),
    events: ref.watch(alarmEventRepoProvider),
  ),
);

final nativeStatusProvider = FutureProvider<NativeStatus>(
  (ref) => ref.watch(nativeBridgeProvider).getStatus(),
);

final llmClientProvider = Provider<LlmClient>(
  (ref) => LlmClient(settings: () => ref.read(settingsProvider)),
);

/// Online check of hadith wording against the fawazahmed0/hadith-api dataset.
final hadithClientProvider = Provider<HadithClient>((ref) => HadithClient());

final quranAudioProvider = Provider<QuranAudioCache>(
  (ref) => QuranAudioCache(baseDir: getApplicationSupportDirectory),
);

final duaPlayerProvider = Provider<DuaPlayer>((ref) {
  final player = DuaPlayer();
  ref.onDispose(player.dispose);
  return player;
});

/// Clock, overridable in tests.
final nowProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Re-runs every data query after a write so all screens refresh.
void invalidateData(WidgetRef ref) {
  ref.invalidate(duasProvider);
  ref.invalidate(categoriesProvider);
  ref.invalidate(routinesProvider);
  ref.invalidate(remindersProvider);
  ref.invalidate(completedLogsProvider);
  ref.invalidate(unfinishedSessionProvider);
}

/// Same as [invalidateData] for code that only holds the container (for
/// example a SnackBar action that outlives the screen that showed it).
void invalidateContainerData(ProviderContainer container) {
  container.invalidate(duasProvider);
  container.invalidate(categoriesProvider);
  container.invalidate(routinesProvider);
  container.invalidate(remindersProvider);
  container.invalidate(completedLogsProvider);
  container.invalidate(unfinishedSessionProvider);
}
