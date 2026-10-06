# Reliable alarm-clock reminders on Android (Kotlin, inside a Flutter plugin) — research notes

Scope: the `flet_dua_native` Flutter plugin (Kotlin) used by the Daily Duas Flet 1.0.3 app. The app is a sideloaded APK for one phone. The OS range is Android 13 to Android 17 (API 33–37). The code still has to run on the default minSdk 24.
Researched 2026-10-06. Every claim carries a source tag such as `[AM-SCHED]`, and the **Sources** table at the end maps each tag to a URL.
Legend: **VERIFIED** means read in official docs, AOSP source, or the real package source in this session. **UNVERIFIED** means memory, inference, or a third-party claim that was not confirmed here. Untagged prose is the author's design recommendation.

---

## 0. TL;DR decisions

1. **Scheduling.** Use `AlarmManager.setAlarmClock(AlarmClockInfo(t, showPI), opPI)` for every ring (weekly, snooze, nag). In AOSP it is exempt from Doze, App Standby and Battery Saver. It is also allowed to start a foreground service (FGS) from the background. [AM-REF][DOZE][AOSP-AMS]
2. **Permissions.** Declare `USE_EXACT_ALARM`, which is auto-granted on API 33+ and cannot be revoked. Also declare `SCHEDULE_EXACT_ALARM` with `android:maxSdkVersion="32"`. Always check `canScheduleExactAlarms()` and fall back to `setAndAllowWhileIdle`. [PERM-REF][AM-SCHED]
3. **Ringing.** `AlarmReceiver` calls `startForegroundService(RingService)`. The service calls `ServiceCompat.startForeground(..., type)` with **`systemExempted` on API 34+**. That type is allowed for apps that hold an exact-alarm permission, and it is **not** in Android 15's `BOOT_COMPLETED` deny list. On API 29–33 use `mediaPlayback`. The manifest declares `foregroundServiceType="systemExempted|mediaPlayback"`. [FGS-TYPES][SI-REF][A15-T]
4. **Audio.** Play with `MediaPlayer` and `AudioAttributes(USAGE_ALARM, CONTENT_TYPE_SONIFICATION)`, looping, only while the FGS runs. This also satisfies Android 15's audio-focus rule and Android 17's background-audio hardening. [A15-T][A17-AUDIO]
5. **Notification.** Use an `IMPORTANCE_HIGH` channel with sound off (the service plays the audio), `CATEGORY_ALARM`, `setFullScreenIntent(pi, true)`, and actions Done / Snooze. `CATEGORY_ALARM` lets the notification pass Do Not Disturb (DND) whenever alarms are allowed. [NB-REF][AOSP-ZEN]
6. **Lock screen.** Launch a **small native `RingActivity`** declared in the plugin (`showWhenLocked`, `turnScreenOn`, its own task). Do not send the full-screen intent to Flet's `MainActivity`. A Flet cold start boots the Flutter engine plus Python, which is slow, and the `alarm` package documents the same dedicated-activity pattern as an option. Hand-off to the app is a mailbox in SharedPreferences plus intent extras. [ALARM-PKG][FLET-TPL]
7. **Re-arming.** One receiver handles `BOOT_COMPLETED`, `MY_PACKAGE_REPLACED`, `TIME_SET`, `TIMEZONE_CHANGED` and `SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED`. Also re-arm idempotently every time the plugin attaches. On Android 15+, `BOOT_COMPLETED` is also delivered on the first launch after a force-stop. [INTENT-REF][A15-ALL]
8. **Next occurrence.** Compute it natively with `java.time` (`ZonedDateTime.of(date, time, ZoneId.systemDefault())`; DST gaps move the time later, overlaps take the earlier offset). Flutter 3.44.8's default `minSdk` is **24** but `java.time` needs **26**. Either set `[tool.flet.android] min_sdk_version = 26`, or use the `Calendar` fallback. [FL-EXT][J8][ZDT]
9. **Disk and APK size.** Flutter's embedding already pulls in `androidx.core:core:1.13.1`, so `NotificationCompat` and `ServiceCompat` add nothing. Avoid other dependencies: use `org.json` instead of kotlinx-serialization, the system default alarm sound or downloaded dua audio instead of bundled audio, and a vector-drawable icon. [FL-POM]

---

## 1. Toolchain facts (Flutter 3.44.8, Flet 1.0.3)

### 1.1 Flutter 3.44.8 defaults (VERIFIED, read at tag `3.44.8`)
- `FlutterExtension.kt` sets `compileSdkVersion = 36`, `minSdkVersion = 24`, `targetSdkVersion = 36` and `ndkVersion = "28.2.13676358"`. [FL-EXT]
- `gradle_utils.dart` sets these template values. [FL-GU]
  - Gradle `9.1.0`, AGP `9.0.1` (module template too), KGP `2.3.20`.
  - Java 17 minimum.
  - Max known/supported: AGP `9.1`, Gradle `9.3.1`, KGP `2.3.20`.
- Plugin template `plugin/android-kotlin.tmpl/build.gradle.kts.tmpl`: [FL-TPL]
  - Applies **only** `id("com.android.library")` in `plugins {}`, plus a `buildscript` classpath for AGP and KGP.
  - Uses `compileSdk = {{compileSdkVersion}}`, `minSdk = {{minSdkVersion}}`, Java 17 and `kotlin { compilerOptions { jvmTarget = JVM_17 } }`.
  - Has `sourceSets main java.srcDirs("src/main/kotlin")`.
  - Its manifest template is an empty `<manifest package=...>`.
- App template `gradle.properties` contains `android.newDsl=false` and `android.builtInKotlin=false`. [FL-TPL]
- The Flutter Gradle Plugin (FGP) **auto-applies `kotlin-android`** to every plugin subproject whose build file applies AGP but whose text does not match FGP's KGP regex (`detectApplyingKotlinGradlePlugin`). [FL-FGP]
  - If a plugin applies KGP explicitly and AGP is 9 or newer, FGP only logs a WARNING that future Flutter versions will fail.
- The embedding `flutter_embedding_release` (engine `0cd610717bde95fd88343c64f81c11ba4e5c0010`) depends on: [FL-POM]
  - `androidx.core:core:1.13.1`, `fragment:1.7.1`, `lifecycle-*:2.7.0`, `annotation:1.8.1`, `window-java:1.2.0`, `tracing:1.2.0`, `relinker:1.4.5`, `exifinterface:1.4.1`.
  - `ServiceCompat.startForeground(service, id, n, type)` exists since core **1.12.0**. [SC-REF]

### 1.2 Flet 1.0.3 build template (VERIFIED: `flet-build-template.zip` from release v1.0.3; `flet_cli/commands/build_base.py`)
- `flet build` **does not use the Flutter app template**. It downloads `https://github.com/flet-dev/flet/releases/download/v{flet_version}/flet-build-template.zip`. [FLET-TPL]
- Template `settings.gradle.kts` pins **AGP `8.11.1`**, **KGP `2.2.20`** (`apply false`) and Gradle wrapper **`8.14`**. [FLET-TPL]
  - So our plugin must build with AGP **8**, not 9.
  - FGP auto-applies `kotlin-android` (see 1.1), but the safest plugin build file is the guarded Groovy pattern shown below. [TZ-PKG][ALARM-PKG]
- App `build.gradle.kts` reads `minSdk` from `tool.flet.android.min_sdk_version`, defaulting to `flutter.minSdkVersion` (=24). `targetSdk` comes from `tool.flet.android.target_sdk_version` or `flutter.targetSdkVersion` (=36). Java 17. [FLET-TPL]
- Manifest facts: [FLET-TPL]
  - `MainActivity` is **`FlutterFragmentActivity`** with `launchMode="singleTop"`, `taskAffinity=""` and `exported="true"`.
  - `<application android:enableOnBackInvokedCallback="true">`.
  - Extra `<application>` attributes are possible through `[tool.flet.android.manifest_application]`.
  - Permissions come from `[tool.flet.android.permission]`; a mapping value adds attributes, for example `maxSdkVersion`.
  - No per-activity attributes are configurable, so lock-screen attributes on `MainActivity` are not possible from pyproject.
- Library manifests merge into the app manifest, so **the plugin's own `AndroidManifest.xml` can carry all permissions, receivers, the service and `RingActivity`**. This is standard manifest merging; it was not tested with Flet (UNVERIFIED).

### 1.3 Recommended plugin `android/build.gradle` (Groovy; works with AGP 8 and 9)
This is adapted from `flutter_timezone`'s published guard [TZ-PKG] and the `alarm` package [ALARM-PKG].
```groovy
group 'dev.duas.flet_dua_native'
version '1.0'
apply plugin: 'com.android.library'
def agpMajor = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION.tokenize('.')[0] as int
def builtInKotlin = project.findProperty('android.builtInKotlin')?.toString() == 'true'
// pluginManager.apply (not `apply plugin:`) so FGP's text-regex KGP detector doesn't warn
if (agpMajor < 9 || !builtInKotlin) { pluginManager.apply('kotlin-android') }
android {
    namespace 'dev.duas.flet_dua_native'
    compileSdk 36
    defaultConfig { minSdk 24 }   // 26 if java.time is used without a fallback (then the app must set min_sdk_version=26)
    compileOptions { sourceCompatibility JavaVersion.VERSION_17; targetCompatibility JavaVersion.VERSION_17 }
    sourceSets { main.java.srcDirs += 'src/main/kotlin' }
}
kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }
dependencies { implementation 'androidx.core:core:1.13.1' }  // already in the APK via the Flutter embedding
```
- No `buildscript {}` block is needed: Flet's `settings.gradle.kts` already puts AGP and KGP on the classpath. This is standard Gradle behaviour but was not tested here (UNVERIFIED).
- The Flutter template's `.kts` variant relies on the `kotlin {}` accessor existing under AGP 8 after FGP auto-applies KGP. That ordering was not verified, which is why Groovy is used above (UNVERIFIED).
- Flutter `pubspec.yaml` of the Dart package: `flutter: plugin: platforms: android: { package: dev.duas.flet_dua_native, pluginClass: DuaNativePlugin }`. This is standard Flutter plugin metadata (not re-fetched).

