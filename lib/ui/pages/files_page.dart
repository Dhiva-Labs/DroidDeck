import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/fs_entry.dart';
import '../../providers.dart';

IconData _fileIcon(FsEntry e) {
  if (e.isLink) return Icons.link;
  if (e.isDir) return Icons.folder;
  final ext = e.name.contains('.')
      ? e.name.substring(e.name.lastIndexOf('.') + 1).toLowerCase()
      : '';
  return switch (ext) {
    'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' => Icons.image,
    'mp4' || 'mkv' || 'webm' || 'avi' || '3gp' => Icons.movie,
    'mp3' || 'ogg' || 'flac' || 'wav' || 'm4a' => Icons.music_note,
    'apk' => Icons.android,
    'zip' || 'tar' || 'gz' || '7z' || 'rar' => Icons.folder_zip,
    'txt' || 'log' || 'json' || 'xml' || 'md' => Icons.description,
    _ => Icons.insert_drive_file,
  };
}

class FilesPage extends ConsumerStatefulWidget {
  const FilesPage({super.key});

  @override
  ConsumerState<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends ConsumerState<FilesPage> {
  String _path = '/sdcard';
  bool _dragging = false;

  String? get _serial => ref.read(selectedSerialProvider);

  void _navigate(String path) => setState(() => _path = path);

  /// Asks for a file or folder name; null when cancelled. The confirm
  /// button stays disabled until the (trimmed) name is valid.
  Future<String?> _askName({
    required String title,
    required String label,
    required String action,
    required Key fieldKey,
    required Key confirmKey,
    String initial = '',
    int? selectEnd,
  }) {
    final ctrl = TextEditingController(text: initial)
      ..selection = TextSelection(
          baseOffset: 0, extentOffset: selectEnd ?? initial.length);
    String? error(String v) =>
        v.trim().isEmpty ? null : entryNameError(v.trim());
    return showDialog<String>(
      context: context,
      builder: (context) => ValueListenableBuilder<TextEditingValue>(
        valueListenable: ctrl,
        builder: (context, value, _) {
          final valid = entryNameError(value.text.trim()) == null;
          void submit() {
            if (valid) Navigator.of(context).pop(value.text.trim());
          }

          return AlertDialog(
            title: Text(title),
            content: TextField(
              key: fieldKey,
              controller: ctrl,
              autofocus: true,
              decoration: InputDecoration(
                  labelText: label, errorText: error(value.text)),
              onSubmitted: (_) => submit(),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel')),
              FilledButton(
                  key: confirmKey,
                  onPressed: valid ? submit : null,
                  child: Text(action)),
            ],
          );
        },
      ),
    );
  }

  Future<void> _newFolder() async {
    final name = await _askName(
      title: 'New folder',
      label: 'Folder name',
      action: 'Create',
      fieldKey: const ValueKey('files.newFolderName'),
      confirmKey: const ValueKey('files.newFolderCreate'),
    );
    final serial = _serial;
    if (serial == null || name == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(fileExplorerProvider).mkdir(serial, _path, name);
      _refresh();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _rename(FsEntry e) async {
    // Preselect the name without its extension, like desktop file managers.
    final dot = e.isDir ? -1 : e.name.lastIndexOf('.');
    final name = await _askName(
      title: 'Rename',
      label: 'New name',
      action: 'Rename',
      fieldKey: const ValueKey('files.renameName'),
      confirmKey: const ValueKey('files.renameConfirm'),
      initial: e.name,
      selectEnd: dot > 0 ? dot : null,
    );
    final serial = _serial;
    if (serial == null || name == null || name == e.name || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(fileExplorerProvider).rename(serial, _path, e.name, name);
      _refresh();
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text('$err')));
    }
  }

  void _refresh() {
    final serial = _serial;
    if (serial != null) {
      ref.invalidate(filesProvider((serial: serial, path: _path)));
    }
  }

  Future<void> _pushLocalFiles(List<String> paths) async {
    final serial = _serial;
    if (serial == null) return;
    final svc = ref.read(fileExplorerProvider);
    final transfers = ref.read(transfersProvider);
    for (final p in paths) {
      final name = p.split('/').last;
      final ok = await transfers.run(
          'Push $name → $_path', () => svc.push(serial, p, _path));
      if (!ok) break;
    }
    _refresh();
  }

  Future<void> _pickAndPush() async {
    final paths = await ref
        .read(portalOpenFilesProvider)('Select files to push', true);
    if (paths.isNotEmpty) await _pushLocalFiles(paths);
  }

  Future<void> _pull(FsEntry e) async {
    final serial = _serial;
    if (serial == null) return;
    final home = Platform.environment['HOME'] ?? '.';
    final dest = '$home/Downloads';
    final svc = ref.read(fileExplorerProvider);
    final ok = await ref.read(transfersProvider).run(
        'Pull ${e.name} → $dest',
        () => svc.pull(serial, joinDevicePath(_path, e.name), dest));
    if (ok && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Saved to $dest/${e.name}')));
    }
  }

  Future<void> _delete(FsEntry e) async {
    final serial = _serial;
    if (serial == null) return;
    final scheme = Theme.of(context).colorScheme;
    final full = joinDevicePath(_path, e.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${e.name}?'),
        content: Text(e.isDir
            ? 'The folder and everything inside it will be deleted from the device. This cannot be undone.'
            : 'The file will be deleted from the device. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('files.deleteConfirm'),
            style: FilledButton.styleFrom(backgroundColor: scheme.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(fileExplorerProvider).delete(serial, full);
      _refresh();
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text('$err')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final serial = ref.watch(selectedSerialProvider);

    if (serial == null) {
      return Center(
        child: Text('Connect a device to browse files',
            style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }

    final listing = ref.watch(filesProvider((serial: serial, path: _path)));

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) {
        setState(() => _dragging = false);
        _pushLocalFiles(detail.files.map((f) => f.path).toList());
      },
      child: Container(
        decoration: _dragging
            ? BoxDecoration(
                border: Border.all(color: scheme.primary, width: 2))
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Up',
                    onPressed: _path == '/'
                        ? null
                        : () => _navigate(parentDevicePath(_path)),
                    icon: const Icon(Icons.arrow_upward),
                  ),
                  Expanded(child: _breadcrumbs(scheme)),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    key: const ValueKey('files.newFolder'),
                    tooltip: 'New folder',
                    onPressed: _newFolder,
                    icon: const Icon(Icons.create_new_folder_outlined),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _pickAndPush,
                    icon: const Icon(Icons.upload),
                    label: const Text('Push here'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: listing.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.folder_off,
                          color: scheme.error, size: 40),
                      const SizedBox(height: 8),
                      Text('Cannot open $_path\n$e',
                          textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: () =>
                            _navigate(parentDevicePath(_path)),
                        child: const Text('Go up'),
                      ),
                    ],
                  ),
                ),
                data: (entries) => entries.isEmpty
                    ? Center(
                        child: Text('Empty folder',
                            style:
                                TextStyle(color: scheme.onSurfaceVariant)))
                    : ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (context, i) =>
                            _entryTile(entries[i], scheme),
                      ),
              ),
            ),
            const _TransfersPanel(),
          ],
        ),
      ),
    );
  }

  Widget _breadcrumbs(ColorScheme scheme) {
    final parts = _path == '/'
        ? <String>[]
        : _path.substring(1).split('/');
    final crumbs = <Widget>[
      InkWell(
        onTap: () => _navigate('/'),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Icon(Icons.smartphone, size: 16),
        ),
      ),
    ];
    var acc = '';
    for (final p in parts) {
      acc = '$acc/$p';
      final target = acc;
      crumbs.add(Text('›', style: TextStyle(color: scheme.onSurfaceVariant)));
      crumbs.add(InkWell(
        onTap: () => _navigate(target),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Text(p,
              style: TextStyle(
                  color: target == _path ? scheme.primary : null,
                  fontWeight:
                      target == _path ? FontWeight.w600 : null)),
        ),
      ));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true,
      child: Row(children: crumbs),
    );
  }

  Widget _entryTile(FsEntry e, ColorScheme scheme) {
    final navigable = e.isDir || e.isLink;
    return ListTile(
      dense: true,
      onTap: navigable
          ? () => _navigate(joinDevicePath(_path, e.name))
          : null,
      leading: Icon(_fileIcon(e),
          color: navigable ? Colors.amber.shade300 : scheme.onSurfaceVariant),
      title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          e.perms,
          '${e.owner}:${e.group}',
          if (e.linkTarget != null) '→ ${e.linkTarget}',
        ].join('  '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              '${humanSize(e.size)}   ${e.modified ?? ''}',
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
          PopupMenuButton<String>(
            key: ValueKey('files.menu.${e.name}'),
            tooltip: 'Actions',
            onSelected: (v) => switch (v) {
              'pull' => _pull(e),
              'rename' => _rename(e),
              'delete' => _delete(e),
              'copy' => Clipboard.setData(
                  ClipboardData(text: joinDevicePath(_path, e.name))),
              _ => null,
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: 'pull', child: Text('Pull to ~/Downloads')),
              const PopupMenuItem(
                  value: 'copy', child: Text('Copy device path')),
              const PopupMenuItem(value: 'rename', child: Text('Rename…')),
              PopupMenuItem(
                value: 'delete',
                child: Text('Delete…',
                    style: TextStyle(color: scheme.error)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TransfersPanel extends ConsumerWidget {
  const _TransfersPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transfers = ref.watch(transfersProvider);
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: transfers,
      builder: (context, _) {
        if (transfers.tasks.isEmpty) return const SizedBox.shrink();
        final visible = transfers.tasks.take(3).toList();
        return Material(
          color: scheme.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('Transfers',
                        style: Theme.of(context).textTheme.titleSmall),
                    const Spacer(),
                    TextButton(
                      onPressed: transfers.clearFinished,
                      child: const Text('Clear finished'),
                    ),
                  ],
                ),
                for (final t in visible) ...[
                  Row(
                    children: [
                      Icon(
                        t.done
                            ? (t.ok ? Icons.check_circle : Icons.error)
                            : Icons.sync,
                        size: 16,
                        color: t.done
                            ? (t.ok
                                ? Colors.greenAccent.shade400
                                : scheme.error)
                            : scheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(t.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12))),
                      Text(
                        t.lastLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                  if (!t.done)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 6),
                      child: LinearProgressIndicator(
                          value: t.progress, minHeight: 4),
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
