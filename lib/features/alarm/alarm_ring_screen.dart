import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/native/native_bridge.dart';
import '../../core/providers.dart';
import '../recite/recite_screen.dart';

/// Full-screen "alarm is ringing" page with Start reciting / Snooze / Dismiss.
class AlarmRingScreen extends ConsumerStatefulWidget {
  const AlarmRingScreen({super.key, required this.alarm});

  final RingingAlarm alarm;

  @override
  ConsumerState<AlarmRingScreen> createState() => _AlarmRingScreenState();
}

class _AlarmRingScreenState extends ConsumerState<AlarmRingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  late final NativeBridge _bridge;
  StreamSubscription<Map<String, dynamic>>? _eventsSub;
  Timer? _clock;
  DateTime _now = DateTime.now();
  bool _stopped = false;
  bool _busy = false;

  /// The engine refused a snooze (cap reached) although this screen offered one.
  bool _snoozeRefused = false;
  String? _routineName;
  int? _snoozeMinutes;

  RingingAlarm get _alarm => widget.alarm;

  int get _snoozesLeft {
    if (_snoozeRefused) return 0;
    final left = _alarm.maxSnoozes - _alarm.snoozesUsed;
    return left < 0 ? 0 : left;
  }

  @override
  void initState() {
    super.initState();
    _bridge = ref.read(nativeBridgeProvider);
    _now = ref.read(nowProvider)();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      lowerBound: 0,
      upperBound: 1,
    );
    _clock = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() => _now = ref.read(nowProvider)());
    });
    try {
      _eventsSub = _bridge.events.listen(_onEvent, onError: (Object e) {
        debugPrint('Alarm events error: $e');
      });
    } catch (e) {
      debugPrint('Alarm events unavailable: $e');
    }
    _loadDetails();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    if (reduceMotion || _stopped) {
      _pulse.stop();
      _pulse.value = 0;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    _clock?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _loadDetails() async {
    final settings = ref.read(settingsProvider);
    String? routineName;
    int? snooze;
    try {
      final routineId = _alarm.routineId;
      if (routineId != null) {
        routineName = (await ref.read(routineRepoProvider).get(routineId))?.name;
      }
      if (_alarm.reminderId >= 0) {
        if (!mounted) return;
        snooze =
            (await ref.read(reminderRepoProvider).get(_alarm.reminderId))
                ?.snoozeMinutes;
      }
    } catch (e) {
      debugPrint('Alarm details failed to load: $e');
    }
    if (!mounted) return;
    setState(() {
      _routineName = routineName;
      _snoozeMinutes = snooze ?? settings.defaultSnoozeMinutes;
    });
  }

  void _onEvent(Map<String, dynamic> event) {
    // While busy, this screen caused the stop and navigates by itself.
    if (!mounted || _busy || event['type'] != 'stopped') return;
    final id = event['reminder_id'];
    if (id is num && id.toInt() != _alarm.reminderId) return;
    final occurrence = event['occurrence_ms'];
    if (occurrence is num && occurrence.toInt() != _alarm.occurrenceMs) return;
    // Started, snoozed or dismissed elsewhere (notification actions): the
    // ring is answered, so close instead of leaving a stale screen whose
    // buttons would act on it again.
    const userReasons = {'started', 'dismissed', 'snoozed', 'start', 'dismiss', 'snooze'};
    if (userReasons.contains(event['reason'])) {
      _leave();
      return;
    }
    setState(() => _stopped = true);
    _pulse.stop();
    _pulse.value = 0;
  }

  /// Returns the snoozes left, or null when the call failed.
  Future<int?> _action(String action) async {
    try {
      return await _bridge.alarmAction(
          action, _alarm.reminderId, _alarm.occurrenceMs);
    } catch (e) {
      debugPrint('alarmAction($action) failed: $e');
      return null;
    }
  }

  /// This screen's route while it is still in the navigator (it can be
  /// replaced by another alarm or removed while an action is in flight).
  Route<dynamic>? get _activeRoute {
    final route = ModalRoute.of(context);
    return route != null && route.isActive ? route : null;
  }

  Future<void> _start() async {
    if (_busy) return;
    setState(() => _busy = true);
    await _action('start');
    if (!mounted) return;
    final route = _activeRoute;
    if (route == null) return;
    final routineId =
        _alarm.routineId ?? ref.read(settingsProvider).defaultRoutineId;
    final recite = MaterialPageRoute<void>(
      builder: (_) => ReciteScreen(
        routineId: routineId,
        fromAlarm: true,
        reminderId: _alarm.reminderId,
      ),
    );
    final nav = Navigator.of(context);
    if (route.isCurrent) {
      nav.pushReplacement(recite);
    } else {
      nav.replace(oldRoute: route, newRoute: recite);
    }
  }

  Future<void> _snooze() async {
    if (_busy) return;
    setState(() => _busy = true);
    final left = await _action('snooze');
    if (!mounted) return;
    if (left == null) {
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not snooze. Try again.')),
      );
      return;
    }
    // The engine refuses silently once the cap is reached (the ring goes on),
    // so check the ring instead of trusting a missing exception.
    var refused = left < 0;
    if (!refused) {
      try {
        final still = await _bridge.getRinging();
        refused = still != null &&
            still.reminderId == _alarm.reminderId &&
            still.occurrenceMs == _alarm.occurrenceMs;
      } catch (e) {
        debugPrint('getRinging after snooze failed: $e');
      }
      if (!mounted) return;
    }
    if (refused) {
      setState(() {
        _busy = false;
        _snoozeRefused = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No snoozes left')),
      );
      return;
    }
    _leave();
  }

  Future<void> _dismiss() async {
    if (_busy) return;
    setState(() => _busy = true);
    await _action('dismiss');
    if (!mounted) return;
    _leave();
  }

  /// Closes this alarm screen, even when another route sits above it; when it
  /// is the only route (launch screen), closes the app.
  void _leave() {
    final route = _activeRoute;
    if (route == null) return;
    final nav = Navigator.of(context);
    if (!route.isCurrent) {
      nav.removeRoute(route);
    } else if (nav.canPop()) {
      nav.pop();
    } else {
      SystemNavigator.pop().catchError(
        (Object e) => debugPrint('SystemNavigator.pop failed: $e'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final time = DateFormat.Hm().format(_now);
    final snoozeMin = _snoozeMinutes ??
        ref.watch(settingsProvider.select((s) => s.defaultSnoozeMinutes));
    final canSnooze = _snoozesLeft > 0;
    final label = _alarm.label.trim().isEmpty ? 'Dua reminder' : _alarm.label;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 48,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 16),
                        Center(child: _PulsingIcon(animation: _pulse)),
                        const SizedBox(height: 24),
                        Semantics(
                          label: 'Time $time',
                          excludeSemantics: true,
                          child: Text(
                            time,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.displayLarge?.copyWith(
                              fontWeight: FontWeight.w300,
                              color: scheme.onSurface,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Semantics(
                          header: true,
                          child: Text(
                            label,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineSmall,
                          ),
                        ),
                        if (_routineName != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            _routineName!,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                        if (_stopped) ...[
                          const SizedBox(height: 20),
                          Semantics(
                            liveRegion: true,
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: scheme.secondaryContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                'Alarm stopped — start when you are ready',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  color: scheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 32),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FilledButton.icon(
                            onPressed: _busy ? null : _start,
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(64),
                              textStyle: theme.textTheme.titleMedium,
                            ),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('Start reciting'),
                          ),
                          const SizedBox(height: 12),
                          if (canSnooze)
                            FilledButton.tonalIcon(
                              onPressed: _busy ? null : _snooze,
                              style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(56),
                              ),
                              icon: const Icon(Icons.snooze_rounded),
                              label: Text(
                                'Snooze $snoozeMin min ($_snoozesLeft left)',
                                textAlign: TextAlign.center,
                              ),
                            )
                          else
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Text(
                                'No snoozes left',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _dismiss,
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(56),
                            ),
                            icon: const Icon(Icons.close_rounded),
                            label: const Text('Dismiss'),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Dismiss skips today’s reminder.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PulsingIcon extends StatelessWidget {
  const _PulsingIcon({required this.animation});

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          final t = Curves.easeInOut.transform(animation.value);
          return Container(
            width: 128,
            height: 128,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primaryContainer,
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.25 * (1 - t)),
                  blurRadius: 8 + 28 * t,
                  spreadRadius: 4 + 14 * t,
                ),
              ],
            ),
            child: Transform.scale(scale: 1 + 0.08 * t, child: child),
          );
        },
        child: Icon(Icons.alarm_rounded, size: 64, color: scheme.primary),
      ),
    );
  }
}
