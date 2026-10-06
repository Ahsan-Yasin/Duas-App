import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/util.dart';
import '../../core/widgets/common.dart' show WeekdayChips, confirmDialog;
import 'reminders_screen.dart' show weekdaySummary;

const _allDays = [1, 2, 3, 4, 5, 6, 7];
const _weekdays = [1, 2, 3, 4, 5];
const _weekends = [6, 7];

class ReminderEditorScreen extends ConsumerStatefulWidget {
  const ReminderEditorScreen({super.key, this.reminderId});

  final int? reminderId;

  @override
  ConsumerState<ReminderEditorScreen> createState() =>
      _ReminderEditorScreenState();
}

class _ReminderEditorScreenState extends ConsumerState<ReminderEditorScreen> {
  final _label = TextEditingController();
  bool _loading = true;
  String? _loadError;
  Reminder? _existing;

  TimeOfDay _time = const TimeOfDay(hour: 7, minute: 0);
  List<int> _days = [..._allDays];
  int? _routineId;
  bool _enabled = true;
  int _snoozeMinutes = 5;
  int _maxSnoozes = 3;
  bool _nag = true;
  int _nagEvery = 10;
  int _nagMax = 3;
  bool _vibrate = true;
  bool _saving = false;
  bool _showErrors = false;

  bool get _isNew => widget.reminderId == null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final settings = ref.read(settingsProvider);
    _snoozeMinutes = clampInt(settings.defaultSnoozeMinutes, 1, 30);
    _routineId = settings.defaultRoutineId;
    final id = widget.reminderId;
    if (id != null) {
      try {
        final r = await ref.read(reminderRepoProvider).get(id);
        if (r == null) {
          _loadError = 'This reminder no longer exists.';
        } else {
          _existing = r;
          _label.text = r.label;
          _time = TimeOfDay(hour: r.hour, minute: r.minute);
          _days = [...r.weekdays]..sort();
          _routineId = r.routineId;
          _enabled = r.enabled;
          _snoozeMinutes = clampInt(r.snoozeMinutes, 1, 30);
          _maxSnoozes = clampInt(r.maxSnoozes, 0, 10);
          _nag = r.nagEnabled;
          _nagEvery = clampInt(r.nagEveryMinutes, 5, 60);
          _nagMax = clampInt(r.nagMaxTimes, 1, 10);
          _vibrate = r.vibrate;
        }
      } catch (e) {
        _loadError = 'Could not load this reminder.\n$e';
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time,
      helpText: 'Reminder time',
    );
    if (picked != null) setState(() => _time = picked);
  }

  String? _validate(List<Routine> routines) {
    if (_days.isEmpty) return 'Pick at least one day.';
    if (_routineId == null || !routines.any((r) => r.id == _routineId)) {
      return 'Choose a routine to recite when the alarm rings.';
    }
    return null;
  }

  Future<void> _save(List<Routine> routines) async {
    final error = _validate(routines);
    if (error != null) {
      setState(() => _showErrors = true);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final routineName =
        routines.firstWhere((r) => r.id == _routineId).name;
    final label = _label.text.trim().isEmpty ? routineName : _label.text.trim();
    final now = nowIso();
    final reminder = Reminder(
      id: _existing?.id,
      label: label,
      hour: _time.hour,
      minute: _time.minute,
      weekdays: [..._days]..sort(),
      routineId: _routineId,
      enabled: _enabled,
      snoozeMinutes: _snoozeMinutes,
      maxSnoozes: _maxSnoozes,
      nagEnabled: _nag,
      nagEveryMinutes: _nagEvery,
      nagMaxTimes: _nagMax,
      ringSeconds: _existing?.ringSeconds ?? 120,
      vibrate: _vibrate,
      sound: _existing?.sound ?? 'default',
      createdAt: _existing?.createdAt ?? now,
      updatedAt: now,
    );
    final repo = ref.read(reminderRepoProvider);
    try {
      if (_existing == null) {
        await repo.add(reminder);
      } else {
        await repo.update(reminder);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
      return;
    }
    if (!mounted) return;
    invalidateData(ref);
    try {
      await ref.read(alarmServiceProvider).sync('edit');
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(
              'Saved. Alarms will be updated when you reopen the app ($e).')));
    }
    if (!mounted) return;
    navigator.pop(true);
  }

  Future<void> _delete() async {
    final id = _existing?.id;
    if (id == null) return;
    final ok = await confirmDialog(
      context,
      title: 'Delete reminder?',
      message: 'This reminder will stop ringing and be removed.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    try {
      await ref.read(reminderRepoProvider).delete(id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text('Could not delete: $e')));
      return;
    }
    if (!mounted) return;
    invalidateData(ref);
    try {
      await ref.read(alarmServiceProvider).sync('edit');
    } catch (_) {
      // Retried on next app resume.
    }
    if (!mounted) return;
    navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final routinesAsync = ref.watch(routinesProvider);
    final routines = routinesAsync.value ?? const <Routine>[];

