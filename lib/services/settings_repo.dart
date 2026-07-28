import 'package:shared_preferences/shared_preferences.dart';

/// Thin typed wrapper over SharedPreferences. All persisted keys live here.
class SettingsRepo {
  static const _kAdbOverride = 'adbPathOverride';
  static const _kScrcpyOverride = 'scrcpyPathOverride';
  static const _kWirelessDevices = 'wirelessDevices';

  final SharedPreferences _prefs;

  SettingsRepo(this._prefs);

  String? get adbOverride => _nonEmpty(_prefs.getString(_kAdbOverride));
  String? get scrcpyOverride => _nonEmpty(_prefs.getString(_kScrcpyOverride));

  Future<void> setAdbOverride(String? v) => _setOrRemove(_kAdbOverride, v);
  Future<void> setScrcpyOverride(String? v) => _setOrRemove(_kScrcpyOverride, v);

  /// Wireless devices the user has connected to, most-recently-used first.
  List<String> get savedWirelessDevices =>
      _prefs.getStringList(_kWirelessDevices) ?? const [];

  Future<void> addWirelessDevice(String hostPort) async {
    final list = List<String>.of(savedWirelessDevices);
    list.remove(hostPort);
    list.insert(0, hostPort);
    await _prefs.setStringList(_kWirelessDevices, list);
  }

  Future<void> removeWirelessDevice(String hostPort) async {
    final list = List<String>.of(savedWirelessDevices)..remove(hostPort);
    await _prefs.setStringList(_kWirelessDevices, list);
  }

  Future<void> _setOrRemove(String key, String? v) async {
    if (v == null || v.trim().isEmpty) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, v.trim());
    }
  }

  static String? _nonEmpty(String? v) =>
      (v == null || v.trim().isEmpty) ? null : v.trim();
}
