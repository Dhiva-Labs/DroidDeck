import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../services/app_manager.dart';
import '../../services/portal_file_picker.dart';

enum _Segment { user, system, all }

class AppsPage extends ConsumerStatefulWidget {
  const AppsPage({super.key});

  @override
  ConsumerState<AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends ConsumerState<AppsPage> {
  final _searchCtrl = TextEditingController();
  _Segment _segment = _Segment.user;
  bool _dragging = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String? get _serial => ref.read(selectedSerialProvider);

  Future<void> _pickAndInstall() async {
    final paths = await PortalFilePicker.openFiles(
      title: 'Select APK to install',
      filter: ('Android packages', ['*.apk']),
    );
    if (paths.isEmpty) {
      if (mounted) {
        _manualPathInstall();
      }
      return;
    }
    await _install(paths.first);
  }

  /// Fallback when the portal is unavailable or was cancelled.
  Future<void> _manualPathInstall() async {
    final ctrl = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Install APK'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Path to .apk',
            hintText: '/home/you/app-release.apk',
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(ctrl.text),
            child: const Text('Install'),
          ),
        ],
      ),
    );
    if (path != null && path.trim().isNotEmpty) {
      await _install(path.trim());
    }
  }

  Future<void> _install(String apkPath) async {
    final serial = _serial;
    if (serial == null || !mounted) return;
    final svc = ref.read(appManagerProvider);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _InstallDialog(
        apkPath: apkPath,
        start: () => svc.install(serial, apkPath),
      ),
    );
    ref.invalidate(appsProvider);
  }

  Future<void> _confirmAnd(
    String verb,
    String pkg,
    Future<void> Function() action, {
    bool destructive = false,
  }) async {
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$verb $pkg?'),
        content: Text(destructive
            ? 'This cannot be undone.'
            : 'The app will lose its runtime state.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(backgroundColor: scheme.error)
                : null,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(verb),
          ),
        ],
      ),
    );
    if (ok == true) await _run(verb, action);
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      messenger.showSnackBar(SnackBar(content: Text('$label: done')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$label failed — $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final serial = ref.watch(selectedSerialProvider);
    final apps = ref.watch(appsProvider);

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) {
        setState(() => _dragging = false);
        final apk = detail.files
            .map((f) => f.path)
            .where((p) => p.toLowerCase().endsWith('.apk'))
            .toList();
        if (apk.isNotEmpty) _install(apk.first);
      },
      child: Container(
        decoration: _dragging
            ? BoxDecoration(
                border: Border.all(color: scheme.primary, width: 2),
              )
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 260,
                    child: TextField(
                      key: const ValueKey('apps.search'),
                      controller: _searchCtrl,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.search, size: 18),
                        labelText: 'Search packages',
                      ),
                    ),
                  ),
                  SegmentedButton<_Segment>(
                    key: const ValueKey('apps.segment'),
                    segments: const [
                      ButtonSegment(
                          value: _Segment.user, label: Text('User')),
                      ButtonSegment(
                          value: _Segment.system, label: Text('System')),
                      ButtonSegment(value: _Segment.all, label: Text('All')),
                    ],
                    selected: {_segment},
                    showSelectedIcon: false,
                    style:
                        const ButtonStyle(visualDensity: VisualDensity.compact),
                    onSelectionChanged: (s) =>
                        setState(() => _segment = s.first),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: () => ref.invalidate(appsProvider),
                    icon: const Icon(Icons.refresh),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('apps.install'),
                    onPressed: serial == null ? null : _pickAndInstall,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Install APK'),
                  ),
                  Text('drag an .apk anywhere on this page',
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            Expanded(
              child: serial == null
                  ? Center(
                      child: Text('Connect a device to manage apps',
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                    )
                  : apps.when(
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (e, _) => Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.error_outline,
                                color: scheme.error, size: 40),
                            const SizedBox(height: 8),
                            Text('Could not list packages:\n$e',
                                textAlign: TextAlign.center),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: () => ref.invalidate(appsProvider),
                              icon: const Icon(Icons.refresh),
                              label: const Text('Retry'),
                            ),
                          ],
                        ),
                      ),
                      data: (list) => _AppList(
                        list: list,
                        segment: _segment,
                        query: _searchCtrl.text.trim().toLowerCase(),
                        onAction: _onAction,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onAction(String action, AppPackage app) async {
    final serial = _serial;
    if (serial == null) return;
    final svc = ref.read(appManagerProvider);
    switch (action) {
      case 'launch':
        await _run('Launch', () => svc.launch(serial, app.package));
      case 'stop':
        await _run('Force-stop', () => svc.forceStop(serial, app.package));
      case 'clear':
        await _confirmAnd('Clear data of', app.package,
            () => svc.clearData(serial, app.package));
      case 'extract':
        await _run('Extract APK', () async {
          final dir = await svc.extractApk(serial, app.package);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('APK(s) saved to $dir')));
          }
        });
      case 'uninstall':
        await _confirmAnd(
          'Uninstall',
          app.package,
          () async {
            await svc.uninstall(serial, app.package);
            ref.invalidate(appsProvider);
          },
          destructive: true,
        );
    }
  }
}

