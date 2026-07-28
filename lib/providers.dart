import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models/adb_device.dart';
import 'models/fs_entry.dart';
import 'services/adb_service.dart';
import 'services/app_manager.dart';
import 'services/file_explorer.dart';
import 'services/portal_file_picker.dart';
import 'services/screen_tools.dart';
import 'services/transfers_controller.dart';
import 'services/device_info.dart';
import 'services/device_tracker.dart';
import 'services/logcat_controller.dart';
import 'services/quick_actions.dart';
import 'services/settings_repo.dart';
import 'services/terminal_session.dart';
import 'services/tool_locator.dart';
import 'services/wireless_service.dart';

/// Overridden with the real instance in main().
final settingsRepoProvider =
    Provider<SettingsRepo>((ref) => throw UnimplementedError());

final adbServiceProvider = Provider<AdbService>((ref) => AdbService());

class ToolStatus {
  final ToolInfo adb;
  final ToolInfo scrcpy;
  const ToolStatus({required this.adb, required this.scrcpy});
}

class ToolStatusNotifier extends AsyncNotifier<ToolStatus> {
  @override
  Future<ToolStatus> build() async {
    final repo = ref.watch(settingsRepoProvider);
    final locator = ToolLocator();
    final adb = await locator.locate('adb', override: repo.adbOverride);
    final scrcpy = await locator.locate('scrcpy', override: repo.scrcpyOverride);
    ref.read(adbServiceProvider).configure(adb.path);
    debugPrint('[DroidDeck] adb: ${adb.path ?? 'NOT FOUND'}'
        '${adb.version != null ? ' v${adb.version}' : ''}'
        ' | scrcpy: ${scrcpy.path ?? 'NOT FOUND'}'
        '${scrcpy.version != null ? ' v${scrcpy.version}' : ''}');
    return ToolStatus(adb: adb, scrcpy: scrcpy);
  }
}

final toolStatusProvider =
    AsyncNotifierProvider<ToolStatusNotifier, ToolStatus>(ToolStatusNotifier.new);

/// The live tracker, created once adb is found; null until then.
final deviceTrackerProvider = Provider<DeviceTracker?>((ref) {
  final status = ref.watch(toolStatusProvider).value;
  if (status == null || !status.adb.found) return null;
  final tracker = DeviceTracker(ref.watch(adbServiceProvider));
  ref.onDispose(tracker.dispose);
  tracker.start();
  return tracker;
});

/// Live device list, pushed from the tracker socket (or its polling fallback).
final devicesProvider = StreamProvider<List<AdbDevice>>((ref) async* {
  final tracker = ref.watch(deviceTrackerProvider);
  if (tracker == null) {
    yield const [];
    return;
  }
  yield tracker.current;
  yield* tracker.devices;
});

final trackerModeProvider = StreamProvider<TrackerMode>((ref) async* {
  final tracker = ref.watch(deviceTrackerProvider);
  if (tracker == null) {
    yield TrackerMode.connecting;
    return;
  }
  yield tracker.mode;
  yield* tracker.modeStream;
});

/// On-demand facts for the detail panel, keyed by serial.
final deviceDetailsProvider = FutureProvider.autoDispose
    .family<DeviceDetails, String>((ref, serial) async {
  final adb = ref.watch(adbServiceProvider);
  return fetchDeviceDetails(adb, serial);
});

final appManagerProvider = Provider<AppManagerService>(
    (ref) => AppManagerService(ref.watch(adbServiceProvider)));

/// Installed packages on the selected device; invalidate to refresh.
final appsProvider =
    FutureProvider.autoDispose<List<AppPackage>>((ref) async {
  final serial = ref.watch(selectedSerialProvider);
  if (serial == null) return const [];
  return ref.watch(appManagerProvider).list(serial);
});

final fileExplorerProvider = Provider<FileExplorerService>(
    (ref) => FileExplorerService(ref.watch(adbServiceProvider)));

