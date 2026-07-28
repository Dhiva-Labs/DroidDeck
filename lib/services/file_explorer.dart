import 'dart:async';

import '../models/fs_entry.dart';
import 'adb_service.dart';

/// A running push/pull with its streamed progress lines.
/// adb writes progress as `[ 45%] path` separated by carriage returns,
/// so the stream splits on both \r and \n.
class TransferHandle {
  final Stream<String> progress;
  final Future<int> exitCode;

  const TransferHandle({required this.progress, required this.exitCode});
}

class FileExplorerService {
  final AdbService _adb;

  FileExplorerService(this._adb);

  Future<List<FsEntry>> list(String serial, String path) async {
    // Trailing slash makes toybox dereference symlink arguments (/sdcard!)
    // and list the directory contents rather than the link itself.
    final target = path.endsWith('/') ? path : '$path/';
    final r = await _adb.shell(serial, 'ls -al ${shQuote(target)}',
        timeout: const Duration(seconds: 30));
    if (!r.ok) {
      throw AdbException(r.error.isEmpty ? 'ls failed' : r.error);
    }
    return FsEntry.parseListing(r.stdout);
  }

  Future<void> mkdir(String serial, String dir, String name) async {
    final r = await _adb.shell(
        serial, 'mkdir ${shQuote(joinDevicePath(dir, name))}');
    if (!r.ok) throw AdbException('mkdir failed: ${r.error}');
  }

  Future<void> delete(String serial, String path) async {
    final r = await _adb.shell(serial, 'rm -rf ${shQuote(path)}',
        timeout: const Duration(minutes: 2));
    if (!r.ok) throw AdbException('delete failed: ${r.error}');
  }

  Future<TransferHandle> pull(
          String serial, String remotePath, String localDir) =>
      _transfer(['pull', remotePath, localDir], serial);

  Future<TransferHandle> push(
          String serial, String localPath, String remoteDir) =>
      _transfer(['push', localPath, remoteDir], serial);

  Future<TransferHandle> _transfer(List<String> args, String serial) async {
    final proc = await _adb.start(args, serial: serial);
    final ctrl = StreamController<String>.broadcast();

    void pipe(Stream<List<int>> s) {
      final buf = StringBuffer();
      s.listen((chunk) {
        for (final byte in chunk) {
          if (byte == 0x0a || byte == 0x0d) {
            final line = buf.toString().trim();
            buf.clear();
            if (line.isNotEmpty && !ctrl.isClosed) ctrl.add(line);
          } else {
            buf.writeCharCode(byte);
          }
        }
      }, onDone: () {
        final line = buf.toString().trim();
        if (line.isNotEmpty && !ctrl.isClosed) ctrl.add(line);
      });
    }

    pipe(proc.stdout);
    pipe(proc.stderr);
    final exit = proc.exitCode.whenComplete(() {
      Future<void>.delayed(
          const Duration(milliseconds: 200), () => ctrl.close());
    });
    return TransferHandle(progress: ctrl.stream, exitCode: exit);
  }
}
