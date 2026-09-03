# Proximity — Campus Attendance System
## Final Design Document

**Version:** 1.0 Final
**Scope:** Cross-platform Flutter (Android + iOS student/prof, macOS + Windows + Linux prof), offline-first, 30–500 students per lecture.
**Auth:** Institute ID + Institute Gmail only.
**Attendance model:** 2 foreground windows per lecture (start + mid-class), 30 seconds each.

---

## 1. Goals

1. Professor starts attendance from phone or laptop in the classroom, with explicit foreground action.
2. Students prove physical presence with their own phones in a 30-second window.
3. One phone cannot mark proxy for another person. One screenshot or forwarded code cannot mark proxy from hostel.
4. Professor ends the lecture with a signed attendance list on their own device.
5. Works fully offline on campus WiFi or phone hotspot. Internet required only once at enrollment.
6. Identical flow and identical security level on every device and OS.

Non-goals: background auto-marking, perfect anti-wormhole against a dedicated real-time accomplice pair (requires UWB distance bounding, not available on all phones), central cloud attendance DB.

---

## 2. System overview

```
ONCE ONLINE (internet):
  Admin roster {ID, Gmail, Name, Role}
  Student/Prof: Google Sign-In (institute domain) + claim ID
    -> roster[ID].gmail must equal OAuth email
    -> generate Ed25519 keypair in secure hardware
    -> face enrollment on-device
    -> upload {ID, public key}
  All devices cache signed roster + revocation list before class.

IN CLASS OFFLINE (no internet):
  Prof host (Android / iOS / macOS / Windows / Linux, foreground):
    BLE advertiser (rotating service UUID) +
    GATT server (same service) +
    HTTPS server (WiFi) +
    Dashboard + SQLite store
         |  BLE radio (proximity proof)  |  WiFi HTTPS (transport)  |
  Student phones (Android / iOS, foreground):
    BLE scanner + BLE advertiser + face check + HTTPS client
```

Why this split: WiFi on campus is routed across buildings. Reachability over WiFi proves nothing about room presence. Bluetooth LE range (≈10–30 m) proves nearness. Identity + holder proofs ride on top via signatures + face. WiFi carries bulk data because it has bandwidth; BLE carries short unpredictable secrets because it has range limits.

For a 500-seat hall a single BLE advertiser cannot reach the back row directly through bodies. Students in front re-advertise the professor's challenge with controlled flood (copied from BitChat mesh, §7). This extends coverage to the whole hall without extra hardware.

---

## 3. Identity and enrollment

### 3.1 Roster source of truth

Admin imports per semester:

```
roster.csv: ID, Gmail, Name, Role(student/prof)
```

Example: `12342210, aarav.12342210@institute.ac.in, Aarav S, student`.

Built into `roster.json` and signed with institute key `SK_inst`. Apps verify `Sig_inst` offline. Revocation list `crl.json` holds revoked public keys (lost phone, re-enroll).

### 3.2 Enrollment (online, ~2 min, once)

1. `Sign in with Google`, restricted to institute domain. Obtain `idToken {email, name}`.
2. Enter `ID`. App checks `roster[ID].gmail == oauth.email`. Mismatch rejects. This binds ID to Gmail without passwords.
3. Generate `Ed25519 (SK, PK)`:
   - Android: `Keystore / StrongBox`, `biometricRequired=true`, non-exportable.
   - iOS: `Secure Enclave`, `biometryAny`, non-exportable.
   - Desktop (prof): OS keychain-backed key (Keychain / Credential Manager / libsecret), file-encrypted at rest.
   - One device per ID per semester.
4. Face enrollment on-device (§4).
5. Upload `{ID, PK, faceHash=H(embedding), modelVer} + Sign(SK) + idToken`. Server verifies OAuth + roster match + signature, adds to `rosterKeys.json`.

Professor enrollment is identical plus `role=prof` check. Professor receives `Cert_p = Sign(SK_inst, PK_p || ID || Gmail)`.

Before class the professor downloads `roster.json + rosterKeys.json + crl.json`. No network calls happen during attendance.

### 3.3 In-class authentication (offline)

