// BleLog console mirror: release-safe default, ring/stream always live.
import 'dart:async';

import 'package:proximity_ble/src/ble_log.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() {
    BleLog.clear();
    BleLog.echoToConsole = !bool.fromEnvironment('dart.vm.product');
  });

  test('default mirrors in test env (product is false here)', () {
    expect(BleLog.echoToConsole, isTrue);
  });

  test('log() always records + broadcasts, print only when echoing',
      () async {
    final seen = <BleLogEntry>[];
    final sub = BleLog.stream.listen(seen.add);
    final prints = <String>[];
    BleLog.echoToConsole = true;
    await runZoned(() async {
      BleLog.log('SEC', 'echo on');
    }, zoneSpecification:
        ZoneSpecification(print: (self, parent, zone, line) {
      prints.add(line);
    }));
    expect(prints, ['[SEC] echo on']);
    BleLog.echoToConsole = false;
    await runZoned(() async {
      BleLog.log('SEC', 'echo off');
    }, zoneSpecification:
        ZoneSpecification(print: (self, parent, zone, line) {
      prints.add(line);
    }));
    expect(prints, hasLength(1)); // nothing more printed
    await sub.cancel();
    expect(BleLog.history.map((e) => e.msg), ['echo on', 'echo off']);
    expect(seen.map((e) => e.msg), ['echo on', 'echo off']);
  });

  test('ring stays bounded', () {
    BleLog.echoToConsole = false;
    for (var i = 0; i < BleLog.cap + 10; i++) {
      BleLog.log('T', 'm$i');
    }
    expect(BleLog.history, hasLength(BleLog.cap));
  });
}
