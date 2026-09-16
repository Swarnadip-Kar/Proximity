# Proximity — Explainer Guide
---

## 1. Introduction

**Proximity is a campus attendance system that proves "you were in the room" — without trusting WiFi, screenshots, or borrowed phones.**

The core problem with attendance apps: anyone can tap a button from the hostel. Proximity fixes that by combining three proofs at the same moment:

1. **Nearness** — you heard a short-lived secret over Bluetooth (which only travels ~10–30 meters).
2. **Ownership** — the proof is signed by a key locked inside *your* phone's secure chip.
3. **Holder** — your face matched on-device seconds before signing.

One app, two modes: **Student** (enroll once, then mark in class) and **Professor** (host a class, collect proofs, export records). It works **offline in the classroom** — internet is needed only once at enrollment and later for cloud backup/sync. There is also a **records-only web build** for viewing attendance, which cannot mark or enroll.

---

## 2. Bird's-Eye View

### The pieces

```
                    ┌──────────────────────────────┐
                    │        GOOGLE / FIREBASE     │
                    │  Login + Cloud Database      │
                    │  (once: enroll · later: sync)│
                    └──────────────┬───────────────┘
                                   │ internet (rare)
        ┌──────────────────────────┼──────────────────────────┐
        │                          │                          │
┌───────▼────────┐        ┌────────▼─────────┐      ┌─────────▼────────┐
│ STUDENT PHONE  │        │ PROFESSOR DEVICE │      │  WEB (records)   │
│ Android / iOS  │        │ Phone or Laptop  │      │  view only       │
│                │  BLE   │                  │      │                  │
│ face + HW key  │◄──────►│ challenge +      │      │  no BLE, no face │
│ + signs proof  │  WiFi  │ verifies + marks │      │  no keys         │
└────────────────┘ HTTPS  └──────────────────┘      └──────────────────┘
        │                          │
        │   classroom only,        │
        │   no internet needed     │
        └──────────────────────────┘
```

### Flow diagram (a single lecture)

```
ENROLL ONCE (online, ~2 min)
  Student signs in with Google
    → phone creates a locked key
    → face enrolled ON the phone (never uploads)
    → cloud records "this Gmail = this phone" (one device per student)

IN CLASS (offline, classroom WiFi + Bluetooth)
  Professor:  Start → shouts rotating secret over Bluetooth (new every 10s)
                         + runs a small web server on WiFi
                         + announces "class is live" on the LAN

  Front-row phones: re-shout the secret so the back row hears it (mesh relay)

  Student phone (automatic, no taps):
    hear secret over Bluetooth
      → face check (~1 sec)
      → sign proof with phone-locked key
      → send over WiFi
    Professor verifies (fresh? signed? face ok? really seen over radio?)
      → returns signed receipt → student sees "✓ Marked"

  Professor: Stop → grace period → End attendance → record saved on device

LATER (online)
  Professor's records back up to cloud · Students see "My Attendance"
```

### What lives where — technology map (names only)

| Where | Technology | One-line job |
|---|---|---|
| Whole app | **Flutter + Dart** | One codebase builds Android, iOS, macOS, Windows, Linux, Web |
| App structure | **Monorepo: app + 4 packages** (`protocol`, `ble`, `transport`, `storage`) | Keeps crypto / radio / network / records logic separated and testable |
| Login | **Firebase Auth + Google Sign-In** | "You are this Gmail" — identity for everything |
| Cloud database | **Cloud Firestore + Security Rules + Indexes** | Stores enrollments, sessions, backups; rules enforce who can read/write |
| App health gate | **Firestore `app_config/min_version`** | Force-updates old unsafe builds |
| Anti-fake-app | **Firebase App Check + Play Integrity (Android) + App Attest/DeviceCheck (iOS) + `flutter_security_suite`** | Blocks rooted, hooked, emulated, re-signed apps |
| Nearness (radio) | **Bluetooth Low Energy via `universal_ble` (+ Linux BlueZ shim)** | Short-range challenge shouts + mesh relay to back rows |
| Transport (data) | **HTTPS server/client via `shelf` + UDP discovery + TLS channel binding** | Carries proofs bulk-data-style; discovery finds the class on the LAN |
| Signatures | **Ed25519** | Student + professor signatures on challenges and receipts |
| Short secrets | **HMAC-SHA256** | Derives rotating challenge/response tokens |
| Fingerprints/hashing | **SHA-256** | IDs, key fingerprints, ticket binding |
| Key wrapping | **AES-GCM** | Locks the signing key to the phone's hardware key |
| Hardware key | **P-256 + Android StrongBox/TEE + iOS Secure Enclave** | Non-exportable device key; proves "this exact phone" |
| Certificate checks | **X.509 chain verify (pure Dart)** | Professor checks the phone's hardware certificate offline |
| Face match | **`face_verification` plugin (FaceNet + ML Kit)** | On-device face enrollment + 1-sec verify, fully offline |
| Anti-photo | **MiniFASNetV2 liveness model via `tflite_flutter`** | Rejects printed photos / screen replays |
| Secrets on phone | **`flutter_secure_storage`** | Hardware-backed vault for keys and install ID |
| App state | **`flutter_riverpod`** | Predictable state plumbing across screens |
| Local records | **`SharedPreferences` (JSON) + SyncEngine outbox** | Offline-first history + queued cloud sync |
| Phone glue | **`permission_handler`, `camera`, `wakelock_plus`, `google_mlkit_face_detection`, `connectivity_plus`, `share_plus`, `file_picker`, `package_info_plus`, `device_info_plus`** | Permissions, camera, keep-awake, pose check, sharing, version/device info |

