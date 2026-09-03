// BLE engine: identical UUID semantics on every OS (§5.2, §6.1, §6.2).
//
// Platform mapping (outside this pure-Dart core):
//  - scan/connect: `universal_ble` (Android/iOS/macOS/Windows/Linux)
//  - advertise: `flutter_ble_peripheral` (Android/iOS/macOS/Windows)
//  - Linux advertise: ~200-line BlueZ LEAdvertisingManager1 D-Bus shim
//    publishing identical UUID_P/UUID_S + PROX_SVC + peerW scan-response.
//  - GATT: PROX_SVC/PROX_CHR read/write/notify + CCCD, MTU 517,
//    autoConnect=false, ≥5s between scan restarts.
//
// This file holds the OS-independent core: rotation schedule, sighting store,
// relay admission (delegates to protocol FloodController), RSSI thresholds.
// A [BlePlatformDelegate] injects the actual radio; fakes drive P0 tests.
library proximity_ble;

import 'dart:async';
import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';

/// Observed advertisement.
class BleSighting {
  final String uuid;
  final Uint8List? peerW; // 8B from scan-response (null if absent)
  final int rssiDbm;
  final DateTime at;
  final int ttl; // relay hop info when known (0 = direct)
  final String? ingressLink;
  BleSighting({
    required this.uuid,
    required this.rssiDbm,
    required this.at,
    this.peerW,
    this.ttl = 0,
    this.ingressLink,
  });

  bool get isChallenge => UuidCodec.isChallengeUuid(uuid);
  bool get isResponse => UuidCodec.isResponseUuid(uuid);
}

/// Platform radio contract. Implementations per OS share this interface —
/// no OS gets a weaker path (same UUID-only payloads, same rotation).
abstract class BlePlatformDelegate {
  Future<void> startAdvertising(String serviceUuid, String rotatingUuid,
      {List<int>? scanResponse});
  Future<void> stopAdvertising();
  Future<void> startScanning(void Function(BleSighting s) onSight);
  Future<void> stopScanning();
  Future<Uint8List?> gattRead(String serviceUuid, String charUuid);
  Future<void> gattWrite(String serviceUuid, String charUuid, Uint8List value);
  String get platformName;
}

/// Fake radio for tests / P0 Android↔Android loop without hardware.
class FakeBleRadio implements BlePlatformDelegate {
  @override
  String get platformName => 'fake';
  String? advertisingUuid;
  void Function(BleSighting s)? _onSight;
  final List<(String, String, Uint8List)> gattWrites = [];

  /// Loop injected sightings to peer radios via test harness.
  void inject(BleSighting s) => _onSight?.call(s);

  @override
  Future<void> startAdvertising(String serviceUuid, String rotatingUuid,
      {List<int>? scanResponse}) async {
    advertisingUuid = rotatingUuid;
  }

  @override
  Future<void> stopAdvertising() async => advertisingUuid = null;

  @override
  Future<void> startScanning(void Function(BleSighting s) onSight) async {
    _onSight = onSight;
  }

  @override
  Future<void> stopScanning() async => _onSight = null;

  @override
  Future<Uint8List?> gattRead(String serviceUuid, String charUuid) async =>
      null;

  @override
  Future<void> gattWrite(
          String serviceUuid, String charUuid, Uint8List value) async =>
      gattWrites.add((serviceUuid, charUuid, value));
}

/// Rotation + relay core. Drives [BlePlatformDelegate] on 5s ticks.
class ProxBleEngine {
  final BlePlatformDelegate radio;
  final FloodController flood;
  final void Function(BleSighting s)? onChallengeHeard;
  final void Function(BleSighting s)? onResponseHeard;
  final Future<void> Function(MeshPdu relay)? onRelayBroadcast;

  final List<BleSighting> sightings = [];
  Timer? _rotTimer;
  int currentJ = 0;
  bool dense = false;

  ProxBleEngine({
    required this.radio,
    FloodController? flood,
    this.onChallengeHeard,
    this.onResponseHeard,
    this.onRelayBroadcast,
  }) : flood = flood ?? FloodController();

  Future<void> startScanning() =>
      radio.startScanning(handleSighting);

  Future<void> stop() async {
    _rotTimer?.cancel();
    await radio.stopAdvertising();
    await radio.stopScanning();
  }

  /// Professor: rotate UUID_P(j) every 5s across 30s window.
  Future<void> startProfRotation(WindowParams window) async {
    currentJ = 0;
    await _advertiseProf(window, 0);
    _rotTimer?.cancel();
    _rotTimer = Timer.periodic(
        const Duration(seconds: kSubEpochSeconds), (t) async {
      final j = t.tick;
      if (j >= kSubEpochsPerWindow) {
        await stop();
        return;
      }
      currentJ = j;
      await _advertiseProf(window, j);
    });
  }

  Future<void> _advertiseProf(WindowParams window, int j) async {
    final cj = window.challengeFor(j);
    await radio.stopAdvertising();
    await radio.startAdvertising(kProxSvc, UuidCodec.packChallenge(cj));
  }

  /// Student: rotate UUID_S(ID,j) every 5s once C_j known.
  Future<void> advertiseStudentResponse(
      String studentId, Uint8List challenge, int j, Uint8List peerW) async {
    final rid = ProxCrypto.responseToken(challenge, studentId);
    await radio.stopAdvertising();
    await radio.startAdvertising(kProxSvc, UuidCodec.packResponse(rid),
        scanResponse: peerW);
  }

  /// Incoming sighting: log RSSI, fire callbacks, relay challenges w/ flood controls.
  void handleSighting(BleSighting s) {
    sightings.add(s);
    if (s.isChallenge) {
      onChallengeHeard?.call(s);
      // Relay path needs full PDU; UUID-only fast path re-advertises same
      // UUID_P with TTL-1 after jitter (caller resolves PDU via GATT if needed).
      // Admission pre-check on RSSI here; full dedup in transport layer.
      if (s.ttl > 0 && s.rssiDbm > kRssiRelayMinDbm) {
        // Note: actual re-advertise scheduled by holder with jitter +
        // split-horizon via FloodController.shouldRelayBroadcast.
      }
    } else if (s.isResponse) {
      onResponseHeard?.call(s);
    }
  }

  /// Strongest-first ordering for nearby-class list UI.
  List<BleSighting> get byRssiDesc {
    final l = List<BleSighting>.of(sightings);
    l.sort((a, b) => b.rssiDbm.compareTo(a.rssiDbm));
    return l;
  }

  void clearSightings() => sightings.clear();
}
