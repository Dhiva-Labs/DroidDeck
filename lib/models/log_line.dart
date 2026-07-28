/// One parsed `logcat -v threadtime` line.
///
///   07-28 12:55:44.123  1234  5678 I ActivityManager: Start proc …
///
/// Lines that don't match (buffer separators like
/// "--------- beginning of main") become meta lines with a null tag.
class LogLine {
  final int seq;
  final String raw;
  final String? time;
  final int? pid;
  final int? tid;

  /// V D I W E F, or '' for meta lines.
  final String priority;
  final String? tag;
  final String? message;

  const LogLine({
    required this.seq,
    required this.raw,
    this.time,
    this.pid,
    this.tid,
    this.priority = '',
    this.tag,
    this.message,
  });

  bool get isMeta => priority.isEmpty;

  static const priorityRanks = {
    'V': 0,
    'D': 1,
    'I': 2,
    'W': 3,
    'E': 4,
    'F': 5,
  };

  int get priorityRank => priorityRanks[priority] ?? 0;

  static final _threadtime = RegExp(
      r'^(\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d{3})\s+(\d+)\s+(\d+)\s+([VDIWEF])\s+(.*?)\s*:\s?(.*)$');

  static LogLine parse(String line, int seq) {
    final m = _threadtime.firstMatch(line);
    if (m == null) return LogLine(seq: seq, raw: line);
    return LogLine(
      seq: seq,
      raw: line,
      time: m.group(1),
      pid: int.tryParse(m.group(2)!),
      tid: int.tryParse(m.group(3)!),
      priority: m.group(4)!,
      tag: m.group(5),
      message: m.group(6),
    );
  }
}