---

## 2. Exact alarm APIs

### 2.1 Which API
| API | Behaviour (VERIFIED) |
|---|---|
| `setAlarmClock(info, op)` (API 21) | "the system never adjusts their delivery time… leaves low-power modes if necessary" [AM-SCHED]. "allowed to trigger even if the system is in … doze" and "will be allowed to start a foreground service even if the app is in the background"; needs `SCHEDULE_EXACT_ALARM` when targeting 31+ [AM-REF]. Doze: "continue to fire normally. The system exits Doze shortly before those alarms fire" [DOZE]. AOSP: `isExemptFromAppStandby` and `isExemptFromBatterySaver` both return true when `alarmClock != null` [AOSP-AMS]. |
| `setExactAndAllowWhileIdle(RTC_WAKEUP, t, op)` (API 23) | Fires in idle and puts the app on the temporary power allowlist for about 10 s. It is rate-limited: "not … more than about every minute; … in low-power idle modes … such as 15 minutes" [AM-REF]. The Doze page says "no more than once per nine minutes, per app" [DOZE]. It can also start an FGS [AM-REF]. |
| `setAndAllowWhileIdle` | Inexact fallback when the exact permission is missing [AM-SCHED]. |

- Side effect of `setAlarmClock`: the system may show an alarm icon or "next alarm" for the **next** alarm clock system-wide [AM-REF].
- `getNextAlarmClock()` returns the next alarm clock "scheduled by **any** application" or `null` [AM-REF].
  - To tell whether it is ours, compare `info.showIntent?.creatorPackage == packageName` (UNVERIFIED trick; `PendingIntent.getCreatorPackage()` exists).
- Alarm delivery opts in AOSP: [AOSP-AMS]
  - Exact alarms use `TEMPORARY_ALLOWLIST_TYPE_FOREGROUND_SERVICE_ALLOWED` for `ALLOW_WHILE_IDLE_WHITELIST_DURATION`, default `10*1000` ms. The reason is `REASON_ALARM_MANAGER_ALARM_CLOCK` for alarm clocks.
  - They also set **`setPendingIntentBackgroundActivityLaunchAllowed(false)`**. An alarm therefore **cannot start an activity directly**; use a full-screen-intent notification.
- Limit: `DEFAULT_MAX_ALARMS_PER_UID = 500`. Exceeding it makes the set call throw (`IllegalStateException`, per the alarm package). [AOSP-AMS][ALARM-PKG]

### 2.2 Permissions
- `USE_EXACT_ALARM` (API 33): [PERM-REF]
  - "without needing to request this permission from the user"; "only intended for … core functionality".
  - "only one of USE_EXACT_ALARM or SCHEDULE_EXACT_ALARM should be requested on a device"; the docs give the `maxSdkVersion="32"` example for `SCHEDULE_EXACT_ALARM`.
  - "Apps that hold this permission, always stay in the WORKING_SET or lower standby bucket".
- Granted on install, cannot be revoked by the user. [AM-SCHED][A14-EXACT]
- `SCHEDULE_EXACT_ALARM` (API 31): "special access … can be revoked by the system or the user"; protection level `signature|privileged|appop`. [PERM-REF]
  - On Android 14 it is "no longer being pre-granted to most newly installed apps targeting Android 13 and higher". [A14-ALL]
  - The Android 14 wording implies it **was** pre-granted on Android 12/13. The page summary for Android 12 says "not pre-granted"; the two conflict (UNVERIFIED). Irrelevant for us on API 33+ (we use `USE_EXACT_ALARM`); on API 31–32, check `canScheduleExactAlarms()`.
- `canScheduleExactAlarms()` is true with the permission **or** when the app is on the power-save exemption list (the battery optimization allowlist). Apps targeting below S always get true. [AM-REF]
- Revocation: "all alarms scheduled with setExact…, setExactAndAllowWhileIdle… and setAlarmClock… will be deleted". The grant broadcast `android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED`: [AM-REF][AM-SCHED]
  - is sent only on **grant**, not on revoke;
  - goes to **runtime and manifest receivers**;
  - is a foreground broadcast that is "allowed to start a foreground service".
  - The docs also say "your app stops" on revoke.
- Request screen: `Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$pkg"))`. With the package URI, the result is `RESULT_OK` if granted. [SET-REF]

```xml
<!-- plugin AndroidManifest.xml -->
<uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM" android:maxSdkVersion="32"/>
<uses-permission android:name="android.permission.USE_EXACT_ALARM"/>
```

### 2.3 PendingIntent identity, flags, request codes
- Identity is the operation plus `Intent.filterEquals` (action, data, type, class, categories) plus the **request code** plus identifying flags such as `FLAG_IMMUTABLE` and `FLAG_ONE_SHOT`. **Extras are not part of identity.** [PI-REF]
  - To look one up with `FLAG_NO_CREATE`, supply the same identifying flags (for example `FLAG_IMMUTABLE`). [PI-REF]
- `FLAG_UPDATE_CURRENT` keeps the token and replaces the extras. It works together with `FLAG_IMMUTABLE`. [PI-REF]
- Android 12+ requires a mutability flag on every PendingIntent. [A12-T]
- Android 14+: a **mutable** PendingIntent with an implicit intent throws, so always use explicit component plus `FLAG_IMMUTABLE`. [A14-T]
- `FLAG_NO_CREATE` returns null if the PendingIntent does not exist [PI-REF]. A non-null result does **not** prove the alarm is still pending: the token can outlive delivery. Keep the truth in our Store and debug with `adb shell dumpsys alarm` (UNVERIFIED nuance, common pitfall).
- `AlarmManager.cancel(op)` removes alarms whose intent `filterEquals` matches; `cancelAll()` exists on API 34+. [AM-REF]

**Recommended identity scheme:** an explicit intent to `AlarmReceiver` with a **data URI per slot** and request code 0. This needs no integer packing and no collisions.
- `duas://alarm/<reminderId>/w<1..7>` — the weekly occurrence of that reminder on that ISO weekday.
- `duas://alarm/<reminderId>/x` — the snooze or nag chain of the current occurrence (only one at a time per reminder).

The alternative is integer codes, for example `reminderId*16 + slot` (slot 1..7 weekdays, 8 = chain).

```kotlin
object AlarmScheduler {
    private fun am(c: Context) = c.getSystemService(AlarmManager::class.java)
    fun canExact(c: Context) = Build.VERSION.SDK_INT < 31 || am(c).canScheduleExactAlarms()

    private fun op(c: Context, rid: Long, slot: String, extras: Bundle?, flags: Int): PendingIntent? {
        val i = Intent(c, AlarmReceiver::class.java)
            .setAction(AlarmReceiver.ACTION_FIRE)
            .setData(Uri.parse("duas://alarm/$rid/$slot"))
        extras?.let { i.putExtras(it) }
        return PendingIntent.getBroadcast(c, 0, i, flags or PendingIntent.FLAG_IMMUTABLE)
    }

    fun arm(c: Context, rid: Long, slot: String, triggerAtMs: Long, extras: Bundle) {
        val operation = op(c, rid, slot, extras, PendingIntent.FLAG_UPDATE_CURRENT)!!
        val m = am(c)
        try {
            if (canExact(c)) {
                val launch = c.packageManager.getLaunchIntentForPackage(c.packageName)
                val show = launch?.let { PendingIntent.getActivity(c, 0, it, PendingIntent.FLAG_IMMUTABLE) }
                m.setAlarmClock(AlarmManager.AlarmClockInfo(triggerAtMs, show), operation)
            } else {
                m.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAtMs, operation) // may be late
            }
        } catch (e: SecurityException) {          // permission revoked between check and call
            m.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAtMs, operation)
        }
    }

    fun cancel(c: Context, rid: Long, slot: String) {
        op(c, rid, slot, null, PendingIntent.FLAG_NO_CREATE)?.let { am(c).cancel(it); it.cancel() }
    }
}
```
The `alarm` package (5.15.0) uses the same priority order: `setAlarmClock` (default since 5.14.0), then `setExactAndAllowWhileIdle`, then `setAndAllowWhileIdle` when `!canScheduleExactAlarms()`, with a catch on `SecurityException`. [ALARM-PKG]

---

## 3. Ringing: foreground service from the alarm receiver

### 3.1 Is starting an FGS from the alarm allowed? (VERIFIED)
- FGS background-start exemption list, Android 12+, includes "Your app invokes an exact alarm to complete an action that the user requests". [FGS-BG]
  - The same list covers `BOOT_COMPLETED`, `LOCKED_BOOT_COMPLETED`, `MY_PACKAGE_REPLACED`, `TIMEZONE_CHANGED`, `TIME_CHANGED` and `LOCALE_CHANGED` receivers, notification interaction, and "The user turns off battery optimizations for your app".
