import 'package:flutter/material.dart';

import '../../core/models/models.dart';
import '../../core/widgets/common.dart';

/// "Session complete" view shown after the last dua.
class FinishView extends StatelessWidget {
  const FinishView({
    super.key,
    required this.completedCount,
    required this.skippedCount,
    required this.saving,
    required this.onDone,
    this.acceptance,
    this.streak,
    this.saveError,
  });

  final int completedCount;
  final int skippedCount;
  final bool saving;
  final Dua? acceptance;
  final int? streak;
  final String? saveError;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final dua = acceptance;
    final s = streak;

    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: reduceMotion ? 1 : 0.6, end: 1),
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.easeOutBack,
                      builder: (context, v, child) =>
                          Transform.scale(scale: v, child: child),
                      child: Container(
                        width: 96,
                        height: 96,
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.check_rounded,
                          size: 56,
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Semantics(
                    header: true,
                    child: Text(
                      'Session complete',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _summary(),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  if (s != null && s > 0) ...[
                    const SizedBox(height: 16),
                    Center(
                      child: Chip(
                        avatar: Icon(Icons.local_fire_department_rounded,
                            color: scheme.tertiary),
                        label: Text(
                          s == 1 ? 'Current streak: 1 day' : 'Current streak: $s days',
                        ),
                      ),
                    ),
                  ],
                  if (saveError != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      saveError!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: scheme.error),
                    ),
                  ],
                  if (dua != null) ...[
                    const SizedBox(height: 28),
                    Card(
                      elevation: 0,
                      color: scheme.surfaceContainerLow,
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Ask Allah to accept it',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleSmall
                                  ?.copyWith(color: scheme.primary),
                            ),
                            const SizedBox(height: 12),
                            ArabicText(dua.arabic, textAlign: TextAlign.center),
                            if (dua.translation.trim().isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text(
                                dua.translation,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyLarge
                                    ?.copyWith(height: 1.5),
                              ),
                            ],
                            if (dua.source.trim().isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                dua.source,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: saving ? null : onDone,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                ),
                child: saving
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : const Text('Done'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _summary() {
    final c = completedCount == 1 ? '1 dua completed' : '$completedCount duas completed';
    if (skippedCount == 0) return c;
    return '$c · $skippedCount skipped';
  }
}