class _AppList extends StatelessWidget {
  final List<AppPackage> list;
  final _Segment segment;
  final String query;
  final Future<void> Function(String action, AppPackage app) onAction;

  const _AppList({
    required this.list,
    required this.segment,
    required this.query,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final filtered = [
      for (final a in list)
        if ((segment == _Segment.all ||
                (segment == _Segment.user ? !a.system : a.system)) &&
            (query.isEmpty || a.package.toLowerCase().contains(query)))
          a,
    ];

    if (filtered.isEmpty) {
      return Center(
        child: Text('No matching packages',
            style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text('${filtered.length} packages',
              style:
                  TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: filtered.length,
            itemBuilder: (context, i) {
              final a = filtered[i];
              return ListTile(
                dense: true,
                leading: Icon(
                  a.system ? Icons.settings_applications : Icons.android,
                  color: a.system
                      ? scheme.onSurfaceVariant
                      : scheme.primary,
                ),
                title: Text(a.package),
                subtitle: Text(a.apkPath,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: PopupMenuButton<String>(
                  key: ValueKey('apps.menu.${a.package}'),
                  tooltip: 'Actions',
                  onSelected: (v) => onAction(v, a),
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                        value: 'launch', child: Text('Launch')),
                    const PopupMenuItem(
                        value: 'stop', child: Text('Force-stop')),
                    const PopupMenuItem(
                        value: 'clear', child: Text('Clear data…')),
                    const PopupMenuItem(
                        value: 'extract', child: Text('Extract APK')),
                    PopupMenuItem(
                      value: 'uninstall',
                      enabled: !a.system,
                      child: Text(
                        a.system ? 'Uninstall (system app)' : 'Uninstall…',
                        style: a.system
                            ? null
                            : TextStyle(color: scheme.error),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _InstallDialog extends StatefulWidget {
  final String apkPath;
  final Future<InstallSession> Function() start;

  const _InstallDialog({required this.apkPath, required this.start});

  @override
  State<_InstallDialog> createState() => _InstallDialogState();
}

class _InstallDialogState extends State<_InstallDialog> {
  final _lines = <String>[];
  int? _exitCode;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  Future<void> _begin() async {
    try {
      final session = await widget.start();
      session.lines.listen((l) {
        if (mounted) setState(() => _lines.add(l));
      });
      final code = await session.exitCode;
      if (mounted) setState(() => _exitCode = code);
    } catch (e) {
      if (mounted) {
        setState(() {
          _lines.add('$e');
          _exitCode = -1;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final done = _exitCode != null;
    final ok = _exitCode == 0 &&
        _lines.any((l) => l.contains('Success'));
    return AlertDialog(
      title: Text('Installing ${widget.apkPath.split('/').last}'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!done) const LinearProgressIndicator(),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(
                child: SelectableText(
                  _lines.isEmpty ? 'Starting…' : _lines.join('\n'),
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
            if (done) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(ok ? Icons.check_circle : Icons.error,
                      color: ok
                          ? Colors.greenAccent.shade400
                          : scheme.error,
                      size: 18),
                  const SizedBox(width: 8),
                  Text(ok ? 'Installed' : 'Failed (exit $_exitCode)'),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              done ? () => Navigator.of(context).pop() : null,
          child: const Text('Close'),
        ),
      ],
    );
  }
}