- "exact alarms aren't affected by foreground service launch restrictions" [AM-SCHED]. `setAlarmClock` and `setExactAndAllowWhileIdle`: "allowed to start a foreground service even if the app is in the background" [AM-REF].
- The allowance is a **~10 s temporary allowlist** [AOSP-AMS]. Call `startForegroundService` synchronously in `onReceive`, and call `startForeground` as the first thing in `onStartCommand`.
- A missing `startForeground` after `startForegroundService` crashes the app with "Context.startForegroundService() did not then call startForeground()". The alarm package re-posts its current notification even for no-op starts. [ALARM-PKG]
- Android 14+ **while-in-use** rule: an FGS needing location, camera, microphone or body sensors cannot be created from the background. That does not apply to us; we need no microphone FGS. [FGS-BG]

### 3.2 FGS type: `systemExempted` vs `mediaPlayback` (VERIFIED)
| | `systemExempted` | `mediaPlayback` |
|---|---|---|
| Permission | `FOREGROUND_SERVICE_SYSTEM_EXEMPTED` (API 34, normal) [PERM-REF] | `FOREGROUND_SERVICE_MEDIA_PLAYBACK` (API 34, normal) [PERM-REF] |
| Constant | `ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED` = 1024, **API 34** [SI-REF] | `FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK` = 2, API 29 [SI-REF] |
| Who may use it | Device owner, demo mode, VPN and similar, … "Apps holding SCHEDULE_EXACT_ALARM or USE_EXACT_ALARM permission"; otherwise `ForegroundServiceTypeNotAllowedException` [FGS-TYPES][SI-REF] | anyone |
| Android 15 `BOOT_COMPLETED` ban | **not listed** [A15-T] | **banned** for target 35+ [A15-T][FGS-TYPES] |
| Timeout | none documented (only `dataSync`, `mediaProcessing` (6 h/24 h) and `shortService` (~3 min)) [FGS-TIMEOUT][FGS-TYPES] | none documented |
| Play Console FGS declaration | not in Play's list of types needing declaration [PLAY-FGS] | required (description and video) [PLAY-FGS] |

- The `alarm` package uses `mediaPlayback` [ALARM-PKG]. It documents and works around the Android 15 pitfall:
  - The `BOOT_COMPLETED` allowlist window (~20 s after `BootReceiver` runs) taints **any** FGS start in that window, including alarm-triggered ones, causing `ForegroundServiceStartNotAllowedException`.
  - Its workaround is to re-arm the ring 30 s later and drop it after one retry.
  - This 20 s attribution detail comes from the package's comments only (UNVERIFIED).
  - Using `systemExempted` sidesteps the type ban. Still never ring directly from the boot receiver (see §6).
- `startForeground(id, n, type)`: [SVC-REF]
  - The type "must be a subset" of the manifest types.
  - API 34+ throws `MissingForegroundServiceTypeException`, `InvalidForegroundServiceTypeException`, or `SecurityException` if a type permission is missing.
  - API 31+ throws `ForegroundServiceStartNotAllowedException` when started from the background without an exemption.
  - The `id` must not be 0.
- `ServiceCompat.startForeground` masks the type: [SC-SRC]
  - API ≥34 passes it through, masked to the U-era type set, which includes `SYSTEM_EXEMPTED`.
  - API 29–33 masks to the Q-era set, so `SYSTEM_EXEMPTED` alone becomes `0`.
  - Below 29 it calls the 2-arg version.
  - Pass `mediaPlayback` explicitly below 34.

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_SYSTEM_EXEMPTED"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
<service android:name=".RingService" android:exported="false"
         android:foregroundServiceType="systemExempted|mediaPlayback"/>
```
```kotlin
private fun fgsType(c: Context) = when {
    Build.VERSION.SDK_INT >= 34 && AlarmScheduler.canExact(c) -> ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED
    Build.VERSION.SDK_INT >= 29 -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
    else -> 0
}
// first statement in onStartCommand for ACTION_RING:
try {
    ServiceCompat.startForeground(this, NOTIF_RINGING, notification, fgsType(this))
} catch (e: Exception) {           // ForegroundServiceStartNotAllowedException / SecurityException
    Notifier.postMissed(this, ring, "fgs_denied"); stopSelf(); return START_NOT_STICKY
}
```
- `Notification.Builder.setForegroundServiceBehavior(FOREGROUND_SERVICE_IMMEDIATE)` (API 31; also in `NotificationCompat`) guarantees the FGS notification is not deferred. [NB-REF][N-REF]
- The `alarm` package's receiver calls `PendingIntent.getForegroundService(ctx, alarmId, svcIntent, IMMUTABLE|UPDATE_CURRENT).send()` on API 31+ instead of `startForegroundService`. Its reason is not documented (UNVERIFIED). Plain `ContextCompat.startForegroundService` is the documented path. [ALARM-PKG][FGS-LAUNCH]

### 3.3 Android 15 / 16 / 17 changes that touch alarms, FGS and audio
- **Android 15 (target 35)** [A15-T]:
  - `BOOT_COMPLETED` receivers may not launch `dataSync`, `camera`, `mediaPlayback`, `phoneCall`, `mediaProjection` or `microphone` FGS.
  - `dataSync` and `mediaProcessing` are limited to 6 h per 24 h, with `onTimeout(int,int)`.
  - The `SYSTEM_ALERT_WINDOW` exemption now needs a visible overlay.
  - Edge-to-edge is the default.
  - **Audio focus requires being the top app or running an FGS**; otherwise the request returns `AUDIOFOCUS_REQUEST_FAILED`.
- **Android 15 (all apps)** [A15-ALL]: entering the **stopped state (force-stop) cancels all pending intents**; when the user removes the stopped state, `ACTION_BOOT_COMPLETED` is delivered. `ApplicationStartInfo.wasForceStopped()` can tell you this happened.
- **Android 16 (target 36)** [A16-T]:
  - The edge-to-edge opt-out `windowOptOutEdgeToEdgeEnforcement` is disabled, so `RingActivity` must handle insets.
  - Predictive back: `onBackPressed` is not called and `KEYCODE_BACK` is not dispatched. The Flet template already sets `enableOnBackInvokedCallback="true"`.
  - Orientation and resizability are ignored on sw ≥ 600dp.
  - Safer-intents strict matching is **opt-in** through `intentMatchingFlags`.
- **Android 16 (all apps)** [A16-ALL]: JobScheduler quota is enforced even while an FGS runs (we use no jobs); ordered broadcast priority is no longer global; 16 KB page-size compatibility mode.
- No Android 16 change was found for AlarmManager, full-screen intent (FSI) or the `mediaPlayback` type in the behaviour-change pages fetched 2026-10-06. [A16-T][A16-ALL]
- **Android 17 (API 37)** is released, with QPR1/QPR2 betas listed; the page was last updated 2026-07-01. [A17] **Background audio hardening** [A17-AUDIO][A17-T]:
  - *All apps on Android 17*: background playback, audio focus and volume APIs need "a visible activity or … a foreground service that is not of type SHORT_SERVICE".
  - *Target 37*: the FGS also needs while-in-use (WIU) capability, but "the requirement for WIU capabilities is waived if the app has been granted the exact alarm permission, and it is making changes to audio streams that have the USAGE_ALARM attribute".
  - Failures are silent: playback is muted, focus returns `AUDIOFOCUS_REQUEST_FAILED`, volume calls are ignored.
  - Test with `adb shell cmd audio set-enable-hardening <enable|disable|throw>`; failures are logged with the prefix `AudioHardening`.
  - Our design (audio only inside `RingService`, `USAGE_ALARM`, exact permission held) is compliant for target 36 and 37.
  - **UNVERIFIED:** how system `TextToSpeech` playback is classified, since the engine process plays the audio. See §8 for the "synthesize to file, play with MediaPlayer" workaround.
  - Also when targeting 37: the large-screen orientation opt-out is removed. [A17-T]

---

## 4. Audio, vibration, wake lock

### 4.1 MediaPlayer on the alarm stream
- `setAudioAttributes` "must call this method before prepare()" [MP-REF]. `MediaPlayer.create(ctx, resId)` **is already prepared, so its audio attributes cannot be changed**. Do not use it for alarm audio. [MP-REF]
- `AudioAttributes.USAGE_ALARM` is the value "to use when the usage is an alarm"; `CONTENT_TYPE_SONIFICATION`. [AA-REF]
- Raw resource from the library module: `Uri.parse("android.resource://${ctx.packageName}/${R.raw.x}")` with `setDataSource(ctx, uri)`. This is a standard scheme (UNVERIFIED in this session). For a notification **channel** sound, the docs warn not to use `android.resource` URIs because resource ids can change on upgrade. [NC-REF]
- Minimal disk: default alarm tone via `RingtoneManager.getActualDefaultRingtoneUri(ctx, RingtoneManager.TYPE_ALARM) ?: RingtoneManager.getDefaultUri(TYPE_ALARM)`; downloaded dua MP3s via `setDataSource(absolutePath)` on files the app owns (UNVERIFIED in this session; standard APIs).

```kotlin
val attrs = AudioAttributes.Builder()
    .setUsage(AudioAttributes.USAGE_ALARM)
    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
    .build()
