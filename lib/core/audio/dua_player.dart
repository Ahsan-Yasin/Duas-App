import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

/// App-wide recitation player (one instance, provided by `duaPlayerProvider`).
///
/// Wraps a single just_audio [AudioPlayer]. Every source carries a
/// just_audio_background [MediaItem] tag so lock-screen / notification
/// controls work and playback continues with the screen off. When
/// `JustAudioBackground.init` was never called (widget tests, non-Android)
/// the tags are simply ignored by the default platform.
///
/// The [AudioPlayer] is created lazily on the first [playFiles] call, so
/// constructing a [DuaPlayer] never touches a platform channel.
class DuaPlayer {
  DuaPlayer({AudioPlayer Function()? createPlayer})
      : _createPlayer = createPlayer ?? AudioPlayer.new;

  final AudioPlayer Function() _createPlayer;
  final StreamController<int?> _indexCtrl = StreamController<int?>.broadcast();
  final StreamController<bool> _playingCtrl =
      StreamController<bool>.broadcast();
  final StreamController<int> _passCtrl = StreamController<int>.broadcast();
  final List<StreamSubscription<dynamic>> _subs = [];

  AudioPlayer? _player;
  bool _disposed = false;

  /// Bumped on every new playlist / stop so stale async work is ignored.
  int _gen = 0;

  /// True between a successful [playFiles] and the end of the last pass
  /// (or [stop]).
  bool _active = false;
  bool _atEnd = false;
  int _repeat = 1;
  int _passesDone = 0;
  double _speed = 1.0;
  bool? _lastPlaying;

  /// Index of the file (within the list given to [playFiles]) that is
  /// currently playing; `null` when idle.
  Stream<int?> get currentIndexStream => _indexCtrl.stream;

  /// Whether audio is audibly playing right now.
  Stream<bool> get playingStream => _playingCtrl.stream;

  /// Emits the 1-based number of the pass that just finished, after each
  /// full pass through the playlist.
  Stream<int> get passCompletedStream => _passCtrl.stream;

  /// Plays [paths] in order, [repeat] times in total.
  ///
  /// Throws [PlayerException] (or another error) when the audio cannot be
  /// loaded, so the caller can show a friendly message.
  Future<void> playFiles(
    List<String> paths, {
    int repeat = 1,
    double speed = 1.0,
    String title = '',
    String? subtitle,
  }) async {
    if (_disposed) return;
    if (paths.isEmpty) {
      throw ArgumentError.value(paths, 'paths', 'No audio files to play');
    }
    final player = _ensurePlayer();
    final gen = ++_gen;
    _active = false;
    _atEnd = false;
    _emitPlaying(false);
    _indexCtrl.add(null);

    final itemTitle = title.trim().isEmpty ? 'Dua recitation' : title.trim();
    final sources = <AudioSource>[
      for (var i = 0; i < paths.length; i++)
        AudioSource.file(
          paths[i],
          tag: MediaItem(
            id: 'dua:$gen:$i',
            title: paths.length > 1
                ? '$itemTitle (${i + 1}/${paths.length})'
                : itemTitle,
            album: 'Daily Duas',
            artist: subtitle,
            displaySubtitle: subtitle,
          ),
        ),
    ];

    try {
      await player.pause();
      await player.setAudioSources(
        sources,
        initialIndex: 0,
        initialPosition: Duration.zero,
      );
    } on PlayerInterruptedException {
      return; // superseded by a newer playFiles/stop call
    }
    if (gen != _gen || _disposed) return;

    _speed = speed;
    await player.setLoopMode(LoopMode.off);
    await player.setSpeed(speed);
    if (gen != _gen || _disposed) return;

    _repeat = repeat < 1 ? 1 : repeat;
    _passesDone = 0;
    _active = true;
    _indexCtrl.add(0);
    _play(player);
  }

  Future<void> pause() async {
    final p = _player;
    if (p == null) return;
    try {
      await p.pause();
    } catch (e) {
      debugPrint('DuaPlayer.pause failed: $e');
    }
  }

  Future<void> resume() async {
    final p = _player;
    if (p == null || !_active) return;
    _play(p);
  }

  Future<void> stop() async {
    _gen++;
    _active = false;
    _atEnd = false;
    _emitPlaying(false);
    if (!_indexCtrl.isClosed) _indexCtrl.add(null);
    final p = _player;
    if (p == null) return;
    try {
      // With just_audio_background, stop() also releases the media session.
      await p.stop();
    } catch (e) {
      debugPrint('DuaPlayer.stop failed: $e');
    }
  }

  Future<void> setSpeed(double s) async {
    _speed = s;
    final p = _player;
    if (p == null) return;
    try {
      await p.setSpeed(s);
    } catch (e) {
      debugPrint('DuaPlayer.setSpeed failed: $e');
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _gen++;
    _active = false;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    final p = _player;
    _player = null;
    if (p != null) {
      try {
        await p.dispose();
      } catch (e) {
        debugPrint('DuaPlayer.dispose failed: $e');
      }
    }
    await _indexCtrl.close();
    await _playingCtrl.close();
    await _passCtrl.close();
  }

  // ---------------------------------------------------------------------------

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final p = _createPlayer();
    _player = p;
    _subs
      ..add(p.currentIndexStream.listen(_onIndex, onError: _onStreamError))
      ..add(p.playerStateStream.listen(_onState, onError: _onStreamError))
      ..add(p.errorStream.listen((e) {
        debugPrint('DuaPlayer error ${e.code}: ${e.message} @${e.index}');
      }, onError: _onStreamError));
    return p;
  }

  void _play(AudioPlayer p) {
    // play() completes only when playback pauses/stops, so never await it.
    p.setSpeed(_speed).catchError((Object _) {});
    p.play().catchError((Object e) {
      debugPrint('DuaPlayer.play failed: $e');
      _emitPlaying(false);
    });
  }

  void _onStreamError(Object e) => debugPrint('DuaPlayer stream error: $e');

  void _onIndex(int? index) {
    if (!_active || _indexCtrl.isClosed) return;
    _indexCtrl.add(index);
  }

  void _onState(PlayerState st) {
    final completed = st.processingState == ProcessingState.completed;
    if (completed && _active) {
      if (!_atEnd) {
        _atEnd = true;
        unawaited(_onPassComplete());
      }
      return; // keep "playing" steady between passes
    }
    if (!completed) _atEnd = false;
    _emitPlaying(_active && st.playing);
  }

  Future<void> _onPassComplete() async {
    final p = _player;
    if (p == null || _passCtrl.isClosed) return;
    final gen = _gen;
    _passesDone++;
    _passCtrl.add(_passesDone);
    if (_passesDone < _repeat) {
      try {
        await p.seek(Duration.zero, index: 0);
        if (gen == _gen && _active) _play(p);
      } catch (e) {
        debugPrint('DuaPlayer replay failed: $e');
      }
      return;
    }
    _active = false;
    _emitPlaying(false);
    if (!_indexCtrl.isClosed) _indexCtrl.add(null);
    try {
      await p.pause();
      await p.seek(Duration.zero, index: 0);
    } catch (e) {
      debugPrint('DuaPlayer park failed: $e');
    }
  }

  void _emitPlaying(bool playing) {
    if (_lastPlaying == playing || _playingCtrl.isClosed) return;
    _lastPlaying = playing;
    _playingCtrl.add(playing);
  }
}
