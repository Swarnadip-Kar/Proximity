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

export 'src/bluez.dart';

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
  Future<Uint8List?> gattRead(
      String deviceId, String serviceUuid, String charUuid);
  Future<void> gattWrite(String deviceId, String serviceUuid,
      String charUuid, Uint8List value);
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
  Future<Uint8List?> gattRead(
          String deviceId, String serviceUuid, String charUuid) async =>
      null;

  @override
  Future<void> gattWrite(String deviceId, String serviceUuid,
          String charUuid, Uint8List value) async =>
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

  /// Front-row relay switch. The student driver enables it while listening;
  /// professors never relay (they originate), and it is off otherwise so
  /// re-advertising strictly extends coverage during open windows.
  bool relayEnabled = false;
  final Set<String> _relayed = {}; // UUIDs already re-advertised (storm guard)
  String? _ownAdvertising; // split-horizon: never relay what we advertise
  bool _halted = false;

  ProxBleEngine({
    required this.radio,
    FloodController? flood,
    this.onChallengeHeard,
    this.onResponseHeard,
    this.onRelayBroadcast,
  }) : flood = flood ?? FloodController();

  Future<void> startScanning() {
    _halted = false;
    return radio.startScanning(handleSighting);
  }

  Future<void> stop() async {
    _halted = true;
    _relayed.clear();
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
    final uuid = UuidCodec.packResponse(rid);
    _ownAdvertising = uuid;
    await radio.stopAdvertising();
    await radio.startAdvertising(kProxSvc, uuid, scanResponse: peerW);
  }

  /// Incoming sighting: log RSSI, fire callbacks, relay challenges w/ flood controls.
  void handleSighting(BleSighting s) {
    sightings.add(s);
    if (s.isChallenge) {
      onChallengeHeard?.call(s);
      for (final w in _challengeWaiters.toList()) {
        if (!w.isCompleted) w.complete(Uint8List.fromList(UuidCodec.lo8Of(s.uuid)));
      }
      _challengeWaiters.clear();
      unawaited(_maybeRelay(s));
    } else if (s.isResponse) {
      onResponseHeard?.call(s);
    }
  }

  /// Front-row re-advertise of professor challenges (controlled flood,
  /// §6.2): unseen UUID_P + TTL left + strong signal + jitter, never what
  /// we already advertise (split horizon), never responses (no flooding).
  /// Responses travel direct (or directed GATT write) only.
  Future<void> _maybeRelay(BleSighting s) async {
    if (!relayEnabled) return;
    final uuid = UuidCodec.normalize(s.uuid);
    if (s.ttl <= 0) return;
    if (s.rssiDbm <= kRssiRelayMinDbm) return;
    if (uuid == _ownAdvertising) return;
    if (!_relayed.add(uuid)) return; // unseen only (storm guard)
    if (_relayed.length > 64) _relayed.remove(_relayed.first);
    await Future.delayed(
        FloodController.relayJitter(dense: dense));
    if (_halted) return;
    try {
      await radio.startAdvertising(kProxSvc, uuid);
      _ownAdvertising = uuid;
    } catch (_) {}
  }

  final List<Completer<Uint8List?>> _challengeWaiters = [];

  /// Resolves with the next challenge's C_j heard over radio, or null on
  /// [timeout] (the window elapsed without signal → honest noSignal).
  /// Already-heard fresh challenges (≤7s old) resolve immediately so slow
  /// pollers never miss a rotation.
  Future<Uint8List?> nextChallenge(
      {Duration timeout = const Duration(seconds: 31)}) {
    final now = DateTime.now().toUtc();
    for (var i = sightings.length - 1; i >= 0; i--) {
      final s = sightings[i];
      if (s.isChallenge &&
          now.difference(s.at.toUtc()).abs() < kFreshness) {
        return Future.value(Uint8List.fromList(UuidCodec.lo8Of(s.uuid)));
      }
    }
    final c = Completer<Uint8List?>();
    _challengeWaiters.add(c);
    Future.delayed(timeout).then((_) {
      if (!c.isCompleted) c.complete(null);
      _challengeWaiters.remove(c);
    });
    return c.future;
  }

  /// Strongest-first ordering for nearby-class list UI.
  List<BleSighting> get byRssiDesc {
    final l = List<BleSighting>.of(sightings);
    l.sort((a, b) => b.rssiDbm.compareTo(a.rssiDbm));
    return l;
  }

  void clearSightings() => sightings.clear();
}
