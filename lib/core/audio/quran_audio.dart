/// Verse-by-verse Quran recitation from EveryAyah.com: reciter list, URLs and
/// an on-disk cache (`<baseDir>/audio/<reciter>/SSSAAA.mp3`).
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../domain/quran_index.dart' show surahAyahCounts;

/// `(folder, display name)`. Every folder was verified complete on
/// everyayah.com (docs/research/content.md §4). The first entry is the default.
const reciters = <(String, String)>[
  ('Alafasy_128kbps', 'Mishary Rashid Alafasy'),
  ('Alafasy_64kbps', 'Mishary Rashid Alafasy (smaller download)'),
  ('Abdul_Basit_Murattal_192kbps', 'Abdul Basit Abdus-Samad (Murattal)'),
  ('Abdul_Basit_Murattal_64kbps', 'Abdul Basit Abdus-Samad (Murattal, smaller download)'),
  ('Husary_128kbps', 'Mahmoud Khalil Al-Husary'),
  ('Husary_64kbps', 'Mahmoud Khalil Al-Husary (smaller download)'),
  ('Minshawy_Murattal_128kbps', 'Mohamed Siddiq Al-Minshawi (Murattal)'),
  ('Abdurrahmaan_As-Sudais_192kbps', 'Abdur-Rahman As-Sudais'),
  ('Abdurrahmaan_As-Sudais_64kbps', 'Abdur-Rahman As-Sudais (smaller download)'),
  ('Saood_ash-Shuraym_128kbps', 'Saud Ash-Shuraim'),
  ('Saood_ash-Shuraym_64kbps', 'Saud Ash-Shuraim (smaller download)'),
  ('MaherAlMuaiqly128kbps', 'Maher Al-Muaiqly'),
  ('Maher_AlMuaiqly_64kbps', 'Maher Al-Muaiqly (smaller download)'),
  ('Hudhaify_128kbps', 'Ali Al-Hudhaify'),
  ('Hudhaify_64kbps', 'Ali Al-Hudhaify (smaller download)'),
];

const String defaultReciter = 'Alafasy_128kbps';

/// Short credit line for the recitation audio.
const String audioAttribution = 'Recitation audio from EveryAyah.com';

/// Display name of a reciter folder (the folder itself when unknown).
String reciterName(String folder) {
  for (final (f, name) in reciters) {
    if (f == folder) return name;
  }
  return folder;
}

/// "Recitation audio: Mishary Rashid Alafasy, verse-by-verse recordings from EveryAyah.com."
String reciterAttribution(String folder) {
  final name = reciterName(folder).replaceAll(RegExp(r'\s*\(.*\)$'), '');
  return 'Recitation audio: $name, verse-by-verse recordings from EveryAyah.com.';
}

String _pad3(int n) => n.toString().padLeft(3, '0');

/// `SSSAAA.mp3`, e.g. 2:255 → `002255.mp3`.
String ayahFileName(int surah, int ayah) => '${_pad3(surah)}${_pad3(ayah)}.mp3';

/// https://everyayah.com/data/{reciter}/{SSS}{AAA}.mp3
String ayahUrl(String reciter, int surah, int ayah) =>
    'https://everyayah.com/data/$reciter/${ayahFileName(surah, ayah)}';

class QuranAudioException implements Exception {
  const QuranAudioException(this.message, {this.offline = false});

  /// Friendly text for the UI.
  final String message;
  final bool offline;

  @override
  String toString() => 'QuranAudioException: $message';
}

