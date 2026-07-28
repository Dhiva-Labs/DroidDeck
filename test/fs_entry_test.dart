import 'package:droid_deck/models/fs_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a plain directory line', () {
    final e = FsEntry.parseLine(
        'drwxrwx--t 2 root sdcard_rw 4096 2026-07-01 10:00 Alarms');
    expect(e!.name, 'Alarms');
    expect(e.isDir, isTrue);
    expect(e.owner, 'root');
    expect(e.group, 'sdcard_rw');
    expect(e.size, 4096);
    expect(e.modified, '2026-07-01 10:00');
  });

  test('parses file names with spaces', () {
    final e = FsEntry.parseLine(
        '-rw-rw---- 1 u0_a123 media_rw 1234567 2026-07-28 12:00 My file with spaces.mp3');
    expect(e!.name, 'My file with spaces.mp3');
    expect(e.isDir, isFalse);
    expect(e.size, 1234567);
  });

  test('parses symlinks with target', () {
    final e = FsEntry.parseLine(
        'lrwxrwxrwx 1 root root 21 2009-01-01 00:00 sdcard -> /storage/self/primary');
    expect(e!.name, 'sdcard');
    expect(e.isLink, isTrue);
    expect(e.linkTarget, '/storage/self/primary');
  });

  test('parses character/block device sizes (major, minor)', () {
    final c = FsEntry.parseLine(
        'crw-rw-rw- 1 root root 1,   3 2026-01-01 00:00 null');
    expect(c!.name, 'null');
    expect(c.size, isNull);
    final b = FsEntry.parseLine(
        'brw------- 1 root root 253, 0 2026-01-01 00:00 dm-0');
    expect(b!.name, 'dm-0');
  });

  test('tolerates SELinux/ACL markers after permissions', () {
    final e = FsEntry.parseLine(
        '-rw-r--r--. 1 root root 0 2026-01-01 00:00 ctx-file');
    expect(e!.name, 'ctx-file');
    final f = FsEntry.parseLine(
        '-rw-r--r--+ 1 root root 9 2026-01-01 00:00 acl-file');
    expect(f!.name, 'acl-file');
  });

  test('skips total, dot entries and junk', () {
    const listing = '''
total 64
drwxr-xr-x 2 root root 4096 2026-07-01 10:00 .
drwxr-xr-x 9 root root 4096 2026-07-01 10:00 ..
drwxr-xr-x 2 root root 4096 2026-07-01 10:00 Download
-rw-r--r-- 1 root root 12 2026-07-01 10:00 zz.txt
-rw-r--r-- 1 root root 12 2026-07-01 10:00 .hidden
''';
    final list = FsEntry.parseListing(listing);
    expect(list.map((e) => e.name).toList(), ['Download', '.hidden', 'zz.txt']);
    expect(list.first.isDir, isTrue); // dir-first sort
  });

  test('path helpers', () {
    expect(joinDevicePath('/', 'sdcard'), '/sdcard');
    expect(joinDevicePath('/sdcard', 'Download'), '/sdcard/Download');
    expect(parentDevicePath('/sdcard/Download'), '/sdcard');
    expect(parentDevicePath('/sdcard'), '/');
    expect(parentDevicePath('/'), '/');
    expect(humanSize(512), '512 B');
    expect(humanSize(2048), '2.0 KB');
    expect(humanSize(1234567), '1.2 MB');
  });
}
