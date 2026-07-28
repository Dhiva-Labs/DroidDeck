/// Parsed representation of one line of `adb devices -l` output (also the
/// payload format streamed by the adb server's `host:track-devices-l`).
enum DeviceState {
  device,
  offline,
  unauthorized,
  authorizing,
  connecting,
  bootloader,
  recovery,
  rescue,
  sideload,
  noPermissions,
  unknown;

  static DeviceState parse(String raw) {
    final r = raw.trim().toLowerCase();
    if (r.startsWith('no permissions')) return DeviceState.noPermissions;
    for (final s in DeviceState.values) {
      if (s.name.toLowerCase() == r) return s;
    }
    return DeviceState.unknown;
  }

  String get label => switch (this) {
        DeviceState.device => 'online',
        DeviceState.noPermissions => 'no permissions',
        _ => name,
      };
}

class AdbDevice {
  final String serial;
  final DeviceState state;

  /// The raw state text (useful for `no permissions (…)` style messages).
  final String stateRaw;
  final String? product;
  final String? model;
  final String? deviceCode;
  final String? transportId;

  const AdbDevice({
    required this.serial,
    required this.state,
    required this.stateRaw,
    this.product,
    this.model,
    this.deviceCode,
    this.transportId,
  });

  bool get isEmulator => serial.startsWith('emulator-');

  bool get isWireless =>
      RegExp(r'^\d{1,3}(\.\d{1,3}){3}:\d+$').hasMatch(serial) ||
      serial.contains('_adb-tls-connect') ||
      serial.contains('.adb-tls-connect');

  /// Human name: model with underscores expanded, falling back to the serial.
  String get displayName =>
      (model != null && model!.isNotEmpty) ? model!.replaceAll('_', ' ') : serial;

  /// Parses one device line, e.g.
  /// `emulator-5554  device product:sdk_gphone64_x86_64 model:sdk_gphone64_x86_64 device:emu64xa transport_id:1`
  /// Returns null for headers/blank/daemon-notice lines.
  static AdbDevice? parseLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty ||
        trimmed.startsWith('List of devices') ||
        trimmed.startsWith('*')) {
      return null;
    }
    final tokens = trimmed.split(RegExp(r'\s+'));
    if (tokens.length < 2) return null;

    final serial = tokens.first;
    // State may span several tokens ("no permissions (…)"); key:value pairs
    // always contain a colon, so the state is everything before the first one.
    final stateTokens = <String>[];
    final kv = <String, String>{};
    for (final t in tokens.skip(1)) {
      final colon = t.indexOf(':');
      if (colon > 0 && kv.isEmpty && stateTokens.isEmpty) {
        // A colon before any state token would be malformed; treat as state.
        stateTokens.add(t);
      } else if (colon > 0) {
        kv[t.substring(0, colon)] = t.substring(colon + 1);
      } else if (kv.isEmpty) {
        stateTokens.add(t);
      }
    }
    if (stateTokens.isEmpty) return null;
    final stateRaw = stateTokens.join(' ');
    return AdbDevice(
      serial: serial,
      state: DeviceState.parse(stateRaw),
      stateRaw: stateRaw,
      product: kv['product'],
      model: kv['model'],
      deviceCode: kv['device'],
      transportId: kv['transport_id'],
    );
  }

  /// Parses full `adb devices -l` output (or a tracker payload) into a list.
  static List<AdbDevice> parseList(String output) => output
      .split('\n')
      .map(parseLine)
      .whereType<AdbDevice>()
      .toList(growable: false);

  @override
  String toString() => '$serial(${state.name})';

  @override
  bool operator ==(Object other) =>
      other is AdbDevice &&
      other.serial == serial &&
      other.state == state &&
      other.stateRaw == stateRaw &&
      other.model == model &&
      other.transportId == transportId;

  @override
  int get hashCode => Object.hash(serial, state, stateRaw, model, transportId);
}