player = MediaPlayer().apply {
    setAudioAttributes(attrs)                 // before prepare()
    setDataSource(this@RingService, soundUri) // file path, content://, or android.resource://
    isLooping = true
    setVolume(0.2f, 0.2f)                     // relative to STREAM_ALARM volume; fade up with a Handler
    setOnErrorListener { _, _, _ -> playFallbackTone(); true }
    prepare()                                 // local file → fast; else prepareAsync + setOnPreparedListener
    start()
}
```
- **Volume.** Prefer `MediaPlayer.setVolume` for fades and leave the system alarm volume to the user. `AudioManager.setStreamVolume(STREAM_ALARM, …)` works but is governed by Android 17 hardening (allowed for us: exact permission plus `USAGE_ALARM`). [A17-AUDIO] Wrap it in try/catch (UNVERIFIED DND edge cases).
- **Audio focus.** Use `AudioFocusRequest.Builder(AUDIOFOCUS_GAIN_TRANSIENT).setAudioAttributes(attrs)`. The `alarm` package uses `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK` with the same `USAGE_ALARM` attributes [ALARM-PKG]. Since Android 12 the system fades out the previous player on focus loss, while before 12 focus is not enforced [FOCUS]. Since Android 15 the request needs the top app or an FGS [A15-T]. During a phone call focus may fail; decide whether to vibrate only.
- **DND.** AOSP `ZenModeFiltering.isAlarm()` is `CATEGORY_ALARM || USAGE_ALARM`. In priority mode alarms pass if `policy.allowAlarms()`; in "alarms only" mode they pass; in "total silence" (`ZEN_MODE_NO_INTERRUPTIONS`) **everything is blocked, including alarms**. [AOSP-ZEN] That alarms are allowed by default in the DND policy is UNVERIFIED (believed true).

### 4.2 Vibration
- `Vibrator.vibrate(VibrationEffect, VibrationAttributes)` (API 33): "Background apps should specify a ringtone, notification or alarm usage in order to vibrate". `VibrationAttributes.USAGE_ALARM` is API 30 and `createForUsage` is API 33. The API 26 overload `vibrate(effect, AudioAttributes)` is deprecated in 33. [VIB-REF][VA-REF]
```kotlin
val vib = if (Build.VERSION.SDK_INT >= 31) getSystemService(VibratorManager::class.java).defaultVibrator
          else @Suppress("DEPRECATION") getSystemService(Vibrator::class.java)
val pattern = longArrayOf(0, 800, 600)
when {
    Build.VERSION.SDK_INT >= 33 -> vib.vibrate(VibrationEffect.createWaveform(pattern, 0),
        VibrationAttributes.createForUsage(VibrationAttributes.USAGE_ALARM))
    Build.VERSION.SDK_INT >= 26 -> @Suppress("DEPRECATION") vib.vibrate(VibrationEffect.createWaveform(pattern, 0),
        AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build())
    else -> @Suppress("DEPRECATION") vib.vibrate(pattern, 0)
}
// stop: vib.cancel()
```
Needs `<uses-permission android:name="android.permission.VIBRATE"/>`. [PERM-REF]

### 4.3 Wake lock
- `PARTIAL_WAKE_LOCK`: "Ensures that the CPU is running". It needs `WAKE_LOCK`. [PM-REF][PERM-REF]
- Acquire it with a timeout equal to the ring duration plus a margin, and release it on stop. The alarm package switched in 5.13.4 from "held for 5 minutes" to releasing on stop. [ALARM-PKG]
```kotlin
wakeLock = getSystemService(PowerManager::class.java)
    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "duas:ring")
    .apply { setReferenceCounted(false); acquire(ringMs + 15_000L) }
// stop: wakeLock?.takeIf { it.isHeld }?.release()
```
- The screen is turned on by the full-screen intent and `RingActivity.turnScreenOn`, not by a wake lock. `TURN_SCREEN_ON` (API 34) is "intended to only be used by home automation apps", so it is not needed. [PERM-REF]

---

## 5. Notification

### 5.1 Facts (VERIFIED)
- `setFullScreenIntent(pi, highPriority)`: [NB-REF]
  - "Only for use with extremely high-priority notifications … alarm clock".
  - Needs `USE_FULL_SCREEN_INTENT` when targeting Q+.
  - **From API 33, while the user is using the device, the system shows a heads-up notification (HUN) instead of launching the intent.** With the permission the HUN is persistent; without it the notification shows as heads-up "even when the screen is locked … only … persistent for 60 seconds".
  - "the notification must also be posted to a channel with importance level set to IMPORTANCE_HIGH".
  - Consequence: Done and Snooze **must be notification actions**, because an unlocked user only sees the HUN.
- Locked device: the full-screen activity covers the lock screen. Unlocked device: an expanded notification. [N-BUILD]
- `NotificationManager.canUseFullScreenIntent()` (API 34). If denied, the notification shows "as an expanded heads up notification on lockscreen". Request access with `Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT`, whose data URI must be `package:<pkg>`. [NM-REF][SET-REF]
- **Sideloaded apps:** "For apps installed on Android 14 and higher, the USE_FULL_SCREEN_INTENT permission is enabled by default"; the **Play Store** revokes it for non-alarm, non-calling apps. Third-party installers can set the state through `PackageInstaller.SessionParams`. So a sideloaded APK installed by a plain package installer should hold it, but check `canUseFullScreenIntent()` at runtime anyway (OEM behaviour UNVERIFIED). [FSI-AOSP]
- `POST_NOTIFICATIONS` is a **dangerous** runtime permission (API 33). On a fresh install on 13+, notifications are **off by default**. If it is denied, FGS notices appear only in the Task Manager, not the drawer. [PERM-REF][N-PERM]
  - Whether FSI still fires with notifications blocked is not documented (UNVERIFIED; assume **no**). Request the permission in onboarding.
- `NotificationChannel.setBypassDnd(true)` works only for apps with DND policy access, and only if the user has not edited the channel; otherwise only the system can change it. It is not needed: `CATEGORY_ALARM` already passes DND whenever alarms are allowed (§4.1). [NC-REF][AOSP-ZEN]
- `NotificationChannel.setSound(uri, attrs)` is only modifiable **before** `createNotificationChannel`. Changing the sound later needs a new channel id. [NC-REF]
- Ongoing notifications:
  - Android 14: `FLAG_ONGOING_EVENT` notifications are user-dismissible except when the phone is locked, or for CallStyle, media and DPC notifications. [A14-ALL]
  - `setOngoing` doc: they cannot be dismissed "on locked devices". [NB-REF]
  - Since Android 13 an FGS notification can be swiped while unlocked. The alarm package handles this with `setDeleteIntent`, either re-posting or stopping. [ALARM-PKG]
- Trampolines: since Android 12, a receiver or service launched from a notification tap or action **cannot `startActivity()`**. Use `PendingIntent.getActivity` directly for "open" taps. [A12-T]

### 5.2 Code
```kotlin
const val CH_RING = "dua_ring_v1"        // bump suffix to change channel config
const val CH_MISSED = "dua_missed_v1"

fun ensureChannels(c: Context) {
    if (Build.VERSION.SDK_INT < 26) return
    val nm = c.getSystemService(NotificationManager::class.java)
    nm.createNotificationChannel(NotificationChannel(CH_RING, "Dua alarms", NotificationManager.IMPORTANCE_HIGH).apply {
        setSound(null, null)              // RingService plays the audio on the alarm stream
        enableVibration(false)            // RingService vibrates
        lockscreenVisibility = Notification.VISIBILITY_PUBLIC
    })
    nm.createNotificationChannel(NotificationChannel(CH_MISSED, "Missed duas", NotificationManager.IMPORTANCE_DEFAULT))
}

fun buildRinging(c: Context, r: Ring): Notification {
    val full = PendingIntent.getActivity(c, r.notifCode,
        Intent(c, RingActivity::class.java).putExtras(r.toBundle())
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_USER_ACTION),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    val b = NotificationCompat.Builder(c, CH_RING)
        .setSmallIcon(R.drawable.ic_dua_notif)          // tiny vector drawable in the plugin
        .setContentTitle(r.title).setContentText(r.body)
        .setCategory(NotificationCompat.CATEGORY_ALARM)
        .setPriority(NotificationCompat.PRIORITY_MAX)   // pre-O devices
        .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        .setOngoing(true).setAutoCancel(false)
        .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        .setFullScreenIntent(full, true)
        .setContentIntent(full)
        .setDeleteIntent(actionPI(c, ActionReceiver.ACTION_SWIPED, r))  // Android 13/14 swipe
        .addAction(0, "Done", actionPI(c, ActionReceiver.ACTION_DONE, r))
    if (r.snoozesLeft > 0) b.addAction(0, "Snooze", actionPI(c, ActionReceiver.ACTION_SNOOZE, r))
    return b.build()
}

