# Daily Duas — Flutter Architecture & Module Contract

Flutter 3.44.8 / Dart 3.12, Android (minSdk 24, target/compile 36), package `daily_duas`,
Android namespace/applicationId `com.dailyduas.daily_duas`. Offline-first; only chat, LLM
translation and first-time Quran audio download use the network. Riverpod 3 (no codegen),
sqflite (no codegen, faster build than Drift), just_audio + just_audio_background, custom Kotlin
alarm engine. This file is the contract between modules: implement exactly these public APIs
(private helpers are fine) and consume only these APIs.

## 0. Rules
- `lib/domain/**` is pure Dart (no `package:flutter` imports) so it is unit-testable.
- Never alter Arabic text silently. Never print API keys.
- Timestamps in DB: ISO-8601 strings with offset (`DateTime.now().toIso8601String()` is local w/o offset → use
  helper `nowIso()` in `core/util.dart`, which appends the offset). Alarm times = epoch ms. Weekdays ISO: Mon=1..Sun=7
  (= Dart `DateTime.weekday`).
- Every screen: loading, empty, error states. Tap targets ≥ 48 dp. Icon-only buttons have `tooltip:` (TalkBack label).
- Arabic: `fontFamily: 'Amiri'`, `textDirection: TextDirection.rtl`, size `settings.arabicFontSize`, height 1.9.
- Material 3, seed color `Color(0xFF0F6E5A)` (deep green), light + dark themes.
- Use `debugPrint` sparingly; `flutter analyze` must be clean (flutter_lints 6).

## 1. File layout (owner in brackets)
```
lib/main.dart                         [UI-1]  init + runApp
lib/app.dart                          [UI-1]  DailyDuasApp: MaterialApp, theme, startup gate, alarm event routing
lib/core/config.dart                  [DATA]  constants + defaultGeminiApiKey
lib/core/util.dart                    [DATA]  nowIso(), parseIso(), jsonList helpers
lib/core/models/models.dart           [DATA]  all model classes (§2)
lib/core/db/app_database.dart         [DATA]  sqflite schema/migrations
lib/core/db/seed.dart                 [DATA]  seedIfEmpty
lib/core/repos/repositories.dart      [DATA]  all repositories (§3)
lib/core/backup/backup_service.dart   [DATA]
lib/domain/arabic.dart, quran_index.dart, verification.dart, schedule.dart, session.dart, stats.dart   [DOMAIN]
lib/core/net/llm_client.dart          [DOMAIN]
lib/core/audio/quran_audio.dart       [DOMAIN]  reciters, URLs, download cache
lib/core/audio/dua_player.dart        [UI-2]    just_audio wrapper
lib/core/native/native_bridge.dart    [NATIVE]  MethodChannel/EventChannel wrapper + FakeNativeBridge
lib/core/alarm/alarm_service.dart     [NATIVE]  sync/repair/ingest/missed banner
android/**                            [NATIVE]  Kotlin alarm engine, manifest, res/raw/alarm_tone.wav
lib/core/providers.dart               [UI-1]    all providers (§5)
lib/core/navigation.dart              [UI-1]    navigatorKey + helpers (§6)
lib/core/theme.dart, lib/core/widgets/common.dart   [UI-1]
lib/features/shell/root_shell.dart    [UI-1]  bottom NavigationBar (Home, Library, Routines, Reminders, More)
lib/features/home/home_screen.dart    [UI-1]
lib/features/library/library_screen.dart, dua_editor_screen.dart        [UI-1]
lib/features/routines/routines_screen.dart, routine_editor_screen.dart  [UI-1]
lib/features/recite/recite_screen.dart (+ finish view)                  [UI-2]
lib/features/alarm/alarm_ring_screen.dart                               [UI-2]
lib/features/reminders/reminders_screen.dart, reminder_editor_screen.dart [UI-3]
lib/features/reliability/reliability_screen.dart                       [UI-3]
lib/features/chat/chat_screen.dart                                     [UI-3]
lib/features/history/history_screen.dart                               [UI-3]
lib/features/settings/settings_screen.dart, more_screen.dart           [UI-3]
lib/features/onboarding/onboarding_screen.dart                         [UI-3]
test/**  each owner tests their own module
assets/data/seed_duas.json, seed_routines.json; assets/quran/quran-simple.txt (Tanzil, "sura|aya|text", '#' comment lines at end); assets/fonts/Amiri-*.ttf
```

