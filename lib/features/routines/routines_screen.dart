import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/navigation.dart';
import '../../core/providers.dart';
import '../../core/widgets/common.dart';
import 'routine_editor_screen.dart';

/// Re-syncs native alarms after routine changes (reminder dicts carry the
/// routine name). Failures are logged only; the next sync repairs them.
void resyncAlarms(WidgetRef ref, String reason) {
  final service = ref.read(alarmServiceProvider);
  unawaited(
    service.sync(reason).then<void>((_) {}).catchError((Object e) {
      debugPrint('Alarm sync after $reason failed: $e');
    }),
  );
}

class RoutinesScreen extends ConsumerWidget {
  const RoutinesScreen({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = await textPromptDialog(
      context,
      title: 'New routine',
      label: 'Routine name',
      confirmLabel: 'Create',
    );
    if (name == null || !context.mounted) return;
    try {
      final routine = await ref.read(routineRepoProvider).add(name);
      invalidateData(ref);
      final id = routine.id;
      if (id != null) {
        await pushScreen<void>(RoutineEditorScreen(routineId: id));
      }
    } catch (e) {
      if (context.mounted) _snack(context, 'Could not create the routine: $e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routinesAsync = ref.watch(routinesProvider);
    final defaultId = ref.watch(settingsProvider.select((s) => s.defaultRoutineId));

    return Scaffold(
      appBar: AppBar(title: const Text('Routines')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'routines_add',
        tooltip: 'Create a routine',
        onPressed: () => _create(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('New routine'),
      ),
      body: routinesAsync.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Could not load routines.\n$e',
          onRetry: () => ref.invalidate(routinesProvider),
        ),
        data: (routines) {
          if (routines.isEmpty) {
            return EmptyState(
              icon: Icons.playlist_add,
              title: 'No routines yet',
              message: 'A routine is a list of duas you recite together, '
                  'like your morning adhkar.',
              action: FilledButton.icon(
                onPressed: () => _create(context, ref),
                icon: const Icon(Icons.add),
                label: const Text('Create a routine'),
              ),
            );
          }
          final effectiveDefault =
              routines.any((r) => r.id == defaultId) ? defaultId : routines.first.id;
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
            itemCount: routines.length,
            itemBuilder: (context, i) => _RoutineCard(
              routine: routines[i],
              isDefault: routines[i].id == effectiveDefault,
            ),
          );
        },
      ),
    );
  }
}

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

class _RoutineCard extends ConsumerWidget {
  const _RoutineCard({required this.routine, required this.isDefault});

  final Routine routine;
  final bool isDefault;

  Future<void> _setDefault(WidgetRef ref) =>
      ref.read(settingsProvider.notifier).update((s) => s.copyWith(defaultRoutineId: routine.id));

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final id = routine.id;
    if (id == null) return;
    final name = await textPromptDialog(
      context,
      title: 'Rename routine',
      initial: routine.name,
      label: 'Routine name',
    );
    if (name == null || name == routine.name || !context.mounted) return;
    try {
      await ref.read(routineRepoProvider).rename(id, name);
      invalidateData(ref);
      resyncAlarms(ref, 'routine_renamed');
    } catch (e) {
      if (context.mounted) _snack(context, 'Could not rename: $e');
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final id = routine.id;
    if (id == null) return;
    final ok = await confirmDialog(
      context,
      title: 'Delete "${routine.name}"?',
      message: 'The duas stay in your library. Reminders that start this '
          'routine will no longer open it.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    try {
      await ref.read(routineRepoProvider).delete(id);
      if (ref.read(settingsProvider).defaultRoutineId == id) {
        await ref
            .read(settingsProvider.notifier)
            .update((s) => s.copyWith(defaultRoutineId: null));
      }
      invalidateData(ref);
      resyncAlarms(ref, 'routine_deleted');
      if (context.mounted) _snack(context, 'Routine deleted');
    } catch (e) {
      if (context.mounted) _snack(context, 'Could not delete: $e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final count = routine.items.length;
    final id = routine.id;
    return Card(
      child: InkWell(
        onTap: id == null ? null : () => pushScreen<void>(RoutineEditorScreen(routineId: id)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(routine.name, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      '$count ${count == 1 ? 'dua' : 'duas'}'
                      '${isDefault ? ' · Default' : ''}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: isDefault ? 'Default routine' : 'Set as default routine',
                isSelected: isDefault,
                onPressed: isDefault ? null : () => _setDefault(ref),
                icon: const Icon(Icons.star_border),
                selectedIcon: Icon(Icons.star, color: theme.colorScheme.primary),
              ),
              FilledButton.tonalIcon(
                onPressed: count == 0 ? null : () => openRecite(routineId: id),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start'),
              ),
              PopupMenuButton<String>(
                tooltip: 'More actions for ${routine.name}',
                onSelected: (v) {
                  switch (v) {
                    case 'edit':
                      if (id != null) pushScreen<void>(RoutineEditorScreen(routineId: id));
                    case 'rename':
                      _rename(context, ref);
                    case 'delete':
                      _delete(context, ref);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'edit',
                    child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Edit duas')),
                  ),
                  PopupMenuItem(
                    value: 'rename',
                    child: ListTile(
                      leading: Icon(Icons.drive_file_rename_outline),
                      title: Text('Rename'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
