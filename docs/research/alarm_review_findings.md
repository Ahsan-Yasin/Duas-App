# Confirmed alarm review findings (all verified real)

## F1 [high] lib/core/native/native_bridge.dart:293 - One MissingPluginException permanently switches the real bridge to FakeNativeBridge (also hit when audio_service starts the engine headless)

**Scenario:** MainActivity extends AudioServiceActivity, so the FlutterEngine comes from AudioServicePlugin.getFlutterEngine(). AudioService.onCreate() calls the same method (audio_service-0.18.19 AudioService.java:345), which runs main() with no MainActivity. That means configureFlutterEngine() never runs and 'daily_duas/native' and 'daily_duas/native_events' have no handlers. This happens when SystemUI media resumption binds the exported MediaBrowserService after reboot or unlock (any user who has played recitation audio), or when a Bluetooth media button reaches MediaButtonReceiver. main.dart:49 getTimezone() then throws MissingPluginException, and _invoke sets _useNative=false for the life of the isolate. DailyDuasApp.initState then subscribes to _fallback.events. The engine stays cached after the service unbinds, so when the user opens the app later, MainActivity registers its handlers but Dart never calls them again. Effects: every reminder create/edit/toggle syncs only to the fake (the new or changed alarm never rings, and the sync check reports OK against the fake). The Reliability screen shows the fake all-green status. 'ringing' events never arrive, so no ring screen opens. Native never received 'listen' (hasListener=false), so ring/start launches go to the mailbox, which is read only once at startup. Ring-screen Start/Snooze/Dismiss only touch the fake, so the real alarm keeps ringing and is logged as missed.

**Proposed fix:** Never latch the fallback on Android. In _invoke: `on MissingPluginException { if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) rethrow; _useNative = false; return fallback(_fallback); }`. Apply the same rule in the `events` getter: never return _fallback.events on Android. Make the event stream re-attachable: add `void resetEvents() => _events = null;` and in DailyDuasApp._onResume cancel and re-listen _eventsSub (a duplicate 'listen' is harmless, because NativeEvents.onListen just replaces the sink). Also call `getLaunchAction()` in _onResume and pass a non-null result to _handleLaunch, so mailbox launches written while Dart was not listening are consumed. main.dart already guards getTimezone, so a rethrow there is safe.

## F2 [medium] lib/features/alarm/alarm_ring_screen.dart:153 - A re-ring of the same occurrence (snooze/nag) never refreshes an open AlarmRingScreen; Snooze then closes the screen while the alarm keeps ringing

**Scenario:** isShowingAlarm() (navigation.dart:55) matches only on (reminderId, occurrenceMs). Snooze and nag rings keep the original occurrence_ms, so app.dart:109 (ringing event), app.dart:137 (ring launch) and app.dart:89 (resume) all skip openAlarm while the old screen is mounted. The old screen keeps its stale widget.alarm (snoozesUsed, kind) and its _stopped flag. Example A: the alarm auto-stops after ring_seconds and the screen shows 'Alarm stopped - start when you are ready' with the pulse stopped. 10 minutes later the nag rings (the full-screen intent shows the activity over the lock screen), but the user still sees 'Alarm stopped' while the tone plays. Example B: a reminder with max_snoozes=1 rings with the app open. The user snoozes from the notification shade, and the screen stays open (see the next finding). The snooze rings with snoozes_used=1, but the stale screen still offers 'Snooze 5 min (1 left)'. Tapping it calls AlarmEngine.perform('snooze'), which returns 0 without calling service.finish() because occ.snoozesUsed >= maxSnoozes. _action() still returns true, so _snooze() calls _leave(). The screen pops, RootShell shows (over the keyguard if launched by the full-screen intent), and the alarm keeps ringing with no ring UI until it times out and is logged as missed.

**Proposed fix:** Refresh the screen when a new ring starts for the same occurrence. In app.dart _onNativeEvent/_onResume/_handleLaunch use `final s = shownAlarm; if (s == null || s.reminderId != a.reminderId || s.occurrenceMs != a.occurrenceMs || s.startedMs != a.startedMs) openAlarm(a);`. openAlarm already replaces an existing alarm route. Alternatively, add startedMs to isShowingAlarm's comparison. In _snooze, do not trust a missing exception. After alarmAction('snooze'), call `final still = await _bridge.getRinging(); if (still != null && still.reminderId == _alarm.reminderId) { setState(() => _busy = false); show 'No snoozes left'; return; }` and only then call _leave().

## F3 [medium] lib/features/alarm/alarm_ring_screen.dart:116 - Ring screen ignores stops caused from the notification; the 'start' launch pushes ReciteScreen above a ghost alarm screen that cannot be popped

**Scenario:** _onEvent returns early for reasons started/dismissed/snoozed even when this screen did not cause them (_busy false), and nothing else closes the alarm route. With the app open while the alarm rings, the user taps 'Start reciting' in the notification. Kotlin performs start, which emits stopped(started) (ignored) and then launch(start). app.dart:139 openRecite() pushes ReciteScreen on top of the still-mounted AlarmRingScreen. After finishing the recitation, the user lands back on a pulsing alarm screen with PopScope(canPop:false) and must press Dismiss. Kotlin perform('dismiss') sees occ.status 'started' != 'dismissed', so it logs a 'dismissed' event and overwrites the occurrence status to dismissed for an alarm that was actually started. A Snooze/Dismiss from the shade also leaves a ghost screen. Pressing its Snooze then spends another snooze and re-arms the snooze alarm. While ReciteScreen is above it, a later alarm for another reminder is put into the hidden route by nav.replace() (navigation.dart:79), so it is invisible.

**Proposed fix:** In _onEvent: `if (userReasons.contains(event['reason'])) { if (!_busy && mounted) Navigator.of(context).removeRoute(ModalRoute.of(context)!); return; }`. Use removeRoute, not pop, because the alarm route may not be on top. Add `void closeAlarm()` in navigation.dart that calls `navigatorKey.currentState?.removeRoute(_alarmRoute!)` when _alarmRoute?.isActive, then clears _alarmRoute/_shownAlarm (removeRoute never completes `popped`). Call closeAlarm() in app.dart _handleLaunch case 'start' before openRecite(), because the stopped event can be dropped when the sink is not ready.

## F4 [medium] lib/app.dart:67 - Cold start while an alarm is ringing (no launch action) never shows AlarmRingScreen

**Scenario:** The process is cold (Dart not running) when AlarmReceiver fires. RingService.begin() emits 'ringing' while NativeEvents.sink is null, so the event is dropped. Nothing writes it to the mailbox, because only launches are stored. The phone is unlocked and in use, so Android shows the full-screen intent as a heads-up instead of starting MainActivity. The user opens Daily Duas from the launcher icon or recents, so there is no EXTRA_LAUNCH and get_launch_action returns null. _runStartupGate handles only the launch, sync and ingestEvents and never calls getRinging(). The first AppLifecycleState.resumed is delivered before DailyDuasApp registers its observer (and _onResume also returns while !_gateDone). The app shows Home, with a 'You missed...' banner, while the alarm rings in the background. The ring screen appears only after a later background/foreground cycle.

**Proposed fix:** In the post-frame callback of _runStartupGate, after `if (launch != null) await _handleLaunch(launch);`, add: `final ringing = await _guard(_bridge.getRinging); if (mounted && ringing != null && !isShowingAlarm(ringing)) openAlarm(ringing);`. Optional: when launch?.action == 'ring', show the alarm screen as the first route instead of building RootShell and then sliding the alarm route over it. Today Home is briefly visible over the keyguard on a full-screen-intent cold start.

## F5 [medium] lib/main.dart:54 - tz local falls back to UTC for Android alias zone IDs (Asia/Calcutta, Europe/Kiev...), so Home shows the wrong next-alarm countdown/day

**Scenario:** main.dart imports timezone/data/latest.dart. Its 'default' database omits deprecated/backward-link IDs (verified in timezone-0.11.1 latest.tzf: Asia/Calcutta, Europe/Kiev, Asia/Katmandu, Asia/Saigon, Asia/Rangoon and America/Buenos_Aires are absent; they are present only in latest_all.tzf). Many Android devices report the ICU canonical ID through ZoneId.systemDefault(), for example 'Asia/Calcutta' in India. tz.getLocation throws, and tz.setLocalLocation(tz.UTC) runs. home_screen.dart:374 then computes nextAlarm in UTC. A 05:00 reminder on an IST phone at 01:00 shows 'Today, 5:00 AM - in 9 h 30 min' instead of 'in 4 h', and the Today/Tomorrow boundary is wrong. The real alarm (java.time) rings at 05:00 local, but the app tells the user otherwise. tz.local is also never updated after a timezone change while the cached engine lives.

**Proposed fix:** Use `import 'package:timezone/data/latest_all.dart' as tzdata;` so alias IDs resolve. If getLocation still fails, do not use UTC. Pick a location whose current offset equals DateTime.now().timeZoneOffset, e.g. `tz.timeZoneDatabase.locations.values.firstWhere((l) => l.currentTimeZone.offset == DateTime.now().timeZoneOffset.inMilliseconds, orElse: () => tz.UTC)`. Move this into a function and call it again from DailyDuasApp._onResume (when getTimezone() differs from tz.local.name), then invalidate the home providers.

## F6 [medium] lib/core/alarm/alarm_service.dart:208 - Event ingestion uses MAX(at_ms) as a watermark, so events logged after the clock moves backwards are never imported

**Scenario:** ingestEvents() fetches getEvents(lastAtMs()), and Kotlin filters at_ms < since_ms. AlarmStore stamps events with System.currentTimeMillis(). If the wall clock was ahead and is then corrected, every later native event has at_ms below the stored maximum and is skipped. Examples: the user moves the clock forward to test a reminder and back again, or a phone boots with a wrong RTC and NITZ/NTP corrects it. Once the clock passes the old maximum, only newer events are fetched, so the skipped ones are lost permanently even though Kotlin still holds them. missedBanner() reads only the DB, so a really missed alarm in that window never produces the Home 'You missed... Start now?' banner, and history/stats lose those rang/started/dismissed rows.

