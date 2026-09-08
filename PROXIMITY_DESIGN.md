# Proximity — Campus Attendance System
## Final Design Document

**Version:** 2.1 as-built (Track 6 consolidation — §8 module map and §13
are new; §1 goal 6, §3 org/claim, §4 face, §5.1 Sig_s rewritten to match
the code; everything else carried over from 2.0 where still true).
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
> Tracks 2+3 replaced the vendored face pipeline with the
> `face_verification` plugin (§4) and extended the claim/proof with the
> dual-key device binding (§3.2–§3.3). Sections below marked “as built”
> describe the shipped behavior; the radio/crypto mechanics (§5–§6) apply
> with the §5.1 extended ticket.

---

## 1. Goals

1. Professor starts attendance from phone or laptop in the classroom, with explicit foreground action.
2. Students prove physical presence with their own phones in an open window (no countdown).
3. One phone cannot mark proxy for another person. One screenshot or forwarded code cannot mark proxy from hostel.
4. Professor ends the lecture with an attendance list on their own device, exportable per session and per date range.
5. Works fully offline on the classroom WiFi (never a phone hotspot — hotspot networking is excluded by design) + BLE mesh. Internet required only once at enrollment (and for cloud sync).
6. Platform split (as built — NOT identical everywhere): student
   marking (radio + face + device keys) is Android/iOS mobile-only;
   professor hosting runs on Android/iOS/macOS/Windows/Linux; the web
   build is records-viewing only (same login, no marking, no keys).
   Where a flow runs, it runs the same protocol — but flows that need
   the radio/face/keys fail closed off-mobile instead of degrading.

Non-goals: background auto-marking, perfect anti-wormhole against a dedicated real-time accomplice pair (requires UWB distance bounding, not available on all phones), central cloud attendance DB.

---

## 2. System overview

