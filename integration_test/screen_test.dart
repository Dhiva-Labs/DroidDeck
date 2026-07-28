import 'dart:io';

import 'package:droid_deck/main.dart' as app;
import 'package:droid_deck/services/adb_service.dart';
import 'package:droid_deck/services/screen_tools.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Screenshot capture, screen recording (with real playback verification via
/// ffprobe/ffmpeg) and Screen-tab UI wiring against a live emulator (expects
/// emulator-5554 booted). scrcpy is expected to be absent on this machine.
/// Run with: flutter test integration_test/screen_test.dart -d linux
const _serial = 'emulator-5554';
const _pngMagic = [0x89, 0x50, 0x4E, 0x47];

final _home = Platform.environment['HOME']!;
final _adbPath = '$_home/Android/Sdk/platform-tools/adb';

Future<void> pumpFor(WidgetTester tester, double seconds) async {
  final end =
      DateTime.now().add(Duration(milliseconds: (seconds * 1000).round()));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('screenshot capture, screen recording and Screen-tab UI',
      (tester) async {
    final adb = AdbService()..configure(_adbPath);

    // --- a. Service-level screenshot capture -------------------------------
    final screencap = ScreencapController(adb);
    await screencap.capture(_serial);
    expect(screencap.error, isNull,
        reason: 'capture failed: ${screencap.error}');
    expect(screencap.bytes, isNotNull);
    final png = screencap.bytes!;
    expect(png.length, greaterThan(8));
    expect(png.sublist(0, 4), _pngMagic, reason: 'not a PNG');
    final img = await decodeImageFromList(png);
    expect(img.width, greaterThan(0));
    expect(img.height, greaterThan(0));
    img.dispose();

    // --- b. Service-level screen recording, with real playback proof ------
    final record = RecordController(adb);
    String? recordedPath;
    try {
      await record.start(_serial, timeLimitSec: 60);
      expect(record.status, RecordStatus.recording,
          reason: 'recording failed to start: ${record.error}');

      // screenrecord's capture is content-driven: an idle emulator screen
      // yields almost no frames (and thus an unreadable/near-zero container
      // duration) no matter how long it "records" for. Drive real on-device
      // activity for the ~10 s window so there's something to capture.
      await Process.run(_adbPath,
          ['-s', _serial, 'shell', 'am', 'start', '-a', 'android.settings.SETTINGS']);
      for (var i = 0; i < 10; i++) {
        await Process.run(_adbPath, [
          '-s', _serial, 'shell', 'input', 'swipe',
          '500', '2200', '500', '800', '150',
        ]);
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      await record.stop();

      var waited = 0.0;
      while (record.status != RecordStatus.done && waited < 20) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        waited += 0.5;
      }
      expect(record.status, RecordStatus.done,
          reason: 'recording did not finalize in time: ${record.error}');
      recordedPath = record.savedPath;
      expect(recordedPath, isNotNull);
      final file = File(recordedPath!);
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), greaterThan(10000));

      final probe = await Process.run('/usr/bin/ffprobe', [
        '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'csv=p=0',
        recordedPath,
      ]);
      expect(probe.exitCode, 0, reason: 'ffprobe failed: ${probe.stderr}');
      final duration = double.parse((probe.stdout as String).trim());
      debugPrint('[screen_test] ffprobe-measured clip duration: ${duration}s');
      expect(duration, inInclusiveRange(6, 16),
          reason: 'unexpected clip duration: $duration s');

      final decode = await Process.run('ffmpeg', [
        '-v', 'error',
        '-ss', '3',
        '-i', recordedPath,
        '-frames:v', '1',
        '-f', 'null',
        '-',
      ]);
      expect(decode.exitCode, 0,
          reason: 'ffmpeg could not decode a frame: ${decode.stderr}');
    } finally {
      if (recordedPath != null && File(recordedPath).existsSync()) {
        File(recordedPath).deleteSync();
      }
    }

    // --- c. UI wiring --------------------------------------------------------
    app.main();
    await pumpFor(tester, 4); // boot, tool detect, tracker connect

    await tester.tap(find.text('Screen'));
    await pumpFor(tester, 1);

    await tester.tap(find.byKey(const ValueKey('screen.capture')));
    await pumpFor(tester, 4);
    expect(find.byKey(const ValueKey('screen.preview')), findsOneWidget);

    // scrcpy is not installed on this machine.
    expect(find.text('scrcpy is not installed'), findsOneWidget);
  });
}
