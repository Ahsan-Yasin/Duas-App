import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/navigation.dart';
import '../../core/providers.dart';
import '../../core/widgets/common.dart';
import '../../domain/arabic.dart';
import '../chat/chat_screen.dart';
import 'dua_editor_screen.dart';

/// Soft-deletes [dua] and shows a "Deleted" SnackBar with Undo. The undo
/// action only uses the [ProviderContainer], so it keeps working after the
/// calling screen has been popped.
Future<void> deleteDuaWithUndo(
  BuildContext context,
  Dua dua, {
  VoidCallback? onUndone,
}) async {
  final id = dua.id;
  if (id == null) return;
  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.of(context);
  await container.read(duaRepoProvider).softDelete(id);
  invalidateContainerData(container);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('Deleted "${dua.title}"'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await container.read(duaRepoProvider).restore(id);
            invalidateContainerData(container);
            onUndone?.call();
          },
        ),
      ),
    );
}

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  final _searchController = TextEditingController();
  String _query = '';
  String? _category;

  /// Ids removed by a swipe, hidden until the provider reloads.
  final Set<int> _hidden = {};

  /// Order shown while a drag-reorder is being saved.
  List<Dua>? _optimistic;

  bool get _filtering => _query.trim().isNotEmpty || _category != null;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Dua> _visible(List<Dua> all) {
    final q = _query.trim().toLowerCase();
    final arabicQuery = q.isNotEmpty && isArabic(q) ? normalizeArabic(q) : null;
    return all.where((d) {
      if (_hidden.contains(d.id)) return false;
      if (_category != null && d.category != _category) return false;
      if (q.isEmpty) return true;
      if (arabicQuery != null) return normalizeArabic(d.arabic).contains(arabicQuery);
      return d.title.toLowerCase().contains(q) ||
          d.translation.toLowerCase().contains(q) ||
          d.transliteration.toLowerCase().contains(q) ||
          d.source.toLowerCase().contains(q) ||
          d.category.toLowerCase().contains(q);
    }).toList();
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _query = '';
      _category = null;
    });
  }

  Future<void> _openEditor({int? duaId}) async {
    await pushScreen<void>(DuaEditorScreen(duaId: duaId));
    if (mounted) invalidateData(ref);
  }

  Future<void> _delete(Dua dua) async {
    final id = dua.id;
    if (id == null) return;
    setState(() => _hidden.add(id));
    try {
      await deleteDuaWithUndo(
        context,
        dua,
        onUndone: () {
          if (mounted) setState(() => _hidden.remove(id));
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _hidden.remove(id));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not delete: $e')));
    }
  }

  Future<void> _reorder(List<Dua> current, int oldIndex, int newIndex) async {
    final list = [...current];
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex.clamp(0, list.length), moved);
    setState(() => _optimistic = list);
    try {
      await ref.read(duaRepoProvider).reorder([
        for (final d in list)
          if (d.id != null) d.id!,
      ]);
      ref.invalidate(duasProvider);
      await ref.read(duasProvider.future);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save the new order: $e')));
      }
    } finally {
      if (mounted) setState(() => _optimistic = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final duasAsync = ref.watch(duasProvider);
    final categories = ref.watch(categoriesProvider).value ?? const <String>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            tooltip: 'Chat to add duas',
            icon: const Icon(Icons.chat_bubble_outline),
            onPressed: () async {
              await pushScreen<void>(const ChatScreen());
              if (mounted) invalidateData(ref);
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'library_add',
        tooltip: 'Add a dua',
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('Add dua'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'Search duas',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
          ),
          if (categories.isNotEmpty)
            SizedBox(
              height: 56,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: const Text('All'),
                      selected: _category == null,
                      onSelected: (_) => setState(() => _category = null),
                    ),
                  ),
                  for (final c in categories)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(c),
                        selected: _category == c,
                        onSelected: (on) => setState(() => _category = on ? c : null),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: duasAsync.when(
              loading: () => const LoadingState(message: 'Loading your duas…'),
              error: (e, _) => ErrorState(
                message: 'Could not load your duas.\n$e',
                onRetry: () => ref.invalidate(duasProvider),
              ),
              data: (all) => _buildList(all),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(List<Dua> all) {
    final visible = _filtering ? _visible(all) : (_optimistic ?? _visible(all));
    if (visible.isEmpty) {
      if (_filtering) {
        return EmptyState(
          icon: Icons.search_off,
          message: _query.trim().isEmpty
              ? 'No duas in this category.'
              : 'No duas match "${_query.trim()}".',
          action: TextButton(onPressed: _clearFilters, child: const Text('Clear filters')),
        );
      }
      return EmptyState(
        icon: Icons.menu_book_outlined,
        title: 'Your library is empty',
        message: 'Add a dua yourself or ask the chat for suggestions.',
        action: FilledButton.icon(
          onPressed: () => _openEditor(),
          icon: const Icon(Icons.add),
          label: const Text('Add dua'),
        ),
      );
    }

    const padding = EdgeInsets.fromLTRB(12, 4, 12, 96);
    if (_filtering) {
      return ListView.builder(
        padding: padding,
        itemCount: visible.length,
        itemBuilder: (context, i) => _tile(visible[i], i, reorderable: false),
      );
    }
    return ReorderableListView.builder(
      padding: padding,
      buildDefaultDragHandles: false,
      itemCount: visible.length,
      onReorderItem: (oldIndex, newIndex) => _reorder(visible, oldIndex, newIndex),
      itemBuilder: (context, i) => _tile(visible[i], i, reorderable: true),
    );
  }

  Widget _tile(Dua dua, int index, {required bool reorderable}) {
    return Dismissible(
      key: ValueKey<String>('dua-${dua.id}'),
      direction: DismissDirection.endToStart,
      background: const _DeleteBackground(),
      onDismissed: (_) => _delete(dua),
      child: DuaTile(
        dua: dua,
        dragIndex: reorderable ? index : null,
        onTap: () => _openEditor(duaId: dua.id),
        onDelete: () => _delete(dua),
      ),
    );
  }
}

class _DeleteBackground extends StatelessWidget {
  const _DeleteBackground();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      alignment: AlignmentDirectional.centerEnd,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
    );
  }
}

