import 'dart:io';

import 'package:daily_duas/domain/arabic.dart';
import 'package:daily_duas/domain/quran_index.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late QuranIndex q;

  setUpAll(() {
    q = QuranIndex.parse(File('assets/quran/quran-simple.txt').readAsStringSync());
  });

  group('QuranIndex.parse', () {
    test('reads all 114 surahs / 6236 ayat and skips comments', () {
      expect(q.surahCount, 114);
      var total = 0;
      for (var s = 1; s <= 114; s++) {
        expect(q.ayahCount(s), surahAyahCounts[s - 1], reason: 'surah $s');
        total += q.ayahCount(s);
      }
      expect(total, 6236);
      expect(q.ayahCount(0), 0);
      expect(q.ayahCount(115), 0);
    });

    test('small synthetic file with CRLF, blank and # lines', () {
      final idx = QuranIndex.parse('1|1|a b\r\n1|2|c\r\n\r\n# comment\n2|1|d\n');
      expect(idx.surahCount, 2);
      expect(idx.ayahCount(1), 2);
      expect(idx.ayahRaw(1, 2), 'c');
      expect(() => QuranIndex.parse('# only comments\n'), throwsFormatException);
    });

    test('ayah strips the Bismillah prefix except for 1:1 and surah 9', () {
      expect(q.ayahRaw(112, 1).startsWith('بِسْمِ'), isTrue);
      // Verbatim Tanzil words after the 4-word prefix (Tanzil puts shadda
      // before the vowel, so compare with the file, not a typed literal).
      expect(q.ayah(112, 1), q.ayahRaw(112, 1).split(' ').skip(4).join(' '));
      expect(normalizeArabic(q.ayah(112, 1)), 'قل هو الله احد');
      expect(normalizeArabic(q.ayah(95, 1)), 'والتين والزيتون'); // prefix with shadda on ba
      expect(q.ayah(1, 1), q.ayahRaw(1, 1));
      expect(normalizeArabic(q.ayah(1, 1)), bismillahNormalized);
      expect(q.ayah(9, 1).startsWith('بَرَاءَةٌ'), isTrue);
      expect(normalizeArabic(q.ayah(27, 30)), endsWith(bismillahNormalized)); // mid-ayah Bismillah kept
      expect(() => q.ayah(112, 5), throwsRangeError);
    });

    test('ayahs ranges, end 0 = to the end', () {
      expect(q.ayahs(112, 1, 4), hasLength(4));
      expect(q.ayahs(112, 1, 0), hasLength(4));
      expect(normalizeArabic(q.ayahs(2, 255, 255).single), startsWith('الله لا اله الا هو الحي القيوم'));
      expect(() => q.ayahs(2, 5, 3), throwsRangeError);
      expect(q.resolve((112, 1, 0)), (112, 1, 4));
      expect(q.resolve((112, 1, 9)), isNull);
    });
  });

  group('find', () {
    test('finds an ayah from LLM-style text', () {
      final hits = q.find(normalizeArabic('ربنا آتنا في الدنيا حسنة وفي الآخرة حسنة وقنا عذاب النار'));
      expect(hits, contains((2, 201, 201)));
    });

    test('finds text across ayah boundaries', () {
      final hits = q.find(normalizeArabic('قل هو الله أحد الله الصمد لم يلد ولم يولد ولم يكن له كفوا أحد'));
      expect(hits, [(112, 1, 4)]);
      final cross = q.find(normalizeArabic('رب اشرح لي صدري ويسر لي أمري'));
      expect(cross, contains((20, 25, 26)));
    });

    test('word aligned, minimum length', () {
      expect(q.find('الله'), isEmpty); // too short
      expect(q.find(normalizeArabic('قل هو الله احد'), minLen: 20), isEmpty);
      // Cut in the middle of a word does not match.
      expect(q.find(normalizeArabic('نا اتنا في الدنيا حسنه')), isEmpty);
      expect(q.find(normalizeArabic('هذا نص ليس في القران ابدا')), isEmpty);
    });

    test('normalizedRange joins stripped ayat', () {
      expect(q.normalizedRange(112, 1, 2), 'قل هو الله احد الله الصمد');
    });
  });

  group('parseQuranRef', () {
    test('common forms', () {
      expect(parseQuranRef('Quran 2:255'), (2, 255, 255));
      expect(parseQuranRef("Qur'an 2:201-202"), (2, 201, 202));
      expect(parseQuranRef('Qur’an 2:201–202'), (2, 201, 202));
      expect(parseQuranRef('Surah Al-Baqarah 2:286'), (2, 286, 286));
      expect(parseQuranRef('Al-Baqarah 2:201-202'), (2, 201, 202));
      expect(parseQuranRef('Q 112:1-4'), (112, 1, 4));
      expect(parseQuranRef('2:255'), (2, 255, 255));
      expect(parseQuranRef('Quran 2:201 - 2:202'), (2, 201, 202));
      expect(parseQuranRef('Surah 2, ayah 255'), (2, 255, 255));
      expect(parseQuranRef('Al-Baqarah, verses 285-286'), (2, 285, 286));
      expect(parseQuranRef('القرآن ٢:٢٥٥'), (2, 255, 255));
    });

    test('whole surah returns end 0', () {
      expect(parseQuranRef('Al-Ikhlas (112)'), (112, 1, 0));
      expect(parseQuranRef('Surah 112'), (112, 1, 0));
      expect(parseQuranRef('Surah Al-Ikhlas'), (112, 1, 0));
      expect(parseQuranRef('Surah Yaseen'), (36, 1, 0));
      expect(parseQuranRef('Surat An-Nas'), (114, 1, 0));
    });

    test('hadith and invalid references return null', () {
      expect(parseQuranRef('Sahih Muslim 2720'), isNull);
      expect(parseQuranRef('Sahih al-Bukhari 3371'), isNull);
      expect(parseQuranRef('Bukhari 6:301'), isNull);
      expect(parseQuranRef("Jami' at-Tirmidhi 3575"), isNull);
      expect(parseQuranRef('Sunan Abi Dawud 5082'), isNull);
      expect(parseQuranRef(''), isNull);
      expect(parseQuranRef('Quran 2:300'), isNull);
      expect(parseQuranRef('Quran 115:1'), isNull);
      expect(parseQuranRef('Quran 2:286-3:1'), isNull);
      expect(parseQuranRef('Surah 200'), isNull);
      expect(parseQuranRef('A beautiful dua'), isNull);
    });

    test('formatQuranRef', () {
      expect(formatQuranRef((2, 255, 255)), 'Quran 2:255');
      expect(formatQuranRef((2, 201, 202)), 'Quran 2:201-202');
      expect(formatQuranRef((112, 1, 0)), 'Quran 112');
    });
  });
}