## 2. Models — `lib/core/models/models.dart` (plain immutable classes with `copyWith`, `toMap()`/`fromMap()` for DB rows and `toJson()`/`fromJson()` for backup)
```dart
enum AudioKind { none, quran, file, tts }            // stored by name
enum VerificationStatus { verified, unverified }

class Dua { final int? id; final String? key; final String title, arabic, transliteration, translation, source, category;
  final int defaultRepeat;            // 1..100
  final AudioKind audioKind; final String? audioPath;   // user file path for AudioKind.file
  final int? quranSurah, quranAyahStart, quranAyahEnd;
  final List<String>? ayahs;          // per-ayah Arabic (Quran duas) for follow-along highlight
  final bool isBuiltIn; final VerificationStatus verificationStatus; final String verificationNote;
  final int sortOrder; final String createdAt, updatedAt; final String? deletedAt;
  bool get isQuran => quranSurah != null; }
class RoutineItem { final int? id; final int routineId; final int duaId; final int position; final int? repeatOverride; }
class Routine { final int? id; final String? key; final String name; final int sortOrder; final String createdAt; final List<RoutineItem> items; }
class Reminder { final int? id; final String label; final int hour, minute; final List<int> weekdays; final int? routineId; final bool enabled;
  final int snoozeMinutes /*5*/, maxSnoozes /*3*/; final bool nagEnabled /*true*/; final int nagEveryMinutes /*10*/, nagMaxTimes /*3*/;
  final int ringSeconds /*120*/; final bool vibrate /*true*/; final String sound /*'default'*/; final String createdAt, updatedAt;
  String get timeLabel;   // "07:00"
  Map<String, dynamic> toNativeJson({required String routineName}); }   // §4 reminder dict
class SessionLog { final int? id; final int? routineId; final String startedAt; final String? finishedAt;
  final List<int> completedDuaIds, skippedDuaIds; final bool fromAlarm; final int? reminderId; final bool completed;
  final String? stateJson; }          // ReciteSession.toJson() while unfinished (resume)
class AlarmEvent { final int? id; final int reminderId; final int occurrenceMs; final String event; final int atMs; final String label; }
  // event ∈ rang, auto_stopped, snoozed, dismissed, started, nag_rang, test_rang
class ChatMessage { final int? id; final String role /*user|assistant|error*/; final String text; final String? payloadJson; final String createdAt; }
enum CounterMode { countUp, countDown }
enum AudioMode { off, listen, listenThenRecite, followAlong }
class AppSettings { ThemeMode themeMode=system; int arabicFontSize=30 /*20..56*/; bool showTransliteration=true, showTranslation=true, haptics=true;
  CounterMode counterMode=countUp; bool autoAdvance=true; AudioMode audioMode=off; double playbackRate=1.0 /*0.75..1.25*/;
  String reciter='Alafasy_128kbps'; String llmProvider='gemini' /*gemini|anthropic*/; String geminiApiKey='' /* '' => defaultGeminiApiKey */;
  String geminiModel='gemini-flash-latest'; String anthropicApiKey=''; String anthropicModel='claude-sonnet-5-5';
  String translationLanguage='Urdu'; int defaultSnoozeMinutes=5; int? defaultRoutineId; bool onboardingDone=false;
  String get effectiveGeminiKey; Map<String,dynamic> toJson(); factory fromJson(...); copyWith(...) }
```

## 3. Data — `app_database.dart`, `repositories.dart`, `seed.dart`, `backup_service.dart`
`class AppDatabase { static Future<AppDatabase> open({String? path, DatabaseFactory? factory}); // path null => getDatabasesPath()/duas.db; tests pass inMemoryDatabasePath + databaseFactoryFfi
  Database get db; Future<void> close(); }` — schema v1 tables: duas, routines, routine_items, reminders, session_logs,