/// Library row: title, one-line Arabic preview, repeat badge and
/// verification status. Shows a drag handle when [dragIndex] is set.
class DuaTile extends StatelessWidget {
  const DuaTile({
    super.key,
    required this.dua,
    required this.onTap,
    this.onDelete,
    this.dragIndex,
  });

  final Dua dua;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  final int? dragIndex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            dua.title,
                            style: theme.textTheme.titleMedium,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        RepeatBadge(dua.defaultRepeat),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Align(
                      alignment: Alignment.centerRight,
                      child: ArabicText(dua.arabic, maxLines: 1, size: 22),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        VerificationChip(
                          status: dua.verificationStatus,
                          note: dua.verificationNote,
                        ),
                        if (dua.category.isNotEmpty)
                          Text(
                            dua.category,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        if (dua.audioKind != AudioKind.none)
                          Icon(
                            Icons.volume_up_outlined,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                            semanticLabel: 'Has audio',
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'More actions for ${dua.title}',
                onSelected: (v) {
                  if (v == 'edit') onTap();
                  if (v == 'delete') onDelete?.call();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'edit',
                    child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Edit')),
                  ),
                  if (onDelete != null)
                    const PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        leading: Icon(Icons.delete_outline),
                        title: Text('Delete'),
                      ),
                    ),
                ],
              ),
              if (dragIndex != null)
                ReorderableDragStartListener(
                  index: dragIndex!,
                  child: Semantics(
                    label: 'Drag to reorder ${dua.title}',
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Icon(Icons.drag_handle),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
