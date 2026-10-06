import 'package:daily_duas/domain/hadith_ref.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseHadithRef', () {
    const cases = {
      'Sahih al-Bukhari 3371': ('bukhari', 3371),
      'Bukhari 3371': ('bukhari', 3371),
      'Sahih Muslim 2720': ('muslim', 2720),
      'Muslim #2720': ('muslim', 2720),
      'Sunan Abi Dawud 5088': ('abudawud', 5088),
      'Abu Dawud 5088': ('abudawud', 5088),
      'Abu Daud 5088': ('abudawud', 5088),
      'Jami at-Tirmidhi 3388': ('tirmidhi', 3388),
      'Tirmidhi 3388': ('tirmidhi', 3388),
      "Sunan an-Nasa'i 5500": ('nasai', 5500),
      'Ibn Majah 3869': ('ibnmajah', 3869),
      'Muwatta Malik 51': ('malik', 51),
      'Sahih Muslim 2713a': ('muslim', 2713),
      'Sahih al-Bukhari, Book of Supplications, Hadith 6306': ('bukhari', 6306),
      'Narrated by Anas ibn Malik, Bukhari 6363': ('bukhari', 6363),
    };
    cases.forEach((source, expected) {
      test(source, () {
        final ref = parseHadithRef(source);
        expect(ref, isNotNull);
        expect(ref!.collection, expected.$1);
        expect(ref.number, expected.$2);
      });
    });

    for (final source in [
      'Riyad as-Salihin 1478',
      'Hisn al-Muslim 75',
      'Quran 2:255',
      'Sahih Muslim',
      'Bukhari 6:301',
      '',
    ]) {
      test('null for "$source"', () => expect(parseHadithRef(source), isNull));
    }
  });

  test('HadithRef urls and label', () {
    final ref = parseHadithRef('Bukhari 3371')!;
    expect(ref.label, 'Sahih al-Bukhari 3371');
    expect(ref.sunnahUrl, 'https://sunnah.com/bukhari:3371');
    expect(ref.apiUrl,
        'https://cdn.jsdelivr.net/gh/fawazahmed0/hadith-api@1/editions/ara-bukhari/3371.json');
    const nawawi =
        HadithRef(collection: 'nawawi', number: 22, displayName: '40 Hadith Nawawi');
    expect(nawawi.sunnahUrl, 'https://sunnah.com/nawawi40:22');
    const qudsi =
        HadithRef(collection: 'qudsi', number: 5, displayName: '40 Hadith Qudsi');
    expect(qudsi.sunnahUrl, 'https://sunnah.com/qudsi40:5');
  });

  test('sourceUrl', () {
    expect(sourceUrl('Quran 2:255'), 'https://quran.com/2/255');
    expect(sourceUrl('Quran 2:201-202'), 'https://quran.com/2/201-202');
    expect(sourceUrl('Surah 112'), 'https://quran.com/112');
    expect(sourceUrl('Sahih Muslim 2720'), 'https://sunnah.com/muslim:2720');
    expect(sourceUrl('Abu Dawud 5088'), 'https://sunnah.com/abudawud:5088');
    expect(sourceUrl('Riyad as-Salihin 1478'), isNull);
    expect(sourceUrl('Unknown'), isNull);
  });
}
