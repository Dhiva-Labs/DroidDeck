import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/adb_device.dart';
import '../providers.dart';
import 'device_visuals.dart';
import 'pages/apps_page.dart';
import 'pages/devices_page.dart';
import 'pages/files_page.dart';
import 'pages/logcat_page.dart';
import 'pages/screen_page.dart';
import 'pages/settings_page.dart';
import 'pages/shell_page.dart';
import 'pages/wireless_page.dart';

class DroidDeckShell extends ConsumerStatefulWidget {
  const DroidDeckShell({super.key});

  @override
  ConsumerState<DroidDeckShell> createState() => _DroidDeckShellState();
}

class _DroidDeckShellState extends ConsumerState<DroidDeckShell> {
  // Startup tab override for development/screenshot tooling.
  int _index =
      int.tryParse(Platform.environment['DROIDDECK_TAB'] ?? '') ?? 0;
  bool _scrcpyHintDismissed = false;

  static const _sections = [
    (icon: Icons.devices, label: 'Devices'),
    (icon: Icons.subject, label: 'Logcat'),
    (icon: Icons.apps, label: 'Apps'),
    (icon: Icons.folder_outlined, label: 'Files'),
    (icon: Icons.screenshot_monitor, label: 'Screen'),
    (icon: Icons.wifi, label: 'Wireless'),
    (icon: Icons.terminal, label: 'Shell'),
    (icon: Icons.settings_outlined, label: 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.android),
            SizedBox(width: 10),
            Text('DroidDeck'),
          ],
        ),
        actions: const [
          _DeviceSelector(),
          SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          _toolBanner(),
          Expanded(
            child: Row(
              children: [
                NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: (i) => setState(() => _index = i),
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (final s in _sections)
                      NavigationRailDestination(
                        icon: Icon(s.icon),
                        label: Text(s.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(
                  child: IndexedStack(
                    index: _index,
                    children: const [
                      DevicesPage(),
                      LogcatPage(),
                      AppsPage(),
                      FilesPage(),
                      ScreenPage(),
                      WirelessPage(),
                      ShellPage(),
                      SettingsPage(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolBanner() {
    final status = ref.watch(toolStatusProvider);
    final scheme = Theme.of(context).colorScheme;
    return status.when(
      loading: () => const LinearProgressIndicator(minHeight: 2),
      error: (e, _) => _banner(
        color: scheme.errorContainer,
        fg: scheme.onErrorContainer,
        icon: Icons.error_outline,
        text: 'Tool detection failed: $e',
      ),
      data: (s) {
        if (!s.adb.found) {
          return _banner(
            color: scheme.errorContainer,
            fg: scheme.onErrorContainer,
            icon: Icons.error_outline,
            text:
                'adb not found — install Android platform-tools or set its path in Settings.',
            action: TextButton(
              onPressed: () => setState(() => _index = _sections.length - 1),
              child: const Text('Open Settings'),
            ),
          );
        }
        if (!s.scrcpy.found && !_scrcpyHintDismissed) {
          return _banner(
            color: scheme.surfaceContainerHighest,
            fg: scheme.onSurfaceVariant,
            icon: Icons.info_outline,
            text:
                'scrcpy not found — screen mirroring will be unavailable. Install it with:  sudo apt install scrcpy',
            action: IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => setState(() => _scrcpyHintDismissed = true),
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _banner({
    required Color color,
    required Color fg,
    required IconData icon,
    required String text,
    Widget? action,
  }) {
    return Material(
      color: color,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 18, color: fg),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: TextStyle(color: fg))),
            ?action,
          ],
        ),
      ),
    );
  }
}

/// Global device picker shown in the app bar.
class _DeviceSelector extends ConsumerWidget {
  const _DeviceSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider).value ?? const <AdbDevice>[];
    final selected = ref.watch(selectedSerialProvider);
    final scheme = Theme.of(context).colorScheme;

    if (devices.isEmpty) {
      return Chip(
        avatar: Icon(Icons.phonelink_off,
            size: 16, color: scheme.onSurfaceVariant),
        label: const Text('No devices'),
        visualDensity: VisualDensity.compact,
      );
    }

    final value = devices.any((d) => d.serial == selected) ? selected : null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          hint: const Text('Select device'),
          borderRadius: BorderRadius.circular(12),
          items: [
            for (final d in devices)
              DropdownMenuItem(
                value: d.serial,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(stateIcon(d.state),
                        size: 16, color: stateColor(scheme, d.state)),
                    const SizedBox(width: 8),
                    Text(d.displayName),
                    const SizedBox(width: 8),
                    Text(
                      d.serial,
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
          ],
          onChanged: (v) =>
              ref.read(selectedSerialProvider.notifier).select(v),
        ),
      ),
    );
  }
}
