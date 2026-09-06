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
  const RadioSighting({required this.rssiDbm, required this.hop});
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
  });

  Duration sightingGrace = const Duration(seconds: 4);

  int get port => _web();
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

  void registerWaiting(String email, String name, [String roll = '']) =>
      _web();

  void requestManual(String email, String name, [String roll = '']) => _web();

  bool decideManual(String email, bool approve) => _web();

  Future<void> stop() => _web();
}
