import 'package:daily_duas/core/db/app_database.dart';
import 'package:daily_duas/features/library/library_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui1_test_utils.dart';

void main() {
  late AppDatabase db;

  setUp(() async => db = await openSeededTestDb());
  tearDown(() async => db.close());

  testWidgets('shows the seeded duas with verification chips', (tester) async {
    await tester.pumpWidget(await testApp(db, const LibraryScreen()));
    await pumpUntilFound(tester, find.text('Surah Al-Ikhlas'));

    expect(find.text('Surah Al-Falaq'), findsOneWidget);
    expect(find.text('Verified'), findsWidgets);
    expect(find.byTooltip('Chat to add duas'), findsOneWidget);
    expect(find.text('Add dua'), findsOneWidget);
    // Category filter chips come from the library.
    expect(find.widgetWithText(FilterChip, 'Protection'), findsOneWidget);
  });

  testWidgets('search filters the list', (tester) async {
    await tester.pumpWidget(await testApp(db, const LibraryScreen()));
    await pumpUntilFound(tester, find.text('Surah Al-Ikhlas'));

    await tester.enterText(find.byType(TextField), 'falaq');
    await tester.pump();

    expect(find.text('Surah Al-Falaq'), findsOneWidget);
    expect(find.text('Surah Al-Ikhlas'), findsNothing);
    expect(find.text('Surah An-Nas'), findsNothing);

    await tester.enterText(find.byType(TextField), 'no such dua xyz');
    await tester.pump();
    expect(find.textContaining('No duas match'), findsOneWidget);
  });

  testWidgets('delete shows Undo and undo restores the dua', (tester) async {
    await tester.pumpWidget(await testApp(db, const LibraryScreen()));
    await pumpUntilFound(tester, find.text('Surah Al-Ikhlas'));

    await tester.tap(find.byTooltip('More actions for Surah Al-Ikhlas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await pumpUntilFound(tester, find.text('Undo'));
    await tester.pumpAndSettle(); // let the SnackBar finish sliding in

    expect(find.text('Deleted "Surah Al-Ikhlas"'), findsOneWidget);
    expect(find.text('Surah Al-Ikhlas'), findsNothing);

    await tester.tap(find.text('Undo'));
    await pumpUntilFound(tester, find.text('Surah Al-Ikhlas'));
    expect(find.text('Surah Al-Ikhlas'), findsOneWidget);
  });
}