fun actionPI(c: Context, action: String, r: Ring) = PendingIntent.getBroadcast(c, r.notifCode,
    Intent(c, ActionReceiver::class.java).setAction(action)
        .setData(Uri.parse("duas://act/${r.reminderId}/${r.occurrenceKey}")).putExtras(r.toBundle()),
    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
```
- The action is part of PendingIntent identity, so several actions can share a request code. [PI-REF][ALARM-PKG]
- Use separate notification IDs: `NOTIF_RINGING` (fixed, owned by the FGS) and `missedId(reminderId)` per reminder.

---

## 6. Showing UI over the lock screen and handing off to Flutter

### 6.1 Native `RingActivity` (recommended surface)
- `setShowWhenLocked` and `setTurnScreenOn` are API 27 and can also be set in the manifest. Show-when-locked keeps the activity "in the resumed state visible on-top of the lock screen". [ACT-REF]
- `requestDismissKeyguard(activity, cb)` (API 26): on a secure keyguard it "will bring up the UI so the user can enter their credentials". It is **not needed to show** the ring screen; use it only before "Open app". [KG-REF]
  - Since 5.7.1 the alarm package only calls it when `!isDeviceSecure`. [ALARM-PKG]
- The alarm package's documented pattern for a custom alarm screen [ALARM-PKG]:
  - `launchMode="singleInstance"`, its own `taskAffinity`, `excludeFromRecents="true"`, `showWhenLocked="true"`, `turnScreenOn="true"`, `exported="false"`. It is reached through a PendingIntent, so it can stay unexported.
  - "a full screen intent starts the process without starting Flutter".
  - The same PendingIntent should be both the FSI and the content intent.

```xml
<activity android:name=".RingActivity" android:exported="false"
    android:launchMode="singleInstance" android:taskAffinity="${applicationId}.ring"
    android:excludeFromRecents="true" android:showWhenLocked="true" android:turnScreenOn="true"
    android:theme="@android:style/Theme.DeviceDefault.NoActionBar"/>
```
```kotlin
class RingActivity : Activity() {
    override fun onCreate(s: Bundle?) {
        super.onCreate(s)
        if (Build.VERSION.SDK_INT >= 27) { setShowWhenLocked(true); setTurnScreenOn(true) }
        else @Suppress("DEPRECATION") window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // Build UI in code (Arabic TextView, Done/Snooze/Open buttons); apply system-bar insets
        // (edge-to-edge is enforced at target 35/36 [A15-T][A16-T]) via ViewCompat.setOnApplyWindowInsetsListener.
        // Observe an in-process RingBus; finish() when RingService reports the ring ended.
    }
    private fun openApp(r: Ring) {
        Store.setPendingLaunch(this, r.toJson())            // mailbox, read by the plugin / Python
        val go = { startActivity(packageManager.getLaunchIntentForPackage(packageName)!!
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra(EXTRA_ALARM_JSON, r.toJson())); finish() }
        val km = getSystemService(KeyguardManager::class.java)
        if (Build.VERSION.SDK_INT >= 26 && km.isKeyguardLocked)
            km.requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
                override fun onDismissSucceeded() = go() })
        else go()
    }
}
```
- `${applicationId}` placeholders in library manifests are standard manifest-merger behaviour (UNVERIFIED in this session).
- If an existing task is brought to the front by the launcher intent, the extras may **not** reach `onNewIntent`, hence the mailbox. This is standard Android task behaviour (UNVERIFIED in this session).

### 6.2 Using Flet's `MainActivity` instead (possible, not recommended)
- Flet's `MainActivity` is a `FlutterFragmentActivity` (`singleTop`, `taskAffinity=""`). [FLET-TPL]
- `setShowWhenLocked(true)` and `setTurnScreenOn(true)` can be called at runtime from `ActivityAware.onAttachedToActivity`. This is exactly what the alarm package does in an `Observer` while ringing, and it **reverts to false afterwards** so the normal UI is never shown over the lock screen. [ALARM-PKG]
- Timing: `FlutterFragmentActivity.onCreate` commits the `FlutterFragment` asynchronously (`.commit()`), and `onAttachedToActivity` fires from the fragment's `onAttach` before resume [FL-EMB]. The flags take effect "whenever the lockscreen is up and the activity is resumed" [ACT-REF], so attach-time is early enough.
- Drawback: cold start needs the Flutter engine plus Python (serious_python), probably several seconds (UNVERIFIED for this app).

### 6.3 New intents and launch data in the plugin (VERIFIED from Flutter 3.44.8 sources)
- `ActivityPluginBinding.addOnNewIntentListener(PluginRegistry.NewIntentListener)`, where `boolean onNewIntent(Intent)`. [FL-EMB]
- The dispatch path is `FlutterFragmentActivity.onNewIntent` → `flutterFragment.onNewIntent` → delegate → `FlutterEngineConnectionRegistry.onNewIntent`. That method calls **every** listener; the boolean result does **not** stop propagation. [FL-EMB]
- `FlutterFragmentActivity.onNewIntent` does **not** call `setIntent()`, so `activity.intent` keeps the original launch intent. Capture data in the listener. The alarm package's guide calls `setIntent(intent)` in its own `MainActivity` for the same reason. [FL-EMB][ALARM-PKG]
- Behaviour per launch mode: a cold start delivers the intent via `onCreate` (read `binding.activity.intent` in `onAttachedToActivity`); a `singleTop` activity already at the top gets `onNewIntent`; if it is not at the top, a new instance may be created. [ALARM-PKG]
- "Don't push the value to Dart; let Dart pull it": Dart handlers may not be installed yet when the activity is created. [ALARM-PKG] For Flet this applies doubly, because Python starts later. Use **pull** (`get_pending_launch()`) plus an event when the engine is ready.
- Avoid putting a data URI on intents aimed at `MainActivity`: the delegate may treat it as an initial route or deep link (`maybeGetInitialRouteFromIntent`). [FL-EMB]

```kotlin
class DuaNativePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    PluginRegistry.NewIntentListener {
    private var binding: ActivityPluginBinding? = null
    override fun onAttachedToActivity(b: ActivityPluginBinding) {
        binding = b; b.addOnNewIntentListener(this); capture(b.activity.intent)
    }
    override fun onNewIntent(intent: Intent): Boolean { capture(intent); return false }
    private fun capture(i: Intent?) {
        i?.getStringExtra(EXTRA_ALARM_JSON)?.let { Store.setPendingLaunch(ctx, it); emit("launch", it) }
    }
    override fun onDetachedFromActivity() { binding?.removeOnNewIntentListener(this); binding = null }
    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) = onAttachedToActivity(b)
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    // onAttachedToEngine: create channel, Notifier.ensureChannels(ctx), AlarmScheduler.rearmAll(ctx) (idempotent)
}
```

---

## 7. Re-arming after reboot, time change, update, permission grant

### 7.1 Broadcast facts (VERIFIED)
| Broadcast | Facts |
|---|---|
| `BOOT_COMPLETED` | Needs `RECEIVE_BOOT_COMPLETED`; "the user is unlocked"; **on 15+ also delivered when the app leaves the stopped state** (first launch after force-stop). Protected (system-only). [INTENT-REF] Works only if the app was launched at least once. [AM-SCHED] |
| `LOCKED_BOOT_COMPLETED` (API 24) | Before first unlock; only device-protected storage; the receiver must be `directBootAware`. Same 15+ stopped-state note. [INTENT-REF][DIRECT-BOOT] |
| `MY_PACKAGE_REPLACED` | "only sent to the application that was replaced", so it is **explicit** and not subject to the implicit-broadcast ban; protected. [INTENT-REF] AOSP keeps alarms across updates (`ACTION_PACKAGE_REMOVED` with `EXTRA_REPLACING` → "don't kill its alarms") but re-checks exact permission on update. [AOSP-AMS] |
| `TIME_SET` (`ACTION_TIME_CHANGED`), `TIMEZONE_CHANGED` | Both in the implicit-broadcast exemption list, so manifest receivers still get them [BCAST-EX]. Both are FGS-start exemptions [FGS-BG]. AOSP sends `TIMEZONE_CHANGED` with an FGS-allowed temporary allowlist. [AOSP-AMS] |
| `SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED` | Sent to manifest receivers on grant only (§2.2). [AM-REF] |
| `NEXT_ALARM_CLOCK_CHANGED` | "only sent to registered receivers" (runtime only). [AM-REF] |

- All alarms are cancelled at shutdown. [AM-SCHED]
- **Force-stop** (Settings → Force stop) removes all of the uid's alarms. AOSP handles `ACTION_PACKAGE_RESTARTED` with `removeLocked(uid, …)`. [AOSP-AMS]
  - On 15+ all pending intents are also cancelled. [A15-ALL]
  - Alarms stay dead **until the user opens the app again**. On 15+ that open triggers `BOOT_COMPLETED`; on ≤14 rely on `rearmAll()` in plugin attach.
- **Task Manager "Stop"** (Android 13+ FGS drawer) is *not* a force-stop: "Alarms go off at their scheduled time". [FGS-STOP]
- On some OEMs, swiping the app away from Recents behaves like a force-stop (UNVERIFIED; commonly reported).

```xml
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
<receiver android:name=".SystemEventReceiver" android:exported="true">
  <intent-filter>
    <action android:name="android.intent.action.BOOT_COMPLETED"/>
    <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
    <action android:name="android.intent.action.TIME_SET"/>
    <action android:name="android.intent.action.TIMEZONE_CHANGED"/>
    <action android:name="android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED"/>
  </intent-filter>
