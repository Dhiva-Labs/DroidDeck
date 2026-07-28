import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/log_line.dart';
import '../../providers.dart';
import '../../services/logcat_controller.dart';

const _mono = TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.0);

Color priorityColor(String p) => switch (p) {
      'V' => const Color(0xFF90A4AE),
      'D' => const Color(0xFF4FC3F7),
      'I' => const Color(0xFF81C784),
      'W' => const Color(0xFFFFB74D),
      'E' => const Color(0xFFE57373),
      'F' => const Color(0xFFCE93D8),
      _ => const Color(0xFF757575),
    };

class LogcatPage extends ConsumerStatefulWidget {
  const LogcatPage({super.key});

  @override
  ConsumerState<LogcatPage> createState() => _LogcatPageState();
}

class _LogcatPageState extends ConsumerState<LogcatPage> {
  final _tagCtrl = TextEditingController();
  final _textCtrl = TextEditingController();
  final _pkgCtrl = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;
  bool _showJump = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final show = _scroll.offset > 80;
      if (show != _showJump) setState(() => _showJump = show);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tagCtrl.dispose();
    _textCtrl.dispose();
    _pkgCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _applyTextFilters() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      ref.read(logcatControllerProvider).setFilters(
            tag: _tagCtrl.text,
            text: _textCtrl.text,
            package: _pkgCtrl.text,
          );
    });
  }

  Future<void> _export(LogcatController c) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await c.exportView();
      messenger.showSnackBar(SnackBar(content: Text('Exported to $path')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(logcatControllerProvider);
    final scheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  IconButton(
                    key: const ValueKey('logcat.pause'),
                    tooltip: c.paused ? 'Resume' : 'Pause view',
                    onPressed: c.serial == null
                        ? null
                        : () =>
                            c.paused ? c.resumeView() : c.pauseView(),
                    icon: Icon(c.paused
                        ? Icons.play_arrow
                        : Icons.pause),
                  ),
                  if (!c.running && c.serial != null)
                    IconButton(
                      key: const ValueKey('logcat.restart'),
                      tooltip: 'Restart stream',
                      onPressed: () => c.start(),
                      icon: const Icon(Icons.restart_alt),
                    ),
                  IconButton(
                    key: const ValueKey('logcat.clear'),
                    tooltip: 'Clear (logcat -c)',
                    onPressed: c.serial == null ? null : () => c.clear(),
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
                  IconButton(
                    key: const ValueKey('logcat.export'),
                    tooltip: 'Export current view to ~/Downloads',
                    onPressed: c.viewLength == 0 ? null : () => _export(c),
                    icon: const Icon(Icons.download_outlined),
                  ),
                  SegmentedButton<int>(
                    key: const ValueKey('logcat.priority'),
                    segments: [
                      for (final e in LogLine.priorityRanks.entries)
                        ButtonSegment(value: e.value, label: Text(e.key)),
                    ],
                    selected: {c.minPriorityRank},
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                        visualDensity: VisualDensity.compact),
                    onSelectionChanged: (s) =>
                        c.setFilters(minRank: s.first),
                  ),
                  SizedBox(
                    width: 130,
                    child: TextField(
                      key: const ValueKey('logcat.tag'),
                      controller: _tagCtrl,
                      onChanged: (_) => _applyTextFilters(),
                      decoration: const InputDecoration(
                          isDense: true, labelText: 'Tag'),
                    ),
                  ),
                  SizedBox(
                    width: 170,
                    child: TextField(
                      key: const ValueKey('logcat.text'),
                      controller: _textCtrl,
                      onChanged: (_) => _applyTextFilters(),
                      decoration: const InputDecoration(
                          isDense: true, labelText: 'Contains'),
                    ),
                  ),
                  SizedBox(
                    width: 190,
                    child: TextField(
                      key: const ValueKey('logcat.package'),
                      controller: _pkgCtrl,
                      onChanged: (_) => _applyTextFilters(),
                      decoration: const InputDecoration(
                          isDense: true, labelText: 'Package'),
                    ),
                  ),
                  if (c.packageFilter.isNotEmpty)
                    Chip(
                      key: const ValueKey('logcat.pidChip'),
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(
                        c.packagePid == null
                            ? Icons.error_outline
                            : Icons.memory,
                        size: 16,
                        color: c.packagePid == null
                            ? scheme.error
                            : scheme.primary,
                      ),
                      label: Text(c.packagePid == null
                          ? 'not running'
                          : 'pid ${c.packagePid}'),
                    ),
                  Text(
                    '${c.viewLength} / ${c.bufferLength}'
                    '${c.bufferLength >= LogcatController.capacity ? ' (ring full)' : ''}',
                    key: const ValueKey('logcat.counter'),
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (c.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(c.error!,
                    style: TextStyle(color: scheme.error, fontSize: 12)),
              ),
            if (c.serial == null)
              Expanded(
                child: Center(
                  child: Text('Connect a device to stream logcat',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
              )
            else
              Expanded(
                child: Stack(
                  children: [
                    ColoredBox(
                      color: scheme.surfaceContainerLowest,
                      child: ListView.builder(
                        key: const ValueKey('logcat.list'),
                        controller: _scroll,
                        reverse: true,
                        itemExtent: 20,
                        itemCount: c.viewLength,
                        itemBuilder: (context, i) =>
                            _Row(line: c.viewAt(c.viewLength - 1 - i)),
                      ),
                    ),
                    if (_showJump)
                      Positioned(
                        right: 16,
                        bottom: 16,
                        child: FloatingActionButton.small(
                          tooltip: 'Jump to latest',
                          onPressed: () => _scroll.jumpTo(0),
                          child: const Icon(Icons.arrow_downward),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Row extends StatelessWidget {
  final LogLine line;

  const _Row({required this.line});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (line.isMeta) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            line.raw,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _mono.copyWith(
                color: scheme.onSurfaceVariant,
                fontStyle: FontStyle.italic),
          ),
        ),
      );
    }
    final pc = priorityColor(line.priority);
    final isLoud = line.priority == 'E' || line.priority == 'F';
    return InkWell(
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('${line.priority}/${line.tag}'),
          content: SelectableText(line.raw, style: _mono),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
      child: Container(
        color: isLoud ? pc.withValues(alpha: 0.08) : null,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.centerLeft,
        child: Text.rich(
          TextSpan(children: [
            TextSpan(
                text: '${line.time}  ',
                style: TextStyle(color: scheme.onSurfaceVariant)),
            TextSpan(
                text:
                    '${line.pid}'.padLeft(5) + '/${line.tid} '.padRight(7),
                style: TextStyle(color: scheme.onSurfaceVariant)),
            TextSpan(
                text: ' ${line.priority} ',
                style: TextStyle(
                    color: pc, fontWeight: FontWeight.bold)),
            TextSpan(text: '${line.tag}: ', style: TextStyle(color: pc)),
            TextSpan(text: line.message ?? ''),
          ]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _mono,
        ),
      ),
    );
  }
}
