// Transport core: beacons, TLS-pin check, canonical POST body. §6.3.
library;

import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';

/// Discovered class beacon (mDNS `_proximity._tcp` or manual IP type-in).
class ClassBeacon {
  final String classLabel;
  final String host; // IP or mDNS name
  final int port;
  final int rssiDbm;
  final String displayCode;
  const ClassBeacon({
    required this.classLabel,
    required this.host,
    required this.port,
    required this.rssiDbm,
    required this.displayCode,
  });
}

/// Strongest-RSSI-first ordering for student nearby-class list.
List<ClassBeacon> sortBeaconsByRssi(List<ClassBeacon> beacons) {
  final l = List<ClassBeacon>.of(beacons);
  l.sort((a, b) => b.rssiDbm.compareTo(a.rssiDbm));
  return l;
}

/// Constant-time pin comparison helper.
bool checkTlsPin({
  required Uint8List expected,
  required Uint8List presented,
}) =>
    bytesEqual(expected, presented);

/// Canonical POST /prove body (C_j is radio-only learned, never from /epoch).
/// Identity auto-attaches from the linked Gmail account.
Map<String, dynamic> buildProveBody({
  required String id, // Gmail address (identity key)
  required Uint8List windowId,
  required int j,
  required Uint8List challenge,
  required Uint8List sigS,
  required double faceScore,
  required Uint8List peerW,
  String name = '',
  String roll = '',
  required Uint8List tlsFp,
  required Uint8List sigBind,
}) =>
    {
      'ID': id,
      'windowID': hexEncode(windowId),
      'j': j,
      'C_j': hexEncode(challenge),
      'Sig_s': hexEncode(sigS),
      'faceScore': faceScore,
      'peerW': hexEncode(peerW),
      'name': name,
      'roll': roll,
      'tlsFp': hexEncode(tlsFp),
      'sigBind': hexEncode(sigBind),
    };
