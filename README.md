# Proximity — Campus Attendance System

Offline-first attendance over BLE proximity proofs + WiFi transport.
One Flutter app, two modes (Student / Professor). Foreground-only during
windows — no background-attendance promises on any OS.

Design source of truth: [`PROXIMITY_DESIGN.md`](PROXIMITY_DESIGN.md) v1.0.
Owner decisions taken during implementation intentionally override parts of
it; they are listed under [Decisions](#decisions-locked-during-build) with
rationale. Security level is identical on every OS — no per-OS weakening.

## How it works

**Enroll once (online):** Google sign-in → device Ed25519 keypair → on-device
face enrollment → upload `{email, name, ID number, PK, faceHash}` + signature
to Firestore `rosterKeys/{email}`. Identity is the Gmail account; the ID
number is user-entered and unverified display metadata. One device key per
email per 24h (client + Firestore rules). Keys and identity persist in secure
device storage — sign-in state survives restarts.

**In class (offline-capable):**
1. Professor opens a course (registered by name; renamable, sessions migrate)
   → **Take attendance** starts hosting: HTTPS server up (window closed) +
   class announced on the LAN every 2s, with the professor's optional display
   name. Students see it live under “Live on this WiFi” (or join by shown IP)
   and wait on “attendance has not yet started”.
2. Professor taps **Start #1/#2**: beacons flip live, students auto-continue
   to the face scan, then prove during the 30s window as below.
3. Each 30s window (6 × 5s sub-epochs): professor advertises rotating
   `UUID_P = BaseP64‖C_j`; students hear it over BLE, answer
   `UUID_S = BaseS64‖HMAC(C_j, email)`, pass the holder face check, and POST
   an Ed25519-signed proof with TLS channel binding. Professor verifies
   (freshness 7s, single-use `(email,j)`, signature, roster key, CRL, face
   score, BLE sighting with RSSI gates) and returns a signed ACK.
4. Front-row phones re-advertise challenges (TTL/jitter/dedup/split-horizon
   controlled flood) so back rows hear them. **End + Export** writes the
   signed CSV (`Name,ID Number,Email,W1,W2,Status`) to on-device course
   history with share sheet.

Why it holds: hostel joins never hear `C_j` over radio (30m, 5s rotation);
lent phones fail the holder face gate (SK stays locked); copied emails fail
signature verification; Evil-Twin relays fail TLS channel binding; replays
fail single-use + freshness. See design §7.3.

## Repo layout

```
apps/proximity_app/      single app: student + prof modes (Android/iOS/macOS/Windows/Linux)
packages/protocol/       pure Dart: HMAC/UUID pack, Ed25519, window timer, mesh PDU, dedup, face gate, verify
packages/ble/            BLE engine (rotation/relay/nextChallenge) + Linux BlueZ advertise shim
packages/face/           detection/embedding/liveness interfaces + SK gate (mock until EdgeFace file lands)
packages/face_detect/    first-party detector plugin: Apple Vision (iOS/macOS) / ML Kit (Android)
packages/transport/      shelf HTTPS server/client, per-session TLS + channel binding, LAN discovery, rate limits
packages/storage/        tally + course history (in-memory API; JSON prefs backing)
```

## Build, test, run

Prereqs: Flutter stable, Firebase CLI + flutterfire, Xcode (iOS/macOS),
Android SDK. Firebase project: `proximity-attendence`.

```bash
# per-package
cd packages/protocol && dart test
cd packages/transport && dart test          # incl. 500-hall load drill
cd packages/ble && dart test
cd apps/proximity_app && flutter analyze && flutter test

# Firebase (files live in requirements/ during setup)
cp requirements/google-services.json apps/proximity_app/android/app/
cp requirements/GoogleService-Info.plist apps/proximity_app/ios/Runner/
cd apps/proximity_app && flutterfire configure --project=proximity-attendence
firebase deploy --only firestore:rules --project proximity-attendence
# Android SHAs: cd android && ./gradlew signingReport  (paste into console)

flutter build apk --debug
flutter build ios --no-codesign        # needs iOS platform in Xcode
flutter build macos --debug
```

Simulator UI walkthrough without taps/accounts:
`flutter build ios --simulator --dart-define=PROX_MODE=student|prof|enroll|take`
(`take` opens a live take-attendance screen; enroll/classes seed demo data
via the `course`/`take` flags in `lib/main.dart`.)

## Decisions locked during build

1. **Single app, two modes** (not two apps). Prof/student switch in-app.
2. **Gmail identity, no roster/ID matching.** `roster.csv`/`roster.json`/`Sig_inst`
   flow removed; `rosterKeys` keyed by lowercased email; CSV has no institute-ID
   verification. `hd` domain forcing is a dormant one-line option.
3. **ID Number compulsory but unverified** display metadata (student-entered).
4. **Courses** group sessions (rename migrates history); **professor display
   name** optional, announced live; exports go through the share sheet;
   wakelock held during live windows on all OS.
5. **TLS**: per-hosting-session runtime cert (a cert cannot literally hash to
   `H(PK‖windowID)`); MITM resistance via **channel binding** (`tlsFp` +
   `sigBind` over the presented cert) verified server-side.
6. **Discovery via UDP broadcast** (`:54545`, 2s beacons, 6s expiry) instead of
   mDNS — same “live list + manual IP” UX, no extra plugins. mDNS may return.
7. **History in JSON prefs** (not SQLite yet); **mock embedding** until the
   EdgeFace-XS `.tflite` lands at `assets/models/`; **no biometric OS gate**
   yet (FaceGate logic enforced, Keystore/Enclave binding pending).
8. Present rule default 2/2 (`lenientOneOfTwo` per export call).
9. Prefixes: `BaseP64=9A3B7C1D4E5F6071`, `BaseS64=B7E4A9215C6D8093`,
   `PROX_SVC=6b9e4f22-…-9f01`, `PROX_CHR=6b9e4f23-…-9f01`. Exports are
   host-only source of truth.

## Real-class test checklist

- [ ] Professor hotspot (if AP isolates clients): students join hotspot IP.
- [ ] Two phones: full mark on `#1` and `#2`, export verifies.
- [ ] Back row: relay extends challenge (front-row phones keep app open).
- [ ] Adversarial: forwarded screenshot code, off-site VPN join, lent phone,
      airplane-mode BLE-off (expect honest no-signal, never fake success).
- [ ] Face tuning: threshold 0.60 starting point; `nRF Connect` walk-test for
      −70/−80 dBm gates per hall.

## Gaps / roadmap

- EdgeFace-XS weights file (blocks real recognition; loader + gate ready).
- GATT `PROX_SVC/PROX_CHR` server + directed response relay (client fallback ready).
- SQLite/drift backing, biometric key locking, per-course matrix export.
- Windows/Linux binaries via [CI](.github/workflows/build.yml) (macOS verified here).