settings(key PK, value TEXT json), translations(dua_id, lang, text, PK(dua_id,lang)), alarm_events, chat_messages. Foreign keys ON.
Repositories (constructor takes `AppDatabase`), all async:
```dart
class DuaRepository { Future<List<Dua>> list({bool includeDeleted=false, String search='', String? category});  // sort_order, id
  Future<Dua?> get(int id); Future<Dua?> getByKey(String key); Future<Dua> add(Dua d); Future<Dua> update(Dua d);
  Future<void> softDelete(int id); Future<void> restore(int id); Future<void> reorder(List<int> orderedIds);
  Future<List<String>> categories(); Future<Dua?> findDuplicate(String arabic);  // uses domain/arabic.normalize
  Future<void> setVerification(int id, VerificationStatus s, String note); }
class RoutineRepository { Future<List<Routine>> list(); Future<Routine?> get(int id); Future<Routine> add(String name);
  Future<void> rename(int id, String name); Future<void> delete(int id);
  Future<void> addDua(int routineId, int duaId, {int? repeatOverride}); Future<void> removeItem(int itemId);
  Future<void> reorderItems(int routineId, List<int> orderedItemIds); Future<void> setRepeat(int itemId, int? repeatOverride);
  Future<List<(Dua, int)>> resolvedItems(int routineId); }   // (dua, effective repeat); skips soft-deleted duas
class ReminderRepository { Future<List<Reminder>> list(); Future<Reminder?> get(int id); Future<Reminder> add(Reminder r);
  Future<Reminder> update(Reminder r); Future<void> delete(int id); Future<void> setEnabled(int id, bool enabled); }
class SessionRepository { Future<SessionLog> add(SessionLog l); Future<void> update(SessionLog l); Future<SessionLog?> get(int id);
  Future<SessionLog?> unfinishedLatest(); Future<List<SessionLog>> completedLogs(); Future<void> delete(int id); }
class SettingsRepository { Future<AppSettings> load(); Future<void> save(AppSettings s); }
class TranslationRepository { Future<String?> get(int duaId, String lang); Future<void> put(int duaId, String lang, String text); }
class AlarmEventRepository { Future<void> addAll(List<AlarmEvent> e); /* dedupe reminderId+occurrenceMs+event+atMs */
  Future<List<AlarmEvent>> since(int ms); Future<int> lastAtMs(); }
class ChatRepository { Future<ChatMessage> add(ChatMessage m); Future<List<ChatMessage>> list({int limit=200}); Future<void> clear(); }
```
`Future<void> seedIfEmpty(AppDatabase db, Future<String> Function(String assetPath) loadAsset)` — inserts built-in duas (isBuiltIn,
key, Quran duas get AudioKind.quran) + routines from assets/data/*.json when no built-in duas exist; sets settings.defaultRoutineId
to the 'morning' routine. Idempotent.
`class BackupService { BackupService(AppDatabase db); Future<Map<String,dynamic>> export(); Future<String> exportJson();
  Future<ImportReport> import(Map<String,dynamic> data, {required bool replace}); }`
  format: `{"app":"daily_duas","format":1,"exported_at":..,"duas":[..],"routines":[{..,"items":[..]}],"reminders":[..],"session_logs":[..],"settings":{.. api keys removed}}`;
  merge skips duplicate duas (same key or normalized Arabic), routines by name, logs by startedAt; remaps ids.
  `class ImportReport { int duasAdded, duasSkipped, routinesAdded, remindersAdded, logsAdded; List<String> errors; }`
`core/config.dart`: `const appName='Daily Duas'; const defaultGeminiApiKey='<owner key>'; const appVersion='1.0.0';`

## 4. Domain (pure Dart)
- `arabic.dart`: `String stripDiacritics(String)`, `String normalizeArabic(String)` (strip harakat/tanween/shadda/sukun/U+0670/U+06D6–U+06ED/tatweel; أإآٱ→ا; ى→ي; ة→ه; ؤ→و; ئ→ي; drop punctuation/digits/ayah marks; collapse spaces), `bool isArabic(String)`.
- `quran_index.dart`: `class QuranIndex { factory QuranIndex.parse(String fileText); String ayah(int s,int a); List<String> ayahs(int s,int start,int end);
  int ayahCount(int s); List<(int,int,int)> find(String normalizedText, {int minLen=12}); }` + `(int,int,int)? parseQuranRef(String source)` ("Quran 2:255", "Al-Baqarah 2:201-202", "Q 112:1-4", "Surah 112").
  Tanzil verse 1 of suras ≠1,9 starts with the Bismillah — strip/allow it when comparing.
- `verification.dart`: `class VerificationResult { VerificationStatus status; String kind /*quran|hadith|unknown*/; String note; (int,int,int)? matchedRef; }`
  `VerificationResult verifyDua({required String arabic, required String source, required QuranIndex quran, Map<String,dynamic>? claimedQuran})` —
  Quran claim: verified iff normalized text equals the referenced range or is a contiguous substring of it (≥12 normalized chars → note "partial ayah"),
  optional leading Bismillah; else unverified + note "Text does not match the Quran at <ref>. Check with a teacher or a mushaf." No ref but found verbatim
  → verified with found ref. Hadith/other → unverified "Hadith wording – confirm with a reliable source or teacher."
- `schedule.dart` (uses package:timezone; mirrored by Kotlin): `tz.TZDateTime? nextOccurrence(int hour,int minute, Iterable<int> weekdays, tz.TZDateTime after)`
  — smallest instant > after on an allowed weekday at local hour:minute in `after.location`; DST gap → first valid instant after the gap (java.time
  semantics: shift forward by gap length); DST overlap → earlier instant. `List<(Reminder, tz.TZDateTime)> upcoming(List<Reminder>, tz.TZDateTime after, {int limit=10})`
  (enabled only, sorted); `(Reminder, tz.TZDateTime)? nextAlarm(...)`; `String formatCountdown(Duration)` ("in 6 h 12 min", "in 45 min", "in less than a minute").
- `session.dart`: `class SessionItem { int duaId; String title; int target; }` `class TapResult { int count, target; bool itemDone, sessionDone; }`
  `class ReciteSession { ReciteSession(List<SessionItem> items, {int? routineId, bool fromAlarm=false, int? reminderId, String? startedAt});
   int index; Map<int,int> counts; Set<int> completed, skipped;  SessionItem? get current; int get count, target, remaining;
   String get positionLabel /*"Dua 2 of 5"*/; double get progress; TapResult tap(); bool next(); bool back(); void skip(); void resetCurrent();
   bool get isFinished; List<int> get completedDuaIds, skippedDuaIds; String toJson(); factory ReciteSession.fromJson(String); }`
   tap never exceeds target; reaching target marks completed; skip marks skipped + advances; isFinished when every position completed|skipped.
- `stats.dart`: `Set<DateTime> completedDays(List<SessionLog>)` (local dates, date-only), `int currentStreak(Set<DateTime> days, DateTime today)`
  (from today, or from yesterday if today missing), `int longestStreak(Set<DateTime>)`, `({int sessions,int duas,int days}) totals(List<SessionLog>)`,
  `({int sessions,int duas, Set<int> routineIds}) todaySummary(List<SessionLog>, DateTime today)`.
- `core/net/llm_client.dart`: `class DuaSuggestion {title, arabic, transliteration, translation, source, category; int repeat; String kind /*quran|hadith*/; Map<String,dynamic>? quran /*{surah,ayah_start,ayah_end}*/}`
  `class ChatReply { String reply; List<DuaSuggestion> duas; }` `class LlmException implements Exception { String kind /*offline|bad_key|denied|rate_limit|server|bad_json|no_key|timeout*/; String userMessage; }`
  `class LlmClient { LlmClient({required AppSettings Function() settings, http.Client? client});
   Future<ChatReply> suggestDuas(String userText, List<ChatMessage> history); Future<String> translate(String text, String targetLanguage);
   Future<String> testConnection(); }`  `ChatReply parseReply(String raw)` (tolerates ```json fences). Gemini: POST
  `https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`, header `x-goog-api-key`, responseMimeType application/json.
  Anthropic: POST `https://api.anthropic.com/v1/messages`, headers `x-api-key`, `anthropic-version: 2023-06-01`. Map 400 API_KEY_INVALID/401→bad_key,
  403→denied, 429→rate_limit, 5xx→server, SocketException→offline.
