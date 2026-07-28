import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'adb_service.dart';

/// Screenshot capture via `adb exec-out screencap -p`.
class ScreencapController extends ChangeNotifier {
  final AdbService _adb;

  ScreencapController(this._adb);

  Uint8List? bytes;
  bool busy = false;
  String? error;
  DateTime? capturedAt;

  static const _pngMagic = [0x89, 0x50, 0x4E, 0x47];

  Future<void> capture(String serial) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final b = await _adb.runBytes(['exec-out', 'screencap', '-p'],
          serial: serial, timeout: const Duration(seconds: 30));
      if (b.length < 8 ||
          !List.generate(4, (i) => b[i] == _pngMagic[i]).every((x) => x)) {
        throw AdbException('screencap did not return a PNG '
            '(${b.length} bytes)');
      }
      bytes = b;
      capturedAt = DateTime.now();
    } catch (e) {
      error = '$e';
    }
    busy = false;
    notifyListeners();
  }

  /// Writes the last capture to [path]; creates parent dirs.
  Future<String> saveTo(String path) async {
    final b = bytes;
    if (b == null) throw StateError('nothing captured');
    final f = File(path);
    f.parent.createSync(recursive: true);
    await f.writeAsBytes(b);
    return path;
  }
}

enum RecordStatus { idle, recording, finalizing, done, error }

/// Screen recording: `adb shell screenrecord` to a hidden temp file on the
/// device, stopped via SIGINT (so the mp4 moov atom gets written), then
/// pulled to ~/Videos.
class RecordController extends ChangeNotifier {
  final AdbService _adb;

  RecordController(this._adb);

  static const remoteTemp = '/sdcard/.droiddeck-rec.mp4';

  RecordStatus status = RecordStatus.idle;
  DateTime? startedAt;
  String? savedPath;
  String? error;
  String? _serial;
  Process? _proc;
  Timer? _ticker;
  bool _finalized = false;

  Duration get elapsed => startedAt == null
      ? Duration.zero
      : DateTime.now().difference(startedAt!);

  Future<void> start(String serial, {int timeLimitSec = 180}) async {
    if (status == RecordStatus.recording ||
        status == RecordStatus.finalizing) {
      return;
    }
    _serial = serial;
    _finalized = false;
    error = null;
    savedPath = null;
    try {
      final proc = await _adb.start([
        'shell',
        'screenrecord',
        '--time-limit',
        '$timeLimitSec',
        remoteTemp,
      ], serial: serial);
      _proc = proc;
      startedAt = DateTime.now();
      status = RecordStatus.recording;
      _ticker = Timer.periodic(
          const Duration(seconds: 1), (_) => notifyListeners());
      final errF = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
      proc.stdout.drain<void>();
      unawaited(proc.exitCode.then((code) async {
        // Fires on manual stop AND on the device-side time limit.
        final errText = (await errF).trim();
        await _finalize(code, errText);
      }));
      notifyListeners();
    } catch (e) {
      status = RecordStatus.error;
      error = '$e';
      notifyListeners();
    }
  }

  Future<void> stop() async {
    final s = _serial;
    if (status != RecordStatus.recording || s == null) return;
    try {
      await _adb.shell(s, 'killall -INT screenrecord',
          timeout: const Duration(seconds: 5));
    } catch (_) {}
    // If the device-side kill didn't land, force the local side after a grace
    // period; exitCode handler does the rest.
    unawaited(Future<void>.delayed(const Duration(seconds: 5), () {
      if (status == RecordStatus.recording) {
        _proc?.kill(ProcessSignal.sigterm);
      }
    }));
  }

  Future<void> _finalize(int code, String errText) async {
    if (_finalized) return;
    _finalized = true;
    _ticker?.cancel();
    _ticker = null;
    final s = _serial;
    if (s == null) return;
    status = RecordStatus.finalizing;
    notifyListeners();
    try {
      // Give the device a beat to flush the moov atom.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final home = Platform.environment['HOME'] ?? '.';
      final dir = Directory('$home/Videos');
      dir.createSync(recursive: true);
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final local = '${dir.path}/droiddeck-$s-$ts.mp4';
      final r = await _adb.run(['pull', remoteTemp, local],
          serial: s, timeout: const Duration(minutes: 3));
      if (!r.ok) {
        throw AdbException(
            'pull failed: ${r.error}${errText.isEmpty ? '' : '\n$errText'}');
      }
      await _adb.shell(s, 'rm -f $remoteTemp');
      savedPath = local;
      status = RecordStatus.done;
    } catch (e) {
      status = RecordStatus.error;
      error = '$e';
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _proc?.kill(ProcessSignal.sigterm);
    super.dispose();
  }
}

/// One launched scrcpy window.
class ScrcpySession {
  final String serial;
  final String description;
  final DateTime started = DateTime.now();
  final Process proc;
  int? exitCode;
  final List<String> errTail = [];

  ScrcpySession({
    required this.serial,
    required this.description,
    required this.proc,
  });

  bool get running => exitCode == null;
}

/// Launches and tracks scrcpy windows (scrcpy embeds its own UI; we only
/// manage the processes).
class ScrcpyController extends ChangeNotifier {
  final List<ScrcpySession> sessions = [];
  bool _disposed = false;

  Future<void> launch({
    required String scrcpyPath,
    required String adbPath,
    required String serial,
    required String description,
    required List<String> args,
  }) async {
    final proc = await Process.start(scrcpyPath, ['-s', serial, ...args],
        environment: sanitizedEnv(extra: {'ADB': adbPath}));
    final session =
        ScrcpySession(serial: serial, description: description, proc: proc);
    sessions.insert(0, session);
    proc.stdout.drain<void>();
    proc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((l) {
      session.errTail.add(l);
      if (session.errTail.length > 5) session.errTail.removeAt(0);
    });
    unawaited(proc.exitCode.then((c) {
      session.exitCode = c;
      if (!_disposed) notifyListeners();
    }));
    notifyListeners();
  }

  void kill(ScrcpySession s) => s.proc.kill(ProcessSignal.sigterm);

  void clearFinished() {
    sessions.removeWhere((s) => !s.running);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
