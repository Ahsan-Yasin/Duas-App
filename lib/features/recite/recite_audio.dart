import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;

import '../../core/audio/dua_player.dart';
import '../../core/audio/quran_audio.dart';
import '../../core/models/models.dart';

/// What kind of audio a dua can offer on the recite screen.
enum ReciteAudioSource {
  /// Downloaded per-ayah Quran recitation (everyayah.com).
  reciter,

  /// A user-attached audio file.
  file,

  /// Device text-to-speech only (not a reciter).
  deviceVoice,

  /// No audio at all; device voice is still offered.
  none,
}

ReciteAudioSource audioSourceFor(Dua d) {
  switch (d.audioKind) {
    case AudioKind.quran:
      return d.isQuran ? ReciteAudioSource.reciter : ReciteAudioSource.none;
    case AudioKind.file:
      return (d.audioPath ?? '').trim().isNotEmpty
          ? ReciteAudioSource.file
          : ReciteAudioSource.none;
    case AudioKind.tts:
      return ReciteAudioSource.deviceVoice;
    case AudioKind.none:
      return ReciteAudioSource.none;
  }
}

const offlineAudioMessage =
    'Audio not downloaded yet — connect to the internet once';

/// Per-screen audio state for the recite screen: resolves the current dua's
/// audio (downloading Quran ayahs when needed), drives the shared
/// [DuaPlayer], and offers device text-to-speech as a fallback.
class ReciteAudioController extends ChangeNotifier {
  ReciteAudioController({
    required this.player,
    required this.quranAudio,
    FlutterTts Function()? createTts,
  }) : _createTts = createTts ?? FlutterTts.new {
    _subs
      ..add(player.playingStream.listen(_onPlaying))
      ..add(player.currentIndexStream.listen(_onIndex))
      ..add(player.passCompletedStream.listen(_onPass));
  }

  final DuaPlayer player;
  final QuranAudioCache quranAudio;
  final FlutterTts Function() _createTts;
  final List<StreamSubscription<dynamic>> _subs = [];

  /// Called after each full pass of the current playback (follow-along).
  void Function(int pass)? onPass;

  Dua? _dua;
  int _gen = 0;
  bool _disposed = false;
  bool _userPaused = false;
  FlutterTts? _tts;
  String? _ttsLanguage;
  String? _cachedFor;
  List<String>? _files;

  bool downloading = false;
  int downloadDone = 0;
  int downloadTotal = 0;
  String? error;
  bool playing = false;

  /// A playlist for the current dua is loaded and can be paused/resumed.
  bool loaded = false;

  /// Index of the ayah currently heard (follow-along highlight).
  int? ayahIndex;
  bool speaking = false;

  Dua? get dua => _dua;

  ReciteAudioSource get source =>
      _dua == null ? ReciteAudioSource.none : audioSourceFor(_dua!);

  /// True when the dua has real recitation audio (reciter or user file).
  bool get hasRecording =>
      source == ReciteAudioSource.reciter || source == ReciteAudioSource.file;

  bool get isPaused => loaded && !playing && _userPaused;

  /// True while something can be paused or resumed.
  bool get canPause => loaded || speaking;

  /// Switches to [dua] and stops whatever was playing for the previous one.
  Future<void> select(Dua? dua) async {
    _gen++;
    _dua = dua;
    _files = null;
    _cachedFor = null;
    error = null;
    downloading = false;
    downloadDone = 0;
    downloadTotal = 0;
    loaded = false;
    _userPaused = false;
    ayahIndex = null;
    _notify();
    await _stopAll();
  }

  /// Plays the current dua [repeat] times. Returns false when audio could not
  /// be started ([error] then holds a friendly message).
  Future<bool> play({
    required int repeat,
    required String reciter,
    required double speed,
  }) async {
    final dua = _dua;
    if (dua == null || !hasRecording) return false;
    final gen = ++_gen;
    error = null;
    _userPaused = false;
    await _stopTts();
    final files = await _resolveFiles(dua, reciter, gen);
    if (files == null || gen != _gen || _disposed) return false;
    try {
      await player.playFiles(
        files,
        repeat: repeat,
        speed: speed,
        title: dua.title,
        subtitle: source == ReciteAudioSource.reciter
            ? reciterName(reciter)
            : 'Daily Duas',
      );
      if (gen != _gen || _disposed) return false;
      loaded = true;
      _notify();
      return true;
    } catch (e) {
      debugPrint('Recite audio failed: $e');
      if (gen != _gen || _disposed) return false;
      loaded = false;
      error = 'Could not play this audio.';
      _notify();
      return false;
    }
  }

  Future<void> pause() async {
    if (speaking) {
      await _stopTts();
      return;
    }
    if (!loaded) return;
    _userPaused = true;
    await player.pause();
    _notify();
  }

  Future<void> resume() async {
    if (!loaded) return;
    _userPaused = false;
    await player.resume();
    _notify();
  }

  Future<void> togglePause() => playing ? pause() : resume();

