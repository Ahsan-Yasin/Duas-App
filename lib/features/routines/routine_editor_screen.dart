import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/navigation.dart';
import '../../core/providers.dart';
import '../../core/widgets/common.dart';
import 'routines_screen.dart';

/// One routine with its items (ordered by position).
final routineDetailProvider = FutureProvider.family<Routine?, int>(
  (ref, id) => ref.watch(routineRepoProvider).get(id),
);

class RoutineEditorScreen extends ConsumerStatefulWidget {
  const RoutineEditorScreen({super.key, required this.routineId});

  final int routineId;

  @override
  ConsumerState<RoutineEditorScreen> createState() => _RoutineEditorScreenState();
}

class _RoutineEditorScreenState extends ConsumerState<RoutineEditorScreen> {
  /// Order shown while a drag-reorder is being saved.
  List<RoutineItem>? _optimistic;

  /// Latest repeat chosen per item id (null value = back to default), shown
  /// immediately while the write is in flight.
  final Map<int, int?> _repeatEdits = {};

  int get _id => widget.routineId;

  void _refresh() {
    ref.invalidate(routineDetailProvider(_id));
    ref.invalidate(routinesProvider);
  }

  void _snack(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  Future<void> _rename(Routine routine) async {
    final name = await textPromptDialog(
      context,
      title: 'Rename routine',
      initial: routine.name,
      label: 'Routine name',
    );
    if (name == null || name == routine.name || !mounted) return;
    try {
      await ref.read(routineRepoProvider).rename(_id, name);
      if (!mounted) return;
      _refresh();
      resyncAlarms(ref, 'routine_renamed');
    } catch (e) {
      _snack('Could not rename: $e');
    }
  }

  Future<void> _reorder(List<RoutineItem> current, int oldIndex, int newIndex) async {
    final list = [...current];
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex.clamp(0, list.length), moved);
    setState(() => _optimistic = list);
    try {
      await ref.read(routineRepoProvider).reorderItems(_id, [
        for (final item in list)
          if (item.id != null) item.id!,
      ]);
      if (!mounted) return;
      _refresh();
      await ref.read(routineDetailProvider(_id).future);
    } catch (e) {
      _snack('Could not save the new order: $e');
    } finally {
      if (mounted) setState(() => _optimistic = null);
    }
  }

  Future<void> _setRepeat(RoutineItem item, Dua? dua, int value) async {
    final itemId = item.id;
    if (itemId == null) return;
    final override = (dua != null && value == dua.defaultRepeat) ? null : value;
    setState(() => _repeatEdits[itemId] = override);
    try {
      await ref.read(routineRepoProvider).setRepeat(itemId, override);
      if (mounted) _refresh();
    } catch (e) {
      _snack('Could not change the repeat count: $e');
    }
  }

