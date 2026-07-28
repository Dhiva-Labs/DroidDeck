import 'package:droid_deck/models/adb_device.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a full emulator line', () {
    final d = AdbDevice.parseLine(
        'emulator-5554          device product:sdk_gphone64_x86_64 '
        'model:sdk_gphone64_x86_64 device:emu64xa transport_id:1');
    expect(d, isNotNull);
    expect(d!.serial, 'emulator-5554');
    expect(d.state, DeviceState.device);
    expect(d.model, 'sdk_gphone64_x86_64');
    expect(d.deviceCode, 'emu64xa');
    expect(d.transportId, '1');
    expect(d.isEmulator, isTrue);
    expect(d.isWireless, isFalse);
  });

  test('parses unauthorized device without kv pairs', () {
    final d = AdbDevice.parseLine('R58M12ABCDE\tunauthorized');
    expect(d!.serial, 'R58M12ABCDE');
    expect(d.state, DeviceState.unauthorized);
    expect(d.model, isNull);
    expect(d.displayName, 'R58M12ABCDE');
  });

  test('parses no-permissions state with spaces', () {
    final d = AdbDevice.parseLine(
        '1234567\tno permissions (missing udev rules); see [http://developer.android.com]');
    expect(d!.serial, '1234567');
    expect(d.state, DeviceState.noPermissions);
  });

  test('parses wireless serial', () {
    final d = AdbDevice.parseLine(
        '192.168.1.42:5555      device product:lynx model:Pixel_7a device:lynx transport_id:4');
    expect(d!.isWireless, isTrue);
    expect(d.displayName, 'Pixel 7a');
  });

  test('skips headers, daemon notices and blanks', () {
    const output = '''
* daemon not running; starting now at tcp:5037
* daemon started successfully
List of devices attached
emulator-5554\tdevice product:p model:m device:d transport_id:1

''';
    final list = AdbDevice.parseList(output);
    expect(list, hasLength(1));
    expect(list.single.serial, 'emulator-5554');
  });

  test('parseList of empty output is empty', () {
    expect(AdbDevice.parseList('List of devices attached\n'), isEmpty);
  });
}
