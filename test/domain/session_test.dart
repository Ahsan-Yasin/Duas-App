import 'package:daily_duas/domain/session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<SessionItem> items() => const [
        SessionItem(duaId: 10, title: 'Ayat al-Kursi', target: 1),
        SessionItem(duaId: 11, title: 'Al-Ikhlas', target: 3),
        SessionItem(duaId: 12, title: 'Al-Falaq', target: 3),
      ];

  test('initial state', () {
    final s = ReciteSession(items(), routineId: 5);
    expect(s.current!.duaId, 10);
    expect(s.positionLabel, 'Dua 1 of 3');
    expect(s.count, 0);
    expect(s.target, 1);
    expect(s.remaining, 1);
    expect(s.progress, 0);
    expect(s.isFinished, isFalse);
    expect(s.startedAt, matches(RegExp(r'[+-]\d\d:\d\d$')));
  });

  test('tap counts to target and completes the item automatically', () {
    final s = ReciteSession(items());
    final r = s.tap();
    expect(r.count, 1);
    expect(r.itemDone, isTrue);
    expect(r.sessionDone, isFalse);
    expect(s.completed, {0});
    expect(s.next(), isTrue);
    expect(s.tap().itemDone, isFalse);
    expect(s.tap().count, 2);
    expect(s.remaining, 1);
    expect(s.tap().itemDone, isTrue);
  });

  test('tap never exceeds target', () {
    final s = ReciteSession(items())..next();
    for (var i = 0; i < 10; i++) {
      s.tap();
    }
    expect(s.count, 3);
    final extra = s.tap();
    expect(extra.count, 3);
    expect(extra.counted, isFalse);
    expect(extra.itemDone, isTrue);
  });

  test('skip / back / next and isFinished', () {
    final s = ReciteSession(items());
    s.tap(); // item 0 done
    s.next();
    s.skip(); // item 1 skipped, moves to 2
    expect(s.index, 2);
    expect(s.skipped, {1});
    expect(s.positionLabel, 'Dua 3 of 3');
    expect(s.next(), isFalse);
    s.tap();
    s.tap();
    final last = s.tap();
    expect(last.itemDone, isTrue);
    expect(last.sessionDone, isTrue);
    expect(s.isFinished, isTrue);
    expect(s.completedDuaIds, [10, 12]);
    expect(s.skippedDuaIds, [11]);
    expect(s.back(), isTrue);
    expect(s.back(), isTrue);
    expect(s.back(), isFalse);
    expect(s.index, 0);
  });

  test('skip on the last item stays put; tapping a skipped item un-skips it', () {
    final s = ReciteSession(items())..goTo(2);
    s.skip();
    expect(s.index, 2);
    expect(s.skipped, {2});
    s.tap();
    expect(s.skipped, isEmpty);
    expect(s.count, 1);
  });

  test('progress and resetCurrent', () {
    final s = ReciteSession(items());
    s.tap(); // item 0 fully done
    s.next();
    s.tap(); // 1 of 3 reps on item 1
    expect(s.progress, closeTo((1 + 1 / 3) / 3, 1e-9));
    s.resetCurrent();
    expect(s.count, 0);
    expect(s.progress, closeTo(1 / 3, 1e-9));
    expect(s.firstUnfinished, 1);
  });

  test('toJson / fromJson round trip', () {
    final s = ReciteSession(
      items(),
      routineId: 7,
      fromAlarm: true,
      reminderId: 3,
      startedAt: '2026-10-06T07:00:00.000+05:00',
    );
    s.tap();
    s.next();
    s.tap();
    s.tap();
    s.next();
    s.skip();
    final r = ReciteSession.fromJson(s.toJson());
    expect(r.items.map((e) => e.duaId), [10, 11, 12]);
    expect(r.items[1].title, 'Al-Ikhlas');
    expect(r.items[1].target, 3);
    expect(r.routineId, 7);
    expect(r.fromAlarm, isTrue);
    expect(r.reminderId, 3);
    expect(r.startedAt, '2026-10-06T07:00:00.000+05:00');
    expect(r.index, s.index);
    expect(r.counts, s.counts);
    expect(r.completed, s.completed);
    expect(r.skipped, s.skipped);
    expect(r.progress, s.progress);
    expect(() => ReciteSession.fromJson('[]'), throwsFormatException);
  });

  test('fromJson clamps bad values', () {
    const json = '{"items":[{"dua_id":1,"title":"x","target":2}],"index":9,'
        '"counts":{"0":99,"5":1},"completed":[0,4],"skipped":[0]}';
    final s = ReciteSession.fromJson(json);
    expect(s.index, 0);
    expect(s.counts, {0: 2});
    expect(s.completed, {0});
    expect(s.skipped, isEmpty);
  });

  test('empty session and zero targets', () {
    final e = ReciteSession(const []);
    expect(e.current, isNull);
    expect(e.isFinished, isTrue);
    expect(e.positionLabel, 'Dua 0 of 0');
    expect(e.tap().counted, isFalse);
    final z = ReciteSession(const [SessionItem(duaId: 1, title: 'a', target: 0)]);
    expect(z.target, 1);
    expect(z.tap().sessionDone, isTrue);
  });
}
