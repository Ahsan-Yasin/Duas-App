/// Arabic text helpers used for search, duplicate detection and Quran
/// verification. Pure Dart.
///
/// The functions here never change stored text; they produce comparison keys.
/// See docs/research/content.md §6 for the code points involved. The Tanzil
/// "Simple" text uses tatweel + superscript alef (U+0640 U+0670), shadda before
/// the vowel, waqf marks U+06D6–U+06DC and the sajdah sign U+06E9 as separate
/// tokens. LLM / keyboard input instead tends to use plain letters, a different
/// mark order, Farsi yeh/keheh, presentation forms or bidi control characters.
/// [normalizeArabic] folds all of these onto one letter skeleton.
library;

/// Code points removed by [normalizeArabic] and [stripDiacritics]: harakat,
/// tanween, shadda, sukun, maddah/hamza marks, superscript alef, Quranic
/// annotation marks, tatweel and the extended-A marks.
bool _isMark(int c) =>
    (c >= 0x0610 && c <= 0x061A) || // honorifics, small high marks
    (c >= 0x064B && c <= 0x065F) || // harakat, tanween, shadda, sukun, maddah, hamza above/below
    c == 0x0670 || // superscript (dagger) alef
    c == 0x0640 || // tatweel
    (c >= 0x06D6 && c <= 0x06ED) || // Quranic annotation marks incl. small waw/yeh, sajdah, ayah end
    (c >= 0x08D3 && c <= 0x08FF) || // extended-A marks, sequential tanween
    (c >= 0xFE70 && c <= 0xFE7F); // presentation forms of harakat

/// Zero-width and bidi control characters (dropped, never turned into a space).
bool _isInvisible(int c) =>
    (c >= 0x200B && c <= 0x200F) ||
    (c >= 0x202A && c <= 0x202E) ||
    (c >= 0x2066 && c <= 0x2069) ||
    c == 0x061C ||
    c == 0xFEFF ||
    c == 0x00AD;

/// Arabic Presentation Forms-B letters (U+FE80..U+FEFC) to base letters.
/// Each entry covers a contiguous block of isolated/final/initial/medial forms.
const List<(int, int, String)> _presentationB = [
  (0xFE80, 0xFE80, 'ء'),
  (0xFE81, 0xFE82, 'آ'),
  (0xFE83, 0xFE84, 'أ'),
  (0xFE85, 0xFE86, 'ؤ'),
  (0xFE87, 0xFE88, 'إ'),
  (0xFE89, 0xFE8C, 'ئ'),
  (0xFE8D, 0xFE8E, 'ا'),
  (0xFE8F, 0xFE92, 'ب'),
  (0xFE93, 0xFE94, 'ة'),
  (0xFE95, 0xFE98, 'ت'),
  (0xFE99, 0xFE9C, 'ث'),
  (0xFE9D, 0xFEA0, 'ج'),
  (0xFEA1, 0xFEA4, 'ح'),
  (0xFEA5, 0xFEA8, 'خ'),
  (0xFEA9, 0xFEAA, 'د'),
  (0xFEAB, 0xFEAC, 'ذ'),
  (0xFEAD, 0xFEAE, 'ر'),
  (0xFEAF, 0xFEB0, 'ز'),
  (0xFEB1, 0xFEB4, 'س'),
  (0xFEB5, 0xFEB8, 'ش'),
  (0xFEB9, 0xFEBC, 'ص'),
  (0xFEBD, 0xFEC0, 'ض'),
  (0xFEC1, 0xFEC4, 'ط'),
  (0xFEC5, 0xFEC8, 'ظ'),
  (0xFEC9, 0xFECC, 'ع'),
  (0xFECD, 0xFED0, 'غ'),
  (0xFED1, 0xFED4, 'ف'),
  (0xFED5, 0xFED8, 'ق'),
  (0xFED9, 0xFEDC, 'ك'),
  (0xFEDD, 0xFEE0, 'ل'),
  (0xFEE1, 0xFEE4, 'م'),
  (0xFEE5, 0xFEE8, 'ن'),
  (0xFEE9, 0xFEEC, 'ه'),
  (0xFEED, 0xFEEE, 'و'),
  (0xFEEF, 0xFEF0, 'ى'),
  (0xFEF1, 0xFEF4, 'ي'),
  (0xFEF5, 0xFEF6, 'لآ'),
  (0xFEF7, 0xFEF8, 'لأ'),
  (0xFEF9, 0xFEFA, 'لإ'),
  (0xFEFB, 0xFEFC, 'لا'),
];

/// Expands presentation forms (compatibility decomposition for the Arabic
/// ranges, the part of NFKC that matters here). Returns null when [c] is not a
/// presentation form that maps to letters.
String? _expandPresentation(int c) {
  if (c == 0xFDF2) return 'الله'; // ﷲ
  if (c >= 0xFE80 && c <= 0xFEFC) {
    for (final (lo, hi, s) in _presentationB) {
      if (c >= lo && c <= hi) return s;
    }
  }
  return null;
}

