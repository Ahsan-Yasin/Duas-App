// Dart side of the Kotlin alarm engine (ARCHITECTURE.md section 7).
//
// MethodChannel 'daily_duas/native' + EventChannel 'daily_duas/native_events'.
// All maps use the snake_case keys of the contract. MethodChannelNativeBridge
// falls back to an in-memory FakeNativeBridge on non-Android platforms (and when
// the native side is missing there), so desktop runs and widget tests never
// crash. On Android it never falls back: an engine started headless by
// audio_service has no handlers until MainActivity attaches, so a
// MissingPluginException is rethrown and later calls retry the real channel.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';

int _int(Object? v, [int fallback = 0]) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

int? _intOrNull(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

bool _bool(Object? v, [bool fallback = false]) => v is bool ? v : fallback;

String _str(Object? v, [String fallback = '']) => v == null ? fallback : '$v';

/// Converts platform-channel maps (`Map<Object?, Object?>`) to `Map<String, dynamic>`.
Map<String, dynamic> nativeMap(Object? raw) {
  if (raw is! Map) return <String, dynamic>{};
  return raw.map((k, v) => MapEntry('$k', _deep(v)));
}

Object? _deep(Object? v) {
  if (v is Map) return nativeMap(v);
  if (v is List) return v.map(_deep).toList();
  return v;
}

/// One alarm known to AlarmManager. [weekday] is 0 for snooze/nag/test.
class ScheduledAlarm {
  const ScheduledAlarm({
    required this.reminderId,
    required this.weekday,
    required this.kind,
    required this.triggerAtMs,
    required this.exists,
  });

  factory ScheduledAlarm.fromMap(Map<String, dynamic> m) => ScheduledAlarm(
        reminderId: _int(m['reminder_id']),
        weekday: _int(m['weekday']),
        kind: _str(m['kind'], 'main'),
        triggerAtMs: _int(m['trigger_at_ms']),
        exists: _bool(m['exists']),
      );

  final int reminderId;
  final int weekday;

  /// main | snooze | nag | test
  final String kind;
  final int triggerAtMs;

  /// The PendingIntent is still registered with AlarmManager.
  final bool exists;

  Map<String, dynamic> toMap() => {
        'reminder_id': reminderId,
        'weekday': weekday,
        'kind': kind,
        'trigger_at_ms': triggerAtMs,
        'exists': exists,
      };

  @override
  String toString() => 'ScheduledAlarm(${toMap()})';
}

/// The alarm that is ringing right now.
class RingingAlarm {
  const RingingAlarm({
    required this.reminderId,
    required this.occurrenceMs,
    this.routineId,
    required this.label,
    required this.kind,
    required this.snoozesUsed,
    required this.maxSnoozes,
    required this.startedMs,
  });

  factory RingingAlarm.fromMap(Map<String, dynamic> m) => RingingAlarm(
        reminderId: _int(m['reminder_id']),
        occurrenceMs: _int(m['occurrence_ms']),
        routineId: _intOrNull(m['routine_id']),
        label: _str(m['label']),
        kind: _str(m['kind'], 'main'),
        snoozesUsed: _int(m['snoozes_used']),
        maxSnoozes: _int(m['max_snoozes']),
        startedMs: _int(m['started_ms']),
      );

  /// -1 for the test alarm.
  final int reminderId;
  final int occurrenceMs;
  final int? routineId;
  final String label;

  /// main | snooze | nag | test
  final String kind;
  final int snoozesUsed;
  final int maxSnoozes;
  final int startedMs;

  int get snoozesLeft => (maxSnoozes - snoozesUsed).clamp(0, 1 << 20);
  bool get isTest => reminderId < 0;

  Map<String, dynamic> toMap() => {
        'reminder_id': reminderId,
        'occurrence_ms': occurrenceMs,
        'routine_id': routineId,
        'label': label,
        'kind': kind,
        'snoozes_used': snoozesUsed,
        'max_snoozes': maxSnoozes,
        'started_ms': startedMs,
      };

  @override
  String toString() => 'RingingAlarm(${toMap()})';
}

/// Why the activity was launched from an alarm notification.
class AlarmLaunch {
  const AlarmLaunch({
    required this.action,
    required this.reminderId,
    required this.occurrenceMs,
    this.routineId,
    required this.label,
    required this.kind,
  });

  factory AlarmLaunch.fromMap(Map<String, dynamic> m) => AlarmLaunch(
        action: _str(m['action'], 'open'),
        reminderId: _int(m['reminder_id']),
        occurrenceMs: _int(m['occurrence_ms']),
        routineId: _intOrNull(m['routine_id']),
        label: _str(m['label']),
        kind: _str(m['kind'], 'main'),
      );

  /// ring | start | open
  final String action;
  final int reminderId;
  final int occurrenceMs;
  final int? routineId;
  final String label;
  final String kind;

  Map<String, dynamic> toMap() => {
        'action': action,
        'reminder_id': reminderId,
        'occurrence_ms': occurrenceMs,
        'routine_id': routineId,
        'label': label,
        'kind': kind,
      };

  @override
  String toString() => 'AlarmLaunch(${toMap()})';
}

/// Alarm reliability status of the device.
class NativeStatus {
  const NativeStatus({
    required this.notificationsEnabled,
    required this.exactAlarmsAllowed,
    required this.fullScreenAllowed,
    required this.ignoringBatteryOptimizations,
    this.nextAlarmMs,
    required this.manufacturer,
    required this.model,
    required this.timezone,
    required this.sdkInt,
    required this.isAndroid,
  });

  factory NativeStatus.fromMap(Map<String, dynamic> m) => NativeStatus(
        notificationsEnabled: _bool(m['notifications_enabled']),
        exactAlarmsAllowed: _bool(m['exact_alarms_allowed']),
        fullScreenAllowed: _bool(m['full_screen_allowed']),
        ignoringBatteryOptimizations: _bool(m['ignoring_battery_optimizations']),
        nextAlarmMs: _intOrNull(m['next_alarm_ms']),
        manufacturer: _str(m['manufacturer']),
        model: _str(m['model']),
        timezone: _str(m['timezone'], 'UTC'),
        sdkInt: _int(m['sdk_int']),
        isAndroid: _bool(m['is_android']),
      );

  final bool notificationsEnabled;
  final bool exactAlarmsAllowed;
  final bool fullScreenAllowed;
  final bool ignoringBatteryOptimizations;
  final int? nextAlarmMs;
  final String manufacturer;
  final String model;
  final String timezone;
  final int sdkInt;
  final bool isAndroid;

  Map<String, dynamic> toMap() => {
        'notifications_enabled': notificationsEnabled,
        'exact_alarms_allowed': exactAlarmsAllowed,
        'full_screen_allowed': fullScreenAllowed,
        'ignoring_battery_optimizations': ignoringBatteryOptimizations,
        'next_alarm_ms': nextAlarmMs,
        'manufacturer': manufacturer,
        'model': model,
        'timezone': timezone,
        'sdk_int': sdkInt,
        'is_android': isAndroid,
      };
}

AlarmEvent alarmEventFromNative(Map<String, dynamic> m) => AlarmEvent(
      reminderId: _int(m['reminder_id']),
      occurrenceMs: _int(m['occurrence_ms']),
      event: _str(m['event']),
      atMs: _int(m['at_ms']),
      label: _str(m['label']),
    );

abstract class NativeBridge {
  /// Full desired state (`Reminder.toNativeJson` dicts). Returns what is scheduled afterwards.
  Future<List<ScheduledAlarm>> syncReminders(List<Map<String, dynamic>> reminders);
  Future<List<ScheduledAlarm>> getScheduled();

  /// Arms a real alarm (reminder id -1) in [seconds]; returns its trigger time (epoch ms).
  Future<int> scheduleTest({int seconds = 10, required String label, int? routineId});

  /// Pending launch action; consumed on read.
  Future<AlarmLaunch?> getLaunchAction();
  Future<RingingAlarm?> getRinging();

  /// [action]: start | snooze | dismiss | stop. Returns the snoozes left.
  Future<int> alarmAction(String action, int reminderId, int occurrenceMs);
  Future<List<AlarmEvent>> getEvents(int sinceMs);
  Future<NativeStatus> getStatus();
  Future<bool> requestNotificationPermission();

  /// [page]: exact_alarm | full_screen | battery | battery_request | notifications | app_details
  Future<bool> openSettings(String page);
  Future<String> getTimezone();

  /// {"type":"ringing",...RingingAlarm} | {"type":"stopped","reminder_id","occurrence_ms","reason"} | {"type":"launch",...AlarmLaunch}
  ///
  /// 'ringing' is sent for every ring, including snooze/nag re-rings of the
  /// same occurrence (new started_ms). 'stopped' is sent whenever a ring ends;
  /// reason: auto_stopped | snoozed | dismissed | started | stopped | replaced.
  ///
  /// A long-lived broadcast stream: subscriptions survive [reattachEvents].
  Stream<Map<String, dynamic>> get events;

  /// Re-sends 'listen' to the native side when an earlier one may have been
  /// lost (the channel was missing, e.g. a headless engine start). Call on
  /// app resume; a no-op when the subscription is known to be live.
  void reattachEvents();
}

class MethodChannelNativeBridge implements NativeBridge {
  MethodChannelNativeBridge({
    MethodChannel? channel,
    EventChannel? eventChannel,
    NativeBridge? fallback,
    bool? useNative,
    bool? isAndroid,
  })  : _channel = channel ?? const MethodChannel('daily_duas/native'),
        _eventChannel = eventChannel ?? const EventChannel('daily_duas/native_events'),
        _fallback = fallback ?? FakeNativeBridge(),
        _isAndroid = isAndroid ?? _platformIsAndroid,
        _useNative = useNative ?? isAndroid ?? _platformIsAndroid;

  static bool get _platformIsAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  final MethodChannel _channel;
  final EventChannel _eventChannel;
  final NativeBridge _fallback;

  /// The Kotlin side ships with the app: a missing handler is temporary.
  final bool _isAndroid;
  bool _useNative;

  final StreamController<Map<String, dynamic>> _eventsOut = StreamController.broadcast();
  StreamSubscription<dynamic>? _nativeSub;

  /// A MissingPluginException was seen, so a 'listen' sent meanwhile may have
  /// gone nowhere; [reattachEvents] re-sends it.
  bool _eventsMayBeDetached = false;

  Future<T> _invoke<T>(
    String method,
    Map<String, dynamic>? args,
    T Function(Object? raw) parse,
    Future<T> Function(NativeBridge fallback) fallback,
  ) async {
    if (!_useNative) return fallback(_fallback);
    try {
      return parse(await _channel.invokeMethod<Object?>(method, args));
    } on MissingPluginException {
      if (_isAndroid) {
        // Headless engine (audio_service) before MainActivity registered the
        // handlers: never latch to the fake; callers guard and retry later.
        _eventsMayBeDetached = true;
        rethrow;
      }
      _useNative = false;
      return fallback(_fallback);
    }
  }

  static List<ScheduledAlarm> _scheduledList(Object? raw) => raw is List
      ? raw.map((e) => ScheduledAlarm.fromMap(nativeMap(e))).toList()
      : const <ScheduledAlarm>[];

  @override
  Future<List<ScheduledAlarm>> syncReminders(List<Map<String, dynamic>> reminders) => _invoke(
        'sync_reminders',
        {'reminders': reminders},
        _scheduledList,
        (f) => f.syncReminders(reminders),
      );

  @override
  Future<List<ScheduledAlarm>> getScheduled() =>
      _invoke('get_scheduled', null, _scheduledList, (f) => f.getScheduled());

  @override
  Future<int> scheduleTest({int seconds = 10, required String label, int? routineId}) => _invoke(
        'schedule_test',
        {'seconds': seconds, 'label': label, 'routine_id': routineId},
        (raw) => _int(raw),
        (f) => f.scheduleTest(seconds: seconds, label: label, routineId: routineId),
      );

  @override
  Future<AlarmLaunch?> getLaunchAction() => _invoke(
        'get_launch_action',
        null,
        (raw) => raw is Map ? AlarmLaunch.fromMap(nativeMap(raw)) : null,
        (f) => f.getLaunchAction(),
      );

  @override
  Future<RingingAlarm?> getRinging() => _invoke(
        'get_ringing',
        null,
        (raw) => raw is Map ? RingingAlarm.fromMap(nativeMap(raw)) : null,
        (f) => f.getRinging(),
      );

  @override
  Future<int> alarmAction(String action, int reminderId, int occurrenceMs) => _invoke(
        'alarm_action',
        {'action': action, 'reminder_id': reminderId, 'occurrence_ms': occurrenceMs},
        (raw) => _int(raw),
        (f) => f.alarmAction(action, reminderId, occurrenceMs),
      );

  @override
  Future<List<AlarmEvent>> getEvents(int sinceMs) => _invoke(
        'get_events',
        {'since_ms': sinceMs},
        (raw) => raw is List
            ? raw.map((e) => alarmEventFromNative(nativeMap(e))).toList()
            : const <AlarmEvent>[],
        (f) => f.getEvents(sinceMs),
      );

  @override
  Future<NativeStatus> getStatus() => _invoke(
        'get_status',
        null,
        (raw) => NativeStatus.fromMap(nativeMap(raw)),
        (f) => f.getStatus(),
      );

  @override
  Future<bool> requestNotificationPermission() => _invoke(
        'request_notification_permission',
        null,
        (raw) => _bool(raw),
        (f) => f.requestNotificationPermission(),
      );

  @override
  Future<bool> openSettings(String page) => _invoke(
        'open_settings',
        {'page': page},
        (raw) => _bool(raw),
        (f) => f.openSettings(page),
      );

  @override
  Future<String> getTimezone() => _invoke(
        'get_timezone',
        null,
        (raw) => _str(raw, 'UTC'),
        (f) => f.getTimezone(),
      );

  @override
  Stream<Map<String, dynamic>> get events {
    if (!_useNative) return _fallback.events;
    _nativeSub ??= _listenNative();
    return _eventsOut.stream;
  }

  @override
  void reattachEvents() {
    if (!_useNative || _nativeSub == null || !_eventsMayBeDetached) return;
    _eventsMayBeDetached = false;
    // Cancel first: its 'cancel' reaches Kotlin before the new 'listen', so the
    // native sink ends up on the new subscription. Listeners of [events] keep
    // their subscriptions (they are on [_eventsOut]).
    unawaited(_nativeSub!.cancel());
    _nativeSub = _listenNative();
  }

  StreamSubscription<dynamic> _listenNative() => _eventChannel.receiveBroadcastStream().listen(
        (raw) => _eventsOut.add(nativeMap(raw)),
        onError: (Object e) {
          if (e is MissingPluginException) {
            _eventsMayBeDetached = true;
            debugPrint('Native events unavailable: $e');
          } else {
            _eventsOut.addError(e);
          }
        },
      );
}

/// In-memory bridge for tests and non-Android platforms. Scheduling uses local
/// [DateTime] (no DST subtleties); [scheduleTest] emits a fake ringing event.
class FakeNativeBridge implements NativeBridge {
  FakeNativeBridge({DateTime Function()? now, NativeStatus? status})
      : _now = now ?? DateTime.now,
        status = status ??
            const NativeStatus(
              notificationsEnabled: true,
              exactAlarmsAllowed: true,
              fullScreenAllowed: true,
              ignoringBatteryOptimizations: true,
              manufacturer: '',
              model: '',
              timezone: 'UTC',
              sdkInt: 0,
              isAndroid: false,
            );

  final DateTime Function() _now;
  NativeStatus status;
  String timezone = 'UTC';

  /// Last reminder dicts passed to [syncReminders].
  List<Map<String, dynamic>> reminders = [];

  /// Event log returned by [getEvents]; tests may add to it.
  final List<AlarmEvent> eventLog = [];

  /// Simulates the OS losing alarms: [getScheduled] reports these reminders' main alarms as missing.
  final Set<int> missingReminderIds = {};

  /// When true, the second and later [syncReminders] calls clear [missingReminderIds] (repair works).
  bool healOnResync = false;
  int syncCalls = 0;
  RingingAlarm? ringing;
  AlarmLaunch? pendingLaunch;
  final List<String> openedSettings = [];
  final List<(String, int, int)> actions = [];
  final Map<int, int> _snoozesUsed = {};
  final List<ScheduledAlarm> _oneShots = [];
  final StreamController<Map<String, dynamic>> _events = StreamController.broadcast();
  Timer? _testTimer;

  /// Pushes a native-style event to [events] listeners.
  void emit(Map<String, dynamic> event) => _events.add(event);

  static DateTime nextLocal(int hour, int minute, int weekday, DateTime after) {
    for (var i = 0; i <= 8; i++) {
      final d = DateTime(after.year, after.month, after.day + i, hour, minute);
      if (d.weekday == weekday && d.isAfter(after)) return d;
    }
    return DateTime(after.year, after.month, after.day + 7, hour, minute);
  }

  List<ScheduledAlarm> _computeScheduled() {
    final now = _now();
    final out = <ScheduledAlarm>[];
    for (final r in reminders) {
      if (r['enabled'] != true) continue;
      final id = _int(r['id']);
      final days = (r['weekdays'] as List? ?? const []).map(_int).where((d) => d >= 1 && d <= 7).toSet();
      for (final d in days) {
        out.add(ScheduledAlarm(
          reminderId: id,
          weekday: d,
          kind: 'main',
          triggerAtMs: nextLocal(_int(r['hour']), _int(r['minute']), d, now).millisecondsSinceEpoch,
          exists: !missingReminderIds.contains(id),
        ));
      }
    }
    final nowMs = now.millisecondsSinceEpoch;
    out.addAll(_oneShots.where((s) => s.triggerAtMs > nowMs));
    out.sort((a, b) => a.triggerAtMs.compareTo(b.triggerAtMs));
    return out;
  }

  void _log(int reminderId, int occurrenceMs, String event, String label) => eventLog.add(AlarmEvent(
        reminderId: reminderId,
        occurrenceMs: occurrenceMs,
        event: event,
        atMs: _now().millisecondsSinceEpoch,
        label: label,
      ));

  @override
  Future<List<ScheduledAlarm>> syncReminders(List<Map<String, dynamic>> reminders) async {
    syncCalls++;
    if (healOnResync && syncCalls > 1) missingReminderIds.clear();
    this.reminders = [for (final r in reminders) Map<String, dynamic>.of(r)];
    return _computeScheduled();
  }

  @override
  Future<List<ScheduledAlarm>> getScheduled() async => _computeScheduled();

  @override
  Future<int> scheduleTest({int seconds = 10, required String label, int? routineId}) async {
    final at = _now().add(Duration(seconds: seconds)).millisecondsSinceEpoch;
    _oneShots
      ..removeWhere((s) => s.reminderId == -1)
      ..add(ScheduledAlarm(reminderId: -1, weekday: 0, kind: 'test', triggerAtMs: at, exists: true));
    _testTimer?.cancel();
    _testTimer = Timer(Duration(seconds: seconds), () {
      _oneShots.removeWhere((s) => s.reminderId == -1);
      final alarm = RingingAlarm(
        reminderId: -1,
        occurrenceMs: at,
        routineId: routineId,
        label: label,
        kind: 'test',
        snoozesUsed: 0,
        maxSnoozes: 3,
        startedMs: _now().millisecondsSinceEpoch,
      );
      ringing = alarm;
      _log(-1, at, 'test_rang', label);
      emit({'type': 'ringing', ...alarm.toMap()});
    });
    return at;
  }

  @override
  Future<AlarmLaunch?> getLaunchAction() async {
    final launch = pendingLaunch;
    pendingLaunch = null;
    return launch;
  }

  @override
  Future<RingingAlarm?> getRinging() async => ringing;

  @override
  Future<int> alarmAction(String action, int reminderId, int occurrenceMs) async {
    actions.add((action, reminderId, occurrenceMs));
    final current = ringing?.reminderId == reminderId ? ringing : null;
    final max = current?.maxSnoozes ??
        _int(reminders.where((r) => _int(r['id']) == reminderId).firstOrNull?['max_snoozes'], 3);
    final used = _snoozesUsed[reminderId] ?? 0;
    final label = current?.label ?? '';
    void stopRinging(String reason) {
      if (current == null) return;
      ringing = null;
      emit({
        'type': 'stopped',
        'reminder_id': reminderId,
        'occurrence_ms': current.occurrenceMs,
        'reason': reason,
      });
    }

    switch (action) {
      case 'start':
      case 'dismiss':
        stopRinging(action == 'start' ? 'started' : 'dismissed');
        _snoozesUsed.remove(reminderId);
        _oneShots.removeWhere((s) => s.reminderId == reminderId);
        _log(reminderId, occurrenceMs, action == 'start' ? 'started' : 'dismissed', label);
        return (max - used).clamp(0, max);
      case 'snooze':
        if (used >= max) return 0;
        stopRinging('snoozed');
        _snoozesUsed[reminderId] = used + 1;
        _log(reminderId, occurrenceMs, 'snoozed', label);
        return max - used - 1;
      case 'stop':
        if (current != null) {
          // Like Kotlin: the event reason is 'stopped', the logged event auto_stopped.
          stopRinging('stopped');
          _log(reminderId, occurrenceMs, 'auto_stopped', label);
        }
        return (max - used).clamp(0, max);
      default:
        return (max - used).clamp(0, max);
    }
  }

  @override
  Future<List<AlarmEvent>> getEvents(int sinceMs) async =>
      eventLog.where((e) => e.atMs >= sinceMs).toList();

  @override
  Future<NativeStatus> getStatus() async {
    final next = _computeScheduled().where((s) => s.exists).firstOrNull;
    final s = status;
    return NativeStatus(
      notificationsEnabled: s.notificationsEnabled,
      exactAlarmsAllowed: s.exactAlarmsAllowed,
      fullScreenAllowed: s.fullScreenAllowed,
      ignoringBatteryOptimizations: s.ignoringBatteryOptimizations,
      nextAlarmMs: next?.triggerAtMs,
      manufacturer: s.manufacturer,
      model: s.model,
      timezone: timezone,
      sdkInt: s.sdkInt,
      isAndroid: s.isAndroid,
    );
  }

  @override
  Future<bool> requestNotificationPermission() async => status.notificationsEnabled;

  @override
  Future<bool> openSettings(String page) async {
    openedSettings.add(page);
    return false;
  }

  @override
  Future<String> getTimezone() async => timezone;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  void reattachEvents() {}

  Future<void> dispose() async {
    _testTimer?.cancel();
    await _events.close();
  }
}
