# Alarm + notification architecture (Flutter, Android) — research and decision

Status: decided. Researched 2026-10-06 against pub.dev, the published package archives (source read line by line), GitHub issues, developer.android.com and AOSP `main` sources.
Scope: Android only. iOS is secondary and not built (see section 3.1.9 and section 9).

Legend: **[V]** verified in source code or official docs (link given). **[V-src]** verified by reading the package source in the pub.dev archive. **[U]** unverified, from memory or inferred. Test it on the device before relying on it.

---

## 0. Decision (TL;DR)

**Option C: a custom Kotlin "alarm engine" in `android/app/src/main/kotlin/...`** that talks to Dart over one `MethodChannel` and one `EventChannel`. Do not add `alarm`, `flutter_local_notifications`, `timezone` or `flutter_timezone` for the alarm path.

Why:

1. **Every required action has to work while no Flutter engine is running.** Snooze with a cap, Dismiss that cancels today's nags, auto-stop that leaves a persistent "missed" notification, and nag re-rings all run as plain Kotlin in C. In A, the `alarm` package can only stop or snooze (with no cap). In B, `flutter_local_notifications` (FLN) has to cold-start a headless Flutter engine from a `BroadcastReceiver` without `goAsync()` for every Snooze or Dismiss.
2. **Weekly re-arm, time zone changes, DST and reboot need native code that recomputes local wall-clock times.** `alarm` has no weekly repeat (issue #47, open since 2023) and no time-zone handling (issue #164, open). FLN repeats weekly natively but keeps the IANA zone that was current at schedule time. It has no `TIMEZONE_CHANGED` handling, and on boot it rings stale occurrences immediately.
3. **Two required behaviours are impossible in B without "re-arming" from Dart:**
   - nags "until confirmed" that can be skipped for today. A weekly `matchDateTimeComponents` notification cannot skip one occurrence: re-scheduling it recomputes from *now*, so a nag later today is re-armed for today. **[V-src]**
   - a hook when a scheduled notification is shown. There isn't one (FLN issue #2825, open).
4. **B's sound model is the notification channel with `FLAG_INSISTENT`.** That sound stops as soon as the user opens the notification shade. AOSP `onPanelRevealed` calls `clearAttentionEffects()` **[V]**. The sound is also subject to Android 16 notification cooldown, which is enabled by default and applies to all apps in AOSP `main` **[V]**. A foreground service that plays a `MediaPlayer` on `USAGE_ALARM` has neither problem.
5. **The previous architecture already specified C** (`ARCHITECTURE.md` section 7: setAlarmClock, ring FGS, three actions, auto-stop, nags, boot/time receivers). Moving from Flet to Flutter makes C easier: Kotlin lives in the app module, and `MainActivity` talks to Dart directly.
6. **The cost is about 1,000–1,200 lines of Kotlin plus about 250 lines of Dart bridge.** Behaviour is deterministic and unit-testable: the next-occurrence calculator is pure `java.time`. The code depends on no third-party package that changes every week. `alarm` shipped 8 releases between 2026-09-10 and 2026-10-05, including fixes for "alarms unstoppable in production" (#437) and "setAlarmClock instead of setExactAndAllowWhileIdle" (#439, 5.14.0, 4 days old).

### Requirement coverage

| Required behaviour | A: `alarm` 5.15.0 | B: FLN 22.3.1 | **C: custom Kotlin** |
|---|---|---|---|
| Weekly per-weekday exact alarm, no re-arming from Dart | No. One-shot only. Needs a rolling window re-armed on every app open (#47) | Yes. `dayOfWeekAndTime` is re-armed natively after each fire **[V-src]** | **Yes.** Receiver re-arms next week before ringing |
| Looping sound on alarm volume, vibration, full screen over the lock screen | Yes. `MediaPlayer` `USAGE_ALARM` in a `mediaPlayback` FGS **[V-src]** | Partly. Insistent channel sound with `USAGE_ALARM`. Stops when the shade opens. Channel sound is immutable. A user-picked file needs a content URI grant to SystemUI | **Yes** |
| "Start reciting" opens the app straight into the routine | Only the notification tap or full-screen intent opens the app. Buttons are Stop and Snooze only **[V-src]** | Yes. `showsUserInterface: true` action | **Yes.** Activity `PendingIntent` |
| Snooze N min, max M | Partly. Native snooze, **no max**. Button is always shown **[V-src]** | Partly. Background Dart engine schedules the snooze; engine must boot first | **Yes.** Counter stored natively; button hidden when used up |
| Dismiss (skip today) | Partly. Stop works, but pre-scheduled nags still ring because Dart is not running | Partly. Same problem with weekly nags | **Yes** |
| Auto-stop after 2 min, leaving a persistent notification | No (#390 open). Hack: a non-looping 2-minute audio file plus `keepNotificationAfterAlarmEnds`, which leaves a silent notification with no actions | Partly. `timeoutAfter: 120000`. AOSP sends `deleteIntent` on timeout **[V]**, so the `dismissIsolate` background callback could post the "missed" notification, again through a headless engine | **Yes.** `Handler` inside the FGS |
| Nag every K min, up to J times, until confirmed | Partly. Pre-scheduled one-shots that are not cancelled when dismissed from the notification | No. See point 3 above | **Yes** |
| Reboot | Yes. `BOOT_COMPLETED` only; stale after 15 min **[V-src]** | Yes. `BOOT_COMPLETED`, `MY_PACKAGE_REPLACED`, `QUICKBOOT`. Stale occurrences fire immediately. ANR risk (#2829) | **Yes.** Also `LOCKED_BOOT_COMPLETED` (direct boot) |
| Time zone or clock change | No (#164) | No. Old zone kept until Dart re-schedules | **Yes.** `TIMEZONE_CHANGED` and `TIME_SET` |
| DST | Yes. Absolute instants are computed with zone rules | Yes. `ZonedDateTime` | **Yes.** `ZonedDateTime` |
| App update | Yes. AOSP keeps alarms on replace **[V]** | Yes | **Yes**, plus `MY_PACKAGE_REPLACED` as a safety net |
| "Test alarm in 10 s" | Yes | Yes | **Yes** |
| Reliability status checks | Needs another plugin | Partly. No `canUseFullScreenIntent` getter. `pendingNotificationRequests()` reads the plugin cache and has no trigger times **[V-src]** | **Yes.** Anything we want |
| Works with no Flutter engine | Stop and snooze only | No. Snooze and Dismiss need a headless engine | **Yes. Everything** |

---

## 1. Environment baseline (verified locally)

- Flutter SDK at `D:\DuasSDK\home\flutter\3.44.8`, Dart **3.12.2** (`bin/cache/dart-sdk/version`).
- Flutter Gradle defaults (`packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt`): `compileSdkVersion = 36`, `minSdkVersion = 24`, `targetSdkVersion = 36`, `ndkVersion = "28.2.13676358"`.
- Project `D:\Coding\Python\duas app\android`, already generated from the 3.44.8 template:
  - AGP **9.0.1**, Kotlin Gradle plugin **2.3.20**, Gradle **9.1.0**.
  - `android.builtInKotlin=false` and `android.newDsl=false`.
  - Namespace and applicationId are `com.dailyduas.daily_duas`.
  - `MainActivity : FlutterActivity()` with `launchMode="singleTop"` and `taskAffinity=""`.
- `androidx.core:core` / `core-ktx` AAR metadata **[V]** (read from Google Maven):
  - 1.17.0 and 1.18.0: `minCompileSdk=36`, AGP ≥ 8.9.1.
  - **1.19.1: `minCompileSdk=37`, AGP ≥ 9.1.0.** Pin `core-ktx:1.18.0` while compileSdk is 36.
- `com.android.tools:desugar_jdk_libs` latest is **2.1.5** **[V]** (maven-metadata.xml). FLN's README still says 2.1.4.

---

## 2. Android platform facts that drive the design

1. **`setAlarmClock()` is the most privileged alarm.** In AOSP `AlarmManagerService` (main) **[V]**:
   - `if (alarmClock != null) { flags |= FLAG_WAKE_FROM_IDLE; windowLength = 0; }`, so it is exact and wakes the device from Doze.
   - `isExemptFromAppStandby()` returns true for `a.alarmClock != null`, so App Standby buckets (including "restricted") do not apply.
   - `isExemptFromBatterySaver()` returns true for `alarmClock != null`.
   - Delivery grants `TEMPORARY_ALLOW_LIST_TYPE_FOREGROUND_SERVICE_ALLOWED` with `REASON_ALARM_MANAGER_ALARM_CLOCK`, so the receiver may start a foreground service from the background.
   - `setExactAndAllowWhileIdle` has a quota (`DEFAULT_ALLOW_WHILE_IDLE_QUOTA = 72` per hour, compat quota 7) **[V]**.
   - The docs say alarm clocks are "the most critical ones" and the system "leaves low-power modes if necessary" **[V]** (developer.android.com/develop/background-work/services/alarms).
2. **Exact-alarm permission.**
   - `USE_EXACT_ALARM` is granted on install, cannot be revoked by the user, and needs targetSdk 33 or higher. Play only allows it for alarm-clock and calendar apps. It does not matter for a sideloaded APK.
   - `SCHEDULE_EXACT_ALARM` is denied by default for new installs on Android 14+ (targetSdk ≥ 33) unless the app is an alarm or calendar app **[V]**.
   - When `SCHEDULE_EXACT_ALARM` is revoked, the app is killed and all its future exact alarms are cancelled. Granting it sends `ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED` **[V]**.
   - Android 12/12L (API 31–32) has no `USE_EXACT_ALARM`. There `SCHEDULE_EXACT_ALARM` was pre-granted **[U, widely documented]**.
3. **Alarm persistence.**
   - All alarms are cleared on shutdown **[V docs]**.
   - On app update they are **kept**. AOSP `ACTION_PACKAGE_REMOVED` with `EXTRA_REPLACING` reads: `// This package is being updated; don't kill its alarms.` **[V]**. AOSP then re-checks exact-alarm permission after the update (`CHECK_EXACT_ALARM_PERMISSION_ON_UPDATE`).
   - **Force-stop (`ACTION_PACKAGE_RESTARTED`) removes all alarms** **[V]**, and a force-stopped app receives no broadcasts, `BOOT_COMPLETED` included, until the user opens it. Some OEMs (MIUI, some ColorOS and EMUI builds) treat "swipe from recents" as force-stop **[U]**. This is the one failure no architecture can fix. It is covered by the battery-optimisation and autostart guidance in the reliability screen.
4. **Implicit-broadcast exceptions** **[V]**. Manifest receivers still get `BOOT_COMPLETED`, `LOCKED_BOOT_COMPLETED`, `TIME_SET` and `TIMEZONE_CHANGED` ("Clock apps might need to receive these broadcasts to update alarms when the time, timezone, or alarms change"). `MY_PACKAGE_REPLACED` is sent explicitly to the app.
5. **Foreground-service background-start exemptions** **[V]** (restrictions-bg-start): exact alarm, `BOOT_COMPLETED` / `LOCKED_BOOT_COMPLETED` / `MY_PACKAGE_REPLACED`, `TIMEZONE_CHANGED` / `TIME_CHANGED`, "user turns off battery optimizations for your app", and "service starts by interacting with a notification".
6. **Android 15: `BOOT_COMPLETED` receivers may not start these FGS types:** `dataSync`, `camera`, **`mediaPlayback`**, `phoneCall`, `mediaProjection`, `microphone` **[V]** (behavior-changes-15). The `alarm` package found that during the ~20 s boot allowlist window this also refuses a normal alarm-triggered `mediaPlayback` start (alarm #424). It works around it by re-arming 30 s later **[V-src]**.
7. **FGS type `systemExempted`** **[V]** (fgs/service-types):
   - Permission `FOREGROUND_SERVICE_SYSTEM_EXEMPTED`; no runtime prerequisites.
   - Allowed for "Apps holding `SCHEDULE_EXACT_ALARM` or `USE_EXACT_ALARM` permission". Otherwise the system throws `ForegroundServiceTypeNotAllowedException`.
   - Not in the Android 15 boot blocklist.
   - Play requires FGS-type declarations for targetSdk ≥ 34. This does not apply to a sideloaded build.
8. **Android 17 background-audio hardening** **[V]** (about/versions/17/changes/bg-audio):
   - On **all apps** running on Android 17, background audio (playback, focus requests, volume calls) needs a visible activity or a foreground service that is not `shortService`.
   - Apps that **target** 37 additionally need a while-in-use (WIU) FGS. Verbatim: "the requirement for WIU capabilities is waived if the app has been granted the exact alarm permission, and it is making changes to audio streams that have the `USAGE_ALARM` attribute".
   - Failures are silent: playback is muted and volume calls are ignored.
   - So the ring must be FGS + `USAGE_ALARM` + `USE_EXACT_ALARM`. C does exactly that.
   - Watch out: the `alarm` package switches to `USAGE_MEDIA` when `preferConnectedAudioDevice: true` **[V-src]**, which would lose the waiver at targetSdk 37.
9. **Full-screen intents (FSI)** **[V]** (source.android.com fsi-limits):
   - On Android 14+ the permission is "enabled by default" at install. "Google Play Store revokes" it for apps without calling or alarm features. A sideloaded APK should therefore keep it **[U for sideload, inferred]**.
   - Check with `NotificationManager.canUseFullScreenIntent()` and request with `Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT`.
   - Without the permission the user gets a persistent heads-up notification with buttons.
   - When the screen is on and unlocked, Android shows a heads-up notification instead of launching the activity. This is by design.
10. **Notification trampolines (targetSdk ≥ 31)** **[V]**: "after the user taps on a notification, or an action button ... your app cannot call startActivity() inside of a service or broadcast receiver". So "Start reciting" must be `PendingIntent.getActivity(...)` directly.
11. **Notification sound internals** (for option B) **[V]** (AOSP `NotificationAttentionHelper` / `NotificationManagerService`, main):
    - `FLAG_INSISTENT` (value 4) loops the sound. Docs: "until the notification is cancelled or the notification window is opened". Opening the shade calls `clearAttentionEffects()`.
    - While an insistent sound plays, other notifications are muted (`MUTE_REASON_OTHER_INSISTENT_PLAYING`).
    - Notification cooldown: `DEFAULT_NOTIFICATION_COOLDOWN_ENABLED = 1` and `DEFAULT_NOTIFICATION_COOLDOWN_ALL = 1`, behind the `politeNotifications` flag. It lowers or mutes successive alerts from the same app.
    - `timeoutAfter` cancels with `REASON_TIMEOUT` and `sendDelete=true`, so the `deleteIntent` fires. Notifications with `FLAG_FOREGROUND_SERVICE` are excluded from timeout.

---

## 3. Package research

### 3.1 `alarm` (gdelataillade) — evaluated, **not recommended**

- **Latest: 5.15.0** (published 2026-10-05) **[V]** https://pub.dev/packages/alarm — API JSON https://pub.dev/api/packages/alarm
- **Constraints:** `sdk: ">=3.0.0 <4.0.0"`, `flutter: ">=3.41.0"`. Compatible with Flutter 3.44.8 / Dart 3.12.2.
  - Dependencies: `flutter_fgbg ^0.8.0`, `rxdart ^0.28.0`, `shared_preferences ^2.5.4`, `equatable`, `json_annotation`, `logging`, `collection`, `plugin_platform_interface`.
  - Plugin build: compileSdk 35, minSdk 19, Java/Kotlin 17, Kotlin 2.2.20, kotlinx-serialization. The install doc asks for app `minSdkVersion 23`, Kotlin ≥ 2.0.0, and for AGP 9 `android.builtInKotlin=false` / `android.newDsl=false` (our template already has these).
- **Breaking changes:**
  - 5.0.0: `volumeSettings` and `notificationSettings` are required; parameters were renamed.
  - 5.5.0: requires Flutter 3.41.
  - **5.9.0: `Alarm.set()` throws `AlarmException` on failure** (it used to return true).
  - 5.11.0: alarms more than 15 min stale at boot are discarded (`androidStaleAfter`).
  - 5.12.0: `Alarm.snoozed` deprecated in favour of `Alarm.events`.
  - **5.14.0: arms with `AlarmManager.setAlarmClock`** (`androidAlarmClock: true` default). Before that it used `setExactAndAllowWhileIdle`, which Doze rate-limits (#439).
  - 5.15.0: a non-looping alarm now stops when its audio ends.

#### 3.1.1 API (5.15.0, verified from `lib/alarm.dart` and models)

```dart
await Alarm.init();                       // also reconciles: re-sets future alarms, stops past ones (>30 s grace)
await Alarm.set(alarmSettings: AlarmSettings(
  id: 4201,                               // != 0, != -1, 32-bit
  dateTime: next,                         // absolute instant, one-shot
  assetAudioPath: 'assets/audio/alarm.mp3', // 'assets/...' -> flutter_assets via openFd; relative -> <data>/app_flutter/; absolute path as is; null -> system default alarm sound
  loopAudio: true,                        // default true
  vibrate: true,                          // default true
  warningNotificationOnKill: false,       // default true (meant for iOS)
  androidFullScreenIntent: true,          // default true
  allowAlarmOverlap: false,               // default false: a second alarm while one rings is dropped (or queued if allowSameSecondScheduling)
  allowSameSecondScheduling: false,       // default false: same-second alarms replace each other
  androidStopAlarmOnTermination: false,   // default TRUE: swiping the task away stops a ringing alarm
  preferConnectedAudioDevice: false,      // true -> USAGE_MEDIA (loses Android 17 alarm waiver)
  androidSnoozeDuration: const Duration(minutes: 5), // >= 1 min, else no snooze
  androidStaleAfter: const Duration(minutes: 15),    // default 15 min; null = ring however late at boot
  androidAlarmClock: true,                // default true (5.14.0+)
  payload: '{"reminderId":42,"routineId":1}',
  volumeSettings: const VolumeSettings.fixed(volume: null, volumeEnforced: false), // also .fade(fadeDuration:..), .staircaseFade(fadeSteps:[VolumeFadeStep(t, v)])
  notificationSettings: const NotificationSettings(
    title: 'Morning duas', body: 'Time to recite',
    stopButton: 'Dismiss',                // null = no button
    androidSnoozeButton: 'Snooze',        // needs androidSnoozeDuration
    icon: 'ic_stat_alarm',                // drawable name, resolved with getIdentifier (keep it in keep.xml)
    iconColor: Color(0xFF2E7D32),
    keepNotificationAfterAlarmEnds: false,
    androidStopAlarmOnDismiss: false,     // default true: swipe = stop
  ),
));
Alarm.ringing.listen((AlarmSet s) { for (final a in s.alarms) { /* a.id, a.payload */ } }); // rxdart ValueStream
Alarm.scheduled.listen((AlarmSet s) {});
Alarm.events.listen((AlarmEvent e) { switch (e) { case AlarmMoved(): break; case AlarmDropped(): break; } });
await Alarm.stop(4201);  await Alarm.stopAll();
final List<AlarmSettings> all = await Alarm.getAlarms();
final bool ringing = await Alarm.isRinging(4201);   // or isRinging() for "any"
```

#### 3.1.2 Manifest (the plugin merges these) **[V-src]**

- Permissions: `RECEIVE_BOOT_COMPLETED`, `WAKE_LOCK`, `VIBRATE`, `USE_FULL_SCREEN_INTENT`, `FOREGROUND_SERVICE`, `ACCESS_NOTIFICATION_POLICY`, `POST_NOTIFICATIONS`, `READ_EXTERNAL_STORAGE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, `USE_EXACT_ALARM`, `SCHEDULE_EXACT_ALARM`.
- `AlarmReceiver` (`exported="true"`, no intent filter). Any app can broadcast `ACTION_STOP` to it.
- `BootReceiver` (`BOOT_COMPLETED` only).
- `AlarmService` (`foregroundServiceType="mediaPlayback"`).
- Optional, if `warningNotificationOnKill` is used: `<service android:name="com.gdelataillade.alarm.services.NotificationOnKillService"/>`.

#### 3.1.3 Behaviour answers (from Android source)

- **Reboot without opening the app:** yes. `BootReceiver` re-arms stored alarms from native storage (`AlarmSharedPreferences`). Alarms more than `androidStaleAfter` (15 min) late are dropped and reported as `AlarmDropped(staleAtBoot)` on the next `init()`. It handles only `BOOT_COMPLETED`: no `LOCKED_BOOT_COMPLETED`, `TIME_SET`, `TIMEZONE_CHANGED` or `MY_PACKAGE_REPLACED`.
- **Killed or swiped away:**
  - Rings, because `AlarmReceiver` starts the FGS from the alarm broadcast.
  - If the task is swiped *while ringing*, `androidStopAlarmOnTermination` (default true) stops the ring.
  - An open issue (#391, Samsung, Android 15) reports the app UI popping up after reboot; not reproduced by the maintainer.
- **Notification actions:** Stop, plus Snooze from 5.7.0. Snooze is handled natively by `SnoozeCoordinator` and works with no engine running. It re-arms at now + `androidSnoozeDuration` and is **unbounded** (no max count). No custom actions.
- **Tap or full screen:**
  - Opens the launcher activity. Since 5.7.0 it opens any activity that declares the `com.gdelataillade.alarm.action.RING` filter, with extras `alarmId`, `alarmTitle`, `alarmBody`, `alarmStopLabel` and `alarmSnoozeLabel`.
  - Dart learns which alarm is ringing from `Alarm.ringing`, filled by `Alarm.init()` → `checkAlarm()` → native `getAlarmState(id)`.
  - Telling an alarm launch apart from a normal launch needs your own Kotlin `MethodChannel` (`help/DETECT-ALARM-LAUNCH-ANDROID.md`).
- **Audio:**
  - `MediaPlayer` with `USAGE_ALARM` / `CONTENT_TYPE_SONIFICATION` (5.3.0+).
  - `assets/...` is read through `context.assets.openFd("flutter_assets/...")`. Assets must be stored uncompressed; mp3 is not compressed by AAPT **[U]**.
  - If playback throws, the alarm is silent: there is no fallback to the default sound, and since `isRinging` derives from `MediaPlayer.isPlaying` it is also not "ringing".
  - The notification channel `alarm_plugin_channel` is `IMPORTANCE_HIGH` and silent.
  - Vibration uses `VibrationEffect.createWaveform([0,500,500], 1)` with no `USAGE_ALARM` attributes.
- **Max duration or auto-stop:** none (#390 open). It rings until stopped. The wake lock (5 min) is released on stop (5.13.4).
- **Reliability issues (last 12 months):**
  - #437 fatal NPE made alarms unstoppable (fixed 5.13.x).
  - #424 alarms within about 45 s of boot never rang on Android 15+ (fixed 5.10.0).
  - #418 stale alarm rang at boot (fixed 5.11.0).
  - #439 Doze rate-limited `setExactAndAllowWhileIdle` (fixed 5.14.0).
  - #452 wake-lock leak (fixed 5.13.4).
  - #454 queued alarm lost on task removal (fixed 5.13.5).
  - Still open: #358 "Unable to start alarm in background" (23 comments), #257 "screen does not turn on" (28 comments), #230 `ForegroundServiceDidNotStartInTimeException`, #391 UI pops up after reboot, #164 time zone, #390 auto-dismiss, #47 periodic.
- **iOS:** keeps the app alive with a silent `AVAudioPlayer` plus Background Fetch. It does not ring after reboot or after the user kills the app. The README points to `flutter_alarmkit` (0.4.1, iOS 26 AlarmKit) for robust iOS alarms.
- **ProGuard:** consumer rules are shipped (`-keep class com.gdelataillade.alarm.** { *; }`).
- **Verdict:** high-quality and actively fixed, but it is missing weekly repeat, time-zone handling, a snooze cap, auto-stop, a third action and engine-less nag cancellation. We would still need Kotlin glue for "Start reciting".

### 3.2 `flutter_local_notifications` (FLN) — evaluated, **not recommended for alarms**

- **Latest stable: 22.3.1** (2026-09-13) **[V]** https://pub.dev/packages/flutter_local_notifications.
  - Prerelease **23.0.0-dev.3** (2026-10-05) requires Flutter ≥ 3.44.0, Dart ^3.12.0, **compileSdk 37 and AGP 9.1.1**, and explicitly denies creator background-activity launches on Android 14+.
- **22.3.1 constraints:** `sdk: ^3.10.0`, `flutter: >=3.38.1`, `timezone ^0.11.0`. OK with Flutter 3.44.8.
  - Android library: compileSdk 36, minSdk 24, Java 17, `coreLibraryDesugaringEnabled true`, GSON 2.12. No ProGuard rules needed since v19.
  - **The app must enable core library desugaring even if it never schedules** (README).
- **Breaking changes:**
  - 18.0: `androidScheduleMode` required; `androidAllowWhileIdle` removed.
  - 19.0: compileSdk 35, desugar 2.1.4, `uiLocalNotificationDateInterpretation` removed.
  - **20.0: all positional parameters became named** (`initialize(settings:)`, `show(id:, ...)`, `zonedSchedule(id:, scheduledDate:, notificationDetails:, androidScheduleMode:)`, `cancel(id:)`).
  - **21.0: Flutter 3.38.1, Dart 3.10, Android minSdk 24, compileSdk 36.**
  - 22.2.0: dismissal callbacks (`dismissIsolate`).
  - 22.3.0: `openAppNotificationSettings()`.
- **Manifest the app must add (README):**

```xml
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
<uses-permission android:name="android.permission.USE_EXACT_ALARM"/>   <!-- or SCHEDULE_EXACT_ALARM + requestExactAlarmsPermission() -->
<uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT"/>
<application>
  <activity android:name=".MainActivity" android:showWhenLocked="true" android:turnScreenOn="true" .../>
  <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver"/>
  <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
    <intent-filter>
      <action android:name="android.intent.action.BOOT_COMPLETED"/>
      <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
      <action android:name="android.intent.action.QUICKBOOT_POWERON"/>
      <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>
    </intent-filter>
  </receiver>
  <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver"/>
</application>
```

- **Gradle (app):** `isCoreLibraryDesugaringEnabled = true`, `coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")` (2.1.5 is the latest), `multiDexEnabled = true`. The README also suggests `androidx.window:window` if desugaring crashes on 12L+ (Flutter #110658).

#### 3.2.1 API used in option B (22.3.1 signatures verified)

```dart
final fln = FlutterLocalNotificationsPlugin();
await fln.initialize(
  settings: const InitializationSettings(android: AndroidInitializationSettings('ic_stat_alarm')),
  onDidReceiveNotificationResponse: onForegroundResponse,               // taps + showsUserInterface actions
  onDidReceiveBackgroundNotificationResponse: notificationBackground,   // other actions, in a NEW headless engine
);
final launch = await fln.getNotificationAppLaunchDetails();            // didNotificationLaunchApp, notificationResponse
final android = fln.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()!;
await android.requestNotificationsPermission();      // POST_NOTIFICATIONS (33+)
await android.requestExactAlarmsPermission();        // opens ACTION_REQUEST_SCHEDULE_EXACT_ALARM
await android.requestFullScreenIntentPermission();   // opens ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT if !canUseFullScreenIntent()
final exact = await android.canScheduleExactNotifications();
final enabled = await android.areNotificationsEnabled();

final details = AndroidNotificationDetails('ring_v1', 'Alarms',
  importance: Importance.max, priority: Priority.max,
  category: AndroidNotificationCategory.alarm,
  fullScreenIntent: true,
  audioAttributesUsage: AudioAttributesUsage.alarm,          // channel audio attrs (immutable after creation)
  sound: const RawResourceAndroidNotificationSound('alarm_tone'),
  additionalFlags: Int32List.fromList(<int>[4]),            // FLAG_INSISTENT
  ongoing: true, autoCancel: false,
  timeoutAfter: 120000,                                      // ms; auto-cancel also stops the insistent sound
  visibility: NotificationVisibility.public,
  dismissIsolate: NotificationDismissedIsolate.background,   // deleteIntent -> background callback (also on timeout, see section 2)
  actions: const <AndroidNotificationAction>[
    AndroidNotificationAction('start', 'Start reciting', showsUserInterface: true), // activity PendingIntent; main isolate
    AndroidNotificationAction('snooze', 'Snooze'),            // broadcast -> ActionBroadcastReceiver -> headless engine
    AndroidNotificationAction('dismiss', 'Dismiss'),          // cancelNotification: true (default) cancels natively first
  ]);
await fln.zonedSchedule(
  id: 4201, scheduledDate: nextMonday0500 /* tz.TZDateTime */,
  notificationDetails: NotificationDetails(android: details),
  androidScheduleMode: AndroidScheduleMode.alarmClock,     // also: exact, exactAllowWhileIdle, inexact, inexactAllowWhileIdle
  matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
  title: 'Morning duas', body: 'Time to recite', payload: '{"reminderId":42}');
final pending = await fln.pendingNotificationRequests(); // id/title/body/payload from the plugin's cache, NO trigger time

@pragma('vm:entry-point')
void notificationBackground(NotificationResponse r) {
  // Runs in a separate FlutterEngine started by ActionBroadcastReceiver (plugins auto-registered).
  // Could call FlutterLocalNotificationsPlugin().zonedSchedule(... one-shot snooze ...).
}
```

#### 3.2.2 Behaviour answers **[V-src]**

- **`alarmClock` mode** uses `AlarmManagerCompat.setAlarmClock(am, t, pendingIntent, pendingIntent)`. The *show intent* is the broadcast itself, so tapping the next-alarm tile in Quick Settings **fires the notification** (issue #2726, closed as "not related").
- **Missing permission:** `alarmClock`, `exact` and `exactAllowWhileIdle` throw `ExactAlarmPermissionException` without exact permission. On reboot that exception **removes the notification from the plugin cache permanently**.
- **Weekly repeat:** after each fire, `ScheduledNotificationReceiver` shows the notification and then calls `scheduleNextNotification()` → `getNextFireDateMatchingDateTimeComponents()`. The weekly repeat works with the app killed.
- **Time zone:** `zonedSchedule` with `matchDateTimeComponents` **recomputes the date from now** (native `zonedSchedule()` overwrites `scheduledDateTime`). The zone stored is the `TZDateTime`'s location name. There is no `TIMEZONE_CHANGED` receiver.
- **Boot:** `rescheduleNotifications()` re-arms the *stored* `scheduledDateTime`. An occurrence missed while the phone was off fires immediately at boot.
  - The boot receiver runs synchronously on the main thread; issue #2829 (open, 2026-09-19) reports an ANR in production.
- **Background action handler (Snooze/Dismiss with the app killed):**
  - `ActionBroadcastReceiver.onReceive` first cancels the notification natively when `cancelNotification` is true (this stops the insistent sound).
  - It then calls `loader.ensureInitializationComplete()` and **creates a `FlutterEngine` on the main thread, without `goAsync()`**, and runs the registered `@pragma('vm:entry-point')` callback.
  - Dart *can* call `zonedSchedule` there, but the process has no foreground component while the engine boots (about 1–3 s), so an aggressive OEM can kill it **[U, inferred from code]**.
  - The engine is static and never destroyed. Drift streams in the UI engine will not see writes from that engine.
- **No "notification shown" callback** for scheduled notifications (#2825 open).
- **`timeoutAfter`** maps to `NotificationCompat.Builder.setTimeoutAfter(ms)`.
- **Recent issues:** #2737 (scheduled notifications unreliable when the app is terminated on real devices; a comment points to Android "Notification Cooldown"), #2821 (zonedSchedule not firing when closed), #2795 (background-activity-launch modes, addressed in 23.0.0-dev.3).
- **Verdict:** excellent for ordinary reminders. As an alarm clock, the sound stops when the shade opens, Snooze and Dismiss depend on a headless engine, and nags or "missed" notifications cannot be skipped for today without re-arming from Dart.

### 3.3 `timezone` and `flutter_timezone`

- **`timezone` 0.11.1** (2026-06-29) **[V]** https://pub.dev/packages/timezone
  - `sdk: ^3.10.0`; depends on `http ^1.6.0`, `path`. IANA DB 2025c.
  - Breaking in 0.11.0: `offset` became a `Duration` (was int ms); the package moved to dart-lang/labs. 0.11.1: the default local location is `Etc/UTC`.

  ```dart
  import 'package:timezone/data/latest_all.dart' as tzdata;   // 'all' variant includes link names like Asia/Calcutta
  import 'package:timezone/timezone.dart' as tz;
  tzdata.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation(id));      // throws LocationNotFoundException for unknown ids
  final now = tz.TZDateTime.now(tz.local);
  ```

- **`flutter_timezone` 5.1.1** (2026-10-03) **[V]** https://pub.dev/packages/flutter_timezone
  - `sdk: >=3.4.0 <4.0.0`, `flutter: >=3.22.0`; Android minSdk 21, compileSdk 35. AGP 9 support since 5.1.0.
  - **Breaking 5.0.0: `getLocalTimezone()` returns `TimezoneInfo`**, not a `String`.

  ```dart
  final TimezoneInfo info = await FlutterTimezone.getLocalTimezone();     // optional [String? locale]
  final String iana = info.identifier;                // e.g. "Asia/Karachi"
  final ({String name, String locale})? pretty = info.localizedName;
  final List<TimezoneInfo> all = await FlutterTimezone.getAvailableTimezones();
  ```

- **With option C neither package is needed.** Kotlin computes occurrences with `java.time` and `ZoneId.systemDefault()` and returns epoch-ms trigger times. Dart shows them with `DateTime.fromMillisecondsSinceEpoch(ms)` (local). `getStatus()` returns the zone id. Add these packages only if some other feature needs zone-aware maths in Dart.

---

## 4. Architecture comparison and recommendation

| Criterion | A `alarm` | B FLN | C custom Kotlin |
|---|---|---|---|
| Action buttons with no engine | Stop and Snooze only | Needs a headless engine (no `goAsync`) | **All native** |
| Time-zone change | Not handled | Old zone kept | **Recomputed on `TIMEZONE_CHANGED`** |
| Missed while device off | Dropped after 15 min | Rings immediately at boot | **Our policy:** ring if ≤ 10 min late, else post "missed" |
| Direct boot (reboot overnight, not unlocked yet) | No | No | **Yes**, with `directBootAware` and device-protected prefs |
| Sound engine | `MediaPlayer` `USAGE_ALARM` (FGS `mediaPlayback`) | System notification sound (insistent); shade-open stops it; cooldown | **`MediaPlayer` `USAGE_ALARM` in FGS `systemExempted`** (API 34+), `mediaPlayback` on API 29–33 |
| Testability | Black box; Dart reconciliation is complex | Dart unit tests only; behaviour lives in a plugin | **JUnit tests for the pure calculator and state machine; Dart fake bridge** |
| Code we own | ~300 Dart + ~80 Kotlin glue + workarounds | ~400 Dart | **~1,000–1,200 Kotlin + ~250 Dart** |
| Upgrade risk | Very active churn | Major release every few months; 23.x needs compileSdk 37 | **None from third parties** |
| Play policy (n/a for sideload) | `mediaPlayback` FGS, FSI, `USE_EXACT_ALARM` | FSI, exact alarm | `systemExempted` FGS needs a Play declaration; FSI; `USE_EXACT_ALARM` (alarm-clock apps qualify) |

**Recommendation: C.** Keep FLN in mind only if the app ever needs ordinary non-alarm notifications. If it is added, enable desugaring.

---

## 5. Recommended design (C) in detail

### 5.1 Responsibilities

- **Dart (source of truth for user data, in Drift):**
  - Reminders: label, time, ISO weekdays, routine, snooze minutes and max, nag interval and max, ring seconds, vibrate, sound.
  - Session logs and history.
  - Dart pushes the full reminder list to native with `syncReminders` whenever reminders change and on every app start or resume. It ingests native events into Drift and routes launch actions.
- **Kotlin (source of truth for armed alarms and ring state):**
  - Stores a copy of the reminder list in **device-protected `SharedPreferences`**, plus per-occurrence state and an event log.
  - Owns `AlarmManager`, the ring FGS, notifications and the boot/time receivers.
  - Never needs Dart to make a decision.

### 5.2 Identity and request codes

- PendingIntent identity uses `Intent.filterEquals` (action, **data**, type, class, categories); extras are ignored. Make each alarm unique with a **data URI**: `dailyduas://alarm/{kind}/{reminderId}/{weekday}`, with kind in main, snooze, nag, test.
  - Main: one per (reminder, weekday).
  - Snooze and nag: one per reminder (only one can be pending).
  - Test: reminderId -1.
- Extras: `reminderId`, `kind`, `weekday`, `occurrenceMs`. `occurrenceMs` is the main occurrence the snooze or nag belongs to.
- Notification ids:
  - Ring: one FGS notification, id 1001 (only one alarm rings at a time; a newer ring supersedes an older one, which becomes "missed").
  - Missed: `20000 + reminderId`.

### 5.3 Flows

1. **`syncReminders(list)`**
   - Save the list.
   - For each enabled reminder and each of its weekdays: `trigger = NextOccurrence.nextForWeekday(h, m, wd, now)`, then `arm(main, rid, wd, trigger, occurrenceMs = trigger)`.
   - Cancel main alarms for removed weekdays and reminders, and for disabled reminders (also their snooze and nag).
   - Return `scheduled: [{reminderId, weekday, kind, triggerAtMs}]`.
2. **Main fires (`AlarmFireReceiver`)**
   - Acquire a short hand-off wake lock (60 s).
   - **First re-arm next week:** `after = max(now, occurrenceMs)`, strictly after, so a slightly early delivery can never double-ring.
   - Skip if:
     - the reminder is gone or disabled;
     - the occurrence is marked skipped ("skip next");
     - the alarm is stale: `now - occurrenceMs > 10 min` (for example the phone slept through it). Log `missed_late` and post the "missed" notification.
   - Otherwise `ContextCompat.startForegroundService(RingService, ACTION_RING)`.
3. **`RingService` ACTION_RING**
   - Call `startForeground` immediately with the ring notification: full-screen intent, three actions, category ALARM, visibility PUBLIC, ongoing.
   - Then: wake lock for `ringSeconds + 15 s`; audio focus `AUDIOFOCUS_GAIN_TRANSIENT` with `USAGE_ALARM`; looping `MediaPlayer` on `USAGE_ALARM` (sound fallback chain: user-chosen file → bundled `R.raw.alarm_default` → `RingtoneManager.TYPE_ALARM` → `TYPE_NOTIFICATION`); vibration waveform repeat 0 with `USAGE_ALARM` attributes.
   - `Handler.postDelayed(autoStop, ringSeconds)`.
   - Log `rang`, `nag_rang` or `test_rang` and push an event to Dart if attached.
4. **"Start reciting"**
   - `PendingIntent.getActivity(MainActivity, ACTION_START_ROUTINE + extras)`, no trampoline.
   - `MainActivity.handleIntent` calls `AlarmEngine.start()` **before Flutter draws**: stop ring, cancel snooze and nag for this reminder, clear the missed notification, mark the occurrence `started`, log.
   - It then sets show-over-lock-screen and stores a pending launch action `{action:"start", reminderId, occurrenceMs, routineId}`.
   - Dart pulls it with `getLaunchAction()` before deciding the first route and opens `/recite?routine=..&alarm=1`.
5. **Snooze** (broadcast → `AlarmActionReceiver`, native)
   - If `snoozesUsed < maxSnoozes`: increment, stop ring, cancel any nag, `arm(snooze, rid, 0, now + snoozeMinutes, occurrenceMs)`, log `snoozed`.
   - The ring notification only offers Snooze while `snoozesUsed < maxSnoozes`.
6. **Dismiss** (broadcast) — stop ring, cancel snooze and nag, clear the missed notification, mark `dismissed`, log.
7. **Auto-stop** (`Handler` in the FGS)
   - Stop sound and vibration. Post the "Missed — tap to start" notification: channel `missed_v1`, `setOngoing(true)`, actions Start reciting and Dismiss, `contentIntent` = Start.
   - If `nagEnabled && nagsUsed < nagMax`, `arm(nag, rid, 0, now + nagEvery, occurrenceMs)`. Log `auto_stopped`, then stop the FGS.
   - Android 14+ lets users swipe ongoing notifications while unlocked. Treat a swipe as "leave it" (no state change); nags continue until Start or Dismiss.
8. **Nag or snooze fires** — same as main without the weekly re-arm. A nag increments `nagsUsed`. The ring has the same three actions and the same auto-stop, so the nag chain continues until J is reached.
9. **Test alarm** — `arm(test, -1, 0, now + seconds)`. It rings with defaults; no re-arm, no nags.
10. **`SystemEventsReceiver`** (`BOOT_COMPLETED`, `LOCKED_BOOT_COMPLETED`, `MY_PACKAGE_REPLACED`, `TIME_SET`, `TIMEZONE_CHANGED`, `SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED`, `QUICKBOOT_POWERON`)
    - Use `goAsync()` and a worker thread (avoids the FLN #2829 ANR pattern).
    - `rescheduleAll()`: recompute every main alarm from the store with the current `ZoneId.systemDefault()`.
    - Re-arm pending snooze and nag entries if they are still in the future. If a snooze or nag fell due while the phone was off and is ≤ 10 min late, arm it at now + 10 s. Otherwise log `missed_while_off` and post "missed".
    - Never start the FGS directly from the boot receiver.
11. **Ring superseded** (a second ring arrives while one is ringing) — the old occurrence goes through the auto-stop path with reason `superseded` (missed notification and nag), and the new one rings.
12. **Notification swiped while ringing** — the `deleteIntent` broadcasts `ACTION_RESTORE`, which re-posts through `startForeground` (same approach as `alarm` 5.9.0). Sound continues until Start, Snooze, Dismiss or auto-stop.

### 5.4 Channel contract (Dart ⇄ Kotlin)

`MethodChannel("daily_duas/alarm")` and `EventChannel("daily_duas/alarm_events")`. Arguments and results are **JSON strings** (`jsonEncode` / `org.json`). This avoids `Map<Object?, Object?>` casting and keeps it testable. Times are epoch ms; weekdays are ISO 1..7 (same as `ARCHITECTURE.md` section 7):

| Method | Args | Result |
|---|---|---|
| `syncReminders` | `{"reminders":[{id,label,hour,minute,weekdays,enabled,routineId,routineName,snoozeMinutes,maxSnoozes,nagEnabled,nagEveryMinutes,nagMaxTimes,ringSeconds,vibrate,sound}]}` | `{"scheduled":[{reminderId,weekday,kind,triggerAtMs}]}` |
| `getScheduled` | – | `[{reminderId,weekday,kind,triggerAtMs,exists}]` (`exists` = `PendingIntent` with `FLAG_NO_CREATE` is non-null and `triggerAtMs > now`) |
| `scheduleTest` | `{seconds,label,routineId}` | `{triggerAtMs}` |
| `getLaunchAction` | – | `null` or `{action:"ring"\|"start"\|"open", reminderId, occurrenceMs, routineId, label, kind}` (consumed) |
| `getRinging` | – | `null` or `{reminderId, occurrenceMs, routineId, label, kind, snoozesUsed, maxSnoozes, startedMs}` |
| `alarmAction` | `{action:"start"\|"snooze"\|"dismiss"\|"stop", reminderId, occurrenceMs}` | `{ok, snoozesLeft}` (used by the in-app ring screen) |
| `skipNext` | `{reminderId}` | `{skippedOccurrenceMs}` |
| `getEvents` | `{sinceMs}` | `[{reminderId, occurrenceMs, event, atMs, label}]`; event ∈ `rang, nag_rang, test_rang, auto_stopped, snoozed, dismissed, started, superseded, missed_late, missed_while_off, skipped` |
| `getStatus` | – | see section 5.5 |
| `requestNotificationPermission` | – | `bool` |
| `openSettings` | `{page:"exact_alarm"\|"full_screen"\|"battery"\|"battery_request"\|"notifications"\|"ring_channel"\|"app_details"\|"sound"}` | `bool` |

Events on the `EventChannel`: `{type:"ringing", ...}`, `{type:"stopped", reminderId, reason}`, `{type:"launch", ...launchAction}` (from `onNewIntent` while Dart runs) and `{type:"event", ...}` (log entry).

### 5.5 Reliability status (`getStatus`)

```
notificationsEnabled      NotificationManagerCompat.from(ctx).areNotificationsEnabled()
ringChannelImportance     nm.getNotificationChannel("ring_v1")?.importance   (user may lower it)
exactAlarmsAllowed        SDK<31 || am.canScheduleExactAlarms()
fullScreenAllowed         SDK<34 || nm.canUseFullScreenIntent()
ignoringBatteryOpt        pm.isIgnoringBatteryOptimizations(pkg)
backgroundRestricted      SDK>=28 && activityManager.isBackgroundRestricted
standbyBucket             SDK>=28: usageStatsManager.appStandbyBucket   (own app, no permission)
alarmVolume / max         audioManager.getStreamVolume/ getStreamMaxVolume(STREAM_ALARM)  (0 = silent alarm!)
interruptionFilter        nm.currentInterruptionFilter (+ policy allows alarms?)
nextOwnTriggerMs          from store (AlarmManager has no query API for own alarms)
systemNextAlarmClockMs    am.nextAlarmClock?.triggerTime  (system-wide; may belong to another app)
manufacturer, model, sdkInt, timezone (ZoneId.systemDefault().id)
```

Settings intents:

- `Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM` (31+), with `package:` URI.
- `Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT` (34+), with `package:` URI.
- `Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS`, or `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` with `package:` URI (needs the `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` permission).
- `Settings.ACTION_APP_NOTIFICATION_SETTINGS` + `EXTRA_APP_PACKAGE`.
- `Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS` + `EXTRA_CHANNEL_ID`.
- `Settings.ACTION_APPLICATION_DETAILS_SETTINGS`.
- `Settings.ACTION_SOUND_SETTINGS`.

Add the dontkillmyapp.com link for the manufacturer.

### 5.6 Testing

- **Kotlin JUnit** (`android/app/src/test/kotlin/...`, run with `gradlew :app:testDebugUnitTest`):
  - `NextOccurrence` across weekdays, midnight, DST gap and overlap (`Europe/London` 2026-03-29 01:30, 2026-10-25 01:30) and time-zone switch.
  - The state machine (snooze cap, nag count, stale policy) as pure functions over a fake clock and in-memory store.
- **Dart:** `AlarmBridge` interface with a `FakeAlarmBridge` (timers) for widget tests and desktop runs. Use `TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler` for channel encoding tests.
- **Device checklist (adb):**
  - `adb shell dumpsys alarm | findstr dailyduas` — look for the `RTC_WAKEUP` entries with an alarm clock.
  - Doze: `adb shell dumpsys deviceidle force-idle`, then `... unforce`.
  - Standby: `adb shell am set-standby-bucket com.dailyduas.daily_duas restricted`.
  - Process death: `adb shell am kill com.dailyduas.daily_duas` (alarms must survive). `am force-stop` must be shown as "alarms cleared until next launch".
  - Reboot: `adb reboot`, and test once **without unlocking** (direct boot).
  - Time zone: change it in Settings.
  - Notifications off: `adb shell pm revoke com.dailyduas.daily_duas android.permission.POST_NOTIFICATIONS`.
  - On an Android 17 device: `adb shell cmd audio set-enable-hardening enable` **[V docs]**.

### 5.7 Coexistence with routine audio

- "Start reciting" stops the ring and **abandons audio focus before** `just_audio` / `audio_service` start the routine.
- The routine is started from a notification tap or activity, so it gets while-in-use for the `mediaPlayback` FGS. This matters if targetSdk is later raised to 37.

---

## 6. Exact `AndroidManifest.xml` additions (option C)

Add to `android/app/src/main/AndroidManifest.xml`. The Kotlin package is `com.dailyduas.daily_duas.alarm`.

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- Show notifications (runtime permission on Android 13+). -->
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <!-- Exact alarms. Auto-granted on install, not user-revocable (API 33+). Play policy: only for
         alarm-clock / calendar core functionality, which this app is. Sideloaded build: no review. -->
    <uses-permission android:name="android.permission.USE_EXACT_ALARM"/>
    <!-- Android 12/12L (API 31-32) have no USE_EXACT_ALARM. On 33+ USE_EXACT_ALARM covers it. -->
    <uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM" android:maxSdkVersion="32"/>
    <!-- Re-arm after reboot (also LOCKED_BOOT_COMPLETED). -->
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <uses-permission android:name="android.permission.VIBRATE"/>
    <!-- Full-screen alarm over the lock screen. Default-granted on install (Android 14+); Google Play revokes it
         for apps that are not alarm/calling apps. Check NotificationManager.canUseFullScreenIntent(). -->
    <uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT"/>
    <!-- Ring service. systemExempted is allowed for apps holding USE_EXACT_ALARM/SCHEDULE_EXACT_ALARM (API 34+)
         and is not blocked from BOOT_COMPLETED on Android 15. mediaPlayback is used on API 29-33.
         Play: FGS types must be declared in Play Console (n/a for sideload). -->
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_SYSTEM_EXEMPTED"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
    <!-- Lets the app show the system "Allow ignoring battery optimizations?" dialog directly.
         Google Play restricts this permission; fine for a sideloaded personal build. -->
    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>

    <application ...>
        <activity android:name=".MainActivity" ... (keep template attributes; launchMode="singleTop")>
            <!-- Do NOT add showWhenLocked/turnScreenOn here: MainActivity sets them at runtime only when it
                 is launched for an alarm, so the whole app is not visible over the keyguard. -->
        </activity>

        <receiver android:name=".alarm.AlarmFireReceiver"
                  android:exported="false" android:directBootAware="true"/>
        <receiver android:name=".alarm.AlarmActionReceiver"
                  android:exported="false" android:directBootAware="true"/>
        <receiver android:name=".alarm.SystemEventsReceiver"
                  android:exported="false" android:directBootAware="true">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.LOCKED_BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
                <action android:name="android.intent.action.TIME_SET"/>
                <action android:name="android.intent.action.TIMEZONE_CHANGED"/>
                <action android:name="android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED"/>
                <action android:name="android.intent.action.QUICKBOOT_POWERON"/>
            </intent-filter>
        </receiver>
        <service android:name=".alarm.RingService"
                 android:exported="false"
                 android:directBootAware="true"
                 android:foregroundServiceType="systemExempted|mediaPlayback"/>
    </application>
</manifest>
```

Notes:

- `exported="false"` still receives the system's protected broadcasts. FLN uses the same setting for its boot receiver. AOSP `DeskClock` listens for the same actions (`BOOT_COMPLETED`, `LOCKED_BOOT_COMPLETED`, `MY_PACKAGE_REPLACED`, `TIME_SET`, `TIMEZONE_CHANGED`) **[V]**.
- `systemExempted` on API 29–33 devices: the manifest flag is unknown there. We pass `FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK` explicitly on those versions **[U: verify on an API 29–33 emulator]**.
- Direct boot: only the receivers and the service are `directBootAware`, not `MainActivity`. Before first unlock the ring and notification work, the full-screen activity does not, and a user-chosen sound in credential-encrypted storage falls back to `R.raw`.
- Resources: notification icon `res/drawable/ic_stat_alarm.xml` (white vector) and `res/raw/alarm_default.ogg`. They are referenced through `R.*`, so R8 keeps them. If anything is resolved by name, add `res/raw/keep.xml` with `tools:keep`.

## 7. Gradle changes (`android/app/build.gradle.kts`)

```kotlin
android {
    defaultConfig {
        minSdk = 26          // java.time, NotificationChannel, AudioFocusRequest without desugaring.
                             // If you keep flutter.minSdkVersion (24), enable desugaring below.
    }
    compileOptions {
        // Required only if minSdk < 26 OR flutter_local_notifications is ever added:
        // isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    testOptions { unitTests.isReturnDefaultValues = true }
}
dependencies {
    implementation("androidx.core:core-ktx:1.18.0")   // NotificationCompat/ServiceCompat/ContextCompat.
                                                     // 1.19.x needs compileSdk 37 + AGP 9.1.
    // coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")   // only if desugaring enabled
    testImplementation("junit:junit:4.13.2")
}
```

- No ProGuard rules are needed. Manifest-declared classes are kept, and `org.json` uses no reflection.
- Cross-cutting: `permission_handler_android` 14.x requires **compileSdk 37** (its changelog) **[V]**. So do `androidx.core` 1.19 and FLN 23. If any of them is adopted, set `compileSdk = 37` and AGP to ≥ 9.1.x. For alarms we don't need `permission_handler`: `POST_NOTIFICATIONS` is requested from `MainActivity`.

## 8. Kotlin needed (skeletons of the critical parts)

Files under `android/app/src/main/kotlin/com/dailyduas/daily_duas/`:

- `MainActivity.kt`
- `alarm/AlarmContract.kt`
- `alarm/AlarmStore.kt` (device-protected prefs, JSON)
- `alarm/NextOccurrence.kt`
- `alarm/AlarmScheduler.kt`
- `alarm/AlarmEngine.kt` (state machine: `syncReminders`, `onFire`, `start`, `snooze`, `dismiss`, `onRingEnded`, `rescheduleAll`, `skipNext`, event log)
- `alarm/AlarmFireReceiver.kt`
- `alarm/AlarmActionReceiver.kt`
- `alarm/SystemEventsReceiver.kt`
- `alarm/RingService.kt`
- `alarm/AlarmNotifications.kt`
- `alarm/AlarmChannel.kt` (Method and Event channels, status, settings)
- `alarm/WakeLocks.kt`

```kotlin
// alarm/NextOccurrence.kt — pure, unit-tested. Weekdays ISO 1..7.
object NextOccurrence {
    /** Smallest instant strictly after [after] on an allowed weekday at local hour:minute in after.zone.
     *  java.time semantics: DST gap -> shifted later by the gap length (02:30 -> 03:30);
     *  DST overlap -> earlier offset. (Dart/Python mirrors must copy exactly this.) */
    fun next(hour: Int, minute: Int, weekdays: Set<Int>, after: ZonedDateTime): ZonedDateTime? {
        if (weekdays.isEmpty()) return null
        var date = after.toLocalDate()
        repeat(8) {
            if (date.dayOfWeek.value in weekdays) {
                val c = ZonedDateTime.of(date, LocalTime.of(hour, minute), after.zone)
                if (c.isAfter(after)) return c
            }
            date = date.plusDays(1)
        }
        return null
    }
    fun nextForWeekday(h: Int, m: Int, weekday: Int, after: ZonedDateTime): ZonedDateTime =
        next(h, m, setOf(weekday), after)!!
}
```

```kotlin
// alarm/AlarmScheduler.kt
object AlarmScheduler {
    private fun fireIntent(ctx: Context, kind: String, rid: Int, wd: Int) =
        Intent(ctx, AlarmFireReceiver::class.java)
            .setAction(AlarmContract.ACTION_FIRE)
            .setData(Uri.parse("dailyduas://alarm/$kind/$rid/$wd"))   // identity; extras are not part of it

    fun arm(ctx: Context, kind: String, rid: Int, wd: Int, triggerAtMs: Long, occurrenceMs: Long) {
        val am = ctx.getSystemService(AlarmManager::class.java)
        val op = PendingIntent.getBroadcast(ctx, 0,
            fireIntent(ctx, kind, rid, wd)
                .putExtra(AlarmContract.EXTRA_KIND, kind).putExtra(AlarmContract.EXTRA_REMINDER_ID, rid)
                .putExtra(AlarmContract.EXTRA_WEEKDAY, wd).putExtra(AlarmContract.EXTRA_OCCURRENCE_MS, occurrenceMs),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        if (Build.VERSION.SDK_INT >= 31 && !am.canScheduleExactAlarms()) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAtMs, op)   // degraded; surfaced by getStatus
        } else {
            am.setAlarmClock(AlarmManager.AlarmClockInfo(triggerAtMs, showIntent(ctx)), op)
        }
    }

    fun cancel(ctx: Context, kind: String, rid: Int, wd: Int = 0) {
        val op = PendingIntent.getBroadcast(ctx, 0, fireIntent(ctx, kind, rid, wd),
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE) ?: return
        ctx.getSystemService(AlarmManager::class.java).cancel(op)
        op.cancel()
    }

    // Activity intent for the system "next alarm" UI (FLN wrongly passes the broadcast here, see #2726).
    private fun showIntent(ctx: Context): PendingIntent = PendingIntent.getActivity(ctx, 1,
        Intent(ctx, MainActivity::class.java).setAction(AlarmContract.ACTION_OPEN_REMINDERS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
}
```

```kotlin
// alarm/AlarmFireReceiver.kt
class AlarmFireReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val ctx = context.applicationContext
        WakeLocks.acquireHandoff(ctx)                                  // static PARTIAL lock, 60 s timeout
        val kind = intent.getStringExtra(AlarmContract.EXTRA_KIND) ?: return WakeLocks.releaseHandoff()
        val decision = AlarmEngine.onFire(ctx, kind,
            intent.getIntExtra(AlarmContract.EXTRA_REMINDER_ID, 0),
            intent.getIntExtra(AlarmContract.EXTRA_WEEKDAY, 0),
            intent.getLongExtra(AlarmContract.EXTRA_OCCURRENCE_MS, 0L))  // re-arms next week FIRST
        if (decision != AlarmEngine.Decision.RING) return WakeLocks.releaseHandoff()
        ContextCompat.startForegroundService(ctx,
            Intent(ctx, RingService::class.java).setAction(AlarmContract.ACTION_RING).putExtras(intent))
        // allowed: setAlarmClock delivery grants a temporary FGS-start allowlist (AOSP REASON_ALARM_MANAGER_ALARM_CLOCK)
    }
}
```

```kotlin
// alarm/RingService.kt (core only)
class RingService : Service() {
    companion object { @Volatile var instance: RingService? = null; private set }
    private val handler = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private var focus: AudioFocusRequest? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var current: RingInfo? = null
    private val autoStop = Runnable { current?.let { end(it, "auto_stopped") } }
    private val attrs = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ALARM)                 // Android 17 waiver needs USAGE_ALARM
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()

    override fun onCreate() { super.onCreate(); instance = this }
    override fun onDestroy() { stopOutputs(); instance = null; super.onDestroy() }
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action != AlarmContract.ACTION_RING) { stopSelf(); return START_NOT_STICKY }
        val info = RingInfo.from(this, intent)                  // reminder from AlarmStore + extras
        goForeground(AlarmNotifications.ringing(this, info))    // FIRST (FGS start deadline)
        WakeLocks.releaseHandoff()
        current?.let { AlarmEngine.onRingEnded(this, it, "superseded") }
        startRinging(info)
        return START_NOT_STICKY
    }

    private fun goForeground(n: Notification) {
        val type = when {
            Build.VERSION.SDK_INT >= 34 -> ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED
            Build.VERSION.SDK_INT >= 29 -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            else -> 0
        }
        try {
            ServiceCompat.startForeground(this, AlarmContract.NOTIF_RING, n, type)
        } catch (e: RuntimeException) {   // e.g. ForegroundServiceTypeNotAllowedException
            if (Build.VERSION.SDK_INT < 34) throw e
            ServiceCompat.startForeground(this, AlarmContract.NOTIF_RING, n,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        }
    }

    fun restoreNotification() { current?.let { goForeground(AlarmNotifications.ringing(this, it)) } }

    private fun startRinging(info: RingInfo) {
        stopOutputs(); current = info
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "dailyduas:ring")
            .apply { setReferenceCounted(false); acquire(info.ringSeconds * 1000L + 15_000L) }
        val am = getSystemService(AudioManager::class.java)
        focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(attrs).build().also { am.requestAudioFocus(it) }
        for (uri in info.soundCandidates(this)) {               // chosen file -> R.raw -> TYPE_ALARM -> TYPE_NOTIFICATION
            try {
                player = MediaPlayer().apply {
                    setAudioAttributes(attrs); setDataSource(this@RingService, uri)
                    isLooping = true; prepare(); start()
                }
                break
            } catch (e: Exception) { player?.release(); player = null }
        }
        if (info.vibrate) startVibration()
        handler.postDelayed(autoStop, info.ringSeconds * 1000L)
        AlarmEngine.onRingStarted(this, info)                   // log + EventChannel push
    }

    @Suppress("DEPRECATION")
    private fun startVibration() {
        val v = if (Build.VERSION.SDK_INT >= 31) getSystemService(VibratorManager::class.java).defaultVibrator
                else getSystemService(Vibrator::class.java)
        val effect = VibrationEffect.createWaveform(longArrayOf(0, 800, 700), 0)   // repeat forever
        if (Build.VERSION.SDK_INT >= 33)
            v.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_ALARM))
        else v.vibrate(effect, attrs)
        vibrator = v
    }

    /** Called in-process by AlarmEngine for Start/Snooze/Dismiss (no startService from background needed). */
    fun stopFromAction(reason: String) { current?.let { end(it, reason) } }

    private fun end(info: RingInfo, reason: String) {
        stopOutputs(); current = null
        AlarmEngine.onRingEnded(this, info, reason)            // auto_stopped -> missed notif + nag arm
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun stopOutputs() {
        handler.removeCallbacks(autoStop)
        player?.run { runCatching { stop() }; release() }; player = null
        vibrator?.cancel(); vibrator = null
        focus?.let { getSystemService(AudioManager::class.java).abandonAudioFocusRequest(it) }; focus = null
        wakeLock?.let { if (it.isHeld) it.release() }; wakeLock = null
    }
}
```

```kotlin
// alarm/AlarmNotifications.kt (ring notification)
fun ringing(ctx: Context, i: RingInfo): Notification {
    ensureChannels(ctx)   // "ring_v1": IMPORTANCE_HIGH, setSound(null,null), enableVibration(false), lockscreen PUBLIC
                          // "missed_v1": IMPORTANCE_HIGH, silent
    val openRing = activityPi(ctx, AlarmContract.ACTION_OPEN_RING_SCREEN, i)   // FSI + content tap -> Flutter ring screen
    val b = NotificationCompat.Builder(ctx, AlarmContract.CH_RING)
        .setSmallIcon(R.drawable.ic_stat_alarm)
        .setContentTitle(i.label).setContentText(i.routineName)
        .setCategory(NotificationCompat.CATEGORY_ALARM)
        .setPriority(NotificationCompat.PRIORITY_MAX)
        .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        .setOngoing(true).setAutoCancel(false).setShowWhen(true)
        .setContentIntent(openRing)
        .setFullScreenIntent(openRing, true)
        .setDeleteIntent(broadcastPi(ctx, AlarmContract.ACTION_RESTORE, i))   // swipe -> re-post while ringing
        .addAction(0, "Start reciting", activityPi(ctx, AlarmContract.ACTION_START_ROUTINE, i)) // no trampoline
    if (i.snoozesUsed < i.maxSnoozes)
        b.addAction(0, "Snooze ${i.snoozeMinutes} min", broadcastPi(ctx, AlarmContract.ACTION_SNOOZE, i))
    b.addAction(0, "Dismiss", broadcastPi(ctx, AlarmContract.ACTION_DISMISS, i))
    return b.build()
}
// activityPi: Intent(ctx, MainActivity::class.java).setAction(a).setData(uri(a, i)).putExtras(i.toBundle())
//   .addFlags(FLAG_ACTIVITY_NEW_TASK or FLAG_ACTIVITY_SINGLE_TOP or FLAG_ACTIVITY_CLEAR_TOP),
//   PendingIntent.getActivity(..., FLAG_UPDATE_CURRENT or FLAG_IMMUTABLE)
// broadcastPi: Intent(ctx, AlarmActionReceiver::class.java).setAction(a).setData(uri(a, i)).putExtras(...),
//   PendingIntent.getBroadcast(..., FLAG_UPDATE_CURRENT or FLAG_IMMUTABLE)
```

```kotlin
// alarm/SystemEventsReceiver.kt
class SystemEventsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()                                   // never block the main thread (cf. FLN #2829)
        Thread {
            try { AlarmEngine.rescheduleAll(context.applicationContext, intent.action ?: "unknown") }
            finally { pending.finish() }
        }.start()
    }
}

// alarm/AlarmActionReceiver.kt
class AlarmActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val ctx = context.applicationContext
        val rid = intent.getIntExtra(AlarmContract.EXTRA_REMINDER_ID, 0)
        val occ = intent.getLongExtra(AlarmContract.EXTRA_OCCURRENCE_MS, 0L)
        when (intent.action) {
            AlarmContract.ACTION_SNOOZE -> AlarmEngine.snooze(ctx, rid, occ)    // caps at maxSnoozes
            AlarmContract.ACTION_DISMISS -> AlarmEngine.dismiss(ctx, rid, occ)  // cancels snooze+nag for occ
            AlarmContract.ACTION_RESTORE -> RingService.instance?.restoreNotification()
        }
    }
}

// alarm/AlarmStore.kt — storage location (direct-boot safe); use commit() for state transitions
private fun prefs(ctx: Context) = ctx.createDeviceProtectedStorageContext()
    .getSharedPreferences("alarm_store", Context.MODE_PRIVATE)
```

```kotlin
// MainActivity.kt
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        AlarmChannel.attach(this, flutterEngine.dartExecutor.binaryMessenger)  // Method + Event channels
    }
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        AlarmChannel.detach(); super.cleanUpFlutterEngine(flutterEngine)
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)       // configureFlutterEngine runs inside this
        handleAlarmIntent(intent)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent); setIntent(intent); handleAlarmIntent(intent)
    }
    private fun handleAlarmIntent(i: Intent?) {
        val launch = LaunchAction.from(i) ?: return               // only our ACTION_* (ring/start/open)
        if (launch.action == "start")
            AlarmEngine.start(applicationContext, launch.reminderId, launch.occurrenceMs) // sound stops before Flutter draws
        if (launch.action == "ring" || launch.action == "start") showOverLockScreen(true)
        AlarmChannel.offerLaunch(launch)   // kept until Dart calls getLaunchAction(); also pushed if Dart is listening
    }
    @Suppress("DEPRECATION")   // annotate the function; `else @Suppress(..) { }` would parse as an unused lambda
    fun showOverLockScreen(on: Boolean) {                         // call with false when the routine/ring screen closes
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(on); setTurnScreenOn(on)
        } else {                                                  // API 26 only (minSdk 26)
            val f = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (on) window.addFlags(f) else window.clearFlags(f)
        }
    }
    override fun onRequestPermissionsResult(code: Int, perms: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, perms, results)   // keep plugin delegation
        AlarmChannel.onPermissionResult(code, results)           // completes requestNotificationPermission()
    }
}
```

Dart side (no extra packages):

```dart
abstract interface class AlarmBridge {
  Future<Map<String, Object?>> syncReminders(List<Map<String, Object?>> reminders);
  Future<Map<String, Object?>?> getLaunchAction();
  Future<Map<String, Object?>> alarmAction(String action, int reminderId, int occurrenceMs);
  Future<List<Map<String, Object?>>> getEvents(int sinceMs);
  Future<Map<String, Object?>> getStatus();
  Future<bool> openSettings(String page);
  Stream<Map<String, Object?>> get events;
}

