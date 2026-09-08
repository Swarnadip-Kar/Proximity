# Proximity — Campus Attendance System

Offline-first attendance over BLE proximity proofs + WiFi transport.
One Flutter app, two modes (Student / Professor): student enrollment and
marking are mobile-only (Android/iOS, on-device face + hardware key);
sign-in and records read everywhere (macOS/Windows/Linux/web, org-scoped),
and professor hosting runs on any platform. Plus a records-only web build.
Foreground-only during windows — no background-attendance promises on any
OS. Trust is tiered, not identical: hardware-backed mobile (FULL/STD),
stale-attestation grace (STALE), software-key mobile (NONE — no tier
claimed, marks via the flagged `device-none-fallback` until HW keys
ship), and records-only devices (no key at all, manual path only) — see
design §3.4/§4.

Design source of truth: [`PROXIMITY_DESIGN.md`](PROXIMITY_DESIGN.md).
This README describes the system as built.

## How it works

**Enroll once (sign in first).** One Gmail can hold both roles and the app
opens on the last-used mode — switch anytime from the home screens (back
goes to the landing hub, which offers every held role with the last mode
first). Professors register with a display name (Gmail default, any number
of devices); students enroll one device per Gmail — account (picked up
silently, no second tap) →
device keypair (hardware DKey, non-exportable where silicon allows, sealing
the Ed25519 attendance SKey — file copies unwrap to nothing) → on-device
3-still face enrollment (Centre / Left / Right via the `face_verification`
plugin, FaceNet gallery on the phone, embeddings never leave it) → online
atomic
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
   response token, pass the single-shot plugin holder check, and POST an
   Ed25519-signed proof binding the live challenge + score/timestamp/
   matcher-version ticket + device key, with TLS channel binding. The
   student first compares the class org (a mismatch returns a typed
   wrong-org verdict — no proof sent, no PII leaves). Professor verifies
   (freshness, single-use `(windowID,ID,j)`, signatures under the
   presented keys, ticket score ≥ 0.70 + 5-min freshness + allowlisted
   matcher version, hardware `dSig`, BLE sighting with RSSI gates) and
   returns a signed ACK, which the student sees as ✓ Marked.
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
cross-org joins die at the typed wrong-org gate before any proof is sent;
lent phones fail the plugin holder check (SKey stays sealed without a
fresh match ticket); cloned app bundles hold ciphertext without the
silicon DKey (restore detected → re-enroll); forged keys fail signature
verification under the presented keys; Evil-Twin relays fail TLS channel
binding; replays fail single-use + freshness. Identity is the Google
account itself, org-scoped end to end (rules, queries, exports). A
modified client can still lie about a local match — each lie must be
fresh, challenge-bound, and hardware-signed, and face-ticket anomaly
flags plus the offline double-pkD audit leave a permanent attributable
trace. No server re-check exists (see design §3.4 for what that costs).
See design §4–§5.

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
for transport client/discovery/server, BLE BlueZ shim, the
`face_verification` plugin (fail-closed stub on web — records only, never
verifies), file saving, attestation HTTP, and interface enumeration;
`platformx.dart` replaces `dart:io Platform`; protocol prefixes are built
from 32-bit halves (a >2⁵³ literal cannot compile to JS — values are
bit-exact on 64-bit native, untouched by web which never runs radio
crypto). `flutter build web` is the guard: any new native-only import in
the shared closure fails it loudly.

## Firestore data + rules

Collections (`apps/proximity_app/firestore.rules` + `firestore.indexes.json` —
deploy with `firebase deploy --only firestore:rules,firestore:indexes
--project proximity-attendence`; Track 1 org redeploy REQUIRED: the
org-scoped queries fail without the new composite indexes, cross-org
 writes fail without the new rules; legacy docs without `org` stay
 owner-visible while SyncEngine discovers (unfiltered pull) and stamps them;
 remove `missingOrg()` ONLY after its backfill-complete signal fires (SYNC
 log + persisted flag) AND the org-wide console check (all four collections
 where `org` missing) returns zero):

- `users/{uid}`: `{email, roles[prof|student], lastMode, org}` validated
  (name/displayName pass through unvalidated) — one doc per Firebase uid;
  the same Gmail can
  hold BOTH roles (professor multi-device, student single-device).
  `lastMode` is the last-used mode (landing + relaunch default). Owner
  read/write only; roles merge (array union), never overwrite. Email
  comparisons are case-insensitive on both sides (rules `lower()`); `org`
  must equal the caller's Google-account domain (`tokenOrg()`).
