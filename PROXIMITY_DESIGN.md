# Proximity — Campus Attendance System
## Final Design Document

**Version:** 2.0 as-built (superset of the 1.0 design below — the
radio/crypto mechanics in §5–§6 are unchanged).
**Scope:** One Flutter app — student + professor modes on Android, iOS,
macOS, Windows, Linux — plus a records-only web build. Offline-first,
30–500 students per lecture.
**Auth:** Google sign-in (any Gmail this phase; institute-domain forcing is
a dormant one-line option).
**Attendance model:** foreground windows per lecture (open until the
professor stops them); present = intersection over all windows taken.

> As-built deltas vs the 1.0 text: no admin roster, no institute PKI, no
> CRL — enrollment is an online device claim (one student device per Gmail,
> one Gmail per install), proofs verify against presented device keys
> (TOFU per class), attendance is the local per-course union, export is
> unsigned from the course page, TLS trust is per-session channel binding.
> Sections below marked “as built” describe the shipped behavior; the
> radio/crypto mechanics (§5–§6) apply unchanged.

---

## 1. Goals

1. Professor starts attendance from phone or laptop in the classroom, with explicit foreground action.
2. Students prove physical presence with their own phones in an open window (no countdown).
3. One phone cannot mark proxy for another person. One screenshot or forwarded code cannot mark proxy from hostel.
4. Professor ends the lecture with an attendance list on their own device, exportable per session and per date range.
5. Works fully offline on campus WiFi or phone hotspot. Internet required only once at enrollment (and for cloud sync).
6. Identical flow and identical security level on every device and OS. The web build is records-viewing only (same login, no marking).

Non-goals: background auto-marking, perfect anti-wormhole against a dedicated real-time accomplice pair (requires UWB distance bounding, not available on all phones), central cloud attendance DB.

---

## 2. System overview

```
ONCE ONLINE (internet):
  Student/Prof: Google Sign-In
    -> generate Ed25519 keypair in secure storage
    -> face enrollment on-device
    -> atomic device claim {Gmail, public key, installId}
  Professors sync course sessions to the cloud (backup + multi-device).

IN CLASS OFFLINE (no internet):
  Prof host (Android / iOS / macOS / Windows / Linux, foreground):
    BLE advertiser (rotating challenge) +
    HTTPS server (WiFi) +
    Dashboard + on-device history
         |  BLE radio (proximity proof)  |  WiFi HTTPS (transport)  |
  Student phones (Android / iOS, foreground):
    BLE scanner + BLE advertiser + face check + HTTPS client
```

Why this split: WiFi on campus is routed across buildings. Reachability over WiFi proves nothing about room presence. Bluetooth LE range (≈10–30 m) proves nearness. Identity + holder proofs ride on top via signatures + face. WiFi carries bulk data because it has bandwidth; BLE carries short unpredictable secrets because it has range limits.

For a 500-seat hall a single BLE advertiser cannot reach the back row directly through bodies. Students in front re-advertise the professor's challenge with controlled flood (copied from BitChat mesh, §7). This extends coverage to the whole hall without extra hardware.

---

## 3. Identity and enrollment (as built — no roster, no institute PKI)

### 3.1 No roster source of truth

There is no admin roster. Identity is the Google account itself; the ID
number is compulsory but unverified display metadata. Attendance never
consults a key list: whoever proves presence over radio lands in the
per-course union, verified under the presented device key (TOFU per
class). Revocation = the weekly device-move bound (a new phone enrolls at
most once per 7 days); manual attendance covers any gap.

### 3.2 Enrollment (online, ~2 min, once)

1. `Sign in with Google` (landing). Obtain `idToken {email, name}`. The
   enrollment page needs no second tap: it adopts the persisted session
   in the background at start (token refreshed when online for live
   status); the button remains only for fresh installs with no session.
2. Register roles on the same Gmail: professor (display name, any number
   of devices), student (one enrolled device per Gmail), or both. The app
   opens on the last-used mode.
3. Generate `Ed25519 (SK, PK)`:
   - Android: Keystore/StrongBox-backed secure storage.
   - iOS: Secure Enclave-backed secure storage.
   - Desktop (prof): OS keychain-backed secure storage.
   - Status: hardware biometric binding still pending (FaceGate logic
     enforced, keys in secure storage).
   - The install is the device identity: an app-install UUID in secure
     storage (clones/dual-apps get their own).