class MethodChannelAlarmBridge implements AlarmBridge {
  static const _m = MethodChannel('daily_duas/alarm');
  static const _e = EventChannel('daily_duas/alarm_events');
  Future<Object?> _call(String method, [Object? args]) async {
    final res = await _m.invokeMethod<String>(method, args == null ? null : jsonEncode(args));
    return res == null ? null : jsonDecode(res);
  }
  @override
  Future<Map<String, Object?>> syncReminders(List<Map<String, Object?>> r) async =>
      (await _call('syncReminders', {'reminders': r}))! as Map<String, Object?>;
  @override
  Future<Map<String, Object?>?> getLaunchAction() async => await _call('getLaunchAction') as Map<String, Object?>?;
  @override
  Stream<Map<String, Object?>> get events =>
      _e.receiveBroadcastStream().map((e) => jsonDecode(e as String) as Map<String, Object?>);
  // ... remaining methods identical in shape
}
```

Startup order:

1. `WidgetsFlutterBinding.ensureInitialized()`.
2. `final launch = await bridge.getLaunchAction()`.
3. `runApp(ProviderScope(overrides: [initialLaunchProvider.overrideWithValue(launch)], ...))`. The router's **initial location** comes from `launch` (ring → `/alarm`, start → `/recite?...&alarm=1`), so splash or onboarding can never cover a ringing alarm. This is the same advice as alarm's `DETECT-ALARM-LAUNCH-ANDROID.md`.
4. After the first frame: `syncReminders`, then ingest `getEvents(sinceLast)` into Drift. Repeat on `AppLifecycleState.resumed`.

---

## 9. iOS (not built)

If iOS is ever built:

- Neither A nor B gives a real alarm clock on iOS. `alarm` stops ringing when the user kills the app and does not survive reboot.
- FLN gives ordinary notifications with sounds of 30 s or less and no looping.
- The right path is Apple AlarmKit (iOS 26+): `flutter_alarmkit` 0.4.1 (2026-09-23; `sdk ^3.7.0`, `flutter >=3.38.0`) supports one-shot, countdown and recurring alarms **[V pub.dev metadata only]**.
- Keep `AlarmBridge` platform-neutral so an iOS implementation can be added later.

## 10. Risks and open items

- OEM battery killers (Xiaomi, Oppo, Vivo, Huawei, some Samsung modes). Force-stop clears all alarms (AOSP) **[V]**. Mitigate with the reliability screen, the battery-optimisation exemption and OEM autostart guidance.
- `systemExempted` manifest type on API 29–33 devices is **[U]**. Verify on an emulator; the fallback is `mediaPlayback` everywhere, plus never starting the ring within about 30 s of boot.
- `taskAffinity=""` (Flutter template) together with `FLAG_ACTIVITY_NEW_TASK` from our `PendingIntent`s. Expected to reuse the existing task, because AOSP matches the root component **[U]**. Verify that there is never a second `MainActivity` (and so no second Flutter engine and DB connection).
- Full-screen intent on a sideloaded APK should stay granted **[U]**. Check `canUseFullScreenIntent()` in status.
- Alarm stream volume at 0, or DND "total silence", silences the alarm. Show a warning in status. Optionally raise `STREAM_ALARM` to a floor while ringing; this is allowed under the Android 17 `USAGE_ALARM` waiver.
- If `targetSdk` is raised to 37 later, the Android 17 background-audio rules apply. The ring complies (FGS + `USAGE_ALARM` + exact alarm). Routine audio must start from a user action, which it does (notification or activity tap).
- compileSdk 37 becomes necessary as soon as `permission_handler` ≥ 13.0.2 (`permission_handler_android` 14.x), `androidx.core` 1.19 or FLN 23 is added. Then AGP must be ≥ 9.1.
- Nothing here was run on a device. No `flutter` or Gradle command was run, so the Kotlin above is a design skeleton and has not been compiled.

## 11. Sources

Packages (archives downloaded and read):

- https://pub.dev/packages/alarm — https://pub.dev/api/packages/alarm — https://pub.dev/api/archives/alarm-5.15.0.tar.gz
  - Files read: `android/src/main/AndroidManifest.xml`, `alarm/AlarmService.kt`, `AlarmReceiver.kt`, `BootReceiver.kt`, `services/AlarmScheduler.kt`, `NotificationService.kt`, `AudioService.kt`, `SnoozeCoordinator.kt`, `VibrationService.kt`, `lib/alarm.dart`, `lib/model/*`, `help/INSTALL-ANDROID.md`, `help/DETECT-ALARM-LAUNCH-ANDROID.md`, `CHANGELOG.md`.
- https://github.com/gdelataillade/alarm/issues — #47, #164, #230, #257, #358, #390, #391, #418, #424, #437, #439, #449, #452, #454.
- https://pub.dev/packages/flutter_local_notifications — https://pub.dev/api/archives/flutter_local_notifications-22.3.1.tar.gz and `-23.0.0-dev.3.tar.gz`
  - Files read: `FlutterLocalNotificationsPlugin.java`, `ScheduledNotificationReceiver.java`, `ScheduledNotificationBootReceiver.java`, `ActionBroadcastReceiver.java`, `lib/src/*`, `README.md`, `CHANGELOG.md`.
- https://github.com/MaikuB/flutter_local_notifications/issues — #2726, #2737, #2795, #2821, #2825, #2829.
- https://pub.dev/packages/timezone (0.11.1) and https://pub.dev/packages/flutter_timezone (5.1.1); archives read.
- https://pub.dev/packages/flutter_alarmkit (0.4.1), https://pub.dev/packages/permission_handler_android (14.1.0 changelog).
- https://dl.google.com/android/maven2/androidx/core/core/1.19.1/core-1.19.1.aar (aar-metadata) and `desugar_jdk_libs` maven-metadata.

Android docs:

- https://developer.android.com/develop/background-work/services/fgs/service-types
- https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start
- https://developer.android.com/about/versions/15/behavior-changes-15
- https://developer.android.com/about/versions/16/behavior-changes-all and https://developer.android.com/about/versions/16/behavior-changes-16 (nothing alarm-specific)
- https://developer.android.com/about/versions/17/behavior-changes-17 and https://developer.android.com/about/versions/17/changes/bg-audio
- https://developer.android.com/develop/background-work/services/alarms
- https://developer.android.com/about/versions/14/changes/schedule-exact-alarms
- https://developer.android.com/develop/background-work/background-tasks/broadcasts/broadcast-exceptions
- https://developer.android.com/about/versions/12/behavior-changes-12 (notification trampolines)
- https://source.android.com/docs/core/permissions/fsi-limits

AOSP (`main`, fetched 2026-10-06):

- https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/apex/jobscheduler/service/java/com/android/server/alarm/AlarmManagerService.java (`isExemptFromAppStandby`, `isExemptFromBatterySaver`, `EXTRA_REPLACING`, allowlist reasons, quotas)
- https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/services/core/java/com/android/server/notification/NotificationManagerService.java (`REASON_TIMEOUT` with sendDelete, `onPanelRevealed` → `clearEffects`)
- https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/services/core/java/com/android/server/notification/NotificationAttentionHelper.java (insistent, cooldown defaults)
- https://android.googlesource.com/platform/packages/apps/DeskClock/+/refs/heads/main/AndroidManifest.xml (receiver actions)
