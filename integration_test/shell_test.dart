import 'dart:io';

import 'package:droid_deck/main.dart' as app;
import 'package:droid_deck/services/adb_service.dart';
import 'package:droid_deck/services/terminal_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Interactive shell (Plan A: xterm + flutter_pty) and quick-actions against
/// a live emulator (expects emulator-5554 booted).
/// Run with: flutter test integration_test/shell_test.dart -d linux
const _serial = 'emulator-5554';

final _home = Platform.environment['HOME']!;
final _adbPath = '$_home/Android/Sdk/platform-tools/adb';

Future<ProcessResult> _adb(List<String> args) =>
    Process.run(_adbPath, ['-s', _serial, ...args]);

Future<void> pumpFor(WidgetTester tester, double seconds) async {
  final end =
      DateTime.now().add(Duration(milliseconds: (seconds * 1000).round()));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Generic short-poll helper, same shape as the one in wireless_test.dart.
Future<bool> _waitFor(
  Future<bool> Function() check, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await check()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return check();
}

/// `dumpsys power`'s mWakefulness: Awake / Asleep / Dozing.
Future<String?> _wakefulness() async {
  final r = await _adb(['shell', 'dumpsys', 'power']);
  return RegExp(r'mWakefulness=(\w+)').firstMatch('${r.stdout}')?.group(1);
}

Future<String> _topResumedLine() async {
  final r = await _adb(['shell', 'dumpsys', 'activity', 'activities']);
  for (final line in '${r.stdout}'.split('\n')) {
    if (line.contains('topResumedActivity')) return line.trim();
  }
  return '';
}

/// Flattens the xterm scrollback + viewport into one searchable string.
String _terminalText(TerminalSession session) {
  final buf = StringBuffer();
  final lines = session.terminal.buffer.lines;
  for (var i = 0; i < lines.length; i++) {
    buf.writeln(lines[i].toString());
  }
  return buf.toString();
}

/// Forces the emulator back to a known-good state regardless of how the
/// test above fared: screen on, sitting on the launcher.
Future<void> _ensureAwakeAndHome() async {
  try {
    for (var i = 0; i < 3; i++) {
      if (await _wakefulness() == 'Awake') break;
      await _adb(['shell', 'input', 'keyevent', '224']); // KEYCODE_WAKEUP
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    await _adb(['shell', 'input', 'keyevent', '3']); // KEYCODE_HOME
  } catch (e) {
    debugPrint('[shell_test] cleanup wake/home best-effort failed: $e');
  }
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('interactive shell, quick-action keyevents, dumpsys dialog',
      (tester) async {
    // --- a. Service-level PTY interaction (Plan A: TerminalSession/Pty) ---
    final adb = AdbService()..configure(_adbPath);
    final session = TerminalSession(adb, _serial);
    try {
      session.start();
      expect(session.error, isNull,
          reason: 'shell failed to start: ${session.error}');
      expect(session.running, isTrue);

      // Let the remote shell come up before typing into it.
      await Future<void>.delayed(const Duration(seconds: 2));

      session.terminal.textInput('ls /sdcard\n');
      final gotDownload = await _waitFor(
          () async => _terminalText(session).contains('Download'));
      expect(gotDownload, isTrue,
          reason: 'terminal output never showed Download:\n'
              '${_terminalText(session)}');

      // cd persists across commands (persistent shell process) + no crash.
      session.terminal.textInput('cd /sdcard/Download\nls\n');
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(session.error, isNull,
          reason: 'shell reported an error after cd: ${session.error}');
      expect(session.running, isTrue,
          reason: 'shell process died after cd/ls');
      debugPrint('[shell_test] service-level PTY interaction OK, '
          '${session.terminal.buffer.lines.length} buffered lines');
    } finally {
      session.dispose();
    }

    // --- UI smoke: the Shell tab mounts a terminal ------------------------
    app.main();
    await pumpFor(tester, 4); // boot, tool detect, tracker connect

    await tester.tap(find.text('Shell'));
    await pumpFor(tester, 2);
    expect(find.byKey(const ValueKey('shell.terminal')), findsOneWidget);

    try {
      // --- b(i). Power keyevent visibly toggles wakefulness --------------
      final before = await _wakefulness();
      expect(before, isNotNull, reason: 'could not read mWakefulness');

      await _tap(tester, 'qa.power');
      await pumpFor(tester, 0.6);
      final changed1 =
          await _waitFor(() async => (await _wakefulness()) != before);
      final after1 = await _wakefulness();
      expect(changed1, isTrue,
          reason: 'wakefulness did not change after first power tap '
              '(stuck at $before)');
      debugPrint('[shell_test] power tap 1: $before -> $after1');

      await _tap(tester, 'qa.power');
      await pumpFor(tester, 0.6);
      final changed2 =
          await _waitFor(() async => (await _wakefulness()) != after1);
      final after2 = await _wakefulness();
      expect(changed2, isTrue,
          reason: 'wakefulness did not change back after second power tap '
              '(stuck at $after1)');
      debugPrint('[shell_test] power tap 2: $after1 -> $after2');

      // --- b(ii). Home keyevent visibly leaves Settings -------------------
      await _adb(['shell', 'am', 'start', '-a', 'android.settings.SETTINGS']);
      await pumpFor(tester, 1);
      final onSettings = await _topResumedLine();
      debugPrint('[shell_test] topResumedActivity before home: $onSettings');

      await _tap(tester, 'qa.home');
      await pumpFor(tester, 0.6);
      final leftSettings = await _waitFor(
          () async => !(await _topResumedLine()).contains('com.android.settings'));
      expect(leftSettings, isTrue,
          reason: 'home keyevent did not leave Settings: '
              '${await _topResumedLine()}');
      debugPrint('[shell_test] topResumedActivity after home: '
          '${await _topResumedLine()}');

      // --- c. Dumpsys dialog (battery) -------------------------------------
      await _tap(tester, 'qa.battery');
      await pumpFor(tester, 1.5);
      final dumpoutFinder = find.byKey(const ValueKey('qa.dumpout'));
      expect(dumpoutFinder, findsOneWidget);
      final dumpText = tester.widget<SelectableText>(dumpoutFinder).data ?? '';
      expect(dumpText, contains('level'),
          reason: 'battery dumpsys output missing "level":\n$dumpText');

      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text('Close')));
      await pumpFor(tester, 0.5);
      expect(find.byType(AlertDialog), findsNothing);
    } finally {
      // --- d. Leave the device awake and on the launcher -------------------
      await _ensureAwakeAndHome();
    }
  });
}
