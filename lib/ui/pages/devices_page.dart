import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/adb_device.dart';
import '../../providers.dart';
import '../../services/device_info.dart';
import '../../services/device_tracker.dart';
import '../device_visuals.dart';

class DevicesPage extends ConsumerWidget {
  const DevicesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tools = ref.watch(toolStatusProvider);
    final devices = ref.watch(devicesProvider);
    final list = devices.value ?? const <AdbDevice>[];

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _InfoCard(
                icon: Icons.adb,
                title: 'adb',
                value: tools.when(
                  loading: () => 'detecting…',
                  error: (e, _) => 'error',
                  data: (s) => s.adb.found ? 'v${s.adb.version}' : 'not found',
                ),
                subtitle: tools.value?.adb.path,
              ),
              _InfoCard(
                icon: Icons.devices,
                title: 'Connected devices',
                value: devices.isLoading && list.isEmpty ? '…' : '${list.length}',
              ),
              const _TrackerChip(),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 380, child: _DeviceList(list: list)),
                const SizedBox(width: 16),
                const Expanded(child: _DetailPanel()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackerChip extends ConsumerWidget {
  const _TrackerChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(trackerModeProvider).value ?? TrackerMode.connecting;
    final scheme = Theme.of(context).colorScheme;
    final (label, icon, color) = switch (mode) {
      TrackerMode.socket => (
          'Live tracking',
          Icons.bolt,
          Colors.greenAccent.shade400
        ),
      TrackerMode.polling => ('Polling fallback', Icons.sync, Colors.amber),
      TrackerMode.connecting => (
          'Connecting…',
          Icons.hourglass_top,
          scheme.onSurfaceVariant
        ),
    };
    return Chip(
      avatar: Icon(icon, size: 16, color: color),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _DeviceList extends ConsumerWidget {
  final List<AdbDevice> list;

  const _DeviceList({required this.list});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final selected = ref.watch(selectedSerialProvider);

    if (list.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.phonelink_off, size: 64, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            const Text('No devices connected'),
            const SizedBox(height: 4),
            Text(
              'Plug in a phone with USB debugging enabled,\nor start an emulator.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      itemCount: list.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final d = list[i];
        final isSelected = d.serial == selected;
        return Card(
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: isSelected ? scheme.primary : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: ListTile(
            onTap: () =>
                ref.read(selectedSerialProvider.notifier).select(d.serial),
            leading: Icon(deviceIcon(d), color: stateColor(scheme, d.state)),
            title: Text(d.displayName),
            subtitle: Text(
              [
                d.serial,
                if (d.transportId != null) 'transport ${d.transportId}',
              ].join('  ·  '),
            ),
            trailing: Chip(
              avatar: Icon(stateIcon(d.state),
                  size: 16, color: stateColor(scheme, d.state)),
              label: Text(d.state.label),
              visualDensity: VisualDensity.compact,
            ),
          ),
        );
      },
    );
  }
}

class _DetailPanel extends ConsumerWidget {
  const _DetailPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final device = ref.watch(selectedDeviceProvider);
    final scheme = Theme.of(context).colorScheme;

    if (device == null) {
      return Center(
        child: Text('Select a device to see its details',
            style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }

    if (device.state != DeviceState.device) {
      final hint = switch (device.state) {
        DeviceState.unauthorized =>
          'Accept the USB-debugging authorization prompt on the device.',
        DeviceState.offline =>
          'The device is offline — replug it or restart adb.',
        DeviceState.noPermissions =>
          'Missing udev permissions — check your udev rules.',
        _ => 'Device is not ready (${device.stateRaw}).',
      };
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(stateIcon(device.state),
                size: 56, color: stateColor(scheme, device.state)),
            const SizedBox(height: 12),
            Text('${device.displayName} is ${device.state.label}'),
            const SizedBox(height: 4),
            Text(hint,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ],
        ),
      );
    }

    final details = ref.watch(deviceDetailsProvider(device.serial));
    return details.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: scheme.error, size: 40),
            const SizedBox(height: 8),
            Text('Could not read device details:\n$e',
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () =>
                  ref.invalidate(deviceDetailsProvider(device.serial)),
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
      data: (d) => _DetailContent(device: device, details: d),
    );
  }
}

class _DetailContent extends ConsumerWidget {
  final AdbDevice device;
  final DeviceDetails details;

  const _DetailContent({required this.device, required this.details});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final d = details;

    String sizeText() {
      if (d.physicalSize == null) return '—';
      final o = d.overrideSize != null && d.overrideSize != d.physicalSize
          ? '  (override: ${d.overrideSize})'
          : '';
      return '${d.physicalSize}$o';
    }

    String densityText() {
      if (d.physicalDensity == null) return '—';
      final o = d.overrideDensity != null &&
              d.overrideDensity != d.physicalDensity
          ? '  (override: ${d.overrideDensity})'
          : '';
      return '${d.physicalDensity} dpi$o';
    }

    return ListView(
      children: [
        Row(
          children: [
            Icon(deviceIcon(device),
                size: 40, color: stateColor(scheme, device.state)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(device.displayName,
                      style: Theme.of(context).textTheme.titleLarge),
                  Text(device.serial,
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Refresh details',
              onPressed: () =>
                  ref.invalidate(deviceDetailsProvider(device.serial)),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _Section(
          title: 'System',
          rows: [
            ('Android', d.androidVersion ?? '—'),
            ('API level', d.apiLevel ?? '—'),
            ('Manufacturer', d.manufacturer ?? '—'),
            ('Model', d.model ?? '—'),
            ('Build', d.buildId ?? '—'),
          ],
        ),
        const SizedBox(height: 12),
        _Section(
          title: 'Display',
          rows: [
            ('Resolution', sizeText()),
            ('Density', densityText()),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Battery', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 12),
                if (d.batteryLevel != null) ...[
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: d.batteryLevel! / 100,
                            minHeight: 8,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text('${d.batteryLevel}%'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    [
                      if (d.batteryStatus != null) d.batteryStatus!,
                      if (d.powerSource != null) d.powerSource!,
                    ].join('  ·  '),
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ] else
                  Text('—',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _Section(
          title: 'Network',
          rows: d.ipAddresses.isEmpty
              ? [('IP address', '—')]
              : [for (final ip in d.ipAddresses) ('IP', ip)],
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<(String, String)> rows;

  const _Section({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 130,
                      child: Text(label,
                          style: TextStyle(
                              fontSize: 13, color: scheme.onSurfaceVariant)),
                    ),
                    Expanded(
                      child: SelectableText(value,
                          style: const TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final String? subtitle;

  const _InfoCard({
    required this.icon,
    required this.title,
    required this.value,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text(title, style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 6),
            Text(value, style: Theme.of(context).textTheme.titleLarge),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(subtitle!,
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }
}
