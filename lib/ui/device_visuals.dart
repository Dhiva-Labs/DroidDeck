import 'package:flutter/material.dart';

import '../models/adb_device.dart';

IconData deviceIcon(AdbDevice d) {
  if (d.isEmulator) return Icons.computer;
  if (d.isWireless) return Icons.wifi;
  return Icons.smartphone;
}

IconData stateIcon(DeviceState s) => switch (s) {
      DeviceState.device => Icons.check_circle,
      DeviceState.offline => Icons.cloud_off,
      DeviceState.unauthorized => Icons.lock,
      DeviceState.authorizing || DeviceState.connecting => Icons.hourglass_top,
      DeviceState.noPermissions => Icons.block,
      DeviceState.bootloader ||
      DeviceState.recovery ||
      DeviceState.rescue ||
      DeviceState.sideload =>
        Icons.build,
      DeviceState.unknown => Icons.help_outline,
    };

Color stateColor(ColorScheme scheme, DeviceState s) => switch (s) {
      DeviceState.device => Colors.greenAccent.shade400,
      DeviceState.unauthorized ||
      DeviceState.authorizing ||
      DeviceState.connecting =>
        Colors.amber.shade400,
      DeviceState.offline ||
      DeviceState.unknown =>
        scheme.onSurfaceVariant,
      _ => scheme.error,
    };
