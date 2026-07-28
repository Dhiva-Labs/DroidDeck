import 'adb_service.dart';

/// Detail-panel facts about one device, fetched on demand.
class DeviceDetails {
  final String? androidVersion;
  final String? apiLevel;
  final String? manufacturer;
  final String? model;
  final String? buildId;
  final int? batteryLevel;
  final String? batteryStatus;
  final String? powerSource;
  final String? physicalSize;
  final String? overrideSize;
  final String? physicalDensity;
  final String? overrideDensity;
  final List<String> ipAddresses;

  const DeviceDetails({
    this.androidVersion,
    this.apiLevel,
    this.manufacturer,
    this.model,
    this.buildId,
    this.batteryLevel,
    this.batteryStatus,
    this.powerSource,
    this.physicalSize,
    this.overrideSize,
    this.physicalDensity,
    this.overrideDensity,
    this.ipAddresses = const [],
  });
}

Future<DeviceDetails> fetchDeviceDetails(AdbService adb, String serial) async {
  final results = await Future.wait([
    adb.shell(
        serial,
        'getprop ro.build.version.release; getprop ro.build.version.sdk; '
        'getprop ro.product.manufacturer; getprop ro.product.model; '
        'getprop ro.build.display.id'),
    adb.shell(serial, 'dumpsys battery'),
    adb.shell(serial, 'wm size; wm density'),
    adb.shell(serial, 'ip -o -4 addr show scope global'),
  ]);

  final props = results[0].ok
      ? results[0].out.split('\n').map((l) => l.trim()).toList()
      : const <String>[];
  String? prop(int i) =>
      (i < props.length && props[i].isNotEmpty) ? props[i] : null;

  int? batteryLevel;
  String? batteryStatus;
  String? powerSource;
  if (results[1].ok) {
    final battery = results[1].stdout;
    final level = RegExp(r'level: (\d+)').firstMatch(battery);
    batteryLevel = level == null ? null : int.tryParse(level.group(1)!);
    final status = RegExp(r'status: (\d+)').firstMatch(battery);
    batteryStatus = switch (int.tryParse(status?.group(1) ?? '')) {
      2 => 'charging',
      3 => 'discharging',
      4 => 'not charging',
      5 => 'full',
      _ => null,
    };
    final sources = <String>[
      if (battery.contains('AC powered: true')) 'AC',
      if (battery.contains('USB powered: true')) 'USB',
      if (battery.contains('Wireless powered: true')) 'wireless',
      if (battery.contains('Dock powered: true')) 'dock',
    ];
    powerSource = sources.isEmpty ? 'unplugged' : sources.join(' + ');
  }

  String? wmValue(String output, String label) =>
      RegExp('$label: (.+)').firstMatch(output)?.group(1)?.trim();
  final wm = results[2].ok ? results[2].stdout : '';

  final ips = <String>[];
  if (results[3].ok) {
    for (final line in results[3].stdout.split('\n')) {
      final m =
          RegExp(r'^\d+:\s+(\S+)\s+inet\s+([\d.]+)').firstMatch(line.trim());
      if (m != null) ips.add('${m.group(1)}  ${m.group(2)}');
    }
  }

  return DeviceDetails(
    androidVersion: prop(0),
    apiLevel: prop(1),
    manufacturer: prop(2),
    model: prop(3),
    buildId: prop(4),
    batteryLevel: batteryLevel,
    batteryStatus: batteryStatus,
    powerSource: powerSource,
    physicalSize: wmValue(wm, 'Physical size'),
    overrideSize: wmValue(wm, 'Override size'),
    physicalDensity: wmValue(wm, 'Physical density'),
    overrideDensity: wmValue(wm, 'Override density'),
    ipAddresses: ips,
  );
}
