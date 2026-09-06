# Proximity — Campus Attendance System

Offline-first attendance over BLE proximity proofs + WiFi transport.
One Flutter app, two modes (Student / Professor) on
Android/iOS/macOS/Windows/Linux, plus a records-only web build.
Foreground-only during windows — no background-attendance promises on any
OS. Security level is identical on every OS — no per-OS weakening.

Design source of truth: [`PROXIMITY_DESIGN.md`](PROXIMITY_DESIGN.md).
This README describes the system as built.

## How it works

**Enroll once (sign in first).** One Gmail can hold both roles and the app
opens on the last-used mode — switch anytime from the home screens (back
goes to the landing hub, which offers every held role with the last mode
first). Professors register with a display name (Gmail default, any number
of devices); students enroll one device per Gmail — account (picked up
silently, no second tap) →
device Ed25519 keypair → on-device 5-angle face enrollment → online atomic
device claim (`studentDevices` + `deviceInstalls`, one transaction).
The claim enforces both sides: a Gmail enrolled on another phone refuses —
the screen names the exact re-enroll date (`You can re-enroll this device
on XYZ`) and the old device's last online day. Moves are unlimited over a
lifetime but at most one per 7 days; there is deliberately no reset
shortcut (professor registration is self-asserted, so any reset permission
would let a student self-reset around the wait). Until the date, attendance
comes from the professor's manual path: manual adds need only the ID —
online it resolves name/email from the directory, offline it queues and
applies on the next sync. An install already enrolled as another Gmail
refuses too (one phone holds one student enrollment; app clones/dual-apps
count as the same phone — wipe app data to switch identity). Same-device
re-keys and re-enrolls are always free. Student enrollment needs internet
exactly once (claim + role register); offline progress is kept for retry.
Every claim and every online re-sign-in heartbeats last-online.
The enrollment page needs no Google tap: it adopts the persisted session
in the background at start (token refreshed when online, proving live
account status); the sign-in button remains only for fresh installs with
no session — the claim binds to the Google identity, so it cannot run
unsigned.
Professors may skip sign-in: classes stay on that device only until sign-in
+ sync. Keys, identity and the install ID persist in secure device storage
— sign-in state survives restarts (account switches land on the landing
page, never someone else's home).

**In class (offline-capable, LAN-only):**
1. Professor opens a course (registered by name; renamable, sessions
   migrate, deletable with X/Y warning) → **Take attendance** starts
   hosting: HTTPS server up (window closed) + class announced on the LAN
   every 2s, with the professor's optional display name and all-IP picker.
   Students join by shown IP (single field, last IP prefilled) or live
   list and land in the **waiting room**: Connected / Not connected +
   “waiting for professor to start marking”. Presence heartbeats give the
   professor a live waiting count.
2. Professor taps **Start**: beacons flip live, waiting rooms
   auto-continue to the face scan (camera opens, radio pre-warmed so face
   + mesh overlap), then students prove while the window is open — it stays
   open until **Stop**, no countdown on either side. Live controls:
   **Stop** (ends acceptance after a short grace for proofs already on the
   wire), live `present/waiting` counter, waiting list, manual requests,
   direct manual entry. **Take another round** adds window 2, 3, … —
   present is the intersection of all windows taken. A stopped round can
   instead be resumed with **Retake round N** (same round number, fresh
   secrets, marks merge — no new intersection hurdle).
3. While open, the professor advertises a rotating challenge (new token
   every 5s, unbounded); students hear it over BLE, answer with their
   response token, pass the holder face check, and POST an Ed25519-signed
   proof with TLS channel binding. Professor verifies (freshness 7s,
   single-use `(email,j)`, signatures against the presented device key,
   face score, BLE sighting with RSSI gates) and returns a signed ACK,
   which the student sees as ✓ Marked.
4. Front-row phones re-advertise challenges (TTL/jitter/dedup/split-horizon
   controlled flood) so back rows hear them — each phone keeps relaying for
   20s after first hearing the token, never cutting at its own ACK.
   **Manual path (LAN-only):** students tap “Request manual attendance”;
   the professor sees a live request list (selective approve/reject +
   Select all) or uses the unified manual-add form (directory search with
   ID/name/email bars, ID compulsory, offline queue) — approved students
   are marked present and see the ACK. **End attendance** finalizes the
   class record (history saved, hosting down, draft cleared) — export is a
   separate feature: course pages offer per-session CSV plus calendar
   **date-range matrix export** (email primary key, P/A per session date,
   time disambiguates same-day sessions; warns when no classes took
   place) and multi-select session deletion with X/Y warning. Leaving the
   live screen ends hosting and closes all ports (HTTPS + UDP); nothing
   stays bound after the app closes — but marks are never lost: every
   round close (and every manual action) rewrites the SAME class record in
   on-device history, and the unsent tally autosaves per course and resumes
   on re-entry (even after a full app kill), with Take again continuing the
   window numbering. Saved sessions stay editable later from the course
   page (per-round checkboxes plus partial/absent quick lists).
   The course page also keeps the roster union: anyone seen in any session
   of the course reads as absent in sessions they missed (matching the
   matrix exports).

Why it holds: hostel joins never hear `C_j` over radio (30m, 5s rotation);
lent phones fail the holder face gate (SK stays locked); forged keys fail
signature verification under the presented key; Evil-Twin relays fail TLS
channel binding; replays fail single-use + freshness. Email is
self-asserted in this phase (a copier still needs the live challenge +
holder face on the claiming device) — verified identity returns with
institute-verified professor roles. See design §7.3.

Persistence notes: the student signs, announces and POSTs *every* fresh
challenge until a verdict lands (unheard responses, stale tokens and
loose-WiFi drops wait for the next rotation, never fail; refused means
wrong IP and fails fast); dead air ends the listen only after a window
probe confirms the round closed; repeat garbage that never verifies ends
it as no-valid-signal. The professor keeps accepting proofs for a short
grace after Stop (scan lingers in parallel), then the window hard-closes;
Bluetooth-off gets a tappable Turn-on prompt on both entries (never a
log-only failure); a scan started while the radio is off defers and
restarts itself when Bluetooth powers on (Turn-on retries at once,
Settings-enable is picked up by the engine poll). Relay/RX repeats log
once per packet — the terminal stays readable mid-session. Beacons log on
targets-change, else every 10th live / 5th idle. Every HTTPS connect is
bounded (enterprise WiFi blackholes SYNs without RST — an unbounded
connect used to stall a prove mid-flow with zero log lines); timeouts are
transient, so the next rotation retries. A platform scan that dies
silently while reporting active is re-armed every quiet 15 s spell while
listening; the UDP listener falls back when reusePort is unsupported
(Android), so beacon discovery works there too. The student response
waits for the radio instead of skipping under relay load (a skipped
answer used to log success and guarantee no-ble-sighting); a
crypto-valid POST whose sighting hasn't landed yet waits up to 4 s for
the scan instead of instantly failing, so marking no longer depends on
WiFi-vs-BLE arrival luck. Marked students stay for the next round with
zero taps: the badge parks until the round ends (same window never
re-faces — the next window carries a fresh code), then the waiting room
reopens, face re-checks, and the next mark appends to the per-round trail
(R1, R2, …) shown on the waiting AND marked/late cards; the professor
list shows the same ticks per student (Present intersection + Partial
sections, e.g. `R1 ✓ · R2 ✗`). Rounds are noted at Stop (not after the
grace), so empty rounds still count and the intersection never sticks at
1/1 after 2 rounds. Browsing re-arms a scan that went
silent for 30 s, so a class started after the student opened the app
still lists.

**Records.** Professors: course pages (sessions newest-first, per-session
`Partial (n)` one-liners, exports, date-range matrix, multi-delete),
saved-session editor (per-round checkboxes, partial + absent quick lists
with mark-present, unified manual-add, queue resolution on sync).
Students: My Attendance (course cards with `x/y days attended` → per-course
detail with totals header, progress, session tiles; device-only hide).
The web build is records-only (see below).

## Web records build

`flutter build web` produces the same app, same login, records only: no
BLE, no camera/face, no hosting, no enrollment, no manual edits. Students
land on My Attendance; professors get courses/sessions/exports (CSV Save
downloads in-browser); every records screen carries a “records view only —
marking needs the native app” banner. Native-only affordances (Take
attendance, retake, rename/delete, session toggles/add/save, offline
professor, role registration) are hidden on web.

Setup left (the Firebase web app is already registered —
`firebase_options.dart` carries the web config): add the site + localhost
to Firebase console → Authentication → Settings → Authorized domains
(else the Google popup is refused), then publish:
```bash
cd apps/proximity_app
firebase init hosting   # when ready to publish
firebase deploy --only hosting --project proximity-attendence
```
Web sign-in uses Firebase Auth's Google popup (`signInWithPopup`) — the
`google_sign_in` plugin has no client-ID path on web (it asserts on a
`<meta google-signin-client_id>` tag), so no OAuth client ID or meta tag
is needed. Closing the popup counts as abort, same as backing out on
mobile. Student sign-in on web skips the device binding gate (that
install is never the enrolled device — the check would refuse legit
students) and lands straight on records; student registration stays
native-only.
Web platform seams (all compile-neutral on native): conditional exports
for transport client/discovery/server, BLE BlueZ shim, TFLite
(EdgeFace/BlazeFace) runtimes, file saving, and interface enumeration;
`platformx.dart` replaces `dart:io Platform`; protocol prefixes are built
from 32-bit halves (a >2⁵³ literal cannot compile to JS — values are
bit-exact on 64-bit native, untouched by web which never runs radio
crypto). `flutter build web` is the guard: any new native-only import in
the shared closure fails it loudly.

## Firestore data + rules

Collections (`apps/proximity_app/firestore.rules` — deploy with
`firebase deploy --only firestore:rules --project proximity-attendence`):

- `users/{uid}`: `{email, roles[prof|student], lastMode}` validated
  (name/displayName pass through unvalidated) — one doc per Firebase uid;
  the same Gmail can
  hold BOTH roles (professor multi-device, student single-device).
  `lastMode` is the last-used mode (landing + relaunch default). Owner
  read/write only; roles merge (array union), never overwrite. Email
  comparisons are case-insensitive on both sides (rules `lower()`).
- `studentDevices/{emailLower}`: `{email, uid, pkHex, installId, name,
  roll, modelVer, platform, createdAtMillis/lastMoveAtMillis/lastSeenAtMillis/updatedAtMillis,
  moveCount}` — one enrolled student device per Gmail. Same-install
  re-keys free; moves need the 7-day cooldown (server-enforced; a bare
  pkHex match from another install is a move, not the same device);
  pre-timestamp docs migrate once. Claimed in one transaction
  (`studentDevices` + `deviceInstalls` + directory row) so racing devices
  resolve to exactly one winner. **No delete for anyone** (reset would be
  self-service while professor registration is self-asserted).
- `deviceInstalls/{installId}`: `{email, pkHex, updatedAtMillis}` — one
  student Gmail per app install (secure-storage UUID; clones/dual-apps get
  their own). Unguessable ids; writes bound to the signing-in Gmail.
- `studentDirectory/{emailLower}`: `{email, name, roll, nameLower,
  updatedAtMillis}` — minimal professor-searchable directory, maintained
  by the claim transaction. Prefix search on ID/name/email (single-field
  range queries merged client-side, no composite index). Professor reads
  are **advisory** until professor roles are institute-verified.
- `classSessions/{sessionId}`: `{courseId, courseName, classLabel, profUid,
  profEmail, profName, dateIso, timestampIso, startIso, windows, names,
  rolls, studentEmails[], updatedAt}` — professors own their sessions;
  students read sessions listing their Gmail (lowercased both sides).
  Create validates profUid/profEmail + courseId/studentEmails/names/rolls
  types; readers coerce numeric names/rolls to strings. Single-filter queries, sort
  client-side, no composite index. Doc ids are lowercased Gmails throughout;
  rules compare `lower()` on both sides so mixed-case accounts work.

Timelines: device moves unlimited lifetime, ≤1 per 7 days, exact
re-enroll date shown with the old device's last-online day; same-install
re-key/re-enroll always free; first bind always free; manual attendance
covers any gap; offline manual adds queue and resolve on the next course
sync (live drafts excluded so the queue never races the tally).

## Repo layout

```
apps/proximity_app/      single app: student + prof modes (Android/iOS/macOS/Windows/Linux) + web records
  lib/core/              auth, cloud_sync (roles/claim/directory/search), device_store, device_identity,
                         enrollment, face_camera/detect/edgeface (+ web/native splits), ble_radio,
                         host_driver, student_driver, platformx/net_if/file_saver (web-safe shims)
  lib/screens/           landing, courses, course_detail, session_edit, take_attendance,
                         student_home, enrollment, face_capture, my_attendance, student_course
  lib/widgets/           manual_add (unified form + offline queue), partial_list (roster/partial pure),
                         course_attendance (student summaries), web_banner,
                         ble_log_view, ip_join, clock, animated
  web/                   records build shell (title/manifest set)
packages/protocol/       pure Dart: HMAC/UUID pack, Ed25519, window timer, mesh PDU, dedup, face gate, verify
packages/ble/            BLE engine (rotation/relay/nextChallenge) + Linux BlueZ advertise shim (+ web stub)
packages/face/           detection/embedding/liveness interfaces + SK gate (mock adapter for tests/web)
packages/transport/      shelf HTTPS server/client, per-session TLS + channel binding, LAN discovery, rate limits
                         (+ web API stubs; pure types shared)
packages/storage/        tally + course history + roster helpers (in-memory API; JSON prefs backing)
```

## Build, test, run

Prereqs: Flutter stable, Firebase CLI + flutterfire, Xcode (iOS/macOS),
Android SDK. Firebase project: `proximity-attendence`. Suite status:
protocol 57 · transport 32 · ble 30 · storage 9 · app 163 — green,
`flutter analyze` clean, `flutter build web` green. Verified 2026-09-06:
`flutter build macos`, `flutter build apk`, `flutter build ios
--no-codesign` all green (CI runs protocol/transport/ble unit tests only;
storage/app/web/native builds verify locally).

```bash
# per-package
cd packages/protocol && dart test
cd packages/transport && dart test          # incl. 500-hall load drill
cd packages/ble && dart test
cd packages/storage && dart test
cd apps/proximity_app && flutter analyze && flutter test
flutter build web --no-pub                  # records-build guard

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
(`take` opens a live take-attendance screen seeded with demo courses;
`prof`/`take`/`course` seed demo data via `_debugSeededStore` in
`lib/main.dart`; routing flags live in `lib/mode.dart`.)

## Decisions locked during build

1. **Single app, two modes** (not two apps). Prof/student switch in-app;
   web adds a records-only third face with the same login.
2. **No roster — cloud syncs sessions, not keys.** Attendance never
   consults a key list. Students verify with presented device keys
   (trust-on-first-use per class); whoever proves presence over radio
   lands in the per-course union. `hd` domain forcing is a dormant
   one-line option. Cloud holds multi-role `users`, one-device
   `studentDevices` (+`deviceInstalls`, `studentDirectory`) and
   `classSessions` backups (offline-first, local history stays source of
   truth) — key sync, revocation and signed exports remain future work.
3. **ID Number compulsory but unverified** display metadata
   (student-entered; the only compulsory manual-add field).
4. **Courses** group sessions (rename migrates local history AND cloud
   copies); **professor display name** registered at sign-in (Gmail
   default), announced live; exports share or save to the device CSV
   (download on web); wakelock held during live windows on all OS.
5. **TLS**: per-hosting-session runtime cert; MITM resistance via
   **channel binding** (`tlsFp` + `sigBind` over the presented cert)
   verified server-side.
6. **Discovery is passive** (UDP beacons `:54545`, 2s beacons, 6s expiry)
   **+ BLE IP hint + typed IP**, instead of mDNS — same “live list +
   manual IP” UX, no extra plugins. mDNS may return. The old unicast
   `/24` sweep fallback is **deleted**: 254 rapid TCP+TLS probes kicked
   phones off enterprise WiFi. On APs that suppress broadcasts, classes
   surface via the BLE hint (Android/Linux profs publish `host:port` in
   the air packet; students background-probe and list answerers with
   zero taps) or by typing the IP from the professor's screen (last IP
   prefilled).
   **BLE IP hint:** Android/Linux profs publish `host:port` inside the
   primary v2 air packet (`FCD2` + `0xFFFF`/`PX 02` manufacturer payload,
   18 B: token + IPv4 + port — `packages/protocol/lib/src/air.dart`); browsing students
   background-probe hinted hosts and list answerers in ~2–4 s (no taps,
   no verification of the hint itself — joining still enforces radio +
   signature + face). Apple stacks displace attached manufacturer data
   out of the primary packet (confirmed live 2026-09-05: Mac `FCD2`+mfg
   arrives on Android as UUID-only, the mfg half in no callback at all —
   not a split packet, so no merge cache can recover it), so Apple profs
   alternate legacy v1 challenge ticks with server-address hint ticks
   (`BaseI64` — IPv4 + port beside the discriminator; the 8-byte
   challenge itself is never truncated, crypto untouched).
7. **BLE is dual-format v2 + legacy v1, unfiltered scan.** The air packet
   (v2, `packages/protocol/lib/src/air.dart`) is fixed `FCD2` + 18 B manufacturer payload
   (`PX 02`, type, token8, IPv4, port — 29 B total in the PRIMARY
   advertisement on every platform, no scan-response dependence).
   Android/Linux originate v2; Apple/Windows originate legacy v1
   single-UUID ticks alternating challenge and server-address hint
   (`BaseI64`/`packIpHint` — IPv4 + port in the low 8 bytes, so
   Apple-originated classes are joinable with zero taps despite the
   displacement). Students parse all formats;
   relays preserve the heard format (`expectedAirKey`/`expectedUuid`
   match). Scanning is unfiltered with in-app parsing (`AirParser`).
   Verified live 2026-09-05 Mac↔phone: phone→Mac v2 heard on bleak with
   5 s token rotation (RSSI −41…−54); Mac→phone v2 arrives UUID-only
   (`air FCD2 without v2 payload`, mfg in no callback); Mac→phone v1
   parses (`RX challenge v1 tok=01020304… rssi=−57`); no-ADV control
   stays silent (no own-ADV loopback, no phantoms).
8. **Live refresh + explicit leave.** Browsing recomputes the merged
   (beacon/BLE-hint) list every 2 s; unacked entries vanish on the 6 s
   expiry, while hinted hosts that answered a TCP probe persist up to
   120 s (re-probed every 15 s) so the class survives the round end —
   tapping re-validates through the waiting room. Pull-down refreshes
   instantly from local state (no network
   scan of any kind). Leaving the waiting room POSTs `/leave` so the
   prof count/view drops within ~2 s (logged as `waiting -email`).
9. **History in JSON prefs** (not SQLite yet); **EdgeFace-XS TFLite vendored**
   at `apps/proximity_app/assets/models/edgeface_xs.tflite` (see Face model
   provenance below); **no biometric OS gate**
   yet (FaceGate logic enforced, Keystore/Enclave binding pending).
10. Present rule: single window by default; each “Take another round” adds a window and
   Present = intersection of all windows taken (`lenientOneOfTwo` per export
   call preserves the old any-window mode).
11. Prefixes: `BaseP64=9A3B7C1D4E5F6071`, `BaseS64=B7E4A9215C6D8093`,
    air `FCD2`/`0xFFFF`/`PX 02` (v2; scan filtering uses the 16-bit
    `FCD2` service — the old `PROX_SVC`/`PROX_CHR` GATT UUIDs are
    deleted). Exports are
    host-only source of truth. (Built from 32-bit halves in code: a >2⁵³
    literal cannot compile to JS; bit-exact on 64-bit native.)
12. **Announce IP is WiFi-first and self-healing.** Cellular interfaces
    (`rmnet`/`ccmni`/…) score below WiFi in `lanAddressCandidates` /
    `bestLanAddress`, and every window open re-resolves NICs
    (`refreshAnnounceIps`, logged `announce IP refreshed`) so a WiFi DHCP
    that completes after hosting started heals before beacons + air
    packets go out — verified live 2026-09-05 (stale cellular
    `10.148.50.125` announced until the fix; now `10.50.37.76`).
13. **Local-first class records; End ≠ Export.** Every round close (and
    every manual action) upserts the same history record, so un-closed
    sessions still leave data; **End attendance** finalizes + clears the
    draft with no export step. Export (per-session CSV, date-range matrix)
    lives only on the course page; saved sessions stay editable there.
    Course union = everyone marked in any round of the class; roster =
    union over the course's sessions (newcomers read as absent earlier —
    no roster schema needed, the data already rides on sessions).
14. **Manual-add is one form.** Live direct entry and session edit share
    `ManualAddForm`: ID compulsory, online exact-ID resolve, offline queue
    applied on next course sync (live drafts excluded). Course cards show
    one-line `Partial (n)` markers; the full partial + absent lists live
    on the edit page with mark-present actions. Live search: 400 ms
    debounced, online-gated (presence probe cached 15 s), one round trip
    of parallel single-field prefix range queries (roll / nameLower /
    email, `limit(10)` each, merged by email, capped at 10 — single-field
    only, no composite index; worst case ~30 doc reads per pause plus one
    cached probe read per 15 s; search failures are SHOWN (rules-denied
    names the redeploy, offline shows the queued note) — a denied query
    no longer looks like "no students". Empty results say so explicitly.
    The name field waits for 2 chars (a 1-char name prefix returns the
    first 10 names alphabetically — noise that still bills reads);
    ID/email fire at 1 char. Stale generations are dropped so a slow
    earlier query never overwrites newer keystrokes. Re-adding someone
    already present (intersection) notes "Already marked present." —
    partials still go through.
15. **No personal fixture data.** Tests/seeds/docs use the Student
    One/Two + `student@example.com` family; single-letter/number fixtures
    carry no personal data.

## Robustness notes (audit)

- Races closed: device claim is one transaction (second device loses);
  role registration unions (no lost update); queue resolution is
  single-flight, re-checks live drafts and pushes resolved ids explicitly
  (a plain id-diff merge would skip them); manual-add search drops stale
  generations (slow query never overwrites newer keystrokes); enrollment
  finalize drops only the weakest slot (no whole-set wipe); the enroll
  camera stays open until requested angles clear (3-fruitless-round bound,
  Cancel always exits — a camera exit means success or the holder's own
  Cancel); single-flight autosaves, single-flight hosting/prove/queue
  (`_starting`, `_listening`, `_hostingBusy`, `_resolvingQueue`);
  rename-course batches recreate after each 400-commit (batch reuse throw);
  landing caches the role future per email (no refetch per rebuild);
  student hint retries are tracked timers cancelled on dispose; prof
  ADV-start failure unwinds the half-open window + scan.
- Same-install rule: the install is the device identity everywhere
  (client verdict + server rules mirror); a bare pkHex match from another
  install is a move. Heartbeat touches stay lenient (timestamp only).
  Corrupt local templates fail soft (empty vector → inconclusive/
  recapture, never a throw); corrupt seeds fail as terminal receipts;
  numeric names/rolls coerce to strings on read. Email identity is
  lowercased on both client and rules sides. Dead code removed:
  `MarkResult`, `simpleStatus`, `flagFace`/`faceFlags`, `decisionFromCode`
  (unused); unused deps dropped (`cupertino_icons`, `cryptography`,
  `meta` ×5, app-direct `dbus`); web `postLeave` stub throws like its
  siblings. Raw `writeStudentDevice` (claim bypass) throws —
  enrollment goes through `claimStudentDevice` only.
- Navigation safety: landing post-await mode switches go through a
  mounted-guarded `_goto` — the mode flip unmounts landing mid-flight, so
  a bare `setMode(ref, …)` after an await is a ref-read-after-dispose
  crash (seen on macOS). All other screens read providers synchronously
  or inside try/caught blocks; audited, no other uncaught site.
- Accepted risks, stated: enroll-then-crash between claim and local write
  strands the key until the cooldown (millisecond window); two colluding
  phones with live relay + victim face can still wormhole within 5 s
  (needs an accomplice present both windows; UWB would close it);
  printed-photo face fraud can pass (fix is video liveness, not stills
  heuristics); directory professor-gate is advisory until roles are
  institute-verified.
- Simplifications applied: manual-add is one widget (the separate search
  widget is deleted); edit-page save preserves `startIso`; course cards
  carry one-line partials (big section removed); legacy pk-only binding
  helper deleted; `dart:io Platform` replaced by `platformx`; CSV saving
  and interface enumeration are conditional shims.

## Real-class test checklist

- [ ] Professor hotspot (if AP isolates clients): students join hotspot IP.
- [ ] Two phones: full mark on `#1` and `#2`, course-page export verifies.
- [x] Back row: relay extends challenge — verified live 2026-09 (Mac advertises
      challenge, phone re-advertises it, Mac sees phone's relay at −43 dBm;
      split-horizon + 20s linger logged in the system log).
- [ ] Adversarial: forwarded screenshot code, off-site VPN join, lent phone,
      airplane-mode BLE-off (expect honest no-signal, never fake success).
- [x] BLE air matrix — verified live 2026-09-05 (institute WiFi,
      Mac `2C:CA:16:74:D0:05` + `SM-A528B`): phone→Mac v2 `FCD2`+mfg with
      rotation on bleak; Mac→phone v2 UUID-only (Apple displacement, no
      split — v1 fallback stands); Mac→phone v1 `RX challenge v1`
      (rssi −57); no-ADV control silent.
- [x] LAN discovery on isolating AP — verified live 2026-09 (institute /18:
      broadcasts 0/5 variants, so listing flows through the BLE IP hint
      and typed IP + Rejoin; the /24 unicast sweep was deleted after it
      kicked phones off WiFi).
- [x] Live refresh + leave — verified live 2026-09 (`/leave` drops prof
      count 1→0 with `waiting -email` log; sweep-hit expiry removes stopped
      classes via the 6 s refresh).
- [ ] Phone→phone BLE IP-hint listing (unit + TX-air verified; needs a
      second Android on hand: prof hint `0xFFFF/PX 02` decodes to host:port;
      Mac bleak already confirms the bytes survive the air intact).
- [ ] Face tuning: threshold 0.60 marking / 0.70 within-pose enroll /
      0.50 centre-vs-sides hold-out / 0.35 cross-pose floor starting points; yaw gates grounded
      ±0.12 frontal spread; `nRF Connect` walk-test for
      −70/−80 dBm gates per hall.
- [ ] macOS sign-in + camera on-device (entitlements merged, native SDK
      pinned to 7.0.0 — rebuild and run: ALLOW the keychain prompt, delete
      any stale `auth` item in Keychain Access if it still fails; then
      Google sign-in, face enroll, host a window).
- [x] Firestore rules deployed 2026-09-06 (`firebase deploy --only
      firestore:rules --project proximity-attendence` — released, compiles
      clean) + drill still to run: second student device refuses (re-enroll
      date + last-online + manual pointer); stale (>7d) moves; same-phone
      second Gmail (incl. clone) refuses; directory ID/name/email search;
      offline ID queue resolves on sync; partial + absent edit lists;
      student course totals match exports; rename/delete converge; offline
      edits sync on reconnect.
      NOTE: rules changed since the 09-06 deploy (install-anchored same
      device, no deletes, directory reads) — redeploy before the drill.
- [ ] Web records: authorized domains → Google-popup sign in → student
      course totals + prof course/session/CSV views; native actions hidden
      with the download banner.
- [ ] Windows/Linux: confirm offline-professor start (no Firebase crash)
      and the plain-language sign-in limit.
- [ ] Face scan UX in a real classroom: preview bright and true-ratio in
      low light with only a thin oval marker, lighting gate rarely
      false-triggers (tune `kDarkFrameLuma` / `kBrightFrameLuma`),
      sharpness gate passes soft cabin light but rejects mush (tune
      `kMinSharpness`).

## Face scan UX

`FaceCaptureScreen` (shared by enrollment + marking) runs a continuous
still-analysis loop, lock-screen style, over the stock camera view at its
true ratio (loose constraints — tight ones squash it) with a thin oval
framing marker drawn inside the preview itself (outline only: no dimming,
glow, or filtering; capture always used the raw stills). Each still runs
the BlazeFace face gate (box + 6 keypoints, geometric sanity) +
on-device lighting gate (`estimateBrightness`, pure `analyzeFrame`) +
motion-sharpness gate (`estimateSharpness`: rejects streaked mush, keeps
soft-but-usable faces) → streak-of-2 good frames auto-accepts a still
with zero taps (no photo confirmation step). On the marking flow the scan
starts by itself the moment the face step appears (Samsung-style, zero
taps; the Scan button stays as fallback/retry). The holder's head stays
exactly still throughout — no head turns, no blink/gaze tests (motion
blur and pose spread are what tank genuine similarity; still frames match
at ~0.95, and sparse ~1s-spaced stills cannot reliably catch a 200ms
blink — that gate blocked legit users, so it was removed). Anti-spoof is
accordingly modest: geometric sanity + sharpness + stillness make
 opportunistic photo fraud hard, and the mismatch budget (4 mismatch
 sessions, then needs-review; `FaceGate` instant-retry cap
 `kFaceMaxRetries=2`),
needs-review queue with professor check, server-side 0.60 gate, and
pipeline versioning sit behind it — but a good-quality printed photo CAN
pass, stated plainly. If photo fraud appears in the pilot, the fix is a
video-stream liveness (30fps blink/attention) or a spoof-classifier
model, not another stills heuristic. Marking runs a 12s verify session
at a fast 350ms cadence: every accepted still is checked live with score
feedback and a countdown — any one pass pops at once, so a single bad
frame never exits the camera nor burns a retry. A dead session pops its
 failures together and burns exactly one of the 4 mismatch sessions; empty rounds
 auto-retry twice and unreadable verdicts auto-relaunch twice (Cancel
 always exits, never burns). Poor frames fail closed as inconclusive
 (the embedder itself enforces the quality gates, so garbage can never
 score into a mismatch). Enrollment is one tap, one camera page: a guided
 5-angle scan (Centre / Left / Right / Top / Bottom — slight turns only,
 ~10–20°, head near-frontal throughout; see `enrollSlotNames` in
 `lib/core/enrollment.dart`)
  with live yaw-zone gates plus pitch gates (`face_detect.dart`: Top/Bottom
  validated by their own 0.70 within-slot pair + the 0.35 global floor;
  pitched embeddings foreshorten under the similarity warp, so Top/Bottom
  stay OUT of the hold-out mean below)
  (each angle must clear 0.70, shown live in the single top instruction
 line with what's remaining) and a progress bar — the template is the
 normalized mean of all five slot means (pose-robust, Face-ID style). The
camera stays open until the requested angles clear (bounded rounds, Cancel
always exits with completed sections) — a mismatched angle never pops
partial and forces a re-tap, and a camera exit means success (or the
holder's own Cancel). A
repeat tap scans ONLY the missing slots (`missingSlots`): completed
angles are never re-captured nor overwritten, titles show the remaining
angles, and returned pairs map back by missing index — so there is no
  "Section 4" and no lost progress. Consistency is checked at two
  measured levels: within an angle every pair must agree (bar 0.70 —
  same-pose frames are near-duplicates ~0.95+; a 0.65 same-pose pair is a bad
  frame, and only that angle is dropped for a targeted rescan, others kept), and
  across angles the odd-ones-out rule applies (global bar 0.35 — below
  measured same-person turned pairs at 0.50+, far above strangers ~0.0):
disagreeing angles are rescanned alone, and with no agreeing pair at all
only the single weakest slot drops — a finalize failure NEVER wipes the
set, key always kept.
Final hold-out checks
 the CENTRE frame against the mean of the LEFT+RIGHT slot means at 0.50
 (`kEnrollHoldoutMin` — symmetric
  yaw cancels toward frontal; cross-pose same-person reads 0.50–0.57
  measured, strangers ~0.0, and 0.50 keeps full
  impostor separation; Top/Bottom join the saved template but stay out of
 this mean — a weak hold-out
 drops only the
weakest slot for a targeted rescan in good light). A bad scan can
therefore never force a full restart nor advance to save. Every accepted frame is similarity-aligned
 to the EdgeFace 112×112 canonical frame before embedding — no more
 center-crop guesswork. Only a confident mismatch — a readable session
 matching somebody else — consumes one of the 4 mismatch sessions (`FaceMatch.mismatch`
→ needs-review with retries left); bad light/angle/blur just keeps
scanning inside the session and never burns an attempt. Enrollment is fail-closed too: a
failed capture stores no template and keeps score 0, so the UI stays on
the Scan step and save stays blocked — a bad scan can never skip ahead
to "enrolled". Save stays disabled until all five validate, and the
controller re-validates (partial scans report angles-left).

## System log (toggleable terminal)

Every live screen carries a **Show system log** toggle rendering the same
`BleLog` stream in a terminal window (black, monospace, color-coded tags,
autoscroll, 500-entry ring buffer, clear button):

- Student: browsing (browse/list), waiting room, face scan, listening radar,
  marked/late/no-signal verdicts. Face-scan screen too (radio keeps
  listening under the camera UI).
- Professor: take-attendance screen (above the waiting list).

Tags: `BLE` (scan start, ADV on air/failures, RX challenge/response with
RSSI, IP-hint heard/probe/listed, `air FCD2 without v2 payload` /
`air mfg FFFF without FCD2 svc` air-visibility probes), `MESH` (relay armed, forwarding, relayed,
skip reasons: TTL/weak/dup/split-horizon — the disarmed steady state stays
silent), `LAN` (HTTPS up, announce IP,
broadcast targets, beacon sent, beacon heard/new, presence, leave, manual,
waiting joins/leaves), `SEC` (face score,
signing), `NET` (window fetch, token sent,
ACK verdicts). Silent radio failures were the original mesh bug — nothing
in this path fails silently anymore. Every entry is also mirrored to
`adb logcat` (`I/flutter`) so live radio tests can be grepped after the
fact (the on-screen ring autoscrolls).

## Gaps / roadmap

- GATT `PROX_SVC/PROX_CHR` server + directed response relay (client fallback ready).
- SQLite/drift backing, biometric key locking.
- Institute-verified professor roles (turns the directory gate from
  advisory to enforced; enables a safe reset path).
- App Check (Play Integrity / App Attest) against tampered clients.
- CoreML `.mlpackage` export of EdgeFace-XS for iOS ANE acceleration
  (TFLite path works on both OS today).
- Windows/Linux binaries via [CI](.github/workflows/build.yml) (macOS verified here).

## Face model provenance

Two vendored TFLites under `apps/proximity_app/assets/models/`, both run
fully on-device (no photo ever leaves the phone):

`blaze_face_short_range.tflite` (224KB, float32, NHWC `[1,128,128,3]`
RGB `[-1,1]` in → 896×16 boxes + 896×1 scores out) is MediaPipe's
BlazeFace short-range detector
([google-ai-edge/mediapipe](https://github.com/google-ai-edge/mediapipe),
Apache-2.0). Loader + SSD decode (fixed-size anchors, sigmoid, weighted
NMS) + similarity alignment live in `lib/core/face_detect.dart`.

`apps/proximity_app/assets/models/edgeface_xs.tflite` (7.1 MB, float32,
NCHW `[1,3,112,112]` in → `[1,512]` out) is EdgeFace-XS γ=0.6 (1.77M params,
LFW 99.73%) exported from the official PyTorch weights
([otroshi/edgeface](https://github.com/otroshi/edgeface),
`checkpoints/edgeface_xs_gamma_06.pt`) with `litert-torch` (`torch.export`
on a 1×3×112×112 sample). Loader: `lib/core/edgeface_native.dart`
(`EdgeFaceEmbedder`); cosine gate 0.60; preprocessing RGB
`(x-127.5)/127.5` with L2 normalization after inference.

Verification (2026-09-05, `tmp_edgeface/` scratch dir, since removed):
worst cosine 0.99999994 vs the ONNX reference over 5 random inputs
(max abs diff 1.9e-07); zero custom ops; invokes under the XNNPACK
delegate; end-to-end Dart check (`flutter test test/face_wiring_test.dart`)
proves `main.dart` injects the loaded real embedder into enrollment +
student drivers, an unloadable model fails closed (error phase /
inconclusive verdict, SK never signs), and the no-camera demo bytes can
never embed. (Note: a direct `edgeface_xs_gamma_06.onnx → onnx2tf`
conversion was rejected — the flatbuffer backend emitted a numerically
broken graph and the TF backend fails on the model's depthwise layout —
hence the PyTorch route.)

Identity separation, end-to-end through the SHIPPED pipeline
(BlazeFace detect → similarity warp → EdgeFace TFLite, measured 2026-09-05
in `/tmp/facecheck`, public portraits Obama×2 + Biden): same person
**0.80**, strangers **−0.05/+0.04** — wide margin around the 0.60 gate.
This measurement caught a real bug: the inverse warp had flipped
off-diagonal signs, invisible on frontal faces (b≈0, all prior checks)
but shifting tilted faces by tens of pixels — with the bug the same
matrix read genuine 0.21 vs impostor 0.56 (false accepts, e.g. 0.79 in
the field). Fixed in `alignFace`, locked by the tilted-landmark warp test
in `test/blazeface_test.dart`, and all on-device templates stamped with
`kFacePipelineVer` (`edgeface-xs-g06-tflite-alignfix1`): stale templates
force face recapture (key kept) instead of matching across versions.

Verification (2026-09-05, `tmp_blaze/` scratch dir, since removed):
BlazeFace decode reproduces factory geometry on real portraits (tight box
+ keypoints on features; 0.6ms inference desktop CPU); alignment reaches
0.94 cosine parity with the SCRFD-based reference alignment on the same
photo; Dart port covered by `test/blazeface_test.dart` (anchors, decode,
weighted NMS, similarity recovery, warp, sanity, yaw).

To regenerate EdgeFace:

```bash
git clone https://github.com/otroshi/edgeface.git tmp_edgeface/edgeface-torch
/opt/homebrew/bin/python3.12 -m venv tmp_edgeface/venv
tmp_edgeface/venv/bin/pip install torch timm litert-torch torchao onnxruntime
# load get_model('edgeface_xs_gamma_06') + checkpoint, torch.export sample,
# litert_torch.convert(...).export('edgeface_xs.tflite'), then re-run the
# parity checks above before replacing the vendored file.
```

License: EdgeFace weights are **CC BY-NC-SA 4.0** (Idiap Research
Institute) — non-commercial use, attribution required, share-alike. The
BlazeFace detector model is **Apache-2.0** (Google). Both cover
research/pilot use; commercial deployment needs a separate EdgeFace
license.
