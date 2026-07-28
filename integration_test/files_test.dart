import 'dart:io';
import 'dart:math';

import 'package:droid_deck/main.dart' as app;
import 'package:droid_deck/services/adb_service.dart';
import 'package:droid_deck/services/file_explorer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Round-trips a file to /sdcard/Download and back, byte-identical, against
/// the live emulator — plus UI navigation incl. a spaces-in-name entry.
const _serial = 'emulator-5554';
const _remoteDir = '/sdcard/Download';
const _fixtureName = 'dd round trip test.bin';

final _home = Platform.environment['HOME']!;
final _adbPath = '$_home/Android/Sdk/platform-tools/adb';

Future<String> _localMd5(String path) async {
  final r = await Process.run('md5sum', [path]);
  expect(r.exitCode, 0, reason: 'md5sum failed: ${r.stderr}');
  return (r.stdout as String).split(' ').first.trim();
}

Future<String> _remoteMd5(String path) async {
  final r = await Process.run(
      _adbPath, ['-s', _serial, 'shell', 'md5sum', shQuote(path)]);
  expect(r.exitCode, 0, reason: 'remote md5sum failed: ${r.stderr}');
  return (r.stdout as String).split(' ').first.trim();
}

Future<void> pumpFor(WidgetTester tester, double seconds) async {
  final end =
      DateTime.now().add(Duration(milliseconds: (seconds * 1000).round()));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('push/pull round-trip is byte-identical; UI browses it',
      (tester) async {
    final adb = AdbService()..configure(_adbPath);
    final svc = FileExplorerService(adb);

    // 1 MB of random bytes, name contains spaces on purpose.
    final tmp = Directory.systemTemp.createTempSync('droiddeck');
    final localPath = '${tmp.path}/$_fixtureName';
    final rng = Random(42);
    File(localPath).writeAsBytesSync(
        List<int>.generate(1024 * 1024, (_) => rng.nextInt(256)));
    final sumBefore = await _localMd5(localPath);

    final remotePath = '$_remoteDir/$_fixtureName';
    try {
      // Push, verify on-device checksum.
      final push = await svc.push(_serial, localPath, _remoteDir);
      final pushLines = <String>[];
      push.progress.listen(pushLines.add);
      expect(await push.exitCode, 0, reason: 'push failed: $pushLines');
      expect(await _remoteMd5(remotePath), sumBefore);

      // Pull back to a fresh dir, verify byte-identical.
      final backDir = Directory('${tmp.path}/back')..createSync();
      final pull = await svc.pull(_serial, remotePath, backDir.path);
      expect(await pull.exitCode, 0);
      expect(await _localMd5('${backDir.path}/$_fixtureName'), sumBefore);

      // Service listing parses the spaces-in-name entry.
      final entries = await svc.list(_serial, _remoteDir);
      expect(entries.any((e) => e.name == _fixtureName), isTrue);

      // UI: navigate /sdcard → Download, see the file, mkdir + delete.
      app.main();
      await pumpFor(tester, 4);
      await tester.tap(find.text('Files'));
      await pumpFor(tester, 3);
      expect(find.text('Download'), findsWidgets);
      await tester.tap(find.text('Download').first);
      await pumpFor(tester, 2);
      expect(find.text(_fixtureName), findsOneWidget);

      // New folder via UI.
      await tester.tap(find.byKey(const ValueKey('files.newFolder')));
      await pumpFor(tester, 0.5);
      await tester.enterText(
          find.byKey(const ValueKey('files.newFolderName')), 'dd-ui-dir');
      await tester.tap(find.byKey(const ValueKey('files.newFolderCreate')));
      await pumpFor(tester, 2);
      expect(find.text('dd-ui-dir'), findsOneWidget);

      // Delete it via the UI menu.
      await tester.tap(find.byKey(const ValueKey('files.menu.dd-ui-dir')));
      await pumpFor(tester, 0.5);
      await tester.tap(find.text('Delete…'));
      await pumpFor(tester, 0.5);
      await tester.tap(find.byKey(const ValueKey('files.deleteConfirm')));
      await pumpFor(tester, 2);
      expect(find.text('dd-ui-dir'), findsNothing);
    } finally {
      await Process.run(_adbPath,
          ['-s', _serial, 'shell', 'rm', '-rf', shQuote(remotePath)]);
      await Process.run(_adbPath, [
        '-s',
        _serial,
        'shell',
        'rm',
        '-rf',
        shQuote('$_remoteDir/dd-ui-dir')
      ]);
      tmp.deleteSync(recursive: true);
    }
  });
}
