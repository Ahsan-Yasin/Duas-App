import 'package:daily_duas/domain/arabic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeArabic', () {
    test('tatweel + superscript alef (Tanzil) matches plain spelling', () {
      expect(normalizeArabic('الرَّحْمَـٰنِ'), normalizeArabic('الرحمن'));
      expect(normalizeArabic('إِلَـٰهَ'), 'اله');
      expect(normalizeArabic('إله'), 'اله');
      expect(normalizeArabic('ذَٰلِكَ'), 'ذلك');
      expect(normalizeArabic('عَلَىٰ'), 'علي');
    });

    test('hamza seats, alef maqsura, ta marbuta are folded', () {
      expect(normalizeArabic('رَبَّنَا آتِنَا'), 'ربنا اتنا');
      expect(normalizeArabic('ربنا آتنا'), 'ربنا اتنا');
      expect(normalizeArabic('أَعُوذُ'), 'اعوذ');
      expect(normalizeArabic('ٱلْحَمْدُ'), 'الحمد');
      expect(normalizeArabic('رَحْمَةً'), 'رحمه');
      expect(normalizeArabic('يُؤْمِنُونَ'), 'يومنون');
      expect(normalizeArabic('سَيِّئَاتِ'), 'سييات');
      expect(normalizeArabic('شَيْءٍ'), 'شي');
      expect(normalizeArabic('عَلَى'), normalizeArabic('علي'));
    });

    test('mark order and shadda placement do not matter', () {
      // Tanzil: shadda before fatha; keyboards: fatha before shadda.
      expect(normalizeArabic('اللَّهِ'), normalizeArabic('اللَّهِ'));
      expect(normalizeArabic('مِن شَرِّ'), normalizeArabic('مِنْ شَرِّ'));
    });

    test('waqf/sajdah marks, small waw/yeh and punctuation are dropped', () {
      expect(normalizeArabic('مِنَّا ۖ إِنَّكَ'), 'منا انك');
      expect(normalizeArabic('يَسْتَكْبِرُونَ ۩'), 'يستكبرون');
      expect(normalizeArabic('إِبْرَٰهِـۧمَ'), 'ابرهم'); // Uthmani spelling stays different
      expect(normalizeArabic('هُوَ ۥ'), 'هو');
      expect(normalizeArabic('قُلْ، هُوَ اللَّهُ أَحَدٌ ﴿١﴾'), 'قل هو الله احد');
      expect(normalizeArabic('سبحان الله؟ (٣٣)'), 'سبحان الله');
    });

    test('bidi controls, presentation forms and Farsi letters', () {
      expect(normalizeArabic('‏بِسْمِ‏ اللَّهِ'), 'بسم الله');
      expect(normalizeArabic('ﷲ'), 'الله');
      expect(normalizeArabic('ﻻ'), 'لا');
      expect(normalizeArabic('ﺍﻟﻠﻪ'), 'الله');
      expect(normalizeArabic('یا ربی'), 'يا ربي');
      expect(normalizeArabic('کتاب'), 'كتاب');
    });

    test('whitespace collapsed, idempotent, latin lower-cased', () {
      expect(normalizeArabic('  قُلْ   هُوَ\n\tاللَّهُ  '), 'قل هو الله');
      const s = 'الرَّحْمَـٰنِ الرَّحِيمِ ۚ';
      expect(normalizeArabic(normalizeArabic(s)), normalizeArabic(s));
      expect(normalizeArabic('Allah الله!'), 'allah الله');
      expect(normalizeArabic(''), '');
      expect(normalizeArabic('۞ ۝'), '');
    });
  });

  group('stripDiacritics', () {
    test('keeps letters, removes marks and collapses spaces', () {
      expect(stripDiacritics('الرَّحْمَـٰنِ'), 'الرحمن');
      expect(stripDiacritics('أَعُوذُ'), 'أعوذ');
      expect(stripDiacritics('مِنَّا ۖ إِنَّكَ'), 'منا إنك');
    });
  });

  group('isArabic', () {
    test('detects Arabic letters', () {
      expect(isArabic('بسم'), isTrue);
      expect(isArabic('Dua: رَبِّ'), isTrue);
      expect(isArabic('ﷲ'), isTrue);
      expect(isArabic('Bismillah 123'), isFalse);
      expect(isArabic('٣٣'), isFalse);
      expect(isArabic(''), isFalse);
    });
  });
}
