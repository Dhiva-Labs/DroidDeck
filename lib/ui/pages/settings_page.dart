import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../services/tool_locator.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController _adbCtrl;
  late final TextEditingController _scrcpyCtrl;

  @override
  void initState() {
    super.initState();
    final repo = ref.read(settingsRepoProvider);
    _adbCtrl = TextEditingController(text: repo.adbOverride ?? '');
    _scrcpyCtrl = TextEditingController(text: repo.scrcpyOverride ?? '');
  }

  @override
  void dispose() {
    _adbCtrl.dispose();
    _scrcpyCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final repo = ref.read(settingsRepoProvider);
    await repo.setAdbOverride(_adbCtrl.text);
    await repo.setScrcpyOverride(_scrcpyCtrl.text);
    ref.invalidate(toolStatusProvider);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved — re-detecting tools…')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tools = ref.watch(toolStatusProvider);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Tools', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Detection order: custom path → \$PATH → common install locations.',
          style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        _ToolCard(
          title: 'adb',
          info: tools.value?.adb,
          loading: tools.isLoading,
          controller: _adbCtrl,
          hintText: '/home/you/Android/Sdk/platform-tools/adb',
          missingHelp:
              'Install Android platform-tools (part of the Android SDK), '
              'or point this at an adb binary.',
        ),
        const SizedBox(height: 12),
        _ToolCard(
          title: 'scrcpy',
          info: tools.value?.scrcpy,
          loading: tools.isLoading,
          controller: _scrcpyCtrl,
          hintText: '/usr/bin/scrcpy',
          missingHelp: 'Optional — used for screen mirroring. '
              'Install with: sudo apt install scrcpy',
        ),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.refresh),
            label: const Text('Save & re-detect'),
          ),
        ),
      ],
    );
  }
}

class _ToolCard extends StatelessWidget {
  final String title;
  final ToolInfo? info;
  final bool loading;
  final TextEditingController controller;
  final String hintText;
  final String missingHelp;

  const _ToolCard({
    required this.title,
    required this.info,
    required this.loading,
    required this.controller,
    required this.hintText,
    required this.missingHelp,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final found = info?.found ?? false;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  loading
                      ? Icons.hourglass_top
                      : (found ? Icons.check_circle : Icons.cancel),
                  size: 18,
                  color: loading
                      ? scheme.onSurfaceVariant
                      : (found ? Colors.greenAccent.shade400 : scheme.error),
                ),
                const SizedBox(width: 8),
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: 12),
                if (found)
                  Text('v${info!.version}',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              loading
                  ? 'detecting…'
                  : (found ? info!.path! : missingHelp),
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                labelText: 'Custom $title path (leave empty to auto-detect)',
                hintText: hintText,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
