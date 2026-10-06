import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers.dart';
import '../theme.dart';

/// Converts [n] to Arabic-Indic digits (e.g. 12 -> ١٢).
String arabicDigits(int n) {
  const digits = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
  return n.toString().split('').map((c) {
    final d = int.tryParse(c);
    return d == null ? c : digits[d];
  }).join();
}

/// Arabic text rendered right-to-left in Amiri at the user's font size.
///
/// When [ayahs] is given, each ayah is followed by an ayah-end ornament
/// (numbered when [firstAyahNumber] is known) and the ayah at
/// [highlightIndex] gets a tinted background for follow-along reading.
class ArabicText extends ConsumerWidget {
  const ArabicText(
    this.text, {
    super.key,
    this.ayahs,
    this.highlightIndex,
    this.size,
    this.firstAyahNumber,
    this.maxLines,
    this.textAlign = TextAlign.start,
    this.color,
  });

  final String text;
  final List<String>? ayahs;
  final int? highlightIndex;

  /// Font size; defaults to `settings.arabicFontSize`.
  final double? size;
  final int? firstAyahNumber;
  final int? maxLines;
  final TextAlign textAlign;
  final Color? color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fontSize =
        size ?? ref.watch(settingsProvider.select((s) => s.arabicFontSize)).toDouble();
    final scheme = Theme.of(context).colorScheme;
    final base = TextStyle(
      fontFamily: arabicFontFamily,
      fontSize: fontSize,
      height: 1.9,
      color: color ?? scheme.onSurface,
      locale: const Locale('ar'),
    );
    final overflow = maxLines == null ? null : TextOverflow.ellipsis;
    final list = ayahs;
    if (list == null || list.isEmpty) {
      return Text(
        text,
        textDirection: TextDirection.rtl,
        textAlign: textAlign,
        style: base,
        maxLines: maxLines,
        overflow: overflow,
      );
    }
    final marker = base.copyWith(color: scheme.primary);
    final highlight = base.copyWith(
      backgroundColor: scheme.primaryContainer,
      color: scheme.onPrimaryContainer,
    );
    final spans = <InlineSpan>[];
    for (var i = 0; i < list.length; i++) {
      final number = firstAyahNumber == null ? '' : arabicDigits(firstAyahNumber! + i);
      spans
        ..add(TextSpan(text: list[i], style: i == highlightIndex ? highlight : null))
        ..add(TextSpan(text: ' ۝$number ', style: marker));
    }
    return Text.rich(
      TextSpan(style: base, children: spans),
      textDirection: TextDirection.rtl,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}

/// Centered icon + message shown when a list has no items.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.message,
    this.title,
    this.icon = Icons.inbox_outlined,
    this.action,
  });

  final String message;
  final String? title;
  final IconData icon;

  /// Optional call-to-action button.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            if (title != null) ...[
              Text(title!, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
              const SizedBox(height: 8),
            ],
            Text(
              message,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

/// Error message with an optional retry button.
class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 56, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
            if (onRetry != null) ...[
              const SizedBox(height: 20),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Centered progress indicator with an optional message.
class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (message != null) ...[
            const SizedBox(height: 16),
            Text(message!, textAlign: TextAlign.center),
          ],
        ],
      ),
    );
  }
}

/// Small heading above a group of content.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing, this.padding});

  final String text;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                text,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Green "Verified" / amber "Unverified" pill; the note is shown as tooltip.
class VerificationChip extends StatelessWidget {
  const VerificationChip({super.key, required this.status, this.note = ''});

  final VerificationStatus status;
  final String note;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final verified = status == VerificationStatus.verified;
    final bg = verified
        ? VerificationColors.verifiedBackground(b)
        : VerificationColors.unverifiedBackground(b);
    final fg = verified
        ? VerificationColors.verifiedForeground(b)
        : VerificationColors.unverifiedForeground(b);
    final label = verified ? 'Verified' : 'Unverified';
    final tip = note.trim().isNotEmpty
        ? note
        : verified
            ? 'Text checked against its source.'
            : 'Not checked — confirm with a reliable source or teacher.';
    return Tooltip(
      message: tip,
      triggerMode: TooltipTriggerMode.tap,
      child: Semantics(
        label: '$label. $tip',
        excludeSemantics: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(verified ? Icons.verified_outlined : Icons.help_outline, size: 14, color: fg),
              const SizedBox(width: 4),
              Text(
                label,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: fg, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small "×3" badge showing a repeat count.
class RepeatBadge extends StatelessWidget {
  const RepeatBadge(this.count, {super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Repeat $count times',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          '×$count',
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: scheme.onSecondaryContainer, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// Minus / value / plus control for small integer ranges.
class NumberStepper extends StatelessWidget {
  const NumberStepper({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 1,
    this.max = 100,
    this.label = 'Repeat',
  });

  final int value;
  final ValueChanged<int> onChanged;
  final int min;
  final int max;

  /// Used for accessibility labels ("Decrease repeat").
  final String label;

  @override
  Widget build(BuildContext context) {
    final lower = label.toLowerCase();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Decrease $lower',
          onPressed: value > min ? () => onChanged(value - 1) : null,
          icon: const Icon(Icons.remove_circle_outline),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 32),
          child: Semantics(
            label: '$label $value',
            excludeSemantics: true,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
        IconButton(
          tooltip: 'Increase $lower',
          onPressed: value < max ? () => onChanged(value + 1) : null,
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }
}

/// Shows a confirmation dialog; resolves to true only when confirmed.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  String? message,
  String confirmLabel = 'OK',
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return AlertDialog(
        title: Text(title),
        content: message == null ? null : Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(cancelLabel),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  )
                : null,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

/// Asks for a single line of text (e.g. a routine name). Resolves to the
/// trimmed text, or null when cancelled or empty.
Future<String?> textPromptDialog(
  BuildContext context, {
  required String title,
  String initial = '',
  String label = 'Name',
  String confirmLabel = 'Save',
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (v) => Navigator.of(ctx).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  controller.dispose();
  final trimmed = result?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

/// Mon..Sun filter chips (ISO weekdays 1..7).
class WeekdayChips extends StatelessWidget {
  const WeekdayChips({super.key, required this.selected, required this.onChanged});

  final List<int> selected;
  final ValueChanged<List<int>> onChanged;

  static const _short = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _long = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 2,
      children: [
        for (var day = 1; day <= 7; day++)
          FilterChip(
            label: Text(_short[day - 1]),
            tooltip: _long[day - 1],
            showCheckmark: false,
            materialTapTargetSize: MaterialTapTargetSize.padded,
            selected: selected.contains(day),
            onSelected: (on) {
              final next = {...selected};
              if (on) {
                next.add(day);
              } else {
                next.remove(day);
              }
              onChanged(next.toList()..sort());
            },
          ),
      ],
    );
  }
}