- Student to professor: `Sign(SK_s, ...)` + `ID`. Professor looks up `PK_s = rosterKeys[ID]`, checks not revoked, verifies signature.
- Professor to student: `Cert_p + Sign(SK_p, ...)` over session descriptor. Student verifies against cached `PK_inst`. Blocks Evil-Twin access point.
- TLS: professor HTTPS uses self-signed cert with hash `H(PK_p || windowID)`. Student pins after verifying `Cert_p`. No external CA needed.

---

## 4. Face binding

Purpose: the key proves the phone, BLE proves the phone's location, face proves the holder. Lending an unlocked phone fails.

Pipeline (identical both mobile OS):

```
camera frame -> face detect -> crop/align -> embedding -> cosine vs enrollment template -> liveness
```

- Detection: `google_mlkit_face_detection` (Android) / Vision `VNDetectFaceRectangles` (iOS).
- Recognition model: `EdgeFace-XS` (~1.8 MB, LFW 99.72%), shipped as TFLite (Android) and CoreML `.mlpackage` (iOS, ANE-accelerated). 20–40 ms per inference.
- Template stored encrypted on-device only (Keystore-wrapped AES-GCM). Server never receives photos. Server receives `{matchScore, livenessPass}` inside signed payload.
- Threshold: cosine `0.60` starting point, tuned in pilot for FAR ~0.01% / FRR <2%.
- Liveness: passive texture plus active prompt derived from challenge (`C_j[0] & 1 ? blink : turn-head`), verified on-device in <2 s. Pre-recorded video cannot predict the prompt.
- Gating: private-key use requires `faceValid < 5 min`. Signing API throws otherwise. Each 30 s window demands a fresh check (~1 s oval UI).
- Failure: 2 instant retries, then `needs-review` queue. Professor verifies the person in the room and applies a logged manual override. Never auto-present on face fail.

---

## 5. Cryptography specification

Package: `packages/protocol` (pure Dart, no platform code). Primitives via `cryptography` + `ed25519_edwards`: `Ed25519`, `HMAC-SHA256`, `HKDF-SHA256`, `SHA-256`, `CSPRNG`.

### 5.1 Per-window secrets (professor, never leaves host)

```
sessionID  = rand(128) per lecture
windowID   = rand(48) per attendance window (3-char display code derived from it)
S_w        = rand(256) per window
j          = 0..5 sub-epoch index (5 s each, 6 per 30 s window)
C_j        = HMAC-SHA256(S_w, windowID || j)[0:8]        // 64-bit rolling secret
A_j        = HMAC-SHA256(S_w, "auth" || j)[0:8]
R_IDj      = HMAC-SHA256(C_j, ID)[0:8]                   // per-student response token
peerW(ID)  = HMAC-SHA256(PK_s, windowID)[0:8]            // rotating over-air alias
Sig_p(j)   = Sign(SK_p, sessionID || windowID || j || C_j)
Sig_s      = Sign(SK_s, sessionID || windowID || j || C_j || ID || faceScore)
```

### 5.2 Over-air encoding (UUID-only, universal)

To keep every OS on the identical code path, all BLE proximity bytes travel as 128-bit service UUIDs (the one advertise payload supported on Android, iOS, macOS, Windows, and Linux via BlueZ D-Bus shim). No manufacturer data is used.

```
BaseP64 = fixed 64-bit Proximity challenge prefix (e.g. 9A3B7C1D4E5F6071)
BaseS64 = fixed 64-bit Proximity response prefix (different constant)
UUID_P(j) = BaseP64 || C_j                 // professor challenge, rotating every 5 s
UUID_S(ID,j) = BaseS64 || R_IDj            // student response, rotating every 5 s
```

Fixed service UUID `PROX_SVC` is always advertised alongside for scan filtering. Rotating UUID carries the secret. Scan-response carries `peerW(ID)` (8 bytes) so the professor can map radio sightings to roster entries without stable MACs and without linkability across lectures.

GATT service `PROX_SVC` with characteristic `PROX_CHR` (read/write/notify + CCCD) exposes the full `{windowID, j, C_j, Sig_p(j), TTL}` for fallback reads when advertisements collide.

Binary packet header for any relayed Mesh PDU (copied from BitChat framing):

