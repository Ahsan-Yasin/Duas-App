import 'package:daily_duas/core/db/app_database.dart';
import 'package:daily_duas/features/home/home_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'ui1_test_utils.dart';

void main() {
  late AppDatabase db;

  setUpAll(() {
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.UTC);
  });
  setUp(() async => db = await openSeededTestDb());
  tearDown(() async => db.close());

  testWidgets('shows Start now for the default routine', (tester) async {
    await tester.pumpWidget(await testApp(db, const HomeScreen()));
    await pumpUntilFound(tester, find.text('Start now'));

    expect(find.text('Assalamu alaikum'), findsOneWidget);
    // Seed makes "Morning" the default routine.
    expect(find.text('Morning'), findsWidgets);
    expect(find.text('No reminders yet — add one'), findsOneWidget);
  });
}