  /// Stops audio and TTS but keeps the current dua selected.
  Future<void> stop() async {
    _gen++;
    loaded = false;
    _userPaused = false;
    ayahIndex = null;
    _notify();
    await _stopAll();
  }

  Future<void> setSpeed(double speed) => player.setSpeed(speed);

  /// Reads [text] (Arabic) aloud with the device voice; tapping again stops.
  Future<void> speak(String text, double speed) async {
    if (speaking) {
      await _stopTts();
      return;
    }
    final gen = _gen;
    error = null;
    try {
      if (loaded) {
        loaded = false;
        await player.stop();
      }
      final tts = _tts ??= _initTts();
      final lang = _ttsLanguage ?? await _pickArabicVoice(tts);
      if (lang == null) {
        error = 'No Arabic voice on this device. Add one in Android '
            'text-to-speech settings.';
        _notify();
        return;
      }
      _ttsLanguage = lang;
      await tts.setSpeechRate((0.5 * speed).clamp(0.1, 1.0));
      if (gen != _gen || _disposed) return;
      speaking = true;
      _notify();
      await tts.speak(text);
    } catch (e) {
      debugPrint('TTS failed: $e');
      error = 'The device voice is not available.';
    } finally {
      if (gen == _gen) speaking = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _gen++;
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    // The player is app-wide; only stop it.
    player.stop().catchError((Object _) {});
    _tts?.stop().catchError((Object _) {});
    super.dispose();
  }

  // ---------------------------------------------------------------------------

  Future<List<String>?> _resolveFiles(Dua dua, String reciter, int gen) async {
    final cacheKey = '${dua.id}|$reciter';
    if (_files != null && _cachedFor == cacheKey) return _files;
    switch (source) {
      case ReciteAudioSource.file:
        final path = dua.audioPath!;
        if (!await File(path).exists()) {
          error = 'Audio file not found — attach it again in the dua editor.';
          _notify();
          return null;
        }
        _files = [path];
        _cachedFor = cacheKey;
        return _files;
      case ReciteAudioSource.reciter:
        final s = dua.quranSurah!;
        final start = dua.quranAyahStart ?? 1;
        final end = dua.quranAyahEnd ?? start;
        downloading = true;
        downloadDone = 0;
        downloadTotal = end - start + 1;
        _notify();
        try {
          final files = await quranAudio.ensureAyahs(
            reciter,
            s,
            start,
            end,
            onProgress: (done, total) {
              if (gen != _gen || _disposed) return;
              downloadDone = done;
              downloadTotal = total;
              _notify();
            },
          );
          if (gen != _gen || _disposed) return null;
          downloading = false;
          _files = [for (final f in files) f.path];
          _cachedFor = cacheKey;
          _notify();
          return _files;
        } catch (e) {
          debugPrint('Quran audio download failed: $e');
          if (gen != _gen || _disposed) return null;
          downloading = false;
          error = _isNetworkError(e)
              ? offlineAudioMessage
              : e is QuranAudioException
                  ? e.message
                  : 'Could not download the recitation. Please try again.';
          _notify();
          return null;
        }
      case ReciteAudioSource.deviceVoice:
      case ReciteAudioSource.none:
        return null;
    }
  }

  static bool _isNetworkError(Object e) =>
      (e is QuranAudioException && e.offline) ||
      e is SocketException ||
      e is TimeoutException ||
      e is HttpException ||
      e is http.ClientException ||
      e is HandshakeException;

  FlutterTts _initTts() {
    final tts = _createTts();
    tts.awaitSpeakCompletion(true).catchError((Object _) {});
    void done() {
      if (!speaking) return;
      speaking = false;
      _notify();
    }

    tts
      ..setCompletionHandler(done)
      ..setCancelHandler(done)
      ..setErrorHandler((_) => done());
    return tts;
  }

  Future<String?> _pickArabicVoice(FlutterTts tts) async {
    final raw = await tts.getLanguages;
    final langs = raw is List ? raw.map((e) => '$e').toList() : <String>[];
    final ar = langs.where((l) => l.toLowerCase().startsWith('ar')).toList()
      ..sort((a, b) => a.length.compareTo(b.length));
    final candidates = ar.isEmpty ? const ['ar'] : ar;
    for (final tag in candidates) {
      final ok = await tts.setLanguage(tag);
      if (ok == 1 || ok == true) return tag;
    }
    return null;
  }

  Future<void> _stopTts() async {
    if (!speaking) return;
    speaking = false;
    _notify();
    try {
      await _tts?.stop();
    } catch (e) {
      debugPrint('TTS stop failed: $e');
    }
  }

  Future<void> _stopAll() async {
    await _stopTts();
    await player.stop();
  }

  void _onPlaying(bool value) {
    playing = value;
    if (!value && !_userPaused) {
      // Finished (or interrupted): nothing left to resume.
      loaded = false;
      ayahIndex = null;
    }
    _notify();
  }

  void _onIndex(int? index) {
    if (ayahIndex == index) return;
    ayahIndex = index;
    _notify();
  }

  void _onPass(int pass) {
    if (_disposed) return;
    onPass?.call(pass);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