---

## 3. User Flows

### 3.1 First-time setup (online, once)

**Student:**
1. Sign in with Google.
2. Enter ID number, generate device key (locked in secure chip).
3. Face enroll: 5 quick angles (Centre / Left / Right / Up / Down) — stays on phone.
4. Tap Save → cloud does an atomic "claim": this Gmail now owns this phone. Done — attendance works offline from here.

Rules worth knowing: one Gmail = one enrolled phone; moving to a new phone is allowed at most once per 30 days (prevents passing one account around); same phone re-enrolling is always free. Until a move date arrives, the professor marks you manually.

**Professor:**
Sign in, pick a display name. No face, no single-device limit. Can skip sign-in and host offline — classes just stay on that device until sign-in + sync.

### 3.2 In class — professor

1. Open a course → **Take attendance** → hosting starts (HTTPS up, class announced every 2s, IP shown).
2. Students land in the **waiting room** (live count).
3. Tap **Start** → window opens (no timer — stays open until Stop), Bluetooth starts shouting a new secret every 10 seconds.
4. Watch `present / waiting`, waiting list, manual requests. **Take another round** adds Round 2, 3… (Present = passed *every* round). **Retake** re-runs the same round with fresh secrets.
5. Tap **Stop** (short grace for proofs already on the wire) → **End attendance** → record saved on-device, hosting shuts down, all ports close. Export (per-session CSV, date-range matrix) happens separately from the course page.

### 3.3 In class — student (mostly automatic)