```
ver(1) | type(1) | TTL(1) | ts(4) | flags(1) | sender8 | payload | Ed25519-64
```

Signatures exclude the TTL byte so relays can decrement it without invalidating the signature. Payload length is fixed and tiny (no fragmentation needed in the common case; 469-byte fragment path retained for GATT fallback).

### 5.3 Verification (professor, per POST + per BLE sighting)

```
1. window open? |now - t_j| < 7 s (5 s + drift), (ID, j) unseen -> else late/invalid
2. C_j == expected for (windowID, j)          // proves live radio hear
3. UUID_S == BaseS64 || HMAC(C_j, ID)[0:8]    // proves radio response heard
4. Verify(PK_s[ID], Sig_s), PK in rosterKeys, not in CRL
5. faceScore >= threshold and fresh
6. BLE sighting exists: direct RSSI > -70 dBm, or relayed hop <= 2 (flagged)
7. Mark ID present for W, update live counts, return signed ACK
```

Deduplication: LRU seen-set (1000 entries, 5-min expiry) keyed `sender + ts + type + digest`, identical to BitChat dedup.

---

## 6. BLE + WiFi transport

### 6.1 Advertise / scan parameters

- Advertise interval 200 ms, connectable, TxPower Low (`-12 dBm` small room, `-6 dBm` large hall).
- Scan: foreground continuous, filter `PROX_SVC`, in-app prefix check `BaseP/BaseS`, RSSI logged per sighting.
- Rotation: stop/start advertise every 5 s to publish next `UUID_P(j)` / `UUID_S`.
- MTU 517 negotiated before any GATT read/write. `autoConnect=false` for fast fallback connects. Minimum 5 s between scan restarts (Android scanner rate-limit guard).

### 6.2 Mesh relay (challenge distribution, students help)

Back rows cannot hear the professor directly. Front-row phones re-advertise what they heard, with BitChat flood controls:

- Only professor challenge PDUs are relayed. Student responses are direct (or directed-forwarded, below).
- Rules: if `TTL > 0`, unseen, `RSSI > -80 dBm`, wait `jitter 10–220 ms` (wider when dense), re-advertise same `UUID_P` with `TTL-1`, never back to ingress link (split horizon). Originate `TTL=3`, dense graphs cap at 2. LRU-dedup suppresses storms. Fanout is implicit in radio (one re-advertise reaches all nearby).
- Response relay (rare, AP-isolated corners): if a student hears a neighbor `UUID_S` with hop < 2 and the professor is GATT-connected, forward via directed GATT write with `TTL-1` and tight jitter. Never broadcast-flood responses.
- Presence: while window is open all devices advertise/scan continuously (30 s burst, no duty cycling needed). Reachability timeout 60 s covers the full window plus tally.

This is the BitChat controlled flood reduced to the minimum needed for a lecture hall: 3 hops max, 30 s lifetime, tiny fixed payloads, authority still centralized.

### 6.3 WiFi HTTPS (bulk transport)

Professor runs embedded `shelf` server (phone or laptop, foreground) + mDNS `_proximity._tcp` + manual IP display with type-in join. Endpoints:

```
GET  /window               -> {class, sessionID, windowID, j_now, PK_p, Cert_p, Sig_p}
GET  /epoch/j              -> {Sig_p(j)} (no C_j; C_j is radio-only)
POST /prove {ID,windowID,j,C_j,Sig_s,faceScore,peerW} -> {confirmed|late|invalid, serverTime, Sig_pAck}
GET  /live                 -> counts + rows (professor Bearer)
GET  /export               -> attendance.csv + .sig (professor Bearer)
```

Rate limits: `/prove` 40/10 s/IP, `/window` 5/10 s/IP. TLS pinned as in §3.3. If campus AP isolates clients, professor phone hotspot is the documented fallback (same protocol, same code).

---

## 7. Flows

### 7.1 Professor flow (identical on phone and laptop)