```
ONCE ONLINE (internet):
  Student/Prof: Google Sign-In
    -> generate Ed25519 keypair in secure storage (sealed to the
       device key — §3.2)
    -> face enrollment on-device (plugin, §4)
    -> atomic device claim {Gmail, pkS, pkD, installId, attestation...}
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

### 3.0 Org scoping (Track 1 — the join gate)

The org is the Google-account domain (`orgOf`: lowercased domain,
`googlemail→gmail`, rejects spaces/`@`/leading-trailing dots;
`apps/proximity_app/lib/core/sync/org.dart`). It is stamped on the role
cache at sign-in (`roleOrg`), on every session record, and on every
outbox entry; pulls filter by org, and the rules enforce same-org
reads/writes.

The student join-gate compares the class descriptor org against
`studentOrgOf` (explicit identity org, else the Gmail domain) BEFORE any
radio response or POST — a mismatch returns a structured wrong-org
receipt (`MarkedReceipt.isWrongOrg` + `classOrg`/`myOrg`, Track 6) and
sends no PII. Legacy `''` on either side passes (migration). The UI
branches on the flag, never on matching detail text.

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
3. Generate keys (dual-key, Tracks 2+3):
   - `SKey` Ed25519 (the signing key), sealed to `DKey` (AES-GCM `PXK1`
     envelope — ciphertext only at rest).
    - `DKey` P-256: StrongBox→TEE / Secure Enclave on HW backends;
      software/fake backends (level `none`: no tier claimed — live proofs
      confirm via the flagged `device-none-fallback`). **Residual: the HW
      keystore/Enclave backend and its enrollment-time material
      persistence are deferred — production DKeys are software until it
      lands (§13).**
   - The install is the device identity: an app-install UUID in secure
     storage (clones/dual-apps get their own).
4. Face enrollment on-device (§4). The plugin store is keyed by
   `faceIdOf = SHA-256(lowercased Gmail || installId)` — the raw Gmail
   never lands in the plugin-owned table.
5. Atomic extended claim `{Gmail, pkS, pkD, installId, name, roll,
   modelVer/verifierVer, attestationLevel, attestedAt,
   attestedUntil=+90d}` in one Firestore transaction
   (`studentDevices/{email}` + `deviceInstalls/{installId}` + a
   `studentDirectory` search row + a `facePrints` quantized face-code for
   the same-face duplicate check — §4). Same-install re-keys are free; moves
   to a different install need a 7-day cooldown (unlimited moves,
   ≤1/week, exact re-enroll date shown; an old-DKey-signed MoveIntent
   moves instantly; no reset exists); an install enrolled as another
   Gmail hard-refuses. Every claim and online re-sign-in heartbeats
   last-online. (Web records builds skip the device gate: no key lives
   there, sign-in lands on records.)

Professor cloud sync is session backup (offline-first, local history
stays source of truth), not key distribution.

### 3.3 In-class authentication (offline, as built)

- Student to professor: `Sig_s` (extended ticket, §5.1) + Gmail +
  `pkD` + `dSig = Sign(DKey, deviceProvePreimage)` + the face ticket
  `{score, faceValidAt, verifierVer}` (hash-bound, no images leave the
  device). Professor verifies against the presented `PK_s` (TOFU per
  class, no roster lookup), checks `score >= T`, `faceValidAt` fresh,
  `verifierVer` allowlisted, then: FULL/STD fresh → confirmed, FULL/STD
  past `attestedUntil` within the 14d grace → confirmed+banner,
  expired/bad-dSig → device-unproven → manual path, and level NONE →
  graceful fallback (same ticket-bound `Sig_s` + face + sighting checks,
  no tier claimed, `dSig` not gated) → confirmed with a
  `device-none-fallback` flag. The fallback exists because HW keys don't
  ship yet — production is always `SoftwareDeviceKey`/NONE, and gating it
  hard-invalid stranded all live marking.
- Professor to student: `Sign(SK_p, ...)` over the session descriptor,
  verified against the live window fetch (rotation-tolerant). Blocks
  Evil-Twin access points.
- TLS: per-hosting-session runtime cert; MITM resistance via channel
  binding (`tlsFp` + `sigBind` over the presented cert) verified
  server-side. No external CA needed.

### 3.4 Attestation trust — offline-only (no server re-check)

Stated plainly: NO server-side attestation verification exists in this
system. A `verifyAttestationChain` Cloud Function was designed and built,
then REMOVED before ever deploying: the project carries no billing-gated
backend (hard constraint), so there is nothing to run it on. The project
is serverless-direct Firestore everywhere, with no exceptions. Do not
read any older note, comment, or report as implying a server check —
if one does, it is stale and this section wins.

What that costs, honestly: the `attestationLevel` on every binding
(FULL/STD/NONE) is SELF-ASSERTED by the enrolling client. No chain
verification exists anywhere — not on-device, not on-server. A modified
client can claim FULL while holding a software key, and no component in
the system can tell the difference from the claim alone. The tier
machinery (`evaluateDeviceProof`) still runs on every proof, but until
the keystore/Enclave track lands real hardware keys, treat every mobile
tier as provisional.

What still holds without it (all offline, all tested):
- dSig challenge-binding: every proof carries a FRESH signature over
  the live 5s challenge. Replays are worthless after rotation
  (single-use `(windowID,ID,j)` + 12s window); forging requires the
  device's SKey unwrapped behind a fresh face ticket, every rotation.
- Sealed SKey: on hardware keys, file copies are ciphertext without the
  silicon DKey (restore detected → re-enroll). On software keys
  (everything shipped today — `SoftwareDeviceKey`, level NONE) the seal
  travels with its files: that is exactly why software keys claim NO tier
  and confirm only via the flagged `device-none-fallback` rather than as
  FULL/STD. The fallback flag (plus the ticket anomaly flags and the
  double-pkD audit below) is the honest record that no silicon stood
  behind the mark.
- Face-ticket anomaly flags (`detectFaceAnomalies`: saturated scores,
  future/reused stamps, unknown verifier, version flapping) ride every
  proof for professor-side visibility.
- One-active-device accounting (claim tx, 7d cooldown, MoveIntent) and
  the offline double-pkD audit (`findDoublePkD` / `auditDoublePkD`):
  a copied identity used on two installs leaves a permanent,
  attributable trace in the synced bindings.
- Live marking works on both shapes: legacy unbound proofs verify
  exactly as before, and bound-NONE proofs (what every genuine mobile
  student sends today) confirm via the flagged fallback — same
  ticket-bound `Sig_s`, face, org, sighting and channel-binding gates,
  only the device tier skipped. FULL/STD confirmation is reserved for the
  HW keys that earn it; until they ship, the binding story is the ticket
  binding + fallback flag + double-pkD audit, not a hard NONE gate (which
  stranded all live marking — see fix note 2026-09-08).

Remains (scoped feature work, not stubs): on-device HW key production
by the keystore/Enclave track (the step that makes FULL/STD mean
silicon, not self-assertion); Apple App Attest root provisioning (moot
until a backend exists to verify against it); revocation/CRL checks
(theft response today: 7-day move bound + manual attendance).

---

## 4. Face binding (as built — plugin model, Tracks 2+3)

Purpose: the key proves the phone, BLE proves the phone's location, face proves the holder. Lending an unlocked phone fails.

The vendored custom pipeline (BlazeFace + EdgeFace-XS, five guided
poses, 0.60 cosine gate) is DELETED (net −2044). Everything face goes
through the ONE narrow `FaceVerifier` interface
(`apps/proximity_app/lib/features/face_identity/face_verifier.dart`):
enrollment, marking, and the SK-use stamp. Backend is the
 `face_verification` plugin (^0.3.9, MIT, Android/iOS, bundled FaceNet
 TFLite, offline) following its Quick Demo pattern: init once →
 `registerFromImagePath` per still → `verifyFromImagePath[Isolate]`.
 No IMAGES ever leave the device, and the plugin-owned gallery never does
 either — but ONE quantized face-code per Gmail DOES (see dedup below):
 the old "embeddings never leave the device, full stop" guarantee is
 narrowed to "photos and the gallery never leave; a consented,
 quantized face-code is stored for duplicate checks".

- Enrollment: ONE continuous camera session (open once, close on
  done/cancel — never falls out and back per angle) over the 5186c65
  preview ancestor chain, constructed identically (same widgets, same
  flex — the displayed ratio IS the preview-area ratio, so the chain
  sets it; a chain-parity test pins it). The overlay is strictly
  Positioned/IgnorePointer decoration: thin oval with a slow clockwise
  sweep glow on its rim (one calm revolution per several seconds; steady
  full-rim glow under reduced motion) + progress dots. ONE static prompt
  below the preview; no narrated checker state, no per-angle titles.
  Every still classifies into ANY matching unfilled bucket
  (centre/left/right/up/down — ML Kit euler windows: yaw ±12° centre;
  8–35° side turns; 8–30° tilts; roll ≤20°; null/unreadable fails
  closed); rejects stay silent. Then the 5 go to the plugin gallery with
  a centre-still self-check before advancing. Fail-closed throughout
  (save blocked till all 5 validate; cancel enrolls nothing). Patterns
  followed: Apple Face ID enrollment (one imperative + rim progress),
  Tobii "follow the target" calibration (one target, 5 points, repeat
  missing).
- Threshold: `kFaceThreshold = 0.70` (plugin scale). The old 0.60/0.80
  EdgeFace cosine numbers MUST NOT be reused — different embedding
  space, incomparable. **Residual: 0.70 FAR~0.01%/FRR<2% is the
  plugin's published operating point, not a Proximity-measured ROC
  (§13).**
- Score semantics (plugin reality, not hidden): verify returns the
  matched id (or null), not a distance — a match is carried at exactly
  the decision threshold (the honest boundary value), bound into the
  ticket and re-checked host-side (`score >= T`).
- Pipeline versioning: every ticket carries `verifierVer =
  face_verification/<pkgVer>+<assetHash8>` (8-hex plugin-asset pin);
  any plugin/model swap forces re-face via the stale-pipeline check
  (key kept). The host allowlists verifier versions; flapping across
  proves is flagged post-hoc.
- Liveness: passive only, stated plainly — no blink/turn-head prompts,
  no stills heuristics (tried and removed: sparse stills can't catch
  200ms blinks and either false-reject or are trivially weak). The 5
  pose-gated angles buy genuine-match robustness and raise the spoof
  cost (a single frontal print no longer suffices — the attacker needs
  five pose-consistent views), but they are NOT photo-spoof immunity: a
  good-quality print or replay held at each asked angle CAN still pass
  the passive matcher. What stands behind that residual is the
  4-mismatch-session budget → needs-review → professor manual
  override, the 5-minute holder-freshness gate, and ticket binding
  (a replayed score can't cross tickets). If photo fraud appears in the
  pilot, the fix is video-stream liveness or a spoof-classifier model.
- Gating: private-key use requires `faceValid < 5 min`
  (`kFaceValidWindow`). Signing throws otherwise. Each 30 s window
  demands a fresh check (~1 s oval UI).
- Failure: 4 mismatch sessions on confident mismatch only (unreadable
  frames rescan free; `kFaceMaxRetries = 2` instant retries), then the
  `needs-review` queue. Professor verifies the person in the room and
  applies a logged manual override. Never auto-present on face fail.
- Mobile-only: every method gates on Android/iOS first — desktop/web
  fail closed through `UnavailableFaceVerifier` (DI-wired, never the
  plugin) and the UI shows `FaceBlockedCard` instead. Records-only
  builds never touch face code (conditional-export stub throws).
- Same-face dedup (claim-time, online): enrollment derives ONE canonical
  face-code from the 5 stills (L2 mean → int8 quant, 512 B base64 — the
  plugin exposes gallery embeddings via `getFacesForUser`, no fork) plus
  10 simhash bucket strings (80-bit Rademacher projection, fixed seed —
  integer math only, identical on every phone). The code lands in
  `facePrints/{gmail}` atomically in the claim transaction; before the
  claim the phone pulls the org bucket shortlist (ONE
  org+arrayContainsAny query, limit 25) and exact-compares (cosine on
  dequantized vectors, flag at 0.75 — stricter than the 0.70 marking
  gate; self-excluded, pipeline-scoped). A hit refuses with
  non-accusatory copy (siblings named as the FP class, nobody named,
  nothing stored for the refusal) + recapture retry (key kept) + manual
  attendance (never a dead end). Naive O(org) pull blows the Spark quota
  at 150+ pilots (85k reads/day at N=500); bucketed costs ~20
  reads/enrollment (~3.4k/day). Privacy cost, stated: quantized codes
  are invertible biometric data (Mai TPAMI'19 et al.), org-listable by
  design, kept indefinitely (no delete/TTL on Spark). Residuals: twins
  flag each other (manual path); custom clients can file garbage codes
  (self-assertion posture, §3.4); simultaneous duplicate claims can race;
  no cloud professor-override exists (the prof gate is advisory, so any
  override doc would be self-forgeable — manual attendance is the path).

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
Sig_s      = Sign(SK_s, sessionID || windowID || j32 || C_j || ID
                  || faceMilliBE || faceValidAtBE || verifierVerHash8
                  || pkD32 || faceTicketHash8)       // extended ticket, §5.1a
dSig       = Sign(DKey, sessionID || windowID || j || C_j
                  || faceTicketHash || pkS)          // deviceProvePreimage
```

