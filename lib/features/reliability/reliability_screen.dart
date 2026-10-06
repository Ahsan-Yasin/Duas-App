import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/native/native_bridge.dart';
import '../../core/providers.dart';
import '../../core/theme.dart' show VerificationColors;
import '../../domain/schedule.dart' show formatCountdown;
import '../reminders/reminders_screen.dart' show runTestAlarm;

/// Phone-maker specific steps that keep alarms alive.
class _Vendor {
  const _Vendor(this.name, this.match, this.slug, this.steps);

  final String name;
  final List<String> match;

  /// dontkillmyapp.com page ('' = home page).
  final String slug;
  final List<String> steps;

  bool matches(String manufacturer) {
    final m = manufacturer.toLowerCase();
    return match.any(m.contains);
  }
}

const _vendors = <_Vendor>[
  _Vendor('Samsung', ['samsung'], 'samsung', [
    'Open Settings > Battery > Background usage limits.',
    "Add Daily Duas to 'Never sleeping apps'.",
    "Make sure it is not in 'Sleeping apps' or 'Deep sleeping apps'.",
    "Settings > Apps > Daily Duas > Battery: choose 'Unrestricted'.",
  ]),
  _Vendor('Xiaomi / Redmi / POCO', ['xiaomi', 'redmi', 'poco'], 'xiaomi', [
    'Settings > Apps > Manage apps > Daily Duas: turn Autostart ON.',
    "Battery saver: choose 'No restrictions'.",
    'Open recent apps, long-press Daily Duas and tap the lock icon so it is never cleared.',
  ]),
  _Vendor('Oppo / Realme', ['oppo', 'realme'], 'oppo', [
    "Settings > Apps > Daily Duas: turn on 'Allow auto-launch' (Auto startup).",
    "Battery usage: turn on 'Allow background activity'.",
    'Lock Daily Duas in recent apps so it is not cleared.',
  ]),
  _Vendor('Vivo / iQOO', ['vivo', 'iqoo'], 'vivo', [
    "Settings > Battery > Background power consumption management: set Daily Duas to 'Allow'.",
    'Settings > Apps > Autostart (or i Manager > App manager > Autostart): turn on Daily Duas.',
  ]),
  _Vendor('Huawei / Honor', ['huawei', 'honor'], 'huawei', [
    'Settings > Battery > App launch: find Daily Duas.',
    "Switch it to 'Manage manually'.",
    'Turn on all toggles: Auto-launch, Secondary launch and Run in background.',
  ]),
  _Vendor('OnePlus', ['oneplus'], 'oneplus', [
    "Settings > Battery > Battery optimization: set Daily Duas to 'Don't optimize'.",
    "Turn off 'Deep optimization' and 'Sleep standby optimization' (Battery > Advanced optimization).",
  ]),
];

const _dkmaPages = {
  'samsung', 'xiaomi', 'oneplus', 'huawei', 'oppo', 'vivo', 'realme', //
  'google', 'motorola', 'nokia', 'sony', 'asus',
};

/// dontkillmyapp.com page for a manufacturer (home page when unknown).
String dontKillMyAppUrl(String manufacturer) {
  var m = manufacturer.toLowerCase().trim();
  if (m.contains('redmi') || m.contains('poco')) m = 'xiaomi';
  if (m.contains('iqoo')) m = 'vivo';
  return _dkmaPages.contains(m)
      ? 'https://dontkillmyapp.com/$m'
      : 'https://dontkillmyapp.com/';
}

Future<void> _launch(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final ok =
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok) throw Exception('no browser');
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text('Could not open $url')));
  }
}

class ReliabilityScreen extends ConsumerStatefulWidget {
  const ReliabilityScreen({super.key});

  @override
  ConsumerState<ReliabilityScreen> createState() => _ReliabilityScreenState();
}

