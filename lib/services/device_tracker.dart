import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/adb_device.dart';
import 'adb_service.dart';

/// How the tracker is currently getting device updates.
enum TrackerMode { connecting, socket, polling }

const _utf8Lenient = Utf8Decoder(allowMalformed: true);

sealed class TrackerEvent {
  const TrackerEvent();
}

class TrackerOkay extends TrackerEvent {
  const TrackerOkay();
}

class TrackerFail extends TrackerEvent {
  final String message;
  const TrackerFail(this.message);
}

class TrackerPayload extends TrackerEvent {
  final String text;
  const TrackerPayload(this.text);
}

/// Incremental parser for the adb server's client protocol as seen by a
/// `host:track-devices*` subscriber:
///
///   OKAY                      ← 4-byte status (or FAIL + %04x + message)
///   %04x `device list`        ← repeated, one frame per device-set change
///
/// Frames arrive on a TCP stream and can be split or coalesced arbitrarily;
/// feed() buffers bytes and emits complete events only.
class TrackerFrameParser {
  final List<int> _buf = [];
  bool _statusParsed = false;
  bool _failed = false;

  List<TrackerEvent> feed(List<int> chunk) {
    _buf.addAll(chunk);
    final events = <TrackerEvent>[];
    while (true) {
      if (_failed) break;
      if (!_statusParsed) {
        if (_buf.length < 4) break;
        final status = String.fromCharCodes(_buf.sublist(0, 4));
        if (status == 'OKAY') {
          _drop(4);
          _statusParsed = true;
          events.add(const TrackerOkay());
        } else if (status == 'FAIL') {
          if (_buf.length < 8) break;
          final len = _hexLen(4);
          if (_buf.length < 8 + len) break;
          final msg = _utf8Lenient.convert(_buf.sublist(8, 8 + len));
          _drop(8 + len);
          _statusParsed = true;
          _failed = true;
          events.add(TrackerFail(msg));
        } else {
          throw FormatException('unexpected tracker status "$status"');
        }
      } else {
        if (_buf.length < 4) break;
        final len = _hexLen(0);
        if (_buf.length < 4 + len) break;
        final payload = _utf8Lenient.convert(_buf.sublist(4, 4 + len));
        _drop(4 + len);
        events.add(TrackerPayload(payload));
      }
    }
    return events;
  }

  int _hexLen(int offset) {
    final hex = String.fromCharCodes(_buf.sublist(offset, offset + 4));
    final len = int.tryParse(hex, radix: 16);
    if (len == null) throw FormatException('bad tracker frame length "$hex"');
    return len;
  }

  void _drop(int n) => _buf.removeRange(0, n);
}

/// Live device-list source. Primary path: subscribe to the adb server's
/// `host:track-devices-l` socket (push updates, no polling). If the socket
/// cannot be (re)established, falls back to polling `adb devices -l` every
/// 2 s while continuing to retry the socket with capped exponential backoff.
class DeviceTracker {
  final AdbService _adb;
  final int port;

  DeviceTracker(this._adb, {int? port})
      : port = port ??
            int.tryParse(
                Platform.environment['ANDROID_ADB_SERVER_PORT'] ?? '') ??
            5037;

  final _devicesCtrl = StreamController<List<AdbDevice>>.broadcast();
  final _modeCtrl = StreamController<TrackerMode>.broadcast();

  Stream<List<AdbDevice>> get devices => _devicesCtrl.stream;
  Stream<TrackerMode> get modeStream => _modeCtrl.stream;

  List<AdbDevice> _current = const [];
  List<AdbDevice> get current => _current;

  TrackerMode _mode = TrackerMode.connecting;
  TrackerMode get mode => _mode;

  Socket? _socket;
  Timer? _pollTimer;
  bool _started = false;
  bool _stopped = false;
  int _failures = 0;
  String _lastSig = '\x00';

  void start() {
    if (_started) return;
    _started = true;
    unawaited(_run());
  }

  void dispose() {
    _stopped = true;
    _socket?.destroy();
    _pollTimer?.cancel();
    _devicesCtrl.close();
    _modeCtrl.close();
  }

  Future<void> _run() async {
    while (!_stopped) {
      Socket? sock;
      try {
        // Make sure a server exists before dialing it.
        try {
          await _adb.run(['start-server'],
              timeout: const Duration(seconds: 10));
        } catch (_) {}
        sock = await Socket.connect(InternetAddress.loopbackIPv4, port,
            timeout: const Duration(seconds: 3));
        _socket = sock;
        const req = 'host:track-devices-l';
        sock.add(ascii
            .encode('${req.length.toRadixString(16).padLeft(4, '0')}$req'));
        await sock.flush();

        final parser = TrackerFrameParser();
        await for (final chunk in sock) {
          for (final event in parser.feed(chunk)) {
            switch (event) {
              case TrackerOkay():
                _failures = 0;
                _stopPolling();
                _setMode(TrackerMode.socket);
                debugPrint(
                    '[DroidDeck] tracker: connected (host:track-devices-l)');
              case TrackerFail(:final message):
                throw AdbException('tracker rejected: $message');
              case TrackerPayload(:final text):
                _emit(AdbDevice.parseList(text));
            }
          }
        }
        // Stream ended: the adb server went away.
        throw const SocketException('tracker socket closed');
      } catch (e) {
        if (_stopped) break;
        _failures++;
        debugPrint('[DroidDeck] tracker: lost ($e) — attempt #$_failures');
        if (_failures >= 3) _startPolling();
        if (_pollTimer == null) _setMode(TrackerMode.connecting);
      } finally {
        sock?.destroy();
        _socket = null;
      }
      if (_stopped) break;
      final delayMs =
          math.min(500 * (1 << math.min(_failures, 4)), 5000);
      await Future<void>.delayed(Duration(milliseconds: delayMs));
    }
  }

  void _startPolling() {
    if (_pollTimer != null || _stopped) return;
    _setMode(TrackerMode.polling);
    debugPrint('[DroidDeck] tracker: polling fallback active');
    unawaited(_pollOnce());
    _pollTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _pollOnce());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _pollOnce() async {
    try {
      _emit(await _adb.listDevices());
    } catch (_) {}
  }

  void _emit(List<AdbDevice> list) {
    if (_stopped) return;
    final sig =
        list.map((d) => '${d.serial}|${d.stateRaw}|${d.model}').join('\n');
    if (sig == _lastSig) return;
    _lastSig = sig;
    _current = list;
    final t = DateTime.now().toIso8601String().substring(11, 19);
    debugPrint('[DroidDeck $t] devices (${list.length}): '
        '${list.isEmpty ? '<none>' : list.join(', ')}');
    _devicesCtrl.add(list);
  }

  void _setMode(TrackerMode m) {
    if (_stopped || _mode == m) return;
    _mode = m;
    _modeCtrl.add(m);
  }
}