- `core/audio/quran_audio.dart`: `const reciters = <(String folder, String name)>[...]`, `const audioAttribution`, `String ayahUrl(String reciter,int s,int a)`
  (https://everyayah.com/data/{reciter}/{SSS}{AAA}.mp3), `class QuranAudioCache { QuranAudioCache({required Future<Directory> Function() baseDir, http.Client? client});
  Future<File> fileFor(String reciter,int s,int a); Future<bool> isCached(...); Future<List<File>> ensureAyahs(String reciter,int s,int start,int end,{void Function(int done,int total)? onProgress});
  Future<int> cacheSizeBytes(); Future<void> clear(); }` (atomic .part → rename).

## 5. Providers — `lib/core/providers.dart` (Riverpod 3, no codegen)
```dart
final databaseProvider = Provider<AppDatabase>((ref) => throw UnimplementedError());   // overridden in main/tests
final duaRepoProvider, routineRepoProvider, reminderRepoProvider, sessionRepoProvider, settingsRepoProvider,
      translationRepoProvider, alarmEventRepoProvider, chatRepoProvider            // Provider<XRepository>
final backupServiceProvider = Provider<BackupService>
final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>   // SettingsNotifier.update(AppSettings Function(AppSettings)) persists
final initialSettingsProvider = Provider<AppSettings>((ref) => throw UnimplementedError()); // loaded in main, overridden
final duasProvider = FutureProvider<List<Dua>>;            final categoriesProvider = FutureProvider<List<String>>;
final routinesProvider = FutureProvider<List<Routine>>;    final remindersProvider = FutureProvider<List<Reminder>>;
final completedLogsProvider = FutureProvider<List<SessionLog>>; final unfinishedSessionProvider = FutureProvider<SessionLog?>;
final quranIndexProvider = FutureProvider<QuranIndex>;     // rootBundle.loadString('assets/quran/quran-simple.txt')
final nativeBridgeProvider = Provider<NativeBridge>((ref) => MethodChannelNativeBridge());   // tests override with FakeNativeBridge
final alarmServiceProvider = Provider<AlarmService>;      final nativeStatusProvider = FutureProvider<NativeStatus>;
final llmClientProvider = Provider<LlmClient>;            final quranAudioProvider = Provider<QuranAudioCache>;
final duaPlayerProvider = Provider<DuaPlayer>;            // disposed via ref.onDispose
final nowProvider = Provider<DateTime Function()>((ref) => DateTime.now);
void invalidateData(WidgetRef ref)   // invalidates duas/categories/routines/reminders/logs/unfinished providers after writes
```

## 6. Navigation — `lib/core/navigation.dart`
`final navigatorKey = GlobalKey<NavigatorState>();` Plain Navigator (MaterialPageRoute). Helpers (all screens use these):
```dart
Future<T?> pushScreen<T>(Widget screen, {bool fullscreenDialog=false});
void openRecite({required int? routineId, bool fromAlarm=false, int? reminderId, int? resumeLogId});   // pushes ReciteScreen
void openAlarm(RingingAlarm alarm);   // pushes AlarmRingScreen (replaces an existing alarm screen)
```
Screen constructors: `ReciteScreen({super.key, required this.routineId, this.fromAlarm=false, this.reminderId, this.resumeLogId})`,
`AlarmRingScreen({super.key, required this.alarm})`, `DuaEditorScreen({this.duaId, this.initial /*DuaSuggestion prefill*/})`,
`RoutineEditorScreen({required this.routineId})`, `ReminderEditorScreen({this.reminderId})`, `ReliabilityScreen()`, `ChatScreen()`,
`HistoryScreen()`, `SettingsScreen()`, `MoreScreen()`, `OnboardingScreen({required this.onDone})`, `HomeScreen()`, `LibraryScreen()`,
`RoutinesScreen()`, `RemindersScreen()`, `RootShell()`.

## 7. Native bridge — `lib/core/native/native_bridge.dart` ⇄ Kotlin
Channels: `MethodChannel('daily_duas/native')`, `EventChannel('daily_duas/native_events')`.
```dart
class ScheduledAlarm { int reminderId; int weekday; String kind /*main|snooze|nag|test*/; int triggerAtMs; bool exists; }
class RingingAlarm { int reminderId; int occurrenceMs; int? routineId; String label; String kind; int snoozesUsed, maxSnoozes; int startedMs; }
class AlarmLaunch { String action /*ring|start|open*/; int reminderId; int occurrenceMs; int? routineId; String label; String kind; }
class NativeStatus { bool notificationsEnabled, exactAlarmsAllowed, fullScreenAllowed, ignoringBatteryOptimizations; int? nextAlarmMs;
  String manufacturer, model, timezone; int sdkInt; bool isAndroid; }
