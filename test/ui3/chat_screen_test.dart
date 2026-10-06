import 'dart:io';

import 'package:daily_duas/core/models/models.dart';
import 'package:daily_duas/core/net/llm_client.dart';
import 'package:daily_duas/core/providers.dart';
import 'package:daily_duas/domain/quran_index.dart';
import 'package:daily_duas/features/chat/chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui3_fakes.dart';

class _OfflineLlm extends LlmClient {
  _OfflineLlm() : super(settings: () => const AppSettings());

  int calls = 0;

  @override
  Future<ChatReply> suggestDuas(
      String userText, List<ChatMessage> history) async {
    calls++;
    throw const LlmException('offline', 'No internet connection.');
  }
}

void main() {
  late QuranIndex quran;

  setUpAll(() {
    quran = QuranIndex.parse(
        File('assets/quran/quran-simple.txt').readAsStringSync());
  });

  testWidgets(
      'renders suggestion cards; wrong Quran text is flagged unverified',
      (tester) async {
    useTallWindow(tester);
    final llm = FakeLlmClient(const ChatReply(
      reply: 'Here are duas that may help.',
      duas: [
        DuaSuggestion(
          title: 'Wrong Ikhlas',
          arabic: 'قُلْ هُوَ اللَّهُ وَاحِدٌ',
          transliteration: 'Qul huwa Allahu wahid',
          translation: 'Say: He is Allah, One.',
          source: 'Quran 112:1',
          category: 'Protection',
          repeat: 3,
          kind: 'quran',
          quran: {'surah': 112, 'ayah_start': 1, 'ayah_end': 1},
        ),
        DuaSuggestion(
          title: 'Correct Ikhlas',
          arabic: 'قُلْ هُوَ اللَّهُ أَحَدٌ',
          source: 'Quran 112:1',
          kind: 'quran',
          quran: {'surah': 112, 'ayah_start': 1, 'ayah_end': 1},
        ),
      ],
    ));
    final chat = MemChatRepository();
    await tester.pumpWidget(testApp(const ChatScreen(), [
      initialSettingsProvider.overrideWithValue(const AppSettings()),
      settingsRepoProvider.overrideWithValue(MemSettingsRepository()),
      chatRepoProvider.overrideWithValue(chat),
      llmClientProvider.overrideWithValue(llm),
      quranIndexProvider.overrideWith((ref) async => quran),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Needs internet. Suggestions come from an AI model — always verify.'),
        findsOneWidget);
    await tester.tap(find.text('Dua for anxiety'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    expect(llm.asked, ['Dua for anxiety']);
    expect(chat.messages.map((m) => m.role), ['user', 'assistant']);

    expect(find.text('Wrong Ikhlas'), findsOneWidget);
    expect(find.text('قُلْ هُوَ اللَّهُ وَاحِدٌ'), findsOneWidget);
    expect(find.text('Qul huwa Allahu wahid'), findsOneWidget);
    expect(find.text('Say: He is Allah, One.'), findsOneWidget);
    expect(find.text('Source: Quran 112:1'), findsNWidgets(2));
    expect(find.text('Unverified'), findsOneWidget);
    expect(find.text('Verified'), findsOneWidget);
    expect(
        find.textContaining(
            'Could not verify this text against the Quran. Please check with a teacher or a mushaf'),
        findsOneWidget);
    expect(find.text('Add to my library'), findsNWidgets(2));
    expect(find.text('Edit'), findsNWidgets(2));
  });

  testWidgets('offline error shows a friendly bubble with Retry',
      (tester) async {
    useTallWindow(tester);
    final llm = _OfflineLlm();
    await tester.pumpWidget(testApp(const ChatScreen(), [
      initialSettingsProvider.overrideWithValue(const AppSettings()),
      settingsRepoProvider.overrideWithValue(MemSettingsRepository()),
      chatRepoProvider.overrideWithValue(MemChatRepository()),
      llmClientProvider.overrideWithValue(llm),
      quranIndexProvider.overrideWith((ref) async => quran),
    ]));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Dua for exams');
    await tester.tap(find.byTooltip('Send'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    expect(find.textContaining('You seem to be offline'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(llm.calls, 2);
    expect(find.text('Retry'), findsOneWidget); // only on the latest error
  });
}