#### 5.1a Extended ticket (Tracks 2+3, as built)

The face ticket `{score, faceValidAt, verifierVer}` travels in POST
`/prove face:{...}`; its hash `faceTicketHash =
SHA-256(scoreMilliBE16 || faceValidAtBE64 || verifierVerHash8)[0:8]`
binds into BOTH Sig_s and dSig, so neither signature transplants
across tickets. No images/embeddings leave the device — only the hash
+ the ticket. The preimage is longer than the old 6-field form, so old
signatures never verify against it and vice versa; the host requires
non-zero `faceValidAt` + allowlisted `verifierVer` (legacy-neutral
defaults exist only to keep the migration compilable, never to accept
legacy proofs at runtime).

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
POST /prove {ID,windowID,j,C_j,Sig_s,faceScore,peerW[, face:{score,faceValidAt,verifierVer}, pkD, dSig, attestationLevel]} -> {confirmed|late|invalid, serverTime, Sig_pAck}
POST /waiting {email,name,roll}   -> presence heartbeat (waiting room)
POST /leave {email}               -> explicit leave (count drops at once)
GET  /waiting                     -> waiting rows (professor)
POST /manual-request {...} / GET /manual-requests / POST /manual-decide / GET /manual-status
GET  /live                 -> counts + rows (professor Bearer)
GET  /export               -> {csv} (professor Bearer; .sig applied at the app layer)
```

Rate limits: `/prove` 40/10 s/IP, `/window` 5/10 s/IP. TLS pinned as in §3.3. If campus AP isolates clients, BLE hint + typed IP carry the join and an unreachable host fails honestly into the manual path — hotspot is excluded, never the fallback.

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
The discovery ladder (assumptions table + degradation order,
`packages/transport/lib/src/discovery.dart`) is the decision record for
which rung is active; the UI shows the current rung, never a silent
empty state.

---

## 7. Flows (as built)

Screen inventory lives in `apps/proximity_app/SCREEN_MAP.md` (Track 5 —
one line per screen: what exists / merged / split / removed + its reason
to exist). The flows below are the operator summary; the map is
authoritative for which screens exist.

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

### 7.2 Student flow (Android/iOS only — §1 goal 6)

1. Install once, enroll once online (§3.2).
2. In class, open app, keep in foreground. Join the waiting room by live list or typed IP. Cross-org classes refuse with a structured
   wrong-org verdict (`isWrongOrg` + real orgs on the card) before any
   proof is sent — a decision, not a network hole.
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
- **Cloned app fails:** the install UUID + sealed SKey envelope don't
  transfer — a backup-restore clone fails unwrap and must re-enroll
  (subject to the 7-day move bound), and the old install's binding
  still names the old install. (Residual: software DKey until §13 HW
  lands, so this is envelope+server-claim strength, not silicon.)
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
- **Equal where it runs:** every marking device advertises/scans the
  same packets, verifies the same signatures, runs the same face gate
  and timing. Off-mobile there is no weaker path — there is no path
  (fail-closed, §1 goal 6).

Residual risk (stated): two colluding phones with continuous real-time radio relay across two full windows plus live victim face on the remote end could still wormhole within 5 s. Cost is a dedicated accomplice present for the whole lecture plus low-latency link, far above casual proxy. UWB distance bounding would close it once available on all phones.

---

## 8. Flutter implementation details (as built)

Monorepo (single app + records web build):

```
apps/proximity_app/      single app: student + prof modes (mobile + desktop) + web records
  lib/core/              drivers (host/student), auth, sync_hook, platform seams
  lib/core/sync/         SyncEngine + outbox + union merge + org/roles/claim/
                         directory/cloud_api/sessions/queue/backends
  lib/core/sync/store/   DeviceStore (secure/memory) + record_helpers (pure)
  lib/features/          entry / enroll / face_identity / live / mark /
                         review / records / debug (one dir per flow)
  lib/widgets/           prox_* shared library (cards/tiles/buttons/states/
                         motion/verdict) + trust_cards/sync_badge/clock/...
  lib/screens/           thin hosts: student_home + take_attendance
                         (orchestration only; rendering lives in features/)
  lib/design/            tokens (single source: spacing/type/color/motion)