**Proposed fix:** Do not use a strict watermark. The native log is capped at 500 entries and the table has UNIQUE(reminder_id, occurrence_ms, event, at_ms) with ConflictAlgorithm.ignore, so either call `bridge.getEvents(0)` or use a generous overlap: `final since = await events.lastAtMs(); final fresh = await bridge.getEvents(since > 0 ? since - const Duration(days: 7).inMilliseconds : 0);`. Clamp to >= 0. Duplicates are dropped by the unique index.

## F7 [high] android/app/src/main/AndroidManifest.xml:90 - No direct-boot support: alarms are not re-armed after a reboot until the user unlocks the phone

**Scenario:** The phone reboots at night while locked, for example after an overnight OTA install or Samsung's Auto optimization restart around 3 AM. AlarmManager drops every alarm at reboot. BOOT_COMPLETED only arrives after the first unlock, because BootReceiver is not directBootAware, LOCKED_BOOT_COMPLETED is not in the intent-filter or ACTIONS, and AlarmStore keeps its data in credential-encrypted SharedPreferences. So nothing is armed until the user unlocks, and the morning dua alarm (e.g. 05:00) never rings. ARCHITECTURE.md section 7 and docs/research/flutter_alarm.md (lines 342, 529-556) both require LOCKED_BOOT_COMPLETED, but the implementation leaves it out.

**Proposed fix:** Manifest: add `<action android:name="android.intent.action.LOCKED_BOOT_COMPLETED"/>` to BootReceiver and set `android:directBootAware="true"` on BootReceiver, AlarmReceiver, ActionReceiver and RingService (not MainActivity). BootReceiver.ACTIONS: add Intent.ACTION_LOCKED_BOOT_COMPLETED. AlarmStore.prefs(): use `val dp = c.applicationContext.createDeviceProtectedStorageContext()`, run `dp.moveSharedPreferencesFrom(c.applicationContext, PREFS)` once (guard it with a flag stored in dp prefs, and only when the user is unlocked), then return `dp.getSharedPreferences(PREFS, MODE_PRIVATE)`. Notifications.buildRinging: when `!UserManagerCompat.isUserUnlocked(c)`, leave out setFullScreenIntent and the Start action, because Flutter/MainActivity cannot run before unlock. Snooze and Dismiss through ActionReceiver still work. BOOT_COMPLETED after unlock re-runs rescheduleAll, which is idempotent.

## F8 [high] android/app/src/main/kotlin/com/dailyduas/daily_duas/MainActivity.kt:122 - EventChannel sink goes stale when audio_service destroys the cached engine, so launch and ringing events are dropped and the mailbox is never written

**Scenario:** AudioServiceActivity's engine is destroyed whenever the activity detaches while recitation audio is not playing. AudioServicePlugin.onDetachedFromActivity disconnects the MediaBrowser, AudioService.onDestroy runs, and disposeFlutterEngine() destroys the engine. FlutterEngine.destroy() never calls NativeEvents.onCancel, so the cached process keeps `sink` set to the dead engine and `hasListener` stays true. Example: the user exits the app with Back (or SystemNavigator.pop) and the process stays cached. A snooze, nag or the next reminder fires. RingService.begin emits 'ringing' into the dead sink. The FSI starts a fresh MainActivity with a new engine. handleLaunch sees hasListener==true, emits 'launch' into the dead sink (FlutterJNI is detached, so the message is silently dropped) and does not call AlarmStore.setLaunch. Dart's startup gate then gets getLaunchAction()==null, and the full-screen intent shows the home screen instead of AlarmRingScreen. showWhenLocked is true at that point, so the whole app UI is usable over the keyguard. The same loss hits LAUNCH_START: the ring stops natively but Dart never opens ReciteScreen.

**Proposed fix:** In configureFlutterEngine, when `eventsEngine?.get() !== flutterEngine`, first call `NativeEvents.onCancel(null)`, then setStreamHandler. Also register `flutterEngine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener { override fun onPreEngineRestart() = NativeEvents.onCancel(null); override fun onEngineWillDestroy() = NativeEvents.onCancel(null) })`. To be safe, make handleLaunch always call AlarmStore.setLaunch(launch) and also emit the event when a listener exists. Dart's 'launch' handler then consumes it via get_launch_action, so the same launch is never handled twice.

## F9 [medium] android/app/src/main/kotlin/com/dailyduas/daily_duas/AlarmReceiver.kt:16 - No hand-off wake lock between AlarmReceiver and RingService, so the CPU can sleep before the ring starts

**Scenario:** AlarmManager holds its wake lock only while onReceive runs. AlarmEngine.onFire calls startForegroundService and returns. RingService.onCreate/onStartCommand/startForeground and the ring wake lock in begin() run in later main-looper messages. If the device suspends after the AlarmManager lock is released (screen off at 05:00, Doze), the ring, its FSI and its audio wait until something else wakes the device, so the alarm is late or effectively silent. AlarmManager's class docs warn about exactly this. docs/research/flutter_alarm.md:385 and 669 specify a 60 s hand-off lock, but the code does not take one.

**Proposed fix:** Add a process-wide static PARTIAL_WAKE_LOCK, e.g. in an object WakeLocks: tag "DailyDuas:handoff", setReferenceCounted(false). Acquire it with a 60_000 ms timeout as the first statement of AlarmReceiver.onReceive. Release it in RingService.begin() after acquiring the ring lock, on RingService's goForeground-failure and null-ring paths, and on AlarmEngine.onFire's early returns that do not ring. The 60 s timeout covers any path that is missed.

## F10 [medium] android/app/src/main/kotlin/com/dailyduas/daily_duas/RingService.kt:105 - A second alarm while ringing hides the ring UI behind the keyguard, and its full-screen intent never fires

**Scenario:** Reminder A is ringing with MainActivity shown over the lock screen. Reminder B fires (same time, or a nag or snooze of another reminder). onStartCommand calls goForeground(B), which replaces notification ID_RINGING in place, then notifyStopped(A) calls MainActivity.onRingStopped, which runs setShowOverLockScreen(false) synchronously on the main thread. Because the update reuses the same ID with setOnlyAlertOnce(true) (Notifications.kt:84), SystemUI shows no heads-up and does not launch B's full-screen intent again. Dart opens B's ring screen inside an activity that is now hidden behind the keyguard. B rings with no visible UI on a locked phone, and the user has to find the notification in the shade.

**Proposed fix:** In the supersede branch (lines 105-111), emit only the 'stopped' NativeEvent for A and do not call MainActivity.onRingStopped. Add `MainActivity.onRingStarted()`, which re-applies setShowOverLockScreen(true) on a live activity, and call it from begin(). Also post B's notification as a new notification, e.g. alternate the FGS notification id per ring (ID_RINGING / ID_RINGING+1) in goForeground. startForeground with a new id cancels the old one, and the new post alerts and fires its FSI.

## F11 [medium] android/app/src/main/kotlin/com/dailyduas/daily_duas/MainActivity.kt:107 - Opening the app any way other than the alarm notification while an alarm rings never shows the ring screen

**Scenario:** An alarm rings and the Flutter engine is cold. That is the normal state after audio_service has destroyed the engine, or when POST_NOTIFICATIONS is denied, in which case neither the notification nor its FSI is ever shown. The user unlocks and taps the launcher icon. handleLaunch returns immediately because there is no EXTRA_LAUNCH. The 'ringing' event from begin() was already lost (no listener). app.dart's _runStartupGate never calls getRinging, and _onResume is skipped because `_gateDone` is false during the first resume. The user lands on Home while the alarm keeps sounding for ring_seconds (up to 30 min), with no in-app Stop, Snooze or Dismiss. With notifications denied there is no other way to stop it.

**Proposed fix:** In handleLaunch, when there is no EXTRA_LAUNCH but `RingService.ringing()` is non-null and the activity is fresh or the intent is MAIN, synthesize `ring.launchMap(LAUNCH_RING)` and deliver it through the mailbox or event as usual. Do not set showWhenLocked on this path. In app.dart, also call `_bridge.getRinging()` at the end of `_runStartupGate` when launch is null, and openAlarm if it returns a ring.

## F12 [medium] android/app/src/main/kotlin/com/dailyduas/daily_duas/RingService.kt:152 - finish() calls stopSelf() without a startId, which can kill a queued ring start, and onDestroy drops an active ring silently

**Scenario:** Ring A is active and foreground. Reminder B's AlarmReceiver calls startForegroundService. Because the service is already foreground, AMS clears fgRequired, and B's SERVICE_ARGS is queued. In the same instant A finishes (the user taps Dismiss, or the timeout fires), and finish() calls stopSelf(), which stops the service whatever starts are pending. Either B's onStartCommand never runs, or it runs and the queued stop's onDestroy then calls stopOutputs() and silences B immediately. B has already been logged 'rang' with occurrence status 'ringing', but gets no missed notification and no nag, so the occurrence is lost.

**Proposed fix:** Store `lastStartId = startId` at the top of onStartCommand. In finish(), and in the failure and null paths, call `stopSelf(lastStartId)` (stopSelfResult) instead of stopSelf(), so that a newer pending start keeps the service alive. In onDestroy, if `currentRing != null`: capture it, run stopOutputs(), set currentRing = null, then call notifyStopped(ring, AUTO_STOPPED) and AlarmEngine.onMissed(applicationContext, ring), so a ring that is torn down still leaves the missed notice and nag.

