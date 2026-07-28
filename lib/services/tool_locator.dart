import 'dart:io';

/// Where an external CLI tool (adb / scrcpy) was found and which version it is.
class ToolInfo {
  final String tool;
  final String? path;
  final String? version;

  const ToolInfo(this.tool, {this.path, this.version});

  bool get found => path != null;
}

/// Resolves adb/scrcpy executables. Order: user override from settings →
/// `which` on PATH → well-known install locations. The last step matters when
/// the app is launched from a .desktop entry, where the Android SDK is
/// typically not on PATH.
class ToolLocator {
  static List<String> candidatesFor(String tool) {
    final home = Platform.environment['HOME'] ?? '';
    switch (tool) {
      case 'adb':
        return [
          '$home/Android/Sdk/platform-tools/adb',
          '/usr/lib/android-sdk/platform-tools/adb',
          '/opt/android-sdk/platform-tools/adb',
          '/usr/bin/adb',
          '/snap/bin/adb',
        ];
      case 'scrcpy':
        return [
          '/usr/bin/scrcpy',
          '/usr/local/bin/scrcpy',
          '/snap/bin/scrcpy',
          '$home/.local/bin/scrcpy',
        ];
      default:
        return const [];
    }
  }

  Future<ToolInfo> locate(String tool, {String? override}) async {
    final candidates = <String>[
      if (override != null && override.trim().isNotEmpty) override.trim(),
      ...await _fromPath(tool),
      ...candidatesFor(tool),
    ];
    final seen = <String>{};
    for (final c in candidates) {
      if (!seen.add(c)) continue;
      if (!File(c).existsSync()) continue;
      final version = await _probeVersion(tool, c);
      if (version != null) return ToolInfo(tool, path: c, version: version);
    }
    return ToolInfo(tool);
  }

  Future<List<String>> _fromPath(String tool) async {
    try {
      final r = await Process.run('which', [tool]).timeout(const Duration(seconds: 5));
      if (r.exitCode == 0) {
        final p = (r.stdout as String).trim();
        if (p.isNotEmpty) return [p];
      }
    } catch (_) {}
    return const [];
  }

  /// Runs the tool's version command; returns a cleaned version string, or
  /// null if the binary is not runnable.
  Future<String?> _probeVersion(String tool, String path) async {
    try {
      final arg = tool == 'adb' ? 'version' : '--version';
      final r = await Process.run(path, [arg]).timeout(const Duration(seconds: 8));
      if (r.exitCode != 0) return null;
      final out = '${r.stdout}\n${r.stderr}';
      if (tool == 'adb') {
        final bridge =
            RegExp(r'Android Debug Bridge version ([\d.]+)').firstMatch(out);
        final build = RegExp(r'^Version (\S+)', multiLine: true).firstMatch(out);
        if (bridge != null && build != null) {
          return '${bridge.group(1)} (${build.group(1)})';
        }
        if (bridge != null) return bridge.group(1);
      } else {
        final m = RegExp(r'scrcpy v?([\d.]+)').firstMatch(out);
        if (m != null) return m.group(1);
      }
      final first = out
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.isNotEmpty, orElse: () => '');
      return first.isEmpty ? null : first;
    } catch (_) {
      return null;
    }
  }
}