1. Open Proximity prof app, foreground, plugged in where possible. Confirm Bluetooth + WiFi + location prompts (one-time onboarding screens).
2. Enter class label (e.g. `CS201-Room301`). App shows radio tier `HIGH` and current IP for student join.
3. Tap **Start Attendance #1** at lecture start. App:
   - generates `S_w`, starts 30 s timer,
   - starts BLE advertise (`UUID_P` rotation) + GATT server + HTTPS server + BLE scan,
   - shows LIVE `00:23  214/480 present`, plus `pending / face-flag / late` lists with search by ID.
4. At 30 s auto-close. Tally persisted to SQLite. Leave app open.
5. Mid-lecture tap **Start Attendance #2**. Same 30 s flow with fresh `S_w`.
6. Tap **End + Export**. Download/share `attendance-<date>-<class>.csv` plus detached `Sign(SK_p, H(csv))` for audit. Phone and laptop exports are byte-identical formats; whichever hosted is source of truth for that lecture.

Present rule (default): `Present = pass W1 AND W2`, else `Partial`/`Absent`. Configurable to `1/2` lenient per course.

### 7.2 Student flow (identical Android/iOS)

1. Install once, enroll once online (§3.2).
2. In class, open app, keep in foreground. Tap nearby class (mDNS-discovered, strongest RSSI first) or type shown IP.
3. Face oval (~1 s). App holds `faceValid`.
4. During the 30 s window the phone automatically, with no further taps:
   - scans `UUID_P(j)`, extracts `C_j`,
   - advertises `UUID_S(ID,j)`,
   - relays challenge if front-row (invisible to user),
   - POSTs `Sig_s` with jittered retry (up to 3 attempts),
   - shows progress `Listening 00:18`, then `✓ Attendance #1 Marked (KQ7 · 10:04:12)` on signed ACK.
5. Idle until window #2, repeat face + auto-prove. Keep app open; backgrounding pauses proving and is shown as `Paused — reopen`.

### 7.3 Why this flow works

- **Hostel join fails:** attacker on campus WiFi elsewhere can fetch `/window` but never hears `UUID_P(j)` over radio (30 m limit, 5 s rotation). Without `C_j` they cannot build a valid `UUID_S` or `Sig_s` for the current sub-epoch. A screenshot forwarded after 5 s is already stale.
- **Lent phone fails:** holder's face does not match enrollment template, `SK_s` stays locked, no signature is produced. Two retries then flagged for in-person check.
- **Copied ID fails:** signatures verify against the enrolled `PK_s` for that ID. Attacker's phone holds a different key (or none), verification fails.
- **Fake professor fails:** student verifies `Cert_p + Sig_p(j)` against pinned institute key before signing. Rogue AP cannot forge professor signatures.
- **Replay fails:** `(ID, j)` single-use plus 7 s freshness window plus LRU dedup. Replayed POST or re-advertised UUID is marked late/invalid.
- **Back-row works:** controlled-flood relay brings the challenge to every seat within 2–3 hops; WiFi POSTs need no relay; BLE response sightings tolerate one relay hop with flag.
- **Equal everywhere:** every device advertises/scans UUIDs only, verifies the same signatures, runs the same face gate and timing. No OS gets a weaker path.

Residual risk (stated): two colluding phones with continuous real-time radio relay across two full windows plus live victim face on the remote end could still wormhole within 5 s. Cost is a dedicated accomplice present for the whole lecture plus low-latency link, far above casual proxy. UWB distance bounding would close it once available on all phones.

---

## 8. Flutter implementation details

Monorepo:

```
apps/student_app/        // Android + iOS
apps/prof_host_app/      // Android + iOS + macOS + Windows + Linux (same Dart)
packages/protocol/       // pure Dart: IDs, HMAC/UUID pack, sign/verify, window timer, dedup LRU
packages/ble/            // advertise/scan/GATT/relay engine (platform channels inside)
packages/face/           // detection + embedding + liveness + SK gate
packages/transport/      // shelf server/client, mDNS, TLS pinning, rate limits
packages/storage/        // SQLite (prof tally) + secure storage (keys/templates)
```

