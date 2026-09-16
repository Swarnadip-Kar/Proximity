# Proximity — Deployment Runbook

**Scope:** everything an operator (not code) must do at release, in order.
Code is already wired — this file is console + CLI steps only.
**Project:** `proximity-attendence`. **Current build:** `0.1.0+1` (`apps/proximity_app/pubspec.yaml`).

Companions: `PROXIMITY_SECURITY.md` §9 (why the floor event exists),
`apps/proximity_app/lib/core/security/integrity.dart` (`IntegrityAppCheck` docs).

> **⚠️ PILOT LINEAGE (no Play account, 2026-09-14): this release ships as a
> DIRECT-SIDELOAD pilot APK built with `--dart-define=PROX_PILOT_SIDELOAD=true`
> — NOT via Play. That one flag waives ONLY the installer-trust half of the
> enroll integrity gate so a properly-signed sideloaded APK can enroll
> (re-sign/root/hook/emulator still hard-block). Full contract, tester
> instructions, kill-switch, and the honest accounting of what the pilot
> costs (§5c–§5d) — READ BOTH BEFORE
> forwarding the APK to anyone. NEVER upload a pilot-flagged binary to any
> store track; NEVER build the store release with the flag.**

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

CI (`.github/workflows/build.yml`) builds ONLY what this Mac cannot:
`windows` + `linux` in `--release`, gated on `analyze-test`. Android +
macOS + iOS build locally (§5b–§5c) — they were removed from CI because
the repo is private (macOS bills 10x, Windows 2x) and the macOS .app
artifact alone (~400MB/run) blew the 500MB free storage quota. Each CI
run now costs ~10 billed minutes instead of ~170. A red platform never
blocks the other: each green job uploads its own artifact (7-day
retention), and a release ships whatever is green. Check status with:

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
    `gh run download <RUN_ID> --dir dist/ci` (artifacts
    `proximity-windows-release`, `proximity-linux-release`).
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

### 5c. ⚠️ Pilot sideload build (no Play account — disposable lineage)

> **Read this whole section before distributing.** The pilot APK is a
> release-grade binary (`--release`: AOT + `-O`, same flags as the store
> build, no `--obfuscate`) with exactly ONE baked-in difference: the
> `PROX_PILOT_SIDELOAD` compile flag. There is no runtime toggle, no
> settings switch, no intent/prefs override — the waiver lives or dies
> with the binary.

#### What the flag does (and does NOT do)

- **Waives:** ONLY the installer-trust half of `isAppIntegrityValid`
  (sideloaded installs report installer-null ⇒ invalid). A
  properly-signed pilot APK therefore clears `entryRequireEnrollIntegrity`
  and can complete the device claim. The waiver logs
  `SEC pilot-sideload: installer-trust waived …` on-device.
- **Keeps:** re-sign/strip (`isTampered`), rooted OS, Frida/Xposed hooks,
  and emulators still hard-block enrollment with the same copy as store
  builds; marking still flags (never auto-absents) on taint; the 30-day
  device-move cooldown, one-device-per-Gmail claim, HW key tiering, and
  the version floor all behave identically.
- **Kill-switch (no code revert needed):** ship the store build at a higher
  core version (e.g. `0.2.0`) and raise the §2 floor to that core with
  `force:true` — pilot builds barrier out with update copy on next online
  contact (and immediately if they have ever seen the floor, via the
  disk-backed cache).

#### Prerequisites (do §1–§3 first — pilot changes NONE of this)

1. §1 rules + indexes deployed (console timestamp verified) and the
   rules drill green.
2. §2 floor `app_config/min_version = {minVersion:"0.1.0",
   latest:"0.1.0", force:true, …}` set. Pilot core is `0.1.0`, so the
   floor does NOT block the pilot — it blocks only pre-break builds.
