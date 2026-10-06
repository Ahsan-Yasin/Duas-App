# Flutter media and platform packages: research notes

Project: Daily Duas (Flutter, Android sideloaded APK). Researched 2026-10-06.

## How this was verified

I downloaded each package from the pub.dev API on 2026-10-06 (`https://pub.dev/api/packages/<name>`, then its `archive_url`). For each one I checked:

- `pubspec.yaml`
- `android/build.gradle(.kts)`
- the plugin `AndroidManifest.xml`
- `README.md`
- `CHANGELOG.md`
- the Dart and Kotlin/Java source, where an API's behavior mattered

Claims that come from that source are marked **[verified]**. Claims I did not check against source or official docs are marked **[unverified]**. I did not run `flutter pub get`, because the SDK was still installing and I was told not to touch `D:\DuasSDK`. I compared the version constraints by hand, but the dependency solver has not confirmed them.

## 0. Toolchain facts that drive the Android setup

| Fact | Value | Source |
|---|---|---|
| Flutter 3.44.8 ships Dart | **3.12.2** | `releases_windows.json` (storage.googleapis.com/flutter_infra_release/releases) [verified] |
| Template `compileSdk` / `minSdk` / `targetSdk` | **36 / 24 / 36** | `flutter/flutter@3.44.8 packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt` [verified] |
| Template AGP / Gradle / Kotlin | **AGP 9.0.1 / Gradle 9.1.0 / KGP 2.3.20** | `flutter_tools/lib/src/android/gradle_utils.dart@3.44.8` [verified] |
| Template `gradle.properties` | `android.newDsl=false`, `android.builtInKotlin=false` | `templates/app/android.tmpl/gradle.properties.tmpl@3.44.8` [verified] |
| Template `ndkVersion` | 28.2.13676358 | `FlutterExtension.kt` [verified] |
| `INTERNET` permission | Only in the `src/debug` and `src/profile` manifests, **not in `src/main`**. A release APK has no network access until you add it to `src/main/AndroidManifest.xml`. | `templates/app/android.tmpl/app/src/{main,debug}/AndroidManifest.xml.tmpl@3.44.8` [verified] |
| Android SDK installed now under `D:\DuasSDK\home\Android\sdk` | Only `platforms;android-35` and `build-tools;34.0.0` | directory listing plus `install_sdks.log` [verified] |

**Consequence:** the first Gradle build will try to download `platforms;android-36`, the AGP 9 default build-tools (probably 36.x, **[unverified]**), NDK 28.2.13676358 and CMake. NDK and CMake are needed because `path_provider_android` 2.3.x now uses `package:jni`, which is an `ffiPlugin` built with CMake (see §7). The licenses are already accepted, so AGP should download these automatically. Pre-installing them with `sdkmanager` avoids a slow or failing first build on a bad connection.

### Flags: minSdk above 23, desugaring, compileSdk above 36, NDK

- **Plugin minSdk 24:**
  - `audio_session` 0.2.4
  - `record_android` 2.2.0 (the README still says 23; the changelog and gradle file say 24)
  - `flutter_tts` 4.2.5 (the README says 21; the gradle file says 24)
  - `permission_handler_android` 14.1.0
  - `url_launcher_android` 6.3.33
  - `flutter_local_notifications` (cross-reference)

  All are fine with the template default `minSdk = 24`. **None need more than 24.**
- **coreLibraryDesugaring:** none of the packages in this document need it. Only `flutter_local_notifications` does (cross-reference: `desugar_jdk_libs:2.1.4`, per its README).
- **compileSdk 37:** `permission_handler` 13.x, which pulls `permission_handler_android` 14.x, hard-codes `compileSdk = 37`. Its changelog says "make sure to also set the compileSdkVersion in app/build.gradle to 37". The Flutter template uses 36. This is one of the reasons I recommend **not** using permission_handler (see §6).
- **NDK/CMake:** `path_provider_android` 2.3.x, through `jni` 1.1.0 (`externalNativeBuild { cmake }`, `ndkVersion = flutter.ndkVersion`) [verified].
- **ProGuard/R8:** none of these packages need app-level keep rules. `android_file_picker` and `alarm` ship their own consumer rules [verified]. If you give the media notification a custom drawable icon, add `res/raw/keep.xml` with `tools:keep="@drawable/*"` (audio_service README) [verified].

---

## Summary table (latest on pub.dev, 2026-10-06)