abstract class NativeBridge {
  Future<List<ScheduledAlarm>> syncReminders(List<Map<String, dynamic>> reminders);   // full desired state
  Future<List<ScheduledAlarm>> getScheduled();
  Future<int> scheduleTest({int seconds = 10, required String label, int? routineId}); // returns triggerAtMs; reminderId -1
  Future<AlarmLaunch?> getLaunchAction();     // consumed on read
  Future<RingingAlarm?> getRinging();
  Future<int> alarmAction(String action /*start|snooze|dismiss|stop*/, int reminderId, int occurrenceMs);  // returns snoozes left
  Future<List<AlarmEvent>> getEvents(int sinceMs);
  Future<NativeStatus> getStatus();
  Future<bool> requestNotificationPermission();
  Future<bool> openSettings(String page /*exact_alarm|full_screen|battery|battery_request|notifications|app_details*/);
  Future<String> getTimezone();
  Stream<Map<String, dynamic>> get events;    // {"type":"ringing",...RingingAlarm} | {"type":"stopped","reminder_id","occurrence_ms","reason"} | {"type":"launch",...AlarmLaunch}
                                              // long-lived broadcast stream; subscriptions survive reattachEvents()
  void reattachEvents();                      // re-sends 'listen' after a MissingPluginException (headless engine); call on resume
}
class MethodChannelNativeBridge implements NativeBridge   // JSON maps use snake_case keys exactly as below
class FakeNativeBridge implements NativeBridge           // in-memory; for tests & non-Android
```
Method names / args (snake_case keys): `sync_reminders {reminders:[reminder]}` → `[scheduled]`; `get_scheduled` → `[scheduled]`;
`schedule_test {seconds,label,routine_id}` → trigger_at_ms; `get_launch_action` → launch|null; `get_ringing` → ringing|null;
`alarm_action {action,reminder_id,occurrence_ms}` → snoozes_left; `get_events {since_ms}` → `[event]`; `get_status` → status;
`request_notification_permission` → bool; `open_settings {page}` → bool; `get_timezone` → String.
Reminder dict: `{"id","label","hour","minute","weekdays":[1..7],"enabled","routine_id","routine_name","snooze_minutes","max_snoozes",
"nag_enabled","nag_every_minutes","nag_max_times","ring_seconds","vibrate","sound"}`.
scheduled: `{"reminder_id","weekday","kind","trigger_at_ms","exists"}`; ringing: `{"reminder_id","occurrence_ms","routine_id","label","kind",
"snoozes_used","max_snoozes","started_ms"}`; launch: `{"action","reminder_id","occurrence_ms","routine_id","label","kind"}` (+ `"created_ms"`
from `get_launch_action`); event: `{"reminder_id","occurrence_ms","event","at_ms","label"}`; status keys = snake_case of NativeStatus fields.

Event/launch rules: `ringing` is emitted for every ring, including snooze/nag re-rings of the same occurrence (same occurrence_ms, new
started_ms). `stopped` is emitted whenever a ring ends for any reason (in-app or notification action): reason
`auto_stopped|snoozed|dismissed|started|stopped|replaced` (`stopped` = stop action / swiped notification, `replaced` = another alarm started
ringing; both, like auto_stopped, end as missed + nag). A launch is emitted as a `launch` event when Dart is listening, otherwise stored in the
mailbox; `get_launch_action` drops entries older than 15 min and a `ring` entry whose occurrence is no longer ringing. Dart calls `get_ringing`
after the launch on cold start and on every resume and opens the ring screen unless that ring (reminder_id, occurrence_ms, started_ms) is
already shown. A refused snooze (cap reached) returns 0 and the ring continues, so Dart checks `get_ringing` after a snooze.

Kotlin behaviour: one `AlarmManager.setAlarmClock` per (enabled reminder, weekday) at the next local occurrence (java.time, same DST rules as
schedule.dart); request codes main `id*10+weekday`, snooze `id*10+8`, nag `id*10+9`, test 999990. When a main alarm fires: schedule next week
first, then ring. Ringing = foreground service (type systemExempted on API 34+), looping `res/raw/alarm_tone` on USAGE_ALARM, vibration,
partial wake lock, full-screen notification (label + time) with actions Start reciting (activity PendingIntent, extras), Snooze (hidden when
exhausted), Dismiss. MainActivity shows over lock screen when launched for an alarm. Auto-stop after ring_seconds → persistent "Missed — tap to
start" notification + nag re-ring every nag_every_minutes up to nag_max_times if nag_enabled. Start/Dismiss stop ringing, cancel snooze/nag, log.
Store = device-protected (direct boot) SharedPreferences JSON (reminders, occurrence state, launch mailbox, event log capped 500); the
receivers and RingService are directBootAware. Receivers reschedule on BOOT_COMPLETED,
LOCKED_BOOT_COMPLETED, TIME_SET, TIMEZONE_CHANGED, MY_PACKAGE_REPLACED, SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED.

`lib/core/alarm/alarm_service.dart`: `class AlarmService { AlarmService(Ref ref);  // or explicit deps
  Future<SyncResult> sync(String reason);   // builds reminder dicts (routine names), syncReminders, compares getScheduled() with
                                             // schedule.dart expectations (enabled reminder×weekday must exist), re-syncs once on mismatch
  Future<List<AlarmEvent>> ingestEvents();  // getEvents(0) (whole native log, ≤500) → AlarmEventRepository (unique-index dedupe)
  Future<MissedAlarm?> missedBanner(DateTime now);   // latest occurrence within 90 min with rang/auto_stopped/nag_rang and no started/dismissed
  SyncResult? get lastSync; }`  `class SyncResult { bool ok; int expected, scheduled; List<String> mismatches; DateTime at; }`
  `class MissedAlarm { int reminderId; int occurrenceMs; String label; int? routineId; }`

## 8. Audio — `lib/core/audio/dua_player.dart` [UI-2]
`class DuaPlayer { Stream<int?> get currentIndexStream; Stream<bool> get playingStream; Stream<int> get passCompletedStream; // emits after each full pass
  Future<void> playFiles(List<String> paths, {int repeat=1, double speed=1.0, String title='', String? subtitle});
  Future<void> pause(); Future<void> resume(); Future<void> stop(); Future<void> setSpeed(double s); Future<void> dispose(); }`
Uses just_audio playlist + just_audio_background MediaItem tags (lock-screen controls, plays with screen off). TTS fallback uses flutter_tts
("Not a reciter" label) inside recite screen.

## 9. Startup (`main.dart` / `app.dart`)
main: `WidgetsFlutterBinding.ensureInitialized(); await JustAudioBackground.init(androidNotificationChannelId: 'com.dailyduas.audio', androidNotificationChannelName: 'Recitation audio', androidNotificationOngoing: true);`
open DB, seedIfEmpty, load settings, tz.initializeTimeZones() + setLocalLocation(getTimezone()), runApp(ProviderScope(overrides: [...], child: DailyDuasApp())).
App: if launch action ring → AlarmRingScreen; start → ReciteScreen; else onboarding (if !onboardingDone) or RootShell. Listen to bridge events
(ringing → openAlarm; launch start → openRecite). On resume (AppLifecycleState.resumed): reattachEvents, getLaunchAction, getRinging,
getTimezone (re-apply local zone), alarmService.sync('resume'), ingestEvents, invalidate home data. After startup: getLaunchAction, getRinging,
sync('app_start'), ingestEvents.