## F13 [medium] android/app/src/main/kotlin/com/dailyduas/daily_duas/AlarmEngine.kt:136 - Snooze on an already-snoozed occurrence uses up another snooze, and the ring screen stays open after a notification action

**Scenario:** The user is in the app when the alarm fires. AlarmRingScreen opens and the heads-up notification shows. The user taps Snooze on the notification. ActionReceiver calls perform('snooze'), which sets snoozesUsed=1 and status=snoozed. The 'stopped' event arrives with reason 'snoozed', which alarm_ring_screen.dart:115-116 treats as a user reason and ignores, so the screen stays up with the pulsing icon and 'Snooze 5 min (3 left)'. The user taps Snooze again. perform() finds ringing==null and occ.status==snoozed, still passes the cap check, and sets snoozesUsed=2. It also re-arms the snooze from now (pushing the re-ring later) and logs a second 'snoozed' event. Each extra tap uses up the snooze cap.

**Proposed fix:** Kotlin: in perform 'snooze', return left(occ.snoozesUsed) without changing anything when `ringing == null && occ.status == STATUS_SNOOZED && occ.occurrenceMs == occMs`. Dart: in AlarmRingScreen._onEvent, when `!_busy` and the reason is started, dismissed or snoozed (the action came from the notification), call _leave() instead of ignoring the event.

## F14 [medium] android/app/src/main/kotlin/com/dailyduas/daily_duas/AlarmStore.kt:106 - Launch mailbox never expires and is not checked, so a stale 'ring' or 'start' replays on a later cold start

**Scenario:** An FSI or notification tap writes the launch mailbox because no Dart listener exists yet (MainActivity.kt:125). The activity is then finished or killed before Dart's _runStartupGate reads it: the user backs out during the splash, the process is killed, or the engine fails to start. Days later the user opens the app from the launcher. takeLaunch returns the old {action:'ring'}. app.dart:_handleLaunch finds getRinging()==null, builds a fake RingingAlarm and shows AlarmRingScreen for an alarm that is not ringing. Its Start or Dismiss then logs events against an old occurrence. An old 'start' launch instead pushes ReciteScreen unexpectedly.

**Proposed fix:** In setLaunch, store `at_ms = System.currentTimeMillis()`. In takeLaunch, return null (and clear the entry) when it is older than about 5 minutes. For action 'ring', downgrade to 'open' unless `RingService.ringing()?.reminderId == reminder_id`. In app.dart's 'ring' case, treat getRinging()==null as 'open' rather than building a fake ring.


# Verifier verdicts (order may differ from findings; match by content)

## V1
**Reason:** The claim is real, but it only happens when the wall clock jumps backwards, so the impact is low to medium. I checked each step in the code:
- `AlarmService.ingestEvents()` (lib/core/alarm/alarm_service.dart:206-211) calls `bridge.getEvents(await events.lastAtMs())`.
- `lastAtMs()` (lib/core/repos/repositories.dart:505-508) returns `SELECT MAX(at_ms) FROM alarm_events`.
- On the native side, `AlarmStore.events()` (AlarmStore.kt:134-144) drops every entry with `at_ms < sinceMs`.
- `AlarmStore.logEvent()` (AlarmStore.kt:122-132) stamps `at_ms` with `System.currentTimeMillis()`, which is wall-clock time and can go backwards.
- Nothing resets this watermark. BootReceiver handles ACTION_TIME_CHANGED but only calls `AlarmScheduler.rescheduleAll`. Dart has no other path that writes to alarm_events.

So once a native event with a large `at_ms` is imported, every later event stamped earlier than that value is filtered out. This happens if the clock was ahead and then gets corrected backwards, for example after a manual time change while testing (likely for an alarm app), a wrong RTC fixed by NITZ/NTP, or a large `at_ms` from a far-forward test. After the clock passes the old maximum again, the events stamped in between are permanently excluded, even though Kotlin still holds them (up to 500).

Effects:
- History and stats lose rang/started/dismissed/snoozed rows.
- `missedBanner()` reads only the DB, so a genuinely missed alarm in that window shows no banner.
- In `HomeScreen._logMissedAction` (home_screen.dart:80-91), a dismiss/start tapped on the banner is logged natively, but the ingest skips it. If the occurrence's 'rang' event was imported before the correction, the banner keeps coming back.

This does not stop alarms from ringing; the damage is to event history and the missed banner. The proposed fix is sound. The UNIQUE(reminder_id, occurrence_ms, event, at_ms) index plus ConflictAlgorithm.ignore in `addAll` makes re-importing idempotent, and nothing in Dart deletes alarm_events, so re-reading cannot bring deleted rows back. Of the two options, a full re-read (`getEvents(0)`) is better than a 7-day overlap, because a backward jump can be larger than any fixed overlap.

**Verifier fix:** In lib/core/alarm/alarm_service.dart:206-211, stop using MAX(at_ms) as a strict watermark and re-read the whole native log, which is capped at AlarmStore.MAX_EVENTS = 500. The unique index already drops duplicates:

```dart
Future<List<AlarmEvent>> ingestEvents() async {
  final all = await bridge.getEvents(0);
  if (all.isNotEmpty) await events.addAll(all);
  return all;
}
```

Production code ignores the return value: app.dart calls it through `_guard`, and home_screen.dart only awaits it. If callers should still get only the newly added rows, `addAll` can return the inserted count or the inserted rows (with `noResult: false`, rows with id 0 or null are the ignored ones).

Update test/native/alarm_service_test.dart:240 ('copies only new native events') to match. That test still passes as written, because the second call's result is not checked and the dedupe is done in the DB. Note that its in-memory FakeEvents (line ~45) must also dedupe in `addAll`, or the test will see duplicates.

Optional hardening: give native events a monotonic sequence number (a counter kept in AlarmStore prefs) and use it as the watermark instead of `at_ms`, so ordering no longer depends on the wall clock.

## V2
**Reason:** The code confirms the claim. Each step:
1. If the process is cold when the alarm fires, the Flutter engine and Dart are not running. RingService.begin() (RingService.kt:142) calls NativeEvents.emit with type "ringing" while NativeEvents.sink is null. emit() calls `sink?.success`, so the event is silently dropped (NativeEvents.kt:24-31). Nothing persists the ringing state. AlarmStore's mailbox only holds launches, written by MainActivity.handleLaunch:125.
2. When the device is unlocked and in use, Android shows the full-screen intent as a heads-up notification and does not start the activity. The same happens on API 34+ when the full-screen-intent permission is denied.
3. If the user opens the app from the launcher, the intent has no EXTRA_LAUNCH, so handleLaunch returns at line 107 and stores nothing. If the user opens it from recents, the intent carries FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY, so fresh is false and the extra is removed (MainActivity.kt:69-78). Either way, get_launch_action returns null.
4. In Dart, _runStartupGate (app.dart:61-73) only runs _handleLaunch (when launch is not null), sync('app_start'), ingestEvents and _invalidateHome. getRinging is called in just two places, both conditional: _onResume (line 87) and _handleLaunch's 'ring' branch (line 125).
5. The first AppLifecycleState.resumed is lost:
   - main() calls ensureInitialized and then awaits JustAudioBackground.init, AudioSession, the DB open, seeding, settings and getTimezone before runApp.
   - The activity's onResume lifecycle message reaches ServicesBinding during those awaits, before DailyDuasApp.initState adds its observer.
   - Even if it arrived later, _onResume returns while `!_gateDone`.
6. The result is that the Home tab shows while the alarm keeps ringing. RingService.begin also logs a 'rang' event, and missedBanner treats 'rang' as unanswered, so ingestEvents makes Home show a "missed" banner for the alarm that is still ringing.
7. AlarmRingScreen only appears after a later background/foreground cycle, or if the user taps the heads-up notification. The tap works because the listener is live by then: onNewIntent sees hasListener, emits the launch event, and _handleLaunch('ring') opens the screen.

Severity is moderate rather than critical. The alarm still rings, and it can still be stopped from the notification's actions or, oddly, from the banner's Start/Dismiss buttons, which call alarm_action and finish the ring. What is broken is that the in-app ring UI never appears on this cold-start path.

**Verifier fix:** In lib/app.dart, in the post-frame callback of _runStartupGate, insert this after line 67 (`if (launch != null) await _handleLaunch(launch);`) and before sync:

  final ringing = await _guard(_bridge.getRinging);
  if (!mounted) return;
  if (ringing != null && !isShowingAlarm(ringing)) openAlarm(ringing);

This is safe in every launch case:
- If launch is 'ring', _handleLaunch has already opened the screen, and isShowingAlarm prevents a second one.
- If launch is 'start', AlarmEngine.perform has already finished the ring, so getRinging returns null.
- If launch is 'open', there is no active ring.

A more robust option, which could be added as well, is a native replay of the current ring when Dart subscribes. In NativeEvents.onListen, after `sink = events`, add:
`RingService.ringing()?.let { r -> emit(HashMap(r.toMap()).apply { put("type", "ringing") }) }`
This means no 'ringing' event is lost before the Dart listener attaches, and that covers an engine re-attach as well as cold start.

Optional cosmetic change: when launch?.action == 'ring', build AlarmRingScreen as the first route instead of RootShell. Today RootShell is built first and the alarm route is pushed over it, so Home is briefly visible over the keyguard.

Separate follow-up: missedBanner should skip an occurrence that is currently ringing, for example by checking getRinging or by excluding an occurrence whose latest event is 'rang' and that has no auto_stopped yet. Otherwise the "missed" banner appears while the alarm is still sounding.

## V3
**Reason:** The claim holds; I traced every step in the code.

1. Snooze and nag re-rings keep the original occurrence. In AlarmEngine.kt:53-56 the SNOOZE/NAG branch does `(previous ?: ...).copy(status = STATUS_RINGING)`, so `occurrenceMs` is unchanged. Only `startedMs` (= now, line 70), `kind` and possibly `snoozesUsed` differ.

