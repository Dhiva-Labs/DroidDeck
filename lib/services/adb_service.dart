import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/adb_device.dart';

class AdbException implements Exception {
  final String message;
  AdbException(this.message);

  @override
  String toString() => message;
}

class AdbResult {
  final int exitCode;
  final String stdout;
  final String stderr;

  const AdbResult(this.exitCode, this.stdout, this.stderr);

  bool get ok => exitCode == 0;
  String get out => stdout.trim();

  /// Best error text for surfacing to the UI.
  String get error {
    final e = stderr.trim();
    return e.isNotEmpty ? e : stdout.trim();
  }
}

const _utf8Lenient = Utf8Decoder(allowMalformed: true);

/// POSIX single-quote escaping for paths passed through `adb shell`.
String shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

/// Child-process environment with snap-Flutter poisoning removed.
Map<String, String> sanitizedEnv({Map<String, String> extra = const {}}) {
  final env = Map.of(Platform.environment);
  env.remove('LD_LIBRARY_PATH');
  final path = env['PATH'];
  if (path != null) {
    env['PATH'] =
        path.split(':').where((p) => !p.contains('/snap/')).join(':');
  }
  return {...env, ...extra};
}

/// The single choke-point for every adb invocation in the app.
/// Nothing else in the codebase is allowed to spawn adb directly.
class AdbService {
  String? _adbPath;

  String? get adbPath => _adbPath;
  bool get available => _adbPath != null;

  void configure(String? path) => _adbPath = path;

  List<String> _scoped(List<String> args, String? serial) =>
      [if (serial != null) ...['-s', serial], ...args];

  String _requirePath() {
    final p = _adbPath;
    if (p == null) throw AdbException('adb is not available');
    return p;
  }

  /// Runs adb to completion, killing it after [timeout].
  Future<AdbResult> run(
    List<String> args, {
    String? serial,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final path = _requirePath();
    final proc = await Process.start(path, _scoped(args, serial),
        environment: sanitizedEnv());
    final outF = proc.stdout.transform(_utf8Lenient).join();
    final errF = proc.stderr.transform(_utf8Lenient).join();
    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      proc.kill(ProcessSignal.sigkill);
    });
    final code = await proc.exitCode;
    timer.cancel();
    final result = AdbResult(code, await outF, await errF);
    if (timedOut) {
      throw AdbException(
          "adb ${args.join(' ')} timed out after ${timeout.inSeconds}s");
    }
    return result;
  }

  /// Starts a long-lived adb process (logcat, push/pull with progress, …).
  /// The caller owns the process and must kill it when done.
  Future<Process> start(List<String> args, {String? serial}) =>
      Process.start(_requirePath(), _scoped(args, serial),
          environment: sanitizedEnv());

  /// Runs adb and returns raw stdout bytes (for `exec-out screencap -p` etc.).
  Future<Uint8List> runBytes(
    List<String> args, {
    String? serial,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final proc = await Process.start(_requirePath(), _scoped(args, serial),
        environment: sanitizedEnv());
    final bytes = BytesBuilder(copy: false);
    final done = proc.stdout.listen(bytes.add).asFuture<void>();
    final errF = proc.stderr.transform(_utf8Lenient).join();
    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      proc.kill(ProcessSignal.sigkill);
    });
    final code = await proc.exitCode;
    timer.cancel();
    await done;
    if (timedOut) {
      throw AdbException("adb ${args.join(' ')} timed out");
    }
    if (code != 0) {
      throw AdbException(
          "adb ${args.join(' ')} failed: ${(await errF).trim()}");
    }
    return bytes.takeBytes();
  }

  /// Runs `adb shell <command>` and returns the result.
  Future<AdbResult> shell(
    String serial,
    String command, {
    Duration timeout = const Duration(seconds: 20),
  }) =>
      run(['shell', command], serial: serial, timeout: timeout);

  Future<List<AdbDevice>> listDevices() async {
    final r = await run(['devices', '-l'], timeout: const Duration(seconds: 10));
    if (!r.ok) throw AdbException('adb devices failed: ${r.error}');
    return AdbDevice.parseList(r.stdout);
  }
}
