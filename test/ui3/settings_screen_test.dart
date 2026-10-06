import 'package:daily_duas/core/models/models.dart';
import 'package:daily_duas/core/native/native_bridge.dart';
import 'package:daily_duas/core/providers.dart';
import 'package:daily_duas/features/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui3_fakes.dart';

void main() {
  testWidgets('Arabic font size slider updates the live preview and persists',
      (tester) async {
    useTallWindow(tester);
    final repo = MemSettingsRepository();
    await tester.pumpWidget(testApp(const SettingsScreen(), [
      initialSettingsProvider
          .overrideWithValue(const AppSettings(arabicFontSize: 30)),
      settingsRepoProvider.overrideWithValue(repo),
      routinesProvider.overrideWith((ref) async => const <Routine>[]),
      quranAudioProvider.overrideWithValue(FakeQuranAudioCache()),
      nativeBridgeProvider.overrideWithValue(FakeNativeBridge()),
    ]));
    await tester.pumpAndSettle();

    final preview = find.descendant(
      of: find.byKey(const ValueKey('arabicFontPreview')),
      matching: find.text(bismillahPreview),
    );
    double previewSize() => tester.widget<Text>(preview).style!.fontSize!;

    expect(preview, findsOneWidget);
    expect(previewSize(), 30);
    expect(find.text('Arabic text size: 30'), findsOneWidget);

    await tester.drag(find.byType(Slider).first, const Offset(300, 0));
    await tester.pumpAndSettle();

    final size = previewSize();
    expect(size, greaterThan(30));
    expect(find.text('Arabic text size: ${size.round()}'), findsOneWidget);
    expect(repo.saved.arabicFontSize, size.round());
  });

  testWidgets('theme selection persists immediately', (tester) async {
    useTallWindow(tester);
    final repo = MemSettingsRepository();
    await tester.pumpWidget(testApp(const SettingsScreen(), [
      initialSettingsProvider.overrideWithValue(const AppSettings()),
      settingsRepoProvider.overrideWithValue(repo),
      routinesProvider.overrideWith((ref) async => const <Routine>[]),
      quranAudioProvider.overrideWithValue(FakeQuranAudioCache()),
      nativeBridgeProvider.overrideWithValue(FakeNativeBridge()),
    ]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(repo.saved.themeMode, ThemeMode.dark);
    expect(find.text('Using built-in key'), findsOneWidget);
  });
}
