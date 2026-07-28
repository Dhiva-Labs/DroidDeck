import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../services/wireless_service.dart';

/// Wireless ADB: enable tcpip on a USB device, connect by IP, pair
/// (Android 11+), mdns discovery, and a persisted list of saved devices.
class WirelessPage extends ConsumerStatefulWidget {
  const WirelessPage({super.key});

  @override
  ConsumerState<WirelessPage> createState() => _WirelessPageState();
}

class _WirelessPageState extends ConsumerState<WirelessPage> {
  final _hostCtrl = TextEditingController();
  final _pairHostCtrl = TextEditingController();
  final _pairCodeCtrl = TextEditingController();
  final _pairSectionKey = GlobalKey();

  bool _tcpipBusy = false;
  bool _connectBusy = false;
  bool _pairBusy = false;
  String? _pairInfo;

  List<MdnsService>? _mdnsResult;
  bool _mdnsLoading = false;

  List<String> _saved = const [];

  @override
  void initState() {
    super.initState();
    _saved = ref.read(settingsRepoProvider).savedWirelessDevices;
    unawaited(_refreshMdns());
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _pairHostCtrl.dispose();
    _pairCodeCtrl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- actions --

  Future<void> _enableTcpip(String serial) async {
    setState(() => _tcpipBusy = true);
    try {
      final out = await ref.read(wirelessServiceProvider).enableTcpip(serial);
      _showInfo(out);
    } catch (e) {
      _showError('$e');
    } finally {
      if (mounted) setState(() => _tcpipBusy = false);
    }
  }

  Future<void> _connectByIpField() async {
    final hostPort = _hostCtrl.text.trim();
    if (hostPort.isEmpty) return;
    setState(() => _connectBusy = true);
    try {
      final out = await ref.read(wirelessServiceProvider).connect(hostPort);
      await _saveDevice(hostPort);
      _hostCtrl.clear();
      _showInfo(out);
    } catch (e) {
      _showError('$e');
    } finally {
      if (mounted) setState(() => _connectBusy = false);
    }
  }

  /// Shared by the tcpip IP suggestion, the discovered-list Connect button
  /// and the saved-devices one-click Connect button.
  Future<void> _connectTo(String hostPort) async {
    try {
      final out = await ref.read(wirelessServiceProvider).connect(hostPort);
      await _saveDevice(hostPort);
      _showInfo(out);
    } catch (e) {
      _showError('$e');
    }
  }

  Future<void> _doPair() async {
    final hostPort = _pairHostCtrl.text.trim();
    final code = _pairCodeCtrl.text.trim();
    if (hostPort.isEmpty || code.isEmpty) return;
    setState(() {
      _pairBusy = true;
      _pairInfo = null;
    });
    try {
      final out = await ref.read(wirelessServiceProvider).pair(hostPort, code);
      _showInfo(out);
      if (mounted) {
        setState(() => _pairInfo = 'Paired — now connect using the port '
            'shown under Wireless debugging.');
      }
    } catch (e) {
      _showError('$e');
    } finally {
      if (mounted) setState(() => _pairBusy = false);
    }
  }

  Future<void> _refreshMdns() async {
    setState(() => _mdnsLoading = true);
    final result = await ref.read(wirelessServiceProvider).mdnsServices();
    if (!mounted) return;
    setState(() {
      _mdnsResult = result;
      _mdnsLoading = false;
    });
  }

  void _prefillPair(String hostPort) {
    setState(() {
      _pairHostCtrl.text = hostPort;
      _pairInfo = null;
    });
    final ctx = _pairSectionKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 250), alignment: 0.1);
    }
  }

  Future<void> _saveDevice(String hostPort) async {
    final repo = ref.read(settingsRepoProvider);
    await repo.addWirelessDevice(hostPort);
    if (!mounted) return;
    setState(() => _saved = repo.savedWirelessDevices);
  }

  Future<void> _removeSaved(String hostPort) async {
    final repo = ref.read(settingsRepoProvider);
    await repo.removeWirelessDevice(hostPort);
    if (!mounted) return;
    setState(() => _saved = repo.savedWirelessDevices);
  }

  void _showInfo(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _showError(String msg) {
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: TextStyle(color: scheme.onErrorContainer)),
      backgroundColor: scheme.errorContainer,
    ));
  }

  // --------------------------------------------------------------- build --

  @override
  Widget build(BuildContext context) {
    final serial = ref.watch(selectedSerialProvider);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _section(_tcpipCard(serial)),
        _section(_connectByIpCard()),
        _section(_pairCard(), key: _pairSectionKey),
        _section(_discoveredCard()),
        _section(_savedCard()),
      ],
    );
  }

  Widget _section(Widget child, {Key? key}) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: Card(
            key: key,
            margin: const EdgeInsets.only(bottom: 16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: child,
            ),
          ),
        ),
      );

  // ------------------------------------------------------------- tcpip ---

  Widget _tcpipCard(String? serial) {
    final scheme = Theme.of(context).colorScheme;
    final ips = serial == null
        ? const <String>[]
        : (ref.watch(deviceDetailsProvider(serial)).value?.ipAddresses ??
            const []);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Enable Wi-Fi debugging over USB',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          'Plug the phone in via USB first. This restarts adbd in TCP mode '
          'so it starts listening for adb over Wi-Fi as well.',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const ValueKey('wireless.tcpip'),
          onPressed: (serial == null || _tcpipBusy)
              ? null
              : () => _enableTcpip(serial),
          icon: _tcpipBusy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.usb),
          label: const Text('Enable tcpip :5555'),
        ),
        if (serial == null) ...[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'No device selected — pick one from the picker at the '
                  'top once it shows up in adb.',
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ] else ...[
          if (ips.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final raw in ips) _ipRow(raw),
          ],
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.shield_outlined,
                  size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'TCP debugging stays open on the device until reverted — '
                  'anyone on the same network can try to connect to port 5555.',
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                key: const ValueKey('wireless.usb'),
                onPressed: () => _revertToUsb(serial),
                icon: const Icon(Icons.usb_off, size: 16),
                label: const Text('Revert to USB'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _revertToUsb(String serial) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final out = await ref.read(wirelessServiceProvider).usbMode(serial);
      messenger.showSnackBar(SnackBar(content: Text(out)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Widget _ipRow(String raw) {
    final ip = raw.trim().split(RegExp(r'\s+')).last;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
              child: Text(raw, style: const TextStyle(fontSize: 12))),
          OutlinedButton(
            key: ValueKey('wireless.tcpipConnect.$ip'),
            onPressed: () => _connectTo('$ip:5555'),
            child: Text('Connect to $ip:5555'),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------- connect by ip --

  Widget _connectByIpCard() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Connect by IP', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('wireless.host'),
                controller: _hostCtrl,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  labelText: 'host:port',
                  hintText: '192.168.1.42:5555',
                ),
                onSubmitted: (_) => _connectByIpField(),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              key: const ValueKey('wireless.connect'),
              onPressed: _connectBusy ? null : _connectByIpField,
              child: _connectBusy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Connect'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'The device list and app-bar picker update automatically once '
          'connected — no need to refresh.',
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  // ------------------------------------------------------------- pairing --

  Widget _pairCard() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Pair a device (Android 11+)',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'On the phone: Developer options → Wireless debugging → Pair '
          'device with pairing code',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                key: const ValueKey('wireless.pairHost'),
                controller: _pairHostCtrl,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  labelText: 'host:port',
                  hintText: '192.168.1.42:37000',
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: TextField(
                key: const ValueKey('wireless.pairCode'),
                controller: _pairCodeCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  labelText: 'pairing code',
                  hintText: '123456',
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              key: const ValueKey('wireless.pair'),
              onPressed: _pairBusy ? null : _doPair,
              child: _pairBusy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Pair'),
            ),
          ],
        ),
        if (_pairInfo != null) ...[
          const SizedBox(height: 8),
          Text(_pairInfo!,
              style: TextStyle(fontSize: 12, color: scheme.primary)),
        ],
      ],
    );
  }

  // ---------------------------------------------------------- discovered --

  Widget _discoveredCard() {
    final scheme = Theme.of(context).colorScheme;
    final result = _mdnsResult;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Discovered on the network',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            IconButton(
              key: const ValueKey('wireless.mdnsRefresh'),
              tooltip: 'Refresh',
              onPressed: _mdnsLoading ? null : _refreshMdns,
              icon: _mdnsLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        if (result == null && _mdnsLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator()),
          )
        else if ((result ?? const []).isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'No services discovered — mdns may be disabled (check `adb '
              'mdns check`), or no phones with Wireless debugging are on '
              'this network.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          )
        else
          for (final s in result!) _mdnsTile(s),
      ],
    );
  }

  Widget _mdnsTile(MdnsService s) {
    Widget? trailing;
    if (s.isPairing) {
      trailing = OutlinedButton(
        onPressed: () => _prefillPair(s.hostPort),
        child: const Text('Pair…'),
      );
    } else if (s.isConnect) {
      trailing = OutlinedButton(
        onPressed: () => _connectTo(s.hostPort),
        child: const Text('Connect'),
      );
    }
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.wifi),
      title: Text(s.instance),
      subtitle: Text('${s.type}  ·  ${s.hostPort}'),
      trailing: trailing,
    );
  }

  // --------------------------------------------------------------- saved --

  Widget _savedCard() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Saved devices', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (_saved.isEmpty)
          Text(
            'Devices you connect to are remembered here.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          )
        else
          for (final hostPort in _saved) _savedTile(hostPort),
      ],
    );
  }

  Widget _savedTile(String hostPort) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(hostPort),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton.tonal(
            key: ValueKey('wireless.saved.$hostPort'),
            onPressed: () => _connectTo(hostPort),
            child: const Text('Connect'),
          ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _removeSaved(hostPort),
          ),
        ],
      ),
    );
  }
}