4. Face enrollment on-device (§4).
5. Atomic claim `{Gmail, PK, installId, name, roll, modelVer}` in one
   Firestore transaction (`studentDevices/{email}` + `deviceInstalls/
   {installId}` + a `studentDirectory` search row). Same-install re-keys
   are free; moves to a different install need a 7-day cooldown
   (unlimited moves, ≤1/week, exact re-enroll date shown; no reset
   exists); an install enrolled as another Gmail hard-refuses. Every
   claim and online re-sign-in heartbeats last-online. (Web records builds
   skip the device gate: no key lives there, sign-in lands on records.)

Professor cloud sync is session backup (offline-first, local history
stays source of truth), not key distribution.

### 3.3 In-class authentication (offline, as built)

- Student to professor: `Sign(SK_s, ...)` + Gmail. Professor verifies
  against the presented `PK_s` (TOFU per class, no roster lookup).
- Professor to student: `Sign(SK_p, ...)` over the session descriptor,
  verified against the live window fetch (rotation-tolerant). Blocks
  Evil-Twin access points.
- TLS: per-hosting-session runtime cert; MITM resistance via channel
  binding (`tlsFp` + `sigBind` over the presented cert) verified
  server-side. No external CA needed.

---

## 4. Face binding

Purpose: the key proves the phone, BLE proves the phone's location, face proves the holder. Lending an unlocked phone fails.

Pipeline (identical both mobile OS):

```
camera frame -> BlazeFace detect (+6 keypoints) -> geometric sanity ->
lighting + sharpness gates -> pose zone (guided angles) ->
similarity align (112×112 canonical) -> embedding -> cosine vs enrollment
template (holder exactly still)
```

- Detection: BlazeFace short-range TFLite (224KB, Apache-2.0), identical on
  every OS — one model, one code path, no OS plugin divergence.
- Alignment: least-squares similarity from eyes/nose/mouth keypoints to the
  ArcFace canonical template (replaces naive center-crop).
- Recognition model: `EdgeFace-XS` γ=0.6 (1.77M params, LFW 99.73%), shipped as
  TFLite float32 (7.1 MB) at `apps/proximity_app/assets/models/edgeface_xs.tflite`
  and wired via `EdgeFaceEmbedder` on every OS (identical stack);
  CoreML `.mlpackage` export for iOS ANE acceleration is still open
  (TFLite serves iOS for now). 20–40 ms per inference.
- Template stored encrypted on-device only (Keystore-wrapped AES-GCM). Server never receives photos. Server receives `{matchScore, livenessPass}` inside signed payload.
- Threshold: cosine `0.60`. Measured 2026-09-05 on public portraits through
  the shipped pipeline (BlazeFace + similarity warp + EdgeFace-XS TFLite):
  same person 0.80, strangers −0.05/+0.04 — wide margin around the gate.
  Re-tune in pilot for FAR ~0.01% / FRR <2%.
- Pipeline versioning: embeddings carry `modelVer` (`kFacePipelineVer`);
  any stage change (model, decode, warp, preprocessing) bumps it and stale
  on-device templates force face recapture (key kept) instead of matching
  against incomparable vectors. Never match across versions.
- Liveness: passive only, by explicit trade-off. Still-frame blink/gaze
  gates were tried and removed: sparse ~1s-spaced stills cannot reliably
  catch 200ms blinks (blocked legit users), and any eye-motion heuristic
  either false-rejects or is trivially weak. Current posture: geometric
  sanity + sharpness + stillness make opportunistic photo fraud hard;
  mismatch budget (4 mismatch sessions, then needs-review;
  `FaceGate` instant-retry cap `kFaceMaxRetries=2`),
  server-side 0.60 gate, and pipeline versioning sit behind — but a
  good-quality printed photo CAN pass, stated plainly, plus the
  challenge-bound prompt. If photo fraud appears in the pilot, the fix is
  video-stream liveness (30fps) or a spoof-classifier model, not another
  stills heuristic.
- Stillness: no head turns anywhere in the flow — motion blur and pose
  spread tank genuine similarity (measured), while still frames match at
  ~0.95. Sharpness gate (`kMinSharpness`) rejects streaked mush early with
  a "brace the phone" prompt instead of a confusing mismatch. The scan
  preview is the stock camera view at its true ratio (tight layout
  constraints squash the texture — always wrap it loose) with a thin oval
  framing marker drawn inside the preview itself (outline only: no
  dimming, glow, or filtering).
