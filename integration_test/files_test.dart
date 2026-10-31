import 'dart:io';
import 'dart:math';

import 'package:droid_deck/main.dart' as app;
import 'package:droid_deck/services/adb_service.dart';
import 'package:droid_deck/services/file_explorer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Round-trips a file to /sdcard/Download and back, byte-identical, against
/// the live emulator — plus rename, and UI navigation incl. a spaces-in-name
/// entry.
const _serial = 'emulator-5554';
const _remoteDir = '/sdcard/Download';
const _fixtureName = 'dd round trip test.bin';
const _renamedName = "dd renamed 'quoted' test.bin";

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

      // Rename: quotes and spaces survive, contents are untouched, and a
      // case-only change works on the case-insensitive /sdcard.
      Future<List<String>> names() async =>
          (await svc.list(_serial, _remoteDir)).map((e) => e.name).toList();
      await svc.rename(_serial, _remoteDir, _fixtureName, _renamedName);
      expect(await names(),
          allOf(contains(_renamedName), isNot(contains(_fixtureName))));
      expect(await _remoteMd5('$_remoteDir/$_renamedName'), sumBefore);
      await svc.rename(
          _serial, _remoteDir, _renamedName, _renamedName.toUpperCase());
      expect(await names(), contains(_renamedName.toUpperCase()));
      await svc.rename(
          _serial, _remoteDir, _renamedName.toUpperCase(), _fixtureName);
      expect(await _remoteMd5(remotePath), sumBefore);

      // Folders too, and an existing name is never replaced (mv would
      // move the folder inside it).
      await svc.mkdir(_serial, _remoteDir, 'dd-ren-a');
      await svc.mkdir(_serial, _remoteDir, 'dd-ren-b');
      await svc.rename(_serial, _remoteDir, 'dd-ren-a', 'DD-REN-A');
      expect(await names(), contains('DD-REN-A'));
      await expectLater(
          svc.rename(_serial, _remoteDir, 'DD-REN-A', 'dd-ren-b'),
          throwsA(isA<AdbException>().having(
              (e) => e.message, 'message', contains('already exists'))));
      await expectLater(
          svc.rename(_serial, _remoteDir, 'dd-ren-b', _fixtureName),
          throwsA(isA<AdbException>()));
      expect(await names(), containsAll(['DD-REN-A', 'dd-ren-b']));
      expect(await _remoteMd5(remotePath), sumBefore);
      await expectLater(svc.rename(_serial, _remoteDir, 'dd-ren-b', '../x'),
          throwsA(isA<AdbException>()));
      await svc.delete(_serial, '$_remoteDir/DD-REN-A');
      await svc.delete(_serial, '$_remoteDir/dd-ren-b');

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
      await pumpFor(tester, 0.3); // Create enables once the name is valid
      await tester.tap(find.byKey(const ValueKey('files.newFolderCreate')));
      await pumpFor(tester, 2);
      expect(find.text('dd-ui-dir'), findsOneWidget);

      // Rename it via the UI menu; a "/" keeps the button disabled.
      await tester.tap(find.byKey(const ValueKey('files.menu.dd-ui-dir')));
      await pumpFor(tester, 0.5);
      await tester.tap(find.text('Rename…'));
      await pumpFor(tester, 0.5);
      final renameField = find.byKey(const ValueKey('files.renameName'));
      expect(tester.widget<TextField>(renameField).controller!.text,
          'dd-ui-dir');
      await tester.enterText(renameField, 'dd/ui');
      await pumpFor(tester, 0.3);
      expect(
          tester
              .widget<FilledButton>(
                  find.byKey(const ValueKey('files.renameConfirm')))
              .onPressed,
          isNull);
      await tester.enterText(renameField, 'dd-ui-renamed');
      await pumpFor(tester, 0.3);
      await tester.tap(find.byKey(const ValueKey('files.renameConfirm')));
      await pumpFor(tester, 2);
      expect(find.text('dd-ui-dir'), findsNothing);
      expect(find.text('dd-ui-renamed'), findsOneWidget);

      // Delete it via the UI menu.
      await tester
          .tap(find.byKey(const ValueKey('files.menu.dd-ui-renamed')));
      await pumpFor(tester, 0.5);
      await tester.tap(find.text('Delete…'));
      await pumpFor(tester, 0.5);
      await tester.tap(find.byKey(const ValueKey('files.deleteConfirm')));
      await pumpFor(tester, 2);
      expect(find.text('dd-ui-renamed'), findsNothing);
    } finally {
      for (final name in [
        _fixtureName,
        _renamedName,
        _renamedName.toUpperCase(),
        'dd-ren-a',
        'dd-ren-b',
        'dd-ui-dir',
        'dd-ui-renamed',
      ]) {
        await Process.run(_adbPath, [
          '-s',
          _serial,
          'shell',
          'rm',
          '-rf',
          shQuote('$_remoteDir/$name')
        ]);
      }
      tmp.deleteSync(recursive: true);
    }
  });
}
