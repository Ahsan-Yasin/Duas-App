# Daily Duas

An Android app for reciting your daily duas and adhkar. It has a library of
duas with Quran verification, routines, alarm-style reminders that ring through
Do Not Disturb, a guided counter with audio, history and streaks, and an AI
"Ask for a dua" chat.

Flutter 3.44.8 / Dart 3.12, Riverpod 3, sqflite, and a Kotlin alarm engine
(`android/app/src/main/kotlin/com/dailyduas/daily_duas/`). The module contract
is in [ARCHITECTURE.md](ARCHITECTURE.md).

## Setup (Windows)

All SDKs live on `D:\DuasSDK` (Flutter, JDK, Android SDK, Gradle and pub
caches), so the C: drive stays clean. Load the environment in every new
PowerShell window:

```powershell
. "D:\Coding\Python\duas app\tools\build_env.ps1"
Set-Location "D:\Coding\Python\duas app"
flutter pub get
```

Checks:

```powershell
flutter analyze                 # expected: No issues found!
flutter test                    # run from the project root (tests read assets/quran/quran-simple.txt)
cd android; .\gradlew.bat :app:compileReleaseKotlin --console=plain; cd ..
```

Run `flutter test` one invocation at a time. Parallel runs race on
`build/test_cache`.

## Build and install

The built-in Gemini key is not in the source code. Copy `secrets.example.json`
to `secrets.json` (git-ignored) and put the key in it, then build:

```powershell
powershell -ExecutionPolicy Bypass -File tools\build_apk.ps1
# same as: flutter build apk --release --target-platform android-arm64 --dart-define-from-file=secrets.json
```

Without `secrets.json` the app still builds; chat then asks for a key in
Settings > AI.

The APK is written to `build\app\outputs\flutter-apk\app-release.apk` (the
script also copies it to `DailyDuas-<version>.apk` in the project root). Release
builds are signed with the debug key; add a keystore in
`android/app/build.gradle.kts` before publishing.

Install it in one of two ways:

- **adb:** enable USB debugging on the phone, then run
  `adb install -r build\app\outputs\flutter-apk\app-release.apk`.
- **Copy:** copy the APK to the phone, open it in a file manager and allow
  "Install unknown apps" for that file manager.

Minimum Android version: 8.0 (API 26).

Regenerate the bundled alarm tone and launcher icons with
`python tools/gen_alarm_tone.py` and `python tools/gen_icons.py`.

## First run

Onboarding asks for notification permission and full-screen alarm permission,
and suggests turning off battery optimisation. You can set a first reminder from
there. Later, **More > Alarm reliability** shows every permission, the next
scheduled alarm and the last sync, and links to the right system settings for
your phone maker (from dontkillmyapp.com).

## Testing alarms by hand

Run these checks on a real phone with a release build. Emulators do not show
the doze and OEM behaviour you need to test.

