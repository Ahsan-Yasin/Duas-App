import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/arabic.dart';
import '../../domain/hadith_ref.dart';
import '../models/models.dart';

/// Result of checking a hadith dua against the online collection.
class HadithVerification {
  const HadithVerification({
    required this.status,
    required this.note,
    this.ref,
    this.grades = const [],
  });

  final VerificationStatus status;
  final String note;
  final HadithRef? ref;

  /// e.g. "Sahih (Al-Albani)".
  final List<String> grades;
}

/// Checks hadith duas against the public-domain fawazahmed0/hadith-api
/// dataset served by jsDelivr.
class HadithClient {
  HadithClient({http.Client? client, this.timeout = const Duration(seconds: 20)})
      : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  static const _noRef =
      'No hadith reference to check – confirm with a reliable source or teacher.';
  static const _offline = 'Could not check online (no internet?). Try again later.';

  /// Never throws.
  Future<HadithVerification> verify({
    required String arabic,
    required String source,
  }) async {
    final ref = parseHadithRef(source);
    if (ref == null) {
      return const HadithVerification(
        status: VerificationStatus.unverified,
        note: _noRef,
      );
    }
    HadithVerification unverified(String note, [List<String> grades = const []]) =>
        HadithVerification(
          status: VerificationStatus.unverified,
          note: note,
          ref: ref,
          grades: grades,
        );
    final notFound = unverified(
      'Hadith ${ref.label} was not found in the online collection '
      '(numbering can differ between editions). Check the source yourself.',
    );

    final http.Response res;
    try {
      res = await _client.get(Uri.parse(ref.apiUrl)).timeout(timeout);
    } catch (_) {
      return unverified(_offline);
    }
    if (res.statusCode == 404) return notFound;
    if (res.statusCode != 200) return unverified(_offline);

    final texts = <String>[];
    final grades = <String>[];
    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      final hadiths = body is Map ? body['hadiths'] : null;
      if (hadiths is List) {
        for (final h in hadiths) {
          if (h is! Map) continue;
          final t = h['text'];
          if (t is String && t.trim().isNotEmpty) texts.add(t);
          final g = h['grades'];
          if (g is List) {
            for (final e in g) {
              if (e is Map && e['grade'] is String) {
                final name = e['name'];
                grades.add(name is String && name.isNotEmpty
                    ? '${e['grade']} ($name)'
                    : '${e['grade']}');
              }
            }
          }
        }
      }
    } catch (_) {
      return notFound;
    }
    if (texts.isEmpty) return notFound;

    final duaWords = normalizeArabic(arabic)
        .split(' ')
        .where((w) => w.isNotEmpty)
        .toList();
    if (duaWords.length < 3) {
      return unverified(
        'Found ${ref.label}, but the dua is too short to match reliably. '
        'Check with a teacher.',
        grades,
      );
    }
    final needle = ' ${duaWords.join(' ')} ';
    final haystack = ' ${normalizeArabic(texts.join(' '))} ';
    if (!haystack.contains(needle)) {
      return unverified(
        'Found ${ref.label}, but the wording does not match. Check with a teacher.',
        grades,
      );
    }

    final gradeText = grades.join('; ');
    if (grades.any(_isWeak)) {
      return unverified(
        'Wording found in ${ref.label}, but it is graded weak ($gradeText).',
        grades,
      );
    }
    return HadithVerification(
      status: VerificationStatus.verified,
      note: 'Wording found in ${ref.label}.'
          '${grades.isEmpty ? '' : ' Grade: $gradeText.'}',
      ref: ref,
      grades: grades,
    );
  }

  static bool _isWeak(String grade) {
    final g = grade.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    return g.contains('daif') ||
        g.contains('weak') ||
        g.contains('mawdu') ||
        g.contains('fabricated');
  }
}
