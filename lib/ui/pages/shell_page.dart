import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../providers.dart';
import '../../services/terminal_session.dart';

/// A terminal palette built from the app's own [ColorScheme] so the shell
/// tab reads as part of DroidDeck rather than a bolted-on widget — the
/// accent colours mirror logcat's priority palette.
TerminalTheme _terminalThemeFrom(ColorScheme scheme) => TerminalTheme(
      cursor: scheme.primary,
      selection: scheme.primary.withValues(alpha: 0.35),
      foreground: scheme.onSurface,
      background: scheme.surfaceContainerLowest,
      black: const Color(0xFF1B1B1B),
      red: const Color(0xFFE57373),
      green: const Color(0xFF81C784),
      yellow: const Color(0xFFFFB74D),
      blue: const Color(0xFF4FC3F7),
      magenta: const Color(0xFFCE93D8),
      cyan: const Color(0xFF4DD0E1),
      white: const Color(0xFFE0E0E0),
      brightBlack: const Color(0xFF757575),
      brightRed: const Color(0xFFEF9A9A),
      brightGreen: const Color(0xFFA5D6A7),
      brightYellow: const Color(0xFFFFCC80),
      brightBlue: const Color(0xFF90CAF9),
      brightMagenta: const Color(0xFFE1BEE7),
      brightCyan: const Color(0xFF80DEEA),
      brightWhite: const Color(0xFFFFFFFF),
      searchHitBackground: const Color(0xFFFFFF2B),
      searchHitBackgroundCurrent: const Color(0xFF31FF26),
      searchHitForeground: const Color(0xFF000000),
    );

/// Interactive `adb shell` (left) plus a quick-actions panel (right) for the
/// globally-selected device.
class ShellPage extends ConsumerStatefulWidget {
  const ShellPage({super.key});