| Package | Latest (published) | Dart / Flutter constraint | Works with Dart 3.12.2 / Flutter 3.44.8? | Android plugin minSdk / compileSdk | Use? |
|---|---|---|---|---|---|
| [just_audio](https://pub.dev/packages/just_audio) | **0.10.6** (2026-06-29) | `^3.6.0` / `>=3.27.0` | yes | 16 / 35 (media3 ExoPlayer 1.4.1) | **yes** |
| [just_audio_background](https://pub.dev/packages/just_audio_background) | **0.0.1-beta.17** (2025-05-13) | `^3.6.0` / `>=3.27.0` | yes | (uses audio_service) | **yes** |
| [audio_service](https://pub.dev/packages/audio_service) | 0.18.19 (2026-06-29) | `^3.6.0` / `>=3.27.0` | yes | 19 / 35 | transitive (only add directly if you outgrow JAB) |
| [audio_session](https://pub.dev/packages/audio_session) | **0.2.4** (2026-06-29) | `^3.6.0` / `>=3.27.0` | yes | **24** / 35 | **yes** |
| [record](https://pub.dev/packages/record) | **7.1.1** (2026-06-29) | `^3.12.0` / `>=3.44.0` | yes (exactly at the floor) | record_android 2.2.0: **24** / 36 | **yes** |
| [flutter_tts](https://pub.dev/packages/flutter_tts) | **4.2.5** (2026-01-05) | `>=3.4.0 <4.0.0` / `>=1.22.0` | yes | **24** / 36 | **yes** |
| [permission_handler](https://pub.dev/packages/permission_handler) | 13.0.2 (2026-09-04) | `^3.6.0` / `>=3.24.0` | yes, but needs **compileSdk 37** | 24 / **37** | no (see §6) |
| [app_settings](https://pub.dev/packages/app_settings) | 9.0.0 (2026-08-16) | `>=2.18.0 <4.0.0` / `>=3.3.0` | yes | 16 / 36 | no (redundant) |
| [android_intent_plus](https://pub.dev/packages/android_intent_plus) | 6.1.0 (2026-07-23) | `>=3.1.0 <4.0.0` / `>=3.12.0` | yes (README: AGP >= 8.13, template has 9.0.1) | 19 / flutter | optional |
| [file_picker](https://pub.dev/packages/file_picker) | **13.1.0** (2026-09-15) | `>=3.10.0 <4.0.0` / `>=3.38.0` | yes. **API rewritten in v12/v13** | android_file_picker 2.0.1: 21 / flutter | **yes** |
| [share_plus](https://pub.dev/packages/share_plus) | **13.3.1** (2026-10-01) | `>=3.10.0 <4.0.0` / `>=3.38.1` | yes | 21 / flutter | **yes** |
| [path_provider](https://pub.dev/packages/path_provider) | **2.1.6** (2026-06-15) | `^3.10.0` / `>=3.38.0` | yes (android impl 2.3.1 uses JNI, so NDK) | jni: 21 / 35 | **yes** |
| [url_launcher](https://pub.dev/packages/url_launcher) | **6.3.3** (2026-10-02) | `^3.11.0` / `>=3.41.0` | yes | url_launcher_android 6.3.33: **24** / flutter | **yes** |
| [package_info_plus](https://pub.dev/packages/package_info_plus) | **10.2.2** (2026-10-01) | `>=3.10.0 <4.0.0` / `>=3.38.1` | yes | 19 / flutter | **yes** |
| [wakelock_plus](https://pub.dev/packages/wakelock_plus) | **1.8.1** (2026-09-29) | `>=3.12.0 <4.0.0` / `>=3.44.0` | yes (exactly at the floor) | flutter.minSdkVersion / flutter | **yes** |
| [device_info_plus](https://pub.dev/packages/device_info_plus) | **13.3.0** (2026-10-01) | `>=3.10.0 <4.0.0` / `>=3.38.1` | yes | 21 / flutter | **yes** |
| [http](https://pub.dev/packages/http) | **1.6.0** (2025-11-10) | `^3.4.0` | yes | pure Dart | **yes** |
| [alarm](https://pub.dev/packages/alarm) (cross-ref) | 5.15.0 (2026-10-05) | `>=3.0.0 <4.0.0` / `>=3.41.0` | yes | 19 / 35 | (other doc) |

The constraints I cross-checked by hand look consistent:

- `rxdart`: just_audio and audio_service use `<0.29`; alarm uses `^0.28.0`.
- `win32 ^6`: the plus_plugins, `windows_file_picker` and `wakelock_plus` all agree.
- `meta ^1.17.0`: Flutter 3.44.8 pins `meta 1.18.0`.
- `package_info_plus`: wakelock_plus requires `>=10.1.0 <11`, and 10.2.2 is the latest.
- `just_audio_platform_interface 4.6.0` satisfies both just_audio (`^4.6.0`) and JAB (`^4.5.0`).

Note that audio_service transitively pulls in `flutter_cache_manager` and from there `sqflite`. That is harmless next to Drift but adds a little APK size.

---

## 1. just_audio 0.10.6

Sources:
- https://pub.dev/packages/just_audio
- changelog: https://pub.dev/packages/just_audio/changelog
- repo: https://github.com/ryanheise/just_audio

### Breaking changes in 0.10.0 [verified, CHANGELOG and README "Migrating to 0.10.x"]

- **New playlist API.** `player.setAudioSources(List<AudioSource>, {preload, initialIndex, initialPosition, shuffleOrder})` replaces `setAudioSource(ConcatenatingAudioSource(children: ...))`. `ConcatenatingAudioSource` is **deprecated**. Use these to change the playlist: `addAudioSource`, `insertAudioSource`, `removeAudioSourceAt`, `moveAudioSource`.
- `LoopingAudioSource` is deprecated. Use `...List.filled(N, source)` instead.
- `playbackEventStream.onError` is replaced by `player.errorStream` (`Stream<PlayerException>`, with `.code`, `.message`, `.index`).
- Skip-on-error is now opt-in through the constructor parameter `maxSkipsOnError` (default 0).
- 0.10.5: Android audio offload is **disabled by default** (`androidAudioOffloadPreferences`).
- 0.10.6: supports AGP 9. The Android build files are now `.kts`.

### Android setup [verified, README]

- `<uses-permission android:name="android.permission.INTERNET"/>` in **`src/main`**.
- everyayah is HTTPS, so **no cleartext is needed** for plain URL playback.
- Cleartext *is* needed for `LockCachingAudioSource`, `StreamAudioSource`, and `headers:` (when `useProxyForRequestHeaders` is true). These use a local proxy on `http://127.0.0.1`. Allow cleartext for `127.0.0.1` only, using `res/xml/network_security_config.xml` plus `android:networkSecurityConfig="@xml/network_security_config"`:

  ```xml
  <?xml version="1.0" encoding="utf-8"?>
  <network-security-config>
      <domain-config cleartextTrafficPermitted="true">
          <domain includeSubdomains="false">127.0.0.1</domain>
      </domain-config>
  </network-security-config>
  ```

- The README warns that AGP 8.6 and 8.7 have a release-mode ExoPlayer bug. The template uses AGP 9.0.1, so it is not affected.

### API snippets [signatures verified in `lib/just_audio.dart`]

```dart
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart'; // re-exports MediaItem

// ONE app-wide player (just_audio_background allows a single live instance; see §2).
final player = AudioPlayer(); // optional: maxSkipsOnError: 3

// Local file. A MediaItem tag is REQUIRED on every source when just_audio_background is used.
await player.setAudioSource(AudioSource.file(
  '/data/user/0/<pkg>/files/audio/Alafasy_128kbps/112001.mp3',
  tag: const MediaItem(id: 'q:112:1', title: 'Al-Ikhlas 1', album: 'Daily Duas'),
));
player.play(); // don't await in UI code. `await player.play()` completes only when playback stops or pauses.

// URL (HTTPS)
await player.setAudioSource(AudioSource.uri(
  Uri.parse('https://everyayah.com/data/Alafasy_128kbps/112001.mp3'),
  tag: const MediaItem(id: 'q:112:1', title: 'Al-Ikhlas 1'),
));
```

#### Playlist for a dua or surah, highlighting the current ayah, speed, loop, completion

```dart
Future<void> loadRecitation(List<AyahAudio> ayahs, {int repeatEach = 1}) async {
  final sources = <AudioSource>[
    for (final a in ayahs)
      for (var r = 0; r < repeatEach; r++) // distinct instances; see note below
        AudioSource.file(a.localPath,
            tag: MediaItem(id: '${a.key}#$r', title: a.title, album: a.collectionTitle,
                extras: {'ayahIndex': a.index})),
  ];
  await player.setAudioSources(sources, initialIndex: 0, initialPosition: Duration.zero);
  await player.setLoopMode(LoopMode.off);   // LoopMode.off | one | all
  await player.setSpeed(1.0);               // UI slider range 0.75–1.25
}

// Highlight: either currentIndexStream (int?) or sequenceStateStream (gives the tag).
player.sequenceStateStream.listen((s) {
  final tag = s.currentSource?.tag as MediaItem?;
  final ayahIndex = tag?.extras?['ayahIndex'] as int?;
  // update Riverpod state -> scroll/highlight ayah
});

// Completion (end of playlist with LoopMode.off). Never fires with LoopMode.one.
player.playerStateStream.listen((st) async {
  if (st.processingState == ProcessingState.completed) {
    // mark "recited" in DB, etc. To replay:
    // await player.seek(Duration.zero, index: 0); player.play();
  }
});

player.errorStream.listen((e) => log('audio error ${e.code} ${e.message} @${e.index}'));

// Jump to the ayah the user tapped
await player.seek(Duration.zero, index: tappedIndex);
```

Notes:

- `ProcessingState` has the values `idle`, `loading`, `buffering`, `ready`, `completed` [verified].
- Wrap `setAudioSources` in `try { } on PlayerException { } on PlayerInterruptedException { }`.
- `SequenceState.currentSource`, `currentIndexStream` (`Stream<int?>`), and `positionDiscontinuityStream` all exist in 0.10.6 [verified].
- Repeat-N: the README idiom is `...List.filled(N, source)`, which puts the same instance in the list N times. I used **distinct instances** with distinct `MediaItem.id`s instead. I did not check whether duplicate instances or ids cause problems in the media-notification queue **[unverified]**, and distinct objects cost almost nothing.
- Speed 0.75–1.25: `setSpeed` is pitch-preserving on Android (ExoPlayer) **[unverified detail, but standard ExoPlayer behavior]**.

### LockCachingAudioSource vs manual download

`LockCachingAudioSource(uri, {headers, cacheFile, tag})` is annotated `@experimental` [verified]. It streams through a 127.0.0.1 proxy, so it needs the cleartext config above. It exposes `downloadProgressStream` and `clearCache()`.

**Recommendation: download manually with `http` into `getApplicationSupportDirectory()` and always play `AudioSource.file`.** The reasons:

- The files are tiny (112001.mp3 is 48,192 bytes).
- It gives a real offline guarantee and a simple DB flag (`downloaded = true`).
- There is no proxy and no cleartext exception.
- Playlists only ever contain local files.

Stream with `AudioSource.uri` only as a fallback when a file is missing and the device is online. Fall back to TTS when offline (§5).

```dart
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<File> ensureAyahFile(http.Client client, String reciter, int surah, int ayah) async {
  final root = await getApplicationSupportDirectory();          // /data/user/0/<pkg>/files
  final dir = Directory(p.join(root.path, 'audio', reciter));
  await dir.create(recursive: true);
  final name = '${surah.toString().padLeft(3, '0')}${ayah.toString().padLeft(3, '0')}.mp3';
  final file = File(p.join(dir.path, name));
  if (await file.exists() && await file.length() > 0) return file;

  final uri = Uri.https('everyayah.com', '/data/$reciter/$name');
  final res = await client.send(http.Request('GET', uri)).timeout(const Duration(seconds: 20));
  if (res.statusCode != 200) {
    await res.stream.drain<void>();
    throw HttpException('HTTP ${res.statusCode}', uri: uri);
  }
  final tmp = File('${file.path}.part');
  try {
    await res.stream.pipe(tmp.openWrite());                      // pipe() closes the sink
    final expected = res.contentLength;
    if (expected != null && await tmp.length() != expected) {
      throw HttpException('truncated download', uri: uri);
    }
    return await tmp.rename(file.path);                          // atomic publish
  } catch (_) {
    if (await tmp.exists()) await tmp.delete();
    rethrow;
  }
}
```

(`path` is already a transitive dependency. Add `path: ^1.9.1` to pubspec to import it directly.)

---

## 2. Background playback and lock-screen controls

### Decision: use **just_audio_background** (0.0.1-beta.17)

Reasons:

- It is the simplest option and is officially recommended in the just_audio README.
- It is built on audio_service.
- Its example uses the new `setAudioSources` API [verified, `example/lib/main.dart`].
- It supports our case: one player, a playlist, and a notification and lock screen with play, pause, next and previous.

Hard limitations [verified in source]:

1. **Only one live `AudioPlayer`.** The source contains `throw PlatformException(message: "just_audio_background supports only a single player instance")`. The slot is released when the player is disposed or `stop()`ped, because `stop()` disposes the platform player. Keep **one** player app-wide (a Riverpod `keepAlive` provider) and reuse it to play back the user's own recordings too.
2. **Every source needs a `MediaItem` tag.** The source does `assert(sequence.every((s) => s.tag is MediaItem))` and casts `as MediaItem`. `MediaItem` requires `id` and `title`.
3. The "beta" label and a last release on 2025-05-13 are a maintenance risk. It still declares `audio_service ^0.18.18` and Flutter `>=3.27`, so it resolves fine today.

**When to switch to audio_service directly (0.18.19):**

- You need custom notification buttons (for example "repeat ayah").
- You need more than one simultaneous player.
- You want a `BaseAudioHandler` that controls the notification yourself.

The manifest and the `AudioServiceActivity` requirement are identical, so switching later is cheap.

### Init (main.dart)

```dart
import 'package:audio_session/audio_session.dart';
import 'package:flutter/widgets.dart';
import 'package:just_audio_background/just_audio_background.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(                 // before any AudioPlayer() is created
    androidNotificationChannelId: 'com.example.daily_duas.audio',
    androidNotificationChannelName: 'Recitation playback',
    androidNotificationOngoing: true,             // requires androidStopForegroundOnPause == true (default)
    // androidNotificationIcon: 'drawable/ic_stat_recite', // default 'mipmap/ic_launcher'; custom => keep.xml
  );
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.speech()); // §3
  runApp(const ProviderScope(child: DailyDuasApp()));
}
```

`init` parameters [verified]:

- `androidResumeOnClick`
- `androidNotificationChannelId`
- `androidNotificationChannelName` (default 'Notifications')
- `androidNotificationChannelDescription`
- `notificationColor`
- `androidNotificationIcon`
- `androidShowNotificationBadge`
- `androidNotificationClickStartsActivity`
- `androidNotificationOngoing`
- `androidStopForegroundOnPause` (default true)
- `fastForwardInterval` / `rewindInterval`
- `preloadArtwork`
- `artDownscaleWidth` / `artDownscaleHeight`

audio_service asserts `!androidNotificationOngoing || androidStopForegroundOnPause` [verified].

### Manifest (identical for JAB and audio_service) [verified, both READMEs]

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
          xmlns:tools="http://schemas.android.com/tools">
  <uses-permission android:name="android.permission.WAKE_LOCK"/>
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/> <!-- required targetSdk >= 34 -->
  <application ...>
    <activity android:name=".MainActivity" ... />   <!-- MainActivity extends AudioServiceActivity -->
    <service android:name="com.ryanheise.audioservice.AudioService"
        android:foregroundServiceType="mediaPlayback"
        android:exported="true" tools:ignore="Instantiatable">
      <intent-filter>
        <action android:name="android.media.browse.MediaBrowserService"/>
      </intent-filter>
    </service>
    <receiver android:name="com.ryanheise.audioservice.MediaButtonReceiver"
        android:exported="true" tools:ignore="Instantiatable">
      <intent-filter>
        <action android:name="android.intent.action.MEDIA_BUTTON"/>
      </intent-filter>
    </receiver>
  </application>
</manifest>
```

**Does MainActivity have to extend `AudioServiceActivity`? Yes**, or you set `android:name="com.ryanheise.audioservice.AudioServiceActivity"` directly. We need our own MainActivity for the MethodChannel in §6, so use `class MainActivity : AudioServiceActivity()` [verified, audio_service README "Custom Android activity"].

`AudioServiceActivity` overrides `provideFlutterEngine()` to return a **cached FlutterEngine** shared with the AudioService. That engine outlives the Activity. So register MethodChannels in `configureFlutterEngine` and clear them in `cleanUpFlutterEngine` (Kotlin in §6).

Android 13+: media-session notifications are **exempt** from `POST_NOTIFICATIONS` (https://developer.android.com/develop/ui/views/notifications/notification-permission, "Exemptions: Media sessions") [verified]. The lock-screen and notification controls therefore work even if the user denies notifications.

Android 12+ `ForegroundServiceStartNotAllowedException`: the default `androidStopForegroundOnPause = true` can make resume-after-long-pause fail. The audio_service README suggests a battery-optimization exemption or `androidStopForegroundOnPause: false`. We already ask for the battery exemption (§6), so the default is fine.

### Coexistence with the `alarm` package's foreground service [verified in alarm 5.15.0 source]

- alarm declares its own `com.gdelataillade.alarm.alarm.AlarmService` with `foregroundServiceType="mediaPlayback"` and `FOREGROUND_SERVICE_MEDIA_PLAYBACK`. It also merges `USE_EXACT_ALARM` and `SCHEDULE_EXACT_ALARM`.
- It plays the alarm with its own `android.media.MediaPlayer` (`USAGE_ALARM`), not ExoPlayer. So there is **no ExoPlayer duplicate-class conflict**.
- An app may run both foreground services at once. The manifest entries merge cleanly because the service classes are different.
- Audio focus: when an alarm rings, alarm requests `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK`. With `AudioSessionConfiguration.speech()` (`androidWillPauseWhenDucked: true`), audio_session turns that into a *pause* interruption. just_audio (`handleInterruptions: true`, the default) then **pauses recitation and auto-resumes** it when the alarm abandons focus [verified in `audio_session/lib/src/core.dart` and the `just_audio.dart` interruption handler]. If the dua alarm should *stop* any recitation instead, call `player.pause()` from the alarm-ring stream.
- Both show a notification: the media notification plus the alarm notification. That is expected.
- Android 15: `mediaPlayback` foreground services may not be started from a `BOOT_COMPLETED` receiver. alarm's `BootReceiver` only reschedules alarms, so this is fine **[unverified that it never starts the FGS at boot; I did not read BootReceiver.kt]**.
- I found no documented conflict between alarm and audio_service. Their combination with a cached engine has not been tested **[unverified]**. If you route the alarm "RING" intent to MainActivity (per alarm's `help/DETECT-ALARM-LAUNCH-ANDROID.md`), extend `AudioServiceActivity` instead of `FlutterActivity` there. The rest of that code is unchanged.

---

## 3. audio_session 0.2.4: configure for speech

Sources:
- https://pub.dev/packages/audio_session
- https://github.com/ryanheise/audio_session

Breaking change in 0.2.0: iOS `AUDIO_SESSION_MICROPHONE=0` is now the default. The package was migrated to Kotlin, and the Android minSdk is now **24** [verified].

```dart
final session = await AudioSession.instance;
await session.configure(const AudioSessionConfiguration.speech());
// speech() = Android: AudioAttributes(contentType: speech, usage: media), focus gain = gain,
//            androidWillPauseWhenDucked: true; iOS: playback + spokenAudio.   [verified source]

session.becomingNoisyEventStream.listen((_) => player.pause()); // headphones unplugged
// just_audio already handles interruptionEventStream itself (handleInterruptions: true).
```

Configure it **before the first `play()`**. If you don't, just_audio falls back to `AudioSessionConfiguration.music()` [verified, `setActive` fallback]. The README recommends configuring after other audio plugins load, because they may override the shared session (iOS mostly).

Interaction with the other audio plugins [verified in source]:

- `record` requests `AUDIOFOCUS_GAIN` when recording starts (unless `audioInterruption: AudioInterruptionMode.none`). just_audio receives `loss`, so it **pauses and does not auto-resume**. This is the behavior we want: starting a recording stops recitation.
- `flutter_tts.speak(text)` requests audio focus only when called with `focus: true` (then `GAIN_TRANSIENT_MAY_DUCK`). With the default `focus: false` it does not touch focus.

---

## 4. record 7.1.1: recording the user's recitation

Sources:
- https://pub.dev/packages/record
- https://pub.dev/packages/record/changelog
- repo: https://github.com/llfbandit/record

Breaking changes [verified, CHANGELOG]:

- **7.0.0** raised the minimum to **Flutter 3.44 / Dart 3.12**. It **removed the Android background-recording service**: record only while the app is in the foreground, and keep the screen on with wakelock_plus. It also moved to AGP 9 and the Kotlin DSL, and removed the deprecated iOS `manageAudioSession`.
- **7.1.0** added `onConfigChanged`, which reports the effective config after clamping to device and codec capabilities. Android AAC output is now stricter and readable on iOS.
- **record_android 2.2.0** raised minSdk to **24**.

Android manifest: `<uses-permission android:name="android.permission.RECORD_AUDIO"/>`. The plugin's manifest already merges it [verified]. Declare it in the app anyway for clarity. `MODIFY_AUDIO_SETTINGS` is optional (Bluetooth SCO headsets).

```dart
import 'package:record/record.dart';

final recorder = AudioRecorder();

Future<String?> startRecording(String id) async {
  // hasPermission({bool request = true}) shows the RECORD_AUDIO dialog when needed.
  // false => denied (or permanently denied: send user to app settings, §6).
  if (!await recorder.hasPermission()) return null;
  final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'recordings'));
  await dir.create(recursive: true);
  final path = p.join(dir.path, '$id.m4a');
  await recorder.start(
    const RecordConfig(
      encoder: AudioEncoder.aacLc,   // default encoder; .m4a container
      bitRate: 64000,                // defaults: 128000
      sampleRate: 44100,             // default 44100
      numChannels: 1,                // default 2; mono is enough for voice
    ),
    path: path,                      // required named arg
  );
  return path;
}

final String? savedPath = await recorder.stop();   // returns the output path
await recorder.cancel();                            // stop + delete file
final level = recorder.onAmplitudeChanged(const Duration(milliseconds: 200)); // Stream<Amplitude> (.current dBFS)
await recorder.dispose();                           // when the screen/provider is disposed
```

Other API [verified, `record/lib/src/record.dart`]:

- `pause()` / `resume()`
- `isRecording()`
- `isPaused()`
- `onStateChanged()`
- `isEncoderSupported(AudioEncoder)`
- `listInputDevices()`

Other `RecordConfig` fields [verified]:

- `autoGain`, `echoCancel`, `noiseSuppress`
- `androidConfig: AndroidRecordConfig(useLegacy, muteAudio, manageBluetooth, audioSource, speakerphone, audioManagerMode)`
- `audioInterruption` (default `AudioInterruptionMode.pause`)

Play the result back through the **same** just_audio player, with `AudioSource.file(path, tag: MediaItem(id: 'rec:$id', title: 'My recitation'))`.

---

## 5. flutter_tts 4.2.5: TTS fallback

Sources:
- https://pub.dev/packages/flutter_tts
- https://github.com/dlutton/flutter_tts

The last release was 2026-01-05, and there have been no breaking changes in 4.x. Android plugin `minSdkVersion 24`, `compileSdk 36`. The README's "minSdk 21" is out of date [verified].

**Required manifest entry for targetSdk 30+.** The plugin's own manifest does *not* include it [verified]:

```xml
<queries>
  <intent>
    <action android:name="android.intent.action.TTS_SERVICE"/>
  </intent>
</queries>
```

Behavior verified in `FlutterTtsPlugin.kt`:

- **Speech rate mapping on Android:** the plugin calls `tts.setSpeechRate(rate * 2.0f)`. So **Dart 0.5 is Android's normal speed (1.0x)**. For a 0.75–1.25x UI, pass `0.5 * multiplier` (0.375–0.625).
- `setLanguage(tag)` returns `1` if `isLanguageAvailable(Locale.forLanguageTag(tag)) >= LANG_AVAILABLE`, otherwise `0`, and does not change the language.
- `isLanguageInstalled(tag)` requires a voice whose locale **exactly equals** `Locale.forLanguageTag(tag)` and that lacks `KEY_FEATURE_NOT_INSTALLED`. So `'ar'` may return false on an engine whose voices are, say, `ar-XA`. Pick the tag from `getLanguages` instead.
- `speak(text, {bool focus = false})`

```dart
import 'package:flutter_tts/flutter_tts.dart';

final tts = FlutterTts();

Future<bool> initArabicTts() async {
  await tts.awaitSpeakCompletion(true);              // `await speak()` resolves on completion
  final langs = (await tts.getLanguages as List?)?.cast<String>() ?? const [];
  final arTag = langs.firstWhere((l) => l.toLowerCase().startsWith('ar'), orElse: () => 'ar');
  final available = await tts.isLanguageAvailable(arTag) == true;
  if (!available) return false;                      // offer "Install voice data" (§6 'ttsInstall')
  await tts.setLanguage(arTag);
  final installed = await tts.isLanguageInstalled(arTag) == true; // Android only; may need download
  await tts.setSpeechRate(0.5);                      // Android normal speed
  tts.setCompletionHandler(() { /* advance to next dua line / update state */ });
  tts.setErrorHandler((msg) { /* fall back silently */ });
  return installed;
}

Future<void> speakArabic(String text, double speed /* 0.75..1.25 */) async {
  await tts.setSpeechRate(0.5 * speed);
  await tts.speak(text);                             // focus:false => doesn't pause just_audio
}
```

Also available [verified, Dart API]: `getEngines`, `getDefaultEngine`, `setEngine(String)`, `getVoices`, `setQueueMode(int)`, `stop()`, and `pause()` (Android 26+).

**Content caveat:** device TTS reading Qur'anic Arabic is not tajweed-accurate, and handling of diacritics varies by engine and device **[unverified per device]**. Use TTS only for duas or translations when no recording exists, and label it "device voice" in the UI.

---

## 6. Android settings pages and permission status: pick the minimal set

### What each candidate actually does [verified in source]

| Need | permission_handler 13.0.2 | app_settings 9.0.0 | android_intent_plus 6.1.0 | flutter_local_notifications 22.3.1 (already in stack) |
|---|---|---|---|---|
| POST_NOTIFICATIONS request/status | `Permission.notification` | open page only | open page only | `requestNotificationsPermission()`, `areNotificationsEnabled()` |
| Exact alarm status/request | `Permission.scheduleExactAlarm` (`canScheduleExactAlarms`) | `AppSettingsType.alarm` opens `ACTION_REQUEST_SCHEDULE_EXACT_ALARM` + `package:` | any intent | `canScheduleExactNotifications()`, `requestExactAlarmsPermission()` (opens the page with `package:`) |
| Full-screen intent (API 34+) | **none** | **none** | any intent | `requestFullScreenIntentPermission()`: returns `true` immediately if granted, otherwise opens `ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT` and returns the result. **There is no status-only getter.** |
| Battery optimization status | `Permission.ignoreBatteryOptimizations` (`PowerManager.isIgnoringBatteryOptimizations`) | `.batteryOptimization` opens the *list* page (`ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS`) | any intent | none |
| Overlay | `Permission.systemAlertWindow` (`Settings.canDrawOverlays`) | none | any intent | none |
| Mic | `Permission.microphone` | none | none | none. **record's `hasPermission()` covers it.** |
| Build cost | **compileSdk 37** required (needs `platforms;android-37` installed; AGP 9.0.1 may warn that it was only tested up to 36 **[unverified]**) | Kotlin plugin; iOS SPM-only since 8.0 | none special | already present (needs desugaring anyway) |

permission_handler 13 / android 14.1 also changed behavior. On Android, `Permission.status` **never** returns `permanentlyDenied`; only `request()` can [verified, CHANGELOG].

### Decision: no permission_handler, no app_settings, no android_intent_plus

Use these instead:

1. **flutter_local_notifications** for the notification permission, exact alarms, and requesting the full-screen intent. These calls are covered in the notifications doc.
2. **record** `hasPermission()` for the microphone.
3. **About 70 lines of Kotlin** in `MainActivity` (below) for *status-only* checks: full-screen intent, battery optimization, overlay, exact alarm, notifications. The same code launches every settings page, with the `package:` data URI where Android supports it.

This is the minimal set: zero extra plugins. The Kotlin is needed anyway for `canUseFullScreenIntent()`.

If you would rather launch pages from pure Dart, `android_intent_plus` is the only one worth adding. It passes non-aliased action strings through unchanged and uses the Activity context when it has one [verified, `MethodCallHandlerImpl.convertAction` / `IntentSender.send`]:

```dart
// optional alternative
await const AndroidIntent(
  action: 'android.settings.MANAGE_APP_USE_FULL_SCREEN_INTENT',
  data: 'package:com.example.daily_duas',
).launch();
```

### Manifest additions for §6

```xml
<!-- direct "Allow app to ignore battery optimizations?" dialog; fine for sideloaded app -->
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>
<!-- USE_FULL_SCREEN_INTENT / SCHEDULE_EXACT_ALARM / USE_EXACT_ALARM / POST_NOTIFICATIONS:
     declared per the notifications/alarm doc (alarm also merges them). -->
```

Note: if `USE_EXACT_ALARM` is declared (the alarm package merges it), `canScheduleExactAlarms()` is normally `true` on API 33+, so the exact-alarm page rarely matters **[unverified on OEM ROMs]**.

### Kotlin: `android/app/src/main/kotlin/<your/package>/MainActivity.kt`

```kotlin
package com.example.daily_duas   // must match android.namespace / applicationId path

import android.app.AlarmManager
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.speech.tts.TextToSpeech
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    private val channelName = "daily_duas/platform"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getStatus" -> result.success(status())
                    "open" -> result.success(
                        open(call.argument<String>("page") ?: "app", call.argument<String>("channelId"))
                    )
                    else -> result.notImplemented()
                }
            }
    }

    // audio_service caches the engine beyond this Activity's life: drop the handler that captures `this`.
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler(null)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun status(): Map<String, Any> {
        val ctx = applicationContext
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val exact = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) am.canScheduleExactAlarms() else true
        val fsi = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) nm.canUseFullScreenIntent() else true
        return mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "manufacturer" to Build.MANUFACTURER,
            "notificationsEnabled" to nm.areNotificationsEnabled(),                 // API 24
            "ignoringBatteryOptimizations" to pm.isIgnoringBatteryOptimizations(ctx.packageName), // API 23
            "canScheduleExactAlarms" to exact,                                      // API 31
            "canUseFullScreenIntent" to fsi,                                        // API 34
            "canDrawOverlays" to Settings.canDrawOverlays(ctx),                     // API 23
        )
    }

    private fun appDetails(pkg: Uri) = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkg)

    private fun open(page: String, channelId: String?): Boolean {
        val pkg = Uri.parse("package:$packageName")
        val sdk = Build.VERSION.SDK_INT
        val intent: Intent = when (page) {
            "notifications" -> if (sdk >= Build.VERSION_CODES.O)
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName) else appDetails(pkg)
            "channel" -> if (sdk >= Build.VERSION_CODES.O && channelId != null)
                Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                    .putExtra(Settings.EXTRA_CHANNEL_ID, channelId) else appDetails(pkg)
            "exactAlarm" -> if (sdk >= Build.VERSION_CODES.S)
                Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, pkg) else appDetails(pkg)
            "fullScreenIntent" -> if (sdk >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
                Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, pkg) else appDetails(pkg)
            "batteryRequest" -> Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, pkg) // needs manifest perm
            "batteryList" -> Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            "overlay" -> Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, pkg)
            "tts" -> Intent("com.android.settings.TTS_SETTINGS")          // not a public constant [unverified on all OEMs]
            "ttsInstall" -> Intent(TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA)
            else -> appDetails(pkg)
        }
        return try {
            startActivity(intent); true
        } catch (e: ActivityNotFoundException) {
            try { startActivity(appDetails(pkg)) } catch (_: Exception) {}
            false
        } catch (e: SecurityException) {
            false
        }
    }
}
```

APIs and levels, all from official Android reference docs:

- `NotificationManager.canUseFullScreenIntent()`, API 34
- `Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT`, API 34
- `AlarmManager.canScheduleExactAlarms()`, API 31
- `Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM`, API 31
- `ACTION_APP_NOTIFICATION_SETTINGS` / `ACTION_CHANNEL_NOTIFICATION_SETTINGS`, API 26

flutter_local_notifications' Java source uses the same calls [verified]. I did not compile this Kotlin, because the SDK is not ready **[unverified compile]**.

### Dart side

```dart
import 'package:flutter/services.dart';

enum SettingsPage { notifications, channel, exactAlarm, fullScreenIntent,
                    batteryRequest, batteryList, overlay, tts, ttsInstall, app }

class PlatformBridge {
  static const _ch = MethodChannel('daily_duas/platform');

  static Future<Map<String, Object?>> status() async =>
      await _ch.invokeMapMethod<String, Object?>('getStatus') ?? const {};

  static Future<bool> open(SettingsPage page, {String? channelId}) async {
    try {
      return await _ch.invokeMethod<bool>('open', {'page': page.name, 'channelId': channelId}) ?? false;
    } on MissingPluginException {
      return false; // no Activity attached (e.g. called from background)
    }
  }
}
```

The user comes back from Settings without any result callback. Re-read `status()` on resume, for example with `AppLifecycleListener(onResume: () => ref.invalidate(platformStatusProvider))`.

---

## 7. Utility packages

### file_picker 13.1.0: import and export backups

Sources:
- https://pub.dev/packages/file_picker
- repo: https://github.com/vicajilau/flutter_file_picker (maintainer changed in 2026)

**Breaking changes. The old snippets you find online (`FilePicker.platform.pickFiles(withData: true)`, `FilePickerResult`, `.files.single.bytes`) no longer compile** [verified, CHANGELOG and source]:

- v12:
  - The package became a federated plugin; the Android implementation is `android_file_picker`.
  - The methods are **static on `FilePicker`**.
  - `pickFiles()` returns `List<PlatformFile>` (empty if cancelled).
  - `pickFile()` returns `PlatformFile?`.
  - `FilePickerResult` was removed.
  - `PlatformFile.size` was removed.
  - `saveFile()` now **requires `fileName` and `bytes`** and returns `Uri?`.
- v13:
  - `withData`, `withReadStream`, `allowMultiple` and `androidSafOptions` were **removed**. Read data with `await file.readAsBytes()` or `readAsByteStream()`.
  - `length()` returns `Future<int?>`.

On Android, `android_file_picker` merges a `<queries>` entry for `GET_CONTENT` and ships its own ProGuard rules [verified]. No app manifest changes are needed. If MainActivity ever overrides `onActivityResult`, it must call `super` [verified README]. `AudioServiceActivity` does not override it.

```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';

// Import
final PlatformFile? picked = await FilePicker.pickFile(
  type: FileType.any,   // see note: custom extension filtering on Android is MIME-based
);
if (picked != null) {
  final Uint8List bytes = await picked.readAsBytes();
  final backup = jsonDecode(utf8.decode(bytes));
  // validate picked.extension == 'json' / schema version before importing
}

// Export (SAF "Save as" dialog; Android requires bytes)
final Uri? saved = await FilePicker.saveFile(
  dialogTitle: 'Save Daily Duas backup',
  fileName: 'daily_duas_backup_2026-10-06.json',
  bytes: Uint8List.fromList(utf8.encode(jsonString)),
  mimeType: 'application/json',          // param exists, default 'application/octet-stream'
);
if (saved == null) { /* cancelled */ }
```

`FileType.custom` with `allowedExtensions: ['json']` works through MIME mapping on Android. Files that a file manager labels as `octet-stream`, and unknown custom extensions, may show greyed out **[unverified]**. `FileType.any` plus your own validation is the robust choice.

### share_plus 13.3.1: share a backup file

Sources:
- https://pub.dev/packages/share_plus
- https://github.com/fluttercommunity/plus_plugins

The API is `SharePlus.instance.share(ShareParams(...))`. The old static `Share.shareXFiles` was replaced in the 11.0 refactor. `XFile` is re-exported from `share_plus` [verified exports: `ShareResult`, `ShareResultStatus`, `XFile`, `ShareParams`].

The plugin manifest adds its own `FileProvider` (`${applicationId}.flutter.share_provider`) and receiver [verified], so nothing needs to go in the app manifest.

```dart
import 'package:share_plus/share_plus.dart';

final tmp = File(p.join((await getTemporaryDirectory()).path, 'daily_duas_backup.json'));
await tmp.writeAsString(jsonString, flush: true);
final ShareResult r = await SharePlus.instance.share(ShareParams(
  files: [XFile(tmp.path, mimeType: 'application/json')],
  subject: 'Daily Duas backup',
));
// r.status: ShareResultStatus.success / dismissed / unavailable
```

### path_provider 2.1.6

Directory mapping on Android, verified in `path_provider_android_real.dart` 2.3.1:

| Dart call | Android dir | Use for |
|---|---|---|
| `getApplicationSupportDirectory()` | `context.filesDir` (`/data/user/0/<pkg>/files`) | downloaded reciter audio |
| `getApplicationDocumentsDirectory()` | `context.getDir("flutter")` (`.../app_flutter`) | user recordings, DB (if not using drift's default) |
| `getTemporaryDirectory()` = `getApplicationCacheDirectory()` | `context.cacheDir` | share/export temp files. **The OS may purge this.** |

`path_provider_android` 2.3.x moved to JNI (`jni` + `jni_flutter`), which needs the **NDK and CMake** at build time (see §0) [verified].

Android Auto Backup (`allowBackup` defaults to true) may try to back up the downloaded audio. Consider `android:allowBackup="false"`, or backup rules that exclude `files/audio/`, since the app has its own export **[advisory]**.

### url_launcher 6.3.3

Sources:
- https://pub.dev/packages/url_launcher
- https://github.com/flutter/packages

`launchUrl` needs **no** `<queries>` entry. Only `canLaunchUrl` and `supportsLaunchMode(inAppBrowserView)` need one [verified, README].

```dart
import 'package:url_launcher/url_launcher.dart';
await launchUrl(Uri.parse('https://dontkillmyapp.com/$vendor'), mode: LaunchMode.externalApplication);
```

The vendor URLs return 200 for: samsung, xiaomi, oneplus, huawei, oppo, vivo, realme, google, motorola, nokia, sony, asus. `/honor` returns 404, so fall back to `https://dontkillmyapp.com/`. Checked 2026-10-06 with `curl -I`. A JSON API also exists at `https://dontkillmyapp.com/api/v2/<vendor>.json` (200, `application/json`).

### package_info_plus 10.2.2

v9 changed the Android compile SDK and build config. v10 moved to win32 6. Neither affects the Android API.

```dart
final info = await PackageInfo.fromPlatform();
final versionLabel = '${info.version}+${info.buildNumber}';
```

### wakelock_plus 1.8.1: keep the screen on while reciting or recording

No permissions are needed. It is a screen wakelock only [verified README]. It needs Dart 3.12 / Flutter 3.44.

```dart
import 'package:wakelock_plus/wakelock_plus.dart';
@override void initState() { super.initState(); WakelockPlus.enable(); }
@override void dispose() { WakelockPlus.disable(); super.dispose(); }
```

### device_info_plus 13.3.0: manufacturer for the battery guide

v12 removed `AndroidDeviceInfo.serialNumber` and changed the compile SDK. v13 moved to win32 6 [verified].

```dart
import 'package:device_info_plus/device_info_plus.dart';
final a = await DeviceInfoPlugin().androidInfo;
final vendor = a.manufacturer.toLowerCase(); // 'samsung', 'xiaomi', ...
final sdk = a.version.sdkInt;
```

The Kotlin `getStatus` in §6 already returns `manufacturer` and `sdkInt`. If the app needs nothing else from device_info_plus (`model`, `brand`), you can **drop it**.

### http 1.6.0

Pure Dart. It needs only `INTERNET` in `src/main`. Use one long-lived `http.Client` (a Riverpod provider) and `close()` it on dispose. See the download snippet in §1.

---

## 8. everyayah.com per-ayah audio

Checked 2026-10-06 with headers-only requests: `curl -I`, plus a 16-byte range request.

- `https://everyayah.com/data/Alafasy_128kbps/112001.mp3`
  - returns **200**, `Content-Type: audio/mpeg`, `Content-Length: 48192`
  - `Accept-Ranges: bytes`. A `Range: bytes=0-15` request returns **206** with `Content-Range: bytes 0-15/48192`.
  - `Cache-Control: max-age=25600000`
  - served by BunnyCDN (`Server: BunnyCDN-DE1-…`, `CDN-Cache: HIT`)
  - `Access-Control-Allow-Origin: *`
- The URL scheme is `https://everyayah.com/data/<Reciter_Folder>/<SSS><AAA>.mp3`, with surah and ayah each zero-padded to 3 digits. `001001` and `002286` return 200. `112005` returns **404**, which is correct because Al-Ikhlas has 4 ayat. Treat 404 as "no such ayah" and never retry it.
- `http://everyayah.com/...` returns **301** to the `https://` URL. **Always build `https://` URLs.** Then no `usesCleartextTraffic` is needed. Android 9+ blocks cleartext by default. The only cleartext exception you might need is `127.0.0.1`, for just_audio's proxy features (§1).
- These reciter folders returned 200 for 112001:
  - `Alafasy_64kbps`, `Alafasy_128kbps`
  - `Husary_128kbps`
  - `Abdul_Basit_Murattal_192kbps`
  - `Minshawy_Murattal_128kbps`
  - `Abdurrahmaan_As-Sudais_192kbps`
  - `Saood_ash-Shuraym_128kbps`
- **Machine-readable index:** `https://everyayah.com/data/recitations.js` (200, about 10.9 KB). Despite the `.js` extension it is **pure JSON**: `{"ayahCount":[7,286,200,...], "1":{"subfolder":"Abdul_Basit_Murattal_64kbps","name":"Abdul Basit Murattal","bitrate":"64kbps"}, ...}`. Use it, or a bundled copy, for the reciter picker and the per-surah ayah counts.
- Per-reciter zips exist, for example `.../Alafasy_128kbps/000_versebyverse.zip` returns 200 `application/zip`. They are useful for "download all", but large **[size unverified]**.
- The server supports byte ranges and sends correct `Content-Type` and `Content-Length`. Streaming with just_audio (`AudioSource.uri`) therefore reports duration correctly. Downloaded files keep the `.mp3` extension, so ExoPlayer picks the right extractor.
- Licensing and terms of use for redistributing or bulk-downloading everyayah audio were not checked **[unverified]**. For personal sideloaded use this is low risk. Be polite: download on demand, use a modest concurrency of 2–4, and don't hammer the server.

---

## 9. Consolidated Android setup for these packages

### `android/app/src/main/AndroidManifest.xml` (media/platform parts only)

Merge this with the notification and alarm entries from the other research doc.

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
          xmlns:tools="http://schemas.android.com/tools">

    <uses-permission android:name="android.permission.INTERNET"/>                       <!-- NOT in template main! -->
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
    <uses-permission android:name="android.permission.RECORD_AUDIO"/>
    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>

    <application
        android:label="Daily Duas"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher">
        <!-- add android:networkSecurityConfig="@xml/network_security_config" ONLY if using
             LockCachingAudioSource / StreamAudioSource / headers (127.0.0.1 cleartext) -->

        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTop"
            android:taskAffinity=""
            android:theme="@style/LaunchTheme"
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            android:hardwareAccelerated="true"
            android:windowSoftInputMode="adjustResize">
            <meta-data android:name="io.flutter.embedding.android.NormalTheme"
                       android:resource="@style/NormalTheme"/>
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>

        <service android:name="com.ryanheise.audioservice.AudioService"
            android:foregroundServiceType="mediaPlayback"
            android:exported="true" tools:ignore="Instantiatable">
            <intent-filter>
                <action android:name="android.media.browse.MediaBrowserService"/>
            </intent-filter>
        </service>

        <receiver android:name="com.ryanheise.audioservice.MediaButtonReceiver"
            android:exported="true" tools:ignore="Instantiatable">
            <intent-filter>
                <action android:name="android.intent.action.MEDIA_BUTTON"/>
            </intent-filter>
        </receiver>

        <meta-data android:name="flutterEmbedding" android:value="2"/>
    </application>

    <queries>
        <intent>   <!-- from Flutter template -->
            <action android:name="android.intent.action.PROCESS_TEXT"/>
            <data android:mimeType="text/plain"/>
        </intent>
        <intent>   <!-- flutter_tts, Android 11+ -->
            <action android:name="android.intent.action.TTS_SERVICE"/>
        </intent>
    </queries>
</manifest>
```

### `android/app/build.gradle.kts`

- Keep the template's `compileSdk = flutter.compileSdkVersion` (36) and `minSdk = flutter.minSdkVersion` (24). Nothing in this document needs more.
- Add only the desugaring block that `flutter_local_notifications` requires (see that doc).
- If you ever adopt permission_handler 13.x, set `compileSdk = 37` and install `platforms;android-37`.

### `pubspec.yaml` (media/platform subset)

```yaml
dependencies:
  just_audio: ^0.10.6
  just_audio_background: ^0.0.1-beta.17
  audio_session: ^0.2.4
  record: ^7.1.1
  flutter_tts: ^4.2.5
  file_picker: ^13.1.0
  share_plus: ^13.3.1
  path_provider: ^2.1.6
  path: ^1.9.1
  url_launcher: ^6.3.3
  package_info_plus: ^10.2.2
  wakelock_plus: ^1.8.1
  device_info_plus: ^13.3.0   # optional: Kotlin getStatus already returns manufacturer/sdkInt
  http: ^1.6.0
  # NOT added: permission_handler (compileSdk 37), app_settings, android_intent_plus (optional alternative ^6.1.0)
```

---

## 10. Risks and unknowns

1. **just_audio_background is beta**, and its last release was 2025-05-13. It is limited to a single player and requires a MediaItem tag on every source. The fallback is audio_service 0.18.19 with a custom `BaseAudioHandler`; the manifest and Activity are the same.
2. **Cached FlutterEngine.** `AudioServiceActivity` hosts the shared cached engine, and the alarm package also wakes the app. I found no documented conflicts, but this has not been tested together on a device.
3. **First build downloads.** Only android-35 and build-tools 34 are installed. AGP 9.0.1 / Flutter 3.44 need android-36, newer build-tools, NDK 28.2.13676358 and CMake (for `jni`, via path_provider_android 2.3.x). The download is about 1 GB and needs network on the first build.
4. **permission_handler 13** needs compileSdk 37. It is avoided here. AGP 9.0.1's support for API 37 is **[unverified]**.
5. **Arabic TTS** availability and quality depend on the device and engine. `isLanguageInstalled` needs an exact locale match. Qur'anic text through TTS is not accurate, so use it only as a labelled fallback.
6. **Kotlin MainActivity** has not been compiled yet, because the SDK is not ready. The `"com.android.settings.TTS_SETTINGS"` action is not a public SDK constant and may be missing on some OEM ROMs. The code falls back to the app-details page.
7. **file_picker v12/v13** rewrote its API. Online examples are stale, so use only the snippets in §7. Custom-extension filtering on Android is unreliable, so use `FileType.any` and validate.
8. **Dependency solver not run.** The constraints were cross-checked by hand. Run `flutter pub get` once the SDK is installed to confirm.
9. **everyayah** terms of use and bulk-download policy were not checked. The zip sizes are unknown.
