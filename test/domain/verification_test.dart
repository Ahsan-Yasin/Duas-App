import 'dart:io';

import 'package:daily_duas/core/models/models.dart' show VerificationStatus;
import 'package:daily_duas/domain/quran_index.dart';
import 'package:daily_duas/domain/verification.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late QuranIndex q;

  setUpAll(() {
    q = QuranIndex.parse(File('assets/quran/quran-simple.txt').readAsStringSync());
  });

  test('exact Tanzil text with reference is verified', () {
    final r = verifyDua(arabic: q.ayah(2, 201), source: 'Quran 2:201', quran: q);
    expect(r.status, VerificationStatus.verified);
    expect(r.kind, 'quran');
    expect(r.matchedRef, (2, 201, 201));
  });

  test('LLM-style spelling (no tatweel, different marks) is verified', () {
    final r = verifyDua(
      arabic: 'قُلْ هُوَ اللَّهُ أَحَدٌ، اللَّهُ الصَّمَدُ، لَمْ يَلِدْ وَلَمْ يُولَدْ، وَلَمْ يَكُنْ لَهُ كُفُوًا أَحَدٌ',
      source: 'Surah Al-Ikhlas (112)',
      quran: q,
    );
    expect(r.status, VerificationStatus.verified);
    expect(r.matchedRef, (112, 1, 4));
    expect(r.note, isNot(contains('partial')));
  });

  test('leading Bismillah is tolerated', () {
    final r = verifyDua(
      arabic: 'بسم الله الرحمن الرحيم قل هو الله أحد',
      source: 'Quran 112:1',
      quran: q,
    );
    expect(r.status, VerificationStatus.verified);
  });

  test('partial ayah substring is verified with a note', () {
    final r = verifyDua(
      arabic: 'رَبَّنَا تَقَبَّلْ مِنَّا إِنَّكَ أَنْتَ السَّمِيعُ الْعَلِيمُ',
      source: 'Quran 2:127',
      quran: q,
    );
    expect(r.status, VerificationStatus.verified);
    expect(r.note, contains('partial ayah'));
  });

  test('claimedQuran map takes precedence and supports ranges', () {
    final r = verifyDua(
      arabic: 'رب اشرح لي صدري ويسر لي أمري',
      source: 'Musa’s dua',
      quran: q,
      claimedQuran: {'surah': 20, 'ayah_start': 25, 'ayah_end': 26},
    );
    expect(r.status, VerificationStatus.verified);
    expect(r.matchedRef, (20, 25, 26));
  });

  test('wrong text for the reference is unverified with the standard note', () {
    final r = verifyDua(
      arabic: 'ربنا آتنا في الدنيا حسنة وفي الآخرة حسنة وقنا عذاب النار',
      source: 'Quran 2:202',
      quran: q,
    );
    expect(r.status, VerificationStatus.unverified);
    expect(r.note, startsWith('Text does not match the Quran at Quran 2:202. Check with a teacher or a mushaf.'));
    expect(r.matchedRef, (2, 201, 201)); // found elsewhere, reported as a hint
  });

  test('altered word is unverified', () {
    final r = verifyDua(
      arabic: 'ربنا آتنا في الدنيا خيرا وفي الآخرة حسنة وقنا عذاب النار',
      source: 'Quran 2:201',
      quran: q,
    );
    expect(r.status, VerificationStatus.unverified);
    expect(r.matchedRef, isNull);
  });

  test('short fragment below 12 characters is not a partial match', () {
    final r = verifyDua(arabic: 'رَبَّنَا', source: 'Quran 2:201', quran: q);
    expect(r.status, VerificationStatus.unverified);
  });

  test('no reference but verbatim Quran text is verified with found ref', () {
    final r = verifyDua(
      arabic: 'رَبَّنَا لَا تُزِغْ قُلُوبَنَا بَعْدَ إِذْ هَدَيْتَنَا وَهَبْ لَنَا مِن لَّدُنكَ رَحْمَةً إِنَّكَ أَنتَ الْوَهَّابُ',
      source: '',
      quran: q,
    );
    expect(r.status, VerificationStatus.verified);
    expect(r.matchedRef, (3, 8, 8));
  });

  test('hadith is unverified with the hadith note', () {
    final r = verifyDua(
      arabic: 'أَعُوذُ بِكَلِمَاتِ اللَّهِ التَّامَّةِ مِنْ كُلِّ شَيْطَانٍ وَهَامَّةٍ وَمِنْ كُلِّ عَيْنٍ لَامَّةٍ',
      source: 'Sahih al-Bukhari 3371',
      quran: q,
    );
    expect(r.status, VerificationStatus.unverified);
    expect(r.kind, 'hadith');
    expect(r.note, hadithNote);
  });

  test('invalid reference and empty text', () {
    final bad = verifyDua(arabic: 'قل هو الله أحد', source: 'Quran 2:300', quran: q);
    expect(bad.status, VerificationStatus.unverified);
    final empty = verifyDua(arabic: '  ', source: 'Quran 2:255', quran: q);
    expect(empty.status, VerificationStatus.unverified);
    expect(empty.kind, 'unknown');
  });
}
