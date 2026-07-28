import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'adb_service.dart';

class AppPackage {
  final String package;
  final String apkPath;
  final bool system;

  const AppPackage({
    required this.package,
    required this.apkPath,
    required this.system,
  });
}

/// A running `adb install` with its streamed output.
class InstallSession {
  final Stream<String> lines;
  final Future<int> exitCode;

  const InstallSession({required this.lines, required this.exitCode});
}

const _utf8Lenient = Utf8Decoder(allowMalformed: true);

class AppManagerService {
  final AdbService _adb;

  AppManagerService(this._adb);

  Future<List<AppPackage>> list(String serial) async {
    final all = await _adb.shell(serial, 'pm list packages -f',
        timeout: const Duration(seconds: 30));
    if (!all.ok) {
      throw AdbException('pm list packages failed: ${all.error}');
    }
    final sys = await _adb.shell(serial, 'pm list packages -s',
        timeout: const Duration(seconds: 30));
    final sysSet = <String>{};
    if (sys.ok) {
      for (final line in sys.stdout.split('\n')) {
        final t = line.trim();
        if (t.startsWith('package:')) sysSet.add(t.substring(8));
      }
    }
    final out = <AppPackage>[];
    for (final line in all.stdout.split('\n')) {
      final t = line.trim();
      if (!t.startsWith('package:')) continue;
      final rest = t.substring(8);
      // package:<apk path>=<package name>; APK paths never contain '=' but
      // split on the last one to be safe.
      final eq = rest.lastIndexOf('=');
      if (eq <= 0) continue;
      out.add(AppPackage(
        package: rest.substring(eq + 1),
        apkPath: rest.substring(0, eq),
        system: sysSet.contains(rest.substring(eq + 1)),
      ));
    }
    out.sort((a, b) => a.package.compareTo(b.package));
    return out;
  }

  Future<void> launch(String serial, String pkg) async {
    final r =
        await _adb.shell(serial, 'cmd package resolve-activity --brief $pkg');
    String? component;
    if (r.ok) {
      for (final line in r.out.split('\n')) {
        final t = line.trim();
        if (t.contains('/') && !t.startsWith('No activity')) component = t;
      }
    }
    if (component != null) {
      final s = await _adb.shell(serial, 'am start -n $component');
      if (s.ok && !s.stdout.contains('Error')) return;
    }
    final m = await _adb.shell(
        serial, 'monkey -p $pkg -c android.intent.category.LAUNCHER 1');
    if (!m.ok || m.stdout.contains('No activities found')) {
      throw AdbException('could not launch $pkg: ${m.error}');
    }
  }

  Future<void> forceStop(String serial, String pkg) async {
    final r = await _adb.shell(serial, 'am force-stop $pkg');
    if (!r.ok) throw AdbException('force-stop failed: ${r.error}');
  }

  Future<void> clearData(String serial, String pkg) async {
    final r = await _adb.shell(serial, 'pm clear $pkg',
        timeout: const Duration(seconds: 60));
    if (!r.ok || !r.stdout.contains('Success')) {
      throw AdbException('pm clear failed: ${r.error}');
    }
  }

  Future<void> uninstall(String serial, String pkg) async {
    final r = await _adb.run(['uninstall', pkg],
        serial: serial, timeout: const Duration(seconds: 60));
    if (!r.ok || !r.stdout.contains('Success')) {
      throw AdbException('uninstall failed: ${r.error}');
    }
  }

  Future<List<String>> apkPaths(String serial, String pkg) async {
    final r = await _adb.shell(serial, 'pm path $pkg');
    if (!r.ok) throw AdbException('pm path failed: ${r.error}');
    return [
      for (final line in r.stdout.split('\n'))
        if (line.trim().startsWith('package:')) line.trim().substring(8),
    ];
  }

  /// Pulls all APKs (base + splits) for [pkg] into a folder and returns it.
  Future<String> extractApk(String serial, String pkg) async {
    final paths = await apkPaths(serial, pkg);
    if (paths.isEmpty) throw AdbException('no APK paths for $pkg');
    final home = Platform.environment['HOME'] ?? '.';
    final dest = Directory('$home/Downloads/droiddeck-apks/$pkg');
    dest.createSync(recursive: true);
    for (final p in paths) {
      final r = await _adb.run(['pull', p, dest.path],
          serial: serial, timeout: const Duration(minutes: 5));
      if (!r.ok) throw AdbException('pull $p failed: ${r.error}');
    }
    return dest.path;
  }

  /// Starts `adb install -r -t` and exposes its streamed output.
  Future<InstallSession> install(String serial, String apkPath) async {
    final proc = await _adb.start(['install', '-r', '-t', apkPath],
        serial: serial);
    final ctrl = StreamController<String>.broadcast();
    void pipe(Stream<List<int>> s) {
      s
          .transform(_utf8Lenient)
          .transform(const LineSplitter())
          .listen((l) {
        if (l.trim().isNotEmpty && !ctrl.isClosed) ctrl.add(l.trim());
      });
    }

    pipe(proc.stdout);
    pipe(proc.stderr);
    final exit = proc.exitCode.whenComplete(() {
      // Give the tail lines a beat to flush before closing.
      Future<void>.delayed(
          const Duration(milliseconds: 200), () => ctrl.close());
    });
    return InstallSession(lines: ctrl.stream, exitCode: exit);
  }
}
