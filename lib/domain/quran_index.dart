/// In-memory index of the bundled Tanzil "Simple" Quran text
/// (assets/quran/quran-simple.txt, lines `sura|aya|text`, `#` licence lines).
/// Pure Dart.
library;

import 'arabic.dart';

/// Number of ayat in each surah (index 0 = surah 1). Verified against the
/// bundled Tanzil file (6236 ayat in total).
const List<int> surahAyahCounts = [
  7, 286, 200, 176, 120, 165, 206, 75, 129, 109, 123, 111, 43, 52, 99, 128, //
  111, 110, 98, 135, 112, 78, 118, 64, 77, 227, 93, 88, 69, 60, 34, 30, 73, //
  54, 45, 83, 182, 88, 75, 85, 54, 53, 89, 59, 37, 35, 38, 29, 18, 45, 60, //
  49, 62, 55, 78, 96, 29, 22, 24, 13, 14, 11, 11, 18, 12, 12, 30, 52, 52, //
  44, 28, 28, 20, 56, 40, 31, 50, 40, 46, 42, 29, 19, 36, 25, 22, 17, 19, //
  26, 30, 20, 15, 21, 11, 8, 8, 19, 5, 8, 8, 11, 11, 8, 3, 9, 5, 4, 7, 3, //
  6, 3, 5, 4, 5, 6,
];

/// Common English transliterations of the surah names (index 0 = surah 1).
const List<String> surahNames = [
  'Al-Fatihah', 'Al-Baqarah', 'Al-Imran', 'An-Nisa', 'Al-Maidah', //
  'Al-Anam', 'Al-Araf', 'Al-Anfal', 'At-Tawbah', 'Yunus', 'Hud', 'Yusuf', //
  'Ar-Rad', 'Ibrahim', 'Al-Hijr', 'An-Nahl', 'Al-Isra', 'Al-Kahf', 'Maryam', //
  'Ta-Ha', 'Al-Anbiya', 'Al-Hajj', 'Al-Muminun', 'An-Nur', 'Al-Furqan', //
  'Ash-Shuara', 'An-Naml', 'Al-Qasas', 'Al-Ankabut', 'Ar-Rum', 'Luqman', //
  'As-Sajdah', 'Al-Ahzab', 'Saba', 'Fatir', 'Ya-Sin', 'As-Saffat', 'Sad', //
  'Az-Zumar', 'Ghafir', 'Fussilat', 'Ash-Shura', 'Az-Zukhruf', 'Ad-Dukhan', //
  'Al-Jathiyah', 'Al-Ahqaf', 'Muhammad', 'Al-Fath', 'Al-Hujurat', 'Qaf', //
  'Adh-Dhariyat', 'At-Tur', 'An-Najm', 'Al-Qamar', 'Ar-Rahman', 'Al-Waqiah', //
  'Al-Hadid', 'Al-Mujadilah', 'Al-Hashr', 'Al-Mumtahanah', 'As-Saff', //
  'Al-Jumuah', 'Al-Munafiqun', 'At-Taghabun', 'At-Talaq', 'At-Tahrim', //
  'Al-Mulk', 'Al-Qalam', 'Al-Haqqah', 'Al-Maarij', 'Nuh', 'Al-Jinn', //
  'Al-Muzzammil', 'Al-Muddaththir', 'Al-Qiyamah', 'Al-Insan', 'Al-Mursalat', //
  'An-Naba', 'An-Naziat', 'Abasa', 'At-Takwir', 'Al-Infitar', 'Al-Mutaffifin', //
  'Al-Inshiqaq', 'Al-Buruj', 'At-Tariq', 'Al-Ala', 'Al-Ghashiyah', 'Al-Fajr', //
  'Al-Balad', 'Ash-Shams', 'Al-Layl', 'Ad-Duha', 'Ash-Sharh', 'At-Tin', //
  'Al-Alaq', 'Al-Qadr', 'Al-Bayyinah', 'Az-Zalzalah', 'Al-Adiyat', //
  'Al-Qariah', 'At-Takathur', 'Al-Asr', 'Al-Humazah', 'Al-Fil', 'Quraysh', //
  'Al-Maun', 'Al-Kawthar', 'Al-Kafirun', 'An-Nasr', 'Al-Masad', 'Al-Ikhlas', //
  'Al-Falaq', 'An-Nas',
];

