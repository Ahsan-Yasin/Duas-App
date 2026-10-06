import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config.dart';
import 'core/local_zone.dart';
import 'core/native/native_bridge.dart';
import 'core/navigation.dart';
import 'core/providers.dart';
import 'core/theme.dart';
import 'features/home/home_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/shell/root_shell.dart';

/// Root widget: MaterialApp, theming, startup gate and alarm event routing.
class DailyDuasApp extends ConsumerStatefulWidget {
  const DailyDuasApp({super.key});

  @override
  ConsumerState<DailyDuasApp> createState() => _DailyDuasAppState();
}

class _DailyDuasAppState extends ConsumerState<DailyDuasApp>
    with WidgetsBindingObserver {
  static final ThemeData _light = AppTheme.light();
  static final ThemeData _dark = AppTheme.dark();

  StreamSubscription<Map<String, dynamic>>? _eventsSub;
  bool _gateDone = false;
  bool _resuming = false;

  NativeBridge get _bridge => ref.read(nativeBridgeProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _eventsSub = _bridge.events.listen(
      _onNativeEvent,
      onError: (Object e) => debugPrint('Native event error: $e'),
    );
    unawaited(_runStartupGate());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _eventsSub?.cancel();
    super.dispose();
  }

  Future<T?> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (e) {
      debugPrint('Startup/resume step failed: $e');
      return null;
    }
  }

  Future<void> _runStartupGate() async {
    final launch = await _guard(_bridge.getLaunchAction);
    if (!mounted) return;
    setState(() => _gateDone = true);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (launch != null) await _handleLaunch(launch);
      // Opened from the launcher/recents while an alarm rings: the 'ringing'
      // event was emitted before Dart listened and there is no launch action,
      // and the first resume is not delivered to _onResume.
      await _showCurrentRing();
      if (!mounted) return;
      final service = ref.read(alarmServiceProvider);
      await _guard(() => service.sync('app_start'));
      await _guard(service.ingestEvents);
      if (mounted) _invalidateHome();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_onResume());
  }

  Future<void> _onResume() async {
    if (_resuming || !_gateDone) return;
    _resuming = true;
    try {
      // An engine started headless (audio_service) had no channel handlers;
      // now that the activity is attached, re-listen and pull what was missed.
      _bridge.reattachEvents();
      final launch = await _guard(_bridge.getLaunchAction);
      if (!mounted) return;
      if (launch != null) await _handleLaunch(launch);
      await _showCurrentRing();
      final zone = await _guard(_bridge.getTimezone);
      if (zone != null) applyLocalZone(zone); // home providers are invalidated below
      if (!mounted) return;
      final service = ref.read(alarmServiceProvider);
      await _guard(() => service.sync('resume'));
      await _guard(service.ingestEvents);
      if (mounted) _invalidateHome();
    } finally {
      _resuming = false;
    }
  }

  /// Opens the ring screen for whatever is ringing now, unless that ring is
  /// already shown.
  Future<void> _showCurrentRing() async {
    final ringing = await _guard(_bridge.getRinging);
    if (mounted) showRingingAlarm(ringing);
  }

  void _invalidateHome() {
    ref.invalidate(remindersProvider);
    ref.invalidate(routinesProvider);
    ref.invalidate(completedLogsProvider);
    ref.invalidate(unfinishedSessionProvider);
    ref.invalidate(missedAlarmProvider);
    ref.invalidate(nativeStatusProvider);
  }

  void _onNativeEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'ringing':
        // A snooze/nag re-ring of the same occurrence has a new started_ms and
        // replaces a stale screen.
        showRingingAlarm(RingingAlarm.fromMap(event));
      case 'launch':
        unawaited(_onLaunchEvent(AlarmLaunch.fromMap(event)));
      case 'stopped':
        // The ring screen closes itself (user reasons) or shows "stopped".
        unawaited(_afterStopped());
    }
  }

  Future<void> _afterStopped() async {
    await _guard(ref.read(alarmServiceProvider).ingestEvents);
    if (mounted) ref.invalidate(missedAlarmProvider);
  }

  Future<void> _onLaunchEvent(AlarmLaunch launch) async {
    // Native may also have stored this launch in the mailbox; take it so a
    // later resume or cold start does not replay it.
    final stored = await _guard(_bridge.getLaunchAction);
    if (!mounted) return;
    if (stored != null) await _handleLaunch(stored);
    await _handleLaunch(launch);
  }

  String? _lastStartKey;
  DateTime? _lastStartAt;

  /// The same 'start' launch can arrive twice (event + mailbox/resume).
  bool _isRepeatedStart(AlarmLaunch launch) {
    final key = '${launch.reminderId}:${launch.occurrenceMs}';
    final now = DateTime.now();
    final last = _lastStartAt;
    final repeated = key == _lastStartKey &&
        last != null &&
        now.difference(last).abs() < const Duration(minutes: 1);
    _lastStartKey = key;
    _lastStartAt = now;
    return repeated;
  }

  Future<void> _handleLaunch(AlarmLaunch launch) async {
    switch (launch.action) {
      case 'ring':
        // Nothing ringing (stale launch): just show the app.
        final ringing = await _guard(_bridge.getRinging);
        if (mounted) showRingingAlarm(ringing);
      case 'start':
        if (!mounted || _isRepeatedStart(launch)) return;
        // Native already stopped this ring; its stopped event may have been
        // missed, so never leave its ring screen under the recitation.
        closeAlarm(reminderId: launch.reminderId);
        openRecite(
          routineId: launch.routineId,
          fromAlarm: true,
          reminderId: launch.reminderId,
        );
      default:
        break; // 'open': just show the app.
    }
  }

  Future<void> _finishOnboarding() async {
    await ref
        .read(settingsProvider.notifier)
        .update((s) => s.copyWith(onboardingDone: true));
    await _guard(() => ref.read(alarmServiceProvider).sync('onboarding'));
    if (mounted) invalidateData(ref);
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(settingsProvider.select((s) => s.themeMode));
    final onboardingDone =
        ref.watch(settingsProvider.select((s) => s.onboardingDone));
    final Widget home;
    if (!_gateDone) {
      home = const _Splash();
    } else if (!onboardingDone) {
      home = OnboardingScreen(onDone: _finishOnboarding);
    } else {
      home = const RootShell();
    }
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: _light,
      darkTheme: _dark,
      themeMode: themeMode,
      home: home,
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
