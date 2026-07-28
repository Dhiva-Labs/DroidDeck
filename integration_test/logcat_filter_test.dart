import 'dart:io';

import 'package:droid_deck/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Drives the real app against a live emulator (expects emulator-5554 booted).
/// Run with: flutter test integration_test/logcat_filter_test.dart -d linux
const _serial = 'emulator-5554';

final _adb =
    '${Platform.environment['HOME']}/Android/Sdk/platform-tools/adb';

Future<void> _adbRun(List<String> args) async {
  final r = await Process.run(_adb, ['-s', _serial, ...args]);
  if (r.exitCode != 0) {
    throw StateError('adb $args failed: ${r.stderr}');
  }
}

/// Real-time pump: integration tests run live, so background streams keep
/// flowing while we repeatedly pump frames.
Future<void> pumpFor(WidgetTester tester, double seconds) async {
  final end = DateTime.now()
      .add(Duration(milliseconds: (seconds * 1000).round()));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('logcat streams, tag/priority/package filters work',
      (tester) async {
    app.main();
    await pumpFor(tester, 4); // boot, tool detect, tracker connect

    // Open the Logcat tab.
    await tester.tap(find.text('Logcat'));
    await pumpFor(tester, 3); // stream starts, backfill arrives

    // Inject known markers into the device log.
    for (var i = 0; i < 5; i++) {
      await _adbRun(['shell', 'log', '-p', 'i', '-t', 'DeckIT',
          'hello-info-$i']);
    }
    await _adbRun(
        ['shell', 'log', '-p', 'e', '-t', 'DeckIT', 'boom-error-marker']);
    await pumpFor(tester, 2);

    // Tag filter narrows the view to our markers.
    await tester.enterText(find.byKey(const ValueKey('logcat.tag')), 'DeckIT');
    await pumpFor(tester, 1.5); // debounce + flush
    expect(find.textContaining('hello-info-4', findRichText: true),
        findsOneWidget);
    expect(find.textContaining('boom-error-marker', findRichText: true),
        findsOneWidget);

    // Min-priority E hides the info lines, keeps the error.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('logcat.priority')),
        matching: find.text('E'),
      ),
    );
    await pumpFor(tester, 1);
    expect(find.textContaining('hello-info-4', findRichText: true),
        findsNothing);
    expect(find.textContaining('boom-error-marker', findRichText: true),
        findsOneWidget);

    // Back to V for the package-filter check.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('logcat.priority')),
        matching: find.text('V'),
      ),
    );
    await pumpFor(tester, 0.5);

    // Package filter: bogus package shows "not running".
    await tester.enterText(
        find.byKey(const ValueKey('logcat.package')), 'no.such.package');
    await pumpFor(tester, 1.5);
    expect(find.text('not running'), findsOneWidget);

    // Real package resolves to a pid (launch Settings first).
    await _adbRun([
      'shell', 'am', 'start', '-a', 'android.settings.SETTINGS'
    ]);
    await pumpFor(tester, 2);
    await tester.enterText(find.byKey(const ValueKey('logcat.package')),
        'com.android.settings');
    await pumpFor(tester, 2);
    expect(find.textContaining('pid '), findsOneWidget);

    // Clear filters, clear buffer.
    await tester.enterText(
        find.byKey(const ValueKey('logcat.package')), '');
    await tester.enterText(find.byKey(const ValueKey('logcat.tag')), '');
    await pumpFor(tester, 1);
    await tester.tap(find.byKey(const ValueKey('logcat.clear')));
    await pumpFor(tester, 1);
    expect(find.textContaining('boom-error-marker', findRichText: true),
        findsNothing);
  });
}
