// Proximity protocol constants — source of truth per PROXIMITY_DESIGN.md §5, §6, §12.
//
// Decisions locked (§12):
//  1. Present rule default 2/2, configurable lenient 1/2 per course.
//  2. Prefixes + UUIDs below are the allocation.
//  3. Export host-only source of truth; mirror/laptop copies are not authoritative.
library;

import 'dart:typed_data';

/// 64-bit Proximity challenge prefix. Fixed, e.g. 9A3B7C1D4E5F6071 (§5.2).
/// Built from 32-bit halves: a single >2^53 literal cannot compile to JS
/// (web records builds), while halves stay exact on 64-bit native — where
/// the radio crypto actually runs. Web never touches these (records only).
int _u64(int hi, int lo) => (hi * 0x100000000) + lo;
final int kBaseP64 = _u64(0x9A3B7C1D, 0x4E5F6071);

/// 64-bit Proximity response prefix. MUST differ from [kBaseP64].
final int kBaseS64 = _u64(0xB7E4A921, 0x5C6D8093);

/// 64-bit IP-hint prefix (legacy v1 server-address packet, Apple-safe
/// single UUID). MUST differ from [kBaseP64] and [kBaseS64].
/// Bytes read "IPHINT01".
final int kBaseI64 = _u64(0x49504849, 0x4E543031);

/// BLE advertise interval (ms). §6.1
const int kAdvIntervalMs = 200;

/// Rotation period per sub-epoch (s). Challenges rotate every 5s for as
/// long as the window is open (unbounded j); the window closes only when
/// the professor stops it. 5s bounds replay to a radio-plausible window
/// (a forwarded screenshot arrives stale) while staying cheap on BLE
/// stacks that rate-limit scan restarts — shorter costs radio churn,
/// longer widens the wormhole.
const int kSubEpochSeconds = 5;

/// Freshness acceptance: 0 <= now - t_j < 5s + 7s (one-sided; a future
/// sub-epoch is never fresh, so tokens cannot pre-play). §5.3
const Duration kFreshness = Duration(seconds: 7);

/// Direct-sighting RSSI threshold (dBm). §5.3 step 6.
const int kRssiDirectDbm = -70;

/// Relay-admission RSSI threshold (dBm). §6.2.
const int kRssiRelayMinDbm = -80;

/// Max relay hops. Originate TTL=3, dense graphs cap at 2. §6.2. Three hops
/// cover a 500-seat hall; the dense cap and the 4/s per-device relay cap
/// bound pathological resonators without touching flood correctness.
const int kTtlOriginate = 3;
const int kTtlDenseCap = 2;

/// Max relayed hop accepted as BLE sighting (flagged). §5.3 step 6.
const int kMaxRelayHop = 2;

/// LRU dedup capacity + expiry (BitChat parity). §5.3.
const int kDedupCapacity = 1000;
const Duration kDedupExpiry = Duration(minutes: 5);

/// Relay jitter window (ms): 10–220ms, wider when dense. §6.2.
const int kJitterMinMs = 10;
const int kJitterMaxMs = 220;

/// Face match threshold on the `face_verification` plugin (FaceNet TFLite)
/// scale. 0.70 = plugin default, calibrated for FAR ~0.01% / FRR <2%.
/// The old 0.60/0.80 EdgeFace-XS cosine numbers MUST NOT be reused: the
/// vendored EdgeFace pipeline is deleted (Tracks 2+3) and its embedding
/// space is incomparable with the plugin's FaceNet space.
/// Policy shape (valid window, retry counts) is unchanged — only the VALUE
/// is recalibrated to the new scale.
const double kFaceThreshold = 0.70;

/// Private-key use requires faceValid < 5 min. §4.
const Duration kFaceValidWindow = Duration(minutes: 5);

/// Face failure: 2 instant retries then needs-review. §4.
const int kFaceMaxRetries = 2;

/// Marking verify-session budget: one dead 12s session burns exactly one
/// attempt (4 sessions → needs-review → manual override, never
/// auto-present). Policy constant kept with FaceGate (threshold VALUE
/// recalibrated above; counts untouched).
const int kFaceMaxSessions = 4;

/// Inconclusive rescan cadence inside a verify session (passive only —
/// no blink/turn-head prompts; the holder just holds still).
const Duration kFaceRescanInterval = Duration(seconds: 12);

/// Verifier-version allowlist prefix. Stored `verifierVer` values look like
/// `face_verification/0.3.9+b45ab893` (plugin version + bundled-asset
/// hash8). The host accepts any version with this prefix unless a course
/// pins a stricter list (offline professor verifies against this prefix;
/// post-hoc sync flags flapping — see device_binding.dart).
const String kVerifierVerPrefix = 'face_verification/';

/// Device attestation validity: +90d from attestation, with a 14d stale
/// grace (STALE → confirmed+banner; NONE claims no tier — see the
/// `device-none-fallback` path in verify.dart).
const Duration kDeviceAttestedValidity = Duration(days: 90);
const Duration kDeviceStaleGrace = Duration(days: 14);

/// TLS pin preimage: H(PK_p || windowID). §3.3.
const int kSessionIdBytes = 16; // rand(128) per lecture
const int kWindowIdBytes = 6; // rand(48) per window
const int kWindowSecretBytes = 32; // S_w rand(256)
const int kChallengeBytes = 8; // C_j 64-bit
const int kPeerAliasBytes = 8; // peerW 8 bytes

/// Mesh PDU types.
const int kPduTypeChallenge = 0x01; // professor challenge relay (broadcast flood)
const int kPduTypeResponseFwd = 0x02; // directed response forward (GATT write)
const int kPduTypeGattFallback = 0x03; // full {windowID,j,C_j,Sig_p,TTL} read
const int kPduVersion = 0x01;

/// Rate limits (§6.3): /prove 40/10s/IP, /window 5/10s/IP.
const int kRateProveMax = 40;
const int kRateWindowMax = 5;
const Duration kRateWindow = Duration(seconds: 10);

/// Crockford base32 alphabet for 3-char display code derived from windowID.
const String kDisplayAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// Session/window byte lengths for signatures.
Uint8List u64be(int v) {
  final b = ByteData(8)..setUint64(0, v, Endian.big);
  return b.buffer.asUint8List();
}

int u64beDecode(List<int> b, [int offset = 0]) {
  if (offset < 0 || b.length < offset + 8) {
    throw FormatException('u64beDecode out of range');
  }
  return ByteData.sublistView(Uint8List.fromList(b), offset, offset + 8)
      .getUint64(0, Endian.big);
}