- [ ] **Weekday reminder, screen locked.** Create a reminder for 07:00 Mon-Fri
      (or a few minutes from now on today's weekday). Lock the phone and wait.
      The alarm should ring at full volume with a full-screen screen over the
      lock screen. It uses the alarm stream, so it rings in Do Not Disturb when alarms are allowed there (the default).
- [ ] **Start reciting.** Tap *Start reciting*. The ring stops and the recite
      screen opens on the first dua of the reminder's routine.
- [ ] **Snooze.** Snooze rings again after the snooze time (default 5 min, up
      to 3 times). After the last snooze, the Snooze button disappears.
- [ ] **Dismiss.** Dismiss stops the ring. No nag or missed notification
      follows.
- [ ] **Auto-stop.** Let it ring without touching it. After 2 minutes
      (the reminder's ring length) it stops. A persistent "missed" notification
      appears and the nag rings again every 10 minutes (up to 3 times) until
      you start or dismiss it.
- [ ] **Missed banner.** Open the app within 90 minutes of an unanswered
      alarm. Home shows a banner with *Start* / *Dismiss*.
- [ ] **Reboot.** Reboot and unlock the phone. The next alarm is still
      scheduled (check More > Alarm reliability). Alarms re-arm after the first
      unlock.
- [ ] **Time zone change.** Change the time zone or the clock in system
      settings. The alarm still rings at the local wall-clock time.
- [ ] **Test alarm.** Reminders > *Test alarm in 10 seconds* rings without
      touching your real reminders.
- [ ] **Force-stop caveat.** Settings > Apps > Daily Duas > *Force stop*
      cancels all alarms. That is Android behaviour. Alarms come back the next
      time you open the app.
- [ ] **OEM battery settings.** On Xiaomi, Samsung, Huawei, Oppo/Realme/OnePlus
      and Vivo, allow autostart and set battery to "No restrictions"/"Unrestricted".
      Alarm reliability links to the right instructions.

An alarm that the OS delivers more than 30 minutes late (for example, the
phone was off) is logged as missed and does not ring.

## Offline behaviour

Everything except the AI features works offline: the library, routines,
reminders and alarms, the recite counter, history, text-to-speech, your own
recordings and backups. The Quran text is bundled.

These features need the internet:

- **Quran recitation audio** is streamed per ayah from EveryAyah on first use
  and then cached on the phone. Download a routine's audio once (the recite
  screen offers it) and it plays offline after that.
- **Ask for a dua** (chat) and **AI translation** call Gemini or Anthropic.
  Without a connection they show an offline message.

## Chat / AI key setup

Chat and translation use **Gemini** by default with a built-in key. Right now
Google rejects that key with **403 "project denied"**, so chat fails until you
do one of these in **Settings > AI**:

1. Paste your own Gemini API key (free from Google AI Studio). A key you enter
   always takes priority over the built-in one.
2. Switch the provider to **Anthropic** and paste an Anthropic API key.

Keys are stored only on the device. They are never shown in logs and never
included in backups. Anyone can extract the built-in key from the APK, so
restrict it (API restrictions, quota) or rotate it before you share builds.

AI suggestions are checked against the bundled Quran text. Quran wording that
does not match is flagged **unverified**. Nothing is added to your library
unless you tap *Add to my library*.

## Backup

Settings > Backup & restore exports everything (duas, routines, reminders,
history, cached translations) to a JSON file. You can share or save that file.
Import supports **Merge**, which skips duplicates, or **Replace**. API keys are
never exported.

## Known limits

- **Android only.** iOS has not been built or tested; the alarm engine is
  Android native code.
- **sqflite instead of Drift.** Drift was replaced with plain sqflite to keep
  build times down (no code generation).
- **Hadith verification is manual.** Only Quran text is checked automatically.
  Hadith wording always shows as unverified with a source note.
- **Quran audio needs a one-time download** per ayah range and reciter.
- Force-stopping the app and aggressive OEM battery managers can block alarms
  (see the checklist above).

## Licences and attributions

- **Quran text:** Tanzil Project, "Simple" text v1.1 (https://tanzil.net),
  CC BY 3.0. The text is bundled unmodified in `assets/quran/quran-simple.txt`
  with its licence in `assets/quran/LICENSE-tanzil.txt`. The app strips the
  Bismillah prefix from ayah 1 only for display and matching. The file itself
  is unchanged.
- **Quran audio:** EveryAyah.com reciters, streamed on demand and cached per
  device. No audio is bundled in the APK. The reciter credit appears in
  More > About.
- **Arabic font:** Amiri by The Amiri Project Authors, SIL Open Font License
  1.1 (`assets/fonts/OFL-Amiri.txt`).
- **Hadith:** Sahih al-Bukhari 3371 (Arabic as published on sunnah.com).
- English meanings and transliterations were written for this app.
  They are not a published translation.
- The alarm tone and icons are original. They are generated by the scripts in
  `tools/`.
