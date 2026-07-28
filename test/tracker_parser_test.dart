import 'dart:convert';

import 'package:droid_deck/services/device_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> enc(String s) => ascii.encode(s);

List<int> frame(String payload) =>
    enc(payload.length.toRadixString(16).padLeft(4, '0') + payload);

void main() {
  test('OKAY followed by one payload in a single chunk', () {
    final p = TrackerFrameParser();
    final events =
        p.feed([...enc('OKAY'), ...frame('emulator-5554\tdevice\n')]);
    expect(events, hasLength(2));
    expect(events[0], isA<TrackerOkay>());
    expect((events[1] as TrackerPayload).text, 'emulator-5554\tdevice\n');
  });

  test('frames split across arbitrary chunk boundaries', () {
    final p = TrackerFrameParser();
    final whole = [...enc('OKAY'), ...frame('emulator-5554\tdevice\n')];
    final all = <TrackerEvent>[];
    // Feed one byte at a time — worst-case TCP fragmentation.
    for (final b in whole) {
      all.addAll(p.feed([b]));
    }
    expect(all, hasLength(2));
    expect((all[1] as TrackerPayload).text, 'emulator-5554\tdevice\n');
  });

  test('multiple payload frames coalesced into one chunk', () {
    final p = TrackerFrameParser();
    final events = p.feed([
      ...enc('OKAY'),
      ...frame(''),
      ...frame('a\tdevice\n'),
      ...frame('a\tdevice\nb\toffline\n'),
    ]);
    expect(events, hasLength(4));
    expect((events[1] as TrackerPayload).text, isEmpty);
    expect((events[3] as TrackerPayload).text, contains('offline'));
  });

  test('empty payload (no devices) parses as empty string', () {
    final p = TrackerFrameParser();
    final events = p.feed([...enc('OKAY'), ...enc('0000')]);
    expect(events, hasLength(2));
    expect((events[1] as TrackerPayload).text, isEmpty);
  });

  test('FAIL carries its message', () {
    final p = TrackerFrameParser();
    final events = p.feed([...enc('FAIL'), ...frame('unknown host service')]);
    expect(events, hasLength(1));
    expect((events[0] as TrackerFail).message, 'unknown host service');
  });

  test('garbage status throws', () {
    final p = TrackerFrameParser();
    expect(() => p.feed(enc('WHAT')), throwsFormatException);
  });

  test('long-format payload round-trips through AdbDevice parsing', () {
    final p = TrackerFrameParser();
    const payload =
        'emulator-5554          device product:sdk_gphone16k_x86_64 '
        'model:sdk_gphone16k_x86_64 device:emu64xa16k transport_id:1\n';
    final events = p.feed([...enc('OKAY'), ...frame(payload)]);
    expect(events, hasLength(2));
  });
}
