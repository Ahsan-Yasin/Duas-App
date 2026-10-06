import 'dart:io';

import 'package:daily_duas/core/audio/quran_audio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('quran_audio_test');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('ayahUrl pads surah and ayah to 3 digits', () {
    expect(ayahUrl('Alafasy_128kbps', 2, 255), 'https://everyayah.com/data/Alafasy_128kbps/002255.mp3');
    expect(ayahUrl('Alafasy_128kbps', 112, 1), 'https://everyayah.com/data/Alafasy_128kbps/112001.mp3');
    expect(ayahUrl('Husary_64kbps', 1, 7), 'https://everyayah.com/data/Husary_64kbps/001007.mp3');
    expect(ayahFileName(114, 6), '114006.mp3');
  });

  test('reciters, default and attribution', () {
    expect(reciters.first.$1, 'Alafasy_128kbps');
    expect(defaultReciter, reciters.first.$1);
    expect(reciters.map((r) => r.$1).toSet(), hasLength(reciters.length));
    expect(audioAttribution, 'Recitation audio from EveryAyah.com');
    expect(reciterName('Alafasy_128kbps'), 'Mishary Rashid Alafasy');
    expect(reciterName('Unknown_folder'), 'Unknown_folder');
    expect(
      reciterAttribution('Alafasy_64kbps'),
      'Recitation audio: Mishary Rashid Alafasy, verse-by-verse recordings from EveryAyah.com.',
    );
  });

  test('cache path is <base>/audio/<reciter>/SSSAAA.mp3', () async {
    final cache = QuranAudioCache(baseDir: () async => tmp, client: MockClient((_) async => http.Response('', 404)));
    final f = await cache.fileFor('Alafasy_128kbps', 2, 255);
    expect(f.path, p.join(tmp.path, 'audio', 'Alafasy_128kbps', '002255.mp3'));
    expect(await cache.isCached('Alafasy_128kbps', 2, 255), isFalse);
  });

  test('ensureAyahs downloads missing files, skips existing, reports progress', () async {
    final requested = <String>[];
    final mock = MockClient((req) async {
      requested.add(req.url.toString());
      return http.Response.bytes(List<int>.filled(100, 7), 200, headers: {'content-type': 'audio/mpeg'});
    });
    final cache = QuranAudioCache(baseDir: () async => tmp, client: mock);

    // Pre-existing 112:2 must not be downloaded again.
    final existing = await cache.fileFor('Alafasy_128kbps', 112, 2);
    await existing.parent.create(recursive: true);
    await existing.writeAsBytes([1, 2, 3]);

    final progress = <(int, int)>[];
    final files = await cache.ensureAyahs('Alafasy_128kbps', 112, 1, 4,
        onProgress: (d, t) => progress.add((d, t)));

    expect(files.map((f) => p.basename(f.path)), ['112001.mp3', '112002.mp3', '112003.mp3', '112004.mp3']);
    expect(requested, hasLength(3));
    expect(requested, isNot(contains('https://everyayah.com/data/Alafasy_128kbps/112002.mp3')));
    expect(await existing.readAsBytes(), [1, 2, 3]);
    expect(progress.first, (0, 4));
    expect(progress.last, (4, 4));
    for (final f in files) {
      expect(await f.exists(), isTrue);
      expect(await File('${f.path}.part').exists(), isFalse);
    }
    expect(await cache.cacheSizeBytes(), 3 * 100 + 3);

    // Second call: everything cached, no requests.
    requested.clear();
    await cache.ensureAyahs('Alafasy_128kbps', 112, 1, 4);
    expect(requested, isEmpty);

    await cache.clear();
    expect(await cache.cacheSizeBytes(), 0);
  });

  test('HTTP errors throw and leave no partial file', () async {
    final cache = QuranAudioCache(baseDir: () async => tmp, client: MockClient((_) async => http.Response('nope', 404)));
    await expectLater(cache.ensureAyahs('Alafasy_128kbps', 1, 1, 1), throwsA(isA<QuranAudioException>()));
    final f = await cache.fileFor('Alafasy_128kbps', 1, 1);
    expect(await f.exists(), isFalse);
    expect(await File('${f.path}.part').exists(), isFalse);
  });

  test('offline errors are flagged', () async {
    final cache = QuranAudioCache(
      baseDir: () async => tmp,
      client: MockClient((_) async => throw http.ClientException('Failed host lookup')),
    );
    await expectLater(
      cache.ensureAyahs('Alafasy_128kbps', 1, 1, 2),
      throwsA(isA<QuranAudioException>().having((e) => e.offline, 'offline', isTrue)),
    );
  });

  test('invalid ranges are rejected', () async {
    final cache = QuranAudioCache(baseDir: () async => tmp, client: MockClient((_) async => http.Response('', 200)));
    expect(cache.ensureAyahs('Alafasy_128kbps', 112, 1, 5), throwsA(isA<QuranAudioException>()));
    expect(cache.ensureAyahs('Alafasy_128kbps', 0, 1, 1), throwsA(isA<QuranAudioException>()));
    expect(cache.ensureAyahs('Alafasy_128kbps', 2, 3, 2), throwsA(isA<QuranAudioException>()));
  });
}
