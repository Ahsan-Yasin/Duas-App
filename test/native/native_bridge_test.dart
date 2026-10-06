import 'package:daily_duas/core/native/native_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('daily_duas/native');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('maps snake_case method calls and results', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'sync_reminders':
        case 'get_scheduled':
          return [
            {'reminder_id': 1, 'weekday': 2, 'kind': 'main', 'trigger_at_ms': 1000, 'exists': true},
          ];
        case 'get_ringing':
          return {
            'reminder_id': 1,
            'occurrence_ms': 5,
            'routine_id': null,
            'label': 'Morning',
            'kind': 'snooze',
            'snoozes_used': 1,
            'max_snoozes': 3,
            'started_ms': 6,
          };
        case 'get_launch_action':
          return {'action': 'start', 'reminder_id': 1, 'occurrence_ms': 5, 'routine_id': 4, 'label': 'M', 'kind': 'main'};
        case 'get_events':
          return [
            {'reminder_id': 1, 'occurrence_ms': 5, 'event': 'rang', 'at_ms': 7, 'label': 'M'},
          ];
        case 'get_status':
          return {
            'notifications_enabled': true,
            'exact_alarms_allowed': true,
            'full_screen_allowed': false,
            'ignoring_battery_optimizations': false,
            'next_alarm_ms': 99,
            'manufacturer': 'samsung',
            'model': 'SM-X',
            'timezone': 'Asia/Karachi',
            'sdk_int': 35,
            'is_android': true,
          };
        case 'alarm_action':
          return 2;
        case 'schedule_test':
          return 1234;
        case 'get_timezone':
          return 'Asia/Karachi';
      }
      return null;
    });
    final bridge = MethodChannelNativeBridge(useNative: true);

    final scheduled = await bridge.syncReminders([
      {'id': 1, 'weekdays': [2]},
    ]);
    expect(calls.last.arguments, {
      'reminders': [
        {'id': 1, 'weekdays': [2]},
      ],
    });
    expect(scheduled.single.reminderId, 1);
    expect(scheduled.single.weekday, 2);
    expect(scheduled.single.triggerAtMs, 1000);
    expect(scheduled.single.exists, isTrue);

    final ringing = await bridge.getRinging();
    expect(ringing?.kind, 'snooze');
    expect(ringing?.routineId, isNull);
    expect(ringing?.snoozesLeft, 2);

    final launch = await bridge.getLaunchAction();
    expect(launch?.action, 'start');
    expect(launch?.routineId, 4);

    final events = await bridge.getEvents(3);
    expect(calls.last.arguments, {'since_ms': 3});
    expect(events.single.event, 'rang');
    expect(events.single.atMs, 7);

    final status = await bridge.getStatus();
    expect(status.fullScreenAllowed, isFalse);
    expect(status.nextAlarmMs, 99);
    expect(status.sdkInt, 35);
    expect(status.timezone, 'Asia/Karachi');

    expect(await bridge.alarmAction('snooze', 1, 5), 2);
    expect(calls.last.arguments, {'action': 'snooze', 'reminder_id': 1, 'occurrence_ms': 5});

    expect(await bridge.scheduleTest(seconds: 15, label: 'Test', routineId: 3), 1234);
    expect(calls.last.arguments, {'seconds': 15, 'label': 'Test', 'routine_id': 3});

    expect(await bridge.getTimezone(), 'Asia/Karachi');
  });

  test('falls back to the in-memory bridge when the plugin is missing off Android', () async {
    final fallback = FakeNativeBridge()..timezone = 'Europe/London';
    final bridge = MethodChannelNativeBridge(useNative: true, isAndroid: false, fallback: fallback);
    expect(await bridge.getTimezone(), 'Europe/London');
    expect(await bridge.getRinging(), isNull);
    expect((await bridge.getStatus()).isAndroid, isFalse);
    await fallback.dispose();
  });

  test('on Android a missing plugin is rethrown and never latches the fake', () async {
    final fallback = FakeNativeBridge()..timezone = 'Europe/London';
    final bridge = MethodChannelNativeBridge(isAndroid: true, fallback: fallback);
    // Headless engine: no handlers yet.
    await expectLater(bridge.getTimezone(), throwsA(isA<MissingPluginException>()));
    // MainActivity attached: the same bridge now reaches Kotlin.
    messenger.setMockMethodCallHandler(channel, (call) async => 'Asia/Karachi');
    expect(await bridge.getTimezone(), 'Asia/Karachi');
    await fallback.dispose();
  });

  test('events survive a re-attach after a missing plugin', () async {
    const eventChannel = EventChannel('daily_duas/native_events');
    var listens = 0;
    var cancels = 0;
    MockStreamHandlerEventSink? sink;
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(
        onListen: (_, events) {
          listens++;
          sink = events;
        },
        onCancel: (_) => cancels++,
      ),
    );
    addTearDown(() => messenger.setMockStreamHandler(eventChannel, null));
    final bridge = MethodChannelNativeBridge(isAndroid: true);
    final got = <Map<String, dynamic>>[];
    final sub = bridge.events.listen(got.add);
    await pumpEventQueue();
    expect(listens, 1);

    bridge.reattachEvents(); // nothing was missing: keep the live subscription
    await pumpEventQueue();
    expect((listens, cancels), (1, 0));

    await expectLater(bridge.getRinging(), throwsA(isA<MissingPluginException>()));
    bridge.reattachEvents();
    await pumpEventQueue();
    expect((listens, cancels), (2, 1));

    sink!.success({'type': 'stopped', 'reminder_id': 3, 'occurrence_ms': 9, 'reason': 'snoozed'});
    await pumpEventQueue();
    expect(got.single, {'type': 'stopped', 'reminder_id': 3, 'occurrence_ms': 9, 'reason': 'snoozed'});
    await sub.cancel();
  });

  test('FakeNativeBridge test alarm rings and actions stop it', () async {
    final fake = FakeNativeBridge();
    final ringingEvent = fake.events.firstWhere((e) => e['type'] == 'ringing');
    final at = await fake.scheduleTest(seconds: 1, label: 'Test alarm', routineId: 7);
    expect((await fake.getScheduled()).where((s) => s.kind == 'test'), hasLength(1));

    final event = await ringingEvent;
    expect(event['reminder_id'], -1);
    expect(event['occurrence_ms'], at);
    expect((await fake.getRinging())?.routineId, 7);

    final stopped = fake.events.firstWhere((e) => e['type'] == 'stopped');
    expect(await fake.alarmAction('snooze', -1, at), 2);
    expect((await stopped)['reason'], 'snoozed');
    expect(await fake.getRinging(), isNull);
    expect((await fake.getEvents(0)).map((e) => e.event), ['test_rang', 'snoozed']);
    await fake.dispose();
  });

  test('FakeNativeBridge stop mirrors Kotlin: stopped event reason "stopped", logged auto_stopped', () async {
    final fake = FakeNativeBridge()
      ..ringing = const RingingAlarm(
        reminderId: 4,
        occurrenceMs: 100,
        label: 'Fajr',
        kind: 'main',
        snoozesUsed: 0,
        maxSnoozes: 3,
        startedMs: 101,
      );
    final stopped = fake.events.firstWhere((e) => e['type'] == 'stopped');
    await fake.alarmAction('stop', 4, 100);
    expect(await stopped, {'type': 'stopped', 'reminder_id': 4, 'occurrence_ms': 100, 'reason': 'stopped'});
    expect(await fake.getRinging(), isNull);
    expect((await fake.getEvents(0)).map((e) => e.event), ['auto_stopped']);
    await fake.dispose();
  });
}
