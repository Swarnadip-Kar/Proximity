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
  final String org; // prof org domain, '' = legacy/unknown
  const ClassBeacon({
    required this.classLabel,
    required this.host,
    required this.port,
    required this.rssiDbm,
    required this.displayCode,
    this.org = '',
  });
}

/// Canonical POST /prove body (C_j is radio-only learned, never fetched).
/// Identity auto-attaches from the linked Gmail account. Rosterless
/// (offline-local phase): the student presents its device public key
/// ([pkS], 32B) and the professor verifies both signatures against it —
/// trust-on-first-use per class, no roster lookup. Radio freshness,
/// single-use, face score, sighting and channel binding still gate.
///
/// Tracks 2+3: the face ticket rides as `face:{score,faceValidAt,
/// verifierVer}` (millis UTC + pipeline tag — no images/embeddings leave
/// the device) with Sig_s binding pkD+ticketHash; device binding rides as
/// `pkD` (hex) + `dSig` (hex over deviceProvePreimage, integrity-bound —
/// see `integrityHash`). All four are optional so legacy bodies still
/// encode (server applies the legacy path); bound clients always send
/// them.
///
/// Security §5 integrity binding: `integrityFlag` ('' |
/// `'integrity-flagged'`, advisory — the professor flags, never
/// auto-absent) rides alongside `integrityHash` (the 8-hex verdict hash
/// the HW key SIGNED inside dSig). The server recomputes the dSig
/// preimage with the claimed hash and requires it well-formed on every
/// dSig-gated (FULL/STD) proof — pre-binding clients omit it and fail
/// closed as device-unproven, never a silent downgrade.
///
/// Security §2 (sec-hwkey): HW-bound proofs also carry
/// `attestationChain` (list<string> DER-hex, leaf-first — the same wire
/// form as `StoredEnrollment.chainDERHex` / Firestore `attestationChain`)
/// plus `installId` (the app UUID the enrollment challenge binds:
/// SHA256(email || installId || pkS)). The professor recomputes the
/// challenge from (ID, installId, pkS) and pins the chain offline; absent
/// chain/installId on a FULL/STD claim fails closed as device-unproven
/// (legacy NONE proofs omit both and take the fallback path).
///
/// Local dup path: bound clients also attach `face:{vec}` — ONE base64
/// int8 mean embedding (684 chars, protocol faceVecEncode) over this SAME
/// local HTTPS channel. The professor's phone holds it in RAM for the open
/// window only and exact-compares it against the session's other vectors.
/// Optional like the rest: proofs without it mark normally with no dup
/// participation.
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
  String org = '', // student org domain (join-gate, not crypto)
  int? faceValidAtMs, // ticket stamp (bound path)
  String verifierVer = '', // pipeline tag (bound path)
  Uint8List? pkD, // device-key public bytes (bound path)
  Uint8List? dSig, // device-key signature (bound path)
  String attestationLevel = 'NONE', // DKey attestation claim (bound path)
  int attestedUntilMs = 0, // attestation window end (bound path)
  String faceVecB64 = '', // LAN-only session vector (local dup path)
  // Security §4 liveness ticket (classifier output only, no images).
  double livenessScore = 0.0,
  String livenessVer = '',
  // Security §5 integrity flag ('' | 'integrity-flagged'). Advisory.
  String integrityFlag = '',
  // Security §5 verdict hash (8-hex) bound into the SIGNED dSig preimage.
  // Empty = pre-binding client (server fails those closed on HW tiers).
  String integrityHash = '',
  // Security §2 HW attestation (bound FULL/STD path; omitted on legacy).
  List<String> attestationChain = const [],
  String installId = '',
  // iOS App Attest artifacts (hex; '' on Android / legacy): the enrollment
  // CBOR raw (object or assertion) + credential key. The professor iOS
  // branch parses them (app_attest.dart); absent = Android-shaped gate.
  String appAttestRaw = '',
  String appAttestCredKey = '',
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
      'org': org,
      if (faceValidAtMs != null || verifierVer.isNotEmpty || faceVecB64.isNotEmpty)
        'face': {
          'score': faceScore,
          'faceValidAt': faceValidAtMs ?? 0,
          'verifierVer': verifierVer,
          if (faceVecB64.isNotEmpty) 'vec': faceVecB64,
        },
      if (pkD != null && pkD.isNotEmpty) 'pkD': hexEncode(pkD),
      if (dSig != null && dSig.isNotEmpty) 'dSig': hexEncode(dSig),
      if (faceValidAtMs != null || verifierVer.isNotEmpty)
        'att': {
          'level': attestationLevel,
          'until': attestedUntilMs,
        },
      if (livenessVer.isNotEmpty || livenessScore != 0.0)
        'liveness': {
          'score': livenessScore,
          'ver': livenessVer,
        },
      if (integrityFlag.isNotEmpty) 'integrityFlag': integrityFlag,
      if (integrityHash.isNotEmpty) 'integrityHash': integrityHash,
      if (attestationChain.isNotEmpty)
        'attestationChain': List<String>.of(attestationChain),
      if (installId.isNotEmpty) 'installId': installId,
      if (appAttestRaw.trim().isNotEmpty)
        'appAttestRaw': appAttestRaw.trim().toLowerCase(),
      if (appAttestCredKey.trim().isNotEmpty)
        'appAttestCredKey': appAttestCredKey.trim().toLowerCase(),
    };