class QuranAudioCache {
  QuranAudioCache({
    required this._baseDir,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 60),
    this.concurrency = 3,
  }) : _client = client ?? http.Client();

  final Future<Directory> Function() _baseDir;
  final http.Client _client;
  final Duration requestTimeout;

  /// Parallel downloads (kept small to be polite to everyayah.com).
  final int concurrency;

  final Map<String, Future<File>> _inFlight = {};

  Future<Directory> _audioRoot() async => Directory(p.join((await _baseDir()).path, 'audio'));

  /// Where `surah:ayah` of [reciter] is (or will be) stored.
  Future<File> fileFor(String reciter, int surah, int ayah) async {
    final root = await _audioRoot();
    return File(p.join(root.path, reciter, ayahFileName(surah, ayah)));
  }

  Future<bool> isCached(String reciter, int surah, int ayah) async {
    final f = await fileFor(reciter, surah, ayah);
    return await f.exists() && await f.length() > 0;
  }

  /// Whether every ayah in [start]..[end] is cached.
  Future<bool> areCached(String reciter, int surah, int start, int end) async {
    for (var a = start; a <= end; a++) {
      if (!await isCached(reciter, surah, a)) return false;
    }
    return true;
  }

  /// Makes sure ayat [start]..[end] of [surah] are on disk (downloading the
  /// missing ones) and returns their files in order. Existing files are
  /// skipped. [onProgress] is called with (done, total) after each ayah.
  /// Throws [QuranAudioException] on network or HTTP errors.
  Future<List<File>> ensureAyahs(
    String reciter,
    int surah,
    int start,
    int end, {
    void Function(int done, int total)? onProgress,
  }) async {
    if (surah < 1 ||
        surah > surahAyahCounts.length ||
        start < 1 ||
        end < start ||
        end > surahAyahCounts[surah - 1]) {
      throw QuranAudioException('Invalid Quran range $surah:$start-$end.');
    }
    final total = end - start + 1;
    final files = List<File?>.filled(total, null);
    var done = 0;
    var next = 0;
    onProgress?.call(0, total);

    Future<void> worker() async {
      while (next < total) {
        final i = next++;
        files[i] = await _ensureOne(reciter, surah, start + i);
        done++;
        onProgress?.call(done, total);
      }
    }

    final n = concurrency < 1 ? 1 : (concurrency > total ? total : concurrency);
    await Future.wait([for (var i = 0; i < n; i++) worker()]);
    return [for (final f in files) f!];
  }

  Future<File> _ensureOne(String reciter, int surah, int ayah) async {
    final file = await fileFor(reciter, surah, ayah);
    if (await file.exists() && await file.length() > 0) return file;
    final existing = _inFlight[file.path];
    if (existing != null) return existing;
    final future = _download(reciter, surah, ayah, file);
    _inFlight[file.path] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(file.path);
    }
  }

  Future<File> _download(String reciter, int surah, int ayah, File target) async {
    await target.parent.create(recursive: true);
    final part = File('${target.path}.part');
    final url = Uri.parse(ayahUrl(reciter, surah, ayah));
    IOSink? sink;
    try {
      final response = await _client.send(http.Request('GET', url)).timeout(requestTimeout);
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        throw QuranAudioException(response.statusCode == 404
            ? 'Recitation for $surah:$ayah is not available from this reciter.'
            : 'Could not download recitation for $surah:$ayah (HTTP ${response.statusCode}).');
      }
      sink = part.openWrite();
      await sink.addStream(response.stream.timeout(requestTimeout));
      await sink.flush();
      await sink.close();
      sink = null;
      if (await part.length() == 0) {
        throw QuranAudioException('Recitation for $surah:$ayah downloaded empty.');
      }
      return await part.rename(target.path);
    } on QuranAudioException {
      await _cleanup(sink, part);
      rethrow;
    } on TimeoutException {
      await _cleanup(sink, part);
      throw const QuranAudioException('Downloading the recitation timed out.', offline: true);
    } on SocketException {
      await _cleanup(sink, part);
      throw const QuranAudioException(
          'No internet connection. Recitation audio needs to be downloaded once.',
          offline: true);
    } on http.ClientException {
      await _cleanup(sink, part);
      throw const QuranAudioException(
          'No internet connection. Recitation audio needs to be downloaded once.',
          offline: true);
    } on FileSystemException {
      await _cleanup(sink, part);
      throw const QuranAudioException('Could not save the recitation audio on this device.');
    }
  }

  static Future<void> _cleanup(IOSink? sink, File part) async {
    try {
      await sink?.close();
    } catch (_) {
      // ignore
    }
    try {
      if (await part.exists()) await part.delete();
    } catch (_) {
      // ignore
    }
  }

  /// Total size of all cached audio in bytes.
  Future<int> cacheSizeBytes() async {
    final root = await _audioRoot();
    if (!await root.exists()) return 0;
    var total = 0;
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += await e.length();
        } on FileSystemException {
          // file vanished
        }
      }
    }
    return total;
  }

  /// Deletes all cached audio.
  Future<void> clear() async {
    final root = await _audioRoot();
    if (await root.exists()) await root.delete(recursive: true);
  }

  /// Deletes the cached audio of one reciter.
  Future<void> clearReciter(String reciter) async {
    final dir = Directory(p.join((await _audioRoot()).path, reciter));
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
