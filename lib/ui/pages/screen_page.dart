import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../services/adb_service.dart';
import '../../services/portal_file_picker.dart';
import '../../services/screen_tools.dart';

String _pad2(int n) => n.toString().padLeft(2, '0');

/// yyyyMMdd-HHmmss, safe for filenames.
String _fileTs(DateTime t) => '${t.year}${_pad2(t.month)}${_pad2(t.day)}-'
    '${_pad2(t.hour)}${_pad2(t.minute)}${_pad2(t.second)}';

String _hhmmss(DateTime t) =>
    '${_pad2(t.hour)}:${_pad2(t.minute)}:${_pad2(t.second)}';

String _mmss(Duration d) => '${d.inMinutes}:${_pad2(d.inSeconds % 60)}';

const _scrcpyPresets = <String, List<String>>{
  'Default': [],
  'High quality': ['-b', '16M'],
  'Low latency': ['-b', '4M', '-m', '1024'],
};

/// Screenshot capture, screen recording and scrcpy mirroring for the
/// globally-selected device.
class ScreenPage extends ConsumerStatefulWidget {
  const ScreenPage({super.key});

  @override
  ConsumerState<ScreenPage> createState() => _ScreenPageState();
}

class _ScreenPageState extends ConsumerState<ScreenPage> {
  int _timeLimit = 180;
  String _preset = 'Default';
  bool _stayAwake = false;
  bool _turnScreenOff = false;
  bool _showTouches = false;
  bool _recordToFile = false;

