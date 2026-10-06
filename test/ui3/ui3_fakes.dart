import 'dart:io';

import 'package:daily_duas/core/audio/quran_audio.dart';
import 'package:daily_duas/core/models/models.dart';
import 'package:daily_duas/core/native/native_bridge.dart';
import 'package:daily_duas/core/navigation.dart';
import 'package:daily_duas/core/net/llm_client.dart';
import 'package:daily_duas/core/repos/repositories.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

/// Records test-alarm requests instead of starting a real timer.
class RecordingBridge extends FakeNativeBridge {
  final testCalls = <(int, String, int?)>[];

  @override
  Future<int> scheduleTest(
      {int seconds = 10, required String label, int? routineId}) async {
    testCalls.add((seconds, label, routineId));
    return DateTime(2026, 10, 6, 12).millisecondsSinceEpoch + seconds * 1000;
  }
}

/// In-memory settings persistence (no database).
class MemSettingsRepository implements SettingsRepository {
  AppSettings saved = const AppSettings();

  @override
  Future<AppSettings> load() async => saved;

  @override
  Future<void> save(AppSettings s) async => saved = s;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// In-memory chat history.
class MemChatRepository implements ChatRepository {
  final messages = <ChatMessage>[];
  int _nextId = 1;

  @override
  Future<ChatMessage> add(ChatMessage m) async {
    final saved = m.copyWith(id: _nextId++);
    messages.add(saved);
    return saved;
  }

  @override
  Future<List<ChatMessage>> list({int limit = 200}) async =>
      List.of(messages);

  @override
  Future<void> clear() async => messages.clear();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Returns a fixed reply without touching the network.
class FakeLlmClient extends LlmClient {
  FakeLlmClient(this.reply) : super(settings: () => const AppSettings());

  final ChatReply reply;
  final asked = <String>[];

  @override
  Future<ChatReply> suggestDuas(
      String userText, List<ChatMessage> history) async {
    asked.add(userText);
    return reply;
  }
}

/// Audio cache that never touches the file system.
class FakeQuranAudioCache extends QuranAudioCache {
  FakeQuranAudioCache() : super(baseDir: () async => Directory.systemTemp);

  @override
  Future<int> cacheSizeBytes() async => 0;
}

/// Wraps [screen] in a ProviderScope + MaterialApp using the app navigator.
Widget testApp(Widget screen, List<Override> overrides) => ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        navigatorKey: navigatorKey,
        home: screen,
      ),
    );

/// Makes the test window tall enough to show long screens without scrolling.
void useTallWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}