class _ReliabilityScreenState extends ConsumerState<ReliabilityScreen>
    with WidgetsBindingObserver {
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.invalidate(nativeStatusProvider);
      if (ref.read(alarmServiceProvider).lastSync == null) _refresh();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      ref.invalidate(nativeStatusProvider);
    }
  }

  Future<void> _refresh() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      await ref.read(alarmServiceProvider).sync('reliability');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not re-check alarms: $e')));
      }
    }
    if (!mounted) return;
    ref.invalidate(nativeStatusProvider);
    setState(() => _syncing = false);
  }

  Future<void> _openSettings(String page, {String? fallback}) async {
    final bridge = ref.read(nativeBridgeProvider);
    final messenger = ScaffoldMessenger.of(context);
    var ok = false;
    try {
      ok = await bridge.openSettings(page);
      if (!ok && fallback != null) ok = await bridge.openSettings(fallback);
    } catch (_) {
      ok = false;
    }
    if (!ok) {
      messenger.showSnackBar(const SnackBar(
          content: Text(
              'Could not open that page. Open Settings > Apps > Daily Duas instead.')));
    }
    if (mounted) ref.invalidate(nativeStatusProvider);
  }

  Future<void> _fixNotifications() async {
    final bridge = ref.read(nativeBridgeProvider);
    var granted = false;
    try {
      granted = await bridge.requestNotificationPermission();
    } catch (_) {
      granted = false;
    }
    if (!mounted) return;
    if (!granted) {
      await _openSettings('notifications', fallback: 'app_details');
    } else {
      ref.invalidate(nativeStatusProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusAsync = ref.watch(nativeStatusProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alarm reliability'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: _syncing
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            onPressed: _syncing ? null : _refresh,
          ),
        ],
      ),
      body: statusAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 8),
                Text('Could not read alarm status.\n$e',
                    textAlign: TextAlign.center),
                const SizedBox(height: 8),
                OutlinedButton(
                    onPressed: () => ref.invalidate(nativeStatusProvider),
                    child: const Text('Retry')),
              ],
            ),
          ),
        ),
        data: (s) => _content(context, s),
      ),
    );
  }

  Widget _content(BuildContext context, NativeStatus s) {
    final theme = Theme.of(context);
    final reminders = ref.watch(remindersProvider).value;
    final enabledCount = reminders?.where((r) => r.enabled).length;
    final sync = ref.read(alarmServiceProvider).lastSync;
    final now = ref.watch(nowProvider)();
    final fullScreenNeeded = s.sdkInt >= 34;

    final notifOk = s.notificationsEnabled;
    final exactOk = s.exactAlarmsAllowed;
    final fullOk = !fullScreenNeeded || s.fullScreenAllowed;
    final batteryOk = s.ignoringBatteryOptimizations;
    final allOk = notifOk && exactOk && fullOk && batteryOk;

    // Next alarm row.
    final next = s.nextAlarmMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(s.nextAlarmMs!);
    final syncOk = sync == null || sync.ok;
    final noReminders = enabledCount == 0;
    final unknown = enabledCount == null && next == null;
    final nextOk = noReminders || unknown || (next != null && syncOk);
    String nextTitle;
    String nextSubtitle;
    if (unknown) {
      nextTitle = 'Next alarm';
      nextSubtitle = 'Checking your reminders…';
    } else if (noReminders) {
      nextTitle = 'No reminders switched on';
      nextSubtitle = 'Turn on a reminder to schedule an alarm.';
    } else if (next == null) {
      nextTitle = 'No alarm is scheduled';
      nextSubtitle = 'Tap Fix to schedule your reminders again.';
    } else {
      final when = DateFormat('EEE d MMM, ').add_jm().format(next);
      nextTitle = 'Next alarm: $when';
      final countdown = next.isAfter(now)
          ? formatCountdown(next.difference(now))
          : 'due now';
      if (sync == null) {
        nextSubtitle = 'Rings $countdown.';
      } else if (sync.ok) {
        nextSubtitle =
            'Rings $countdown. All ${sync.expected} alarms are scheduled.';
      } else {
        nextSubtitle =
            'Rings $countdown, but only ${sync.scheduled} of ${sync.expected} alarms are scheduled.';
      }
    }

    final detected = _vendors.where((v) => v.matches(s.manufacturer));
    final vendor = detected.isEmpty ? null : detected.first;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        if (!s.isAndroid)
          const _InfoCard(
            icon: Icons.info_outline,
            text:
                'Alarm checks are only available on Android. Reminders ring on Android phones.',
          )
        else
          _SummaryCard(ok: allOk && nextOk),
        const SizedBox(height: 8),
        _CheckRow(
          ok: notifOk,
          title: 'Notifications allowed',
          detail: notifOk
              ? 'Alarm and "missed" notifications can be shown.'
              : 'Without notifications the alarm cannot show or ring reliably.',
          onFix: _fixNotifications,
        ),
        _CheckRow(
          ok: exactOk,
          title: 'Exact alarms allowed',
          detail: exactOk
              ? 'Alarms ring at the exact minute.'
              : 'Android may delay reminders by many minutes.',
          onFix: () => _openSettings('exact_alarm'),
        ),
        _CheckRow(
          ok: fullOk,
          title: 'Full-screen alerts allowed',
          detail: !fullScreenNeeded
              ? 'Not needed on this Android version.'
              : (fullOk
                  ? 'The alarm screen can open over the lock screen.'
                  : 'The alarm only shows as a notification, not over the lock screen.'),
          onFix: () => _openSettings('full_screen'),
        ),
        _CheckRow(
          ok: batteryOk,
          title: 'Battery optimization disabled',
          detail: batteryOk
              ? 'Android will not put Daily Duas to sleep.'
              : 'Battery saving can stop or delay alarms on some phones.',
          onFix: () =>
              _openSettings('battery_request', fallback: 'battery'),
        ),
        _CheckRow(
          ok: nextOk,
          neutral: noReminders || unknown,
          title: nextTitle,
          detail: nextSubtitle,
          onFix: _refresh,
          fixLabel: 'Re-schedule',
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () => runTestAlarm(context, ref),
          icon: const Icon(Icons.alarm_on),
          label: const Text('Run test alarm'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
        const SizedBox(height: 4),
        Text(
          'Rings in 10 seconds. Lock your phone to check the full-screen alarm.',
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        const _InfoCard(
          icon: Icons.info_outline,
          text:
              'If you force-stop the app from Android settings, Android cancels its alarms until you open the app again.',
        ),
        const SizedBox(height: 24),
        Text('Phone-specific settings', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          s.manufacturer.isEmpty
              ? 'Some phone makers stop background apps aggressively.'
              : 'Your phone: ${s.manufacturer} ${s.model}'
                  '${s.sdkInt > 0 ? ' · Android API ${s.sdkInt}' : ''}',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        for (final v in [
          ?vendor,
          ..._vendors.where((x) => x != vendor),
        ])
          _VendorTile(
            vendor: v,
            expanded: v == vendor,
            onOpenAppSettings: () => _openSettings('app_details'),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _launch(context, dontKillMyAppUrl(s.manufacturer)),
          icon: const Icon(Icons.open_in_new),
          label: const Text('More help at dontkillmyapp.com'),
          style:
              OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.ok});

  final bool ok;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = ok ? scheme.primaryContainer : scheme.errorContainer;
    final fg = ok ? scheme.onPrimaryContainer : scheme.onErrorContainer;
    return Card(
      color: bg,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(ok ? Icons.verified_outlined : Icons.warning_amber_rounded,
                color: fg, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                ok
                    ? 'All set — your reminders should ring on time.'
                    : 'Fix the red items below so your reminders ring on time.',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.ok,
    required this.title,
    required this.detail,
    required this.onFix,
    this.neutral = false,
    this.fixLabel = 'Fix',
  });

  final bool ok;
  final bool neutral;
  final String title;
  final String detail;
  final VoidCallback onFix;
  final String fixLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final good = ok || neutral;
    final color = neutral
        ? scheme.onSurfaceVariant
        : (ok
            ? VerificationColors.verifiedForeground(theme.brightness)
            : scheme.error);
    final icon = neutral
        ? Icons.remove_circle_outline
        : (ok ? Icons.check_circle : Icons.error);
    return Semantics(
      label: neutral ? null : (ok ? 'OK' : 'Needs attention'),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: Icon(icon, color: color, size: 28),
        title: Text(title),
        subtitle: Text(detail),
        trailing: good
            ? null
            : FilledButton.tonal(onPressed: onFix, child: Text(fixLabel)),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
  }
}

class _VendorTile extends StatelessWidget {
  const _VendorTile({
    required this.vendor,
    required this.expanded,
    required this.onOpenAppSettings,
  });

  final _Vendor vendor;
  final bool expanded;
  final VoidCallback onOpenAppSettings;

  @override
  Widget build(BuildContext context) {
    final url = vendor.slug.isEmpty
        ? 'https://dontkillmyapp.com/'
        : 'https://dontkillmyapp.com/${vendor.slug}';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: expanded,
        leading: Icon(expanded ? Icons.smartphone : Icons.phone_android),
        title: Text(vendor.name),
        subtitle: expanded ? const Text('Matches your phone') : null,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < vendor.steps.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 24, child: Text('${i + 1}.')),
                  Expanded(child: Text(vendor.steps[i])),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton(
                onPressed: onOpenAppSettings,
                child: const Text('Open app settings'),
              ),
              TextButton.icon(
                onPressed: () => _launch(context, url),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Guide with pictures'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