  @override
  Widget build(BuildContext context) {
    final serial = ref.watch(selectedSerialProvider);
    final screencap = ref.watch(screencapProvider);
    final record = ref.watch(recordControllerProvider);
    final scrcpy = ref.watch(scrcpyControllerProvider);
    final toolStatus = ref.watch(toolStatusProvider);
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListenableBuilder(
        listenable: Listenable.merge([screencap, record, scrcpy]),
        builder: (context, _) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 380,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _screenshotCard(serial, screencap, scheme),
                    const SizedBox(height: 12),
                    _recordCard(serial, record, scheme),
                    const SizedBox(height: 12),
                    _scrcpyCard(serial, scrcpy, toolStatus.value, scheme),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _PreviewPanel(
                serial: serial,
                bytes: screencap.bytes,
                capturedAt: screencap.capturedAt,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------- screenshot --

  Widget _screenshotCard(
      String? serial, ScreencapController c, ColorScheme scheme) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Screenshot', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  key: const ValueKey('screen.capture'),
                  onPressed: (serial == null || c.busy)
                      ? null
                      : () => c.capture(serial),
                  icon: c.busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.camera_alt),
                  label: const Text('Capture'),
                ),
                if (c.bytes != null)
                  OutlinedButton(
                    key: const ValueKey('screen.save'),
                    onPressed: () => _saveScreenshot(c, serial),
                    child: const Text('Save…'),
                  ),
              ],
            ),
            if (c.error != null) ...[
              const SizedBox(height: 8),
              Text(c.error!,
                  style: TextStyle(color: scheme.error, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _saveScreenshot(ScreencapController c, String? serial) async {
    final messenger = ScaffoldMessenger.of(context);
    final name = 'droiddeck-${serial ?? 'device'}-'
        '${_fileTs(c.capturedAt ?? DateTime.now())}.png';
    final path = await PortalFilePicker.saveFile(
      title: 'Save screenshot',
      suggestedName: name,
      filter: ('PNG image', ['*.png']),
    );
    if (path == null) {
      messenger.showSnackBar(SnackBar(
        content: const Text('Save cancelled'),
        action: SnackBarAction(
          label: 'Save to ~/Pictures',
          onPressed: () => _saveToPictures(c, name),
        ),
      ));
      return;
    }
    try {
      await c.saveTo(path);
      messenger.showSnackBar(SnackBar(content: Text('Saved to $path')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  Future<void> _saveToPictures(ScreencapController c, String name) async {
    final home = Platform.environment['HOME'] ?? '.';
    final path = '$home/Pictures/droiddeck/$name';
    final messenger = ScaffoldMessenger.of(context);
    try {
      await c.saveTo(path);
      messenger.showSnackBar(SnackBar(content: Text('Saved to $path')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  // ------------------------------------------------------------ record ---

  Widget _recordCard(String? serial, RecordController c, ColorScheme scheme) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Screen recording',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            ..._recordBody(serial, c, scheme),
          ],
        ),
      ),
    );
  }

  List<Widget> _recordBody(
          String? serial, RecordController c, ColorScheme scheme) =>
      switch (c.status) {
        RecordStatus.recording => [
            Row(
              children: [
                const Icon(Icons.fiber_manual_record,
                    color: Colors.redAccent, size: 18),
                const SizedBox(width: 8),
                Text(_mmss(c.elapsed)),
                const Spacer(),
                FilledButton.icon(
                  key: const ValueKey('screen.stop'),
                  onPressed: () => c.stop(),
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
              ],
            ),
          ],
        RecordStatus.finalizing => const [
            LinearProgressIndicator(),
            SizedBox(height: 8),
            Text('Saving…'),
          ],
        RecordStatus.error => [
            Text(c.error ?? 'recording failed',
                style: TextStyle(color: scheme.error, fontSize: 12)),
            const SizedBox(height: 8),
            _startRow(serial, c, 'Start'),
            const SizedBox(height: 4),
            _capCaption(scheme),
          ],
        RecordStatus.done => [
            Row(
              children: [
                Icon(Icons.check_circle,
                    color: Colors.greenAccent.shade400, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: SelectableText(c.savedPath ?? '',
                      style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => _openFolder(c.savedPath),
                child: const Text('Open folder'),
              ),
            ),
            const Divider(height: 16),
            _startRow(serial, c, 'Record again'),
            const SizedBox(height: 4),
            _capCaption(scheme),
          ],
        RecordStatus.idle => [
            _startRow(serial, c, 'Start'),
            const SizedBox(height: 4),
            _capCaption(scheme),
          ],
      };

  Widget _capCaption(ColorScheme scheme) => Text(
        'screenrecord caps at 180 s per clip',
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      );

  Widget _startRow(String? serial, RecordController c, String label) {
    return Row(
      children: [
        DropdownButton<int>(
          value: _timeLimit,
          items: const [
            DropdownMenuItem(value: 30, child: Text('30 s')),
            DropdownMenuItem(value: 60, child: Text('60 s')),
            DropdownMenuItem(value: 180, child: Text('180 s (max)')),
          ],
          onChanged: (v) => setState(() => _timeLimit = v ?? 180),
        ),
        const SizedBox(width: 12),
        FilledButton.icon(
          key: const ValueKey('screen.record'),
          onPressed: serial == null
              ? null
              : () => c.start(serial, timeLimitSec: _timeLimit),
          icon: const Icon(Icons.fiber_manual_record),
          label: Text(label),
        ),
      ],
    );
  }

  Future<void> _openFolder(String? path) async {
    if (path == null) return;
    final dir = File(path).parent.path;
    await Process.run('xdg-open', [dir], environment: sanitizedEnv());
  }

  // ------------------------------------------------------------ scrcpy ---

  Widget _scrcpyCard(String? serial, ScrcpyController c, ToolStatus? status,
      ColorScheme scheme) {
    final found = status?.scrcpy.found ?? false;
    final body = found
        ? _scrcpyReadyBody(serial, status!, c)
        : _scrcpyMissingBody(scheme);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('scrcpy mirror',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            ...body,
            if (c.sessions.isNotEmpty) ...[
              const Divider(height: 20),
              for (final s in c.sessions) _sessionTile(s, c, scheme),
              if (c.sessions.any((s) => !s.running))
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: c.clearFinished,
                    child: const Text('Clear finished'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _scrcpyMissingBody(ColorScheme scheme) => [
        Row(
          children: [
            Icon(Icons.info_outline, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            const Expanded(child: Text('scrcpy is not installed')),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'sudo apt install scrcpy',
          style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => ref.invalidate(toolStatusProvider),
          child: const Text('Re-detect'),
        ),
      ];

  List<Widget> _scrcpyReadyBody(
      String? serial, ToolStatus status, ScrcpyController c) {
    return [
      Row(
        children: [
          const Text('Preset'),
          const SizedBox(width: 8),
          DropdownButton<String>(
            value: _preset,
            items: [
              for (final k in _scrcpyPresets.keys)
                DropdownMenuItem(value: k, child: Text(k)),
            ],
            onChanged: (v) => setState(() => _preset = v ?? 'Default'),
          ),
        ],
      ),
      CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text('--stay-awake'),
        value: _stayAwake,
        onChanged: (v) => setState(() => _stayAwake = v ?? false),
      ),
      CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text('--turn-screen-off'),
        value: _turnScreenOff,
        onChanged: (v) => setState(() => _turnScreenOff = v ?? false),
      ),
      CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text('--show-touches'),
        value: _showTouches,
        onChanged: (v) => setState(() => _showTouches = v ?? false),
      ),
      CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text('Record to file'),
        value: _recordToFile,
        onChanged: (v) => setState(() => _recordToFile = v ?? false),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed:
              serial == null ? null : () => _launchScrcpy(serial, status, c),
          icon: const Icon(Icons.cast_connected),
          label: const Text('Launch'),
        ),
      ),
    ];
  }

  Future<void> _launchScrcpy(
      String serial, ToolStatus status, ScrcpyController c) async {
    final home = Platform.environment['HOME'] ?? '.';
    final args = <String>[
      ..._scrcpyPresets[_preset]!,
      if (_stayAwake) '--stay-awake',
      if (_turnScreenOff) '--turn-screen-off',
      if (_showTouches) '--show-touches',
      if (_recordToFile) ...[
        '-r',
        '$home/Videos/droiddeck-scrcpy-${_fileTs(DateTime.now())}.mkv',
      ],
    ];
    await c.launch(
      scrcpyPath: status.scrcpy.path!,
      adbPath: status.adb.path!,
      serial: serial,
      description: _preset,
      args: args,
    );
  }

  Widget _sessionTile(ScrcpySession s, ScrcpyController c, ColorScheme scheme) {
    final chipBg = s.running
        ? scheme.primaryContainer
        : (s.exitCode == 0
            ? scheme.surfaceContainerHighest
            : scheme.errorContainer);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(s.description, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(s.serial,
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
              const SizedBox(width: 8),
              Chip(
                label: Text(s.running ? 'running' : 'exit ${s.exitCode}'),
                visualDensity: VisualDensity.compact,
                backgroundColor: chipBg,
              ),
            ],
          ),
          if (!s.running && s.exitCode != 0 && s.errTail.isNotEmpty)
            Text(
              s.errTail.join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: scheme.error),
            ),
        ],
      ),
      trailing: s.running
          ? IconButton(
              tooltip: 'Stop',
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: () => c.kill(s),
            )
          : null,
    );
  }
}

/// Right-hand preview: shows the last screenshot. Dimensions are decoded
/// once off the paint path purely to report pixel size in the caption.
class _PreviewPanel extends StatefulWidget {
  final String? serial;
  final Uint8List? bytes;
  final DateTime? capturedAt;

  const _PreviewPanel({
    required this.serial,
    required this.bytes,
    required this.capturedAt,
  });

  @override
  State<_PreviewPanel> createState() => _PreviewPanelState();
}

class _PreviewPanelState extends State<_PreviewPanel> {
  Uint8List? _decodedFor;
  int? _w;
  int? _h;

  @override
  void initState() {
    super.initState();
    _maybeDecode();
  }

  @override
  void didUpdateWidget(covariant _PreviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeDecode();
  }

  void _maybeDecode() {
    final b = widget.bytes;
    if (b == null || identical(b, _decodedFor)) return;
    _decodedFor = b;
    decodeImageFromList(b).then((image) {
      if (!mounted || !identical(widget.bytes, b)) return;
      setState(() {
        _w = image.width;
        _h = image.height;
      });
      image.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final b = widget.bytes;
    if (b == null) {
      final noDevice = widget.serial == null;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(noDevice ? Icons.phonelink_off : Icons.screenshot_monitor,
                size: 72, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              noDevice
                  ? 'Connect a device to use screen tools'
                  : 'Capture a screenshot to preview it here',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    final caption = [
      if (widget.capturedAt != null)
        'captured ${_hhmmss(widget.capturedAt!)}',
      if (_w != null && _h != null) '$_w×$_h px',
    ].join('  ·  ');
    return Column(
      children: [
        Expanded(
          child: DecoratedBox(
            decoration:
                BoxDecoration(border: Border.all(color: scheme.outlineVariant)),
            child: InteractiveViewer(
              child: Image.memory(
                b,
                key: const ValueKey('screen.preview'),
                fit: BoxFit.contain,
                gaplessPlayback: true,
              ),
            ),
          ),
        ),
        if (caption.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(caption,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
      ],
    );
  }
}
