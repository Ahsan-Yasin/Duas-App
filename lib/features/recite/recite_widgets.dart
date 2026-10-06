import 'package:flutter/material.dart';

import '../../core/models/models.dart';
import '../../core/widgets/common.dart';

/// Key of the big counter button (used by tests).
const reciteCounterKey = ValueKey('recite-counter');

/// The big circular tap counter. Shows a check mark once the item is done.
class CounterButton extends StatelessWidget {
  const CounterButton({
    super.key,
    required this.count,
    required this.target,
    required this.mode,
    required this.done,
    required this.onTap,
    this.size = 176,
  });

  final int count;
  final int target;
  final CounterMode mode;
  final bool done;
  final VoidCallback? onTap;
  final double size;

  String get _display => mode == CounterMode.countUp
      ? '$count / $target'
      : '${(target - count).clamp(0, target)} left';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final progress = target <= 0 ? 0.0 : (count / target).clamp(0.0, 1.0);
    final label = done
        ? 'Done, $count of $target'
        : 'Count, $count of $target, tap after each recitation';
    final fg = done ? scheme.onTertiaryContainer : scheme.onPrimaryContainer;

    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: SizedBox.square(
        dimension: size,
        child: Material(
          key: reciteCounterKey,
          shape: const CircleBorder(),
          color: done ? scheme.tertiaryContainer : scheme.primaryContainer,
          elevation: 3,
          shadowColor: scheme.shadow,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 6,
                    strokeCap: StrokeCap.round,
                    color: done ? scheme.tertiary : scheme.primary,
                    backgroundColor: fg.withValues(alpha: 0.12),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(size * 0.17),
                  child: AnimatedSwitcher(
                    duration: reduceMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 280),
                    switchInCurve: Curves.easeOutBack,
                    transitionBuilder: (child, anim) => ScaleTransition(
                      scale: anim,
                      child: FadeTransition(opacity: anim, child: child),
                    ),
                    child: done
                        ? Icon(
                            Icons.check_rounded,
                            key: const ValueKey('done'),
                            size: size * 0.42,
                            color: fg,
                          )
                        : FittedBox(
                            key: const ValueKey('count'),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _display,
                                  style: theme.textTheme.displaySmall?.copyWith(
                                    color: fg,
                                    fontWeight: FontWeight.w700,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                                Text(
                                  'Tap',
                                  style: theme.textTheme.labelLarge
                                      ?.copyWith(color: fg),
                                ),
                              ],
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Arabic, transliteration, translation and source of one dua.
class DuaTextCard extends StatelessWidget {
  const DuaTextCard({
    super.key,
    required this.dua,
    required this.showTransliteration,
    required this.showTranslation,
    this.highlightAyah,
    this.extraTranslation,
  });

  final Dua dua;
  final bool showTransliteration;
  final bool showTranslation;

  /// Ayah index to highlight (follow-along); null for plain text.
  final int? highlightAyah;

  /// Cached machine translation section, translate button, etc.
  final Widget? extraTranslation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ayahs = dua.ayahs;
    final useAyahs =
        highlightAyah != null && ayahs != null && ayahs.isNotEmpty;

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ArabicText(
              dua.arabic,
              ayahs: useAyahs ? ayahs : null,
              highlightIndex: useAyahs ? highlightAyah : null,
              firstAyahNumber: useAyahs ? dua.quranAyahStart : null,
              textAlign: TextAlign.center,
            ),
            if (showTransliteration && dua.transliteration.trim().isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                dua.transliteration,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
            if (showTranslation && dua.translation.trim().isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                dua.translation,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
              ),
            ],
            if (showTranslation && extraTranslation != null) ...[
              const SizedBox(height: 12),
              extraTranslation!,
            ],
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                if (dua.source.trim().isNotEmpty)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.menu_book_outlined,
                          size: 16, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          dua.source,
                          style: theme.textTheme.labelMedium
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                VerificationChip(
                  status: dua.verificationStatus,
                  note: dua.verificationNote,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Machine translation in the user's language, or a button to create it.
class ExtraTranslation extends StatelessWidget {
  const ExtraTranslation({
    super.key,
    required this.language,
    required this.text,
    required this.busy,
    required this.onTranslate,
  });

  final String language;
  final String? text;
  final bool busy;
  final VoidCallback? onTranslate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = text;
    if (t != null && t.trim().isNotEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '$language · AI translation',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: scheme.onSecondaryContainer),
            ),
            const SizedBox(height: 6),
            Text(
              t,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
            ),
          ],
        ),
      );
    }
    return Center(
      child: busy
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            )
          : TextButton.icon(
              onPressed: onTranslate,
              icon: const Icon(Icons.translate),
              label: Text('Translate to $language'),
            ),
    );
  }
}

/// Bottom controls: Back, Pause, Skip, Close.
class ReciteControls extends StatelessWidget {
  const ReciteControls({
    super.key,
    required this.onBack,
    required this.onPause,
    required this.paused,
    required this.onSkip,
    required this.onClose,
  });

  final VoidCallback? onBack;
  final VoidCallback? onPause;
  final bool paused;
  final VoidCallback? onSkip;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _ControlButton(
          icon: Icons.skip_previous_rounded,
          label: 'Back',
          tooltip: 'Previous dua',
          onPressed: onBack,
        ),
        _ControlButton(
          icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          label: paused ? 'Resume' : 'Pause',
          tooltip: paused ? 'Resume audio' : 'Pause audio',
          onPressed: onPause,
        ),
        _ControlButton(
          icon: Icons.skip_next_rounded,
          label: 'Skip',
          tooltip: 'Skip this dua',
          onPressed: onSkip,
        ),
        _ControlButton(
          icon: Icons.close_rounded,
          label: 'Close',
          tooltip: 'Close session',
          onPressed: onClose,
        ),
      ],
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = onPressed == null
        ? theme.colorScheme.onSurface.withValues(alpha: 0.38)
        : theme.colorScheme.onSurfaceVariant;
    return Expanded(
      child: Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: Semantics(
          button: true,
          enabled: onPressed != null,
          label: label,
          excludeSemantics: true,
          onTap: onPressed,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, color: color),
                    const SizedBox(height: 2),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(color: color),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
