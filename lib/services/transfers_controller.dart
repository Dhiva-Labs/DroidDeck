import 'package:flutter/foundation.dart';

import 'file_explorer.dart';

class TransferTask {
  final String description;
  double? progress;
  String lastLine = '';
  bool done = false;
  bool ok = false;

  TransferTask(this.description);
}

/// Tracks running/finished push+pull tasks for the transfers panel.
class TransfersController extends ChangeNotifier {
  final List<TransferTask> tasks = [];
  bool _disposed = false;

  static final _percent = RegExp(r'\[\s*(\d+)%\]');

  Future<bool> run(
      String description, Future<TransferHandle> Function() start) async {
    final t = TransferTask(description);
    tasks.insert(0, t);
    _notify();
    try {
      final h = await start();
      h.progress.listen((line) {
        t.lastLine = line;
        final m = _percent.firstMatch(line);
        if (m != null) t.progress = int.parse(m.group(1)!) / 100;
        _notify();
      });
      t.ok = await h.exitCode == 0;
      if (!t.ok && t.lastLine.isEmpty) t.lastLine = 'transfer failed';
    } catch (e) {
      t.ok = false;
      t.lastLine = '$e';
    }
    t.done = true;
    t.progress = 1;
    _notify();
    return t.ok;
  }

  void clearFinished() {
    tasks.removeWhere((t) => t.done);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
