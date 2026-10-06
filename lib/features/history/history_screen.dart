import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/util.dart';
import '../../core/widgets/common.dart';
import '../../domain/stats.dart';

int _dayKey(DateTime d) => d.year * 10000 + d.month * 100 + d.day;

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  DateTime? _month;
  DateTime? _selected;

  @override
  Widget build(BuildContext context) {
    final now = ref.watch(nowProvider)();
    final today = DateTime(now.year, now.month, now.day);
    final month = _month ?? DateTime(today.year, today.month);
    final logsAsync = ref.watch(completedLogsProvider);
    final routines = ref.watch(routinesProvider).value ?? const <Routine>[];

    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: logsAsync.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Could not load your history.\n$e',
          onRetry: () => ref.invalidate(completedLogsProvider),
        ),
        data: (logs) => _body(context, logs, routines, today, month),
      ),
    );
  }

  Widget _body(BuildContext context, List<SessionLog> logs,
      List<Routine> routines, DateTime today, DateTime month) {
    final days = completedDays(logs);
    final keys = days.map(_dayKey).toSet();
    final current = currentStreak(days, today);
    final longest = longestStreak(days);
    final t = totals(logs);
    final selected = _selected;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _StreakCard(current: current, longest: longest),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _StatTile(value: t.sessions, label: 'Sessions')),
            const SizedBox(width: 8),
            Expanded(child: _StatTile(value: t.duas, label: 'Duas recited')),
            const SizedBox(width: 8),
            Expanded(child: _StatTile(value: t.days, label: 'Days')),
          ],
        ),
        if (logs.isEmpty) ...[
          const SizedBox(height: 16),
          const _EmptyHistory(),
        ],
        const SizedBox(height: 16),
        _MonthCalendar(
          month: month,
          today: today,
          completed: keys,
          selected: selected,
          onMonth: (m) => setState(() {
            _month = m;
            _selected = null;
          }),
          onSelect: (d) => setState(
              () => _selected = (selected != null && _dayKey(selected) == _dayKey(d)) ? null : d),
        ),
        if (selected != null) ...[
          const SizedBox(height: 16),
          _DaySessions(
            day: selected,
            logs: logs,
            routines: routines,
          ),
        ],
      ],
    );
  }
}

class _StreakCard extends StatelessWidget {
  const _StreakCard({required this.current, required this.longest});

