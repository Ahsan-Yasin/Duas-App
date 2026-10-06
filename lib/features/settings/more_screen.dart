import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/audio/quran_audio.dart' show reciterAttribution;
import '../../core/config.dart';
import '../../core/navigation.dart';
import '../../core/providers.dart';
import '../chat/chat_screen.dart';
import '../history/history_screen.dart';
import '../reliability/reliability_screen.dart';
import 'settings_screen.dart';

const _tanzilAttribution =
    'Quran text: Tanzil Project (Simple text, v1.1) — https://tanzil.net. '
    'Used verbatim under the Tanzil terms of use (CC BY 3.0; changing the text is not permitted).';
const _amiriAttribution =
    'Arabic font: Amiri by The Amiri Project Authors — SIL Open Font License 1.1.';
const _hadithAttribution =
    'Hadith: Sahih al-Bukhari 3371 (Arabic text as published on sunnah.com).';
const _meaningsAttribution =
    'English meanings and transliterations were written for this app and are not a published translation.';

/// Shows the About dialog with content attributions and licences.
void showAppAbout(BuildContext context, String reciterFolder) {
  showAboutDialog(
    context: context,
    applicationName: appName,
    applicationVersion: 'Version $appVersion',
    applicationIcon: Icon(Icons.menu_book_rounded,
        size: 40, color: Theme.of(context).colorScheme.primary),
    applicationLegalese:
        'Recite your daily duas with reminders, audio and a guided counter. Works offline.',
    children: [
      const SizedBox(height: 16),
      const Text(_tanzilAttribution),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: () => launchUrl(Uri.parse('https://tanzil.net'),
              mode: LaunchMode.externalApplication),
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('tanzil.net'),
        ),
      ),
      const Text(_amiriAttribution),
      const SizedBox(height: 8),
      Text(reciterAttribution(reciterFolder)),
      const SizedBox(height: 8),
      const Text(_hadithAttribution),
      const SizedBox(height: 8),
      const Text(_meaningsAttribution),
    ],
  );
}

class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reciter = ref.watch(settingsProvider.select((s) => s.reciter));
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _Tile(
            icon: Icons.auto_awesome_outlined,
            title: 'Ask for a dua',
            subtitle: 'AI suggestions for any situation (needs internet)',
            onTap: () => pushScreen<void>(const ChatScreen()),
          ),
          _Tile(
            icon: Icons.local_fire_department_outlined,
            title: 'History & streaks',
            subtitle: 'Your completed sessions by day',
            onTap: () => pushScreen<void>(const HistoryScreen()),
          ),
          const Divider(),
          _Tile(
            icon: Icons.settings_outlined,
            title: 'Settings',
            subtitle: 'Theme, Arabic text size, audio, AI',
            onTap: () => pushScreen<void>(const SettingsScreen()),
          ),
          _Tile(
            icon: Icons.health_and_safety_outlined,
            title: 'Alarm reliability',
            subtitle: 'Check that reminders will ring on time',
            onTap: () => pushScreen<void>(const ReliabilityScreen()),
          ),
          _Tile(
            icon: Icons.backup_outlined,
            title: 'Backup & restore',
            subtitle: 'Export or import your duas, routines and reminders',
            onTap: () => pushScreen<void>(
                const SettingsScreen(initialSection: SettingsSection.backup)),
          ),
          const Divider(),
          _Tile(
            icon: Icons.info_outline,
            title: 'About',
            subtitle: '$appName $appVersion · credits and licences',
            onTap: () => showAppAbout(context, reciter),
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      minVerticalPadding: 12,
      onTap: onTap,
    );
  }
}
