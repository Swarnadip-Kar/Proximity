# Proximity — Deployment Runbook

**Scope:** everything an operator (not code) must do at release, in order.
Code is already wired — this file is console + CLI steps only.
**Project:** `proximity-attendence`. **Current build:** `0.1.0+1` (`apps/proximity_app/pubspec.yaml`).

Companions: `PROXIMITY_SECURITY.md` §9 (why the floor event exists),
`apps/proximity_app/lib/core/security/integrity.dart` (`IntegrityAppCheck` docs).

---

## 0. Standing state (2026-09-13)

- Firestore rules: `firestore.rules` carries the `pkS` type-lock
  (`validDirectoryPkS`), `profDevices` pins, App Attest locks, and the
  same-phone reclaim gate (`isSamePhoneReclaim` + `deviceId` type-lock).
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

## 3e. Debug emulator (iterate on-device with no single-device friction)

Release rules enforce one device per Gmail + the 30-day move cooldown, so
repeated reinstall-and-enroll loops on a debug phone keep hitting
`installConflict` / cooldown refusals. Debug builds can point at local
emulators instead (fresh backend every run — enroll freely, nothing touches
prod). Release builds ignore the flag entirely.

```bash
cd apps/proximity_app
firebase emulators:start --only firestore,auth   # needs firebase-tools + JDK
flutter run --dart-define=PROX_EMULATOR=1
```

Then create any test user in the emulator UI (`localhost:4000` → Auth),
sign in with it on-device, and enroll. The app targets `10.0.2.2` on
Android emulators and `localhost` elsewhere (see `main.dart`
`PROX_EMULATOR` wiring); App Check activation is skipped in this mode.
`firestore.rules` is evaluated locally from the repo file, so rule
behavior stays faithful — only the DATA is throwaway.

## 4. What changes later (checklist)

- [ ] §1 deployed (rules timestamp + drill green) — DONE when console shows it.
- [ ] §2 floor set to this build with `force:true` — DONE when the doc reads back.
- [ ] Android SHA-256s pasted, Play Integrity enabled — DONE when App Check shows green checks.
- [ ] Paid Apple membership → §3b filled → `SEC AppCheck activated` seen on iOS.
- [ ] Play release live → `PLAY_RECOGNIZED` ON in Monitor → no legit denials → Firestore Enforce.
- [ ] Web decision before Enforce: reCAPTCHA registration or mobile-only enforcement.
- [ ] Each future break: bump `pubspec` version → repeat §1 + §2 with the new `minVersion` + `storeAndroid`/`storeIos` links.
- [ ] §5 release cut (per-platform builds green → installers → GitHub release).

---

## 5. Release builds (per-platform, CI-gated)

CI (`.github/workflows/build.yml`) runs every platform as an **independent
job** gated only on `analyze-test`. A red platform never blocks the others:
each green job uploads its own artifact, and a release ships whatever is
green. Check status with:

```bash
gh run list --limit 3 --branch First-Release
gh api repos/Swarnadip-Kar/Proximity/actions/runs/<RUN_ID>/jobs \
  --paginate --jq '.jobs[] | "\(.name) \(.conclusion // "pending")"'
```

### 5a. iOS flag (SwiftPM off, CocoaPods on) — DO NOT REVERT

`apps/proximity_app/pubspec.yaml` carries:

```yaml
flutter:
  config:
    enable-swift-package-manager: false
```

Why (2026-09-14, verified against CI logs): `flutter_security_suite`
1.1.1 ships a broken SwiftPM manifest — `Package.swift` declares product
`flutter_security_suite` (underscores) while Flutter's generated
`FlutterGeneratedPluginSwiftPackage` depends on `flutter-security-suite`
(dashes), so SPM resolution fails with "product not found in package".
Reverting the flag re-breaks iOS CI (confirmed: runs `34828971554`,
`34831096297`, `34836223368` all red on iOS). The plugin's `.podspec` is
valid, so CocoaPods builds fine.

Companion rule: **`ios/Podfile.lock` + `macos/Podfile.lock` are tracked —
re-resolve them on every Firebase major bump.** The Firebase 4.x migration
bumped the Dart deps (Firebase iOS SDK `11.15.0` → `12.18.0`) without
refreshing the iOS lockfile, so the CocoaPods fallback failed with the
well-known `Firebase/Auth (= 11.15.0 vs = 12.18.0)` snapshot conflict
(run `34834268759`). Fix, verified locally and on CI:

```bash
cd apps/proximity_app
flutter pub get
cd ios && pod update        # NOT bare `pod install` — the stale snapshot
cd ../macos && pod update   # pins must be re-resolved, then committed
git add ../ios/Podfile.lock ../macos/Podfile.lock
```

Deadline: Firebase deprecated CocoaPods after **October 2026** (new SDK
versions stop publishing to the Specs repo). Before that, either the
security-suite plugin fixes its SPM product name (then delete the flag +
`flutter pub get`) or the plugin is replaced — otherwise iOS/macOS builds
freeze at the last CocoaPods-published SDK.

### 5b. Cutting the release

1. All §1–§3 steps done; `build` workflow green on every shippable
   platform (iOS included after §5a).
2. Bump `apps/proximity_app/pubspec.yaml` `version:` if this is a new
   floor (keep in sync with the §2 `minVersion` core).
3. Build + package per platform (release mode, signed where possible):

   ```bash
   cd apps/proximity_app
   # Android (any OS with the SDK) — the APK IS the installer:
   flutter build apk --release
   # → build/app/outputs/flutter-apk/app-release.apk
   # (debug keystore signs it; Play Store upload needs the release
   # keystore in android/keystore.properties — not wired yet.)

   # macOS (on a Mac) — ad-hoc signed DMG, Gatekeeper = right-click > Open:
   flutter build macos --release
   packaging/macos/make_dmg.sh
   # → dist/Proximity-<version>-macOS-<arch>.dmg

   # Windows (on Windows, Inno Setup 6 installed):
   powershell -ExecutionPolicy Bypass -File packaging\windows\build_installer.ps1
   # → dist\Proximity-Setup-<version>-Windows-x64.exe

   # Linux (on Linux):
   flutter build linux --release
   packaging/linux/make_deb.sh        # → dist/proximity_<version>_amd64.deb
   packaging/linux/make_tarball.sh    # → dist/Proximity-<version>-Linux-x64.tar.gz (no-install fallback)
   ```

   Windows/Linux cannot be built on macOS — take them from CI instead:
   `gh run download <RUN_ID> --dir dist/ci` (jobs `proximity-windows`,
   `proximity-linux`).
4. Publish the GitHub release (tag = version):

   ```bash
   git tag v0.1.0 && git push origin v0.1.0
   gh release create v0.1.0 --title "Proximity 0.1.0" \
     --notes "First release. See PROXIMITY_DEPLOYMENT.md §1–§3 for the rules + version-floor steps that ship WITH these builds." \
     build/app/outputs/flutter-apk/app-release.apk \
     dist/*.dmg dist/*.exe dist/*.deb dist/*.tar.gz
   ```
5. Paste the Play/App Store links back into the §2 floor doc
   (`storeAndroid`/`storeIos`) once listed.
