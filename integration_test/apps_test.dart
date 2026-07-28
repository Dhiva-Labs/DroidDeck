import 'dart:io';

import 'package:droid_deck/main.dart' as app;
import 'package:droid_deck/services/adb_service.dart';
import 'package:droid_deck/services/app_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// End-to-end app management against a live emulator (expects emulator-5554).
/// Fixture: the DeveloperToolbox x86_64 release APK built on this machine.
const _serial = 'emulator-5554';
const _pkg = 'com.dhivalabs.developer_toolbox';

final _home = Platform.environment['HOME']!;
final _adbPath = '$_home/Android/Sdk/platform-tools/adb';
final _apk =
    '$_home/dhiva-labs/developer_toolbox/build/app/outputs/flutter-apk/app-x86_64-release.apk';

Future<String> _adbOut(List<String> args) async {
  final r = await Process.run(_adbPath, ['-s', _serial, ...args]);
  return '${r.stdout}';
}

Future<bool> _installed() async =>
    (await _adbOut(['shell', 'pm', 'list', 'packages', _pkg]))
        .contains('package:$_pkg');

Future<String> _pidof() async =>
    (await _adbOut(['shell', 'pidof', '-s', _pkg])).trim();

Future<void> pumpFor(WidgetTester tester, double seconds) async {
  final end =
      DateTime.now().add(Duration(milliseconds: (seconds * 1000).round()));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('install → list → launch → force-stop → uninstall',
      (tester) async {
    expect(File(_apk).existsSync(), isTrue,
        reason: 'fixture APK missing: $_apk');

    final adb = AdbService()..configure(_adbPath);
    final svc = AppManagerService(adb);

    // Clean slate.
    try {
      await svc.uninstall(_serial, _pkg);
    } catch (_) {}
    expect(await _installed(), isFalse);

    // Service-level install (same pipeline the UI dialog uses).
    final session = await svc.install(_serial, _apk);
    final lines = <String>[];
    session.lines.listen(lines.add);
    final code = await session.exitCode;
    expect(code, 0, reason: 'install failed: $lines');
    expect(await _installed(), isTrue);

    // Launch → a process appears.
    await svc.launch(_serial, _pkg);
    var pid = '';
    for (var i = 0; i < 20 && pid.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      pid = await _pidof();
    }
    expect(pid, isNotEmpty, reason: 'app never came up after launch');

    // Force-stop → process gone.
    await svc.forceStop(_serial, _pkg);
    var stopped = false;
    for (var i = 0; i < 20 && !stopped; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      stopped = (await _pidof()).isEmpty;
    }
    expect(stopped, isTrue, reason: 'app still running after force-stop');

    // Now drive the real UI: find it in the list and launch from the menu.
    app.main();
    await pumpFor(tester, 4);
    await tester.tap(find.text('Apps'));
    await pumpFor(tester, 4); // pm list of ~400 packages
    await tester.enterText(
        find.byKey(const ValueKey('apps.search')), 'developer_toolbox');
    await pumpFor(tester, 1);
    expect(find.text(_pkg), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('apps.menu.$_pkg')));
    await pumpFor(tester, 0.5);
    await tester.tap(find.text('Launch'));
    await pumpFor(tester, 3);
    pid = '';
    for (var i = 0; i < 20 && pid.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      pid = await _pidof();
    }
    expect(pid, isNotEmpty, reason: 'menu launch did not start the app');

    // Uninstall via service, verify gone.
    await svc.uninstall(_serial, _pkg);
    expect(await _installed(), isFalse);
  });
}
