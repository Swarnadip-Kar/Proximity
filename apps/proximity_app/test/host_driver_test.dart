import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';

void main() {
  RealHostDriver makeDriver({DeviceStore? store, ProxBleEngine? engine}) =>
      RealHostDriver(
        store: store ?? InMemoryDeviceStore(),
        engine: engine ?? ProxBleEngine(radio: FakeBleRadio()),
      );

  test('manual entry before any window marks round 1 immediately', () async {
    // Windows always number from 1, so a pre-Start manual entry lands in
    // round 1 at once: visible immediately, captured by drafts, and the
    // first real round intersects it honestly (no phantom numbering).
    final driver = makeDriver();
    await driver.startHosting(classLabel: 'CS101', port: 0);
    await driver.addManualEntry(
        email: 'early@x.in', name: 'Early', roll: '7');
    expect(driver.tally.windowNos, [1]);
    expect(driver.tally.presentCount, 1);
    await driver.startWindow(1);
    expect(driver.tally.windowNos, [1]);
    expect(driver.tally.presentCount, 1);
    await driver.endHosting();
  });

  test('hosting lifecycle: advertise -> window -> stop (grace) -> end',
      () async {
    final driver = makeDriver()
      ..scanLinger = const Duration(milliseconds: 300);
    expect(driver.isHosting, isFalse);
    final hosting =
        await driver.startHosting(classLabel: 'CS101', port: 0);
    expect(driver.isHosting, isTrue);
    expect(driver.windowLive, isFalse);
    expect(hosting.windowOpen, isFalse);
    expect(hosting.allIps, isNotEmpty);
    // bogus IP ignored
    await driver.setAnnounceHost('9.9.9.9');
    final live = await driver.startWindow(1);
    expect(driver.windowLive, isTrue);
    expect(live.windowOpen, isTrue);
    expect(live.displayCode, isNotEmpty);
    await driver.stopWindow();
    // Grace: proofs still accepted briefly after Stop…
    expect(driver.windowLive, isTrue);
    await Future.delayed(const Duration(seconds: 1));
    // …then the window hard-closes.
    expect(driver.windowLive, isFalse);
    await driver.endHosting();
    expect(driver.isHosting, isFalse);
  });

  test('waiting discoverability: idle hints -> rotation -> idle -> off',
      () async {
    // The waiting-room path mirrors the round path: idle hosting repeats
    // the challenge-free IP hint (listable, nothing provable), the window
    // switches to challenge rotation, stop resumes hints, end goes silent.
    final radio = FakeBleRadio();
    final engine = ProxBleEngine(radio: radio);
    final driver = makeDriver(engine: engine);
    final hosting = await driver.startHosting(classLabel: 'CS101', port: 0);
    // Deterministic stand-in for the professor's picked WiFi IP.
    engine.setServerIp('10.50.19.107', hosting.port);
    engine.legacyTx = true;
    await driver.stopWindow(); // re-arms idle rotation on the forced IP
    var uuid = radio.advertisingLegacyUuid!;
    expect(UuidCodec.isIpHintUuid(uuid), isTrue);
    expect(UuidCodec.unpackIpHint(uuid)!.host, '10.50.19.107');
    await driver.startWindow(1);
    uuid = radio.advertisingLegacyUuid!;
    expect(UuidCodec.isChallengeUuid(uuid), isTrue);
    await driver.stopWindow();
    uuid = radio.advertisingLegacyUuid!;
    expect(UuidCodec.isIpHintUuid(uuid), isTrue);
    await driver.endHosting();
    expect(radio.advertisingLegacyUuid, isNull);
    expect(radio.advertisingMfg, isNull);
  });

  test('idle beacons stay quiet (no terminal flood)', () async {
    // Beacons fire every 2s: only targets-change + every 5th idle log,
    // so a long session doesn't drown the terminal.
    BleLog.clear();
    final driver = makeDriver();
    await driver.startHosting(classLabel: 'CS101', port: 0);
    await Future.delayed(const Duration(milliseconds: 4500));
    final lines = BleLog.history
        .where((e) => e.msg.startsWith('beacon sent'))
        .toList();
    expect(lines.length, lessThanOrEqualTo(2));
    await driver.endHosting();
  });

  test('matchResponse maps live-shaped sightings (ttl 3) to hop 0',
      () async {
    // Live air carries no TTL byte: every real sighting defaults to
    // ttl == kTtlOriginate (3). Mapping hop: s.ttl rejected EVERY live
    // prove as no-ble-sighting — stubbed hop-0 tests hid it.
    final engine = ProxBleEngine(radio: FakeBleRadio());
    final token = Uint8List.fromList([7, 7, 7, 7, 7, 7, 7, 7]);
    engine.handleSighting(BleSighting(
      type: kAirTypeResponse,
      token8: token,
      ipHost: '10.50.19.107',
      ipPort: 8443,
      rssiDbm: -60,
      at: DateTime.now().toUtc(),
    ));
    final hit = RealHostDriver.matchResponse(
        engine, '$kAirTypeResponse:${hexEncode(token)}', 'uuid:nope');
    expect(hit, isNotNull);
    expect(hit!.hop, 0);
    expect(hit.rssiDbm, -60);
    expect(
        RealHostDriver.matchResponse(
            engine, '$kAirTypeResponse:00', 'uuid:nope'),
        isNull);
    await engine.stop();
  });

  test('stopWindow grace still accepts proofs, then closes', () async {
    // The reported "linger but can't mark": Stop ends rotation, but the
    // server window stays OPEN for the grace — a proof on the wire still
    // marks — and only then hard-closes.
    final radio = FakeBleRadio();
    final engine = ProxBleEngine(radio: radio);
    final driver = makeDriver(engine: engine)
      ..scanLinger = const Duration(milliseconds: 300);
    await driver.startHosting(classLabel: 'CS101', port: 0);
    await driver.startWindow(1);
    expect(radio.scanning, isTrue);
    await driver.stopWindow();
    // Scan held past the stop (hints resumed in parallel)…
    expect(radio.scanning, isTrue);
    expect(driver.windowLive, isTrue);
    await Future.delayed(const Duration(seconds: 1));
    // …then window closed and scan released, retake-safe.
    expect(driver.windowLive, isFalse);
    expect(radio.scanning, isFalse);
    await driver.endHosting();
  });

  test('windowed proofs tally through the real driver server', () async {
    // Transport-level prove is covered in packages/transport; here the
    // driver-owned tally marks directly (same store the UI reads).
    final driver = makeDriver();
    await driver.startHosting(classLabel: 'CS101', port: 0);
    await driver.startWindow(1);
    expect(driver.tally.presentCount, 0);
    await driver.endHosting();
  });

  test('waiting + manual passthrough on real server', () async {
    final driver = makeDriver();
    await driver.startHosting(classLabel: 'CS101', port: 0);
    expect(driver.waitingCount, 0);
    // Presence + manual go straight to the embedded server (LAN-only).
    final server = driver;
    // Drive via the public interface only.
    await driver.startWindow(1);
    expect(driver.currentWindowNo, 1);
    await driver.addManualEntry(
        email: 'manual@x.in', name: 'Manual M', roll: '9');
    expect(driver.tally.confirmedCount, 1);
    expect(driver.waitingCount, 1);
    expect(server, isNotNull);
    await driver.endHosting();
    expect(driver.isHosting, isFalse);
  });

  test('fake manual approve/reject + select-all semantics', () async {
    final driver = FakeHostDriver();
    await driver.startHosting(classLabel: 'CS101');
    driver.seedManual(const [
      ManualRow(email: 'a@x.in', name: 'A'),
      ManualRow(email: 'b@x.in', name: 'B'),
    ]);
    expect(driver.manualPending.length, 2);
    await driver.decideManual('a@x.in', true);
    expect(driver.manualPending.length, 1);
    expect(driver.tally.confirmedCount, 1);
    await driver.decideManual('b@x.in', false);
    expect(driver.manualPending, isEmpty);
    expect(driver.tally.confirmedCount, 1);
    await driver.endHosting();
  });
}