/// Skeleton of the Bismillah as produced by [normalizeArabic].
final String bismillahNormalized = normalizeArabic('بسم الله الرحمن الرحيم');

class QuranIndex {
  QuranIndex._(this._raw);

  /// `_raw[s - 1][a - 1]` = verbatim Tanzil line text.
  final List<List<String>> _raw;

  /// Lazily built search data: per surah, ' ' + normalized ayahs joined by
  /// ' ' + ' ', and the start offset of each ayah inside it.
  List<String>? _concat;
  List<List<int>>? _offsets;
  List<List<String>>? _normalized;

  /// Parses the Tanzil text. Blank lines and lines starting with `#` are
  /// skipped; malformed lines are ignored. Throws [FormatException] if no verse
  /// could be read.
  factory QuranIndex.parse(String fileText) {
    final bySurah = <int, Map<int, String>>{};
    var maxSurah = 0;
    for (var line in fileText.split('\n')) {
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      if (line.isEmpty) continue;
      if (line.startsWith('﻿')) line = line.substring(1);
      final trimmed = line.trimLeft();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final p1 = line.indexOf('|');
      if (p1 < 0) continue;
      final p2 = line.indexOf('|', p1 + 1);
      if (p2 < 0) continue;
      final s = int.tryParse(line.substring(0, p1).trim());
      final a = int.tryParse(line.substring(p1 + 1, p2).trim());
      if (s == null || a == null || s < 1 || a < 1) continue;
      bySurah.putIfAbsent(s, () => {})[a] = line.substring(p2 + 1);
      if (s > maxSurah) maxSurah = s;
    }
    if (bySurah.isEmpty) {
      throw const FormatException('No Quran verses found in the text.');
    }
    final raw = <List<String>>[];
    for (var s = 1; s <= maxSurah; s++) {
      final m = bySurah[s] ?? const <int, String>{};
      final list = <String>[];
      for (var a = 1; m.containsKey(a); a++) {
        list.add(m[a]!);
      }
      raw.add(List.unmodifiable(list));
    }
    return QuranIndex._(List.unmodifiable(raw));
  }

  /// Number of surahs in the index (114 for the bundled file).
  int get surahCount => _raw.length;

  /// Number of ayat in surah [s]; 0 when [s] is out of range.
  int ayahCount(int s) => (s >= 1 && s <= _raw.length) ? _raw[s - 1].length : 0;

  /// Whether `s:a` exists.
  bool isValid(int s, int a) => a >= 1 && a <= ayahCount(s);

  /// Whether ayah 1 of surah [s] carries the Bismillah prefix in Tanzil.
  bool hasBismillahPrefix(int s) => s != 1 && s != 9 && ayahCount(s) > 0;

  /// The verbatim Tanzil line for `s:a` (ayah 1 of surahs other than 1 and 9
  /// starts with the Bismillah). Throws [RangeError] when invalid.
  String ayahRaw(int s, int a) {
    _check(s, a);
    return _raw[s - 1][a - 1];
  }

  /// The text of `s:a` exactly as in Tanzil, except that the Bismillah prefix
  /// of ayah 1 (surahs other than 1 and 9) is removed, because it is not part
  /// of the ayah. Throws [RangeError] when invalid.
  String ayah(int s, int a) {
    final text = ayahRaw(s, a);
    if (a != 1 || !hasBismillahPrefix(s)) return text;
    return _stripBismillahPrefix(text);
  }

  /// Ayat [start]..[end] of surah [s] (see [ayah]). An [end] of 0 (or below
  /// [start] when 0) means "to the end of the surah", matching the whole-surah
  /// result of [parseQuranRef]. Throws [RangeError] when invalid.
  List<String> ayahs(int s, int start, int end) {
    final last = end <= 0 ? ayahCount(s) : end;
    _check(s, start);
    _check(s, last);
    if (last < start) {
      throw RangeError('Invalid ayah range $s:$start-$end');
    }
    return [for (var a = start; a <= last; a++) ayah(s, a)];
  }

  /// Resolves a reference from [parseQuranRef] (end 0 → last ayah) and
  /// validates it. Returns null when the reference does not exist.
  (int, int, int)? resolve((int, int, int) ref) {
    final (s, start, end) = ref;
    final last = end <= 0 ? ayahCount(s) : end;
    if (!isValid(s, start) || !isValid(s, last) || last < start) return null;
    return (s, start, last);
  }