3. Release SHA-1 + SHA-256 registered under the Android app AND pasted
   into App Check → Android app; `google-services.json` re-downloaded
   (must contain the `8286f07a…` `oauth_client` entry — verify with
   `git log --oneline -1 -- android/app/google-services.json`).
   App Check stays **Monitor**, `PLAY_RECOGNIZED` **OFF** for the pilot.

#### Cut the pilot APK

```bash
cd apps/proximity_app
flutter build apk --release --dart-define=PROX_PILOT_SIDELOAD=true
# → build/app/outputs/flutter-apk/app-release.apk
```

Verify before forwarding (fail the cut if any check fails):

```bash
# 1. Signed with the release key (NOT debug) — APKs use v2/v3 signing,
# so keytool -printcert -jarfile reports "Not a signed jar file": use
# apksigner from the SDK build-tools instead:
~/dev/android-sdk/build-tools/36.0.0/apksigner verify --print-certs \
  build/app/outputs/flutter-apk/app-release.apk | grep -iE "sha-256|sha-1"
# must print SHA-256 9da9291753755c22456f3cc1bda1f9ff…:30a56569 and
# SHA-1 8286f07a6cdbfa6b64c3772e8b84c6ed06dbd67a
# (release-secrets/README.md) — NEVER the debug 72:bc:bc:ae:…
# 2. Face models bundled:
unzip -l build/app/outputs/flutter-apk/app-release.apk \
  | grep -E "facenet.tflite|silentface-minifasnetv2"
# 3. On-device pilot proof (after install, before enroll):
adb logcat -s flutter | grep -i "pilot-sideload"
# enroll once → the SEC pilot-sideload line appears; absence means the
# binary was built WITHOUT the flag (stock store behavior: sideload
# refuses with the tampered message — correct for that binary).
```

#### Tester instructions (send WITH the APK — copy/paste)

1. **Uninstall any existing Proximity first** (debug and release keys
   conflict: `INSTALL_FAILED_UPDATE_INCOMPATIBLE`). Then install the APK.
2. Sign in with your **institute Gmail**, enroll as student (one device
   per Gmail).
3. **⚠️BINDING WARNING: enrolling binds your Gmail to THIS phone for 30
   days** (moves ≤1 per 30 days, server-enforced, no reset shortcut).
   Do NOT enroll a casual/loaner phone — use the phone you will mark
   attendance from. Until any re-enroll date, attendance comes from the
   professor's manual path.
4. If enrollment refuses with "tampered or re-signed": you received a
   non-pilot binary — ask for the pilot build, do not retry.
5. Professor side: host from an Android phone on the same WiFi; the
   pilot has no Play Integrity verdicts yet, so treat `STALE`/unverified
   banners as informational during the pilot.

#### Never-do list (pilot lineage)

- NEVER upload a pilot-flagged binary to Play (any track) — the flag
  would ride into the store lineage. Store uploads are ALWAYS plain
  `flutter build appbundle --release` with NO dart-define.
- NEVER forward the release keystore or `keystore.properties` with the
  APK (lose = bricked updates; leak = anyone ships "Proximity").
- NEVER "fix" a tester failure by turning the flag into a runtime
  setting — the compile-time bake is the guarantee a store binary
  cannot inherit the waiver.
- When the Play account lands: §5b as written, core `0.2.0`, floor bump
  per §2 — pilot installs barrier out on their own.

### 5d. NOTE — Pilot vs official route: why, what it costs, what still holds

#### Why the official route is not available

The stock release binary is already Play-ready (signed, pinned, gated) —
what is missing is the *accounts*, not the code:

1. **No Google Play Developer account** ($25 one-time + identity
   verification + review wait). Without it there is no trusted installer
   on any tester phone: every install reports installer-null, so the
   suite's `isAppIntegrityValid` reads false and the stock gate refuses
   enrollment with the tampered message — on a perfectly legitimate
   binary. The pilot flag exists solely to bridge this account gap.
