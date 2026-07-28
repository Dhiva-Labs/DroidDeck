import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import 'adb_service.dart';

const _utf8Lenient = Utf8Decoder(allowMalformed: true);

/// Owns one interactive `adb shell` session running in a real pseudo-
/// terminal, for one device. The [xterm.Terminal] is created and owned here
/// (not by the page) so its scrollback survives widget rebuilds; the page
/// only mounts a `TerminalView` over it.
///
/// Only [running]/[error]/[exitCode] transitions call [notifyListeners] —
/// terminal text updates flow straight into the xterm [Terminal], which
/// TerminalView already listens to internally, so routing every output
/// chunk through this ChangeNotifier too would just double the rebuilds.
class TerminalSession extends ChangeNotifier {
  final AdbService _adb;
  final String? serial;

  TerminalSession(this._adb, this.serial) {
    terminal = Terminal(maxLines: 10000)
      ..onOutput = _onTerminalOutput
      ..onResize = _onTerminalResize;
  }

  late final Terminal terminal;

  Pty? _pty;
  StreamSubscription<String>? _sub;
  bool _disposed = false;

  bool running = false;
  int? exitCode;
  String? error;

  /// Starts (or, if already running, does nothing) the shell for [serial].
  void start() {
    final s = serial;
    if (s == null || running) return;
    final path = _adb.adbPath;
    if (path == null) {
      error = 'adb is not available';
      notifyListeners();
      return;
    }
    error = null;
    exitCode = null;
    try {
      final pty = Pty.start(
        path,
        arguments: ['-s', s, 'shell'],
        environment: sanitizedEnv(),
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );
      _pty = pty;
      running = true;
      // Pty.output is Stream<Uint8List>, one dart:typed_data notch narrower
      // than the Stream<List<int>> Utf8Decoder expects as a transformer —
      // .cast keeps chunked decoding (multi-byte sequences split across
      // reads) correct without hand-rolling the buffering ourselves.
      _sub = pty.output
          .cast<List<int>>()
          .transform(_utf8Lenient)
          .listen(terminal.write);
      unawaited(pty.exitCode.then(_onExit));
      notifyListeners();
    } catch (e) {
      error = 'could not start shell: $e';
      running = false;
      notifyListeners();
    }
  }

  /// Kills the current shell (if any) and starts a fresh one.
  void restart() {
    terminal.write('\r\n\x1b[33m[restarting shell]\x1b[0m\r\n');
    _teardown();
    start();
  }

  void _onTerminalOutput(String data) {
    _pty?.write(Uint8List.fromList(utf8.encode(data)));
  }

  void _onTerminalResize(int width, int height, int pixelWidth, int pixelHeight) {
    _pty?.resize(height, width);
  }

  void _onExit(int code) {
    if (_disposed) return;
    running = false;
    exitCode = code;
    terminal.write('\r\n\x1b[31m[exited (code $code)]\x1b[0m\r\n');
    notifyListeners();
  }

  void _teardown() {
    _sub?.cancel();
    _sub = null;
    _pty?.kill(ProcessSignal.sigkill);
    _pty = null;
    running = false;
  }

  @override
  void dispose() {
    _disposed = true;
    _teardown();
    super.dispose();
  }
}