</receiver>
<receiver android:name=".AlarmReceiver" android:exported="false"/>
<receiver android:name=".ActionReceiver" android:exported="false"/>
```
- `exported="true"` copies the alarm package's `BootReceiver` [ALARM-PKG]. In `onReceive`, check `intent.action` against the list and ignore anything else; spoofing can only cause a harmless re-arm.
- Whether the system delivers these broadcasts to `exported="false"` receivers was not verified (UNVERIFIED).

**Boot handling rules** (the alarm package's lessons): [ALARM-PKG]
- Never ring from the boot receiver. For an occurrence missed while powered off, either post a "missed" notification (alarm package: discard if older than `androidStaleAfter`, default 15 min) or, if within a short grace period, arm a ring for **now + 30 s** through `setAlarmClock`.
- A failed re-arm keeps the record for a later retry.
- `LOCKED_BOOT_COMPLETED` / direct boot: optional. It requires a `directBootAware` receiver, ring service and activity, and storage via `createDeviceProtectedStorageContext()` (`moveSharedPreferencesFrom` for migration). [DIRECT-BOOT]
  - Recommendation: **skip** it, so alarms resume after the first unlock post-reboot. Document this trade-off in the UI.

### 7.2 Next occurrence and DST (java.time)
- `java.time` is native from **API 26**. A subset is available below 26 through core-library desugaring, which **only the app module** needs to enable (`isCoreLibraryDesugaringEnabled` plus `desugar_jdk_libs` 2.x on AGP 7.4+). [J8]
  - Flet's app `build.gradle.kts` has no desugaring hook, and editing the generated project is not practical. [FLET-TPL]
  - Options: (a) set `[tool.flet.android] min_sdk_version = 26` and plugin `minSdk 26`, which the merger requires because a library minSdk above the app's fails the build (standard, UNVERIFIED here); or (b) keep minSdk 24 and use `java.util.Calendar` on API 24–25.
- DST semantics: [ZDT]
  - Gap (spring forward): "the local date-time is adjusted to be later by the length of the gap".
  - Overlap (fall back): "the previous offset will be retained … otherwise the earlier offset"; `withEarlierOffsetAtOverlap()` and `withLaterOffsetAtOverlap()` select explicitly.
  - `plusDays` / `plusWeeks` keep wall-clock time: "adding one day is not the same as adding 24 hours".
- Python `zoneinfo` with `fold=0` resolves gaps and overlaps to the same instants (PEP 495 semantics, from memory, UNVERIFIED here), so the Python and Kotlin calculations agree.

```kotlin
@RequiresApi(26)
fun nextWeekly(now: ZonedDateTime, dow: DayOfWeek, hour: Int, minute: Int): ZonedDateTime {
    val t = LocalTime.of(hour, minute)
    var d = now.toLocalDate().with(TemporalAdjusters.nextOrSame(dow))
    var z = ZonedDateTime.of(d, t, now.zone)          // gap → shifted later; overlap → earlier offset
    if (!z.isAfter(now)) { d = d.plusWeeks(1); z = ZonedDateTime.of(d, t, now.zone) }
    return z
}
// usage: nextWeekly(ZonedDateTime.now(ZoneId.systemDefault()), DayOfWeek.of(isoDay), h, m).toInstant().toEpochMilli()
```
- Why `TIMEZONE_CHANGED` matters: alarms are absolute UTC milliseconds (`RTC_WAKEUP`), so a zone change shifts the wall-clock meaning, and every slot must be recomputed.
- `TIME_SET` (manual clock change) keeps "07:00 local" correct for the same zone, but alarms now in the past fire immediately ("If the stated trigger time is in the past, the alarm will be triggered immediately"). [AM-REF] Recompute on both.
- DST transitions themselves send no broadcast. That is fine, because each slot is recomputed right after it fires and is never more than 7 days ahead.
- The process default zone updates in place after a zone change (`TimeZone.setDefault(null)` in AOSP's time-zone path for system_server; app-process behaviour UNVERIFIED). Recompute `ZoneId.systemDefault()` on each use and do not cache it.

---

## 8. Android TextToSpeech (Arabic), minimal Kotlin
VERIFIED from [TTS-REF] and [TTSE-REF]:
- The engine is usable only after `OnInitListener`; call `shutdown()` when done.
- Apps targeting 11+ must declare `<queries><intent><action android:name="android.intent.action.TTS_SERVICE"/></intent></queries>`.
- `setLanguage` and `isLanguageAvailable` return `LANG_AVAILABLE`, `LANG_COUNTRY_AVAILABLE`, `LANG_COUNTRY_VAR_AVAILABLE`, `LANG_MISSING_DATA` (-1) or `LANG_NOT_SUPPORTED` (-2).
- `setSpeechRate(1.0f = normal, 0.5f = half)`. `setAudioAttributes(…)` is API 21. `speak(text, QUEUE_FLUSH, params, utteranceId)` is asynchronous; use `UtteranceProgressListener` to detect completion or errors.
- `synthesizeToFile(text, params, File, utteranceId)` is API 21. `Engine.ACTION_INSTALL_TTS_DATA` opens the engine's voice-data installer.

```kotlin
class Speaker(ctx: Context, private val onReady: (Boolean) -> Unit) : TextToSpeech.OnInitListener {
    private val tts = TextToSpeech(ctx.applicationContext, this)
    override fun onInit(status: Int) {
        if (status != TextToSpeech.SUCCESS) return onReady(false)
        val ar = Locale.forLanguageTag("ar")          // Locale("ar") also works (constructor deprecated on newer JDKs)
        val r = tts.isLanguageAvailable(ar)
        if (r == TextToSpeech.LANG_MISSING_DATA || r == TextToSpeech.LANG_NOT_SUPPORTED) return onReady(false)
        tts.language = ar
        tts.setSpeechRate(0.85f)
        tts.setAudioAttributes(AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
        onReady(true)
    }
    fun say(text: String, id: String) = tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, id)
    fun toFile(text: String, out: File, id: String) = tts.synthesizeToFile(text, Bundle(), out, id)
    fun shutdown() = tts.shutdown()
}
// Missing data: startActivity(Intent(TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA).addFlags(FLAG_ACTIVITY_NEW_TASK))
```
- **Recommendation:** while the app is in the foreground (reminder save), `synthesizeToFile` the dua to `filesDir/tts/<id>.wav`, then ring with `MediaPlayer` (`USAGE_ALARM`).
  - This avoids engine cold-start latency and data-missing failures at ring time, and the Android 17 question of who plays the audio (UNVERIFIED).
  - Cost: WAV PCM is roughly 40–50 KB/s (UNVERIFIED estimate). Keep only active reminders' files; or speak live as a fallback.
- Arabic voice availability depends on the installed engine (Google TTS usually ships `ar`); this is UNVERIFIED per device. Check at runtime.

---

## 9. Battery, OEM killers, hibernation

### 9.1 Platform APIs (VERIFIED)
- `PowerManager.isIgnoringBatteryOptimizations(pkg)` reports whether the app is on the power allowlist. Being on it means "the system will not apply most power saving features … Guardrails … may still be applied". [PM-REF]
- `Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` needs `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (normal) and data `package:<pkg>`; "most applications should not use this". [SET-REF][PERM-REF]
- `ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS` opens the list screen and needs no permission. [SET-REF]
- Being allowlisted is also an FGS background-start exemption and makes `canScheduleExactAlarms()` true. [FGS-BG][AM-REF]
- Notification settings: [SET-REF]
  - `Settings.ACTION_APP_NOTIFICATION_SETTINGS` + `Settings.EXTRA_APP_PACKAGE`.
  - `ACTION_CHANNEL_NOTIFICATION_SETTINGS` + `EXTRA_CHANNEL_ID`.
  - `ACTION_APPLICATION_DETAILS_SETTINGS` + `package:` URI; may not exist, so guard it.
- App Standby buckets: Working set 10 alarms/h, Frequent 2/h, Rare 1/h, Restricted 1/day. In Doze, "while-idle" alarms are limited to 7/h. [POWER-LIMITS] Alarm clocks are exempt from standby [AOSP-AMS], and `USE_EXACT_ALARM` holders stay in WORKING_SET or better [PERM-REF].
- **Hibernation** ("Pause app activity if unused", after "a few months" of no use): runtime permissions are reset, and the app "Can't run jobs or alerts from background". **Scheduling alarms does NOT count as usage**; interacting with a notification does (dismissing alone does not). [HIBERNATION]
  - Check with `PackageManagerCompat.getUnusedAppRestrictionsStatus`; ask the user with `IntentCompat.createManageUnusedAppRestrictionsIntent(ctx, pkg)` and **`startActivityForResult`**.
  - Fallback: app-details settings plus a text instruction.

### 9.2 Per-vendor guidance (summarised from dontkillmyapp.com; key on `Build.MANUFACTURER`, case-insensitive; exact strings UNVERIFIED)
| Vendor | User steps to show in-app |
|---|---|
| **Samsung** (One UI) | Battery → Background usage limits: remove the app from *Sleeping* / *Deep sleeping* apps and add it to **Never sleeping apps**; turn off **Put unused apps to sleep**; disable Adaptive battery / Auto-optimize; set the app's battery to **Unrestricted**. Warning: unused-app sleep after about 3 days could stop alarms. July 2024: Samsung promised FGS work to spec from One UI 6 / Android 14. "No known solution on dev end". [DKMA-SAMSUNG] |
| **Xiaomi / Redmi / POCO** (MIUI / HyperOS) | Enable **Autostart**; Battery saver → **No restrictions**; lock the app in Recents; grant **Show on lock screen** and **Display pop-up windows while running in background** (needed for the full-screen ring activity). [DKMA-XIAOMI] |
| **Huawei / Honor** (EMUI / HarmonyOS) | Battery → App launch: switch the app to **Manage manually** and enable auto-launch, secondary launch and run in background; ignore battery optimisation; lock in Recents. PowerGenie is aggressive (the site suggests ADB removal, which is not for us). [DKMA-HUAWEI] |
| **Oppo / Realme** (ColorOS) | Startup manager / **Allow auto start-up**; Battery usage → **Allow background activity / Run in background**; lock in Recents. "No known solution on the dev end". [DKMA-OPPO] |
| **Vivo** (Funtouch / OriginOS) | **Autostart**; Battery → **High background power consumption** allow / Unrestricted; lock in Recents. [DKMA-VIVO] |
| **OnePlus** (OxygenOS) | Battery optimisation → **Don't optimize**; Advanced optimisation: disable **Deep optimization** and **Sleep standby optimization**; lock in Recents. Settings can reset after firmware updates. Recent OxygenOS is ColorOS-based, so Oppo steps may apply (UNVERIFIED). [DKMA-ONEPLUS] |

- Universal advice to show: "Don't force-stop the app; if you do, open it once so reminders are re-armed".
- The alarm package FAQ points to dontkillmyapp and battery-optimisation education. [ALARM-PKG]
- Avoid hardcoded OEM settings component names; they are fragile. Open app details instead (recommendation).

---