2. `isShowingAlarm` (navigation.dart:51-57) compares only `reminderId` and `occurrenceMs`. So all three entry points skip `openAlarm` while the old route is active: app.dart:109 (the 'ringing' event emitted by RingService.begin), app.dart:137 (the 'launch' event from MainActivity.onNewIntent/handleLaunch when the full-screen intent fires) and app.dart:89 (resume).

3. AlarmRingScreen has no `didUpdateWidget` and is never rebuilt with new data, so `widget.alarm` and `_stopped` stay stale.

Example A happens on the default path (nagEnabled=true, ringSeconds=120, nag every 10 min). The ring times out, RingService.timeoutNow sends 'stopped' with reason auto_stopped, and `_onEvent` sets `_stopped=true` ("Alarm stopped - start when you are ready", pulse stopped). The screen is not popped. The nag then rings, the full-screen intent calls `setShowOverLockScreen(true)`, Dart skips `openAlarm`, and the user sees "Alarm stopped" with no pulse while the tone plays. In this case the buttons still work (the nag does not change `snoozesUsed`), so the effect is a misleading UI.

Example B is a real lost action:
- Snoozing from the notification shade goes through ActionReceiver to `perform('snooze')` and `service.finish("snoozed")`.
- `_onEvent` ignores 'snoozed' (it is in `userReasons`), and app.dart's 'stopped' handler only ingests events. So the screen stays open with `snoozesUsed=0`.
- When the snooze re-rings, the screen is not refreshed and still shows "Snooze N min (1 left)".
- Tapping it calls `perform('snooze')`, which returns 0 at AlarmEngine.kt:136 (`occ.snoozesUsed >= maxSnoozes`) without calling `service.finish`.
- The bridge call does not throw, so `_action` returns true and `_snooze` calls `_leave()`. The screen pops while RingService keeps ringing.
- MainActivity is still set to show over the lock screen (`onRingStopped` was never called), so RootShell can appear over the keyguard.
- The ring continues until the ring_seconds timeout and is then logged as auto_stopped/missed, followed by a nag.

The return value cannot tell the cases apart: a successful last snooze also returns `left(used)=0`.

**Verifier fix:** 1. Re-open the screen when a new ring starts for the same occurrence. In lib/core/navigation.dart, make `isShowingAlarm` also compare the ring instance:
`return shown.reminderId == alarm.reminderId && shown.occurrenceMs == alarm.occurrenceMs && shown.startedMs == alarm.startedMs;`
The 'ringing' event and get_ringing both carry `Ring.startedMs`, so the ringing event and the launch/resume path for the same ring still match and nothing opens twice. A snooze or nag ring has a new `startedMs`, so `openAlarm` replaces the old route through `nav.replace`, which builds a fresh State with `_stopped=false` and the current `snoozesUsed`, `maxSnoozes` and `kind`.

2. In app.dart `_handleLaunch`, the fallback `RingingAlarm` (used when getRinging returns null) should not open a screen when nothing is ringing. Native code already downgrades that case to 'open'. Use `if (ringing == null) return;` or keep the fallback but rely on the startedMs comparison.

3. Make `_snooze` in lib/features/alarm/alarm_ring_screen.dart check the result instead of trusting a missing exception. After `final ok = await _action('snooze');` and `if (!ok) {...}`, add:
`final still = await _bridge.getRinging(); if (!mounted) return; if (still != null && still.reminderId == _alarm.reminderId) { setState(() => _busy = false); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No snoozes left'))); return; }`
Only then call `_leave()`. A cleaner native option: have `AlarmEngine.perform('snooze')` return -1 when it refuses (`rem == null || occ.snoozesUsed >= maxSnoozes`), and have Dart treat a negative value as failure.

4. Related, optional: in `_onEvent`, when a 'stopped' event for this reminder arrives with a user reason (snoozed, dismissed, started) while `!_busy`, call `_leave()`. An action taken from the notification then closes the ring screen instead of leaving a stale, pulsing one behind.

## V4
**Reason:** The bug is real. Two parts of the claim are wrong and are corrected below.

What the code does:
1. alarm_ring_screen.dart:111-116. _onEvent returns early for every stopped event whose reason is started, dismissed or snoozed, whether or not this screen caused it.
2. Nothing else closes the alarm route. A grep finds no removeRoute or pop of '/alarm' anywhere. app.dart:112 only calls _afterStopped, which ingests events, and _onResume only opens alarm screens, never closes them.
3. Kotlin: ActionReceiver handles notification Snooze/Dismiss by calling AlarmEngine.perform, then RingService.finish, then notifyStopped. That emits {type: stopped, reason: snoozed/dismissed} on the live sink. The notification "Start" goes to MainActivity.onNewIntent (singleTop), which calls perform('start') and then emits launch(start). app.dart:138 then calls openRecite, which pushes ReciteScreen on top of the alarm route that is still mounted.

Concrete failures:
1. App in the foreground or background with the engine alive. The alarm rings, openAlarm pushes the ring screen, and the user taps Snooze or Dismiss on the heads-up notification. Ringing stops, but the ring screen stays, still pulsing (_stopped is never set). PopScope(canPop:false) blocks back, so the only ways out are its own buttons.
   - If the user snoozed from the shade and then taps Dismiss here, perform('dismiss') runs with isCurrent=true. It cancels the pending SNOOZE alarm and sets the status to dismissed, so the snoozed alarm never rings. That is a lost action.
   - Tapping Snooze here instead spends a second snooze and re-arms the timer.
2. The 'start' action from the notification puts ReciteScreen above the stale ring screen. The user lands back on the pulsing ring screen in two cases: closing the recitation early (back/close, then Save or Discard, which calls _exit and pops once), or pressing "Go back". Pressing Dismiss there makes Kotlin log a 'dismissed' event and overwrite the 'started' status. This only affects log accuracy: both statuses count as answered (alarm_service.dart:87).
3. While the stale route sits under ReciteScreen, a ringing event for another reminder hits openAlarm. Because the stale route still counts as active, nav.replace() (navigation.dart:79) puts the new alarm screen in its slot, hidden under ReciteScreen.

Corrections to the claim:
- "After finishing the recitation, the user lands back on the alarm screen" is wrong for the normal finish. ReciteScreen._done (recite_screen.dart:639) calls popUntil((r) => r.isFirst), and Navigator.pop ignores PopScope, so the stale route is removed too. Only the early-close and "Go back" paths land on it.
- "removeRoute never completes popped" is wrong for the project's SDK (Flutter 3.44.8). There, removeRoute calls entry.complete, then handleComplete, then didComplete, so popped completes and navigation.dart:72 clears _alarmRoute itself. Clearing it manually is harmless but not required.

**Verifier fix:** 1. lib/features/alarm/alarm_ring_screen.dart, _onEvent at line 116. Replace `if (userReasons.contains(event['reason'])) return;` with:

```dart
if (userReasons.contains(event['reason'])) {
  final route = ModalRoute.of(context);
  if (route != null && route.isActive) Navigator.of(context).removeRoute(route);
  return;
}
```

   - Use removeRoute rather than pop, because the alarm route may not be on top. removeRoute ignores PopScope.
   - Keep the existing `_busy` early return. When this screen caused the action, _start, _snooze and _dismiss already navigate.

2. lib/core/navigation.dart. Add:

```dart
void closeAlarm({int? reminderId}) {
  final r = _alarmRoute;
  if (r == null || !r.isActive) return;
  if (reminderId != null && _shownAlarm?.reminderId != reminderId) return;
  navigatorKey.currentState?.removeRoute(r);
  _alarmRoute = null;
  _shownAlarm = null;
}
```

   On Flutter 3.44.8, removeRoute completes `popped` by itself, so the two clears are only a safeguard.

3. lib/app.dart _handleLaunch, case 'start'. Call `closeAlarm(reminderId: launch.reminderId)` before openRecite(...).
   - This covers a stopped event dropped while the sink was not attached.
   - Match the reminderId. Without it, a 'start' from another reminder's missed notification would remove the screen of a different alarm that is still ringing; perform('start') only stops the ring whose reminderId matches.

4. Optional hardening in lib/app.dart. In _onNativeEvent, case 'stopped', when the reason is not auto_stopped, also call `closeAlarm(reminderId: (event['reminder_id'] as num?)?.toInt())`. That way the stale route is removed even when the ring screen's own subscription failed (its try/catch at line 55).

## V5
**Reason:** The bug is real, but it only affects what the Home screen shows. The alarm itself still rings at the right time. The India example in the claim is overstated; Ukraine is the case that always triggers it.

What the code does:
- lib/main.dart:6 imports `package:timezone/data/latest.dart` (timezone-0.11.1, tzdata 2025c).
- I decoded the embedded `_embeddedData` in D:\DuasSDK\pub-cache\hosted\pub.dev\timezone-0.11.1\lib\data\latest.dart. It contains Asia/Kolkata and Europe/Kyiv. It does NOT contain Asia/Calcutta, Europe/Kiev or Asia/Saigon. latest_all.tzf contains all of them.
- main.dart:49 gets the zone from MainActivity.kt:186, which returns `ZoneId.systemDefault().id`. Android does not canonicalise that ID; it is whatever is stored in persist.sys.timezone.
- If the ID is missing from the database, `tz.getLocation(zone)` throws and main.dart:56 silently sets `tz.local` to UTC.

Why it actually happens on Android:
- AOSP system/timezone/input_data/android/countryzones.txt (main branch) lists Ukraine as `defaultTimeZoneId:"Europe/Kiev"` / `id:"Europe/Kiev"`, with `alternativeIds:"Europe/Kyiv"`. The comment there says the swap to Kyiv is still a TODO (b/250606303).
- So every Android 13-16 device in Ukraine, whether on automatic or picker-selected time zone, reports "Europe/Kiev". That ID is missing from latest.dart, so `tz.local` becomes UTC.
- India is listed as `id:"Asia/Kolkata"` with Asia/Calcutta only as an alternative. Stock Indian devices therefore usually report Kolkata. The claim's main Calcutta example only applies to devices or emulators that stored the old alias.

