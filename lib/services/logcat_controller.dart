import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/log_line.dart';
import 'adb_service.dart';

const _utf8Lenient = Utf8Decoder(allowMalformed: true);

/// Owns one `adb logcat -v threadtime` stream for one device.
///
/// Perf contract: a 50k-line ring buffer, an incrementally maintained
/// filtered view (rebuilt only on filter changes), and listener
/// notifications batched to at most one per 100 ms — so a chatty device
/// cannot jank the UI.
class LogcatController extends ChangeNotifier {
  static const capacity = 50000;

  final AdbService _adb;
  final String? serial;

  LogcatController(this._adb, this.serial);

  final ListQueue<LogLine> _buffer = ListQueue();
  ListQueue<LogLine> _filtered = ListQueue();
  final List<LogLine> _pending = [];

  int _seq = 0;
  Process? _proc;
  StreamSubscription<String>? _sub;
  Timer? _flushTimer;
  Timer? _pidTimer;
  bool _disposed = false;

  bool running = false;
  bool paused = false;
  String? error;

  // Filters.
  int minPriorityRank = 0;
  String tagFilter = '';
  String textFilter = '';
  String packageFilter = '';
  int? packagePid;

  int get bufferLength => _buffer.length;
  int get viewLength => _filtered.length;

  /// Random access into the filtered view; ListQueue.elementAt is O(1).
  LogLine viewAt(int i) => _filtered.elementAt(i);

  Future<void> start() async {
    final s = serial;
    if (s == null || running) return;
    error = null;
    try {
      final proc = await _adb.start(['logcat', '-v', 'threadtime'], serial: s);
      _proc = proc;
      running = true;
      _sub = proc.stdout
          .transform(_utf8Lenient)
          .transform(const LineSplitter())
          .listen(_onLine, onError: (_) {});
      proc.stderr.drain<void>();
      unawaited(proc.exitCode.then((code) {
        if (_disposed || _proc != proc) return;
        running = false;
        error = 'logcat exited (code $code)';
        _safeNotify();
      }));
      _syncPidTimer();
      _safeNotify();
    } catch (e) {
      error = 'could not start logcat: $e';
      running = false;
      _safeNotify();
    }
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    final p = _proc;
    _proc = null;
    p?.kill(ProcessSignal.sigkill);
    running = false;
    _pidTimer?.cancel();
    _pidTimer = null;
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  void _onLine(String line) {
    final ll = LogLine.parse(line, _seq++);
    _buffer.add(ll);
    if (_buffer.length > capacity) _buffer.removeFirst();
    if (_matches(ll)) {
      _pending.add(ll);
      if (_pending.length > capacity) _pending.removeAt(0);
    }
    _flushTimer ??= Timer(const Duration(milliseconds: 100), _flush);
  }

  void _flush() {
    _flushTimer = null;
    if (paused || _disposed) return;
    if (_pending.isNotEmpty) {
      _filtered.addAll(_pending);
      _pending.clear();
    }
    // Keep the view consistent with the ring: drop rows that fell off.
    final floor = _buffer.isEmpty ? _seq : _buffer.first.seq;
    while (_filtered.isNotEmpty && _filtered.first.seq < floor) {
      _filtered.removeFirst();
    }
    _safeNotify();
  }

  void pauseView() {
    paused = true;
    _safeNotify();
  }

  void resumeView() {
    paused = false;
    _flush();
  }

  void setFilters({
    int? minRank,
    String? tag,
    String? text,
    String? package,
  }) {
    var packageChanged = false;
    if (minRank != null) minPriorityRank = minRank;
    if (tag != null) tagFilter = tag.trim().toLowerCase();
    if (text != null) textFilter = text.trim().toLowerCase();
    if (package != null) {
      final p = package.trim();
      packageChanged = p != packageFilter;
      packageFilter = p;
    }
    if (packageChanged) {
      packagePid = null;
      _syncPidTimer();
      unawaited(_resolvePid());
    }
    _rebuild();
  }

  void _rebuild() {
    _filtered = ListQueue.of(_buffer.where(_matches));
    _pending.clear();
    _safeNotify();
  }

  bool _matches(LogLine l) {
    if (l.priorityRank < minPriorityRank) return false;
    if (packageFilter.isNotEmpty) {
      final pid = packagePid;
      if (pid == null || l.pid != pid) return false;
    }
    if (tagFilter.isNotEmpty &&
        !(l.tag ?? '').toLowerCase().contains(tagFilter)) {
      return false;
    }
    if (textFilter.isNotEmpty &&
        !(l.message ?? l.raw).toLowerCase().contains(textFilter)) {
      return false;
    }
    return true;
  }

  void _syncPidTimer() {
    _pidTimer?.cancel();
    _pidTimer = null;
    if (packageFilter.isEmpty || serial == null) return;
    _pidTimer = Timer.periodic(
        const Duration(seconds: 3), (_) => unawaited(_resolvePid()));
  }

  Future<void> _resolvePid() async {
    final s = serial;
    if (s == null || packageFilter.isEmpty) return;
    final pkg = packageFilter;
    int? pid;
    try {
      final r = await _adb.shell(s, 'pidof -s $pkg',
          timeout: const Duration(seconds: 5));
      pid = int.tryParse(r.out);
    } catch (_) {}
    if (_disposed || pkg != packageFilter) return;
    if (pid != packagePid) {
      packagePid = pid;
      debugPrint('[DroidDeck] logcat: pid for $pkg -> ${pid ?? 'not running'}');
      _rebuild();
    }
  }

  Future<void> clear() async {
    final s = serial;
    if (s != null) {
      try {
        await _adb.run(['logcat', '-c'], serial: s);
      } catch (_) {}
    }
    _buffer.clear();
    _filtered.clear();
    _pending.clear();
    _safeNotify();
  }

  /// Writes the current view to ~/Downloads and returns the path.
  Future<String> exportView() async {
    final home = Platform.environment['HOME'] ?? '.';
    final dir = Directory('$home/Downloads');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final ts = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final path = '${dir.path}/droiddeck-logcat-${serial ?? 'device'}-$ts.log';
    final sink = File(path).openWrite();
    for (final l in _filtered) {
      sink.writeln(l.raw);
    }
    await sink.close();
    return path;
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