## 10. Play-policy one-liners (for code comments; irrelevant for this sideloaded APK)
```kotlin
// USE_EXACT_ALARM (API33+, auto-granted, not revocable): Play allows only if the app "is an alarm or timer app"
//   or "a calendar app that shows event notifications"; else use SCHEDULE_EXACT_ALARM. [PLAY-PERM][PERM-REF]
// SCHEDULE_EXACT_ALARM maxSdkVersion=32: user/system-revocable special access ("Alarms & reminders");
//   exact alarms only for user-facing features. [PERM-REF][AM-SCHED]
// USE_FULL_SCREEN_INTENT: Play auto-grants only to core alarm / calling apps (since 2024-05-31; others need
//   user grant from 2025-01-22); check canUseFullScreenIntent(), deep-link ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT. [PLAY-FGS][FSI-AOSP]
// FOREGROUND_SERVICE_SYSTEM_EXEMPTED: normal perm; type valid only while holding an exact-alarm permission,
//   else ForegroundServiceTypeNotAllowedException; not in Play's FGS-declaration type list. [FGS-TYPES][PLAY-FGS]
// FOREGROUND_SERVICE_MEDIA_PLAYBACK: Play Console FGS declaration (description + video) when targeting 34+;
//   cannot be started from BOOT_COMPLETED when targeting 35+. [PLAY-FGS][A15-T]
// REQUEST_IGNORE_BATTERY_OPTIMIZATIONS: Play prohibits requesting direct Doze/Standby exemption unless the core
//   function is adversely affected (see acceptable-use table). [DOZE]
// RECEIVE_BOOT_COMPLETED: normal permission; must be declared to receive BOOT_COMPLETED. [PERM-REF]
// POST_NOTIFICATIONS: dangerous runtime permission (API33+); notifications are off by default on fresh installs. [PERM-REF][N-PERM]
// RECORD_AUDIO: dangerous runtime permission; Play: request only for features promoted in the listing;
//   record only while visible (an FGS needing the mic cannot start from background on 14+). [PLAY-PERM][FGS-BG]
// FOREGROUND_SERVICE, WAKE_LOCK, VIBRATE: normal permissions. [SVC-REF][PERM-REF]
```

---

## 11. Recommended end-to-end design for `flet_dua_native` (Android side)

### 11.1 Components
| Class | Responsibility |
|---|---|
| `Store` | SharedPreferences `flet_dua_native` holding JSON strings via `org.json`; no extra dependency. Keys: `reminders` (full config pushed from Python), `occ.<rid>` (state of the current occurrence), `pending_launch`, `events` (bounded ring buffer, about 100). Use `commit()` from receivers for durability (UNVERIFIED necessity; it is cheap). |
| `NextOccurrence` | `nextWeekly(...)` (§7.2) plus a `Calendar` fallback if minSdk stays 24. |
| `AlarmScheduler` | `arm`, `cancel`, `armWeekly(rid, isoDay)`, `armChain(rid, kind, at)`, `rearmAll()` (cancel orphans, arm all enabled `w1..w7` slots and any pending `x` chain), `canExact`. |
| `AlarmReceiver` | `ACTION_FIRE`: (1) if `kind=weekly`, immediately arm next week's same slot so the chain never depends on the ring succeeding; (2) build `Ring` from extras plus Store; (3) `ContextCompat.startForegroundService(RingService)`; on `IllegalStateException` (`ForegroundServiceStartNotAllowedException` extends it), post the missed notification and arm a retry (+30 s, once). |
| `RingService` | FGS (§3). Order: `startForeground`, wake lock, audio focus, `MediaPlayer` (`USAGE_ALARM`, loop) or a TTS file, vibration, `Handler.postDelayed(timeout, ringMs = 120_000)`. Queues rings that arrive while ringing. On end: stop audio and vibration, abandon focus, `ServiceCompat.stopForeground(STOP_FOREGROUND_REMOVE)`, release the wake lock, start the next queued ring or `stopSelf()`. Return `START_NOT_STICKY`; a sticky restart has no alarm context (alarm package lesson). [ALARM-PKG] |
| `ActionReceiver` | `DONE` / `SNOOZE` / `SKIP` / `SWIPED` / `MISSED_DONE`. Mutate Store, re-arm or cancel, then `RingService.instance?.finish(rid)` in-process; if the service is gone, just cancel the notification (alarm package lesson: never start an FGS just to stop). No `startActivity` here (trampoline ban). [A12-T][ALARM-PKG] |
| `SystemEventReceiver` | Boot, replaced, time, tz, exact-permission grant → `rearmAll()` plus the missed-while-off policy (§7.1). |
| `RingActivity` | Lock-screen UI (§6.1); buttons call the same paths as `ActionReceiver`; "Open app" goes through the mailbox. |
| `Notifier` | Channels, ringing notification (FSI), missed notification (persistent, with "Done" action, content → `RingActivity` or the app launch intent), diagnostics. |
| `Speaker` | TTS (§8). |
| `DuaNativePlugin` | MethodChannel bridge for the Flet service. Methods: `setReminders(json)`, `rearm()`, `status()`, `openSettings(kind)`, `requestNotificationPermission()`, `getPendingLaunch()`, `drainEvents()`, `testRing(rid)`, `speak(text, lang, rate)`, `synthesize(text, path)`. Pushes `launch` / `event` to Dart when attached; otherwise the data waits in Store. |

`status()` returns:
- `sdk`, `manufacturer`
- `canScheduleExact`, `canUseFullScreenIntent` (34+, else true)
- `notificationsEnabled` (`NotificationManagerCompat.areNotificationsEnabled`)
- `ignoringBatteryOptimizations`
- `nextAlarmClockMs` and `nextAlarmIsOurs`

`openSettings(kind)` covers: exact alarm, FSI, battery request, battery list, notifications, app details, unused-app restrictions, TTS install.

### 11.2 Ring lifecycle (per occurrence key = `rid@yyyy-mm-dd`)
1. **Weekly fire.** The `w<d>` slot fires at the time from `NextOccurrence`; the receiver re-arms `w<d>` for next week (no app involvement) and starts the ring.
2. **Ring.** Up to 2 min. Notification actions Done / Snooze (Snooze shown while `snoozes < N`), plus the full-screen `RingActivity` when locked.
3. **Done.** Mark `done`, `cancel(rid,"x")`, finish the ring, log a `done` event for Python's SQLite statistics.
4. **Snooze.** `snoozes++`, `armChain(rid, SNOOZE, now + snoozeMin)` on the `x` slot, finish the ring without marking missed.
5. **Timeout (auto-stop at 2 min).** Mark `missed`, stop ringing, post a **persistent missed notification**.
   - The missed notification has `CH_MISSED`, `setOngoing(true)` (still user-dismissible on 14+ when unlocked [A14-ALL]), and actions "Done" and "Skip today".
   - If `nags < K`, then `nags++` and `armChain(rid, NAG, now + M min)`. The nag rings again exactly like a ring, with the same 2-min timeout.
6. **Skip today.** Cancel `x`, mark `skipped`, remove the missed notification. If the app skips **before** the fire time (UI action), cancel `w<d>` and re-arm it for the following week.
7. **Swipe while ringing** (Android 13/14 lets users swipe) → treat as "silence now, keep nagging" (same as Timeout). Alternatively re-post it, as the alarm package's `androidStopAlarmOnDismiss=false` does. [ALARM-PKG]
8. Use `setAlarmClock` for chain alarms too: `setExactAndAllowWhileIdle` is limited to about 1 per 9–15 min in Doze, which would distort snooze or nag timing. [DOZE][AM-REF]
9. Every state transition appends an event to Store. Python drains the events when it starts or resumes, so Python never has to run in the background.

### 11.3 Hand-off to Python / Flet
- The native side owns scheduling. Python sends the full reminder list (`setReminders`); native writes it to Store and calls `rearmAll()`.
- Launch hand-off: native writes `pending_launch` (mailbox) and, if the engine is attached, emits a `launch` event. Python calls `getPendingLaunch()` on startup and on resume, which reads and clears it.
- Dart side (Flet extension): `FletService` relays Python `_invoke_method` calls to the MethodChannel and turns Kotlin→Dart calls into `control.triggerEvent(...)`, per the Flet extension pattern noted in the project context. The Dart code was not re-verified here.