- `studentDevices/{emailLower}`: `{email, uid, pkHex, installId, name,
  roll, modelVer, platform, org, createdAtMillis/lastMoveAtMillis/lastSeenAtMillis/updatedAtMillis,
  moveCount}` — one enrolled student device per Gmail. Same-install
  re-keys free; moves need the 7-day cooldown (server-enforced; a bare
  pkHex match from another install is a move, not the same device);
  pre-timestamp docs migrate once. Claimed in one transaction
  (`studentDevices` + `deviceInstalls` + directory row, all three stamped
  with `org`) so racing devices
  resolve to exactly one winner. **No delete for anyone** (reset would be
  self-service while professor registration is self-asserted).
- `deviceInstalls/{installId}`: `{email, pkHex, org, updatedAtMillis}` — one
  student Gmail per app install (secure-storage UUID; clones/dual-apps get
  their own). Unguessable ids; writes bound to the signing-in Gmail + org.
- `studentDirectory/{emailLower}`: `{email, name, roll, nameLower, org,
  updatedAtMillis}` — minimal professor-searchable directory, maintained
  by the claim transaction. Prefix search on ID/name/email, each
  org-scoped (`where org == myOrg`, indexes org+email/roll/nameLower).
  Professor reads are **advisory** until professor roles are institute-verified.
- `classSessions/{sessionId}`: `{courseId, courseName, classLabel, profUid,
  profEmail, profName, org, dateIso, timestampIso, startIso, windows, names,
  rolls, studentEmails[], updatedAt}` — professors own their sessions;
  students read same-org sessions listing their Gmail (lowercased both sides).
  Session org = prof org at creation, immutable on update (rules enforce).
  Reads: org match AND (owner OR member) + legacy owner-only grace.
  Queries filter `where org == myOrg` (indexes profUid+org,
  studentEmails+org). Create validates profUid/profEmail/org +
  courseId/studentEmails/names/rolls
  types; readers coerce numeric names/rolls to strings. Doc ids are lowercased Gmails throughout;
  rules compare `lower()` on both sides so mixed-case accounts work.

Track 1 manual drill (no emulator in CI — run once per rules deploy):
T1 cross-domain offline pair: prof A (a@univ.edu) hosts, student B
(b@other.edu) joins → waiting stays unlisted for B's presence is rejected
(org-mismatch, count unchanged), B's mark attempt returns the wrong-org
receipt with no POST, A's tally unchanged. Same-org pair marks confirmed.
T2 edges: sign in with `User@Mail.Univ.EDU` vs `user@univ.edu` (same org,
shared sessions), `user@mail.univ.edu` (different org, invisible), and a
`googlemail.com` student against a `gmail.com` class (same org, marks).
T3 direct-ID invisibility: with A's session id, B's device fetches
`classSessions/{id}` directly → permission-denied (rules), and
`studentDevices/b@other.edu` is unreadable to A.

Timelines: device moves unlimited lifetime, ≤1 per 7 days, exact
re-enroll date shown with the old device's last-online day; same-install
re-key/re-enroll always free; first bind always free; manual attendance
covers any gap; offline manual adds queue and resolve on the next course
sync (live drafts excluded so the queue never races the tally).

## Repo layout

```
apps/proximity_app/      single app: student (mobile) + prof (any OS) modes + web records
  lib/core/              auth, sync/ (roles/claim/directory/org/queue/engine/sessions/store),
                          device_store, enrollment, ble_radio, host_driver, student_driver,
                          platformx/net_if/file_saver (web-safe shims), sync_hook
  lib/features/          face_identity/ (plugin adapter + DKey + mobile gates),
                          enrollment/, mark/, live/ (roster/inbox/add/setup sections),
                          records/, entry/
  lib/screens/           landing/roles/device hub, student_home (mark phases), take_attendance
                          (host), course/session/record screens (see SCREEN_MAP.md)
  lib/widgets/           trust_cards (verdict/trust/sync chips), sync_badge, ladder_line,
                          manual_add (+ offline queue), course_attendance, clock, animated
packages/protocol/       pure Dart: air framing, HMAC/UUID pack, Ed25519, window timer,
                          mesh/relay/dedup, face gate policy, device-proof verify
packages/ble/            BLE engine (rotation/relay/nextChallenge) + Linux BlueZ advertise shim (+ web stub)
packages/transport/      shelf HTTPS server/client, per-session TLS + channel binding, LAN discovery, rate limits
                          (+ web API stubs; pure types shared)
packages/storage/        tally + course history + roster helpers (in-memory API; JSON prefs backing)
```

## Build, test, run

