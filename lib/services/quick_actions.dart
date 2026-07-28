import 'adb_service.dart';

/// One-shot device actions (keyevents, rotation, display overrides, dumpsys
/// shortcuts) — every one of them goes through [AdbService.shell], nothing
/// here spawns a process directly.
class QuickActionsService {
  final AdbService _adb;

  QuickActionsService(this._adb);

  Future<void> keyevent(String serial, int code) =>
      _run(serial, 'input keyevent $code');

  Future<void> setAutoRotate(String serial, bool on) =>
      _run(serial, 'settings put system accelerometer_rotation ${on ? 1 : 0}');

  /// [quadrant] is 0..3 for 0/90/180/270 degrees (Android's user_rotation
  /// values). Auto-rotate is disabled first so the override actually sticks.
  Future<void> setRotation(String serial, int quadrant) async {
    await setAutoRotate(serial, false);
    await _run(serial, 'settings put system user_rotation $quadrant');
  }

  /// Overrides display density; `null` resets to the physical default.
  Future<void> density(String serial, int? dpi) => _run(
      serial, dpi == null ? 'wm density reset' : 'wm density $dpi');

  /// Overrides display size (`"720x1280"`); `null` resets to physical.
  Future<void> size(String serial, String? wxh) =>
      _run(serial, wxh == null ? 'wm size reset' : 'wm size $wxh');

  /// Runs `dumpsys <section>` with a 15 s timeout and returns its stdout
  /// (falling back to stderr if the command produced nothing on stdout).
  Future<String> dumpsys(String serial, String section) async {
    final r = await _adb.shell(serial, 'dumpsys $section',
        timeout: const Duration(seconds: 15));
    return r.stdout.isNotEmpty ? r.stdout : r.error;
  }

  Future<void> _run(String serial, String command) async {
    final r = await _adb.shell(serial, command);
    if (!r.ok) throw AdbException(r.error);
  }
}