    Widget body;
    if (_loading || (routinesAsync.isLoading && !routinesAsync.hasValue)) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_loadError != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_loadError!, textAlign: TextAlign.center),
        ),
      );
    } else {
      body = _form(context, routines, routinesAsync.hasError);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New reminder' : 'Edit reminder'),
        actions: [
          if (!_isNew && _existing != null)
            IconButton(
              tooltip: 'Delete reminder',
              icon: const Icon(Icons.delete_outline),
              onPressed: _saving ? null : _delete,
            ),
        ],
      ),
      body: body,
      bottomNavigationBar: (_loading || _loadError != null)
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed: _saving ? null : () => _save(routines),
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.check),
                  label: const Text('Save reminder'),
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52)),
                ),
              ),
            ),
    );
  }

  Widget _form(
      BuildContext context, List<Routine> routines, bool routinesFailed) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final routineValid =
        _routineId != null && routines.any((r) => r.id == _routineId);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        // Time
        Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _pickTime,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Time', style: theme.textTheme.labelLarge),
                        Semantics(
                          label: 'Reminder time',
                          child: Text(
                            _time.format(context),
                            style: theme.textTheme.displayMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: scheme.primary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.edit_outlined),
                  const SizedBox(width: 4),
                  const Text('Change'),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _label,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Label',
            hintText: 'e.g. Morning adhkar',
            helperText: 'Shown on the alarm screen. Leave empty to use the routine name.',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 20),
        // Days
        Text('Repeat on', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(weekdaySummary(_days),
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        WeekdayChips(
          selected: _days,
          onChanged: (days) => setState(() => _days = [...days]..sort()),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            _PresetChip(
                label: 'Every day',
                selected: _sameDays(_days, _allDays),
                onTap: () => setState(() => _days = [..._allDays])),
            _PresetChip(
                label: 'Weekdays',
                selected: _sameDays(_days, _weekdays),
                onTap: () => setState(() => _days = [..._weekdays])),
            _PresetChip(
                label: 'Weekends',
                selected: _sameDays(_days, _weekends),
                onTap: () => setState(() => _days = [..._weekends])),
          ],
        ),
        if (_showErrors && _days.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Pick at least one day.',
                style: TextStyle(color: scheme.error)),
          ),
        const SizedBox(height: 20),
        // Routine
        InputDecorator(
          decoration: InputDecoration(
            labelText: 'Routine',
            border: const OutlineInputBorder(),
            helperText: 'Opens when you tap "Start reciting" on the alarm.',
            errorText: _showErrors && !routineValid
                ? (routinesFailed
                    ? 'Could not load routines.'
                    : 'Choose a routine.')
                : null,
          ),
          child: routines.isEmpty
              ? const Text('No routines yet — create one in the Routines tab.')
              : DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    isExpanded: true,
                    isDense: true,
                    value: routineValid ? _routineId : null,
                    hint: const Text('Choose a routine'),
                    items: [
                      for (final r in routines)
                        if (r.id != null)
                          DropdownMenuItem(
                            value: r.id,
                            child: Text(r.name,
                                overflow: TextOverflow.ellipsis),
                          ),
                    ],
                    onChanged: (v) => setState(() => _routineId = v),
                  ),
                ),
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Reminder on'),
          subtitle: const Text('Turn off to keep it without ringing'),
          value: _enabled,
          onChanged: (v) => setState(() => _enabled = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Vibrate'),
          value: _vibrate,
          onChanged: (v) => setState(() => _vibrate = v),
        ),
        const Divider(height: 24),
        Text('Snooze', style: theme.textTheme.titleSmall),
        _StepperTile(
          title: 'Snooze length',
          value: _snoozeMinutes,
          min: 1,
          max: 30,
          format: (v) => '$v min',
          onChanged: (v) => setState(() => _snoozeMinutes = v),
        ),
        _StepperTile(
          title: 'Snoozes allowed',
          value: _maxSnoozes,
          min: 0,
          max: 10,
          format: (v) => v == 0 ? 'No snooze' : '$v',
          onChanged: (v) => setState(() => _maxSnoozes = v),
        ),
        const Divider(height: 24),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Ring again if missed'),
          subtitle: const Text(
              'If you don\'t respond, the alarm rings again a few times.'),
          value: _nag,
          onChanged: (v) => setState(() => _nag = v),
        ),
        if (_nag) ...[
          _StepperTile(
            title: 'Ring again every',
            value: _nagEvery,
            min: 5,
            max: 60,
            step: 5,
            format: (v) => '$v min',
            onChanged: (v) => setState(() => _nagEvery = v),
          ),
          _StepperTile(
            title: 'Ring again up to',
            value: _nagMax,
            min: 1,
            max: 10,
            format: (v) => v == 1 ? '1 time' : '$v times',
            onChanged: (v) => setState(() => _nagMax = v),
          ),
        ],
        const Divider(height: 24),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.timer_outlined),
          title: Text(
              'Rings for ${((_existing?.ringSeconds ?? 120) / 60).round()} minutes'),
          subtitle: const Text(
              'Then it stops and shows a "Missed — tap to start" notification.'),
        ),
      ],
    );
  }
}

bool _sameDays(List<int> a, List<int> b) {
  final sa = a.toSet();
  return sa.length == b.length && b.every(sa.contains);
}

class _PresetChip extends StatelessWidget {
  const _PresetChip(
      {required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}

/// A labelled value with − / + buttons (large tap targets, works with big text).
class _StepperTile extends StatelessWidget {
  const _StepperTile({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.format,
    required this.onChanged,
    this.step = 1,
  });

  final String title;
  final int value;
  final int min;
  final int max;
  final int step;
  final String Function(int) format;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(title, style: theme.textTheme.bodyLarge)),
          IconButton(
            tooltip: 'Decrease $title',
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: value > min
                ? () => onChanged(clampInt(value - step, min, max))
                : null,
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 72),
            child: Text(
              format(value),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
          ),
          IconButton(
            tooltip: 'Increase $title',
            icon: const Icon(Icons.add_circle_outline),
            onPressed: value < max
                ? () => onChanged(clampInt(value + step, min, max))
                : null,
          ),
        ],
      ),
    );
  }
}