1. Open app, stay in foreground. Join by live list or by typing the IP on the professor's screen → waiting room.
2. When the professor starts, the app auto-continues to a face scan, then keeps proving on every fresh secret until a verdict lands: `✓ Marked`, `Late`, `Wrong org` (wrong institute — nothing sent), `No signal`, or `Needs review` (face didn't match → professor override path).
3. Stay put for the next round — the badge parks, then the waiting room reopens and the next mark appends (R1, R2…). A manual-request button is the fallback if radio truly can't reach you.

### 3.4 After class — records

Professors: course pages (sessions newest-first, per-round checkboxes, partial/absent lists, edits, exports, multi-delete). Students: My Attendance (course cards with `x/y days`, per-course session detail). Everything syncs to the cloud when internet returns. Web shows the same records with a "records view only" banner.

---

## 4. Each Technology — What, Why, Trade-offs, What It Prevents

Read each block the same way: **Does → Why this one → Good → Bad → Prevents.**

### 4.1 Flutter + Dart (whole app)

- **Does:** One language and UI toolkit compiles to Android, iOS, macOS, Windows, Linux, and Web from a single codebase.
- **Why:** A small team can't maintain 3–4 native apps; attendance logic must be identical everywhere.
- **Good:** Same protocol on every platform; fast UI; one test suite; web build falls out nearly free.
- **Bad:** Needs shims where platforms differ (BLE, camera, file save); app size is larger than pure native; platform quirks (e.g. Apple stripping BLE payload data) still leak through.
- **Prevents:** Logic drift — "Android marks but iOS doesn't" class of bugs; plus fail-closed behavior off-mobile (desktop/web *can't* mark instead of marking weakly).

### 4.2 Monorepo packages (`protocol`, `ble`, `transport`, `storage`)

- **Does:** Splits pure logic (crypto/math) from radio, network, and local records.
- **Why:** Pure-Dart crypto can be unit-tested fast with zero phone needed; radio/network can evolve without touching signatures.
- **Good:** Fast tests (1400+), clear ownership, web-safe conditional shims.
- **Bad:** More packages to version and keep in sync.
- **Prevents:** A WiFi bug breaking signature code; untestable spaghetti.

### 4.3 Firebase Auth + Google Sign-In (identity)

- **Does:** "Sign in with Google" gives a verified email + user ID. The org (institute) is derived from the email domain.
- **Why:** No passwords to manage, no custom user database; every student already has a Gmail; institute scoping falls out of the domain.
- **Good:** Free, familiar, works on all platforms; offline-persisted session.
- **Bad:** Tied to Google availability at enroll/sync time; Gmail ≠ verified human (a stolen Gmail enrolls the attacker's face — mitigated by one-device binding + professor review, not eliminated).
- **Prevents:** Fake typed names/IDs as identity; cross-institute joins (wrong-org gate refuses before any proof or personal data is sent).

### 4.4 Cloud Firestore + Security Rules + Indexes (cloud truth)

- **Does:** NoSQL cloud store for users, device bindings, directory, sessions. Security Rules are server-enforced "who can read/write what"; composite indexes make org-scoped queries fast.
- **Why:** Serverless — no backend server to run/pay for (Spark free tier); offline-first with sync-on-reconnect fits classrooms with bad internet.
- **Good:** Real-time sync, transactions (the one-device claim resolves races to exactly one winner), survives app kills via outbox + tombstone deletes.
- **Bad:** No custom server logic (no Cloud Functions on free tier — so no server-side attestation re-check); rules must be redeployed carefully; queries need pre-built indexes.
- **Prevents:** Double-enrollment races; one student rewriting another professor's sessions; cross-org snooping (org match + membership required); silent data loss (union-merge + idempotent replay).

### 4.5 `app_config/min_version` (force-update floor)

- **Does:** A tiny world-readable cloud doc says "minimum safe version". Old builds show a blocking update screen.
- **Why:** Crypto/face/rules breaks must retire old builds, otherwise attackers pin an old APK to bypass new gates.
- **Good:** No extra SDK; disk-cached so it enforces offline across restarts.
- **Bad:** A build that never goes online after the floor publishes can't know about it.
- **Prevents:** Downgrade attacks; cryptic `bad-sig` failures (replaced by clear "update" messaging).

### 4.6 App Check + Play Integrity + App Attest + `flutter_security_suite` (device integrity)

- **Does:** Asks the OS/Play/Apple "is this a genuine app on a genuine device?" plus local checks for root, Frida/Xposed hooks, emulator, re-signed binary, screenshots.
- **Why:** Defense in depth — the crypto still does the real work, but junk devices should be refused early with a clear message.
- **Good:** Blocks the easy fraud lab (emulators, rooted farms, repackaged APKs — repackaged builds crash at launch via cert pin).
- **Bad:** Local checks can be hidden by Magisk/Zygisk; iOS needs a paid Apple membership for full strength; web/Windows stay unregistered by design.
- **Prevents:** Emulator attendance farms; hooked `verify() → true` tricks; backup-restore clones (backups disabled, keys hardware-bound).

### 4.7 Bluetooth Low Energy via `universal_ble` (nearness proof)

- **Does:** Professor shouts a rotating secret; students listen and answer; front rows re-shout so back rows hear (controlled flood with TTL/jitter/dedup/split-horizon).
- **Why:** BLE range (~10–30 m) is the actual proximity sensor. Campus WiFi is routed across buildings — reachability over WiFi proves nothing about the room.
- **Good:** One plugin for all OSes; no extra hardware; covers 500-seat halls via relay.
- **Bad:** Apple stacks strip attached payload data (so Apple hosts fall back to alternating challenge/hint packets); radio needs foreground + Bluetooth on; thresholds need per-hall tuning.
- **Prevents:** Hostel/VPN proxy (you can't hear the 10-second secret from far away; a forwarded screenshot is already stale); back-row dead zones.

### 4.8 HTTPS via `shelf` + UDP discovery + TLS channel binding (bulk transport)

- **Does:** Professor runs a tiny per-class HTTPS server on the LAN; students POST signed proofs. UDP beacons + BLE IP-hint + typed IP help students find the class. Per-session certificate + channel binding ties the TLS pipe to the signature.
- **Why:** BLE has range but no bandwidth; WiFi has bandwidth but no locality. Each does what it's good at.
- **Good:** No internet needed; standard TLS; rate limits tame herds; honest failure (unreachable → manual path, never fake success).
- **Bad:** Some enterprise APs block broadcasts (falls back to BLE hint + typed IP); old unicast-sweep fallback was deleted because it kicked phones off WiFi.
- **Prevents:** Evil-twin AP relays (channel binding); replay floods (rate limits + single-use IDs); rogue-professor harvesting (student verifies professor signature + key pin *before* signing anything).

### 4.9 Ed25519 signatures (who signed what)

- **Does:** Fast public-key signatures. Students sign attendance proofs; professors sign challenges and receipts.
- **Why:** Small keys/signatures, very fast verification (~1000–2500 verifies per lecture is trivial), well-tested libraries.
- **Good:** Phone-friendly speed; deterministic; compact over radio/WiFi.
- **Bad:** Keys must be guarded (hence hardware sealing below) — math can't save a leaked key.
- **Prevents:** Forged proofs (unknown keys rejected offline); copied IDs without the key; tampered receipts (student checks professor's ACK signature).

### 4.10 HMAC-SHA256 (rotating secrets)

- **Does:** Derives the 10-second challenge `C_j`, per-student response token, and rotating radio alias from window secrets.
- **Why:** One secret per window can spawn unlimited unlinkable short tokens without new key exchanges.
- **Good:** Tiny (8 bytes on air), fast, deterministic for verifier, unpredictable for outsiders.
- **Bad:** Anyone who hears the secret can compute the current token — that's why freshness (17 s) + single-use + signatures wrap it.
- **Prevents:** Pre-play (future tokens never verify); linkability across lectures (rotating alias); replay (single-use `windowID + ID + j` + dedup cache).

### 4.11 SHA-256 (hashing)

- **Does:** Fingerprints keys, binds face/liveness tickets into signatures, derives opaque face IDs.
- **Why:** Standard, fast, one-way fingerprint.
- **Good:** Binds many fields into one short hash so signatures can't transplant across tickets.
- **Bad:** Not encryption — it only fingerprints.
- **Prevents:** Ticket transplant (old ticket hash won't verify under a new proof); raw Gmail leaking into the face gallery (hashed ID instead).

### 4.12 AES-GCM + P-256 hardware keys — StrongBox / TEE / Secure Enclave (this phone, really)

- **Does:** The attendance signing key (SKey) is sealed by a non-exportable device key (DKey) in the phone's secure chip. Every proof also carries a fresh hardware signature over the live challenge.
- **Why:** A file copy should be useless without the silicon. Software-only keys travel with their files.
- **Good:** StrongBox → FULL tier / TEE → STD tier / Secure Enclave → STD tier; restore/clone detected → re-enroll; offline-verifiable.
- **Bad:** Needs modern hardware; software/fake keys exist for tests only and never confirm (manual path instead); no server re-check on the free tier (professor's phone verifies the certificate chain offline).
- **Prevents:** Lent-phone marking (key won't unseal without a fresh face ticket); cloned-app fraud (ciphertext unwraps to nothing); tier lies (bad chain → `device-unproven` → manual path, never auto-present).

### 4.13 X.509 chain verify in pure Dart (trust without internet)

- **Does:** Professor's phone checks the student's hardware certificate chain against pinned Google/Apple roots, with challenge match + key binding + expiry checks — no network.
- **Why:** Classrooms are offline; there is no backend to ask. The check must run on the professor's phone.
- **Good:** No server bill; works in airplane-mode classrooms; snapshot revocation cache as a review flag.
- **Bad:** Snapshot-only revocation (true push revocation needs a backend); first-seen keys are trust-on-first-use with a visible banner.
- **Prevents:** Software keys claiming hardware tier; expired/forged chains confirming.

### 4.14 Face matching — `face_verification` plugin, FaceNet + ML Kit (holder proof)

- **Does:** 5-angle on-device enrollment; ~1-second single-shot verify at marking; gallery never leaves the phone. Match stamps a 5-minute ticket that unlocks signing.
- **Why:** The key proves the phone, radio proves nearness — face proves the holder. Vendored custom models were deleted in favor of one maintained plugin.
- **Good:** Fully offline, bundled model, fast; version-pinned so a model bump forces re-face instead of matching across versions.
- **Bad:** Needs good light; twins flag each other (one-tap professor resolve); operating-point numbers are the plugin's, not yet measured on Proximity captures.
- **Prevents:** Lent/unlocked-phone proxy (no match → no signature; mismatches burn attempts → needs-review queue, never auto-present). Same-face duplicates across two Gmails are flagged in-RAM on the professor's phone (vectors only, photos never leave; RAM wiped at window close; nothing face-derived reaches the cloud).

### 4.15 Liveness — MiniFASNetV2 via `tflite_flutter` (anti-photo)

- **Does:** Passive vitality score on every capture plus a shuffled blink/smile walk at enroll; graded score rides the signed ticket.
- **Why:** A matcher alone passes a photo held at each angle. Liveness raises the spoof cost.
- **Good:** Tiny model (~2 MB), on-device, strict threshold with graceful near-miss (inconclusive = free rescan, not a burned attempt).
- **Bad:** Threshold is field-relaxed and FAR/FRR are still unmeasured on real captures — re-tighten only via a measured field ROC shipped with a version bump.
- **Prevents:** Printed-photo / screen-replay fraud (must now beat vitality + face + ticket + radio gates together).

### 4.16 `flutter_secure_storage` (vault on the phone)

- **Does:** Hardware-backed vault (biometric Class-3 on Android, this-device-only on iOS, backups disabled) for keys, install ID, session state.
- **Why:** OS keystores beat any app-level hiding.
- **Good:** Survives restarts; clones/dual-apps get separate IDs (one enrollment per install enforced both client- and server-side).
- **Bad:** History/outbox JSON stays in plaintext prefs (rooted-read residual — the seal key itself never lives there).
- **Prevents:** Backup-restore identity theft; casual file-copy clones.

### 4.17 `flutter_riverpod` (state plumbing)

- **Does:** Predictable, testable state flow across landing → enroll → mark → live → records.
- **Why:** Live radio + timers + navigation is exactly where ad-hoc state explodes.
- **Good:** Guards (web/mobile/auth/role/enrollment) stay centralized; fake drivers make UI tests hermetic.
- **Bad:** Learning curve; misuse can still cause ref-read-after-dispose crashes (audited + guarded).
- **Prevents:** Wrong-screen states (desktop enrolling, web marking); stale-mode landings.

### 4.18 Local records — `SharedPreferences` JSON + SyncEngine outbox (offline-first memory)

- **Does:** Every round close and manual action upserts the same on-device record; drafts autosave per course and resume after app kill; cloud sync happens on reconnect with union-merge, tombstone deletes, idempotent replay, backoff.
- **Why:** Classroom WiFi is hostile; marks must never be lost because the network blinked.
- **Good:** Un-closed sessions still leave data; crash-safe; professor is the host-only source of truth for exports.
- **Bad:** JSON-in-prefs, not SQLite yet (fine at pilot scale, migration later).
- **Prevents:** Lost marks on kill/crash; double-counts on retry; queue-vs-tally races.

### 4.19 Phone glue — permissions, camera, keep-awake, sharing

- **What:** `permission_handler` (camera/Bluetooth/location prompts), `camera` (capture), `google_mlkit_face_detection` (pose gates per still — no extra battery, file-path only), `wakelock_plus` (screen stays awake in live windows), `connectivity_plus` (online probes), `share_plus` / `file_picker` / `archive` (CSV share/save), `package_info_plus` (version floor), `device_info_plus` (same-phone reclaim ID), `google_fonts` (bundled offline fonts).
- **Why each:** Each fills one OS gap the framework doesn't cover.
- **Trade-off:** More native surface = more version churn (e.g. permission_handler pinned off v13 until the Android-37 platform ships; iOS CocoaPods forced until a plugin fixes its SwiftPM manifest).
- **Prevents:** Silent radio failures (tappable Bluetooth prompts, deferred scans); lost proofs to sleeping phones; unjoinable classes (pose-gated angles, resumable drafts, copyable store links).

---

## 5. What Deliberately Isn't Here (honest limits)

- **No background auto-marking.** Foreground-only during windows on every OS — background promises would be lies the OS won't keep.
- **No server re-check of hardware certificates.** Free-tier constraint; professor verifies offline. Tiers are professor-verified, never server provenance.
- **No institute PKI / verified professor roles yet.** Professor registration is self-asserted, so directory reads are advisory and there is deliberately no self-service reset shortcut (it would let a student bypass the 30-day move bound).
- **No distance-bounding (UWB).** Two colluding phones with a live relay + live victim face across two full windows could still wormhole within 10 seconds. Cost is a dedicated accomplice present the whole lecture — far above casual proxy.
- **No biometric data in the cloud, ever.** Face vectors live in the professor phone's RAM for the open window only, then are wiped. The cloud carries only `PRESENT / ABSENT / FLAGGED`.

---

## 6. One-Paragraph Summary for Stakeholders

Proximity marks attendance by proving nearness (rotating Bluetooth secret), ownership (hardware-locked key), and holder (on-device face + liveness) in one offline classroom flow, backed by Google login and a serverless cloud database for enrollment and records. Old builds are force-retired, fake devices are refused early, and every failure lands on an honest verdict or the professor's manual path — never a fake success.
