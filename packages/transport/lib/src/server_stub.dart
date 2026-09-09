// Web records-build stub for server.dart: identical public API, every call
// throws. The web app never hosts (records only); this exists so the
// shared host driver compiles for web. Native builds use server.dart
// (dart:io + shelf). Mirror new shared-code members here or the web build
// fails loudly (by design).
library;

import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_storage/storage.dart';

Never _web() => throw UnsupportedError('records-only web build: no hosting');

class RadioSighting {
  final int rssiDbm;
  final int hop; // 0 = direct
  /// Mirrors server.dart: true when heard via a legacy v1 UUID (no
  /// direct-RSSI proof possible). Drives the verify-rule log.
  final bool legacy;
  const RadioSighting(
      {required this.rssiDbm, required this.hop, this.legacy = false});
}

/// Which sighting rule marked the proof (host log only): `direct-rssi`
/// vs `legacy-hop0-assumed`. Pure mirror of server.dart.
String sightingRuleOf(RadioSighting? sight) {
  if (sight == null) return 'no-sighting';
  if (!sight.legacy && sight.rssiDbm > kRssiDirectDbm) return 'direct-rssi';
  return 'legacy-hop0-assumed';
}

typedef SightingLookup = RadioSighting? Function({
  required Uint8List peerW,
  required String expectedAirKey,
  required String expectedUuid,
});

class WaitingEntry {
  final String email;
  final String name;
  final String roll;
  final DateTime ts;
  const WaitingEntry(
      {required this.email,
      required this.name,
      required this.roll,
      required this.ts});
}

class ManualEntry {
  final String email;
  final String name;
  final String roll;
  final DateTime ts;
  String status; // pending|approved|rejected
  ManualEntry(
      {required this.email,
      required this.name,
      required this.roll,
      required this.ts,
      this.status = 'pending'});
}

String hostBearer(Uint8List windowSecret) => _web();

String dateIsoNow() => _web();

class ProxServer {
  ProxServer({
    required String classLabel,
    required ed.PrivateKey profSk,
    required ed.PublicKey profPk,
    required SightingLookup sightings,
    TallyStore? tally,
    void Function(String email, String decision, String reason)? onProve,
    this.sessionOrg = '',
  });

  String sessionOrg;

  Duration sightingGrace = const Duration(seconds: 4);

  int get port => _web();
  String get boundAddress => _web();
  bool get windowOpen => _web();
  WindowParams? get window => _web();
  String get bearer => _web();
  int get windowNo => _web();
  int get waitingCount => _web();
  List<WaitingEntry> get waitingRows => _web();
  List<ManualEntry> get manualRows => _web();
  List<ManualEntry> get manualPending => _web();

  Future<void> start({String host = '0.0.0.0', int port = 8443}) => _web();

  void openWindow(WindowParams window, int windowNo) => _web();

  void closeWindow() => _web();

  /// Drops all session vectors from RAM NOW (mirror of server.dart —
  /// hosting teardown calls this explicitly; web never hosts).
  void clearFaceVectors() => _web();

  /// Professor override: this pair never flags again this session
  /// (mirror of server.dart; web never hosts).
  void exemptFacePair(String a, String b) => _web();

  void registerWaiting(String email, String name, [String roll = '']) =>
      _web();

  void requestManual(String email, String name, [String roll = '']) => _web();

  bool decideManual(String email, bool approve) => _web();

  Future<void> stop() => _web();
}