  /// The normalized ([normalizeArabic]) text of ayat [start]..[end] of [s]
  /// joined by single spaces (Bismillah prefix removed). Throws [RangeError].
  String normalizedRange(int s, int start, int end) {
    _ensureSearchData();
    final last = end <= 0 ? ayahCount(s) : end;
    _check(s, start);
    _check(s, last);
    return _normalized![s - 1].sublist(start - 1, last).join(' ');
  }

  /// Finds every place where [normalizedText] occurs as a contiguous run of
  /// whole words in a surah, also across ayah boundaries. Returns
  /// `(surah, firstAyah, lastAyah)` for each occurrence, in mushaf order.
  /// Texts shorter than [minLen] normalized characters return an empty list.
  /// The text is normalized again defensively (normalization is idempotent).
  /// The Bismillah prefix of ayah 1 is not part of the searched text.
  List<(int, int, int)> find(String normalizedText, {int minLen = 12}) {
    final q = normalizeArabic(normalizedText);
    if (q.isEmpty || q.length < minLen) return const [];
    _ensureSearchData();
    final needle = ' $q ';
    final results = <(int, int, int)>[];
    for (var si = 0; si < _concat!.length; si++) {
      final hay = _concat![si];
      var from = 0;
      while (true) {
        final idx = hay.indexOf(needle, from);
        if (idx < 0) break;
        final startChar = idx + 1;
        final endChar = idx + needle.length - 2; // last char of the match
        final offsets = _offsets![si];
        final a1 = _ayahAt(offsets, startChar) + 1;
        final a2 = _ayahAt(offsets, endChar) + 1;
        final r = (si + 1, a1, a2);
        if (!results.contains(r)) results.add(r);
        from = idx + 1;
      }
    }
    return results;
  }

  void _check(int s, int a) {
    if (!isValid(s, a)) {
      throw RangeError('Quran reference $s:$a does not exist');
    }
  }