### 11.4 Onboarding checklist (in order)
1. `POST_NOTIFICATIONS` runtime request on 33+, using `ActivityCompat.requestPermissions` plus `binding.addRequestPermissionsResultListener`, or `flet_permission_handler`'s `NOTIFICATION`.
2. `canUseFullScreenIntent()` on 34+; otherwise deep-link to the FSI settings screen.
3. `canScheduleExactAlarms()` (only API 31–32 can be false for us).
4. Battery: `isIgnoringBatteryOptimizations`, otherwise `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (fine for sideload).
5. Unused-app restrictions (hibernation).
6. OEM card from §9.2 when the manufacturer matches.
7. "Test alarm in 1 minute" button: arms a real `setAlarmClock` for now + 60 s, then the user locks the phone.

---

## 12. Test commands (adb)
| Purpose | Command | Status |
|---|---|---|
| Force Doze / exit | `adb shell dumpsys deviceidle force-idle` / `unforce`; `adb shell dumpsys battery reset` | VERIFIED [DOZE] |
| App Standby | `adb shell dumpsys battery unplug; adb shell am set-inactive <pkg> true` | VERIFIED [DOZE] |
| Task Manager stop (alarms must survive) | `adb shell cmd activity stop-app <pkg>` | VERIFIED [FGS-STOP] |
| Android 17 audio hardening | `adb shell cmd audio set-enable-hardening throw` | VERIFIED [A17-AUDIO] |
| List our alarms | `adb shell dumpsys alarm` (search for the package) | UNVERIFIED format |
| Force-stop (alarms must vanish; on 15+ they come back when the app is opened) | `adb shell am force-stop <pkg>` | UNVERIFIED behaviour check |
| FGS state | `adb shell dumpsys activity services <pkg>` | UNVERIFIED |
| Reboot path | `adb reboot` (shell cannot send the protected `BOOT_COMPLETED`) | UNVERIFIED |

---

## 13. Open questions / UNVERIFIED items to confirm on the device
1. That `systemExempted` works as declared alongside `mediaPlayback` in a single `foregroundServiceType` on API 29–33 (unknown 0x400 bit in the manifest on older platforms).
2. That FSI fires when `POST_NOTIFICATIONS` is denied (assume not).
3. That the OEM grants `USE_FULL_SCREEN_INTENT` by default for a sideloaded APK on the actual phone; check `canUseFullScreenIntent()`.
4. The TTS engine audio path under Android 17 hardening; prefer pre-synthesised files.
5. `taskAffinity=""` on Flet's `MainActivity` combined with `FLAG_ACTIVITY_NEW_TASK` from `RingActivity`: whether it creates a second task or instance. The mailbox design makes this harmless.
6. The alarm package's 20 s post-boot FGS taint (only relevant to `mediaPlayback`).
7. The Kotlin DSL `kotlin {}` accessor in a `.kts` plugin build under AGP 8 with FGP's auto-applied KGP; use Groovy to avoid it.
8. Exact `Build.MANUFACTURER` strings: "samsung", "Xiaomi", "OPPO", "vivo", "HUAWEI", "HONOR", "OnePlus", "realme" (compare lowercase).

---

## Sources (all fetched or read 2026-10-06 unless noted; "upd" = page's own last-updated date)
| Tag | URL |
|---|---|
| AM-SCHED | https://developer.android.com/develop/background-work/services/alarms/schedule (upd 2026-10-01) |
| AM-REF | https://developer.android.com/reference/android/app/AlarmManager |
| A12-T | https://developer.android.com/about/versions/12/behavior-changes-12 |
| A14-EXACT | https://developer.android.com/about/versions/14/changes/schedule-exact-alarms (upd 2026-03-03) |
| A14-ALL | https://developer.android.com/about/versions/14/behavior-changes-all |
| A14-T | https://developer.android.com/about/versions/14/behavior-changes-14 |
| A15-T | https://developer.android.com/about/versions/15/behavior-changes-15 |
| A15-ALL | https://developer.android.com/about/versions/15/behavior-changes-all |
| A16-T | https://developer.android.com/about/versions/16/behavior-changes-16 |
| A16-ALL | https://developer.android.com/about/versions/16/behavior-changes-all |
| A17 | https://developer.android.com/about/versions/17 (upd 2026-07-01) |
| A17-T | https://developer.android.com/about/versions/17/behavior-changes-17 |
| A17-ALL | https://developer.android.com/about/versions/17/behavior-changes-all |
| A17-AUDIO | https://developer.android.com/about/versions/17/changes/bg-audio |
| FGS-TYPES | https://developer.android.com/develop/background-work/services/fgs/service-types |
| FGS-BG | https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start |
| FGS-LAUNCH | https://developer.android.com/develop/background-work/services/fgs/launch |
| FGS-TIMEOUT | https://developer.android.com/develop/background-work/services/fgs/timeout |
| FGS-CHANGES | https://developer.android.com/develop/background-work/services/fgs/changes |
| FGS-STOP | https://developer.android.com/develop/background-work/services/fgs/handle-user-stopping |
| SVC-REF | https://developer.android.com/reference/android/app/Service |
| SI-REF | https://developer.android.com/reference/android/content/pm/ServiceInfo |
| SC-REF | https://developer.android.com/reference/androidx/core/app/ServiceCompat |
| SC-SRC | https://github.com/androidx/androidx/blob/androidx-main/core/core/src/main/java/androidx/core/app/ServiceCompat.java |
| CORE-REL | https://developer.android.com/jetpack/androidx/releases/core (core stable 1.19.1) |
| PERM-REF | https://developer.android.com/reference/android/Manifest.permission |
| NB-REF | https://developer.android.com/reference/android/app/Notification.Builder |
| N-REF | https://developer.android.com/reference/android/app/Notification |
| NC-REF | https://developer.android.com/reference/android/app/NotificationChannel |
| NM-REF | https://developer.android.com/reference/android/app/NotificationManager |
| N-BUILD | https://developer.android.com/develop/ui/views/notifications/build-notification |
| N-PERM | https://developer.android.com/develop/ui/views/notifications/notification-permission |
| FSI-AOSP | https://source.android.com/docs/core/permissions/fsi-limits (upd 2026-06-17) |
| SET-REF | https://developer.android.com/reference/android/provider/Settings |
| ACT-REF | https://developer.android.com/reference/android/app/Activity |
| KG-REF | https://developer.android.com/reference/android/app/KeyguardManager |
| BAL | https://developer.android.com/guide/components/activities/background-starts |
| INTENT-REF | https://developer.android.com/reference/android/content/Intent |
| BCAST-EX | https://developer.android.com/develop/background-work/background-tasks/broadcasts/broadcast-exceptions (upd 2026-02-26) |
| DIRECT-BOOT | https://developer.android.com/privacy-and-security/direct-boot |
| DOZE | https://developer.android.com/training/monitoring-device-state/doze-standby (upd 2026-08-18) |
| STANDBY | https://developer.android.com/topic/performance/appstandby |
| POWER-LIMITS | https://developer.android.com/topic/performance/power/power-details |
| HIBERNATION | https://developer.android.com/topic/performance/app-hibernation |
| PM-REF | https://developer.android.com/reference/android/os/PowerManager |
| AA-REF | https://developer.android.com/reference/android/media/AudioAttributes |
| MP-REF | https://developer.android.com/reference/android/media/MediaPlayer |
| FOCUS | https://developer.android.com/media/optimize/audio-focus |
| VIB-REF | https://developer.android.com/reference/android/os/Vibrator |
| VA-REF | https://developer.android.com/reference/android/os/VibrationAttributes |
| TTS-REF | https://developer.android.com/reference/android/speech/tts/TextToSpeech |
| TTSE-REF | https://developer.android.com/reference/android/speech/tts/TextToSpeech.Engine |
| PI-REF | https://developer.android.com/reference/android/app/PendingIntent |
| J8 | https://developer.android.com/studio/write/java8-support |
| ZDT | https://docs.oracle.com/en/java/javase/17/docs/api/java.base/java/time/ZonedDateTime.html |
| AOSP-AMS | https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/apex/jobscheduler/service/java/com/android/server/alarm/AlarmManagerService.java |
| AOSP-ZEN | https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/services/core/java/com/android/server/notification/ZenModeFiltering.java |
| PLAY-PERM | https://support.google.com/googleplay/android-developer/answer/9888170 |
| PLAY-FGS | https://support.google.com/googleplay/android-developer/answer/13392821 |
| PLAY-DEADLINES | https://support.google.com/googleplay/android-developer/answer/12253906 |
| ALARM-PKG | https://pub.dev/packages/alarm (v5.15.0, published 2026-10-05; read from the pub archive) and https://github.com/gdelataillade/alarm: `android/src/main/AndroidManifest.xml`, `android/build.gradle`, `alarm/AlarmReceiver.kt`, `alarm/AlarmService.kt`, `alarm/BootReceiver.kt`, `alarm/AlarmPlugin.kt`, `services/AlarmScheduler.kt`, `services/NotificationService.kt`, `services/AudioService.kt`, `services/VolumeService.kt`, `services/VibrationService.kt`, `README.md`, `help/INSTALL-ANDROID.md`, `help/DETECT-ALARM-LAUNCH-ANDROID.md`, `CHANGELOG.md` |
| TZ-PKG | https://pub.dev/packages/flutter_timezone (`android/build.gradle` AGP 8/9 guard) |
| FL-EXT | https://github.com/flutter/flutter/blob/3.44.8/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt |
| FL-GU | https://github.com/flutter/flutter/blob/3.44.8/packages/flutter_tools/lib/src/android/gradle_utils.dart |
| FL-TPL | https://github.com/flutter/flutter/tree/3.44.8/packages/flutter_tools/templates (`plugin/android-kotlin.tmpl/build.gradle.kts.tmpl`, `plugin/android.tmpl/*`, `app/android*.tmpl/*`) |
| FL-FGP | https://github.com/flutter/flutter/blob/3.44.8/packages/flutter_tools/gradle/src/main/kotlin/FlutterPluginUtils.kt (+ `FlutterPlugin.kt`) |
| FL-EMB | https://github.com/flutter/flutter/tree/3.44.8/engine/src/flutter/shell/platform/android/io/flutter (`embedding/engine/plugins/activity/ActivityPluginBinding.java`, `embedding/android/FlutterFragmentActivity.java`, `embedding/android/FlutterActivityAndFragmentDelegate.java`, `embedding/engine/FlutterEngineConnectionRegistry.java`, `plugin/common/PluginRegistry.java`) |
| FL-POM | https://storage.googleapis.com/download.flutter.io/io/flutter/flutter_embedding_release/1.0.0-0cd610717bde95fd88343c64f81c11ba4e5c0010/flutter_embedding_release-1.0.0-0cd610717bde95fd88343c64f81c11ba4e5c0010.pom |
| FLET-TPL | https://github.com/flet-dev/flet/releases/download/v1.0.3/flet-build-template.zip and local `.venv/Lib/site-packages/flet_cli/commands/build_base.py` |
| DKMA-SAMSUNG / XIAOMI / HUAWEI / OPPO / VIVO / ONEPLUS | https://dontkillmyapp.com/samsung , /xiaomi , /huawei , /oppo , /vivo , /oneplus |