packages/protocol/       pure Dart: HMAC/UUID pack, Ed25519, window timer,
                         mesh PDU, dedup, face gate, ticket/dSig preimages,
                         device tiers, org-free (app-layer)
packages/ble/            BLE engine (rotation/relay/nextChallenge) + Linux
                         BlueZ advertise shim (+ web stub)
packages/transport/      shelf HTTPS server/client, per-session TLS +
                         channel binding, LAN discovery + ladder, rate limits
packages/storage/        tally + course history + roster helpers
                         (in-memory API; JSON prefs backing)
```

(No `packages/face`: face is the plugin + the one-file `FaceVerifier`
interface in `lib/features/face_identity/` — the old vendored-pipeline
package is gone with Tracks 2+3.)

Track 6 consolidated homes (single definition each — §13):
`record_helpers.dateIsoOf/todayIso/recordInCourse` ·
`org.orgOf/resolveMyOrg/inMyOrg` · `roles.roleOrg` ·
`directory.normalizeSearchPrefixes` ·
`sync_hook.readSyncProf/flushNow` ·
`sync_badge.PendingCountChip` · `file_saver_common.sanitizeFilename` ·
`MarkedReceipt.{isWrongOrg,classOrg,myOrg,attestationLevel,
attestationFlags}`. UI rows are `ProxCard/ProxListTile` (dense rows
inside sections included); tertiary inline actions stay raw `TextButton`
by documented reservation, not oversight.

SyncEngine (offline-first sync-on-reconnect): durable outbox
(`pendingSessions` snapshots + `pendingAdds` manual queue + tombstones —
deletes win over older upserts), union-merge-before-push (window maps +
names/rolls additive, `timestampIso` max — never backwards), single
flight, per-entry exp backoff with jitter (5 s → 1 min → 15 min cap,
`nextRetryAt` persisted), remainder-rewrite at end. Triggers:
connectivity-return edge (Firestore `Source.server` probe is ground
truth; the platform hint only wakes a ~5 s debounced probe) + app
resume + post-live-save hook + 15 min backstop while non-empty. The
unsynced badge reads `pendingCount`. Offline→online edges log SYNC
lines, never silent. Student records pull rides the same union reader
directly (the engine has no student-pull entry — kept as-is, §13).

Key packages: `universal_ble` (scan/connect all incl. Linux/Win), BlueZ
`LEAdvertisingManager1` D-Bus shim for Linux peripheral parity, `shelf` +
`shelf_io`, `crypto` + `ed25519_edwards`, `camera`,
`face_verification` plugin (bundled FaceNet, offline — replaces the
vendored BlazeFace/EdgeFace stack on every OS; web gets throwing stubs
— records only), `flutter_secure_storage`,
`permission_handler`, `riverpod` (no `local_auth` — OS biometric gate is
future work). The web build compiles the
same closure through conditional exports (transport client/discovery/
server, BlueZ shim, face plugin stub, file saving, interface enumeration)
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
- Clock drift: 12 s one-sided acceptance covers typical phone drift; professor is time authority (signed `serverTime` in ACK); the app banners median drift over recent verdicts instead of silently verdicting late.
- MAC rotation: neutralized by rotating `peerW` in scan response + presented-key HMAC lookup (500 HMACs per sighting batch, trivial).
- Crash windows (stated): a crash between the history write and the
  outbox enqueue leaves that record unqueued until its next mutation
  re-enqueues it; a crash mid-flush heals via idempotent replay
  (doc id = record id, `set(merge:true)`, monotonic timestamps).
- Tests: golden vectors (HMAC/UUID pack/Ed25519 RFC8032, ticket/dSig
  preimages), claim/tier unit tests, dedup/flood unit tests, two-phone
  relay test, suite: protocol 96 · transport 35 · ble 35 · storage 9 ·
  app 202 · functions 18, `flutter analyze` clean, `flutter build web`
  green. Pilots pending: 30-room, 150-hall, 500-hall load + adversarial
  drill (forwarded code, off-site VPN, lent phone, photo spoof,
  dual-phone wormhole attempt). Ship only when wormhole needs active accomplice across both windows.

---

## 10. Research notes (BitChat mesh, applied)

BitChat (permissionlesstech/bitchat, whitepaper v2.0 Jul 2026; `bitchat-android` mesh docs) demonstrates offline BLE at scale: dual-role GATT central+peripheral on one service/characteristic UUID, 8-byte peer ID in scan response for MAC-rotation stability, MTU 517, `autoConnect=false`, TTL-7 controlled flood with dense-cap 5 / thin-full, LRU dedup (1000/5 min, sender+ts+type+digest), jitter 10–220 ms, fanout `~log2(degree)`, split horizon, directed TTL-1, 469-byte fragments, 4 s→15–30 s announces with 60 s reachability, Noise XX live + Noise X seals, spray-and-wait couriers, GCS gossip sync. Proximity reuses the transport mechanics (dual-role, scan-response alias, TTL/jitter/dedup/split-horizon, MTU/GATT fallback, permission onboarding) while replacing chat semantics with professor-signed windows, rotating unlinkable aliases (fixing BitChat §8 stable-ID linkability), and WiFi bulk transport suited to a lecture hall instead of Nostr/couriers.

---

## 11. Build status (as built, Track 6)

Shipped: protocol HMAC/UUID/Ed25519 + window rotation + mesh relay +
typed-IP/manual join + iOS parity + face gate + SK lock +
channel-bound TLS + desktop host + Linux shim + cloud roles/claims/
session backup + student records + web records build +
org join-gate with structured
wrong-org receipts (§3.0) + Track 6 consolidation (§13). (GATT
`PROX_SVC`/`PROX_CHR` fallback is future work, not shipped.)
Suite: protocol 96 · transport 35 · ble 35 · storage 9 · app 202 ·
functions 18, `flutter analyze` clean, `flutter build web` green.
Prior-track verified: `flutter build macos`, `flutter build apk`,
`flutter build ios --no-codesign` green (2026-09-06; Track 6 touches
Dart only — no native/web manifests changed, so no rebuild was
re-run for this pass).
CI (`.github/workflows/build.yml`) runs protocol/transport/ble unit tests
only — storage/app/web/native builds verify locally. Pilots pending: 30-room, 150-hall, 500-hall
load + adversarial drill (forwarded code, off-site VPN, lent phone, photo
spoof, dual-phone wormhole attempt).

## 12. Decisions (locked; full list lives in README “Decisions locked during build” —

1. Present rule: intersection over all windows taken (`lenientOneOfTwo`
   per export call preserves any-window mode).
2. `BaseP64/BaseS64` prefix allocation + air `FCD2`/`0xFFFF`/`PX 02`
   (built from 32-bit halves in code — JS-safe, bit-exact natively).
3. Exports are host-only source of truth; End ≠ Export (export lives on
   the course page).

---

## 13. Track 6 consolidation record + residual risks (this pass)

### 13.1 What was consolidated (behavior unchanged, all suites green)

| # | Before (copies) | Canonical (winner + why) | Deleted |
|---|---|---|---|
| D1 | `SharedPreferences.getInstance()` ×34 inline in `SecureDeviceStore` | Private `_prefs()` in the store (same instance semantics, no new module) | 34 one-liners → 1 helper |
| D2 | `_orgOf` (student_driver) + inline domain closure (my_attendance) | `orgOf` in `core/sync/org.dart` (tested, most-guarded) | 2 bodies; `studentOrgOf` wrapper kept (adds identity.org precedence) |
| D3 | `_dayOf` (claim) + `trustDateLabel` body + `todayIso` body + `dateIsoOf` body (clock) + `fmt` closure (export) | `dateIsoOf` in `record_helpers.dart` (pure core; core must never import widgets — single definition via the device_store barrel) | 4 bodies + 1 closure; `trustDateLabel` kept as millis-gate wrapper |
| D4 | Filename regex in `file_saver_io` + `file_saver_web` | `sanitizeFilename()` in new `file_saver_common.dart` (platform-neutral; re-exported by the facade — a facade definition would cycle) | 1 copy |
| D5 | `(role?['org'] ?? '').trim().toLowerCase()` ×4 (host/take/manual-add) | `roleOrg()` in `roles.dart` (Track 1 home) | 4 one-liners |
| D6 | `acct.org else role org` in sync_hook ×2 + `_profOrgForSession` | `resolveMyOrg()` in `org.dart` (normalizes the previously raw role side; values already normalized upstream so no behavior change) | 2 blocks + 1 helper body |
| D8 | Prefix trim/lower in Firestore + Fake backends | `normalizeSearchPrefixes()` in `directory.dart` (shared interface file — parity by construction) | 2 blocks (full search bodies stay separate: different query mechanics, same contract) |
| D10 | `entryMergeProfCloud` manual flush tuple | `flushNow` (identical derived identity — callers stamp the cache first) | Manual tuple build |
| D11 | `Chip(N unsynced)` in `UnsyncedBadge` + `SyncStatusStrip` | `PendingCountChip` in `sync_badge.dart` (Badge keeps historic offline icon — rendering byte-identical) | 1 Chip copy |
| D13 | Raw platform `Chip` in flagged review | `ProxStateBadge(neutral)` (the Wrap already speaks badge) | 1 Chip copy |
| D14 | Bespoke `Card+ListTile` (course header/tile) + 4 dense `ListTile`s | `ProxCard` / `ProxListTile(dense:true)` (dialog row keeps original non-dense — density preserved, not forced) | 6 bespoke rows |
| D18 | `detail.contains('wrong organization')` substring match | `MarkedReceipt.{isWrongOrg,classOrg,myOrg,attestationLevel, attestationFlags}` (driver populates; UI branches by type; wrong-org card shows real orgs) | Fragile match (+6 LOC approved addition) |

LOC (first-party, same counting method as Phase A): lib ≈ −130
against 21391 with +6 approved addition — honestly modest (~0.5%),
because Tracks 2+3 (−2044), M6 (pure-helper collapse) and Track 5
(shared library) already took the big wins. Remaining copies are
one-liner idioms and intentional seams (below).

### 13.2 Kept as-is (with reason — do not "consolidate" later without one)

- **Error mapping:** `_friendlySignInError` (keychain remediation) vs
  manual-add `_userMessage` (prefix strip) vs backend guards
  (`_isOfflineError`, `_isRefused`, `_needAvailable/_needOnline`) —
  different layers/vocabularies; the student sniffers stay `dart:io`-free
  for web compilation.
- **Platform seams:** transport/face/file-saver/net-if/attest-http
  stub pairs mirror APIs so web builds without `dart:io`/plugins —
  merging reintroduces the banned import. By design.
- **Test doubles:** one fake per interface (host/student/cloud/face/
  key); unifying couples unrelated contracts.
- **Monolith hosts** (`student_home` 1284 + `take_attendance` 842):
  each has one clear purpose (student prove continuation vs prof host
  orchestration) and already delegates rendering to `features/`
  sections — further splits make forward-only wrappers (§4 smell).
- **`LadderLine` vs `ProxSyncNote`, `CheckboxListTile` ×2, tertiary
  `TextButton`s, compat barrels, per-timer durations:** distinct visual
  intents / too few sites to earn a module / documented reservations.
- **`my_attendance` student-pull path** goes direct to
  `CloudSync` (the engine has no student-pull entry — forcing it through
  `flushNow` would change what is pulled). Same-union-reader, converges.
- **Acct-only org one-liners** (export/flagged): values arrive
  normalized from sign-in; a helper saves nothing net.

### 13.3 Honest residual weaknesses

1. **Face trust is local and vendor-calibrated.** 0.70 FAR/FRR is the
   plugin's published point, never Proximity-measured; no active
   liveness — a good printed photo can pass the matcher. Behind it:
   4-mismatch budget → needs-review → human override, 5-min holder
   gate, cross-ticket replay impossible by construction.
2. **Device trust is software until HW lands, and self-asserted even
   then at the claim layer.** No keystore/Enclave backend yet →
   DKey level `none` in practice; no server re-check exists at all
   (§3.4), so a claimed FULL/STD is consistency-checked, never proven.
    Anti-clone strength today = sealed envelope + install UUID + 7d move
    bound + offline double-pkD audit, not silicon. Live NONE marks carry
    the `device-none-fallback` flag so the lack of silicon stays visible
    per proof.
3. **Network failure modes:** isolating APs kill UDP (measured 0/5 on
   institute /18) → BLE hint + manual IP carry join; the /24 sweep was
   deleted for kicking phones off WiFi; hotspot is excluded by design
   (never a fallback). Wormhole vs a real-time accomplice pair stands (§7.3).
4. **Sync failure modes:** history↔outbox crash window heals on next
   mutation; tombstones beat older upserts (monotonic `timestampIso`
   bounds the skew damage); student-pull bypasses single-flight (same
   reader, converges, but concurrent pulls can overlap).
5. **Stored-material gaps:** no CRL/revocation (validity-at-enrollment +
   bound + manual); no key sync to a new phone except MoveIntent /
   re-enroll; backup-restore clones fail closed into re-enroll (correct
   but a support cost).

### 13.4 Explicitly deferred

HW keystore/Enclave + material persistence · Apple root file ·
SQLite/drift · background modes · privacy manifest / foreground-service /
snap plug · CoreML export · UWB distance bounding · CRL · student-pull
engine entry · README decision 9 still names the deleted EdgeFace stack
(flagged, README out of scope for this pass).