  static int _ayahAt(List<int> offsets, int pos) {
    var lo = 0, hi = offsets.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (offsets[mid] <= pos) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  void _ensureSearchData() {
    if (_concat != null) return;
    final concat = <String>[];
    final offsets = <List<int>>[];
    final normalized = <List<String>>[];
    for (var si = 0; si < _raw.length; si++) {
      final s = si + 1;
      final buf = StringBuffer(' ');
      final offs = <int>[];
      final norms = <String>[];
      for (var ai = 0; ai < _raw[si].length; ai++) {
        final n = normalizeArabic(ayah(s, ai + 1));
        norms.add(n);
        offs.add(buf.length);
        buf
          ..write(n)
          ..write(' ');
      }
      concat.add(buf.toString());
      offsets.add(offs);
      normalized.add(norms);
    }
    _normalized = normalized;
    _offsets = offsets;
    _concat = concat;
  }

  /// Drops the first four words (the Bismillah) when their skeleton really is
  /// the Bismillah; otherwise returns [text] unchanged.
  static String _stripBismillahPrefix(String text) {
    final words = text.split(' ');
    if (words.length <= 4) return text;
    final head = normalizeArabic(words.take(4).join(' '));
    if (head != bismillahNormalized) return text;
    return words.skip(4).join(' ');
  }
}

// ---------------------------------------------------------------------------
// Reference parsing
// ---------------------------------------------------------------------------

final RegExp _hadithWords = RegExp(
  r"\b(bukh[a]?ri|muslim|d[a]?wud|dawood|tirmidh?i|nas[a]?['’]?i|majah|ahmad|musnad|muwatta|malik|hadith|hadeeth|sunan|sahih|saheeh|riyad|riyadh|hisn|adab|bayhaqi|darimi|hibban|hakim|tabarani|mishkat|bulugh|nawawi|ibn)\b",
  caseSensitive: false,
);

final RegExp _quranWords = RegExp(
  r"(\bq\b|\bqur['’ʼ]?a+n\b|\bkoran\b|\bquran\b|\bsur(?:ah|a|at|ut|ah?t?ul)\b|\bayah\b|\bayat\b|\baya\b|القرآن|القران|سورة|سوره)",
  caseSensitive: false,
);

final RegExp _verseRange = RegExp(
  r'(\d{1,3})\s*[:.]\s*(\d{1,3})(?:\s*-\s*(?:(\d{1,3})\s*[:.]\s*)?(\d{1,3}))?',
);

final RegExp _surahVerseWords = RegExp(
  r'(\d{1,3})\s*,?\s*(?:ayah|ayat|aya|verses?|v\.?)\s*(\d{1,3})(?:\s*-\s*(\d{1,3}))?',
  caseSensitive: false,
);

final RegExp _nameVerseWords = RegExp(
  r'(?:ayah|ayat|aya|verses?|v\.?)\s*(\d{1,3})(?:\s*-\s*(\d{1,3}))?',
  caseSensitive: false,
);

String _cleanSource(String source) {
  final b = StringBuffer();
  for (final c in source.runes) {
    if (c >= 0x0660 && c <= 0x0669) {
      b.writeCharCode(0x30 + c - 0x0660);
    } else if (c >= 0x06F0 && c <= 0x06F9) {
      b.writeCharCode(0x30 + c - 0x06F0);
    } else if (c == 0x2010 ||
        c == 0x2011 ||
        c == 0x2012 ||
        c == 0x2013 ||
        c == 0x2014 ||
        c == 0x2212) {
      b.write('-');
    } else if (c == 0xFF1A || c == 0x2236) {
      b.write(':');
    } else {
      b.writeCharCode(c);
    }
  }
  return b.toString().replaceAll(RegExp(r'\s+to\s+', caseSensitive: false), '-');
}

(int, int, int)? _validated(int s, int a, int? e, bool validate) {
  final end = e ?? a;
  if (!validate) return (s < 1 || a < 1) ? null : (s, a, end);
  if (s < 1 || s > 114) return null;
  final count = surahAyahCounts[s - 1];
  if (a < 1 || a > count || end < a || end > count) return null;
  return (s, a, end);
}

String _nameKey(String name) {
  var k = name.toLowerCase().trim();
  k = k.replaceAll(RegExp(r"['’‘`ʿʾʼ]"), '');
  k = k.replaceFirst(
      RegExp(r'^(?:surah|sura|surat|suratul|surat-ul)[\s-]+'), '');
  k = k.replaceFirst(RegExp(r'^(?:aal|ali|al|an|ar|as|ash|at|ath|ad|adh|az|el)[\s-]+'), '');
  k = k.replaceAll(RegExp(r'[^a-z]'), '');
  k = k.replaceAll('ee', 'i').replaceAll('oo', 'u').replaceAll('ou', 'u');
  k = k.replaceAllMapped(RegExp(r'([a-z])\1+'), (m) => m[1]!);
  if (k.endsWith('ah')) k = k.substring(0, k.length - 1);
  if (k.startsWith('e') && k.length > 3) k = k.substring(1); // "Aal-e-Imran"
  return k;
}

final Map<String, int> _nameIndex = () {
  final m = <String, int>{};
  for (var i = 0; i < surahNames.length; i++) {
    m[_nameKey(surahNames[i])] = i + 1;
  }
  // Frequent alternative spellings.
  const aliases = {
    'Al-Imran': 3, 'Imran': 3, 'Aal-e-Imran': 3, 'Al-Maidah': 5,
    'Al-Anaam': 6, 'Tawbah': 9, 'Taubah': 9, 'Baraah': 9, 'Bani Israil': 17,
    'Isra': 17, 'Taha': 20, 'Yasin': 36, 'Yaseen': 36, 'Mumin': 40,
    'Ghafir': 40, 'Ha-Mim Sajdah': 41, 'Fussilat': 41, 'Dahr': 76,
    'Insan': 76, 'Inshirah': 94, 'Sharh': 94, 'Lahab': 111, 'Masad': 111,
    'Tin': 95, 'Teen': 95, 'Naas': 114, 'Nas': 114, 'Falaq': 113,
    'Ikhlas': 112, 'Ikhlaas': 112, 'Tawhid': 112, 'Kafiroon': 109,
    'Kawthar': 108, 'Kauthar': 108, 'Fatiha': 1, 'Fatihah': 1,
  };
  aliases.forEach((name, n) => m.putIfAbsent(_nameKey(name), () => n));
  return m;
}();

/// Looks up a surah number from a transliterated name ("Al-Baqarah",
/// "Surah Yasin"). Returns null when unknown.
int? surahNumberFromName(String name) {
  final k = _nameKey(name);
  if (k.isEmpty) return null;
  return _nameIndex[k];
}

/// Extracts a leading name segment ("Surah Al-Ikhlas (112)" → "Al-Ikhlas").
int? _nameIn(String text) {
  var t = text.replaceAll(_hadithWords, ' ');
  t = t.replaceAll(
      RegExp(r"\b(?:the\s+)?(?:holy\s+)?(?:qur['’ʼ]?a+n|quran|koran|q)\b",
          caseSensitive: false),
      ' ');
  final m = RegExp(r"[A-Za-z][A-Za-z'’ʿʾ\- ]*").allMatches(t);
  for (final match in m) {
    final seg = match[0]!.trim();
    final cleaned = seg
        .replaceAll(
            RegExp(r'\b(?:ayah|ayat|aya|verses?|v)\b.*$', caseSensitive: false),
            '')
        .trim();
    if (cleaned.isEmpty) continue;
    final n = surahNumberFromName(cleaned);
    if (n != null) return n;
  }
  return null;
}

/// Parses a Quran reference from a free-text source.
///
/// Returns `(surah, ayahStart, ayahEnd)`. Supported forms include
/// "Quran 2:255", "Qur'an 2:201-202", "Surah Al-Baqarah 2:286", "Q 112:1-4",
/// "2:201–2:202", "Al-Baqarah, verse 255", "Surah 2, ayah 255".
///
/// A whole-surah reference ("Surah 112", "Al-Ikhlas (112)", "Surah Al-Ikhlas")
/// returns `(surah, 1, 0)`: **an end of 0 means "to the last ayah"**; resolve
/// it with [QuranIndex.resolve] or [QuranIndex.ayahs].
///
/// Hadith citations ("Sahih Muslim 2720", "Bukhari 6:301") return null, as do
/// references to ayat that do not exist (unless [validate] is false, which
/// returns the numbers as written so callers can report a wrong reference) and
/// ranges spanning two surahs.
(int, int, int)? parseQuranRef(String source, {bool validate = true}) {
  final text = _cleanSource(source).trim();
  if (text.isEmpty) return null;
  final hasQuranWord = _quranWords.hasMatch(text);
  final nameNumber = _nameIn(text);
  if (!hasQuranWord && nameNumber == null && _hadithWords.hasMatch(text)) {
    return null;
  }

  // 1. "s:a", "s:a-b", "s:a-s:b".
  final vr = _verseRange.firstMatch(text);
  if (vr != null) {
    final s = int.parse(vr[1]!);
    final a = int.parse(vr[2]!);
    final s2 = vr[3] == null ? null : int.parse(vr[3]!);
    final e = vr[4] == null ? null : int.parse(vr[4]!);
    if (s2 != null && s2 != s) return null;
    return _validated(s, a, e, validate);
  }

  // Bare numbers only count as Quran references with a Quran keyword or a
  // recognised surah name.
  if (!hasQuranWord && nameNumber == null) return null;

  // 2. "Surah 2, ayah 255" / "2 verse 255-256".
  final sv = _surahVerseWords.firstMatch(text);
  if (sv != null) {
    final e = sv[3] == null ? null : int.parse(sv[3]!);
    return _validated(int.parse(sv[1]!), int.parse(sv[2]!), e, validate);
  }

  // 3. "Al-Baqarah, verse 255".
  if (nameNumber != null) {
    final nv = _nameVerseWords.firstMatch(text);
    if (nv != null) {
      final e = nv[2] == null ? null : int.parse(nv[2]!);
      return _validated(nameNumber, int.parse(nv[1]!), e, validate);
    }
  }

  // 4. Whole surah: "Surah 112", "Al-Ikhlas (112)", "Quran 112".
  final num = RegExp(r'(?<![\d:])(\d{1,3})(?![\d:])').firstMatch(text);
  if (num != null) {
    final s = int.parse(num[1]!);
    if (s >= 1 && (s <= 114 || !validate)) return (s, 1, 0);
    return null;
  }

  // 5. Name only: "Surah Al-Ikhlas".
  if (nameNumber != null) return (nameNumber, 1, 0);
  return null;
}

/// Formats a reference as "Quran 2:255" / "Quran 2:201-202" / "Quran 112".
String formatQuranRef((int, int, int) ref) {
  final (s, a, e) = ref;
  if (e == 0) return 'Quran $s';
  if (e == a) return 'Quran $s:$a';
  return 'Quran $s:$a-$e';
}
