# Flutter core research: project setup, Riverpod, Drift, navigation, calendar, testing, icon

Researched 2026-10-06 for **Flutter 3.44.8 / Dart 3.12.2** (Android APK, sideloaded; iOS later).

How each claim was checked:
- **[V-src]**: read in the actual source. That means the local SDK at `D:\DuasSDK\home\flutter\3.44.8` (byte-identical to tag `3.44.8` on GitHub) or the package source downloaded from pub.dev.
- **[V-run]**: I ran it on this Windows machine:
  - `dart pub get` against the real 3.44.8 SDK package pins
  - `dart run build_runner build`
  - `dart analyze` (flutter_lints 6)
  - `dart run` / `dart test`

  All of it used the SDK's bundled `dart.exe` in a scratch copy. Nothing was written into `D:\DuasSDK`.
- **[V-doc]**: taken from official docs or a pub.dev page.
- **[UNVERIFIED]**: I could not confirm it here. Each one says why.

---

## 0. TL;DR decisions

| Topic | Recommendation |
|---|---|
| State | `flutter_riverpod: ^3.4.3`, with no code generation. Use `Provider`, `StreamProvider`, `Notifier`, `AsyncNotifier`, and `.autoDispose` / `.family`. |
| DB | `drift: ^2.35.1` + `drift_flutter: ^0.3.1` + `sqlite3: ^3.5.2`. Dev deps: `drift_dev: ^2.35.1`, `build_runner: ^2.15.1`. Do **not** add `sqlite3_flutter_libs` (it is EOL). |
| Navigation | `go_router: ^17.5.0` with `StatefulShellRoute.indexedStack`. Do **not** use go_router 18 on 3.44 (reason in §4). |
| Calendar | `table_calendar: ^3.2.1` (resolves to 3.3.0). Use `eventLoader` + `calendarBuilders.markerBuilder`. Don't hand-build a month grid. |
| Misc | `intl` (DateFormat), `collection`, `uuid` (only for backup ids). No `freezed`: drift row classes already have `copyWith`, `==` and `toJson`. |
| Tests | `flutter_test` + `ProviderContainer.test()` / `ProviderScope(overrides:)` + `NativeDatabase.memory()`. Use `http/testing.dart` `MockClient` and `fake_async`. **Never add `package:test`**, because it can't resolve on 3.44.8 (§7). |
| Icon | `flutter_launcher_icons: ^0.14.4` as a dev dependency, run once. Or copy PNGs into `mipmap-*` by hand (zero dependencies). |
| Build | `flutter build apk --release --target-platform android-arm64`. Use a single APK, **not** `--split-per-abi`, because split builds change versionCode. |

**Biggest gotcha found.** Flutter 3.44.8 pins `meta 1.18.0`. Many 2026 package releases need `meta ≥1.18.3` or `≥1.19.0`, so the newest versions don't resolve:
- `build_runner` 2.15.2+ (via analyzer ≥13.1)
- `sqlite3` 3.6+ (via `hooks`/`record_use`)

Caret constraints (`^`) still work: pub backtracks on its own to `build_runner 2.15.1`, `analyzer 13.0.0` and `sqlite3 3.5.2`. **[V-run]**

**Current repo state (seen at 20:2x today).** `D:\Coding\Python\duas app` already holds a `flutter create` output:
- `android/` uses AGP 9.0.1, Gradle **9.1.0-bin** and `-Xmx4G` (good)
- `pubspec.yaml` uses **sqflite** + `sqflite_common_ffi`, not Drift

Both stacks resolve on 3.44.8. The project lock shows `sqflite 2.4.4+1`, `sqflite_common_ffi 2.4.3` and `sqlite3 3.5.2`. `sqflite_common_ffi` uses the same `sqlite3` 3.x hook as Drift, so the Windows-test notes in §3.7 apply to both. Choosing Drift over sqflite would give:
- typed queries
- reactive `watch()` streams that feed `StreamProvider` directly
- built-in migration helpers

---

## 1. Flutter 3.44.8 Android project template (verified from the SDK)

Sources:
- `packages/flutter_tools/templates/app/android-kotlin.tmpl/**`
- `templates/app/android.tmpl/**`
- `packages/flutter_tools/lib/src/android/gradle_utils.dart`
- `packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt`, `FlutterPlugin.kt`, `FlutterPluginUtils.kt`, `FlutterPluginConstants.kt`

All read locally and on GitHub at https://github.com/flutter/flutter/tree/3.44.8/packages/flutter_tools. **[V-src]**

| Item | Value in 3.44.8 |
|---|---|
| Flutter commit / Dart | `058e0af2c2b57e369d905a03ac9748b0ebf543c6` / **Dart 3.12.2**. Source: `bin/cache/dart-sdk/version` and https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json |
| Gradle wrapper | **9.1.0**. The template writes the `-all.zip` (232 MB); `-bin.zip` is 134 MB. **Use `-bin`.** |
| AGP | **9.0.1** (`templateAndroidGradlePluginVersion`) |
| Kotlin Gradle Plugin | **2.3.20** |
| compileSdk / targetSdk / minSdk | **36 / 36 / 24** (`flutter.compileSdkVersion`, etc.) |
| ndkVersion | **28.2.13676358** (= r28c; Windows zip is 748 MB) |
| Java | Source/target 17. Tools require **JDK ≥17** for AGP 8.0–9.1. The Flet installer's Temurin 17.0.13 is fine. |
| Build files | Kotlin DSL: `settings.gradle.kts`, `build.gradle.kts`, `app/build.gradle.kts` |
| `gradle.properties` | `org.gradle.jvmargs=-Xmx8G -XX:MaxMetaspaceSize=4G ...`, `android.useAndroidX=true`, **`android.newDsl=false`**, **`android.builtInKotlin=false`** |

Notes:
- **Keep `android.newDsl=false` and `android.builtInKotlin=false`.** They opt out of AGP 9's new DSL and built-in Kotlin, so older plugins still work.
- The app's `plugins {}` block does **not** list `kotlin-android`. `FlutterPluginUtils.detectApplyingKotlinGradlePlugin` applies `kotlin-android` itself when it's missing. KGP is declared in `settings.gradle.kts`.
- Kotlin JVM target is set with `kotlin { compilerOptions { jvmTarget = JvmTarget.JVM_17 } }`.
  - **Do not paste `kotlinOptions { jvmTarget = ... }`** from older plugin READMEs, such as flutter_local_notifications'.
  - That DSL is deprecated in KGP 2.x. Whether it hard-errors in 2.3.20 is **[UNVERIFIED]**.
- **R8/minify is always on in release.**
  - The Flutter plugin sets `isMinifyEnabled = true` and `isShrinkResources = true`, and adds `proguard-android-optimize.txt` + `flutter_proguard_rules.pro`.
  - It also picks up **`android/app/proguard-rules.pro` automatically if the file exists**. **[V-src]**
  - `--no-shrink` is a no-op: the 3.44.8 help text says "This flag has no effect. Code shrinking is always enabled in release builds." **[V-src]**
