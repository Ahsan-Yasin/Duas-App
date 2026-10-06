# Daily Duas

An Android app for reciting your daily duas and adhkar. Keep your own list of
duas, group them into routines, and set alarm-style reminders. When an alarm
rings, the app walks you through each dua one at a time with a counter and
optional recitation audio.

Everything is stored on your phone and works offline. Only the AI chat, AI
translation, online source checks and the first download of Quran audio need
the internet.

> **Download:** [`releases/DailyDuas-1.0.0.apk`](releases/DailyDuas-1.0.0.apk)
> (Android 8.0+, arm64, about 21 MB). This public build has **no built-in AI
> key**: to use the chat, paste your own key in **Settings > AI**.

---

## Contents

- [Features](#features)
- [Can I trust the duas?](#can-i-trust-the-duas)
- [Install](#install)
- [First run and permissions](#first-run-and-permissions)
- [Using the app](#using-the-app)
- [How the alarms work](#how-the-alarms-work)
- [Testing alarms on your phone](#testing-alarms-on-your-phone)
- [AI chat and translation](#ai-chat-and-translation)
- [Offline behaviour and privacy](#offline-behaviour-and-privacy)
- [Backup and restore](#backup-and-restore)
- [Build from source](#build-from-source)
- [Project structure](#project-structure)
- [Known limits](#known-limits)
- [Licences and attributions](#licences-and-attributions)

---

## Features

**Library**
- Starts with Surah Al-Ikhlas, Al-Falaq and An-Nas (3 times each), Ayat
  al-Kursi, and the evil-eye dua *A'udhu bi kalimatillahi t-tammati…*
  (Sahih al-Bukhari 3371, 3 times).
- Search, filter by category, add, edit, delete (with Undo), and drag to reorder.
- Each dua stores its Arabic (full tashkeel), transliteration, translation,
  source, category, repeat count (1–100) and audio.
- Each dua shows a **Verified / Unverified** badge (see
  [Can I trust the duas?](#can-i-trust-the-duas)).

**Routines**
- Two ready-made routines: **Morning** and **Evil eye protection**.
- Create your own, add duas from the library, drag to reorder, and override
  the repeat count per routine.
- Mark one routine as the default for the big **Start now** button.

**Recite session**
- Full screen, one dua at a time, with a progress bar and "Dua 2 of 5".
- Large Arabic text (Amiri font, right-to-left). Transliteration and
  translation can each be shown or hidden.
- A large counter button with haptic feedback. When the count is reached it
  shows a short success animation and moves to the next dua (you can turn
  auto-advance off).
- Back, Skip, Pause and Close. Close asks **Save progress?**, and you can
  resume from Home.
- A finish screen with a dua for acceptance (Quran 2:127), a summary and your
  streak.

**Audio**
- Quran duas are recited verse by verse by well-known reciters (see
  [Audio](#where-the-audio-comes-from)), downloaded once and then cached.
- Four modes:
  - **Off.**
  - **Listen:** plays the dua once when you tap play.
  - **Listen then recite:** plays once, then waits for you to recite and tap.
  - **Follow along:** plays the full repeat count, counts for you, and
    highlights the current verse.
- Speed from 0.75× to 1.25×. Audio keeps playing with the screen off and has
  lock-screen controls.
- For non-Quran duas you can attach an audio file or record yourself. As a
  last resort there is the phone's text-to-speech, clearly labelled
  *Not a reciter*.

**Reminders and alarms**
- Pick a time, the weekdays and a routine. Alarms repeat every week with no
  re-arming needed.
- A real alarm: a looping sound on the **alarm volume**, vibration, and a
  full-screen alarm over the lock screen.
- Three actions: **Start reciting**, **Snooze** and **Dismiss** (skips today
  only).
- If nobody answers, it stops after 2 minutes and leaves a "missed"
  notification. It then rings again every *N* minutes, up to *M* times, until
  you respond (both are configurable).
- Home shows a **missed-alarm banner**: "You missed the 7:00 AM routine. Start
  now?"
- A **Test alarm in 10 seconds** button that behaves exactly like a real
  alarm.
- An **Alarm reliability** screen: red/green checks for each permission, fix
  buttons, and battery-saver guides for your phone maker.

**Also**
- AI chat to find duas, with source checks.
- AI translation of a dua's meaning into your language.
- A History calendar with your streak and totals.
- JSON backup and restore.
- Light and dark themes, an Arabic font-size slider with live preview,
  TalkBack labels, large-text support, and tap targets of at least 48 dp.

---

## Can I trust the duas?

The app never changes Arabic text silently, and it shows you where every dua
comes from.

### Quran duas: checked offline against the real text

The app bundles the complete Quran text (all 6,236 verses) from the
[Tanzil Project](https://tanzil.net). When a dua says it is a Quran verse, for
example "Quran 2:201", the app compares its Arabic with that verse,
ignoring vowel marks:

- **Match:** a green **Verified** badge with the exact reference.
  A partial-verse quote is accepted and marked *partial ayah*.
- **No match:** an amber **Unverified** warning: *check with a teacher or a
  mushaf*.

The built-in Quran duas were copied directly from the Tanzil file, not typed
by hand.

### Hadith duas: checked online against the cited hadith

When a dua cites a hadith (for example "Sahih al-Bukhari 3371" or "Sunan Abi
Dawud 5088"), the app downloads that hadith's Arabic text. The source is the
free, public-domain [fawazahmed0/hadith-api](https://github.com/fawazahmed0/hadith-api)
dataset, which covers Bukhari, Muslim, Abu Dawud, Tirmidhi, Nasa'i,
Ibn Majah, Malik, Nawawi's 40 and others. The app then checks that the dua's
words appear in that hadith.

- **Wording found:** **Verified**, with the reference and, where the
  collection has one, the grading (for example *Sahih (Al-Albani)*).
- **Graded weak, not found, or the wording differs:** stays **Unverified**
  with a warning. Different editions number hadith differently, so a real
  hadith can show as "not found". The app never shows Verified when the
  wording doesn't match.

The dua editor and the chat cards have a **View source** button that opens the verse on
[quran.com](https://quran.com) or the hadith on [sunnah.com](https://sunnah.com),
so you can read it yourself.

### AI suggestions

The chat model is told to suggest only Quran or authentic (sahih/hasan)
hadith duas, to always give a source, and to return nothing if it is unsure.
That reduces mistakes but doesn't prove anything, so every suggestion goes
through the Quran or hadith check above and shows its badge. **Nothing is
saved automatically**: you review and edit each card before tapping
*Add to my library*.

> The app shows whether the words match a real source. For anything you rely
> on, a teacher or scholar is the final authority.

### Where the audio comes from

Quran recitation is streamed from [EveryAyah.com](https://everyayah.com), a
long-running archive of verse-by-verse recordings that many Quran apps use.
Each file is fetched by surah and verse number, so the audio is always the
actual verse at that reference.

Available reciters:
- Mishary Rashid Alafasy
- Abdul Basit Abdus-Samad
- Mahmoud Khalil Al-Husary
- Mohamed Siddiq Al-Minshawi
- Abdur-Rahman As-Sudais
- Saud Ash-Shuraim
- Maher Al-Muaiqly
- Ali Al-Hudhaify

Lower-bitrate versions of most of them are offered as smaller downloads.
Files are cached on the phone after the first play. No audio is bundled in the
APK.

---

## Install

1. Download [`releases/DailyDuas-1.0.0.apk`](releases/DailyDuas-1.0.0.apk) to
   your Android phone (Android 8.0 or newer).
2. Open it. When Android asks, allow **Install unknown apps** for your
   browser or file manager.
3. Open **Daily Duas**.

Or, from a computer with USB debugging turned on:

```bash
adb install -r releases/DailyDuas-1.0.0.apk
```

The APK is signed with a debug key, which is fine for sideloading but not for
the Play Store.

---

## First run and permissions

On first launch, onboarding explains each permission **before** asking for it.

| Permission | Why |
|---|---|
| Notifications (Android 13+) | To show the alarm and the "missed" notification. |
| Exact alarms (`USE_EXACT_ALARM`) | So reminders ring at the exact minute. Granted automatically, because the app's core feature is an alarm clock. |
| Full-screen alerts (Android 14+) | To show the alarm screen over the lock screen. |
| Ignore battery optimisation | Recommended, so Android or the phone maker's battery saver does not delay alarms. |
| Microphone (optional) | Only if you record your own recitation. |
| Internet | AI chat, AI translation, online source checks, and the first download of Quran audio. |

Later, **More > Alarm reliability** shows each item as green or red with a
**Fix** button. It also shows the next scheduled alarm and battery-saver
instructions for Samsung, Xiaomi/Redmi/POCO, Oppo/Realme, Vivo/iQOO,
Huawei/Honor and OnePlus, with links to [dontkillmyapp.com](https://dontkillmyapp.com).

---

## Using the app

The bottom navigation has five tabs:

- **Home:** the next alarm and a countdown, today's progress, your streak,
  a **Start now** button, a Resume card for an unfinished session, and the
  missed-alarm banner.
- **Library:** all your duas. Tap one to edit it; it also has Translate,
  Check source online and View source. The **+** button adds a new dua, and
  the chat icon opens the AI chat.
- **Routines:** start, edit, rename, delete, or set a routine as the default.
- **Reminders:** add or edit alarms, turn them on or off, and test an alarm.
- **More:** Chat, History, Settings, Alarm reliability, Backup & restore and
  About.

**Settings** covers:
- theme;
- Arabic font size (with live preview);
- showing transliteration and translation;
- haptics, counter mode (count up or down) and auto-advance;
- default audio mode, reciter and playback speed;
- downloading the audio for your routines, and clearing the audio cache;
- translation language;
- AI provider, key and model;
- default snooze, default routine, backup, and showing onboarding again.

---

## How the alarms work

The alarm engine is native Kotlin code in
[`android/app/src/main/kotlin/com/dailyduas/daily_duas/`](android/app/src/main/kotlin/com/dailyduas/daily_duas/).
It runs even when the app is closed.

- **Scheduling.** Each reminder gets one `AlarmManager.setAlarmClock` alarm
  for each weekday it uses, at the next local occurrence, computed with
  `java.time`, including daylight-saving rules. When an alarm fires, next
  week's alarm is scheduled first, then it rings.
- **Ringing.** A foreground service:
  - plays a looping tone on the **alarm** audio stream, so it follows alarm
    volume, not media volume;
  - vibrates and holds a wake lock;
  - posts a full-screen notification with Start reciting, Snooze and Dismiss.
- **Auto-stop and nag.** After the ring time (2 minutes) the sound stops and
  a persistent "missed" notification stays. If nagging is on, it rings again
  every N minutes, up to M times, until you start or dismiss.
- **Snooze** works natively, even if the app's interface isn't running, and is
  capped at the reminder's maximum snooze count.
- **Recovery.** Alarms are restored after:
  - a reboot, **even before you unlock the phone** (the app supports
    direct-boot mode);
  - a time change, time zone change or daylight-saving change;
  - an app update;
  - a change in the exact-alarm permission.
- **Self-repair.** Every time the app starts or resumes, it compares what
  Android has scheduled with what the database says and fixes any
  difference.

What Android does not allow:
- If you **Force stop** the app in system settings, Android cancels its alarms
  until you open the app again.
- An alarm delivered more than 30 minutes late (for example, the phone was
  off) is logged as missed instead of ringing.

---

## Testing alarms on your phone

Test on a real phone. Emulators don't reproduce Doze mode or phone-maker
battery behaviour.

- [ ] **Locked screen.** Create a reminder for a few minutes from now on
      today's weekday and lock the phone. It should ring at alarm volume with
      a full-screen alarm.
- [ ] **Start reciting.** The ring stops and the routine's first dua opens
      straight away.
- [ ] **Snooze.** It rings again after the snooze time (default 5 minutes, up
      to 3 times). After the last snooze, the Snooze button disappears.
- [ ] **Dismiss.** The ring stops, and no nag follows for that alarm.
- [ ] **Auto-stop and nag.** Leave it ringing. After 2 minutes it stops, a
      "missed" notification stays, and it rings again every 10 minutes (up to
      3 times).
- [ ] **Missed banner.** Open the app within 90 minutes of an unanswered
      alarm. Home shows *You missed the … routine. Start now?*
- [ ] **Reboot.** Reboot the phone. The alarm still rings, even before you
      unlock it.
- [ ] **Time zone.** Change the time zone or the clock. The alarm still rings
      at the same local time.
- [ ] **Test button.** Reminders > *Test alarm in 10 seconds*.

---

## AI chat and translation

Open **Library > chat icon** or **More > Chat** and type something like
*"dua for anxiety"* or *"morning protection dua"*.

- The app sends your message to the AI provider, which replies with a short
  answer and up to 3 duas. Each dua has its Arabic, transliteration,
  translation, source and suggested repeat count.
- Each suggestion is shown as a card with its verification badge, **View
  source**, **Edit** and **Add to my library**. After adding, you can put the
  dua straight into a routine.
- **Translate** (in the dua editor and the recite screen) translates a dua's
  meaning into your chosen language, such as Urdu. The result is cached, so
  it works offline afterwards.

**Setting up a key** (Settings > AI):
- **Gemini** (default): paste a key from
  [Google AI Studio](https://aistudio.google.com/apikey). Use **Test
  connection** to check it.
- **Anthropic:** switch the provider and paste an Anthropic API key.

Keys are stored only on the phone. They are never logged and never included in
backups.

**Troubleshooting:**

| Error | Cause and fix |
|---|---|
| 403 *Your project has been denied access* | Google has blocked the Google Cloud project behind the key. Create a key in a **new** project in AI Studio, or use another provider. |
| 400 / 401 | The key is invalid. Paste it again. |
| 429 | Rate limit. Wait a minute. |
| No internet | Chat, translation and online checks need a connection. Everything else works offline. |

---

## Offline behaviour and privacy

**Works fully offline:**
- the library, routines and recite sessions;
- reminders and alarms;
- history and streaks;
- the Quran verification;
- your own recordings and text-to-speech;
- backups.

**Needs internet:**
- AI chat and translation (Gemini or Anthropic);
- online hadith checks (jsDelivr CDN);
- the first download of each Quran verse's audio (EveryAyah.com);
- *View source* links.

There are no accounts, no analytics and no ads. Your data stays in a local
SQLite database on the phone.

---

## Backup and restore

**Settings > Backup & restore** exports all your duas, routines, reminders,
history and cached translations to one JSON file. You can share it or save it
to the device.

Import offers two modes:
- **Merge:** adds what's new and skips duplicate duas, routines and sessions.
- **Replace:** wipes your data and loads the backup.

API keys are never exported.

---

## Build from source

**Requirements:**
- Flutter **3.44.8** (Dart 3.12)
- JDK 17
- Android SDK with platform 36

The Gradle files use AGP 9 and Kotlin 2.3.

```bash
git clone https://github.com/Ahsan-Yasin/Duas-App.git
cd Duas-App
flutter pub get
flutter analyze        # expected: No issues found!
flutter test           # 199 tests
```

**Optional built-in AI key.** Copy `secrets.example.json` to `secrets.json`
(which git ignores) and add your key:

```json
{ "GEMINI_API_KEY": "your-key" }
```

**Build the APK:**

```bash
flutter build apk --release --target-platform android-arm64 --dart-define-from-file=secrets.json
# without a built-in key: drop the --dart-define-from-file flag
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`.

On Windows, `tools/build_apk.ps1` does the same and copies the APK to
`DailyDuas-<version>.apk`. `tools/build_env.ps1` points Flutter, the JDK, the
Android SDK, Gradle and the pub cache at `D:\DuasSDK` so a small C: drive
stays free; edit the path for your machine.

Before publishing anywhere, add a release keystore in
`android/app/build.gradle.kts`.

**Other tools:**
- `tools/gen_alarm_tone.py` regenerates the original alarm tone (pure Python).
- `tools/gen_icons.py` regenerates the launcher icons.
- To check the Kotlin code compiles:

  ```bash
  cd android && ./gradlew :app:compileReleaseKotlin
  ```

---

## Project structure

```
lib/
  main.dart, app.dart          app start-up, alarm launch routing, theme
  core/
    alarm/alarm_service.dart   syncs reminders to the native engine, repairs, missed banner
    native/native_bridge.dart  MethodChannel/EventChannel bridge to Kotlin (+ fake for tests)
    audio/                     EveryAyah download cache, just_audio player
    net/                       Gemini/Anthropic client, hadith-api client
    db/, repos/, models/       sqflite schema, repositories, models
    backup/                    JSON export/import
    providers.dart             Riverpod providers
  domain/                      pure Dart: Arabic normalisation, Quran index, verification,
                               hadith references, schedule calculator, recite session, stats
  features/                    screens: home, library, routines, recite, alarm, reminders,
                               reliability, chat, history, settings, onboarding
android/app/src/main/kotlin/com/dailyduas/daily_duas/
  AlarmEngine, AlarmScheduler, NextOccurrence, AlarmStore      scheduling + state
  AlarmReceiver, RingService, Notifications, WakeLocks         ringing
  ActionReceiver, BootReceiver, MainActivity, NativeEvents     actions, recovery, Flutter bridge
assets/  quran/ (Tanzil text + licence), fonts/ (Amiri), data/ (seed duas and routines)
test/    data, domain, native, ui tests (199)
docs/research/  notes behind the design decisions (alarm rules, packages, content licences)
```

[ARCHITECTURE.md](ARCHITECTURE.md) describes the module contracts in detail.

**Tech:** Flutter, Material 3, Riverpod 3, sqflite, just_audio +
just_audio_background, record, flutter_tts, timezone, http, file_picker,
share_plus, url_launcher, wakelock_plus, and a custom Kotlin alarm engine.

---

## Known limits

- **Android only.** iOS isn't built. The alarm engine is Android code; an
  iPhone version would need Apple's AlarmKit (iOS 26+) and a Mac to build.
- **Online hadith check:** some real hadith may show as "not found" because
  of numbering differences between editions.
- **Quran audio** needs a one-time download per verse and reciter.
- **Force stop** and very aggressive phone-maker battery savers can stop
  alarms. See the Alarm reliability screen.
- The release APK is signed with a debug key.
- The spec asked for Drift; the app uses plain sqflite instead to keep the
  build simple (no code generation).

---

## Licences and attributions

- **Quran text:** © [Tanzil Project](https://tanzil.net), "Simple" text,
  licensed under CC BY 3.0. Bundled unmodified in `assets/quran/` with its
  licence notice. The app strips the Bismillah prefix from verse 1 only when
  displaying and comparing; the file itself is unchanged.
- **Quran audio:** [EveryAyah.com](https://everyayah.com) reciters, streamed
  on demand and not redistributed in the APK.
- **Hadith text for verification:**
  [fawazahmed0/hadith-api](https://github.com/fawazahmed0/hadith-api)
  (public domain / Unlicense), fetched on demand.
- **Arabic font:** [Amiri](https://github.com/aliftype/amiri), SIL Open Font
  License 1.1 (`assets/fonts/OFL-Amiri.txt`).
- **Built-in evil-eye dua:** Sahih al-Bukhari 3371.
- The English meanings and transliterations were written for this app; they
  are not a published translation.
- The alarm tone and icons are original, generated by the scripts in `tools/`.

*Always confirm duas with a qualified teacher. The app shows whether the words
match a real source, but scholarly guidance comes first.*
