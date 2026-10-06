import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/native/native_bridge.dart';
import '../../core/navigation.dart';
import '../../core/providers.dart';
import '../reliability/reliability_screen.dart';
import '../reminders/reminder_editor_screen.dart';

/// First-run walkthrough. Each page explains why a permission matters
/// before asking for it.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen>
    with WidgetsBindingObserver {
  static const _pageCount = 5;
  final _controller = PageController();
  int _index = 0;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from a system settings page: re-read permission state.
    if (state == AppLifecycleState.resumed && mounted) {
      ref.invalidate(nativeStatusProvider);
    }
  }

  void _go(int page) {
    _controller.animateToPage(page,
        duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  void _finish({bool openReminder = false}) {
    if (_finished) return;
    _finished = true;
    // State updates synchronously; persisting happens in the background.
    ref
        .read(settingsProvider.notifier)
        .update((s) => s.copyWith(onboardingDone: true))
        .catchError((Object _) {});
    widget.onDone();
    if (openReminder) {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => pushScreen<void>(const ReminderEditorScreen()));
    }
  }

  Future<void> _requestNotifications() async {
    final bridge = ref.read(nativeBridgeProvider);
    try {
      final granted = await bridge.requestNotificationPermission();
      if (!granted) await bridge.openSettings('notifications');
    } catch (_) {
      // Status row below shows the result either way.
    }
    if (mounted) ref.invalidate(nativeStatusProvider);
  }

  Future<void> _openSettings(String page) async {
    try {
      final ok = await ref.read(nativeBridgeProvider).openSettings(page);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Could not open that page. You can fix this later in Alarm reliability.')));
      }
    } catch (_) {
      // Ignore; the user can fix it later from Alarm reliability.
    }
    if (mounted) ref.invalidate(nativeStatusProvider);
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(nativeStatusProvider).value;
    final isLast = _index == _pageCount - 1;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: isLast
                    ? const SizedBox(height: 48)
                    : TextButton(
                        onPressed: _finish,
                        child: const Text('Skip'),
                      ),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (i) => setState(() => _index = i),
                children: [
                  const _Page(
                    icon: Icons.menu_book_rounded,
                    title: 'Assalamu alaikum',
                    body:
                        'Daily Duas helps you keep up your daily duas and adhkar.',
                    bullets: [
                      'A guided counter for every dua',
                      'Alarm reminders that ring like a clock alarm',
                      'Quran recitation audio to listen and follow along',
                      'Works offline — your data stays on your phone',
                    ],
                  ),
                  _Page(
                    icon: Icons.notifications_active_outlined,
                    title: 'Allow notifications',
                    body:
                        'Your reminders ring as an alarm with a notification, so you can start reciting, snooze or dismiss — even when the phone is locked. Android will ask you to allow notifications.',
                    actions: [
                      if (status != null && status.notificationsEnabled)
                        const _Done('Notifications are allowed')
                      else
                        FilledButton.icon(
                          onPressed: _requestNotifications,
                          icon: const Icon(Icons.notifications_outlined),
                          label: const Text('Allow notifications'),
                        ),
                    ],
                  ),
                  _Page(
                    icon: Icons.alarm_on_outlined,
                    title: 'Ring on time, over the lock screen',
                    body:
                        'Android may delay ordinary reminders by many minutes. Exact alarms make reminders ring at the exact minute, and full-screen alerts let the alarm appear over the lock screen like a clock alarm.',
                    actions: _alarmActions(status),
                  ),
                  _Page(
                    icon: Icons.battery_charging_full_outlined,
                    title: 'Keep alarms alive',
                    body:
                        'Some phones stop apps in the background to save battery, which can silence alarms. Letting Daily Duas run without battery restrictions keeps reminders reliable. It only wakes up when an alarm is due.',
                    actions: [
                      if (status != null && status.ignoringBatteryOptimizations)
                        const _Done('No battery restrictions')
                      else
                        FilledButton.icon(
                          onPressed: () => _openSettings('battery_request'),
                          icon: const Icon(Icons.battery_saver_outlined),
                          label: const Text('Allow background use'),
                        ),
                      TextButton(
                        onPressed: () =>
                            pushScreen<void>(const ReliabilityScreen()),
                        child: const Text('Tips for my phone'),
                      ),
                    ],
                  ),
                  _Page(
                    icon: Icons.check_circle_outline,
                    title: "You're ready",
                    body:
                        'Set a reminder for your morning or evening adhkar. You can change everything later in Settings.',
                    actions: [
                      FilledButton.icon(
                        onPressed: () => _finish(openReminder: true),
                        icon: const Icon(Icons.add_alarm),
                        label: const Text('Set your first reminder'),
                      ),
                      TextButton(
                        onPressed: _finish,
                        child: const Text('Explore the app first'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 96,
                    child: _index == 0
                        ? null
                        : TextButton(
                            onPressed: () => _go(_index - 1),
                            child: const Text('Back'),
                          ),
                  ),
                  Expanded(child: _Dots(index: _index, count: _pageCount)),
                  SizedBox(
                    width: 96,
                    child: isLast
                        ? null
                        : FilledButton(
                            onPressed: () => _go(_index + 1),
                            child: const Text('Next'),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _alarmActions(NativeStatus? status) {
    final exactOk = status != null && status.exactAlarmsAllowed;
    final fullNeeded = status == null || status.sdkInt >= 34;
    final fullOk = status != null && (!fullNeeded || status.fullScreenAllowed);
    return [
      if (exactOk)
        const _Done('Exact alarms are allowed')
      else
        FilledButton.icon(
          onPressed: () => _openSettings('exact_alarm'),
          icon: const Icon(Icons.alarm),
          label: const Text('Allow exact alarms'),
        ),
      if (fullOk)
        const _Done('Full-screen alerts are allowed')
      else
        FilledButton.tonalIcon(
          onPressed: () => _openSettings('full_screen'),
          icon: const Icon(Icons.fullscreen),
          label: const Text('Allow full-screen alerts'),
        ),
    ];
  }
}

class _Page extends StatelessWidget {
  const _Page({
    required this.icon,
    required this.title,
    required this.body,
    this.bullets = const [],
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String body;
  final List<String> bullets;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(icon, size: 80, color: theme.colorScheme.primary),
          const SizedBox(height: 24),
          Semantics(
            header: true,
            child: Text(title,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 12),
          Text(body,
              textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
          if (bullets.isNotEmpty) ...[
            const SizedBox(height: 16),
            for (final b in bullets)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.check, size: 20, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(child: Text(b, style: theme.textTheme.bodyLarge)),
                  ],
                ),
              ),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 24),
            for (final a in actions)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: a,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// A "granted" row shown instead of a permission button.
class _Done extends StatelessWidget {
  const _Done(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.check_circle, color: scheme.primary),
        const SizedBox(width: 8),
        Flexible(child: Text(text, style: TextStyle(color: scheme.primary))),
      ],
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.index, required this.count});

  final int index;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Page ${index + 1} of $count',
      excludeSemantics: true,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == index ? 20 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: i == index ? scheme.primary : scheme.outlineVariant,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
        ],
      ),
    );
  }
}
