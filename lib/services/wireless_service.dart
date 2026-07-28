import 'adb_service.dart';

/// One row of `adb mdns services` output, e.g.
/// `adb-XXXX-YYYY\t_adb-tls-connect._tcp\t192.168.1.42:37000`
class MdnsService {
  final String instance;
  final String type;
  final String hostPort;

  const MdnsService({
    required this.instance,
    required this.type,
    required this.hostPort,
  });

  bool get isPairing => type.contains('pairing');
  bool get isConnect =>
      type.contains('tls-connect') || type == '_adb._tcp';

  @override
  String toString() => '$instance $type $hostPort';
}

/// Combines stdout+stderr for callers that don't know (or trust) which
/// stream a given adb subcommand prints its result to.
String _combined(AdbResult r) {
  final out = r.out;
  final err = r.stderr.trim();
  if (out.isNotEmpty && err.isNotEmpty) return '$out\n$err';
  return out.isNotEmpty ? out : err;
}

/// Wireless ADB: enable tcpip mode on a USB-attached device, connect/pair/
/// disconnect by host:port, and mdns-based discovery. Every adb invocation
/// goes through [AdbService] — nothing here spawns a process directly.
class WirelessService {
  final AdbService _adb;

  WirelessService(this._adb);

  /// Restarts adbd on [serial] back in USB-only mode, closing the TCP port
  /// that `tcpip` opened.
  Future<String> usbMode(String serial) async {
    final r = await _adb.run(['usb'],
        serial: serial, timeout: const Duration(seconds: 10));
    final text = r.out.isEmpty ? r.error : r.out;
    if (!r.ok && !text.contains('restarting in USB mode')) {
      throw AdbException(text.isEmpty ? 'adb usb failed' : text);
    }
    return text;
  }

  /// Restarts adbd on [serial] listening over TCP on [port] (default 5555).
  /// The device must currently be reachable (typically over USB).
  Future<String> enableTcpip(String serial, {int port = 5555}) async {
    final r = await _adb.run(['tcpip', '$port'], serial: serial);
    final out = r.out;
    if (out.contains('restarting in TCP mode')) return out;
    throw AdbException(out.isNotEmpty ? out : r.error);
  }

  /// Connects to a device listening at [hostPort] (e.g. `192.168.1.42:5555`).
  /// adb prints connect failures to stdout with a zero exit code (e.g.
  /// `failed to connect to '...': Connection refused`), so success is
  /// judged by the TEXT, not the exit code. `already connected to ...`
  /// also contains `connected to`, so it's treated as success too.
  Future<String> connect(String hostPort) async {
    final r = await _adb.run(['connect', hostPort],
        timeout: const Duration(seconds: 15));
    final out = r.out;
    if (out.contains('connected to')) return out;
    throw AdbException(out.isNotEmpty ? out : r.error);
  }

  Future<String> disconnect(String hostPort) async {
    final r = await _adb.run(['disconnect', hostPort]);
    return r.out.isNotEmpty ? r.out : r.error;
  }

  /// Pairs with a device advertising a pairing service (Android 11+'s
  /// "Wireless debugging → Pair device with pairing code"), using the
  /// host:port and 6-digit code shown on the phone.
  Future<String> pair(String hostPort, String code) async {
    final r = await _adb.run(['pair', hostPort, code],
        timeout: const Duration(seconds: 30));
    final out = _combined(r);
    if (out.contains('Successfully paired')) return out;
    throw AdbException(out);
  }

  /// Lists mdns-discovered adb services on the local network. Returns an
  /// empty list (rather than throwing) if the command fails outright — the
  /// mdns backend may simply be off (`adb mdns check`), which isn't an
  /// error worth surfacing as one.
  Future<List<MdnsService>> mdnsServices() async {
    try {
      final r = await _adb.run(['mdns', 'services'],
          timeout: const Duration(seconds: 10));
      if (!r.ok) return const [];
      return _parseMdns(r.stdout);
    } catch (_) {
      return const [];
    }
  }

  static List<MdnsService> _parseMdns(String output) {
    final services = <MdnsService>[];
    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length != 3) continue; // header line, notices, etc.
      services.add(MdnsService(
        instance: parts[0],
        type: parts[1],
        hostPort: parts[2],
      ));
    }
    return services;
  }
}
