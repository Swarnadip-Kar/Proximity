# Proximity — Deployment Runbook

**Scope:** everything an operator (not code) must do at release, in order.
Code is already wired — this file is console + CLI steps only.
**Project:** `proximity-attendence`. **Current build:** `0.1.0+1` (`apps/proximity_app/pubspec.yaml`).

Companions: `PROXIMITY_SECURITY.md` §9 (why the floor event exists),
`apps/proximity_app/lib/core/security/integrity.dart` (`IntegrityAppCheck` docs).

---

## 0. Standing state (2026-09-13)

- Firestore rules: `firestore.rules` carries the `pkS` type-lock
  (`validDirectoryPkS`), `profDevices` pins, and App Attest locks.
  **Not yet deployed** — deploy in §1.
- Version floor: `app_config/min_version` must be `{minVersion:"0.1.0",
  latest:"0.1.0", force:true, ...}` alongside this release.
  **Not yet set** — set in §2 (Console, admin bypass; rules deny client writes).
- App Check: Android `proximity (org.iitbhilai.proximity)` **Registered**
  (Play Integrity). iOS + web rows **Not registered** (intentional — see §3).
- `Tl=0.85` + directory `pkS` write make old builds fail closed
  (`liveness-unbound` / `unknown-pkS`) — that is the intended floor event.
  Ship rules + floor WITH the build, never silently after.

---

## 1. Deploy rules + indexes (every release that touches them)

```bash
cd apps/proximity_app
firebase deploy --only firestore:rules,firestore:indexes \
  --project proximity-attendence
```

Verify: Firebase Console → Firestore → Rules → timestamp updated.
Then re-run the rules drill (needs JDK 21 for firebase-tools):

```bash
# from apps/proximity_app/rules-drill/
node sec-drill.mjs
```

Then suites:

```bash
cd packages/protocol && dart test
cd packages/transport && dart test
cd packages/ble && dart test
cd packages/storage && dart test
cd apps/proximity_app && flutter analyze && flutter test
```

---

## 2. Bump the version floor (every ticket/rules/verifier break)

`app_config` rules are `allow get:true; allow list,write:false`, so this
is a Console write (admin bypass) — there is no `firestore:set` CLI command.

Firebase Console → Firestore → `app_config/min_version` → set:

```json
{
  "minVersion": "0.1.0",
  "latest": "0.1.0",
  "force": true,
  "msg": "This version of Proximity is too old to mark attendance safely. Update to continue.",
  "storeAndroid": "",
  "storeIos": ""
}
```

Rules:
- `minVersion` = the shipping `pubspec.yaml` version core (`0.1.0+1` → `0.1.0`).
- `force:true` always at a break (old builds must barrier, never cryptic `bad-sig`).
- Fill `storeAndroid`/`storeIos` with Play/App Store links once listed (barrier shows them as copyable text).
- The client enforces the floor from disk (`prox.forceFloor.v1`) offline across restarts once seen. A build that NEVER goes online after the floor publishes cannot know about it (no channel exists — bound is attestation validity + auto-update).

---

## 3. App Check

### 3a. Android (do now — free)

1. `cd apps/proximity_app/android && ./gradlew signingReport` → copy SHA-256 lines (debug + release).
2. Play Console → app → Setup → App integrity → enable Play Integrity API.
3. Firebase Console → App Check → Apps → `proximity (android)` → Play Integrity provider → paste SHA-256s.
4. Settings used: token TTL **1h** (keep); `PLAY_RECOGNIZED` **OFF** while sideloading the pilot, **ON** with the Play release (Monitor first); `LICENSED` **OFF** permanently (free app, no license semantic); minimum device integrity **Don't explicitly check** (never `STRONG` while TEE→STD phones are supported — App Check must stay looser than the protocol's own FULL/STD/NONE gate).

### 3b. iOS (SKIPPED — needs paid Apple Developer membership)

Status: row `proximity (ios)` stays `Not registered`. Safe because activation
is fail-soft (`SEC AppCheck activation skipped` → everything continues) and
Firestore is on Monitor. When the membership lands (10 min, console-only, no rebuild):

1. Apple Developer → Membership details → copy Team ID (10 chars).
2. Certificates, Identifiers & Profiles → Keys → `+` → name `Proximity DeviceCheck` → tick DeviceCheck → Register → download `.p8` once + note Key ID.
3. Firebase Console → App Check → `proximity (ios)` → DeviceCheck section: upload `.p8`, paste Key ID + Team ID, TTL 1h. App Attest section: paste the same Team ID, TTL 1h.
4. Cold-start the iOS build, confirm `SEC AppCheck activated (PlayIntegrity/AppAttest+DC)` in the log.

Note: without the membership, iPhones also cannot reach protocol STD
(`DCAppAttestService` needs it) — they fail closed to the manual path, never
fake-confirm. Firebase registration alone would not fix that.

### 3c. Web / Windows rows (SKIP)

`proximity_app (web)` / `(windows)` are Web Apps → App Check would mean
reCAPTCHA Enterprise, not wired for the records-only build. Leave
`Not registered`. Consequence: the day Firestore flips to Enforce,
unregistered web clients deny — either register web with reCAPTCHA first or
accept mobile-only enforcement.

### 3d. Enforce (NOT yet — Monitor until the floor rolls out)

Firebase Console → App Check → Firestore → Enforce **only after** the §2
floor has rolled out to the fleet (enforcing earlier bricks legit installs
that cannot attest yet). Order: Play release + floor → `PLAY_RECOGNIZED` on in
Monitor, watch for legit denials → Enforce.

---

## 4. What changes later (checklist)

- [ ] §1 deployed (rules timestamp + drill green) — DONE when console shows it.
- [ ] §2 floor set to this build with `force:true` — DONE when the doc reads back.
- [ ] Android SHA-256s pasted, Play Integrity enabled — DONE when App Check shows green checks.
- [ ] Paid Apple membership → §3b filled → `SEC AppCheck activated` seen on iOS.
- [ ] Play release live → `PLAY_RECOGNIZED` ON in Monitor → no legit denials → Firestore Enforce.
- [ ] Web decision before Enforce: reCAPTCHA registration or mobile-only enforcement.
- [ ] Each future break: bump `pubspec` version → repeat §1 + §2 with the new `minVersion` + `storeAndroid`/`storeIos` links.