/// Letter folding for the lenient skeleton. Returns '' to drop a letter.
String? _fold(int c) {
  switch (c) {
    case 0x0622: // آ
    case 0x0623: // أ
    case 0x0625: // إ
    case 0x0671: // ٱ wasla
    case 0x0672: // ٲ
    case 0x0673: // ٳ
      return 'ا';
    case 0x0649: // ى
    case 0x06CC: // ی Farsi yeh
    case 0x06D2: // ے yeh barree
    case 0x0626: // ئ
      return 'ي';
    case 0x0629: // ة
    case 0x06C0: // ۀ
    case 0x06C1: // ہ
    case 0x06D5: // ە
      return 'ه';
    case 0x0624: // ؤ
      return 'و';
    case 0x06A9: // ک keheh
      return 'ك';
    case 0x0621: // ء standalone hamza
      return '';
  }
  return null;
}

bool _isArabicLetter(int c) =>
    (c >= 0x0620 && c <= 0x063F) ||
    (c >= 0x0641 && c <= 0x064A) ||
    c == 0x066E ||
    c == 0x066F ||
    (c >= 0x0671 && c <= 0x06D3) ||
    c == 0x06D5 ||
    c == 0x06EE ||
    c == 0x06EF ||
    (c >= 0x06FA && c <= 0x06FC) ||
    c == 0x06FF ||
    (c >= 0x0750 && c <= 0x077F) ||
    (c >= 0x08A0 && c <= 0x08C9);

bool _isWordChar(int c) =>
    _isArabicLetter(c) ||
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    (c >= 0xC0 && c <= 0x24F && c != 0xD7 && c != 0xF7);

/// Removes harakat, tanween, shadda, sukun, superscript alef, Quranic
/// annotation marks (U+06D6–U+06ED) and tatweel. Letters are kept unchanged
/// (no folding); whitespace runs are collapsed so that standalone waqf marks do
/// not leave double spaces. Useful for display-level search.
String stripDiacritics(String text) {
  final out = StringBuffer();
  var pendingSpace = false;
  for (final c in text.runes) {
    if (_isMark(c) || _isInvisible(c)) continue;
    if (_isSpace(c)) {
      pendingSpace = out.isNotEmpty;
      continue;
    }
    if (pendingSpace) {
      out.write(' ');
      pendingSpace = false;
    }
    out.writeCharCode(c);
  }
  return out.toString();
}

bool _isSpace(int c) =>
    c == 0x20 ||
    c == 0x09 ||
    c == 0x0A ||
    c == 0x0D ||
    c == 0x0B ||
    c == 0x0C ||
    c == 0xA0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200A) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202F ||
    c == 0x205F ||
    c == 0x3000;

/// Lenient letter skeleton used to compare Arabic from any source with the
/// Tanzil text:
/// * presentation forms and ﷲ are expanded (the NFKC part that matters);
/// * zero-width / bidi characters are removed;
/// * harakat, tanween, shadda, sukun, maddah/hamza marks, U+0670, tatweel,
///   U+06D6–U+06ED and U+08D3–U+08FF are removed (so mark order is irrelevant);
/// * أ إ آ ٱ ٲ ٳ → ا, ى ی ے ئ → ي, ة → ه, ؤ → و, ک → ك, standalone ء dropped;
/// * punctuation, digits, symbols and ayah ornaments become spaces;
/// * whitespace is collapsed and trimmed.
///
/// Latin letters are kept (lower-cased) so that mixed text still compares.
/// The function is idempotent.
String normalizeArabic(String text) {
  final out = StringBuffer();
  var pendingSpace = false;

  void emit(String s) {
    if (s.isEmpty) return;
    if (pendingSpace) {
      if (out.isNotEmpty) out.write(' ');
      pendingSpace = false;
    }
    out.write(s);
  }

  void handle(int c) {
    if (_isInvisible(c) || _isMark(c)) return;
    final folded = _fold(c);
    if (folded != null) {
      emit(folded);
      return;
    }
    if (_isArabicLetter(c)) {
      emit(String.fromCharCode(c));
      return;
    }
    if (c >= 0x41 && c <= 0x5A) {
      emit(String.fromCharCode(c + 0x20));
      return;
    }
    if (_isWordChar(c)) {
      emit(String.fromCharCode(c).toLowerCase());
      return;
    }
    // Everything else (spaces, punctuation, digits, symbols, ornaments).
    pendingSpace = true;
  }

  for (final c in text.runes) {
    final expanded = _expandPresentation(c);
    if (expanded != null) {
      for (final e in expanded.runes) {
        handle(e);
      }
    } else {
      handle(c);
    }
  }
  return out.toString();
}

/// True when [text] contains at least one Arabic-script letter (including
/// presentation forms).
bool isArabic(String text) {
  for (final c in text.runes) {
    if (_isArabicLetter(c)) return true;
    if (_expandPresentation(c) != null) return true;
  }
  return false;
}
