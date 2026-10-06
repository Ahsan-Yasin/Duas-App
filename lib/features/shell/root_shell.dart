import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/navigation.dart';
import '../home/home_screen.dart';
import '../library/library_screen.dart';
import '../reminders/reminders_screen.dart';
import '../routines/routines_screen.dart';
import '../settings/more_screen.dart';

/// Bottom navigation shell: Home, Library, Routines, Reminders, More.
/// Tabs are built lazily on first visit and then kept alive.
class RootShell extends ConsumerStatefulWidget {
  const RootShell({super.key});

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell> {
  final Set<int> _visited = {0};

  static const _destinations = <NavigationDestination>[
    NavigationDestination(
      icon: Icon(Icons.home_outlined),
      selectedIcon: Icon(Icons.home),
      label: 'Home',
    ),
    NavigationDestination(
      icon: Icon(Icons.menu_book_outlined),
      selectedIcon: Icon(Icons.menu_book),
      label: 'Library',
    ),
    NavigationDestination(
      icon: Icon(Icons.playlist_play_outlined),
      selectedIcon: Icon(Icons.playlist_play),
      label: 'Routines',
    ),
    NavigationDestination(
      icon: Icon(Icons.alarm_outlined),
      selectedIcon: Icon(Icons.alarm),
      label: 'Reminders',
    ),
    NavigationDestination(
      icon: Icon(Icons.more_horiz),
      selectedIcon: Icon(Icons.more_horiz),
      label: 'More',
    ),
  ];

  Widget _tab(int index) {
    if (!_visited.contains(index)) return const SizedBox.shrink();
    return switch (index) {
      0 => const HomeScreen(),
      1 => const LibraryScreen(),
      2 => const RoutinesScreen(),
      3 => const RemindersScreen(),
      _ => const MoreScreen(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(shellTabProvider);
    _visited.add(index);
    return PopScope(
      canPop: index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) ref.read(shellTabProvider.notifier).select(ShellTab.home);
      },
      child: Scaffold(
        body: IndexedStack(
          index: index,
          children: [for (var i = 0; i < _destinations.length; i++) _tab(i)],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (i) =>
              ref.read(shellTabProvider.notifier).selectIndex(i),
          destinations: _destinations,
        ),
      ),
    );
  }
}
