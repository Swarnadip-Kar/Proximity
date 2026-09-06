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

/// Canonical POST /prove body (C_j is radio-only learned, never fetched).
/// Identity auto-attaches from the linked Gmail account. Rosterless
/// (offline-local phase): the student presents its device public key
/// ([pkS], 32B) and the professor verifies both signatures against it —
/// trust-on-first-use per class, no roster lookup. Radio freshness,
/// single-use, face score, sighting and channel binding still gate.
Map<String, dynamic> buildProveBody({
  required String id, // Gmail address (identity key, self-asserted offline)
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
  required Uint8List pkS, // student device public key, 32B
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
      'pkS': hexEncode(pkS),
    };