  final int current;
  final int longest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(Icons.local_fire_department,
                size: 48, color: scheme.onPrimaryContainer),
            const SizedBox(width: 16),
            Expanded(
              child: Semantics(
                label:
                    'Current streak $current ${current == 1 ? 'day' : 'days'}. Longest streak $longest ${longest == 1 ? 'day' : 'days'}.',
                excludeSemantics: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Current streak',
                        style: theme.textTheme.labelLarge
                            ?.copyWith(color: scheme.onPrimaryContainer)),
                    Text(
                      '$current ${current == 1 ? 'day' : 'days'}',
                      style: theme.textTheme.headlineMedium?.copyWith(
                          color: scheme.onPrimaryContainer,
                          fontWeight: FontWeight.w700),
                    ),
                    Text(
                      'Longest: $longest ${longest == 1 ? 'day' : 'days'}',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: scheme.onPrimaryContainer),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        child: Semantics(
          label: '$label: $value',
          excludeSemantics: true,
          child: Column(
            children: [
              FittedBox(
                child: Text('$value',
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              Text(label,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(Icons.history, size: 36, color: theme.colorScheme.outline),
            const SizedBox(width: 16),
            const Expanded(
              child: Text(
                  'No completed sessions yet. Finish a routine and it will show up here, building your streak.'),
            ),
          ],
        ),
      ),
    );
  }
}

class _MonthCalendar extends StatelessWidget {
  const _MonthCalendar({
    required this.month,
    required this.today,
    required this.completed,
    required this.selected,
    required this.onMonth,
    required this.onSelect,
  });

  final DateTime month;
  final DateTime today;
  final Set<int> completed;
  final DateTime? selected;
  final ValueChanged<DateTime> onMonth;
  final ValueChanged<DateTime> onSelect;

  static const _weekdayLetters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
  static const _weekdayNames = [
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
    final theme = Theme.of(context);
    final first = DateTime(month.year, month.month);
    final leading = first.weekday - 1; // Mon-first
    final daysInMonth = DateUtils.getDaysInMonth(month.year, month.month);
    final cellCount = ((leading + daysInMonth + 6) ~/ 7) * 7;
    final isCurrentOrLater = month.year > today.year ||
        (month.year == today.year && month.month >= today.month);
    final doneThisMonth = [
      for (var d = 1; d <= daysInMonth; d++)
        if (completed.contains(_dayKey(DateTime(month.year, month.month, d))))
          d,
    ].length;

    final rows = <Widget>[];
    for (var r = 0; r < cellCount ~/ 7; r++) {
      rows.add(Row(
        children: [
          for (var c = 0; c < 7; c++)
            Expanded(child: _cell(context, r * 7 + c - leading + 1, daysInMonth)),
        ],
      ));
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Previous month',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () =>
                      onMonth(DateTime(month.year, month.month - 1)),
                ),
                Expanded(
                  child: Column(
                    children: [
                      Text(DateFormat.yMMMM().format(month),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium),
                      Text(
                        '$doneThisMonth ${doneThisMonth == 1 ? 'day' : 'days'} completed',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Next month',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: isCurrentOrLater
                      ? null
                      : () => onMonth(DateTime(month.year, month.month + 1)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ExcludeSemantics(
              child: Row(
                children: [
                  for (var i = 0; i < 7; i++)
                    Expanded(
                      child: Tooltip(
                        message: _weekdayNames[i],
                        child: Text(
                          _weekdayLetters[i],
                          textAlign: TextAlign.center,
                          style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            ...rows,
          ],
        ),
      ),
    );
  }

  Widget _cell(BuildContext context, int day, int daysInMonth) {
    if (day < 1 || day > daysInMonth) {
      return const AspectRatio(aspectRatio: 1, child: SizedBox.shrink());
    }
    final scheme = Theme.of(context).colorScheme;
    final date = DateTime(month.year, month.month, day);
    final key = _dayKey(date);
    final done = completed.contains(key);
    final isToday = key == _dayKey(today);
    final isSelected = selected != null && _dayKey(selected!) == key;
    final label = '${DateFormat.MMMMd().format(date)}, '
        '${done ? 'completed' : 'not completed'}${isToday ? ', today' : ''}';

    Color? fill;
    Color? textColor;
    if (done) {
      fill = scheme.primary;
      textColor = scheme.onPrimary;
    } else if (isSelected) {
      fill = scheme.secondaryContainer;
      textColor = scheme.onSecondaryContainer;
    }
    Border? border;
    if (isToday) {
      border = Border.all(color: scheme.tertiary, width: 2.5);
    } else if (isSelected && done) {
      border = Border.all(color: scheme.onSurface, width: 2);
    }

    return AspectRatio(
      aspectRatio: 1,
      child: Semantics(
        label: label,
        button: true,
        selected: isSelected,
        excludeSemantics: true,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => onSelect(date),
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fill,
                border: border,
              ),
              alignment: Alignment.center,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: FittedBox(
                  child: Text(
                    '$day',
                    style: TextStyle(
                      color: textColor,
                      fontWeight:
                          done || isToday ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DaySessions extends StatelessWidget {
  const _DaySessions({
    required this.day,
    required this.logs,
    required this.routines,
  });

  final DateTime day;
  final List<SessionLog> logs;
  final List<Routine> routines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final key = _dayKey(day);
    final entries = <(SessionLog, DateTime)>[
      for (final l in logs)
        if (parseIso(l.finishedAt ?? l.startedAt) case final DateTime t
            when _dayKey(t) == key)
          (l, t),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    final names = {for (final r in routines) r.id: r.name};

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(DateFormat.yMMMMEEEEd().format(day),
                  style: theme.textTheme.titleSmall),
            ),
            if (entries.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text('No completed sessions on this day.'),
              )
            else
              for (final (log, time) in entries)
                ListTile(
                  leading: Icon(
                    log.fromAlarm ? Icons.alarm : Icons.check_circle_outline,
                    color: theme.colorScheme.primary,
                    semanticLabel: log.fromAlarm ? 'Started from an alarm' : null,
                  ),
                  title: Text(log.routineId == null
                      ? 'Session'
                      : (names[log.routineId] ?? 'Deleted routine')),
                  subtitle: Text(
                    '${DateFormat.jm().format(time)} · '
                    '${log.completedDuaIds.length} '
                    '${log.completedDuaIds.length == 1 ? 'dua' : 'duas'}'
                    '${log.fromAlarm ? ' · from alarm' : ''}',
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