  @override
  ConsumerState<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends ConsumerState<ShellPage> {
  // Purely local/cosmetic — DroidDeck doesn't poll the device for its actual
  // rotation/density/size, so these just reflect the last preset applied
  // from this panel.
  int _rotationQuadrant = 0;
  int? _density;
  String? _size;

  @override
  Widget build(BuildContext context) {
    final serial = ref.watch(selectedSerialProvider);
    final session = ref.watch(terminalSessionProvider);
    final scheme = Theme.of(context).colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _terminalArea(serial, session, scheme)),
        const VerticalDivider(width: 1, thickness: 1),
        SizedBox(
          width: 320,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Text('Quick actions', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              if (serial == null) ...[
                _noDeviceHint(scheme),
                const SizedBox(height: 12),
              ],
              _navCard(serial),
              const SizedBox(height: 12),
              _rotationCard(serial),
              const SizedBox(height: 12),
              _displayCard(serial, scheme),
              const SizedBox(height: 12),
              _dumpsysCard(serial),
            ],
          ),
        ),
      ],
    );
  }

  // ----------------------------------------------------------- terminal ---

  Widget _terminalArea(
      String? serial, TerminalSession session, ColorScheme scheme) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: Row(
                children: [
                  Chip(
                    avatar: Icon(Icons.smartphone,
                        size: 16, color: scheme.onSurfaceVariant),
                    label: Text(serial ?? 'no device'),
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 8),
                  if (serial != null)
                    Text(
                      session.running ? 'running' : 'not running',
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  const Spacer(),
                  IconButton(
                    key: const ValueKey('shell.restart'),
                    tooltip: 'Restart session',
                    onPressed: serial == null ? null : session.restart,
                    icon: const Icon(Icons.restart_alt),
                  ),
                ],
              ),
            ),
            if (session.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(session.error!,
                    style: TextStyle(color: scheme.error, fontSize: 12)),
              ),
            if (!session.running && session.exitCode != null)
              Material(
                color: scheme.errorContainer,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline,
                          size: 18, color: scheme.onErrorContainer),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'exited (code ${session.exitCode}) —',
                          style: TextStyle(color: scheme.onErrorContainer),
                        ),
                      ),
                      TextButton(
                        onPressed: session.restart,
                        child: const Text('Restart'),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: serial == null
                  ? Center(
                      child: Text('Connect a device to open a shell',
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                    )
                  : Container(
                      key: const ValueKey('shell.terminal'),
                      color: scheme.surfaceContainerLowest,
                      padding: const EdgeInsets.all(4),
                      child: TerminalView(
                        session.terminal,
                        theme: _terminalThemeFrom(scheme),
                        autofocus: true,
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  // ------------------------------------------------------- quick actions --

  Widget _noDeviceHint(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.phonelink_off, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Connect a device to enable these actions.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _navCard(String? serial) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Navigation', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _navButton(Icons.arrow_back, 'Back',
                      const ValueKey('qa.back'), serial, 4),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _navButton(Icons.home_outlined, 'Home',
                      const ValueKey('qa.home'), serial, 3),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _navButton(Icons.apps, 'Recents',
                      const ValueKey('qa.recents'), serial, 187),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _navButton(Icons.power_settings_new, 'Power',
                      const ValueKey('qa.power'), serial, 26),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _navButton(
      IconData icon, String label, Key key, String? serial, int code) {
    return OutlinedButton(
      key: key,
      onPressed: serial == null ? null : () => _keyevent(serial, code),
      style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 10)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }

  Widget _rotationCard(String? serial) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Rotation', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            SegmentedButton<int>(
              key: const ValueKey('qa.rotation'),
              segments: const [
                ButtonSegment(value: 0, label: Text('0°')),
                ButtonSegment(value: 1, label: Text('90°')),
                ButtonSegment(value: 2, label: Text('180°')),
                ButtonSegment(value: 3, label: Text('270°')),
              ],
              selected: {_rotationQuadrant},
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onSelectionChanged: serial == null
                  ? null
                  : (s) => _applyRotation(serial, s.first),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: ActionChip(
                key: const ValueKey('qa.autoRotate'),
                avatar: const Icon(Icons.screen_rotation, size: 16),
                label: const Text('Auto'),
                onPressed:
                    serial == null ? null : () => _restoreAutoRotate(serial),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _displayCard(String? serial, ColorScheme scheme) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Display presets',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            Row(
              children: [
                const SizedBox(width: 56, child: Text('Density')),
                Expanded(
                  child: DropdownButton<int?>(
                    key: const ValueKey('qa.density'),
                    isExpanded: true,
                    value: _density,
                    items: const [
                      DropdownMenuItem(value: 320, child: Text('320 dpi')),
                      DropdownMenuItem(value: 420, child: Text('420 dpi')),
                      DropdownMenuItem(value: 480, child: Text('480 dpi')),
                      DropdownMenuItem(value: 560, child: Text('560 dpi')),
                      DropdownMenuItem(value: null, child: Text('Reset')),
                    ],
                    onChanged:
                        serial == null ? null : (v) => _applyDensity(serial, v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const SizedBox(width: 56, child: Text('Size')),
                Expanded(
                  child: DropdownButton<String?>(
                    key: const ValueKey('qa.size'),
                    isExpanded: true,
                    value: _size,
                    items: const [
                      DropdownMenuItem(
                          value: '720x1280', child: Text('720×1280')),
                      DropdownMenuItem(
                          value: '1080x1920', child: Text('1080×1920')),
                      DropdownMenuItem(
                          value: '1440x2560', child: Text('1440×2560')),
                      DropdownMenuItem(value: null, child: Text('Reset')),
                    ],
                    onChanged:
                        serial == null ? null : (v) => _applySize(serial, v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'These override the real device configuration and stay in '
              'effect until you pick Reset.',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dumpsysCard(String? serial) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Dumpsys shortcuts',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            _dumpsysButton(const ValueKey('qa.battery'), 'battery', serial),
            const SizedBox(height: 8),
            _dumpsysButton(
                const ValueKey('qa.activityTop'), 'activity top', serial),
            const SizedBox(height: 8),
            _dumpsysButton(const ValueKey('qa.meminfo'), 'meminfo', serial),
          ],
        ),
      ),
    );
  }

  Widget _dumpsysButton(Key key, String section, String? serial) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        key: key,
        onPressed: serial == null ? null : () => _showDumpsys(serial, section),
        child: Text(section),
      ),
    );
  }

  // --------------------------------------------------------------- logic --

  Future<void> _keyevent(String serial, int code) => _fireAndForget(
      () => ref.read(quickActionsServiceProvider).keyevent(serial, code));

  Future<void> _applyRotation(String serial, int quadrant) async {
    setState(() => _rotationQuadrant = quadrant);
    await _fireAndForget(() =>
        ref.read(quickActionsServiceProvider).setRotation(serial, quadrant));
  }

  Future<void> _restoreAutoRotate(String serial) => _fireAndForget(
      () => ref.read(quickActionsServiceProvider).setAutoRotate(serial, true));

  Future<void> _applyDensity(String serial, int? dpi) async {
    setState(() => _density = dpi);
    await _applyPreset(
      () => ref.read(quickActionsServiceProvider).density(serial, dpi),
      dpi == null ? 'Density reset' : 'Density set to $dpi dpi',
    );
  }

  Future<void> _applySize(String serial, String? wxh) async {
    setState(() => _size = wxh);
    await _applyPreset(
      () => ref.read(quickActionsServiceProvider).size(serial, wxh),
      wxh == null ? 'Size reset' : 'Size set to $wxh',
    );
  }

  void _showDumpsys(String serial, String section) {
    final future = ref.read(quickActionsServiceProvider).dumpsys(serial, section);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(section),
        content: SizedBox(
          width: 560,
          height: 420,
          child: FutureBuilder<String>(
            future: future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final text = snap.hasError ? '${snap.error}' : (snap.data ?? '');
              return Scrollbar(
                child: SingleChildScrollView(
                  child: SelectableText(
                    text,
                    key: const ValueKey('qa.dumpout'),
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _fireAndForget(Future<void> Function() action) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _applyPreset(
      Future<void> Function() action, String successMessage) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      messenger.showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }
}