Impact:
- `tz.local` is used in exactly one place, home_screen.dart:374 (`TZDateTime.from(now, tz.local)` feeding `nextAlarm`). That code works out the next occurrence, the weekday mask, the Today/Tomorrow label and the countdown in UTC.
- Example: Kyiv in summer (UTC+3) at 01:00 local, reminder at 05:00. The card shows "Tomorrow, 5:00 AM - in 7 h" instead of "Today, 5:00 AM - in 4 h". Weekday-filtered reminders near midnight can also show the wrong day.
- The real alarm is unaffected: Kotlin NextOccurrence.kt:26 schedules it with `ZoneId.systemDefault()`, so it rings at the correct local time.
- The secondary claim also holds: `_onResume` (lib/app.dart:80) never re-reads the time zone, so after the user changes time zone in a still-running process, `tz.local` stays stale.

**Verifier fix:** In lib/main.dart:
- Change line 6 to `import 'package:timezone/data/latest_all.dart' as tzdata;` so alias IDs (Europe/Kiev, Asia/Calcutta, Asia/Saigon, Asia/Rangoon, Asia/Katmandu, America/Buenos_Aires, US/*) resolve.
- Move the zone setup into a reusable function such as `Future<void> applyLocalZone(NativeBridge b)`. It should call `getTimezone()`, try `tz.getLocation(id)`, and on failure NOT fall back to UTC. Instead use the location whose current offset matches the device:
  `final off = DateTime.now().timeZoneOffset.inMilliseconds; tz.setLocalLocation(tz.timeZoneDatabase.locations.values.firstWhere((l) => l.currentTimeZone.offset == off, orElse: () => tz.UTC));`

In lib/app.dart `_onResume`:
- Call that function. If the resulting `tz.local.name` changed, call `_invalidateHome()` so the Next-alarm card recomputes.

Optional hardening on the Kotlin side (MainActivity.kt:186): return a canonical IANA ID. On API 34+ use `android.icu.util.TimeZone.getIanaID(id)`, otherwise return the ID unchanged. latest_all already covers older devices.

## V6
**Reason:** Confirmed against the code and the audio_service 0.18.19 sources (D:/DuasSDK/pub-cache/hosted/pub.dev/audio_service-0.18.19).

1) The fallback latches. In lib/core/native/native_bridge.dart:292-294, the `on MissingPluginException` handler sets `_useNative = false`. Nothing ever sets it back to true. `events` (line 390) then returns `_fallback.events`. The only instance is the one created at main.dart:44 and injected through `nativeBridgeProvider.overrideWithValue`.

2) A headless engine without the channels is reachable. MainActivity extends AudioServiceActivity, whose provideFlutterEngine returns `AudioServicePlugin.getFlutterEngine(context)`. AudioService.onCreate (AudioService.java:345) calls the same method with the Service as context. That method creates `new FlutterEngine(appCtx)`, runs `executeDartEntrypoint(createDefault())` (main()) and caches the engine under "audio_service_engine". The manifest exports AudioService with the `android.media.browse.MediaBrowserService` filter and also exports MediaButtonReceiver. So SystemUI media resumption (it binds saved MediaBrowserServices on USER_UNLOCKED for apps that played media recently), a Bluetooth media button, or an Auto/Wear browser can start the process and run main() with no activity. In that case MainActivity.configureFlutterEngine (the only place 'daily_duas/native' and 'daily_duas/native_events' get handlers) has not run.

3) main() reaches the latch. JustAudioBackground.init completes, because the headless AudioServicePlugin.onAttachedToEngine calls connect(), onConnected resolves configureResult, and the call is try/caught anyway. getTimezone() (main.dart:49) then gets an empty reply on an unhandled channel, which surfaces as MissingPluginException. _invoke catches it, latches the fake and returns 'UTC'. So tz.local also becomes UTC, which home_screen.dart:374 uses. runApp then subscribes DailyDuasApp to the fake event stream.

4) The engine outlives the trigger. Only AudioService.onDestroy, through listener.onDestroy, calls disposeFlutterEngine. The headless engine's own MediaBrowserCompat keeps AudioService bound (it disconnects only on engine or activity detach), so the service and the cached engine live as long as the process. When the user opens the app later, FlutterActivityAndFragmentDelegate.onAttach calls configureFlutterEngine on the cached engine, which registers the handlers. But Dart never uses the channel again.

5) Effects:
- `_onResume` → `sync('resume')`, and every reminder create, edit, toggle or delete, go only to FakeNativeBridge. New or changed reminders are never scheduled, and disabled or deleted ones keep ringing.
- Dart never sent 'listen', so NativeEvents.hasListener stays false. MainActivity.handleLaunch then writes ring/start launches to the AlarmStore mailbox, which Dart reads only once at startup (and against the fake).
- `getRinging()` in `_onResume` asks the fake, so the ring screen never opens. Its Start/Snooze/Dismiss would only touch the fake.
- The Reliability screen reads the fake status (isAndroid=false, all checks true).

Corrections to the claim's wording:
- The ringing alarm can still be stopped from the native notification actions and the RingService timeout.
- Reliability shows the "only on Android" card, not an all-green summary.
- The process can be killed while cached, which would clear the bug. It persists whenever the process survives from the background start until the user opens the app, which is common right after a reboot.

**Verifier fix:** 1) lib/core/native/native_bridge.dart:292-294. Do not latch on Android:
```dart
} on MissingPluginException {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) rethrow; // handlers appear once MainActivity attaches
  _useNative = false;
  return fallback(_fallback);
}
```
On Android `_useNative` starts true, so this rethrows only when the channel is missing. Existing callers already guard the call: main.dart:48-52 has a try/catch, and app.dart uses `_guard` for getLaunchAction, sync, ingestEvents and getRinging.

2) `events` getter (line 389): on Android, never return `_fallback.events`. Add a way to re-subscribe:
`void reattachEvents() { if (_useNative) _events = null; }`
Keep `.asBroadcastStream()` without onCancel, so the old source stays subscribed and never sends 'cancel', which would null the native sink. Expose `reattachEvents` on NativeBridge as a no-op in FakeNativeBridge.

3) lib/app.dart `_onResume`: before syncing, re-attach and re-read everything that was missed:
- `await _eventsSub?.cancel(); _bridge.reattachEvents(); _eventsSub = _bridge.events.listen(_onNativeEvent, onError: ...);` A duplicate 'listen' is harmless, because NativeEvents.onListen just replaces the sink.
- `final zone = await _guard(_bridge.getTimezone); if (zone != null) tz.setLocalLocation(tz.getLocation(zone));` (wrapped in try/catch).
- `final launch = await _guard(_bridge.getLaunchAction); if (launch != null) await _handleLaunch(launch);` This consumes mailbox ring/start launches written while Dart was not listening.
- Then run the existing `sync('resume')`, `ingestEvents` and `getRinging`.

Optional, more robust native fix: register the channels on every engine, not only in configureFlutterEngine. For example, move the MethodChannel/EventChannel setup into a small in-repo Flutter plugin package so GeneratedPluginRegistrant attaches it to the headless audio_service engine too. Activity-only methods (request_notification_permission, open_settings) would use the activity binding when one is present.

## V7
**Reason:** I checked this against the code and it holds. (1) The ringing notification has Snooze and Dismiss actions that go to ActionReceiver and then to AlarmEngine.perform (Notifications.kt:91-96, ActionReceiver.kt:22). When the app is in the foreground, app.dart:107-109 opens AlarmRingScreen. Android shows the full-screen-intent notification as a heads-up at the same time, so the user can tap Snooze on it. (2) For snooze, perform calls service.finish("snoozed") (AlarmEngine.kt:138). That emits {type:stopped, reason:"snoozed"} (RingService.kt:162-164). AlarmRingScreen._onEvent returns early for every user reason (alarm_ring_screen.dart:115-116), and app.dart's 'stopped' handler (app.dart:112-120) only ingests events and invalidates a provider. Nothing pops the screen, so it stays up with the pulsing icon and an active Snooze button. (3) A second tap on Snooze calls perform("snooze", id, occMs). Now ringing is null and stored.occurrenceMs equals occMs, so occ is the stored occurrence (status=snoozed, snoozesUsed=1). The cap check at line 136 passes. snoozesUsed becomes 2 and a second SNOOZED event is logged. arm() then replaces the SNOOZE PendingIntent (same request code, FLAG_UPDATE_CURRENT) with a time measured from the second tap, so the re-ring moves later. (4) A worse follow-on: when the snooze fires, the ring keeps the same occurrenceMs (AlarmEngine.kt:55-56). isShowingAlarm() (navigation.dart) therefore returns true, the stale screen is not replaced, and it still shows the snooze count from the first ring (widget.alarm.snoozesUsed). If the notification snooze used the last one (for example maxSnoozes=1), the screen still offers Snooze. Tapping it makes perform return 0 at line 136 without finishing the service. _snooze only checks for an exception, so it calls _leave(): the screen closes but the alarm keeps ringing until ringSeconds runs out, and that timeout is then logged as auto_stopped/missed and starts a nag. So this produces a duplicate snooze, a shifted re-ring time, and a Snooze button that does not stop the alarm.

**Verifier fix:** Kotlin, AlarmEngine.kt perform "snooze" (before line 136): `if (ringing == null && stored != null && stored.occurrenceMs == occMs && stored.status == STATUS_SNOOZED) return left(stored.snoozesUsed)`. A repeated snooze on an occurrence that is already snoozed and not ringing then changes nothing. Also, when the cap is reached while ringing, do not return silently with the ring still going: either `if (occ.snoozesUsed >= maxSnoozes) { return -1 }` (or throw a "no_snoozes_left" error through the method channel) so Dart can tell the action failed. Dart, alarm_ring_screen.dart _onEvent (lines 114-116): replace the early return with `if (userReasons.contains(event['reason'])) { if (!_busy) _leave(); return; }`. This closes the screen when the snooze, dismiss or start came from the notification; for a notification Start, app.dart's 'launch' handler pushes ReciteScreen afterwards. Optionally also check the result in _snooze: if `alarmAction('snooze')` returns <= 0 while the alarm is still ringing, keep the screen open, set _busy=false and show "No snoozes left" instead of calling _leave().

## V8
**Reason:** The bug is real. I checked it against the code.

**Why nothing is armed before unlock**
- `AndroidManifest.xml:90-101`: BootReceiver has no `android:directBootAware` attribute and no LOCKED_BOOT_COMPLETED action.
- `BootReceiver.kt:22-29`: ACTIONS does not include `Intent.ACTION_LOCKED_BOOT_COMPLETED`.
- AlarmReceiver (84), ActionReceiver (86) and RingService (79) are not directBootAware either.
- `AlarmStore.prefs()` (`AlarmStore.kt:26-27`) uses `c.applicationContext.getSharedPreferences(...)`, which is credential-encrypted (CE) storage.

On a device with file-based encryption and a PIN, pattern or password, this is what happens after a reboot:
1. AlarmManager drops every alarm.
2. Only directBootAware components can run until the first unlock.
3. BOOT_COMPLETED is delivered only after the credential is entered.

So `AlarmScheduler.rescheduleAll` (`AlarmScheduler.kt:103`) does not run until the user unlocks. No main, snooze or nag alarm is armed in the meantime, and a 05:00 dua alarm after a 03:00 reboot stays silent.

**Why adding the action alone is not enough**
- Even if BootReceiver got LOCKED_BOOT_COMPLETED, the CE `getSharedPreferences` call throws IllegalStateException before unlock (minSdk is 26, `build.gradle.kts:22`).
- The 05:00 broadcast to a non-directBootAware AlarmReceiver is filtered out while the user is still locked.

**The spec requires it**
- ARCHITECTURE.md section 7 (line 240-241) lists LOCKED_BOOT_COMPLETED among the reschedule triggers.
- docs/research/flutter_alarm.md (342, 362, 529-556) specifies directBootAware receivers and service plus device-protected prefs.
- The implementation leaves all of these out.

**Severity: medium-high rather than high**
Android 11+ Resume-on-Reboot unlocks CE storage after a system OTA on supported devices, so the claim's OTA example is often covered. These cases are not covered:
- crash or kernel-panic reboots
- a manual restart that is not followed by an unlock
- OEM auto-restart features
- devices without Resume-on-Reboot

**What already works under direct boot (so the fix is enough)**
- In `RingService.createPlayer`, a custom sound path in CE storage fails `File.isFile` and falls back to `R.raw.alarm_tone`.
- `NativeEvents` and `MainActivity.onRingStopped` are null-safe when no activity or engine exists.
- `${applicationName}` resolves to the plain Application, so process start is safe.

**Verifier fix:** **1. AndroidManifest.xml**
- Add `<action android:name="android.intent.action.LOCKED_BOOT_COMPLETED"/>` to BootReceiver's intent-filter.
- Add `android:directBootAware="true"` to `.BootReceiver`, `.AlarmReceiver`, `.ActionReceiver` and `.RingService`.
- Leave MainActivity as it is.

**2. BootReceiver.kt ACTIONS**
Add `Intent.ACTION_LOCKED_BOOT_COMPLETED`. Running `rescheduleAll` again on the later BOOT_COMPLETED is safe because it is idempotent: setAlarmClock replaces each alarm in place.

**3. AlarmStore.kt: switch to device-protected storage with a one-time move**
```kotlin
private const val META = "daily_duas_alarms_meta"
@Volatile private var migrated = false
private fun prefs(c: Context): SharedPreferences {
    val app = c.applicationContext
    val dp = app.createDeviceProtectedStorageContext()
    if (!migrated && androidx.core.os.UserManagerCompat.isUserUnlocked(app)) {
        val meta = dp.getSharedPreferences(META, Context.MODE_PRIVATE)
        if (!meta.getBoolean("moved", false)) {
            dp.moveSharedPreferencesFrom(app, PREFS)   // CE -> DE, only possible while unlocked
            meta.edit().putBoolean("moved", true).commit()
        }
        migrated = true
    }
    return dp.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
```
The move happens on the first access after unlock, so existing installs keep their data. That access comes from MY_PACKAGE_REPLACED at update time, from BOOT_COMPLETED, or from the app's sync.

**4. Notifications.buildRinging (optional hardening)**
When `!UserManagerCompat.isUserUnlocked(c)`, you can skip `setFullScreenIntent` and the Start action, because MainActivity cannot resolve before unlock. Two notes:
- If you keep them, the launch just fails quietly.
- The audio still rings, because it plays through the RingService foreground service on USAGE_ALARM.

Snooze, Dismiss and Stop go through the directBootAware ActionReceiver, so they keep working before unlock.

## V9
**Reason:** The bug is real, but it needs a narrow timing race. One part of the claim is wrong: B's onStartCommand always runs.

How it happens. AlarmEngine.onFire calls RingService.start (AlarmEngine.kt:75) as the last thing in AlarmReceiver.onReceive, on the main thread. The service is already running, so AMS calls sendServiceArgsLocked right away. Because r.isForeground is true, it clears fgRequired, so there is no crash later. It then sends SERVICE_ARGS(B) one-way, which posts it to the main looper. If A's timeoutRunnable (or a Dismiss, Snooze or Stop from ActionReceiver or the method channel) is already due, it runs before that message. A's due time only has to fall inside B's onReceive work (AlarmStore reads and writes plus AlarmManager arm/cancel calls, tens of ms). Then timeoutNow() -> finish() -> stopSelf() at RingService.kt:152 runs. stopSelf() is stopSelf(-1), and in ActiveServices.stopServiceTokenLocked a startId below 0 skips the getLastStartId() check, so AMS calls bringDownServiceLocked even though start B was already delivered. It removes the ServiceRecord and queues STOP_SERVICE after SERVICE_ARGS.

What B goes through. onStartCommand(B) runs with currentRing == null. goForeground(B) returns true, but setServiceForegroundLocked is a no-op because findServiceLocked no longer finds the record. So no ringing notification is posted and nothing reaches the missed path. begin(B) logs RANG, the occurrence stays 'ringing' (written in onFire), and the 'ringing' event goes to Dart. A few ms later onDestroy (RingService.kt:259-264) calls stopOutputs() and nulls currentRing. It does not call notifyStopped or onMissed.

Result: B rings for a few ms or not at all. It gets no missed notification and no nag, its status stays 'ringing', and Dart gets no 'stopped' event, so a ring screen can stay open.

When it is likely. B must fire about A.ringSeconds after A. The default is 120 s and reminders are set to the minute, so two reminders 2 minutes apart line up. The window is tens of ms, comparable to alarm-delivery jitter. A user tap landing in the window is much less likely.

The claim's other branch ("B's onStartCommand never runs") is wrong. SERVICE_ARGS is always queued before STOP_SERVICE, so the actual failure is "runs, then is torn down silently." Lines 95 and 102 have the same stopSelf() pattern, but they only run when no ring is active.

**Verifier fix:** In RingService.kt:
1. Add a field `private var lastStartId = 0` and set `lastStartId = startId` as the first statement of onStartCommand.
2. In finish() at line 152, replace `stopSelf()` with `stopSelfResult(lastStartId)`, and do the same on lines 95 and 102. When a newer start (B) has been delivered but not yet handled, AMS's getLastStartId() != lastStartId, so the stop is refused and the service stays alive for onStartCommand(B). B then calls startForeground again. That is allowed because the FGS-start permission was granted when B's startForegroundService was called from the exact-alarm receiver, and goForeground's failure path already handles a refusal. stopForeground(STOP_FOREGROUND_REMOVE) before it can stay.
3. Make onDestroy safe:
   override fun onDestroy() { val ring = currentRing; stopOutputs(); currentRing = null; if (ring != null) { notifyStopped(ring, AlarmEventName.AUTO_STOPPED); AlarmEngine.onMissed(applicationContext, ring) }; if (current === this) current = null; super.onDestroy() }
   A ring that is torn down by anything other than finish() then still leaves the missed notice and nag, and Dart gets 'stopped'.

## V10
**Reason:** The bug is real; I checked it against the code. RingService.onStartCommand (RingService.kt:99-112) first calls goForeground(B), which calls ServiceCompat.startForeground with the same Notifications.ID_RINGING (line 125). For an app that is already in the foreground, that is an in-place update of the same notification key. SystemUI launches a full-screen intent only when a notification entry is added (HeadsUpCoordinator.onEntryAdded on 13+, onPendingEntryAdded before that). On an update it only relaunches for entries that DND alone had suppressed. So B's full-screen intent never fires. setOnlyAlertOnce(true) at Notifications.kt:84 also stops the heads-up, but the update itself is the root cause.

The supersede branch (lines 105-111) then calls notifyStopped(A), and that calls MainActivity.onRingStopped("auto_stopped") (RingService.kt:164). onStartCommand runs on the main thread, so runOnUiThread executes at once, and setShowOverLockScreen(false) (MainActivity.kt:57-62, 129-143) runs. That calls setShowWhenLocked(false) and setTurnScreenOn(false) and clears FLAG_KEEP_SCREEN_ON. The manifest does not declare showWhenLocked statically. The resumed activity therefore stops occluding the keyguard, and the keyguard shows again.

Nothing re-applies the flags afterwards. They are only set in MainActivity.onCreate and in handleLaunch for LAUNCH_RING, and both are reached only through a full-screen intent or a notification tap. Dart's handling of the 'ringing' event (app.dart:107-109, navigation.dart openAlarm) only swaps the Flutter route and makes no native call. The result is that B's ring screen exists but sits hidden behind the lock screen, and the screen can time out while B keeps sounding.

The scenario is realistic. ring_seconds defaults to 120, so reminders one minute apart are enough, and so is a nag or snooze of another reminder landing during a ring. The claim slightly overstates the impact. B's ongoing, VISIBILITY_PUBLIC notification is still listed on the lock screen, and its Snooze and Dismiss actions are broadcasts, so they still work. What is lost is the full-screen alarm UI and screen-on for B, not B's actions.

The proposed fix is correct. If startForeground is called with a different id, ActiveServices calls cancelForegroundNotificationLocked on the old notification. That is an app-level cancel, so A's deleteIntent does not fire. The new id gets a fresh entry, so the heads-up and the full-screen intent fire (including in the keyguard-occluded case). Notifications.ID_RINGING is used nowhere else, so alternating the id is safe.

**Verifier fix:** 1) In RingService.kt, change the supersede branch (lines 105-111) so it does not touch the activity's lock-screen flags:
```kotlin
currentRing?.let { previous ->
    stopOutputs()
    currentRing = null
    NativeEvents.emit(mapOf("type" to "stopped", "reminder_id" to previous.reminderId, "reason" to AlarmEventName.AUTO_STOPPED))
    // no MainActivity.onRingStopped(): the next ring keeps the activity over the keyguard
    AlarmEngine.onMissed(applicationContext, previous)
}
```
2) In MainActivity's companion object, add:
```kotlin
fun onRingStarted() { val a = activityRef?.get() ?: return; a.runOnUiThread { a.setShowOverLockScreen(true) } }
```
Call `MainActivity.onRingStarted()` from RingService.begin() after `currentRing = ring`.

3) Post each new ring as a new notification so it alerts and fires its full-screen intent. Add `private var notifId = Notifications.ID_RINGING` to RingService. In onStartCommand, before goForeground(ring) and only when currentRing != null, flip it: `notifId = if (notifId == Notifications.ID_RINGING) Notifications.ID_RINGING + 1 else Notifications.ID_RINGING`. Use notifId in ServiceCompat.startForeground at line 125. When the service calls startForeground with a new id, ActiveServices cancels the old foreground notification without sending its deleteIntent, and the new post is a new entry that gets a heads-up and its full-screen intent. If goForeground fails, revert notifId.

## V11
**Reason:** The claim holds. In `AlarmReceiver.kt` (lines 9-17), `onReceive` runs synchronously and calls `AlarmEngine.onFire`. That function ends at line 75 with `RingService.start`, which only calls `ContextCompat.startForegroundService` and returns. The receiver uses no `goAsync` and takes no wake lock of its own. A search of the whole android/ tree finds only one wake lock: `RingService.acquireWakeLock`, tag "DailyDuas:ring". It is taken in `begin()` at line 138. That only happens after the service's `onCreate` (which calls `Notifications.ensureChannels`) and after `onStartCommand` has done `Ring.parse`, `goForeground`, `Notifications.cancelMissed` and `AlarmStore.logEvent`. These run as later CREATE_SERVICE/SERVICE_ARGS messages on the main looper, after `onReceive` has returned. Several of these calls cross into other processes, and `logEvent` writes to storage.

AlarmManager's own class Javadoc (AOSP apex/jobscheduler/framework/.../AlarmManager.java) confirms the risk. It says AlarmManager holds its CPU wake lock only while `onReceive()` executes and releases it once `onReceive()` returns. It also says that if the receiver called `startService()`, "it is possible that the phone will sleep before the requested service is launched." The receiver and service must use their own wake lock policy. ActiveServices does not take a wake lock while starting a service. A temporary allowlist only permits the FGS start; it does not keep the CPU awake. `setAlarmClock` changes neither point.

The system releases AlarmManager's lock as soon as its broadcast-finished callback runs, a few ms after `onReceive` returns. That can come before `begin()` reaches the ring lock, which can be tens of ms later. On an idle phone with the screen off and Doze active, nothing else holds the CPU, so the system can suspend inside that window. The app is then frozen part-way through starting the service. Sound, vibration and the full-screen alarm screen are delayed until the next wakeup, so the alarm rings late or not at all. Even if the ring then starts, `onFire` can skip it if the wait passed `LATE_LIMIT_MS` (30 min). The project's own design (docs/research/flutter_alarm.md:385, 669-706) requires a 60 s static hand-off lock, and the code leaves it out. AOSP DeskClock does the same as that design: it calls `AlarmAlertWakeLock.acquireCpuWakeLock` before `startService`. The window is short, so this is an intermittent failure, not one that happens every time. Medium severity is right.

**Verifier fix:** 1. Add a new file `WakeLocks.kt` holding one wake lock for the whole process:
   `object WakeLocks { private var handoff: PowerManager.WakeLock? = null; @Synchronized fun acquireHandoff(c: Context) { val wl = handoff ?: c.applicationContext.getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "DailyDuas:handoff").apply { setReferenceCounted(false) }.also { handoff = it }; wl.acquire(60_000L) }; @Synchronized fun releaseHandoff() { handoff?.let { if (it.isHeld) runCatching { it.release() } } } }`.
2. `AlarmReceiver.onReceive`: after the action check on line 10, call `WakeLocks.acquireHandoff(context)` before anything else. Call `WakeLocks.releaseHandoff()` before the early returns on lines 13-14.
3. `AlarmEngine.onFire`: call `WakeLocks.releaseHandoff()` on every return that does not ring (the cancel-and-return at line 33, the returns at lines 41, 42 and 54). Also call it after `onMissed` when `RingService.start` returns false (lines 75-79).
4. `RingService`:
   - In `begin()`, call `WakeLocks.releaseHandoff()` right after `acquireWakeLock(...)`.
   - In `onStartCommand`, call it on the `ring == null` path (lines 87-97) and on the `!goForeground(ring)` failure path (lines 99-104).
   - Optionally also call it in `onDestroy`.
The 60 s timeout releases the lock on any path these calls miss.

## V12
**Reason:** The claim holds. I checked the code and the Flutter 3.44.8 and audio_service 0.18.19 sources it runs on.

1. **The Flutter engine is often cold when an alarm rings.** AlarmReceiver starts RingService in a process that may have no activity and no engine. audio_service's `disposeFlutterEngine()` (AudioServicePlugin.java:116, called from `onDestroy` at line 829) also destroys the cached engine once the activity and AudioService are gone. `RingService.begin()` (RingService.kt:142) sends the 'ringing' event through `NativeEvents.emit`, which drops it because there is no sink yet. `NativeEvents.onListen` (NativeEvents.kt:281) only stores the sink and never replays the current ring.
2. **Nothing on the cold-launch path asks whether an alarm is ringing.**
   - A launcher or MAIN intent has no EXTRA_LAUNCH, so `handleLaunch` returns at MainActivity.kt:107. A launch from recents has `fresh=false`, so its extras are removed instead.
   - Nothing else in the code calls `AlarmStore.setLaunch`, so `get_launch_action` returns null.
   - `_runStartupGate` (app.dart:61-73) calls `getRinging` only inside `_handleLaunch` for 'ring'. With a null launch it never calls it.
3. **The first resume never reaches `_onResume`.** In LifecycleChannel.java `lastFocus` starts as `true`, so `onResume` sends 'resumed' right away. At that moment Dart `main()` is still awaiting JustAudioBackground.init, the DB and the timezone lookup, so the app's lifecycle observer (added in `DailyDuasApp.initState`) is not registered yet. The later window-focus change sends nothing new. Even if 'resumed' did arrive late, `_onResume` returns early while `_gateDone` is false. Only a later background and foreground cycle would call `getRinging`.
4. **The result:** the user lands on Home or Onboarding while RingService keeps sounding for `ring_seconds`. That value is clamped to 10-1800 s (AlarmModels.kt:80), so up to 30 minutes. HomeScreen only shows a missed-alarm banner and has no control for a ringing alarm.
5. **Notification permission denied makes it worse.** On Android 13+ with POST_NOTIFICATIONS denied, the foreground-service notification is never shown in the drawer, so its full-screen intent and Start/Snooze/Dismiss actions never appear. The in-app ring screen is then the only stop control, and this path never shows it.

If notifications are allowed, the shade notification still offers a way to stop the alarm. Even then, opening the app from the launcher while an alarm rings does not show the ring screen.

**Verifier fix:** Best fix (Dart only, no lock-screen side effects): in lib/app.dart `_runStartupGate`'s post-frame callback, after `if (launch != null) await _handleLaunch(launch);`, add:

```dart
if (launch?.action != 'ring') {
  final ringing = await _guard(_bridge.getRinging);
  if (mounted && ringing != null && !isShowingAlarm(ringing)) openAlarm(ringing);
}
```

Defence in depth (Kotlin): in NativeEvents.onListen (NativeEvents.kt:281), after `sink = events`, replay the current ring:

```kotlin
RingService.ringing()?.let { emit(HashMap(it.toMap()).apply { put("type", "ringing") }) }
```

This delivers the ring to any engine that attaches mid-ring. Dart's `isShowingAlarm` check stops a second ring screen from opening.

Do not call `setShowOverLockScreen` on the launcher path: the user has already unlocked to reach the launcher. With these changes there is no need to fake a LAUNCH_RING in `MainActivity.handleLaunch`.

## V13
**Reason:** The claim is real, with one part of the scenario wrong. Severity is low to medium: it causes a phantom alarm screen and wrong history entries, but it never stops a real alarm from ringing.

What the code does:
- AlarmStore.setLaunch (AlarmStore.kt:98-102) saves the launch with no timestamp.
- takeLaunch (AlarmStore.kt:106-117) returns whatever is saved, no matter how old, and does not check RingService.
- Only takeLaunch ever clears the mailbox. MainActivity.handleLaunch (MainActivity.kt:107/111) returns early on a plain launcher or 'open' intent, so a later normal launch never clears an old entry.
- Dart reads the mailbox once per isolate, in _runStartupGate (app.dart:62).
- In app.dart:124-137, a 'ring' launch with getRinging()==null builds a fake RingingAlarm (maxSnoozes 0) and calls openAlarm.

How a stale entry gets left behind. The claimed "user backs out during the splash" path does NOT leave the mailbox stale. The engine is audio_service's cached engine (AudioServicePlugin.getFlutterEngine; FlutterActivity does not destroy an engine supplied by the host). So after back, the process and Dart keep running main, and initState still consumes the mailbox. Two real paths do leave it stale:
1. The process dies between setLaunch (inside onCreate) and the get_launch_action call. main.dart awaits several things before runApp: JustAudioBackground.init, AudioSession, DB open plus seed, settings, initializeTimeZones and get_timezone. That gives a window of roughly a second.
   - For 'start', AlarmEngine.perform has already stopped RingService, so no foreground service is running. Swiping the task away during the splash kills the process.
   - For 'ring', the foreground service protects the process from that swipe. Only a crash or a system kill leaves a stale 'ring'.
2. Headless engine. AudioService is exported (MediaBrowserService plus MediaButtonReceiver). AudioService.onCreate calls AudioServicePlugin.getFlutterEngine (audio_service AudioService.java:345), which runs Dart main with no activity attached.
   - main's get_timezone call then gets MissingPluginException, because 'daily_duas/native' is registered only in MainActivity.configureFlutterEngine.
   - native_bridge.dart:292-293 then sets _useNative=false for the rest of the isolate's life. The EventChannel sink is never set and getLaunchAction goes to FakeNativeBridge.
   - From then on, every alarm launch in that process writes the mailbox (hasListener is false) and nothing reads it until the next real cold start, possibly days later.

Same symptom without the mailbox: in the back-out case, _handleLaunch runs in a post-frame callback. Frames are disabled while the app is paused or detached, so that callback can run on a much later resume, after the ring has ended, and again build the fake ring.

Result when a stale entry replays:
- 'ring' shows a silent ring screen that cannot be popped (PopScope canPop:false) for an alarm that is not ringing. Dismiss or Start calls AlarmEngine.perform with an old occurrence_ms. That logs a DISMISSED/STARTED event against an old occurrence (occ.status != status, because a fresh Occurrence object is built) and cancels the current missed-alarm notification (Notifications.cancelMissed). The app then closes itself through SystemNavigator.pop.
- 'start' unexpectedly pushes ReciteScreen with fromAlarm:true.

**Verifier fix:** 1) AlarmStore.kt, setLaunch (line 100): store a timestamp, e.g. `JSONObject(launch).put("at_ms", System.currentTimeMillis())`.

2) AlarmStore.kt, takeLaunch (lines 106-117): after the remove/commit, add
```kotlin
val age = System.currentTimeMillis() - o.optLong("at_ms", 0L)
if (age !in 0..LAUNCH_TTL_MS) return null   // LAUNCH_TTL_MS = 2*60_000L
var action = o.optString("action")
if (action == MainActivity.LAUNCH_RING &&
    RingService.ringing()?.reminderId != o.optInt("reminder_id")) {
    action = MainActivity.LAUNCH_OPEN
}
```
Then return `action` in the map instead of `o.optString("action")`.

3) MainActivity.onCreate (line 78): when `fresh` and the intent has no EXTRA_LAUNCH (plain launcher start), call `AlarmStore.setLaunch(applicationContext, null)` so old entries are dropped.

4) app.dart _handleLaunch 'ring' case (lines 124-137): do not build a fake RingingAlarm. Use
```dart
final ringing = await _guard(_bridge.getRinging);
if (ringing != null && ringing.reminderId == launch.reminderId && !isShowingAlarm(ringing)) openAlarm(ringing);
```
If ringing is null, treat it as 'open'. This also covers the delayed post-frame replay in the same process.

5) Related root cause, worth its own fix: make the bridge recover from the headless engine. Either register the 'daily_duas/native' MethodChannel and the EventChannel from a FlutterPlugin or Application-level hook that runs for every engine, not only in MainActivity.configureFlutterEngine, or do not latch `_useNative=false` permanently on MissingPluginException in native_bridge.dart:292-293 (retry, and re-subscribe events when the activity attaches).

## V14
**Reason:** Confirmed against audio_service 0.18.19 and the Flutter 3.44.8 engine sources.

1. **How the engine gets destroyed.**
   - MainActivity extends AudioServiceActivity, so its engine comes from AudioServicePlugin.getFlutterEngine (the FlutterEngineCache entry "audio_service_engine").
   - On activity destroy, FlutterActivity.shouldDestroyEngineWithHost() returns false for a host-provided engine. It still calls detachFromActivity(), which reaches AudioServicePlugin.onDetachedFromActivity(). With one engine (clientInterfaces.size()==1) that calls disconnect(), which runs mediaBrowser.disconnect() and unbinds.
   - AudioService is only started (startForegroundService) in enterPlayingState(). The "configure" call from JustAudioBackground.init does not start it.
   - So if recitation audio never played, or was stopped, the bound-only service is destroyed. AudioService.onDestroy calls listener.onDestroy(), which calls disposeFlutterEngine(). That calls flutterEngine.destroy() because no client activity is attached.
   - There are no other engines: no workmanager or background-isolate plugins in pubspec.

2. **The sink stays stale.**
   - FlutterEngine.destroy() (FlutterEngine.java:505-523) only runs EngineLifecycleListeners, pluginRegistry.destroy(), dartExecutor.onDetachedFromJNI() and the JNI detach. No EventChannel 'cancel' is ever delivered.
   - So NativeEvents.sink keeps the old EventSinkImplementation and hasListener stays true.
   - sink.success() passes its own checks (hasEnded is false, activeSink is still this) and reaches FlutterJNI.dispatchPlatformMessage. Because isAttached() is false, it only logs "Tried to send a platform message to Flutter, but FlutterJNI was detached". The message is silently dropped, with no exception.

3. **How the launch gets lost.**
   - The next MainActivity.onCreate builds a new engine. configureFlutterEngine registers the handler on the new messenger but leaves the stale sink alone.
   - handleLaunch runs on the main thread in the same onCreate, so the new Dart 'listen' cannot have been processed yet. hasListener is therefore true only because of the dead sink.
   - It emits 'launch' into the dead sink and skips AlarmStore.setLaunch. Dart's _runStartupGate then gets getLaunchAction()==null.
   - RingService.begin's 'ringing' emit is lost the same way.
   - The _onResume getRinging fallback is skipped while _gateDone is false. After that it only runs on a later lifecycle resume, so LAUNCH_RING recovery depends on timing.
   - LAUNCH_START has no fallback at all. AlarmEngine.perform('start') stops the ring natively, but ReciteScreen never opens. The user sees the home screen, and for LAUNCH_RING it sits over the keyguard because setShowOverLockScreen(true) is applied anyway.

4. **What triggers it.**
   - The common trigger is Back on the home tab. RootShell's PopScope has canPop: index==0, so the root pop goes to SystemNavigator.pop, then PlatformPlugin.popSystemNavigator, then activity.finish(). FlutterActivity is not an OnBackPressedDispatcherOwner.
   - This happens on Android 13-15, where predictive back is not on by default (the manifest does not set enableOnBackInvokedCallback). On Android 16 with target 36, back-to-home moves the task to the back instead, so this path does not happen there.
   - The process then stays cached, and the next test alarm, snooze, nag, reminder, or tap on the missed-notification "Start" hits the bug.
   - Swiping the app from recents usually kills the process (no foreground service), so it does not reproduce this way. The AlarmRingScreen's own SystemNavigator.pop is effectively unreachable because openAlarm always pushes over home.
   - The bug is real but narrower than the claim says: it needs no live recitation audio service, Android 15 or lower (or another way the activity gets finished), and a process that is still cached.

**Verifier fix:** MainActivity.kt, configureFlutterEngine (lines 100-103).

configureFlutterEngine runs inside super.onCreate before handleLaunch, so clearing the stale sink there is enough to make handleLaunch fall back to AlarmStore.setLaunch:

    if (eventsEngine?.get() !== flutterEngine) {
        // A previous engine was destroyed by audio_service without Dart sending 'cancel'; drop its dead sink.
        NativeEvents.onCancel(null)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(NativeEvents)
        eventsEngine = WeakReference(flutterEngine)
        flutterEngine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
            override fun onPreEngineRestart() = NativeEvents.onCancel(null)
            override fun onEngineWillDestroy() {
                if (eventsEngine?.get() === flutterEngine) { NativeEvents.onCancel(null); eventsEngine = null }
            }
        })
    }

Both EngineLifecycleListener methods are abstract in Flutter 3.44, so both overrides are required.

The onEngineWillDestroy part also stops RingService.begin / notifyStopped from posting into a dead sink.

Optional hardening: make handleLaunch always call AlarmStore.setLaunch(applicationContext, launch), and also emit the event if hasListener. Do this only together with a Dart change. In app.dart's _onNativeEvent 'launch' case, call _bridge.getLaunchAction() and handle that result, not the event payload. Without that change, the mailbox entry stays stale and is replayed at the next cold start (for example a phantom AlarmRingScreen with maxSnoozes 0, or an unexpected ReciteScreen).
