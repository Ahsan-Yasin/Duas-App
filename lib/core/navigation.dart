import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/alarm/alarm_ring_screen.dart';
import '../features/recite/recite_screen.dart';
import 'native/native_bridge.dart';

/// Root navigator used by every screen and by alarm routing.
final navigatorKey = GlobalKey<NavigatorState>();

/// Pushes [screen] on the root navigator. Resolves to null when the navigator
/// is not mounted yet.
Future<T?> pushScreen<T>(Widget screen, {bool fullscreenDialog = false}) {
  final nav = navigatorKey.currentState;
  if (nav == null) return Future<T?>.value();
  return nav.push<T>(
    MaterialPageRoute<T>(
      builder: (_) => screen,
      fullscreenDialog: fullscreenDialog,
    ),
  );
}

/// Opens the guided recitation screen.
void openRecite({
  required int? routineId,
  bool fromAlarm = false,
  int? reminderId,
  int? resumeLogId,
}) {
  pushScreen<void>(
    ReciteScreen(
      routineId: routineId,
      fromAlarm: fromAlarm,
      reminderId: reminderId,
      resumeLogId: resumeLogId,
    ),
  );
}

Route<void>? _alarmRoute;
RingingAlarm? _shownAlarm;

/// The alarm currently shown by [openAlarm], or null when no alarm screen is
/// on the stack.
RingingAlarm? get shownAlarm =>
    (_alarmRoute != null && _alarmRoute!.isActive) ? _shownAlarm : null;

/// True when an alarm screen for the same ring as [alarm] (or any alarm when
/// [alarm] is null) is already on the stack. A snooze or nag re-ring keeps the
/// occurrence but has a new startedMs, so it counts as a different ring and
/// [openAlarm] replaces the stale screen.
bool isShowingAlarm([RingingAlarm? alarm]) {
  final shown = shownAlarm;
  if (shown == null) return false;
  if (alarm == null) return true;
  return shown.reminderId == alarm.reminderId &&
      shown.occurrenceMs == alarm.occurrenceMs &&
      shown.startedMs == alarm.startedMs;
}

/// Opens the alarm screen for [alarm] unless that ring is already shown.
void showRingingAlarm(RingingAlarm? alarm) {
  if (alarm != null && !isShowingAlarm(alarm)) openAlarm(alarm);
}

/// Removes the alarm screen wherever it is in the stack (it may sit below
/// another route). With [reminderId], only when it shows that reminder.
void closeAlarm({int? reminderId}) {
  final route = _alarmRoute;
  final nav = navigatorKey.currentState;
  if (nav == null || route == null || !route.isActive) return;
  if (reminderId != null && _shownAlarm?.reminderId != reminderId) return;
  if (route.isFirst && route.isCurrent) return; // never empty the navigator
  nav.removeRoute(route);
  _alarmRoute = null;
  _shownAlarm = null;
}

/// Shows the full-screen alarm. Replaces an alarm screen that is already on
/// the stack (with fresh state) instead of stacking a second one.
void openAlarm(RingingAlarm alarm) {
  final nav = navigatorKey.currentState;
  if (nav == null) return;
  final route = MaterialPageRoute<void>(
    builder: (_) => AlarmRingScreen(alarm: alarm),
    fullscreenDialog: true,
    settings: const RouteSettings(name: '/alarm'),
  );
  final existing = _alarmRoute;
  _alarmRoute = route;
  _shownAlarm = alarm;
  route.popped.whenComplete(() {
    if (identical(_alarmRoute, route)) {
      _alarmRoute = null;
      _shownAlarm = null;
    }
  });
  if (existing != null && existing.isActive) {
    nav.replace<void>(oldRoute: existing, newRoute: route);
  } else {
    nav.push<void>(route);
  }
}

/// Tabs of the bottom navigation bar in [RootShell] order.
enum ShellTab { home, library, routines, reminders, more }

/// Currently selected bottom navigation tab (index into [ShellTab]).
final shellTabProvider =
    NotifierProvider<ShellTabNotifier, int>(ShellTabNotifier.new);

class ShellTabNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void select(ShellTab tab) => state = tab.index;

  void selectIndex(int index) => state = index;
}

/// Switches the bottom navigation to [tab] and pops any pushed screens so the
/// tab is visible.
void goToTab(WidgetRef ref, ShellTab tab) {
  ref.read(shellTabProvider.notifier).select(tab);
  navigatorKey.currentState?.popUntil((r) => r.isFirst);
}