/// Directory listing keyed by (serial, path); invalidate to refresh.
final filesProvider = FutureProvider.autoDispose
    .family<List<FsEntry>, ({String serial, String path})>((ref, key) {
  return ref.watch(fileExplorerProvider).list(key.serial, key.path);
});

final transfersProvider = Provider<TransfersController>((ref) {
  final c = TransfersController();
  ref.onDispose(c.dispose);
  return c;
});

/// Indirection for the portal picker so integration tests can override it
/// (the real portal opens a system dialog no test can drive).
final portalOpenFilesProvider =
    Provider<Future<List<String>> Function(String title, bool multiple)>(
  (ref) => (title, multiple) => PortalFilePicker.openFiles(
        title: title,
        multiple: multiple,
      ),
);

/// One logcat stream bound to the globally selected device; recreated (and
/// the old one disposed, killing its process) when the selection changes.
final logcatControllerProvider = Provider<LogcatController>((ref) {
  final adb = ref.watch(adbServiceProvider);
  final serial = ref.watch(selectedSerialProvider);
  final c = LogcatController(adb, serial);
  ref.onDispose(c.dispose);
  if (serial != null) unawaited(c.start());
  return c;
});

/// Screenshot capture. Serial is passed per call, not watched, so a capture
/// in flight survives the user switching the globally-selected device.
final screencapProvider = Provider<ScreencapController>((ref) {
  final c = ScreencapController(ref.watch(adbServiceProvider));
  ref.onDispose(c.dispose);
  return c;
});

/// Screen recording lifecycle. Serial is passed per call, not watched.
final recordControllerProvider = Provider<RecordController>((ref) {
  final c = RecordController(ref.watch(adbServiceProvider));
  ref.onDispose(c.dispose);
  return c;
});

/// Tracks launched scrcpy mirror sessions.
final scrcpyControllerProvider = Provider<ScrcpyController>((ref) {
  final c = ScrcpyController();
  ref.onDispose(c.dispose);
  return c;
});

/// Wireless ADB: tcpip/connect/disconnect/pair/mdns discovery.
final wirelessServiceProvider = Provider<WirelessService>(
    (ref) => WirelessService(ref.watch(adbServiceProvider)));

/// Keyevents, rotation, density/size overrides and dumpsys shortcuts.
final quickActionsServiceProvider = Provider<QuickActionsService>(
    (ref) => QuickActionsService(ref.watch(adbServiceProvider)));

/// One interactive `adb shell` PTY session bound to the globally selected
/// device; recreated (and the old one disposed, killing its pty) when the
/// selection changes — same lifecycle as [logcatControllerProvider].
final terminalSessionProvider = Provider<TerminalSession>((ref) {
  final adb = ref.watch(adbServiceProvider);
  final serial = ref.watch(selectedSerialProvider);
  final s = TerminalSession(adb, serial);
  ref.onDispose(s.dispose);
  if (serial != null) s.start();
  return s;
});

class SelectedSerialNotifier extends Notifier<String?> {
  @override
  String? build() {
    ref.listen(devicesProvider, (_, next) {
      final list = next.value;
      if (list == null) return;
      final serials = list.map((d) => d.serial).toSet();
      if (state != null && serials.contains(state)) return;
      AdbDevice? pick;
      for (final d in list) {
        if (d.state == DeviceState.device) {
          pick = d;
          break;
        }
      }
      pick ??= list.isEmpty ? null : list.first;
      state = pick?.serial;
    });
    return null;
  }

  void select(String? serial) => state = serial;
}

/// The globally selected device serial. Auto-picks the first online device
/// and heals itself when the selected device disappears.
final selectedSerialProvider =
    NotifierProvider<SelectedSerialNotifier, String?>(SelectedSerialNotifier.new);

/// Convenience: the AdbDevice for the current selection, if still present.
final selectedDeviceProvider = Provider<AdbDevice?>((ref) {
  final serial = ref.watch(selectedSerialProvider);
  final list = ref.watch(devicesProvider).value ?? const <AdbDevice>[];
  if (serial == null) return null;
  for (final d in list) {
    if (d.serial == serial) return d;
  }
  return null;
});