- Guided enrollment: one tap, one camera page, five slight angles (Centre /
  Left / Right / Top / Bottom, ~10–20° — head near-frontal throughout)
  with live pair scores (each angle clears 0.70, shown with what's
  remaining) and a progress bar. Yaw zones gate all slots plus pitch
  gates for Top/Bottom (`face_detect.dart`; pitched embeddings foreshorten
  under the similarity warp, so Top/Bottom stay out of the hold-out mean
  and are validated by their own 0.70 within-slot pair + the 0.35 global
  floor). Template = mean of
  all five slot means; within-angle agreement ≥ 0.70, cross-angle odd-ones-out at
  0.35, centre hold-out at 0.50 against the mean of the Left+Right slots
  (symmetric yaw cancels toward frontal; cross-pose same-person reads
  0.50–0.57 measured, strangers ~0.0). Finalize failures drop ONLY the
  worst slot for a targeted rescan (never a whole-set wipe), and the
  camera stays open across rounds until the requested angles clear
  (bounded: 3 fruitless rounds surface the retry offer; Cancel always
  exits with completed sections — a camera exit means success or the
  holder's own Cancel).
- Marking: a 12s verify session at fast cadence — every accepted still is
  checked live with score feedback and a countdown, any one pass pops at
  once; a dead session pops its failures together and burns exactly one
  attempt. Auto-retries twice on empty rounds and auto-relaunches twice
  on unreadable verdicts (Cancel always exits, never burns). Attempts
  burn on readable mismatches only — poor frames fail closed as
  inconclusive (the embedder enforces the same quality gates, so garbage
  can never score into a mismatch).
- Gating: private-key use requires `faceValid < 5 min`. Signing API throws otherwise. Each 30 s window demands a fresh check (~1 s oval UI).
- Failure: 4 mismatch sessions on confident mismatch only (unreadable frames
  rescan free), then `needs-review` queue. Professor verifies the person in
  the room and applies a logged manual override. Never auto-present on face fail.

---

## 5. Cryptography specification

Package: `packages/protocol` (pure Dart, no platform code). Primitives via `crypto` + `ed25519_edwards`: `Ed25519`, `HMAC-SHA256`, `SHA-256`, `CSPRNG`.

### 5.1 Per-window secrets (professor, never leaves host)

```
sessionID  = rand(128) per lecture
windowID   = rand(48) per attendance window (3-char display code derived from it)
S_w        = rand(256) per window
j          = 0,1,2… sub-epoch index (5 s each, unbounded — the window stays
             open until the professor stops it; j encodes as u32 BE)
C_j        = HMAC-SHA256(S_w, windowID || j32)[0:8]  // 64-bit rolling secret
R_IDj      = HMAC-SHA256(C_j, ID)[0:8]               // per-student response token
peerW(ID)  = HMAC-SHA256(PK_s, windowID)[0:8]        // rotating over-air alias
Sig_p(j)   = Sign(SK_p, sessionID || windowID || j32 || C_j)
Sig_s      = Sign(SK_s, sessionID || windowID || j32 || C_j || ID || faceScore)
```

### 5.2 Over-air encoding (as built: dual-format v2 + legacy v1)

As built (see README §6–7 and `packages/protocol/lib/src/air.dart`): the air
packet is v2 `FCD2` + 18 B manufacturer payload (`PX 02`, type, token8,
IPv4, port — 29 B in the PRIMARY advertisement, no scan-response
dependence). Android/Linux originate v2; Apple/Windows originate legacy v1
single-UUID ticks alternating challenge and server-address hint UUIDs
(`BaseI64` + IPv4 + port), so Apple-originated classes stay joinable with
zero taps despite Apple stacks displacing attached manufacturer data out
of the primary packet. Students parse all formats; relays preserve the
heard format. Scanning is unfiltered with in-app parsing (`AirParser`).
The 1.0 UUID-only text below (fixed `PROX_SVC` filter, `peerW` in
scan-response, GATT `PROX_SVC`/`PROX_CHR` fallback) is superseded: the old
`PROX_SVC`/`PROX_CHR` GATT UUIDs are deleted and discovery is UDP + BLE
hint (see §6.3).

```
BaseP64 = fixed 64-bit Proximity challenge prefix (e.g. 9A3B7C1D4E5F6071)
BaseS64 = fixed 64-bit Proximity response prefix (different constant)
UUID_P(j) = BaseP64 || C_j                 // professor challenge, rotating every 5 s
UUID_S(ID,j) = BaseS64 || R_IDj            // student response, rotating every 5 s
```

Fixed service UUID `PROX_SVC` is always advertised alongside for scan filtering. Rotating UUID carries the secret. Scan-response carries `peerW(ID)` (8 bytes) so the professor can map radio sightings to class entries without stable MACs and without linkability across lectures.

GATT service `PROX_SVC` with characteristic `PROX_CHR` (read/write/notify + CCCD) exposes the full `{windowID, j, C_j, Sig_p(j), TTL}` for fallback reads when advertisements collide.

Binary packet header for any relayed Mesh PDU (copied from BitChat framing):

```
ver(1) | type(1) | TTL(1) | ts(4) | flags(1) | sender8 | payload | Ed25519-64
```

Signatures exclude the TTL byte so relays can decrement it without invalidating the signature. Payload length is fixed and tiny (no fragmentation needed in the common case; 469-byte fragment path retained for GATT fallback).

### 5.3 Verification (professor, per POST + per BLE sighting)

```
1. window open? 0 <= now - t_j < 12 s (5 s rotation + 7 s drift, one-sided:
   future sub-epochs never verify — no pre-play), (windowID, ID, j) unseen
   -> else late/invalid
2. C_j == expected for (windowID, j)          // proves live radio hear
3. UUID_S == BaseS64 || HMAC(C_j, ID)[0:8]    // proves radio response heard
4. Verify(PK_s presented device key, Sig_s)   // TOFU per class, no roster
5. faceScore >= threshold (holder freshness enforced on-device by the
   SK-use gate; server faceValidAt is POST arrival — defense in depth)
6. BLE sighting exists: direct RSSI > -70 dBm, or relayed hop <= 2 (flagged);
   crypto-valid but not-yet-seen waits the sighting grace, then verdicts late
7. Mark ID present for W (late verdicts mark flagged-late — late-only rounds
   persist), update live counts, return signed ACK binding the DECISION INSTANT
```

Rotation tolerance: `/window` ships `sigP_prev` alongside `sigP`, so a fetch
landing just after the 5 s tick still verifies the heard token (either `j`
verifies; only neither-matching is a genuine mismatch). Single-use is scoped
`(windowId, ID, j)` so retakes never false-replay. Deduplication: LRU
seen-set (1000 entries, 5-min expiry) keyed `sender + ts + type + digest`,
identical to BitChat dedup.

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
- Implementation (verified live 2026-09): every student relays — browsing,
  waiting, face-capture and listening phases all forward (bitchat-style:
  each node re-advertises heard challenges under flood control), with a
  20 s linger after first hear; professors originate only and their
  disarmed steady state logs nothing. The air packet (v2,
  `packages/protocol/lib/src/air.dart`) is fixed `FCD2` + 18 B manufacturer payload (`PX`,
  ver `02`, type, token8, IPv4, port — 29 B in the PRIMARY advertisement,
  no scan-response dependence); scanning is unfiltered with in-app parsing
  (`AirParser` accepts v2 mfg + service-data and legacy v1 single-UUID
  packets). Android/Linux originate v2; Apple/Windows originate legacy v1
  ticks alternating challenge UUIDs (full-strength `C_j`, never truncated)
  and server-address hint UUIDs (`BaseI64` + IPv4 + port — the 4-byte
  address fits beside the discriminator, not inside the challenge), so
  Apple-originated classes publish their HTTPS address through the mesh
  with zero taps despite the displacement (confirmed live 2026-09-05
  Mac→phone: UUID arrives, mfg in no callback, not a split packet; Mac
  UUID-only arrives as `RX challenge v1`, phone→Mac v2 verified on bleak
  with rotation). Students parse all formats; relays preserve the heard
  format (`expectedAirKey`/`expectedUuid`). Air sightings default to
  `TTL=3`; explicit 0 still drops.
- Class IP over BLE (Android/Linux profs): the HTTPS `host:port` rides the
  v2 primary-packet manufacturer payload (`0xFFFF`/`PX 02`); browsing
  students background-probe hinted hosts and list answerers with zero taps
  and zero LAN broadcasts (join still enforces radio + signature + face, so
  the unverified hint can at worst cost one probe). Apple hosts publish
  the same address on their alternating IP-hint UUID ticks (see above),
  with UDP/manual as backstop.

This is the BitChat controlled flood reduced to the minimum needed for a lecture hall: 3 hops max, 30 s lifetime, tiny fixed payloads, authority still centralized.

### 6.3 WiFi HTTPS (bulk transport)

Professor runs an embedded `shelf` HTTPS server (phone or laptop,
foreground) + UDP beacons `:54545` (discovery, not mDNS) + BLE IP hint +
manual IP display with type-in join. Endpoints (as built,
`packages/transport/lib/src/server.dart`):

```
GET  /window               -> {class, sessionID, windowID, j_now, PK_p, Cert_p, Sig_p, Sig_p_prev}
POST /prove {ID,windowID,j,C_j,Sig_s,faceScore,peerW} -> {confirmed|late|invalid, serverTime, Sig_pAck}
POST /waiting {email,name,roll}   -> presence heartbeat (waiting room)
POST /leave {email}               -> explicit leave (count drops at once)
GET  /waiting                     -> waiting rows (professor)
POST /manual-request {...} / GET /manual-requests / POST /manual-decide / GET /manual-status
GET  /live                 -> counts + rows (professor Bearer)
GET  /export               -> {csv} (professor Bearer; .sig applied at the app layer)
```

Rate limits: `/prove` 40/10 s/IP, `/window` 5/10 s/IP. TLS pinned as in §3.3. If campus AP isolates clients, professor phone hotspot is the documented fallback (same protocol, same code).

Discovery detail (as built + field-verified 2026-09): professors announce
over UDP broadcast `:54545` (2 s beacons, 6 s expiry; targets: limited
broadcast + /24 and /16 directed guesses; announced IP prefers non-VPN,
non-cellular WiFi NICs and re-resolves on every window open). Enterprise
APs may suppress inter-client broadcasts entirely (measured on institute
/18 WiFi: all broadcast variants 0/5) — for those networks classes surface
through the BLE IP hint (Android/Linux profs publish `host:port` in the
air packet; students background-probe and list answerers with zero taps),
plus the manual-IP join (last IP prefilled). A former /24 unicast sweep was
deleted: 254 rapid probes kicked phones off enterprise WiFi. Browsing
live-refreshes every 2 s from local state only (stopped classes vanish on
the 6 s expiry) and supports pull-down refresh; leaving the waiting room
POSTs `/leave` so the prof count drops at once. All beacon/probe/presence/
manual/ACK events stream into the toggleable system log on both screens.

---

## 7. Flows (as built)

### 7.1 Professor flow (identical on phone and laptop)

1. Open Proximity, foreground, plugged in where possible. Confirm Bluetooth + WiFi + location prompts.
2. Open a course (registered by name). The Take screen shows the current IP for student join.
3. Tap **Start** at lecture start. App:
   - generates `S_w`, opens the window (no timer — it stays open until Stop),
   - starts BLE advertise (challenge rotation, new token every 5s) + HTTPS server + BLE scan,
   - shows LIVE elapsed clock plus `present/waiting` counts, waiting list, manual requests.
4. Tap **Stop** when marking is done: rotation ends, but proofs already on the wire are still accepted through a short grace; then the window hard-closes. Tally persisted on-device.
   Back navigation autosaves the draft; recent drafts snapshot to history
   AND resume live (same record, zero taps); older drafts ask
   "Recover old session?" (Recover continues, Save & fresh archives first).
5. Mid-lecture tap **Take another round** for window #2 (fresh `S_w`), or **Retake round N** (same number, marks merge).
6. Tap **End attendance**. Export lives on the course page (per-session CSV, date-range matrix). Saved sessions stay editable (per-round checkboxes, partial/absent quick lists, unified manual-add).

Present rule (default): `Present = pass every window taken`, else `Partial`/`Absent`. Lenient any-window mode per export call.

### 7.2 Student flow (identical Android/iOS)

1. Install once, enroll once online (§3.2).
2. In class, open app, keep in foreground. Join the waiting room by live list or typed IP.
3. The room auto-continues to the face check when the window opens (~1 s). App holds `faceValid`.
4. While the window is open the phone automatically, with no further taps:
   - scans the rotating challenge, extracts `C_j`,
   - advertises the response token,
   - relays challenges if front-row (invisible to user),
   - POSTs `Sig_s` per fresh rotation until a verdict lands,
   - shows step status (`Waiting for the class signal…` → `Signal heard — proving…` → `Proof sent — confirming…`), then `✓ Marked` on signed ACK.
   Dead air ends the listen only after a window probe confirms the round closed. Manual fallback: request manual attendance from the waiting room.
5. Idle until the next round: the badge parks until the round ends, then
the waiting room reopens automatically — face re-checks and the next
mark appends to the per-round trail, zero taps. Keep app open;
backgrounding pauses proving and is shown as `Paused — reopen`.
6. Later: My Attendance shows course cards with day totals → per-course sessions.

### 7.3 Why this flow works

- **Hostel join fails:** attacker on campus WiFi elsewhere can fetch `/window` but never hears `UUID_P(j)` over radio (30 m limit, 5 s rotation). Without `C_j` they cannot build a valid `UUID_S` or `Sig_s` for the current sub-epoch. A screenshot forwarded after 5 s is already stale.
- **Lent phone fails:** holder's face does not match enrollment template, `SK_s` stays locked, no signature is produced. Mismatches burn one of 4 attempts, then the needs-review queue with professor check.
- **Copied ID fails:** signatures verify against the presented device key for that Gmail (TOFU per class). Attacker's phone holds a different key (or none), verification fails.
- **Fake professor fails:** the student verifies `Sig_p(j)` over the
  radio-heard challenge before signing anything (fetch also accepts the
  previous rotation's signature across the 5 s tick). A rogue AP without
  `SK_p` cannot forge either, and only a genuine mismatch — never a
  closed window or rate limit — counts as suspicious.
- **Replay fails:** `(windowID, ID, j)` single-use plus one-sided
  freshness (`0 <= now - t_j < 12 s`) plus LRU dedup. Replayed POST or
  re-advertised UUID is marked late/invalid; retakes (fresh windowId)
  never false-replay.
- **Back-row works:** controlled-flood relay brings the challenge to every seat within 2–3 hops; WiFi POSTs need no relay; BLE response sightings tolerate one relay hop with flag.
- **Equal everywhere:** every device advertises/scans UUIDs only, verifies the same signatures, runs the same face gate and timing. No OS gets a weaker path.

Residual risk (stated): two colluding phones with continuous real-time radio relay across two full windows plus live victim face on the remote end could still wormhole within 5 s. Cost is a dedicated accomplice present for the whole lecture plus low-latency link, far above casual proxy. UWB distance bounding would close it once available on all phones.

---

## 8. Flutter implementation details (as built)

Monorepo (single app + records web build):

```
apps/proximity_app/      single app: student + prof modes (Android/iOS/macOS/Windows/Linux) + web records
packages/protocol/       pure Dart: HMAC/UUID pack, Ed25519, window timer, mesh PDU, dedup, face gate, verify
packages/ble/            BLE engine (rotation/relay/nextChallenge) + Linux BlueZ advertise shim (+ web stub)
packages/face/           detection/embedding/liveness interfaces + SK gate (mock adapter for tests/web)
packages/transport/      shelf HTTPS server/client, per-session TLS + channel binding, LAN discovery, rate limits
packages/storage/        tally + course history + roster helpers (in-memory API; JSON prefs backing)
```

Key packages: `universal_ble` (scan/connect all incl. Linux/Win), BlueZ
`LEAdvertisingManager1` D-Bus shim for Linux peripheral parity, `shelf` +
`shelf_io`, `crypto` + `ed25519_edwards`, `camera`, vendored
BlazeFace + EdgeFace-XS TFLites via `tflite_flutter` (identical face stack
all OS; web gets throwing stubs — records only), `flutter_secure_storage`,
`permission_handler`, `riverpod` (no `local_auth` — OS biometric gate is
future work). The web build compiles the
same closure through conditional exports (transport client/discovery/
server, BlueZ shim, TFLite runtimes, file saving, interface enumeration)
plus `platformx` OS flags; `flutter build web` guards it. History is JSON
in prefs (in-memory `TallyStore` API); SQLite/drift is future work.

Permissions (as built): Android `CAMERA + BLUETOOTH_SCAN/ADVERTISE/CONNECT +
FINE (+COARSE, maxSdk 30) LOCATION + INTERNET + ACCESS_NETWORK_STATE/
WIFI_STATE` (no `NEARBY_WIFI`); iOS `NSCamera/BluetoothAlways/Peripheral/
LocationWhenInUse/LocalNetwork` (no `UIBackgroundModes`); wakelock held
during live windows on all OS (`wakelock_plus`, not `idleTimerDisabled`);
no privacy manifest / foreground-service / snap plug yet. Foreground is
mandatory during windows on all OS (keep-open banner).

---

## 9. Scale, robustness, testing

- Load: 500 POSTs/30 s (~17/s) + 500 UUID advertisers + 6 rotations. Ed25519 verify total ~1000–2500 per lecture, well under 1 s on phone/laptop. Jitter 0–2 s plus server `Retry-After` spreads herd. BLE capture requires 1/6 sub-epochs seen per student, not all.
- Collisions: 200 ms adv interval + continuous scan + GATT-read fallback on CRC fail. Field-tune TxPower and `-70 dBm` direct / `-80 dBm` relay thresholds per hall with `nRF Connect` walk-test.
- Clock drift: 7 s acceptance covers typical phone drift; professor is time authority (signed `serverTime` in ACK).
- MAC rotation: neutralized by rotating `peerW` in scan response + presented-key HMAC lookup (500 HMACs per sighting batch, trivial).
- Tests: golden vectors (HMAC/UUID pack/Ed25519 RFC8032), dedup/flood unit tests, two-phone relay test, 30-room pilot (tune face + RSSI), 150-hall, 500-hall load + adversarial drill (forwarded code, off-site VPN, lent phone, photo spoof, dual-phone wormhole attempt). Ship only when wormhole needs active accomplice across both windows.

---

## 10. Research notes (BitChat mesh, applied)

BitChat (permissionlesstech/bitchat, whitepaper v2.0 Jul 2026; `bitchat-android` mesh docs) demonstrates offline BLE at scale: dual-role GATT central+peripheral on one service/characteristic UUID, 8-byte peer ID in scan response for MAC-rotation stability, MTU 517, `autoConnect=false`, TTL-7 controlled flood with dense-cap 5 / thin-full, LRU dedup (1000/5 min, sender+ts+type+digest), jitter 10–220 ms, fanout `~log2(degree)`, split horizon, directed TTL-1, 469-byte fragments, 4 s→15–30 s announces with 60 s reachability, Noise XX live + Noise X seals, spray-and-wait couriers, GCS gossip sync. Proximity reuses the transport mechanics (dual-role, scan-response alias, TTL/jitter/dedup/split-horizon, MTU/GATT fallback, permission onboarding) while replacing chat semantics with professor-signed windows, rotating unlinkable aliases (fixing BitChat §8 stable-ID linkability), and WiFi bulk transport suited to a lecture hall instead of Nostr/couriers.

---

## 11. Build status (as built)

Shipped: protocol HMAC/UUID/Ed25519 + window rotation + mesh relay +
hotspot/manual join + iOS parity + face gate + SK lock +
channel-bound TLS + desktop host + Linux shim + cloud roles/claims/
session backup + student records + web records build. (GATT
`PROX_SVC`/`PROX_CHR` fallback is future work, not shipped.) Suite: protocol 57
· transport 32 · ble 30 · storage 9 · app 163, `flutter analyze` clean,
`flutter build web` green. Verified 2026-09-06: `flutter build macos`,
`flutter build apk`, `flutter build ios --no-codesign` all green.
CI (`.github/workflows/build.yml`) runs protocol/transport/ble unit tests
only — storage/app/web/native builds verify locally. Pilots pending: 30-room, 150-hall, 500-hall
load + adversarial drill (forwarded code, off-site VPN, lent phone, photo
spoof, dual-phone wormhole attempt).

## 12. Decisions (locked; full 15-item list lives in README §Decisions —

1. Present rule: intersection over all windows taken (`lenientOneOfTwo`
   per export call preserves any-window mode).
2. `BaseP64/BaseS64` prefix allocation + air `FCD2`/`0xFFFF`/`PX 02`
   (built from 32-bit halves in code — JS-safe, bit-exact natively).
3. Exports are host-only source of truth; End ≠ Export (export lives on
   the course page).