  Future<void> _remove(Routine routine, RoutineItem item, String title) async {
    final itemId = item.id;
    if (itemId == null) return;
    final container = ProviderScope.containerOf(context, listen: false);
    final oldOrder = [
      for (final i in routine.items)
        if (i.id != null) i.id!,
    ];
    try {
      await ref.read(routineRepoProvider).removeItem(itemId);
      if (!mounted) return;
      _refresh();
      _snack(
        'Removed "$title"',
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            final repo = container.read(routineRepoProvider);
            await repo.addDua(_id, item.duaId, repeatOverride: item.repeatOverride);
            final updated = await repo.get(_id);
            if (updated != null) {
              final added = updated.items
                  .where((i) => i.duaId == item.duaId && !oldOrder.contains(i.id))
                  .lastOrNull;
              if (added?.id != null) {
                final existing = {for (final i in updated.items) i.id};
                await repo.reorderItems(_id, [
                  for (final id in oldOrder)
                    if (id == itemId) added!.id! else if (existing.contains(id)) id,
                ]);
              }
            }
            container.invalidate(routineDetailProvider(_id));
            container.invalidate(routinesProvider);
          },
        ),
      );
    } catch (e) {
      _snack('Could not remove: $e');
    }
  }

  Future<void> _addDuas(Routine routine) async {
    final selected = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _AddDuasSheet(
        existingDuaIds: {for (final i in routine.items) i.duaId},
      ),
    );
    if (selected == null || selected.isEmpty || !mounted) return;
    try {
      final repo = ref.read(routineRepoProvider);
      for (final duaId in selected) {
        await repo.addDua(_id, duaId);
      }
      if (!mounted) return;
      _refresh();
      _snack('Added ${selected.length} ${selected.length == 1 ? 'dua' : 'duas'}');
    } catch (e) {
      _snack('Could not add duas: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final routineAsync = ref.watch(routineDetailProvider(_id));
    final duas = ref.watch(duasProvider).value ?? const <Dua>[];
    final byId = {for (final d in duas) d.id: d};
    final routine = routineAsync.value;
    final items = _optimistic ?? routine?.items ?? const <RoutineItem>[];

    return Scaffold(
      appBar: AppBar(
        title: Text(routine?.name ?? 'Routine'),
        actions: [
          if (routine != null)
            IconButton(
              tooltip: 'Rename routine',
              icon: const Icon(Icons.drive_file_rename_outline),
              onPressed: () => _rename(routine),
            ),
        ],
      ),
      floatingActionButton: routine == null
          ? null
          : FloatingActionButton.extended(
              heroTag: 'routine_add_duas',
              tooltip: 'Add duas to this routine',
              onPressed: () => _addDuas(routine),
              icon: const Icon(Icons.playlist_add),
              label: const Text('Add duas'),
            ),
      bottomNavigationBar: routine == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed: items.isEmpty ? null : () => openRecite(routineId: _id),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start'),
                ),
              ),
            ),
      body: routineAsync.when(
        skipLoadingOnReload: true,
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Could not load this routine.\n$e',
          onRetry: _refresh,
        ),
        data: (r) {
          if (r == null) {
            return const EmptyState(
              icon: Icons.playlist_remove,
              message: 'This routine no longer exists.',
            );
          }
          if (items.isEmpty) {
            return EmptyState(
              icon: Icons.playlist_add,
              title: 'No duas yet',
              message: 'Add duas from your library to build this routine.',
              action: FilledButton.icon(
                onPressed: () => _addDuas(r),
                icon: const Icon(Icons.playlist_add),
                label: const Text('Add duas'),
              ),
            );
          }
          return ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
            buildDefaultDragHandles: false,
            itemCount: items.length,
            onReorderItem: (o, n) => _reorder(items, o, n),
            itemBuilder: (context, i) {
              final item = items[i];
              final dua = byId[item.duaId];
              final itemId = item.id;
              final override = (itemId != null && _repeatEdits.containsKey(itemId))
                  ? _repeatEdits[itemId]
                  : item.repeatOverride;
              return _ItemTile(
                key: ValueKey<String>('item-${item.id ?? 'p${item.position}-$i'}'),
                index: i,
                dua: dua,
                repeatOverride: override,
                onRepeat: (v) => _setRepeat(item, dua, v),
                onRemove: () => _remove(r, item, dua?.title ?? 'dua'),
              );
            },
          );
        },
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({
    super.key,
    required this.index,
    required this.dua,
    required this.repeatOverride,
    required this.onRepeat,
    required this.onRemove,
  });

  final int index;
  final Dua? dua;
  final int? repeatOverride;
  final ValueChanged<int> onRepeat;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = dua;
    final defaultRepeat = d?.defaultRepeat ?? 1;
    final effective = repeatOverride ?? defaultRepeat;
    final title = d?.title ?? 'Deleted dua';
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: d == null ? theme.colorScheme.onSurfaceVariant : null,
                      fontStyle: d == null ? FontStyle.italic : null,
                    ),
                  ),
                  if (d != null)
                    Align(
                      alignment: Alignment.centerRight,
                      child: ArabicText(d.arabic, maxLines: 1, size: 20),
                    )
                  else
                    Text(
                      'This dua was deleted and will be skipped.',
                      style: theme.textTheme.bodySmall,
                    ),
                  if (d != null)
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 4,
                      children: [
                        NumberStepper(value: effective, onChanged: onRepeat),
                        Text(
                          repeatOverride == null
                              ? 'default ×$defaultRepeat'
                              : 'custom · default ×$defaultRepeat',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                        if (repeatOverride != null && repeatOverride != defaultRepeat)
                          TextButton(
                            onPressed: () => onRepeat(defaultRepeat),
                            child: const Text('Reset'),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Remove $title from routine',
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: onRemove,
            ),
            ReorderableDragStartListener(
              index: index,
              child: Semantics(
                label: 'Drag to reorder $title',
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(Icons.drag_handle),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet listing library duas with checkboxes. Pops with the selected
/// dua ids.
class _AddDuasSheet extends ConsumerStatefulWidget {
  const _AddDuasSheet({required this.existingDuaIds});

  final Set<int> existingDuaIds;

  @override
  ConsumerState<_AddDuasSheet> createState() => _AddDuasSheetState();
}

class _AddDuasSheetState extends ConsumerState<_AddDuasSheet> {
  final List<int> _selected = [];
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final duasAsync = ref.watch(duasProvider);
    final theme = Theme.of(context);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.85,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(child: Text('Add duas', style: theme.textTheme.titleLarge)),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Search duas',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: duasAsync.when(
              loading: () => const LoadingState(),
              error: (e, _) => ErrorState(
                message: 'Could not load your duas.\n$e',
                onRetry: () => ref.invalidate(duasProvider),
              ),
              data: (duas) {
                final list = _query.isEmpty
                    ? duas
                    : duas
                        .where((d) =>
                            d.title.toLowerCase().contains(_query) ||
                            d.category.toLowerCase().contains(_query) ||
                            d.translation.toLowerCase().contains(_query))
                        .toList();
                if (duas.isEmpty) {
                  return const EmptyState(
                    icon: Icons.menu_book_outlined,
                    message: 'Your library is empty. Add duas in the Library tab first.',
                  );
                }
                if (list.isEmpty) {
                  return const EmptyState(icon: Icons.search_off, message: 'No duas match.');
                }
                return ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final d = list[i];
                    final id = d.id;
                    final inRoutine = widget.existingDuaIds.contains(id);
                    return CheckboxListTile(
                      value: id != null && _selected.contains(id),
                      onChanged: id == null
                          ? null
                          : (on) => setState(() {
                                if (on ?? false) {
                                  _selected.add(id);
                                } else {
                                  _selected.remove(id);
                                }
                              }),
                      title: Text(d.title),
                      subtitle: Text(
                        [
                          d.category,
                          '×${d.defaultRepeat}',
                          if (inRoutine) 'Already in routine',
                        ].join(' · '),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _selected.isEmpty
                      ? null
                      : () => Navigator.of(context).pop(List<int>.of(_selected)),
                  child: Text(
                    _selected.isEmpty
                        ? 'Select duas to add'
                        : 'Add ${_selected.length} ${_selected.length == 1 ? 'dua' : 'duas'}',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
