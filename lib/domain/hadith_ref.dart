import 'quran_index.dart';

/// A reference to one hadith in a collection of the public-domain
/// fawazahmed0/hadith-api dataset.
class HadithRef {
  const HadithRef({
    required this.collection,
    required this.number,
    required this.displayName,
  });

  /// API slug, e.g. 'bukhari'.
  final String collection;
  final int number;

  /// e.g. 'Sahih al-Bukhari'.
  final String displayName;

  String get label => '$displayName $number';

  String get sunnahUrl {
    final slug = switch (collection) {
      'nawawi' => 'nawawi40',
      'qudsi' => 'qudsi40',
      _ => collection,
    };
    return 'https://sunnah.com/$slug:$number';
  }

  String get apiUrl =>
      'https://cdn.jsdelivr.net/gh/fawazahmed0/hadith-api@1/editions/'
      'ara-$collection/$number.json';

  @override
  bool operator ==(Object other) =>
      other is HadithRef &&
      other.collection == collection &&
      other.number == number;

  @override
  int get hashCode => Object.hash(collection, number);

  @override
  String toString() => 'HadithRef($collection, $number)';
}

// (slug, display name, pattern on the cleaned lower-case source)
final List<(String, String, RegExp)> _collections = [
  ('bukhari', 'Sahih al-Bukhari', RegExp(r'bukh?aa?ri')),
  ('muslim', 'Sahih Muslim', RegExp(r'\bmuslim\b')),
  ('abudawud', 'Sunan Abi Dawud', RegExp(r'\bab[ui]\s?daw?[uo]{1,2}d\b')),
  ('tirmidhi', 'Jami at-Tirmidhi', RegExp(r'tirmi(dh|d|z|th)i')),
  ('nasai', "Sunan an-Nasa'i", RegExp(r'\bnas[a]{1,2}i\b|\bnisai\b')),
  ('ibnmajah', 'Sunan Ibn Majah', RegExp(r'\bibn\s?maa?jah?\b')),
  ('malik', 'Muwatta Malik', RegExp(r'muwatt?a')),
  ('nawawi', '40 Hadith Nawawi', RegExp(r'nawawi')),
  ('qudsi', '40 Hadith Qudsi', RegExp(r'qudsi')),
  ('dehlawi', '40 Hadith Shah Waliullah Dehlawi', RegExp(r'de?hlawi|dihlawi')),
];

/// Books that are not in the dataset; a citation that names one of these
/// before any known collection is not checked.
final RegExp _excluded = RegExp(
  r'riyad|riyaadh|salihin|hisn|fortress|adab\s?al\s?mufrad|mufrad|mishkat|'
  r'bulugh',
);

/// Parses a hadith citation such as "Sahih al-Bukhari 3371", "Muslim #2720",
/// "Abu Dawud 5088" or "Sunan an-Nasa'i 5500". Returns null for Quran
/// references, books outside the dataset and citations without a number.
HadithRef? parseHadithRef(String source) {
  final text = source
      .toLowerCase()
      .replaceAll(RegExp(r"[’'ʿʾ`‘]"), '')
      .replaceAll(RegExp(r'[^a-z0-9:/]+'), ' ')
      .trim();
  if (text.isEmpty) return null;

  (String, String, Match)? best;
  for (final (slug, name, re) in _collections) {
    final m = re.firstMatch(text);
    if (m != null && (best == null || m.start < best.$3.start)) {
      best = (slug, name, m);
    }
  }
  if (best == null) return null;
  final (slug, name, match) = best;

  final ex = _excluded.firstMatch(text);
  if (ex != null && ex.start < match.start) return null;

  final rest = text.substring(match.end);
  int? number;
  final hadithWord = RegExp(r'hadith\s*(?:no\s*)?(\d+)').firstMatch(rest);
  if (hadithWord != null) {
    number = int.parse(hadithWord[1]!);
  } else {
    final m = RegExp(r'(\d+)[a-z]*\s*([:/]\s*\d+)?').firstMatch(rest);
    if (m == null || m[2] != null) return null; // volume:number style
    number = int.parse(m[1]!);
  }
  if (number <= 0) return null;
  return HadithRef(collection: slug, number: number, displayName: name);
}

/// A link to read [source] online: quran.com for Quran references,
/// sunnah.com for hadith references, otherwise null.
String? sourceUrl(String source) {
  final q = parseQuranRef(source);
  if (q != null) {
    final (s, a, e) = q;
    if (e == 0) return 'https://quran.com/$s';
    if (e == a) return 'https://quran.com/$s/$a';
    return 'https://quran.com/$s/$a-$e';
  }
  return parseHadithRef(source)?.sunnahUrl;
}
