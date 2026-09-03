// Proximity protocol constants — source of truth per PROXIMITY_DESIGN.md §5, §6, §12.
//
// Decisions locked (§12):
//  1. Present rule default 2/2, configurable lenient 1/2 per course.
//  2. Prefixes + UUIDs below are the allocation.
//  3. Export host-only source of truth; mirror/laptop copies are not authoritative.
library;

import 'dart:typed_data';

/// 64-bit Proximity challenge prefix. Fixed, e.g. 9A3B7C1D4E5F6071 (§5.2).
const int kBaseP64 = 0x9A3B7C1D4E5F6071;

/// 64-bit Proximity response prefix. MUST differ from [kBaseP64].
const int kBaseS64 = 0xB7E4A9215C6D8093;

/// Fixed BLE service UUID advertised alongside rotating UUIDs for scan filtering.
const String kProxSvc = '6b9e4f22-1c9a-4f8e-9d3a-2b5c7d8e9f01';

/// GATT characteristic UUID exposing {windowID, j, C_j, Sig_p(j), TTL} fallback.
const String kProxChr = '6b9e4f23-1c9a-4f8e-9d3a-2b5c7d8e9f01';

/// BLE advertise interval (ms). §6.1
const int kAdvIntervalMs = 200;

/// Rotation period per sub-epoch (s). 6 × 5s = 30s window.
const int kSubEpochSeconds = 5;

/// Sub-epochs per 30s window.
const int kSubEpochsPerWindow = 6;

/// Full attendance window (s).
const int kWindowSeconds = 30;

/// Freshness acceptance: |now - t_j| < 7s (5s + drift). §5.3
const Duration kFreshness = Duration(seconds: 7);

/// Direct-sighting RSSI threshold (dBm). §5.3 step 6.
const int kRssiDirectDbm = -70;

/// Relay-admission RSSI threshold (dBm). §6.2.
const int kRssiRelayMinDbm = -80;

/// Max relay hops. Originate TTL=3, dense graphs cap at 2. §6.2.
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

/// MTU negotiated before GATT read/write. §6.1.
const int kBleMtu = 517;

/// GATT fallback fragment size. §5.2 / §10.
const int kGattFragmentSize = 469;

/// Reachability timeout covering window + tally. §6.2.
const Duration kReachabilityTimeout = Duration(seconds: 60);

/// Minimum seconds between Android scan restarts (rate-limit guard). §6.1.
const int kMinScanRestartSeconds = 5;

/// Face cosine threshold starting point. §4.
const double kFaceThreshold = 0.60;

/// Private-key use requires faceValid < 5 min. §4.
const Duration kFaceValidWindow = Duration(minutes: 5);

/// Face failure: 2 instant retries then needs-review. §4.
const int kFaceMaxRetries = 2;

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
  return ByteData.sublistView(Uint8List.fromList(b), offset, offset + 8)
      .getUint64(0, Endian.big);
}
