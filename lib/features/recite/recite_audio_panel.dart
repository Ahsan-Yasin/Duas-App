import 'package:flutter/material.dart';

import '../../core/audio/quran_audio.dart';
import '../../core/models/models.dart';
import 'recite_audio.dart';

const playbackSpeeds = <double>[0.75, 0.9, 1.0, 1.1, 1.25];

String speedLabel(double s) {
  final text = s.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
  return '${text.endsWith('.') ? '${text}0' : text}×';
}

String audioModeTitle(AudioMode m) => switch (m) {
      AudioMode.off => 'Audio off',
      AudioMode.listen => 'Listen',
      AudioMode.listenThenRecite => 'Listen, then recite',
      AudioMode.followAlong => 'Follow along',
    };

String audioModeSubtitle(AudioMode m) => switch (m) {
      AudioMode.off => 'Recite on your own',
      AudioMode.listen => 'Play button plays each dua once',
      AudioMode.listenThenRecite =>
        'Each dua plays once automatically, then you recite',
      AudioMode.followAlong =>
        'Plays the dua for every repetition and counts for you',
    };

/// Play / pause, download progress, errors, speed and device-voice fallback
/// for the current dua.
class ReciteAudioPanel extends StatelessWidget {
  const ReciteAudioPanel({
    super.key,
    required this.audio,
    required this.mode,
    required this.speed,
    required this.onPlay,
    required this.onSpeak,
    required this.onSpeed,
  });

  final ReciteAudioController audio;
  final AudioMode mode;
  final double speed;
  final VoidCallback onPlay;
  final VoidCallback onSpeak;
  final ValueChanged<double> onSpeed;

  @override
  Widget build(BuildContext context) {
    if (mode == AudioMode.off) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: audio,
      builder: (context, _) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final children = <Widget>[];

        if (audio.hasRecording) {
          final busy = audio.downloading;
          final String status;
          if (busy) {
            status = 'Downloading audio '
                '${audio.downloadDone}/${audio.downloadTotal}';
          } else if (audio.playing) {
            status = mode == AudioMode.followAlong
                ? 'Playing — follow along'
                : 'Playing';
          } else if (audio.isPaused) {
            status = 'Paused';
          } else {
            status = mode == AudioMode.followAlong
                ? 'Play to recite along'
                : 'Listen to this dua';
          }
          children.add(Row(
            children: [
              IconButton.filledTonal(
                iconSize: 32,
                tooltip: audio.playing ? 'Pause recitation' : 'Play recitation',
                onPressed: busy
                    ? null
                    : audio.playing || audio.isPaused
                        ? audio.togglePause
                        : onPlay,
                icon: Icon(audio.playing
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(status, style: theme.textTheme.bodyMedium),
              ),
              _SpeedButton(speed: speed, onSelected: onSpeed),
            ],
          ));
          if (busy) {
            final total = audio.downloadTotal;
            children.add(Padding(
              padding: const EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(
                value: total > 0 ? audio.downloadDone / total : null,
                semanticsLabel: 'Downloading recitation audio',
              ),
            ));
          }
          if (audio.source == ReciteAudioSource.reciter) {
            children.add(Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                audioAttribution,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ));
          }
        } else {
          if (audio.source == ReciteAudioSource.none) {
            children.add(Row(
              children: [
                Icon(Icons.volume_off_outlined,
                    size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'No recitation audio',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ));
            children.add(const SizedBox(height: 8));
          }
          children.add(Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              onPressed: onSpeak,
              icon: Icon(audio.speaking
                  ? Icons.stop_rounded
                  : Icons.record_voice_over_outlined),
              label: Text(audio.speaking
                  ? 'Stop reading'
                  : 'Read aloud (device voice — not a reciter)'),
            ),
          ));
        }

        final error = audio.error;
        if (error != null) {
          children.add(Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.cloud_off_outlined, size: 18, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    error,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: scheme.error),
                  ),
                ),
              ],
            ),
          ));
        }

        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        );
      },
    );
  }
}

class _SpeedButton extends StatelessWidget {
  const _SpeedButton({required this.speed, required this.onSelected});

  final double speed;
  final ValueChanged<double> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      tooltip: 'Playback speed',
      initialValue: speed,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final s in playbackSpeeds)
          CheckedPopupMenuItem<double>(
            value: s,
            checked: (s - speed).abs() < 0.001,
            child: Text(speedLabel(s)),
          ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              speedLabel(speed),
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet to pick the audio mode and playback speed.
Future<void> showAudioOptionsSheet(
  BuildContext context, {
  required AudioMode mode,
  required double speed,
  required String reciter,
  required ValueChanged<AudioMode> onMode,
  required ValueChanged<double> onSpeed,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      var currentMode = mode;
      var currentSpeed = speed;
      return StatefulBuilder(
        builder: (context, setSheetState) {
          final theme = Theme.of(context);
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                    child: Text('Audio', style: theme.textTheme.titleLarge),
                  ),
                  for (final m in AudioMode.values)
                    ListTile(
                      selected: m == currentMode,
                      leading: Icon(_modeIcon(m)),
                      title: Text(audioModeTitle(m)),
                      subtitle: Text(audioModeSubtitle(m)),
                      trailing: m == currentMode
                          ? const Icon(Icons.check_rounded)
                          : null,
                      onTap: () {
                        setSheetState(() => currentMode = m);
                        onMode(m);
                      },
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                    child: Text('Speed', style: theme.textTheme.titleSmall),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final s in playbackSpeeds)
                          ChoiceChip(
                            label: Text(speedLabel(s)),
                            selected: (s - currentSpeed).abs() < 0.001,
                            onSelected: (_) {
                              setSheetState(() => currentSpeed = s);
                              onSpeed(s);
                            },
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                    child: Text(
                      'Quran reciter: ${reciterName(reciter)}. '
                      '$audioAttribution',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

IconData _modeIcon(AudioMode m) => switch (m) {
      AudioMode.off => Icons.volume_off_outlined,
      AudioMode.listen => Icons.headphones_outlined,
      AudioMode.listenThenRecite => Icons.record_voice_over_outlined,
      AudioMode.followAlong => Icons.graphic_eq_rounded,
    };
