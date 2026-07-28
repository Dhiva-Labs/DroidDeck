import 'package:droid_deck/models/log_line.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a threadtime line', () {
    final l = LogLine.parse(
        '07-28 12:55:44.123  1234  5678 I ActivityManager: Start proc 999',
        7);
    expect(l.seq, 7);
    expect(l.time, '07-28 12:55:44.123');
    expect(l.pid, 1234);
    expect(l.tid, 5678);
    expect(l.priority, 'I');
    expect(l.tag, 'ActivityManager');
    expect(l.message, 'Start proc 999');
    expect(l.isMeta, isFalse);
    expect(l.priorityRank, 2);
  });

  test('parses padded tag and empty message', () {
    final l = LogLine.parse(
        '07-28 00:00:01.000   100   200 W audio_hw_generic : ', 0);
    expect(l.priority, 'W');
    expect(l.tag, 'audio_hw_generic');
    expect(l.message, '');
  });

  test('buffer separators become meta lines', () {
    final l = LogLine.parse('--------- beginning of main', 0);
    expect(l.isMeta, isTrue);
    expect(l.raw, '--------- beginning of main');
    expect(l.priorityRank, 0);
  });

  test('priority ranks are ordered', () {
    expect(
        ['V', 'D', 'I', 'W', 'E', 'F']
            .map((p) => LogLine.priorityRanks[p]!)
            .toList(),
        [0, 1, 2, 3, 4, 5]);
  });
}
