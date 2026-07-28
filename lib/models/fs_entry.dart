/// One entry of a toybox `ls -al` listing.
class FsEntry {
  final String name;
  final String perms;
  final String owner;
  final String group;
  final int? size;
  final String? modified; // "2026-07-28 12:00"
  final String? linkTarget;

  const FsEntry({
    required this.name,
    required this.perms,
    this.owner = '',
    this.group = '',
    this.size,
    this.modified,
    this.linkTarget,
  });

  bool get isDir => perms.startsWith('d');
  bool get isLink => perms.startsWith('l');
  bool get isHidden => name.startsWith('.');

  /// Matches toybox/busybox `ls -al` lines:
  ///   drwxrwx--t  2 root sdcard_rw    4096 2026-07-01 10:00 Alarms
  ///   crw-rw-rw-  1 root root    1,   3 2026-01-01 00:00 null
  ///   lrwxrwxrwx  1 root root      21 2009-01-01 00:00 sdcard -> /storage/self/primary
  /// Permissions may carry a trailing SELinux/ACL marker (. or +).
  static final _line = RegExp(
      r'^([\-dlcbspD][rwxsStT\-]{9}[.+]?)\s+\d+\s+(\S+)\s+(\S+)\s+'
      r'(?:(\d+)|\d+,\s*\d+)\s+'
      r'(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})\s(.*)$');

  static FsEntry? parseLine(String line) {
    final t = line.trimRight();
    if (t.isEmpty || t.startsWith('total ')) return null;
    final m = _line.firstMatch(t);
    if (m == null) return null;
    var name = m.group(6)!;
    String? target;
    final perms = m.group(1)!;
    if (perms.startsWith('l')) {
      final arrow = name.indexOf(' -> ');
      if (arrow > 0) {
        target = name.substring(arrow + 4);
        name = name.substring(0, arrow);
      }
    }
    if (name == '.' || name == '..') return null;
    return FsEntry(
      name: name,
      perms: perms,
      owner: m.group(2)!,
      group: m.group(3)!,
      size: m.group(4) == null ? null : int.tryParse(m.group(4)!),
      modified: m.group(5),
      linkTarget: target,
    );
  }

  static List<FsEntry> parseListing(String output) {
    final entries = output
        .split('\n')
        .map(parseLine)
        .whereType<FsEntry>()
        .toList();
    entries.sort((a, b) {
      final aDir = a.isDir || a.isLink;
      final bDir = b.isDir || b.isLink;
      if (aDir != bDir) return aDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }
}

/// Joins a directory and a child name into a device path.
String joinDevicePath(String dir, String name) =>
    dir == '/' ? '/$name' : '$dir/$name';

/// Parent of a device path ('/' stays '/').
String parentDevicePath(String path) {
  if (path == '/' || !path.contains('/')) return '/';
  final cut = path.substring(0, path.lastIndexOf('/'));
  return cut.isEmpty ? '/' : cut;
}

String humanSize(int? bytes) {
  if (bytes == null) return '';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var u = -1;
  do {
    v /= 1024;
    u++;
  } while (v >= 1024 && u < units.length - 1);
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[u]}';
}