Prereqs: Flutter stable, Firebase CLI + flutterfire, Xcode (iOS/macOS),
Android SDK. Firebase project: `proximity-attendence`. Suite status:
protocol 96 · transport 35 · ble 35 · storage 9 · app 202 · functions 18 — green,
`flutter analyze` clean, `flutter build web` green.

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
firebase deploy --only firestore:rules,firestore:indexes --project proximity-attendence
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
   (trust-on-first-use per class, pinned against the enrolled binding on
   sync); whoever proves presence over radio lands in the per-course
   union. Org is the Google-account domain (token `hd` first, verified
   email fallback — never typed): the join gate, Firestore rules, scoped
   queries, and exports all enforce it. Cloud holds multi-role `users`,
   one-device `studentDevices` (+`deviceInstalls`, `studentDirectory`)
   and `classSessions` backups via the SyncEngine outbox (offline-first,
   union-merge-before-push, tombstone deletes, idempotent replay) — key
   sync and signed exports remain future work.
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
7. **BLE air is v2 + v3-flags + legacy v1, unfiltered scan.** The v2
   packet (`packages/protocol/lib/src/air.dart`) is fixed `FCD2` + 18 B
   manufacturer payload (`PX 02`, type, token8, IPv4, port — 29 B total
   in the PRIMARY advertisement on every platform, no scan-response
   dependence). v3 appends one flags byte (relayed/dense-hint) so v2
   parsers still prefix-parse mixed-version halls with no flag-day;
   token bytes are never reused. Android/Linux originate v2;
   Apple/Windows originate legacy v1 single-UUID ticks alternating
   challenge and server-address hint. Students parse all formats; relays
   preserve the heard format. Scanning is unfiltered with in-app parsing
   (`AirParser`); unknown versions drop with a counted log, never
   silently. Verified live 2026-09-05 Mac↔phone (see §6 above for the
   Apple displacement finding that froze this shape).
8. **Live refresh + explicit leave.** Browsing recomputes the merged
   (beacon/BLE-hint) list every 2 s; unacked entries vanish on the 6 s
   expiry, while hinted hosts that answered a TCP probe persist up to
   120 s (re-probed every 15 s) so the class survives the round end —
   tapping re-validates through the waiting room. Pull-down refreshes
   instantly from local state (no network
   scan of any kind). Leaving the waiting room POSTs `/leave` so the
   prof count/view drops within ~2 s (logged as `waiting -email`).
9. **History in JSON prefs** (not SQLite yet); **face verification is the
   `face_verification` plugin (^0.3.9, FaceNet gallery + ML Kit detect,
   bundled model, fully offline)** — the old hand-rolled
   BlazeFace/EdgeFace pipeline is deleted (models, code, and tests);
   threshold 0.70 on the plugin score scale (old EdgeFace numbers stay
   retired). **Device binding is dual-key** (HW DKey sealing the Ed25519
   SKey) with server attestation re-check on sync; the OS-biometric
   prompt is deliberately NOT a substitute (face-only).
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
   email, `limit(10)` each, merged by email, capped at 10 — each paired
   with an `org == myOrg` equality filter on its composite index; worst
   case ~30 doc reads per pause plus one
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
  rescan replaces per-sample via the plugin gallery (monotonic progress,
  never a whole-set wipe); the enroll capture saves 3 stills
  (Centre/Left/Right) and save stays blocked until all three register
  (Cancel always exits — a capture exit means success or the holder's
  own Cancel); single-flight autosaves, single-flight hosting/prove/queue
  (`_starting`, `_listening`, `_hostingBusy`, `_resolvingQueue`);
  rename-course batches recreate after each 400-commit (batch reuse throw);
  landing caches the role future per email (no refetch per rebuild);
  student hint retries are tracked timers cancelled on dispose; prof
  ADV-start failure unwinds the half-open window + scan.
- Same-install rule: the install is the device identity everywhere
  (client verdict + server rules mirror); a bare pkHex match from another
  install is a move. Heartbeat touches stay lenient (timestamp only).
  Stale matcher versions fail closed into forced re-face (SKey kept);
  corrupt seeds fail as terminal receipts;
  numeric names/rolls coerce to strings on read. Email identity is
  lowercased on both client and rules sides.
- Navigation safety: landing post-await mode switches go through a
  mounted-guarded `_goto` — the mode flip unmounts landing mid-flight, so
  a bare `setMode(ref, …)` after an await is a ref-read-after-dispose
  crash (seen on macOS). All other screens read providers synchronously
  or inside try/caught blocks; audited, no other uncaught site.
- Accepted risks, stated: enroll-then-crash between claim and local write
  strands the key until the cooldown (millisecond window); two colluding
  phones with live relay + victim face can still wormhole within 5 s
  (needs an accomplice present both windows; UWB would close it);
  printed-photo face fraud can pass the passive matcher (fix is a
  liveness-capable plugin behind the same adapter, not stills
  heuristics); directory professor-gate is advisory until roles are
  institute-verified.
- Simplifications applied: manual-add is one widget (the separate search
  widget is deleted); edit-page save preserves `startIso`; course cards
  carry one-line partials (big section removed); legacy pk-only binding
  helper deleted; `dart:io Platform` replaced by `platformx`; CSV saving
  and interface enumeration are conditional shims.

