// Transport: shelf server/client shapes, mDNS/manual join, TLS pinning,
// rate limits. (§6.3) Pure-Dart core; shelf wiring lands in P2.
library proximity_transport;

import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';

export 'package:proximity_protocol/protocol.dart'
    show ProveDecision, RateLimiter, proveLimiter, windowLimiter;

/// Discovered class beacon (mDNS `_proximity._tcp` or manual IP type-in).
class ClassBeacon {
  final String classLabel;
  final String host; // IP or mDNS name
  final int port;
  final int rssiDbm;
  final String displayCode;
  ClassBeacon({
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

/// TLS pin check: student pins H(PK_p || windowID) after verifying Cert_p.
/// No external CA needed (self-signed, §3.3).
bool checkTlsPin({
  required Uint8List profPub32,
  required Uint8List windowId,
  required Uint8List presentedPin,
}) {
  final pin = ProxCrypto.tlsPin(profPub32, windowId);
  if (pin.length != presentedPin.length) return false;
  var acc = 0;
  for (var i = 0; i < pin.length; i++) {
    acc |= pin[i] ^ presentedPin[i];
  }
  return acc == 0;
}

/// POST /prove body builder (C_j is radio-only learned, never from /epoch).
/// Identity auto-attaches: email (+ optional unverified roll) from the
/// linked Gmail account — the student types nothing in class.
Map<String, dynamic> buildProveBody({
  required String id, // Gmail address (identity key)
  required Uint8List windowId,
  required int j,
  required Uint8List challenge,
  required Uint8List sigS,
  required double faceScore,
  required Uint8List peerW,
  String roll = '',
}) =>
    {
      'ID': id,
      'windowID': hexEncode(windowId),
      'j': j,
      'C_j': hexEncode(challenge),
      'Sig_s': hexEncode(sigS),
      'faceScore': faceScore,
      'peerW': hexEncode(peerW),
      'roll': roll,
    };
