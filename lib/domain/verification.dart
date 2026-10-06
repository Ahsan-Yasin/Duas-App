/// Checks a dua's Arabic against the bundled Quran text. Pure Dart.
///
/// A result is "verified" only when the letters (see [normalizeArabic]) match
/// the Tanzil text. Hadith wording cannot be checked offline and is always
/// "unverified" with a note asking the user to confirm it.
library;

import 'package:daily_duas/core/models/models.dart' show VerificationStatus;

import 'arabic.dart';
import 'quran_index.dart';

class VerificationResult {
  const VerificationResult({
    required this.status,
    required this.kind,
    required this.note,
    this.matchedRef,
  });

  final VerificationStatus status;

  /// 'quran', 'hadith' or 'unknown'.
  final String kind;

  /// Human-readable explanation shown next to the dua.
  final String note;

  /// The Quran range the text matched (verified results), or where the text
  /// was found when it did not match the claimed reference.
  final (int, int, int)? matchedRef;

  bool get isVerified => status == VerificationStatus.verified;

  @override
  String toString() =>
      'VerificationResult(${status.name}, $kind, $matchedRef, "$note")';
}

/// Minimum normalized length for a partial-ayah match.
const int partialMatchMinLength = 12;

const String hadithNote =
    'Hadith wording – confirm with a reliable source or teacher.';

final RegExp _hadithSource = RegExp(
  r"(bukh[a]?ri|muslim|d[a]?wud|dawood|tirmidh?i|nas[a]?['’]?i|majah|ahmad|musnad|muwatta|hadith|hadeeth|sunan|sahih|saheeh|riyad|hisn|adab al|bayhaqi|darimi|hibban|hakim|tabarani|mishkat|bulugh|nawawi|reported by|narrated)",
  caseSensitive: false,
);

/// Verifies [arabic] against the Quran.
///
/// * A Quran claim (from [claimedQuran] `{surah, ayah_start, ayah_end}` or
///   parsed from [source]) is verified when the normalized text equals the
///   referenced range, or is a word-aligned contiguous part of it with at least
///   [partialMatchMinLength] normalized characters ("partial ayah"). A leading
///   Bismillah in the text is tolerated.
/// * Without a reference, text found verbatim in the Quran is verified with
///   the found reference.
/// * Anything else is unverified (hadith or unknown source).
VerificationResult verifyDua({
  required String arabic,
  required String source,
  required QuranIndex quran,
  Map<String, dynamic>? claimedQuran,
}) {
  final norm = normalizeArabic(arabic);
  if (norm.isEmpty) {
    return const VerificationResult(
      status: VerificationStatus.unverified,
      kind: 'unknown',
      note: 'There is no Arabic text to check.',
    );
  }

  final candidates = <String>[norm];
  if (norm.startsWith('$bismillahNormalized ')) {
    final rest = norm.substring(bismillahNormalized.length + 1);
    if (rest.isNotEmpty) candidates.add(rest);
  }

  final claimed =
      _claimFromMap(claimedQuran) ?? parseQuranRef(source, validate: false);
  if (claimed != null) {
    final resolved = quran.resolve(claimed);
    final label = formatQuranRef(claimed);
    if (resolved == null) {
      return VerificationResult(
        status: VerificationStatus.unverified,
        kind: 'quran',
        note: '$label is not a valid Quran reference. '
            'Check with a teacher or a mushaf.',
        matchedRef: _findAnywhere(quran, candidates),
      );
    }
    final (s, a, e) = resolved;
    final target = quran.normalizedRange(s, a, e);
    final refLabel = formatQuranRef(resolved);
    for (final c in candidates) {
      if (c == target) {
        return VerificationResult(
          status: VerificationStatus.verified,
          kind: 'quran',
          note: 'Matches the Quran text at $refLabel.',
          matchedRef: resolved,
        );
      }
    }
    for (final c in candidates) {
      if (c.length >= partialMatchMinLength && ' $target '.contains(' $c ')) {
        return VerificationResult(
          status: VerificationStatus.verified,
          kind: 'quran',
          note: 'Matches the Quran text at $refLabel (partial ayah).',
          matchedRef: resolved,
        );
      }
    }
    final elsewhere = _findAnywhere(quran, candidates);
    final hint = elsewhere == null
        ? ''
        : ' (The same text appears at ${formatQuranRef(elsewhere)}.)';
    return VerificationResult(
      status: VerificationStatus.unverified,
      kind: 'quran',
      note: 'Text does not match the Quran at $refLabel. '
          'Check with a teacher or a mushaf.$hint',
      matchedRef: elsewhere,
    );
  }

  final found = _findAnywhere(quran, candidates);
  if (found != null) {
    return VerificationResult(
      status: VerificationStatus.verified,
      kind: 'quran',
      note: 'Found word for word in the Quran at ${formatQuranRef(found)}.',
      matchedRef: found,
    );
  }

  if (_hadithSource.hasMatch(source)) {
    return const VerificationResult(
      status: VerificationStatus.unverified,
      kind: 'hadith',
      note: hadithNote,
    );
  }
  return VerificationResult(
    status: VerificationStatus.unverified,
    kind: 'unknown',
    note: source.trim().isEmpty
        ? 'No source given – confirm the wording with a reliable source or teacher.'
        : hadithNote,
  );
}

(int, int, int)? _findAnywhere(QuranIndex quran, List<String> candidates) {
  for (final c in candidates) {
    final hits = quran.find(c, minLen: partialMatchMinLength);
    if (hits.isNotEmpty) return hits.first;
  }
  return null;
}

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

(int, int, int)? _claimFromMap(Map<String, dynamic>? m) {
  if (m == null) return null;
  final s = _asInt(m['surah']);
  final a = _asInt(m['ayah_start'] ?? m['ayahStart'] ?? m['ayah']);
  if (s == null || a == null) return null;
  final e = _asInt(m['ayah_end'] ?? m['ayahEnd']) ?? a;
  return (s, a, e);
}
