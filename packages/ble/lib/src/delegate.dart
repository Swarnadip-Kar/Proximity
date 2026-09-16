// Platform radio contract + fake radio for tests.
//
// Split from ble.dart (M4 radio slim). GATT (`gattRead`/`gattWrite` +
// `FakeBleRadio.gattWrites`) was deleted here in the same pass: a repo-wide
// grep showed zero production callers (declarations + overrides only, no
// test references either), so the interface is now advertise/scan only.
library;

import 'dart:async';
import 'dart:typed_data';

import 'sighting.dart';

/// Platform radio contract. Implementations per OS share this interface.
/// v2 air packets go through [startAirPacket] (fixed 16-bit [kAirSvc] +
/// 18B manufacturer payload, 29B primary packet everywhere). Legacy v1
/// single-UUID packets (challenge in UUID low bytes, Apple-TX compatible)
/// go through [startLegacyUuid]. Students parse both; relays preserve the
/// heard format so mixed fleets interoperate.
abstract class BlePlatformDelegate {
  Future<void> startAirPacket(String airServiceUuid, Uint8List airMfg,
      {List<int>? scanResponse});
  Future<void> startLegacyUuid(String uuid128);
  Future<void> stopAdvertising();
  Future<void> startScanning(void Function(BleSighting s) onSight);
  Future<void> stopScanning();
  String get platformName;
}

/// Fake radio for tests / P0 Android↔Android loop without hardware.
class FakeBleRadio implements BlePlatformDelegate {
  @override
  String get platformName => 'fake';
  String? advertisingSvc;
  Uint8List? advertisingMfg;
  String? advertisingLegacyUuid;
  void Function(BleSighting s)? _onSight;

  /// Test aid: whether a scan callback is currently armed.
  bool get scanning => _onSight != null;

  /// Loop injected sightings to peer radios via test harness.
  void inject(BleSighting s) => _onSight?.call(s);

  @override
  Future<void> startAirPacket(String airServiceUuid, Uint8List airMfg,
      {List<int>? scanResponse}) async {
    advertisingSvc = airServiceUuid;
    advertisingMfg = airMfg;
    advertisingLegacyUuid = null;
  }

  @override
  Future<void> startLegacyUuid(String uuid128) async {
    advertisingLegacyUuid = uuid128;
    advertisingSvc = null;
    advertisingMfg = null;
  }

  @override
  Future<void> stopAdvertising() async {
    advertisingSvc = null;
    advertisingMfg = null;
    advertisingLegacyUuid = null;
  }

  @override
  Future<void> startScanning(void Function(BleSighting s) onSight) async {
    _onSight = onSight;
  }

  @override
  Future<void> stopScanning() async => _onSight = null;
}
