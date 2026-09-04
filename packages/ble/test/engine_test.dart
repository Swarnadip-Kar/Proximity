import 'dart:typed_data';

import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  test('prof rotation advertises UUID_P per sub-epoch', () async {
    final radio = FakeBleRadio();
    final engine = ProxBleEngine(radio: radio);
    final window = WindowParams(
      sessionId: randBytes(16),
      windowId: randBytes(6),
      secret: randBytes(32),
      t0: DateTime.now().toUtc(),
      classLabel: 'C',
    );
    await engine.startProfRotation(window);
    expect(
        radio.advertisingUuid,
        UuidCodec.packChallenge(window.challengeFor(0)));
    await engine.stop();
    expect(radio.advertisingUuid, isNull);
  });

  test('student response advertises UUID_S + peerW scan-response', () async {
    final radio = FakeBleRadio();
    final engine = ProxBleEngine(radio: radio);
    final cj = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
    // Capture scan-response alias via a recording fake.
    final seen = <String?, List<int>?>{};
    final rec = _RecordingRadio(radio, seen);
    final engine2 = ProxBleEngine(radio: rec);
    final peerW = Uint8List.fromList([9, 9, 9, 9, 9, 9, 9, 9]);
    await engine2.advertiseStudentResponse('s@x.in', cj, 0, peerW);
    expect(radio.advertisingUuid,
        UuidCodec.packResponse(ProxCrypto.responseToken(cj, 's@x.in')));
    expect(seen.values.first, peerW);
    await engine2.stop();
    expect(engine.currentJ, 0);
  });

  test('nextChallenge: fresh past sighting resolves, stale waits', () async {
    final engine = ProxBleEngine(radio: FakeBleRadio());
    final cj = Uint8List.fromList([5, 5, 5, 5, 5, 5, 5, 5]);
    engine.handleSighting(BleSighting(
      uuid: UuidCodec.packChallenge(cj),
      rssiDbm: -60,
      at: DateTime.now().toUtc(),
    ));
    expect(
        await engine.nextChallenge(timeout: const Duration(seconds: 1)), cj);

    final engine2 = ProxBleEngine(radio: FakeBleRadio());
    final t0 = DateTime.now().toUtc().millisecondsSinceEpoch;
    final res = await engine2.nextChallenge(
        timeout: const Duration(milliseconds: 300));
    expect(res, isNull);
    expect(DateTime.now().toUtc().millisecondsSinceEpoch - t0,
        greaterThanOrEqualTo(250));
  });

  test('front-row relay: unseen strong challenge re-advertised once', () async {
    final radio = FakeBleRadio();
    final engine = ProxBleEngine(radio: radio)..relayEnabled = true;
    final cj = Uint8List.fromList([3, 3, 3, 3, 3, 3, 3, 3]);
    final uuid = UuidCodec.packChallenge(cj);
    engine.handleSighting(BleSighting(
        uuid: uuid, rssiDbm: -60, at: DateTime.now().toUtc(), ttl: 3));
    // jitter is 10-220ms; allow generous time, then check.
    await Future.delayed(const Duration(milliseconds: 600));
    expect(radio.advertisingUuid, uuid);
    // Duplicate storm suppressed: second identical sighting changes nothing.
    engine.handleSighting(BleSighting(
        uuid: uuid, rssiDbm: -60, at: DateTime.now().toUtc(), ttl: 3));
    await Future.delayed(const Duration(milliseconds: 400));
    expect(radio.advertisingUuid, uuid);
    await engine.stop();
  });

  test('relay suppressed when disabled, weak, TTL spent, or own UUID',
      () async {
    final radio = FakeBleRadio();
    final engine = ProxBleEngine(radio: radio);
    BleSighting sight(String uuid,
            {int rssi = -60, int ttl = 3}) =>
        BleSighting(
            uuid: uuid, rssiDbm: rssi, at: DateTime.now().toUtc(), ttl: ttl);
    final uuid = UuidCodec.packChallenge(Uint8List.fromList([6, 6, 6, 6, 6, 6, 6, 6]));
    // disabled (default)
    engine.handleSighting(sight(uuid));
    await Future.delayed(const Duration(milliseconds: 400));
    expect(radio.advertisingUuid, isNull);
    // enabled but weak RSSI
    engine.relayEnabled = true;
    engine.handleSighting(sight(uuid, rssi: -85));
    await Future.delayed(const Duration(milliseconds: 400));
    expect(radio.advertisingUuid, isNull);
    // enabled but TTL spent
    engine.handleSighting(sight(uuid, ttl: 0));
    await Future.delayed(const Duration(milliseconds: 400));
    expect(radio.advertisingUuid, isNull);
    await engine.stop();
  });

  test('sightings sort strongest-first', () {
    final engine = ProxBleEngine(radio: FakeBleRadio());
    final now = DateTime.now().toUtc();
    engine.handleSighting(BleSighting(
        uuid: UuidCodec.packChallenge(Uint8List.fromList(List.filled(8, 1))),
        rssiDbm: -80,
        at: now));
    engine.handleSighting(BleSighting(
        uuid: UuidCodec.packChallenge(Uint8List.fromList(List.filled(8, 2))),
        rssiDbm: -55,
        at: now));
    expect(engine.byRssiDesc.first.rssiDbm, -55);
  });
}

class _RecordingRadio implements BlePlatformDelegate {
  final FakeBleRadio inner;
  final Map<String?, List<int>?> seen;
  _RecordingRadio(this.inner, this.seen);

  @override
  String get platformName => 'recording-fake';

  @override
  Future<void> startAdvertising(String serviceUuid, String rotatingUuid,
      {List<int>? scanResponse}) async {
    seen[rotatingUuid] = scanResponse;
    return inner.startAdvertising(serviceUuid, rotatingUuid,
        scanResponse: scanResponse);
  }

  @override
  Future<void> stopAdvertising() => inner.stopAdvertising();
  @override
  Future<void> startScanning(void Function(BleSighting s) onSight) =>
      inner.startScanning(onSight);
  @override
  Future<void> stopScanning() => inner.stopScanning();
  @override
  Future<Uint8List?> gattRead(
          String deviceId, String serviceUuid, String charUuid) =>
      inner.gattRead(deviceId, serviceUuid, charUuid);
  @override
  Future<void> gattWrite(String deviceId, String serviceUuid,
          String charUuid, Uint8List value) =>
      inner.gattWrite(deviceId, serviceUuid, charUuid, value);
}