- On 15 GB RAM, set `org.gradle.jvmargs=-Xmx4G -XX:MaxMetaspaceSize=1G` and `kotlin.daemon.jvmargs=-Xmx2G`. The repo already does this.

### 1.1 Recommended `android/app/build.gradle.kts` (desugaring + release signing)

```kotlin
import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// android/key.properties (NOT committed). rootProject = android/
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.dailyduas.daily_duas"
    compileSdk = flutter.compileSdkVersion      // 36; set 37 if permission_handler stays (see 1.4)
    ndkVersion = flutter.ndkVersion             // 28.2.13676358

    compileOptions {
        isCoreLibraryDesugaringEnabled = true   // required by flutter_local_notifications (10+)
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.dailyduas.daily_duas"
        minSdk = flutter.minSdkVersion           // 24 (also the max plugin minSdk in our graph)
        targetSdk = flutter.targetSdkVersion     // 36
        versionCode = flutter.versionCode        // from pubspec "version: x.y.z+N"
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties.getProperty("keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword")
            storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
            storePassword = keystoreProperties.getProperty("storePassword")
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // FLN README says 2.1.4; latest on Google Maven is 2.1.5 (maven-metadata.xml checked)
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
```

Sources:
- Desugaring: FLN 22.3.1 README, "Gradle setup" (https://pub.dev/packages/flutter_local_notifications). **[V-doc]**
- Signing pattern: https://docs.flutter.dev/deployment/android. **[V-doc]**
- `multiDexEnabled` is unnecessary with minSdk 24.

Create the keystore (PowerShell, from the Flutter docs) and `android/key.properties`:
```powershell
keytool -genkey -v -keystore D:\DuasSDK\keys\upload-keystore.jks -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```
```properties
storePassword=...
keyPassword=...
keyAlias=upload
# Java .properties treats "\" as an escape -> use forward slashes on Windows
storeFile=D:/DuasSDK/keys/upload-keystore.jks
```

Sideload facts:
- **Updates only install if the signing key and applicationId stay the same.** Pick the key before the first install on the phone and back it up.
- A key change, or switching from the debug key, forces an uninstall, which **wipes app data**.
- If the Flet build used the same applicationId with another key, uninstall it first.

### 1.2 Building arm64-only

`flutter build apk` options in 3.44.8 (`commands/build_apk.dart` **[V-src]**):
- `--target-platform` accepts `android-arm`, `android-arm64`, `android-x64`.
- `--split-per-abi` is a flag.
- Release is the default mode.

```powershell
flutter build apk --release --target-platform android-arm64
# -> build\app\outputs\flutter-apk\app-release.apk   (libflutter.so/libapp.so only for arm64-v8a)
```

- **Prefer this single APK.** With `--split-per-abi`, the Flutter Gradle plugin overrides `versionCode = ABI_VERSION*1000 + versionCode`, and arm64 = 2, so `+1` becomes **2001**. **[V-src]**
- After that, installing a non-split build (versionCode 1) over it fails as a downgrade.
- The Flutter docs mention `-P force-version-code-ignoring-abi=true`, but **that property does not exist in the 3.44.8 Gradle plugin** (grep found nothing). **[V-src]**
- Without split, the plugin sets `abiFilters` to `armeabi-v7a, arm64-v8a, x86_64`. Plugin `.so` files (e.g. `jni`) may still ship for those ABIs. That's harmless and only a few hundred KB.
- `-P disable-abi-filtering=true` turns that filtering off (not needed).

### 1.3 NDK and disk

**The NDK download can't be avoided with Flutter 3.44.8:**
1. `FlutterPlugin.apply()` always calls `FlutterPluginUtils.forceNdkDownload()`. It points `externalNativeBuild.cmake` at an **empty** `packages/flutter_tools/gradle/src/main/scripts/CMakeLists.txt`.
   - The comment there reads: "Empty file to trick the Android Gradle Plugin to download the NDK… AGP requires the NDK in order to strip debug symbols."
   - So every app needs **NDK 28.2.13676358** plus an SDK **CMake** package. **[V-src]**
2. Our graph also builds native code. `path_provider` 2.1.6 → `path_provider_android` 2.3.1 → **`jni` 1.1.0**, whose `android/build.gradle` has `externalNativeBuild { cmake { path "../src/CMakeLists.txt" } }` and `ndkVersion = flutter.ndkVersion`. **[V-src]**
   - drift_flutter depends on path_provider, so this comes in transitively.

Sizes from https://dl.google.com/android/repository/repository2-3.xml (Windows archives):

| Package | Download |
|---|---|
| NDK r28c | 748 MB zip. Extracted size is a few GB — **[UNVERIFIED]**. |
| `cmake;3.22.1` | 16 MB |
| `platforms;android-36` | 66 MB |
| `build-tools;36.0.0` | 59 MB |

- Which CMake version AGP 9.0.1 picks by default is **[UNVERIFIED]** (3.22.1 was the AGP 8.x default).
- AGP auto-installs missing NDK, CMake, platforms and build-tools when the SDK licenses have been accepted. The Flet installer already ran `sdkmanager --licenses`.
- That installer only added `platform-tools`, `platforms;android-35` and `build-tools;34.0.0`.

Disk-minimizing checklist:
- **Gradle:**
  - Keep `GRADLE_USER_HOME=D:\DuasSDK\gradle`, `PUB_CACHE=D:\DuasSDK\pub-cache` and `TEMP/TMP` on D:. `tools\build_env.ps1` already does this.
  - Keep the wrapper on `-bin`.
  - After a build, `cd android; .\gradlew --stop` frees daemon RAM.
- **Flutter create:**
  - Create **Android-only**: `flutter create --platforms=android --org com.dailyduas --project-name daily_duas .`
  - `--project-name` is needed because the folder name `duas app` is not a valid package name.
  - With no `windows/`/`linux/` folders, Flutter never creates plugin symlinks, so **Windows Developer Mode is not needed**. Symlinks are only made for those platform folders (`flutter_plugins.dart`). **[V-src]**
- **SDK artifacts:**
  - The stable zip already contains `bin/cache/artifacts/engine/{android-*, windows-x64*}` (1.7 GB). No extra engine download is needed for APK builds or `flutter test`.
  - Optional: `flutter config --no-enable-web --no-enable-windows-desktop --no-enable-linux-desktop --no-enable-macos-desktop`. These are config keys from `features.dart`.
- **Expect extra SDK platforms.** Every plugin module compiles against its own `compileSdk`: 35 (alarm, audio_service, jni, just_audio…), 36, and **37** (`permission_handler_android` 14.1.0). AGP will download each platform once, ~65 MB each. **[V-src for the plugin values]**
- **Offline:** after the first successful build, everything is cached:
  - Gradle deps → `GRADLE_USER_HOME`
  - pub → `PUB_CACHE`
  - sqlite3 binaries → `.dart_tool/hooks_runner/shared/...`

### 1.4 Plugin minSdk/compileSdk survey (resolved graph, read from each plugin's `android/build.gradle*`) [V-src]

- **minSdk.** The highest plugin minSdk is **24**: `flutter_local_notifications`, `audio_session`, `flutter_tts`, `permission_handler_android`, `record_android`, `shared_preferences_android`, `url_launcher_android`. The template minSdk 24 is OK.
- **compileSdk.** `permission_handler_android 14.1.0` uses **compileSdk 37**.
  - Flutter's `detectLowCompileSdkVersionOrNdkVersion` then logs an *error-level message*: "Fix this issue by compiling against the highest Android SDK version… compileSdk = 37". It does not throw.
  - Options: set `compileSdk = 37`, or drop `permission_handler` if the sibling notes show it isn't needed.
  - The SDK package is named `platforms;android-37.0`. Whether AGP 9.0.1 warns about compileSdk 37 is **[UNVERIFIED]**.
- **Desugaring.** Only `flutter_local_notifications` needs desugaring.

### 1.5 Everyday commands (PowerShell, after `. .\tools\build_env.ps1`)

```powershell
flutter pub get
dart run build_runner build -d          # drift codegen; -d = --delete-conflicting-outputs (exists in 2.15.1)
dart run build_runner watch -d          # while editing tables
flutter analyze                         # same analyzer as `dart analyze`
flutter test                            # all tests; flutter test test\db_test.dart --plain-name "insert"
dart format lib test
flutter build apk --release --target-platform android-arm64
adb install -r build\app\outputs\flutter-apk\app-release.apk
```

---

## 2. Riverpod 3 without code generation

Versions:
- `flutter_riverpod 3.4.3` (2026-09-03); env `sdk ^3.12.0`, `flutter >=3.0.0` **[V-src]**
- Depends on `riverpod 3.4.3`, `state_notifier`, `listen ^1.0.0-beta.3` (resolved 1.0.1) and `test_api ^0.7.0` (pinned 0.7.11 by flutter_test, OK)
- https://pub.dev/packages/flutter_riverpod · changelog: https://github.com/rrousselGit/riverpod/blob/master/packages/riverpod/CHANGELOG.md · what's new: https://riverpod.dev/docs/whats_new

### 2.1 Breaking changes from 2.x → 3.x, checked in the 3.4.3 source

- **Legacy providers moved.** `StateProvider`, `StateNotifierProvider` and `ChangeNotifierProvider` now come from `package:flutter_riverpod/legacy.dart`. Don't use them.
- **No more AutoDispose classes.** `AutoDisposeNotifier` and friends are gone. Write `class X extends Notifier<T>` and pick auto-dispose at the provider: `NotifierProvider.autoDispose<X, T>(X.new)`.
- **Family args are constructor parameters.** `FamilyNotifier` is gone: `AsyncNotifierProvider.autoDispose.family<N, T, Arg>(N.new)` where `N(this.arg)`. Builder signature: `call<NotifierT extends AsyncNotifier<StateT>, StateT, ArgT>(NotifierT Function(ArgT) create, {Retry? retry, ...})`.
- **One `Ref` type.** It's non-generic: `FutureProviderRef` etc. are gone.
- **Equality.** All providers now use `==` to decide whether to notify.
- **`AsyncValue` changes.** `valueOrNull` was renamed to `value` (it returns null on loading/error). `AsyncValue` is `sealed`, so `switch` pattern matching works.
- **`ref.mounted`.** Check it after `await` inside notifiers. Touching a disposed ref throws.
- **Automatic retry is ON by default.**
  - `ProviderContainer.defaultRetry`: up to 10 retries, 200 ms doubling to 6.4 s.
  - Errors of type `Error` and `ProviderException` are **not** retried.
  - Turn it off with `ProviderScope(retry: (count, error) => null)` / `ProviderContainer(retry: ...)`, or per provider with `retry:`.
  - Disable it in tests so failures surface immediately.
- **Listeners pause when hidden.** Pausing follows `TickerMode`. go_router's `StatefulShellRoute.indexedStack` wraps inactive branches in `Offstage` + `TickerMode(enabled: false)` (go_router `route.dart` **[V-src]**), so providers watched only by hidden tabs pause until the tab is shown. This is usually what we want.
- **Family overrides.** `family.overrideWith` is deprecated (3.2.0). Use `family.overrideWith2((arg) => Notifier(arg))`.
- **Imports.** `Override` and the `*Family` types are exported from `package:flutter_riverpod/misc.dart`, not the main library. Normally you don't need to name them.

### 2.2 Idiomatic providers (compiled, analyzed and run) [V-run]

```dart
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/database.dart';

/// Overridden in main() (real DB) and in tests (in-memory DB).
final databaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError('databaseProvider must be overridden');
});

final historyDaoProvider = Provider<HistoryDao>(
  (ref) => ref.watch(databaseProvider).historyDao,
);

/// drift .watch() stream -> AsyncValue<List<Dua>>
final duasProvider = StreamProvider<List<Dua>>(
  (ref) => ref.watch(databaseProvider).watchDuas(),
);

/// family + autoDispose
final duaProvider = StreamProvider.autoDispose.family<Dua?, int>(
  (ref, id) => ref.watch(databaseProvider).watchDua(id),
);

/// Notifier: synchronous state
class ReciteCounter extends Notifier<int> {
  @override
  int build() => 0;
  void increment() => state++;
  void reset() => state = 0;
}
final reciteCounterProvider =
    NotifierProvider.autoDispose<ReciteCounter, int>(ReciteCounter.new);

/// AsyncNotifier + family: the argument is a constructor parameter in Riverpod 3
class DuaEditor extends AsyncNotifier<Dua?> {
  DuaEditor(this.duaId);
  final int duaId;

  @override
  Future<Dua?> build() async {
    final db = ref.watch(databaseProvider);
    return (db.select(db.duas)..where((t) => t.id.equals(duaId))).getSingleOrNull();
  }

  Future<void> rename(String title) async {
    final current = state.value;
    if (current == null) return;
    state = const AsyncLoading<Dua?>();
    state = await AsyncValue.guard(() async {
      final updated = current.copyWith(title: title);
      await ref.read(databaseProvider).updateDua(updated);
      return updated;
    });
  }

  Future<void> toggleFavorite() async {
    final current = state.value;
    if (current == null) return;
    await ref.read(databaseProvider).setFavorite(current.id, !current.favorite);
    if (!ref.mounted) return;                       // Riverpod 3 guard
    state = AsyncData(current.copyWith(favorite: !current.favorite));
  }
}
final duaEditorProvider =
    AsyncNotifierProvider.autoDispose.family<DuaEditor, Dua?, int>(DuaEditor.new);
```

`main.dart`. Open the DB once and inject it with an override:
```dart
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final db = openAppDatabase();
  runApp(ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: const DailyDuasApp(),
  ));
}
```

Widget side: use `ref.watch` for rendering, `ref.listen` for side effects and `ref.read` in callbacks. **[V-run analyze]**
```dart
class _ReciteCounterViewState extends ConsumerState<ReciteCounterView> {
  @override
  Widget build(BuildContext context) {
    final dua = ref.watch(duaProvider(widget.duaId));      // AsyncValue<Dua?>
    final count = ref.watch(reciteCounterProvider);
    ref.listen(reciteCounterProvider, (previous, next) {    // side effects only
      final target = dua.value?.repeatCount ?? 0;
      if (target > 0 && next == target) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Completed')));
      }
    });
    return switch (dua) {
      AsyncData(value: final d?) => Column(children: [
          Text(d.arabic, textDirection: TextDirection.rtl,
               style: const TextStyle(fontFamily: 'Amiri', fontSize: 28)),
          Text('$count / ${d.repeatCount}'),
          FilledButton(
            onPressed: () => ref.read(reciteCounterProvider.notifier).increment(),
            child: const Text('Count')),
        ]),
      AsyncData() => const Text('Dua not found'),
      AsyncError(:final error) => Text('Error: $error'),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}
```

### 2.3 Testing APIs (in 3.4.3 source; logic tests ran green) [V-src][V-run]

- **`ProviderContainer.test({overrides, observers, retry, parent})`.** It calls `addTearDown(container.dispose)` for you (via `test_api`), so it works inside `flutter_test`.
- **Override APIs:**
  - `Provider.overrideWithValue(v)`
  - `FutureProvider` / `StreamProvider.overrideWithValue(AsyncValue)`
  - `xProvider.overrideWith(...)`
  - `NotifierProvider.overrideWithBuild((ref, self) => 10)`
  - `family.overrideWith2(...)`
- **`WidgetTester.container({Finder? of})`.** This extension (`RiverpodWidgetTesterX`) is exported by `flutter_riverpod`.

```dart
test('AsyncNotifier family', () async {
  final container = ProviderContainer.test(
    overrides: [databaseProvider.overrideWithValue(db)],
    retry: (retryCount, error) => null,
  );
  final id = await addSampleDua(db, 'Old');
  container.listen(duaEditorProvider(id), (_, _) {});      // keep autoDispose provider alive
  await container.read(duaEditorProvider(id).future);
  await container.read(duaEditorProvider(id).notifier).rename('New');
  expect(container.read(duaEditorProvider(id)).value?.title, 'New');
});

test('overrideWithBuild', () {
  final c = ProviderContainer.test(
      overrides: [reciteCounterProvider.overrideWithBuild((ref, self) => 10)]);
  expect(c.read(reciteCounterProvider), 10);
});
```

Optional, not recommended: `riverpod_lint` 3.1.8 is the last version that works with Dart 3.12, because 3.1.9 needs Dart ≥3.13. `riverpod_generator`/`riverpod_annotation` 4.x are only needed for codegen, which we skip.

---

## 3. Drift (SQLite)

Versions:
- `drift 2.35.1` and `drift_dev 2.35.1` (2026-09-30)
- `drift_flutter 0.3.1` (2026-07-11)
- `sqlite3`: **3.5.2** is the newest that resolves on 3.44.8 (3.7.0 is latest)
- `sqlite3_flutter_libs 0.6.0+eol` is an empty package: "no longer does anything"

Links:
- https://pub.dev/packages/drift
- https://pub.dev/packages/drift_flutter
- https://pub.dev/packages/sqlite3
- drift changelog: https://github.com/simolus3/drift/blob/develop/drift/CHANGELOG.md
- sqlite3 changelog: https://github.com/simolus3/sqlite3.dart/blob/main/sqlite3/CHANGELOG.md
- sqlite3 hook docs: https://github.com/simolus3/sqlite3.dart/blob/main/sqlite3/doc/hook.md

### 3.1 What changed in 2026: sqlite3 3.x uses build hooks [V-doc][V-src][V-run]

- **`sqlite3 3.0.0` breaking change.** In the changelog's words, it uses "build hooks to load SQLite instead of `DynamicLibrary`". You should **drop `sqlite3_flutter_libs`**.
- **`drift 2.32.0`** moved to `sqlite3` 3.x. `drift_flutter 0.3.x` depends on `sqlite3 ^3.0.0` and `sqlite3_flutter_libs ^0.6.0+eol`, the empty one.
- **How the hook works.** `hook/build.dart` downloads a **prebuilt, sha256-pinned** SQLite for the build target from the package's GitHub release. No C compiler is needed.
  - Release tag: `sqlite3-3.5.2`.
  - Android: `libsqlite3.{arm,arm64,ia32,x64}.android.so`. With `--target-platform android-arm64`, only arm64 is fetched.
  - Compile options include FTS5, math functions and `SQLITE_DQS=0`.
  - **The first build needs internet.** Proxy env vars are respected.
- **Optional user-defines** in `pubspec.yaml`: `hooks: user_defines: sqlite3: source: system | sqlite3mc | sqlcipher | ...`, `url_pattern`. Not needed.
- Native assets are **enabled by default on stable 3.44.8**: `features.dart` has `nativeAssets … stable: enabledByDefault: true`. `flutter test` runs hooks for the host.
- The only other hook in our graph is `objective_c`, which is a no-op off iOS/macOS. **[V-src]**

**Windows unit tests (`flutter test` / `dart test`).** You don't need a `sqlite3.dll` on PATH. The hook downloads `sqlite3.dll` (x64) into `.dart_tool\hooks_runner\shared\sqlite3\...` and `.dart_tool\lib\sqlite3.dll`.
- I ran this here. `dart run bin/smoke_db.dart` printed "Running build hooks…" and `sqlite version: 3.53.4`.
- Then drift CRUD, the type converter, the DAO, `PRAGMA foreign_keys=1` and the `watch()` emissions all worked. **[V-run]**
- With sqlite3 **2.x** (old setup), Windows tests needed a manually supplied `sqlite3.dll`. That's no longer true.

### 3.2 Tables + type converter (List<int> as JSON) [V-run]

```dart
// lib/data/converters.dart
import 'dart:convert';
import 'package:drift/drift.dart';

class IntListConverter extends TypeConverter<List<int>, String> {
  const IntListConverter();
  @override
  List<int> fromSql(String fromDb) =>
      [for (final e in jsonDecode(fromDb) as List<dynamic>) e as int];
  @override
  String toSql(List<int> value) => jsonEncode(value);
}
```
Alternatively, `TypeConverter.json2<List<int>>(fromJson: (j) => [for (final e in j as List) e as int])`. Note that `TypeConverter.json` (v1) is **deprecated** in 2.35 in favour of `json2`. **[V-src]**

```dart
// lib/data/tables.dart
import 'package:drift/drift.dart';
import 'converters.dart';

class Duas extends Table {                         // row class `Dua`, companion `DuasCompanion`
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text().withLength(min: 1, max: 200)();
  TextColumn get arabic => text()();
  TextColumn get translation => text().withDefault(const Constant(''))();
  IntColumn get repeatCount => integer().withDefault(const Constant(1))();
  BoolColumn get favorite => boolean().withDefault(const Constant(false))(); // added in v2
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class Reminders extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get duaId => integer().references(Duas, #id, onDelete: KeyAction.cascade)();
  IntColumn get minutesOfDay => integer()();                       // 0..1439 local
  TextColumn get weekdays => text().map(const IntListConverter())(); // ISO 1..7
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
}

class Recitations extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get duaId => integer().references(Duas, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get recitedAt => dateTime()();
  IntColumn get count => integer().withDefault(const Constant(1))();
}
```

### 3.3 Database: queries, streams, batch, transaction, DAO, migrations [V-run]

```dart
// lib/data/database.dart
import 'package:drift/drift.dart';
import 'converters.dart';
import 'tables.dart';
part 'database.g.dart';

@DriftDatabase(tables: [Duas, Reminders, Recitations], daos: [HistoryDao])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);          // app: driftDatabase(...); tests: NativeDatabase.memory()

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async => m.createAll(),
    onUpgrade: (Migrator m, int from, int to) async {
      if (from < 2) await m.addColumn(duas, duas.favorite);
    },
    beforeOpen: (OpeningDetails details) async {
      await customStatement('PRAGMA foreign_keys = ON');   // needed for references()/cascade
      if (details.wasCreated) { /* seed bundled duas with seedDuas(...) */ }
    },
  );

  Stream<List<Dua>> watchDuas() =>
      (select(duas)..orderBy([(t) => OrderingTerm.asc(t.title)])).watch();
  Stream<Dua?> watchDua(int id) =>
      (select(duas)..where((t) => t.id.equals(id))).watchSingleOrNull();
  Future<int> addDua(DuasCompanion e) => into(duas).insert(e);
  Future<bool> updateDua(Dua row) => update(duas).replace(row);
  Future<void> setFavorite(int id, bool v) =>
      (update(duas)..where((t) => t.id.equals(id))).write(DuasCompanion(favorite: Value(v)));

  Future<void> seedDuas(List<DuasCompanion> rows) =>
      batch((b) => b.insertAll(duas, rows));                // batch insert

  Future<int> addDuaWithReminder(DuasCompanion dua,
      {required int minutesOfDay, required List<int> weekdays}) {
    return transaction(() async {                            // all-or-nothing
      final id = await into(duas).insert(dua);
      await into(reminders).insert(RemindersCompanion.insert(
          duaId: id, minutesOfDay: minutesOfDay, weekdays: weekdays));
      return id;
    });
  }
}

@DriftAccessor(tables: [Recitations])
class HistoryDao extends DatabaseAccessor<AppDatabase> with _$HistoryDaoMixin {
  HistoryDao(super.attachedDatabase);

  Future<int> logRecitation(int duaId, {int count = 1, DateTime? at}) =>
      into(recitations).insert(RecitationsCompanion.insert(
          duaId: duaId, recitedAt: at ?? DateTime.now(), count: Value(count)));

  Stream<List<Recitation>> watchBetween(DateTime from, DateTime to) =>
      (select(recitations)
            ..where((r) => r.recitedAt.isBiggerOrEqualValue(from) &
                           r.recitedAt.isSmallerThanValue(to))
            ..orderBy([(r) => OrderingTerm.desc(r.recitedAt)]))
          .watch();
}
```

- The generated code gives you `db.historyDao` (a `late final`), plus `Dua.copyWith`, `==`/`hashCode`, `toJson()` and `Dua.fromJson()`. That's handy for JSON export/import, so **no freezed needed**.
- Drift also generates a "manager" API (`db.managers...`). To skip it, set `generate_manager: false`.
- Drift 2.31+ automatically throws on attempted **downgrades** in step-by-step migrations.
- **Step-by-step migrations + generated migration tests.** Add `databases:` to `build.yaml`, then run `dart run drift_dev make-migrations`. This writes schema snapshots to `drift_schemas/` and tests to `test/drift/`. The command and keys exist in drift_dev 2.35.1. **[V-src]**

`build.yaml`, verified to work with build_runner 2.15.1:
```yaml
targets:
  $default:
    builders:
      drift_dev:
        options:
          store_date_time_values_as_text: true   # ISO-8601 text instead of unix seconds
          databases:
            app_db: lib/data/database.dart        # for `dart run drift_dev make-migrations`
```

**DateTime storage, measured [V-run].** With `store_date_time_values_as_text: true`:
- A local `DateTime(2026,10,6,21,30)` is stored as `2026-10-06T21:30:00.000 +05:00`. It reads back as local, `isUtc=false`.
- A UTC value is stored as `...Z` and reads back as UTC.
- `currentDateAndTime` defaults are stored as SQLite UTC `2026-10-06 15:28:00` and read back as **UTC** (`isUtc=true`). Call `.toLocal()` before grouping by day.

The default (no option) is unix **seconds**, which loses milliseconds. Pick one before the first release, because changing it later needs a migration.

### 3.4 Opening the DB in the app (`drift_flutter`) [V-src][V-run analyze]

```dart
import 'package:drift_flutter/drift_flutter.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

void _configureSqlite(CommonDatabase db) {       // top-level: sent to drift's isolate
  db.execute('PRAGMA journal_mode = WAL;');
  db.execute('PRAGMA busy_timeout = 5000;');
}

AppDatabase openAppDatabase() => AppDatabase(
  driftDatabase(
    name: 'daily_duas',                          // -> <getApplicationDocumentsDirectory()>/daily_duas.sqlite
    native: const DriftNativeOptions(setup: _configureSqlite),
  ),
);
```

- `driftDatabase({required String name, DriftWebOptions? web, DriftNativeOptions? native})` returns a `DatabaseConnection`.
- Native `DriftNativeOptions` fields:
  - `shareAcrossIsolates`
  - `databasePath` / `databaseDirectory` (mutually exclusive)
  - `tempDirectoryPath`
  - `setup`
  - `isolateSetup`
  - `isolateDebugLog`
- It opens SQLite on a **background isolate** (`NativeDatabase.createBackgroundConnection`). It also points `sqlite3.tempDirectory` at the app temp dir, since Android has no `/tmp`.
- About `shareAcrossIsolates: true`: its doc says it uses `IsolateNameServer`, and "**does not work across databases opened by independent Flutter engines**".
  - Alarm/notification callbacks that run in a separate background engine get their own connection. WAL + `busy_timeout` (above) keep that safe.
  - Better still: keep heavy DB writes out of background engines.

### 3.5 Testing with an in-memory DB [V-run]

```dart
import 'package:drift/drift.dart' hide isNull, isNotNull;   // avoid clash with matchers
import 'package:drift/native.dart';

late AppDatabase db;
setUp(() => db = AppDatabase(DatabaseConnection(
      NativeDatabase.memory(),
      closeStreamsSynchronously: true,   // avoids "Timer still pending" in widget tests
    )));
tearDown(() => db.close());

test('insert + watch emits rows', () async {
  final stream = db.watchDuas();
  await db.addDua(DuasCompanion.insert(title: 'Morning', arabic: 'x'));
  await expectLater(stream, emits(isA<List<Dua>>().having((l) => l.length, 'length', 1)));
});
```

- `NativeDatabase.memory({logStatements, setup, ...})` and `DatabaseConnection(executor, closeStreamsSynchronously: ...)` both exist in 2.35.1. **[V-src]**
- If tests create several DB instances, set `driftRuntimeOptions.dontWarnAboutMultipleDatabases = true`.

---

## 4. Navigation: go_router 17.5.0 (recommended) vs plain Navigator

**Why not go_router 18.x?** Its changelog for 18.0.0 says: "Migrates to material_ui and cupertino_ui" + min Flutter 3.44/Dart 3.12. **[V-doc]**
- `material_ui` is the **decoupled Material library**. Its README says it "was previously built directly into the core Flutter framework as `package:flutter/material.dart`".
- Mixing it with `package:flutter/material.dart` (which the 3.44.8 template and most plugins still use) requires wrapping the app in a `MaterialUiCompatibilityBridge`.
- `cupertino_ui` 1.0.x depends on `flutter_localizations` from the SDK, which **pins `intl 0.20.2`**. That conflicts with `table_calendar 3.3.0` (`intl >=0.20.3`). Pub reported exactly that conflict. **[V-run]**
- **`go_router 17.5.0`** has none of this: env `sdk ^3.10`, `flutter >=3.38`, deps only `flutter` + `logging`. It's maintained by the Flutter team. https://pub.dev/packages/go_router
- Revisit material_ui/go_router 18 when we move to Flutter ≥3.47. Note that `material_ui` 1.4+ needs Flutter 3.47 / Dart 3.13. **[V-src]**

**Recommendation: go_router 17.5.**
- `StatefulShellRoute.indexedStack` keeps each tab's stack and scroll state.
- URL-style navigation like `appRouter.go('/today/recite/3')` works from notification callbacks, which have no `BuildContext`.
- Plain `Navigator` would need hand-written tab-state preservation and a global navigator key anyway.

Router code (analyzed; the APIs match the 17.5.0 source **[V-src][V-run analyze]**):

```dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();

final GoRouter appRouter = GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: '/today',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) => HomeShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/today',
            builder: (context, state) => const TodayScreen(),
            routes: [
              // /today/recite/3 : full screen above the bottom bar; Back returns to /today
              GoRoute(
                path: 'recite/:id',
                parentNavigatorKey: rootNavigatorKey,
                builder: (context, state) =>
                    ReciteScreen(id: int.parse(state.pathParameters['id']!)),
              ),
            ],
          ),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/library', builder: (c, s) => const LibraryScreen(), routes: [
            GoRoute(path: 'dua/:id',                         // /library/dua/12 keeps the bottom bar
                builder: (c, s) => DuaDetailScreen(id: int.parse(s.pathParameters['id']!))),
          ]),
        ]),
        StatefulShellBranch(routes: [GoRoute(path: '/history', builder: (c, s) => const HistoryScreen())]),
        StatefulShellBranch(routes: [GoRoute(path: '/settings', builder: (c, s) => const SettingsScreen())]),
      ],
    ),
  ],
);

/// From a notification-tap handler (no BuildContext):
void openReciteFromNotification(int duaId) => appRouter.go('/today/recite/$duaId');

class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: navigationShell,
    bottomNavigationBar: NavigationBar(
      selectedIndex: navigationShell.currentIndex,
      onDestinationSelected: (i) => navigationShell.goBranch(
        i, initialLocation: i == navigationShell.currentIndex), // re-tap pops tab to root
      destinations: const [
        NavigationDestination(icon: Icon(Icons.today), label: 'Today'),
        NavigationDestination(icon: Icon(Icons.menu_book), label: 'Library'),
        NavigationDestination(icon: Icon(Icons.calendar_month), label: 'History'),
        NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
      ],
    ),
  );
}
// MaterialApp.router(routerConfig: appRouter, theme: ThemeData(colorSchemeSeed: Colors.teal), ...)
```

- **Cold start from a notification:** read the launch payload *before* `runApp`. The flutter_local_notifications `getNotificationAppLaunchDetails()` API is covered in the sibling notes.
- Then either build the router with `initialLocation: '/today/recite/3'` (make `appRouter` a function, or a `late final` set in `main`), or call `appRouter.go(...)` right after the first frame.
- `go` replaces the stack. `push` adds to it. Nesting `recite` under `/today` with `parentNavigatorKey: rootNavigatorKey` means Back lands on Today instead of exiting.
- Not run on a device: the nested `parentNavigatorKey` pattern is from the go_router docs and checked by the analyzer only.

---

## 5. History calendar: table_calendar (recommended)

Versions:
- `table_calendar 3.3.0` (2026-10-01; deps `intl >=0.20.3 <0.21.0`, `simple_gesture_detector ^0.2.0`)
- `3.2.1` (2026-08-09; `intl ^0.20.0`)
- https://pub.dev/packages/table_calendar

**Constraint:** use `^3.2.1`. Pub picks 3.3.0, and falls back to 3.2.1 automatically if `flutter_localizations` (which pins intl 0.20.2) is ever added. **[V-run]**

**Why not a custom grid?** We'd be hand-writing month paging/swipe, week-start handling, header, today/selected styling and accessibility. table_calendar is pure Dart with one tiny dependency. `calendarBuilders` covers custom day cells (e.g. a completion-ring color per day).

```dart
import 'package:collection/collection.dart';
import 'package:table_calendar/table_calendar.dart';

/// table_calendar passes UTC-midnight days (normalizeDate = DateTime.utc(y,m,d)) [V-src]
DateTime dayKey(DateTime d) => DateTime.utc(d.year, d.month, d.day);

final byDay = groupBy<Recitation, DateTime>(recitations, (r) => dayKey(r.recitedAt.toLocal()));

TableCalendar<Recitation>(
  firstDay: DateTime.utc(2024, 1, 1),
  lastDay: DateTime.utc(2100, 12, 31),
  focusedDay: _focused,
  startingDayOfWeek: StartingDayOfWeek.monday,
  availableCalendarFormats: const {CalendarFormat.month: 'Month'},
  selectedDayPredicate: (day) => isSameDay(day, _selected),
  eventLoader: (day) => byDay[dayKey(day)] ?? const [],
  onDaySelected: (selected, focused) => setState(() { _selected = selected; _focused = focused; }),
  onPageChanged: (focused) => _focused = focused,          // no setState needed
  calendarBuilders: CalendarBuilders<Recitation>(
    markerBuilder: (context, day, events) => events.isEmpty ? null : Positioned(
      bottom: 4,
      child: Container(width: 6, height: 6,
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle)),
    ),
  ),
)
```

- Feed it from `historyDao.watchBetween(firstOfMonth, firstOfNextMonth)` through a `StreamProvider.autoDispose.family`.
- Non-English `locale:` needs `initializeDateFormatting()` (see §6).

---

## 6. intl, collection, uuid, freezed

- **intl 0.20.3** (https://pub.dev/packages/intl).
  - Usage: `DateFormat.yMMMEd().format(d)` → "Tue, Oct 6, 2026"; `DateFormat.jm()` → "5:08 PM"; `DateFormat('EEE d MMM')`.
  - Only `en_US` symbols are built in. For other locales, call `await initializeDateFormatting('ar')` from `package:intl/date_symbol_data_local.dart`.
  - **Gotcha [V-run]:** `package:intl/intl.dart` exports its own `TextDirection`. With `flutter/material.dart` also imported, `TextDirection.rtl` failed to compile ("The getter 'rtl' isn't defined"). Always `import 'package:intl/intl.dart' show DateFormat;` (or `hide TextDirection`).
  - If `flutter_localizations` is ever added, intl is pinned to **0.20.2**.
- **collection 1.19.1.** The Flutter SDK pins this exact version. Useful bits: `groupBy`, `firstWhereOrNull`, `sortedBy`, `ListEquality`.
- **uuid 4.6.0.** `const Uuid().v4()` or `.v7()` (time-ordered). Only needed for backup/export ids. Drift ints are fine for primary keys.
- **freezed: avoid.**
  - `freezed 4.0.2` needs Dart **≥3.13** (doesn't resolve on 3.12). 3.2.5 would work but adds codegen.
  - Drift row classes already give `copyWith`/`==`/`toJson`. Dart 3 records and sealed classes cover the rest.

---

## 7. Testing

- **Packages:** `flutter_test` (SDK) + `flutter_lints 6.0.0` (depends on `lints ^6.0.0`, resolves to 6.1.0). This is the template default. Use `flutter_lints`, not bare `lints`.
- **SDK pins from flutter_test [V-src]:**
  - `fake_async 1.3.3`
  - `test_api 0.7.11`
  - `matcher 0.12.19`
  - `path 1.9.1`
  - `clock 1.1.2`
  - `stack_trace 1.12.1`
  - `stream_channel 2.1.4`
  - `meta 1.18.0`
  - `collection 1.19.1`
- **Do NOT add `test:`** to dev_dependencies. With `drift_dev 2.35.1` + Flutter 3.44.8 pins, version solving fails. Pub's message said that because the project depends on both `drift_dev ^2.35.1` and `test any`, version solving failed. **[V-run]**
- **`mocktail 1.0.5`** resolves if mocks are wanted. Prefer fakes/overrides.

Widget test with Riverpod overrides + in-memory drift. I analyzed this one but did **not** execute it; running `flutter test` would have written into the SDK cache.
```dart
testWidgets('list shows rows from in-memory DB', (tester) async {
  final db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
  addTearDown(db.close);
  await tester.runAsync(() => addSampleDua(db, 'Morning adhkar'));   // real I/O outside fake-async zone

  await tester.pumpWidget(ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    retry: (retryCount, error) => null,
    child: const MaterialApp(home: Scaffold(body: DuaList())),
  ));
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));  // let the DB isolate answer
  await tester.pumpAndSettle();
  expect(find.text('Morning adhkar'), findsOneWidget);

  final container = tester.container();            // RiverpodWidgetTesterX
  expect(container.read(reciteCounterProvider), 0);
  await tester.pumpWidget(const SizedBox());       // unmount before db.close()
});
```

HTTP mocking and fake time. **[V-run analyze]** The same code patterns ran under `dart test` in the VM check.
```dart
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';           // MockClient
import 'package:fake_async/fake_async.dart';

final client = MockClient((request) async =>
    http.Response(jsonEncode({'out': 'EN:x'}), 200, headers: {'content-type': 'application/json'}));
// inject http.Client into services (e.g. via a Provider) so tests can pass MockClient

fakeAsync((async) {
  var fired = false;
  Future<void>.delayed(const Duration(minutes: 5), () => fired = true);
  async.elapse(const Duration(minutes: 5));
  expect(fired, isTrue);
});
```

Inside `testWidgets` time is already faked: use `tester.pump(duration)`. Use `fakeAsync` for plain `test()` logic such as reminder schedulers. Prefer injecting `clock` (`package:clock`, a transitive dependency) for "now".

Running on Windows:
- `flutter test` and `flutter analyze` work from PowerShell with no extra setup.
- sqlite3 comes from the hook (§3.1); network is needed on the first run.
- No Developer Mode is needed for an Android-only project (§1.3).

---

## 8. App icon

**Lowest disk, zero deps:** generate PNGs once, for example with the existing `tools/make_icon.py`, into `android/app/src/main/res/`:
- `mipmap-mdpi`: 48 px
- `mipmap-hdpi`: 72 px
- `mipmap-xhdpi`: 96 px
- `mipmap-xxhdpi`: 144 px
- `mipmap-xxxhdpi`: 192 px

Name them `ic_launcher.png`, as the template does. For an adaptive icon on API 26+, add `mipmap-anydpi-v26/ic_launcher.xml` with `<adaptive-icon><background android:drawable="@color/ic_bg"/><foreground android:drawable="@mipmap/ic_launcher_foreground"/><monochrome .../></adaptive-icon>`. Foreground PNGs are 108 dp with the logo inside the central 72 dp.

**Convenient:** `flutter_launcher_icons 0.14.4` (2025-06-10; pure Dart; deps include `image ^4.2.0`; resolves on 3.44.8 **[V-run]**). It's a dev dependency and can be removed after running. Config keys from its README **[V-src]**:
```yaml
flutter_launcher_icons:
  android: "ic_launcher"           # true = overwrite default ic_launcher
  ios: false
  image_path: "assets/icon/icon.png"            # 1024x1024
  min_sdk_android: 24
  adaptive_icon_background: "#0F5E55"           # color or image
  adaptive_icon_foreground: "assets/icon/icon_foreground.png"
  adaptive_icon_monochrome: "assets/icon/icon_monochrome.png"   # Android 13 themed icons
```
Run `dart run flutter_launcher_icons`. Adaptive icons are only generated when *both* background and foreground are set.

---

## 9. Recommended `pubspec.yaml` block (resolved against the real 3.44.8 pins) [V-run]

I resolved this with `dart pub get` (FLUTTER_ROOT pointing at the 3.44.8 SDK packages, Dart 3.12.2). It produced 178 packages with no conflicts. The core subset then went through build_runner, analyze and run.

```yaml
environment:
  sdk: ^3.12.0          # Flutter 3.44.8 ships Dart 3.12.2

dependencies:
  flutter:
    sdk: flutter

  # --- app core ---
  flutter_riverpod: ^3.4.3     # -> 3.4.3
  go_router: ^17.5.0           # -> 17.5.0  (18.x = material_ui migration; avoid on 3.44)
  drift: ^2.35.1               # -> 2.35.1
  drift_flutter: ^0.3.1        # -> 0.3.1
  sqlite3: ^3.5.2              # -> 3.5.2  (3.6+ needs meta 1.19 via hooks/record_use)
  path_provider: ^2.1.6        # -> 2.1.6
  path: ^1.9.1                 # pinned 1.9.1 by flutter_test
  table_calendar: ^3.2.1       # -> 3.3.0 (falls back to 3.2.1 if flutter_localizations added)
  intl: ^0.20.2                # -> 0.20.3 (0.20.2 if flutter_localizations added)
  collection: ^1.19.1          # pinned 1.19.1 by flutter
  http: ^1.6.0                 # -> 1.6.0
  uuid: ^4.6.0                 # -> 4.6.0

  # --- platform features (setup details in the sibling research notes) ---
  flutter_local_notifications: ^22.3.1
  timezone: ^0.11.1
  flutter_timezone: ^5.1.1
  alarm: ^5.15.0
  just_audio: ^0.10.6
  audio_service: ^0.18.19
  audio_session: ^0.2.4
  file_picker: ^13.1.0
  record: ^7.1.1
  flutter_tts: ^4.2.5
  app_settings: ^9.0.0
  android_intent_plus: ^6.1.0
  permission_handler: ^13.0.2  # its android impl compiles vs SDK 37 (see 1.4)
  url_launcher: ^6.3.3
  share_plus: ^13.3.1
  package_info_plus: ^10.2.2

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0        # -> 6.0.0 (lints 6.1.0)
  drift_dev: ^2.35.1           # -> 2.35.1
  build_runner: ^2.15.1        # -> 2.15.1 (2.15.2+ needs analyzer >=13.3 -> meta ^1.18.3)
  fake_async: ^1.3.3           # pinned 1.3.3 by flutter_test
  # flutter_launcher_icons: ^0.14.4   # optional, run once (resolves)
  # mocktail: ^1.0.5                  # optional (resolves)

flutter:
  uses-material-design: true
  fonts:
    - family: Amiri
      fonts:
        - asset: assets/fonts/Amiri-Regular.ttf
        - asset: assets/fonts/Amiri-Bold.ttf
          weight: 700
```

Key transitive versions in the lock:
- `analyzer 13.0.0`, `_fe_analyzer_shared 100.0.0`, `build 4.0.7`, `source_gen 4.2.4`, `dart_style 3.1.9`, `sqlparser 0.45.0`
- `hooks 2.0.2`, `code_assets 1.2.1`, `native_toolchain_c 0.19.2`, `record_use 0.6.0`
- `meta 1.18.0`, `test_api 0.7.11`, `riverpod 3.4.3`, `listen 1.0.1`, `state_notifier 1.0.0`, `jni 1.1.0`
- `sqlite3_flutter_libs 0.6.0+eol` (empty), `rxdart 0.28.0`, `shared_preferences 2.5.6`

**Why the newest isn't always picked.** The Flutter SDK pins `meta: 1.18.0` (`packages/flutter/pubspec.yaml`) **[V-src]**:
- `analyzer` 13.1.0–14.4.0 require `meta ^1.18.3`, so drift_dev and build_runner land on analyzer **13.0.0**.
- `build_runner` 2.15.2+ requires `analyzer >=13.3.0`, so **2.15.1**.
- `sqlite3` ≥3.6.0 requires `hooks ^2.2.0` → `record_use ^1.0.0` → `meta ^1.19.0`, so **3.5.2**.

Caret constraints let pub backtrack on its own. Writing `build_runner: ^2.16.1` or `sqlite3: ^3.7.0` makes `pub get` **fail**.

Packages whose newest release needs Dart ≥3.13 (Flutter 3.47) and therefore must be avoided or held back:
- `freezed 4.0.2`
- `riverpod_lint 3.1.9`
- `material_ui 1.4+`
- `cupertino_ui 1.1.1`

---

## 10. What was actually run (reproducibility)

Scratch, outside the repo: a fake `FLUTTER_ROOT` with NTFS junctions to `D:\DuasSDK\home\flutter\3.44.8\packages\*` and `bin\cache\pkg\*`, plus `PUB_CACHE` in the session scratchpad. The SDK's `dart.exe` was only executed (read-only).

1. `dart pub get --dry-run` on the latest versions. It failed on:
   - `table_calendar 3.3.0` vs `flutter_localizations` (intl 0.20.2)
   - `sqlite3 3.7.0` vs the `meta` pin
   - `go_router 18` vs `intl ^0.20.3`
2. Iterated to the block in §9. `dart pub get` succeeded with 178 packages.
3. `dart run build_runner build` (AOT builders, about 98 s the first time) generated `database.g.dart`.
4. `dart analyze` came back clean except `avoid_print` in a scratch script. It covered:
   - drift tables/DB/DAO
   - providers
   - router
   - calendar
   - recite screen
   - `main.dart`
   - all four test files
5. `dart run bin/smoke_db.dart`: the hook downloaded `sqlite3.dll`; SQLite 3.53.4. CRUD, converter, batch, transaction, DAO stream, FK pragma and the DateTime-as-text round-trip all OK.
6. A pure-Dart copy (riverpod 3.4.3 + drift 2.35.1 + sqlite3 3.5.2 + package:test): **7/7 tests passed**. They covered the drift tests and Riverpod `Notifier`/`StreamProvider`/`AsyncNotifier.family`/`overrideWithBuild`/`ProviderContainer.test`.
7. Not run: `flutter test`, `flutter build apk`, and anything Gradle/NDK-related. These need the `flutter` tool, which writes to the SDK cache and downloads the NDK. I left them for the build step.

---

## 11. Open risks / unverified

- **Android build not executed here.** Unverified: the NDK extracted size, AGP 9.0.1's default CMake/build-tools versions, and any warning when a plugin uses compileSdk 37.
- **`--split-per-abi --target-platform android-arm64`.** Whether extra ABI split APKs are also emitted is unverified. The single-APK command avoids the question.
- **Path with a space.** The project path has a space (`duas app`). Flutter only rejects spaces in the *Android SDK* path (`android_sdk.dart`). The `jni` CMake build under `build\` *should* cope with it **[UNVERIFIED]**. If a native build fails on paths, build from a junction such as `mklink /J D:\dd "D:\Coding\Python\duas app"`.
- **The widget test (§7)** is analyzer-verified only.
- **`kotlinOptions {}`** from older plugin READMEs may error under KGP 2.3.20. Keep the template's `kotlin { compilerOptions { … } }`.
- **Future Flutter upgrades (3.47+, Dart 3.13).** Re-run `flutter pub upgrade --major-versions`. Expect the material_ui migration (`dart fix --apply --code=migrate_design_widgets`) and go_router 18.
