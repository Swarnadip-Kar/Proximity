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

  test('PROX_LOG_CONSOLE flag overrides the build default', () {
    // Unset: debug/test echoes, release stays silent.
    expect(BleLog.consoleEchoFor(flag: '', productBuild: false), isTrue);
    expect(BleLog.consoleEchoFor(flag: '', productBuild: true), isFalse);
    // Explicit true-ish forces echo even on release builds.
    for (final f in ['true', 'TRUE', ' 1 ', 'yes', 'on']) {
      expect(BleLog.consoleEchoFor(flag: f, productBuild: true), isTrue,
          reason: f);
    }
    // Explicit false-ish forces silence even on debug builds.
    for (final f in ['false', 'FALSE', ' 0 ', 'no', 'off']) {
      expect(BleLog.consoleEchoFor(flag: f, productBuild: false), isFalse,
          reason: f);
    }
    // Unknown values fall back to the build default (never crash).
    expect(BleLog.consoleEchoFor(flag: 'maybe', productBuild: true), isFalse);
    expect(BleLog.consoleEchoFor(flag: 'maybe', productBuild: false), isTrue);
  });
}