Key packages: `universal_ble` (scan/connect all incl. Linux/Win), `flutter_ble_peripheral` (advertise Android/iOS/macOS/Windows) + ~200-line BlueZ `LEAdvertisingManager1` D-Bus shim for Linux peripheral parity, `shelf` + `shelf_io`, `multicast_dns` / `nsd`, `cryptography` + `ed25519_edwards`, `camera`, `google_mlkit_face_detection` (Android) / Vision+CoreML (iOS), `tflite_flutter`, `flutter_secure_storage`, `local_auth`, `permission_handler`, `riverpod`, `sqlite3`/`drift`.

Permissions: Android `BLUETOOTH_SCAN/ADVERTISE/CONNECT + FINE_LOCATION + NEARBY_WIFI + CAMERA`; iOS `NSBluetoothAlwaysUsageDescription + NSCameraUsageDescription + NSLocalNetworkUsageDescription + NSLocationWhenInUseUsageDescription + UIBackgroundModes[bluetooth-central, bluetooth-peripheral] + Bonjour `_proximity._tcp` + wifi-info entitlement (SSID check only)`; Desktop Bluetooth capability + snap `bluez` plug on Linux. Privacy manifest discloses face-on-device processing. Foreground is mandatory during windows on all OS (Android foreground service with notification; iOS `idleTimerDisabled=true` + keep-open banner).

---

## 9. Scale, robustness, testing

- Load: 500 POSTs/30 s (~17/s) + 500 UUID advertisers + 6 rotations. Ed25519 verify total ~1000–2500 per lecture, well under 1 s on phone/laptop. Jitter 0–2 s plus server `Retry-After` spreads herd. BLE capture requires 1/6 sub-epochs seen per student, not all.
- Collisions: 200 ms adv interval + continuous scan + GATT-read fallback on CRC fail. Field-tune TxPower and `-70 dBm` direct / `-80 dBm` relay thresholds per hall with `nRF Connect` walk-test.
- Clock drift: 7 s acceptance covers typical phone drift; professor is time authority (signed `serverTime` in ACK).
- MAC rotation: neutralized by rotating `peerW` in scan response + roster-side HMAC lookup (500 HMACs per sighting batch, trivial).
- Tests: golden vectors (HMAC/UUID pack/Ed25519 RFC8032), dedup/flood unit tests, two-phone relay test, 30-room pilot (tune face + RSSI), 150-hall, 500-hall load + adversarial drill (forwarded code, off-site VPN, lent phone, photo spoof, dual-phone wormhole attempt). Ship only when wormhole needs active accomplice across both windows.

---

## 10. Research notes (BitChat mesh, applied)

BitChat (permissionlesstech/bitchat, whitepaper v2.0 Jul 2026; `bitchat-android` mesh docs) demonstrates offline BLE at scale: dual-role GATT central+peripheral on one service/characteristic UUID, 8-byte peer ID in scan response for MAC-rotation stability, MTU 517, `autoConnect=false`, TTL-7 controlled flood with dense-cap 5 / thin-full, LRU dedup (1000/5 min, sender+ts+type+digest), jitter 10–220 ms, fanout `~log2(degree)`, split horizon, directed TTL-1, 469-byte fragments, 4 s→15–30 s announces with 60 s reachability, Noise XX live + Noise X seals, spray-and-wait couriers, GCS gossip sync. Proximity reuses the transport mechanics (dual-role, scan-response alias, TTL/jitter/dedup/split-horizon, MTU/GATT fallback, permission onboarding) while replacing chat semantics with professor-signed windows, rotating unlinkable aliases (fixing BitChat §8 stable-ID linkability), and WiFi bulk transport suited to a lecture hall instead of Nostr/couriers.

---

## 11. Build phases

- **P0 Core loop (1–2 wk):** protocol package + Android↔Android 30 s window (BLE UUID + POST + ACK + CSV export).
- **P1 Parity + holder (2 wk):** iOS student parity, face gate + SK lock, TLS pinning, CRL/revoke, desktop host + Linux shim.
- **P2 Hall hardening (1–2 wk):** mesh relay + GATT fallback + hotspot fallback + mDNS/manual join + 500-hall pilot + adversarial tests.

## 12. Decisions to lock

1. Present rule default `2/2` vs `1/2` lenient per course.
2. `BaseP64/BaseS64` prefix allocation + `PROX_SVC/PROX_CHR` UUID assignment.
3. Export allowed from mirror/laptop copy or host-only source of truth.
