import 'dart:io';

import 'package:droid_deck/main.dart' as app;
import 'package:droid_deck/services/adb_service.dart';
import 'package:droid_deck/services/wireless_service.dart';
import 'package:droid_deck/ui/pages/wireless_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Wireless ADB against a live emulator (expects emulator-5554 booted).
/// The emulator's guest adbd already listens on TCP 5555 of the host
/// loopback (standard emulator setup), so `connect 127.0.0.1:5555` is a
/// real loopback round-trip that registers a second device entry alongside
/// `emulator-5554` — exactly what this phase's UI drives.
/// Run with: flutter test integration_test/wireless_test.dart -d linux
const _hostPort = '127.0.0.1:5555';
const _prefsKey = 'wirelessDevices';

final _home = Platform.environment['HOME']!;
final _adbPath = '$_home/Android/Sdk/platform-tools/adb';

Future<String> _adbOut(List<String> args) async {
  final r = await Process.run(_adbPath, args);
  return '${r.stdout}';
}

Future<bool> _isListedAs(String hostPort, String state) async {
  final out = await _adbOut(['devices']);
  for (final line in out.split('\n')) {
    final t = line.trim();
    if (t.startsWith(hostPort) && t.contains(state)) return true;
  }
  return false;
}

Future<bool> _isListed(String hostPort) async {
  final out = await _adbOut(['devices']);
  return out.split('\n').any((l) => l.trim().startsWith(hostPort));
}

/// [hostPort] can transiently show "offline" right after connect before
/// settling into "device" — poll rather than checking once.
Future<bool> _waitFor(
  Future<bool> Function() check, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await check()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  return false;
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

  testWidgets('connect by IP, saved-device reconnect, mdns discovery',
      (tester) async {
    // --- a. Pre-clean: drop any stale loopback connection from a previous
    // run, and clear the saved-devices prefs key so step (c)'s persistence
    // assertion is deterministic regardless of history.
    await Process.run(_adbPath, ['disconnect', _hostPort]);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);

    try {
      // --- b. Boot the app, open the Wireless tab.
      app.main();
      await pumpFor(tester, 4); // boot, tool detect, tracker connect
      await tester.tap(find.text('Wireless'));
      await pumpFor(tester, 1);

      // --- c. Connect by IP against the emulator's own loopback adbd.
      await tester.enterText(
          find.byKey(const ValueKey('wireless.host')), _hostPort);
      await tester.tap(find.byKey(const ValueKey('wireless.connect')));
      await pumpFor(tester, 3);

      final gotDevice =
          await _waitFor(() => _isListedAs(_hostPort, 'device'));
      expect(gotDevice, isTrue,
          reason:
              '$_hostPort never reached state "device" (adb devices: '
              '${await _adbOut(['devices'])})');

      // SharedPreferences persistence, asserted at the service layer (same
      // isolate as the running app, so the singleton is shared).
      final savedList = prefs.getStringList(_prefsKey) ?? const [];
      expect(savedList, contains(_hostPort));

      // --- d. Saved-device one-click reconnect ("already connected" path).
      await pumpFor(tester, 0.5); // let the saved-devices list rebuild
      final savedKey = find.byKey(ValueKey('wireless.saved.$_hostPort'));
      // The "Saved devices" card is the last of five in the ListView and
      // may be laid out below the fold (not yet built by the sliver), so
      // scroll it into view rather than assuming it's already mounted.
      // The scrollable target must be scoped tightly: IndexedStack keeps
      // every tab's page mounted (each with its own ListView), and even
      // within WirelessPage alone each TextField's EditableText carries an
      // internal Scrollable, so find.byType(Scrollable) is ambiguous both
      // globally and within the page. The page's own ListView wraps
      // everything else, so its Scrollable is first in tree order.
      await tester.scrollUntilVisible(savedKey, 250,
          scrollable: find
              .descendant(
                  of: find.byType(WirelessPage), matching: find.byType(Scrollable))
              .first);
      await pumpFor(tester, 0.3);
      expect(savedKey, findsOneWidget);
      await tester.tap(savedKey);
      await pumpFor(tester, 2);
      final stillListed = await _waitFor(() => _isListed(_hostPort));
      expect(stillListed, isTrue,
          reason: 'device disappeared after the saved-device reconnect tap');

      // --- e. mdns: service-level call must not throw.
      final adb = AdbService()..configure(_adbPath);
      final wireless = WirelessService(adb);
      List<MdnsService> mdnsList;
      try {
        mdnsList = await wireless.mdnsServices();
      } catch (e, st) {
        fail('mdnsServices() threw: $e\n$st');
      }
      debugPrint('[wireless_test] mdnsServices() -> ${mdnsList.length} '
          'service(s): ${mdnsList.join(', ')}');
    } finally {
      // --- f. Cleanup: disconnect the wireless device, poll until gone.
      // The saved-devices prefs entry is intentionally left in place — it
      // demonstrates persistence, and addWirelessDevice's dedupe keeps the
      // list stable across reruns (determinism comes from the pre-clean).
      await Process.run(_adbPath, ['disconnect', _hostPort]);
      final gone = await _waitFor(() async => !await _isListed(_hostPort));
      expect(gone, isTrue,
          reason: '$_hostPort still listed after cleanup disconnect');
      // g. emulator-5554 was never disconnected, so its selection (if any)
      // was never "missing" and never got re-picked — nothing to restore.
    }
  });
}
