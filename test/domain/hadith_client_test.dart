import 'dart:convert';
import 'dart:io';

import 'package:daily_duas/core/models/models.dart';
import 'package:daily_duas/core/net/hadith_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _hadithText =
    'حَدَّثَنَا عُثْمَانُ بْنُ أَبِي شَيْبَةَ، كَانَ النَّبِيُّ صلى الله عليه وسلم '
    'يَقُولُ ‏"‏ أَعُوذُ بِكَلِمَاتِ اللَّهِ التَّامَّةِ مِنْ كُلِّ شَيْطَانٍ وَهَامَّةٍ، '
    'وَمِنْ كُلِّ عَيْنٍ لاَمَّةٍ ‏"‏‏.‏';

const _dua = 'أَعُوذُ بِكَلِمَاتِ اللَّهِ التَّامَّةِ مِنْ كُلِّ شَيْطَانٍ وَهَامَّةٍ';

http.Response _body(List<Map<String, Object>> grades) => http.Response.bytes(
      utf8.encode(jsonEncode({
        'metadata': {'name': 'Sahih al Bukhari'},
        'hadiths': [
          {'hadithnumber': 3371, 'text': _hadithText, 'grades': grades},
        ],
      })),
      200,
      headers: {'content-type': 'application/json'},
    );

HadithClient _client(Future<http.Response> Function(http.Request) handler) =>
    HadithClient(client: MockClient(handler));

void main() {
  test('found + matching wording -> verified, requests the jsDelivr url', () async {
    Uri? requested;
    final r = await _client((req) async {
      requested = req.url;
      return _body(const []);
    }).verify(arabic: _dua, source: 'Sahih al-Bukhari 3371');
    expect(requested.toString(),
        'https://cdn.jsdelivr.net/gh/fawazahmed0/hadith-api@1/editions/ara-bukhari/3371.json');
    expect(r.status, VerificationStatus.verified);
    expect(r.note, 'Wording found in Sahih al-Bukhari 3371.');
    expect(r.ref!.collection, 'bukhari');
  });

  test('found with sahih grade -> verified with grade in note', () async {
    final r = await _client((_) async => _body(const [
          {'name': 'Al-Albani', 'grade': 'Sahih'},
        ])).verify(arabic: _dua, source: 'Abu Dawud 5088');
    expect(r.status, VerificationStatus.verified);
    expect(r.grades, ['Sahih (Al-Albani)']);
    expect(r.note, contains('Grade: Sahih (Al-Albani)'));
  });

  test('weak grade -> unverified', () async {
    final r = await _client((_) async => _body(const [
          {'name': 'Al-Albani', 'grade': "Da'if"},
        ])).verify(arabic: _dua, source: 'Abu Dawud 5088');
    expect(r.status, VerificationStatus.unverified);
    expect(r.note, contains('graded weak'));
  });

  test('found + different wording -> unverified', () async {
    final r = await _client((_) async => _body(const [])).verify(
      arabic: 'رَبَّنَا آتِنَا فِي الدُّنْيَا حَسَنَةً',
      source: 'Bukhari 3371',
    );
    expect(r.status, VerificationStatus.unverified);
    expect(r.note, contains('wording does not match'));
  });

  test('404 -> unverified not found', () async {
    final r = await _client((_) async => http.Response('Not found', 404))
        .verify(arabic: _dua, source: 'Bukhari 999999');
    expect(r.status, VerificationStatus.unverified);
    expect(r.note, contains('was not found'));
  });

  test('SocketException -> unverified offline, never throws', () async {
    final r = await _client((_) async => throw const SocketException('offline'))
        .verify(arabic: _dua, source: 'Bukhari 3371');
    expect(r.status, VerificationStatus.unverified);
    expect(r.note, contains('Could not check online'));
  });

  test('no hadith reference -> unverified without a request', () async {
    var calls = 0;
    final r = await _client((_) async {
      calls++;
      return _body(const []);
    }).verify(arabic: _dua, source: 'Hisn al-Muslim 75');
    expect(calls, 0);
    expect(r.status, VerificationStatus.unverified);
    expect(r.note, startsWith('No hadith reference'));
  });
}