2. **No paid Apple Developer membership** (separate, Apple-side). This
   blocks macOS/iOS *distribution* (notarization, signed DMG that keeps
   keychain groups working on other Macs) and App Attest-backed STD tier
   on iPhones — which is why macOS is deliberately undistributed for the
   pilot (§5 scope: Android only). It does not affect the Android pilot.

Neither gap changes a line of protocol, rules, or verifier code — both
are pure distribution plumbing, closable later without rebuilds of logic.

#### Practical implications of the pilot (read honestly)

- **Manual install + manual updates.** Testers sideload (unknown-sources
  prompt, uninstall-first on key conflict) and there are NO auto-updates:
  every fix needs a re-forwarded APK and a manual reinstall. Stale pilots
  linger on phones — the only leash is the §2 floor, which needs one
  online contact to bite (a fully-offline stale pilot keeps marking, same
  as a fully-offline stale store build would).
- **No Play Integrity verdicts.** App Check stays Monitor; the
  PlayIntegrity provider has no recognized installer to vouch for, so
  pilot devices never yield `MEETS_DEVICE_INTEGRITY`/`STRONG`. Attestation
  tiers during the pilot are client-presented + professor-verified offline
  (chain-vs-pinned-roots), exactly as designed for offline-first — but
  there is no independent Play verdict backing them until the store
  build ships.
- **No staged rollout, no per-user revocation.** One APK for everyone;
  stopping a single device means the 30-day move machinery or the global
  floor — both coarse. Keep the tester set small and known.
- **Support surface is yours.** Unknown-sources friction, "app not
  installed" on key conflicts, and the 30-day binding surprise all land
  on you, not on a store listing. The §5c tester note exists to pre-empt
  all three — send it verbatim.
- **A repackaged pilot binary still dies at launch.** This is the point
  most "sideload = insecure" summaries miss: the pilot waives the
  *installer* check, NOT the *signing-cert* pin. `MainActivity`
  compares the APK's actual signing cert against the baked-in
  `9DA9…6569` SHA-256 and throws on mismatch — anyone who unzips,
  modifies, and re-signs the APK produces a build that crashes before
  any UI. Stealing the *file* is useless; only stealing the *keystore*
  breaks this (hence the never-do list).

#### What still holds, in full, on the pilot

- **Server-side gates (untouched, installer-independent):** one student
  device per Gmail (single-transaction claim — racing devices resolve to
  exactly one winner), ≤1 move per 30 days with exact re-enroll date,
  same-install re-key free, no self-reset path, org-scoped rules/queries,
  owner-lazy purge. A phone that "lies" locally still hits the same
  Firestore rules as a store phone.
- **Classroom crypto (identical binaries, identical air):** 10 s
  challenge rotation, 17 s acceptance, single-use `(windowID,ID,j)`,
  Ed25519 proofs under pinned `pkS`, TLS channel binding, BLE sighting
  with RSSI gates, face ticket ≥ 0.70 + 5-min freshness, liveness ≥ 0.85
  with allowlisted versions, HW `dSig` chain-vs-pinned-roots. The
  professor's phone verifies a pilot proof byte-for-byte like a store
  proof — there is no "pilot mode" on the air.
- **Client hard-blocks that remain:** rooted OS, Frida/Xposed hooks,
  emulators, and re-signed binaries still refuse enrollment; marking
  still flags (never auto-absents) on taint; the cert-pin still kills
  repackaged binaries at launch (above).
- **Floor kill-switch:** §5c — the pilot lineage ends the day the store
  build + floor ship, with no cooperation needed from pilot installs
  beyond one online contact.

**One-line summary for stakeholders:** the pilot is the production app
minus Play's installer vouch and auto-update — every attendance-critical
guarantee (claim rules, proof crypto, device binding, re-sign death)
holds; what you lose is convenience (manual installs/updates) and the
independent Play verdict, both restored the day the Play account lands.