## Real-class test checklist

- [ ] Professor hotspot: NEVER in this design (no-hotspot networking is
  fixed) — on isolating APs classes surface via BLE hint + typed IP, and
  a truly unreachable host fails honestly into the manual path.
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
- [ ] Face tuning: threshold 0.70 on the plugin score scale (old EdgeFace
  0.60/0.80 numbers retired, never reused) targeting FAR ~0.01% /
  FRR <2% — re-measure genuine/impostor distributions on-device;
  `nRF Connect` walk-test for −70/−80 dBm gates per hall.
- [ ] Desktop: student enrollment/marking stay unreachable (records-only
  gates); professor hosting + records work on macOS/Windows/Linux.
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
- [ ] Face capture in a real classroom: 3-still enroll completes fast in
  cabin light; single-shot marking verify stays ~1s.

## Face capture UX

Enrollment is one tap, one capture page: 3 stills (Centre / slight-Left /
slight-Right) registered into the on-device plugin gallery under an
opaque faceId (`sha256(gmail+installId)` — never the raw Gmail). Save
stays disabled until all three register; rescan replaces per-sample
(monotonic progress, never a wipe). Marking runs a single-shot verify on
the isolate path (~1s fast path): a match stamps the `FaceGate` and
signs the challenge-bound ticket; an unreadable frame is inconclusive
(rescan in-session, burns nothing); a readable wrong-person frame burns
one attempt (2 instant retries, then per-session fail; 4 mismatch
sessions → needs-review queue → professor manual override; never
auto-present on face fail). A version mismatch forces re-face (key kept);
no images or embeddings ever leave the device. Anti-spoof is accordingly
modest: the passive matcher plus the signed ticket plus the device key —
a good-quality printed photo CAN pass, stated plainly. If photo fraud
appears in the pilot, the fix is swapping the adapter for a
liveness-capable plugin behind the same `FaceVerifier` interface, not
new heuristics.

## System log (toggleable terminal)

Every live screen carries a **Show system log** toggle rendering the same
`BleLog` stream in a terminal window (black, monospace, color-coded tags,
autoscroll, 500-entry ring buffer, clear button):

- Student: browsing (browse/list), waiting room, face scan, listening radar,
  marked/late/no-signal verdicts. Face-scan screen too (radio keeps
  listening under the camera UI).
- Professor: take-attendance screen (above the waiting list).

Tags: `BLE` (scan start, ADV on air/failures, RX challenge/response with
RSSI, IP-hint heard/probe/listed, air-visibility probes), `MESH` (relay armed, forwarding, relayed,
skip reasons: TTL/weak/dup/split-horizon/cap — the disarmed steady state stays
silent), `LAN` (HTTPS up, announce IP,
broadcast targets, beacon sent, beacon heard/new, presence, leave, manual,
waiting joins/leaves), `SEC` (ticket score,
signing), `NET` (window fetch, token sent,
ACK verdicts), `SYNC` (offline→online edges, flush results, backfill
gate), `CLOCK` (server-drift median, drift banner). Silent radio failures were the original mesh bug — nothing
in this path fails silently anymore. Every entry is also mirrored to
`adb logcat` (`I/flutter`) so live radio tests can be grepped after the
fact (the on-screen ring autoscrolls).

## Gaps / roadmap

- GATT directed-response relay (designed, never built — responses stay
  direct-ADV-only).
- SQLite/drift backing (history still JSON prefs).
- Institute-verified professor roles (turns the directory gate from
  advisory to enforced; enables a safe reset path).
- Hardware keystore/Secure Enclave DKey enrollment (interface +
  sealed-SKey + tiers ship; Kotlin/Swift platform work + persisted
  attestation material pending) + Apple App Attest root provisioning +
  attestation revocation/CRL story (theft response today: 7-day move
  bound + manual attendance).
- Liveness-capable face plugin behind the existing adapter if photo
  fraud appears in the pilot.
- Windows/Linux binaries via CI (macOS verified here).

## Face model provenance

Face verification is the `face_verification` Flutter plugin (^0.3.9,
MIT — FaceNet embeddings + ML Kit detection, model bundled in the
package, fully offline and on-device; integration follows the package's
own example app). Threshold 0.70 on the plugin score scale targets
FAR ~0.01% / FRR <2% — the old EdgeFace 0.60/0.80 numbers are retired
and must never be reused (different embedding space). The old
hand-rolled BlazeFace/EdgeFace pipeline — code, vendored `.tflite`s, and
tests — is deleted; no photo or embedding ever leaves the phone, only
the signed match ticket. Enrollment identity is `sha256(gmail+installId)`,
and matcher versions are allowlisted (`verifierVer`) so a plugin/model
bump forces re-face instead of matching across versions.
