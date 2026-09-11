# Proximity app architecture (Phase 1 — UI foundation + foundation-track shared infra)

## Layout

```
lib/
  design/
    tokens.dart      # THE source of truth: durations, curves, spacing,
                     # radii, state colors, palette, log tags/colors,
                     # reduce-motion helper
    app_theme.dart   # Material light/dark themes (Space Grotesk + Inter)
  widgets/
    prox_scaffold.dart  # ProxScreen: app bar + max-width body (wraps AdaptiveScaffold)
    prox_buttons.dart   # ProxPrimaryButton / ProxSecondaryButton (press-scale, never gated)
    prox_cards.dart     # ProxCard / ProxListTile (+dense) / ProxDot (pulse opt-in)
    prox_states.dart    # ProxStateBadge (pulse opt-in) / SectionHeader /
                        # Empty / Loading / Sync+Error notes
    prox_motion.dart    # ProxFadeSlideIn / ProxStaggered / ProxSwitcher
    verdict_badge.dart  # VerdictBadge: the one verdict pill (elastic
                        #   scale-in on flip-to-Marked lives inside it;
                        #   supersedes the old MarkedBadge)
    animated.dart       # PresentTicker (take-header presence ticker)
    trust_cards.dart    # Track 5: DeviceTrustBadge / WrongOrgCard (settled
                        # states, presentation only; sync status lives in
                        # sync_badge.dart)
    ip_join.dart / clock.dart / selection_toolbar.dart / ...
  routes.dart        # IA route table + web guards + ProxRouteObserver (NAV log);
                      # entry/records deep-links + web records-only redirects
  screens/           # thin hosts (landing/setup_flow/student_home/
                      # take_attendance/face_capture — orchestration stays,
                      # rendering lives in features/)
  features/          # IA bundles, one dir per flow (account/debug/entry/
                      # face_identity/live/manual_attendance/mark/records/
                      # setup); hosts compose sections from here
  core/              # drivers, sync, face, BLE (no UI)
  main.dart          # app entry + AdaptiveScaffold (Cupertino nav on Apple OS)
  mode.dart          # AppMode + linked identity (+ STATE log on transitions)
```

## Layered separation

One-way dependencies, top to bottom:

```
presentation (screens/, features/, widgets/)
  → state (mode.dart providers, Riverpod controllers)
    → data (core/sync/, core/enrollment.dart)
      → service (core/host_driver.dart, core/student_driver.dart,
                 BLE engine, face stack, transport)
```

- `design/` and `routes.dart` are dependency leaves: they import Flutter,
  Riverpod types, and feature/legacy screens only as route targets — never
  the reverse for behavior (screens never import routes for logic; pushes
  migrate to `ProxNav` helpers).
- Shared UI (`widgets/prox_*`, `design/`) never imports a screen, a
  driver, or cloud sync — except the log ring (`BleLog`), which is pure
  Dart with no app dependency, so logging never creates a layer cycle.
- `ProxScreen` wraps `AdaptiveScaffold` (still defined in `main.dart`);
  screens keep importing it from there until the shell moves wholesale.
- Feature grouping: new screens live in `lib/features/<bundle>/` with
  bundle-local flow helpers (`entry_flow.dart`, `EnrollFlow`); truly shared
  pieces graduate to `widgets/prox_*` or `design/tokens.dart` instead of
  being copied per bundle.

## Logging discipline

One ring buffer (`BleLog`, 500 entries, coalesced flush, adb-logcat
mirror). Tags from `ProxLogTags`, colors from `ProxLogColors` (single
source for the full-screen debug log — the embedded `BleLogView` was
removed Track 5 as a one-off; `debug/log` is the one terminal):

- BLE / MESH / LAN / SEC / NET — radio + drivers (pre-existing; beacon
  and relay repeats stay deduped by packet key so the terminal survives
  mid-session load).
- NAV — every route push/pop/replace (`ProxRouteObserver`, always on),
  bundle moves, sign-in/out, mode continues.
- SYNC — cloud merges/pushes/pulls, offline-queue defer/resolve counts,
  directory-search failures (with the error text as reproducing context).
- FACE — face-pipeline decision points (which slots rescanned, what the
  controller dropped, gate outcomes).
- STATE — provider recompute reasons (mode transitions incl. persist
  failures, role-cache hit/miss/seed, claim-gate verdicts) and route
  misses with their missing context.
- TRANSPORT — HTTPS/transport lifecycle + contract events (serve up/down,
  prove-pipeline milestones at the transport boundary).
- CRYPTO — sign/verify decisions (proof posted, ACK verify ok/BAD; never
  keys or preimages).
- SESSION — session/round transitions (round recorded with open-round
  list, tally restored with counts, manual decisions).

Rules: meaningful transitions + errors log with reproducing context
(course/session ids, counts, error text — never keys, templates, or
photos); steady states stay silent (relay disarmed, offline-deferred
polls); noisy per-keystroke/per-packet events dedupe by key with a time
window (see the BLE `_loud` keys and the manual-add 10s failure gate);
`BleLog.clear()` exists for the terminal Clear action only — code never
clears to hide state. Both log views are reduced-motion safe (toggle and
chips use `ProxMotion.effective`; autoscroll jumps, never animates) and
cheap under load (capped buffer, plain-Text rows, flush coalescing).

## Core modules (snapshot, not a contract)

Seven single-responsibility modules with DI at each seam (delegates,
embedders, store facets, `SightingLookup`, engine callbacks — no module
reaches into another's internals): crypto (`protocol/src/crypto/`),
air (`protocol/src/air/`), session (`storage`), radio (`ble/src/`),
net (`transport`, incl. `LiveRoom`), sync (`core/sync/` + `SyncQueue`),
face-decision (`features/face_identity/` + `protocol/src/face_gate.dart`).
Size 11003 → 11764 LOC: more, smaller files, net larger — splits added
barrels/wrappers while almost every shrink candidate proved live on
zero-caller check and was kept. CSV unification, stub-entry retirement,
and compat-barrel removal are open product decisions for a later pass.

## Routing map

Canonical names live in `ProxRoutes` (`lib/routes.dart`); deep-link args
in `ProxRouteArgs` (course/session ids + section hint — never record
objects). Guards in `ProxRoutes.isNativeOnly` / `webGuardRedirect`
(web records builds redirect native-only deep-links to `records/mine`;
screens keep their own banners + hidden actions as the second gate).
Preview flags (`PROX_MODE`, `mode.dart`) and `MaterialApp.home` still
drive launch — the table covers entry/records deep-links; live/mark/
enroll render in-tab in their hosts (no named routes for those).

```
welcome · roles · device                        → entry bundle
prof/courses · prof/courses/<course>            → prof setup (overview;
                                                  in-tab identities, also
                                                  deep-linkable)
prof/courses/<course>/sessions/<id>[ /edit]     → session detail (read) / edit
                                                  (in-tab identities)
prof/courses/<course>/export                    → export center (in-tab
                                                  identity, also deep-linkable)
live/<course> (+ /roster /inbox /add            → prof live (one host screen;
  /setup /recover)                                section suffixes land on the
                                                  host — no standalone section
                                                  screens)
mark/* (browse/waiting/face/proving/            → student mark (one
  verdict/manual phases, in-tab only —            continuation; no named
  no named routes)                                mark routes)
enroll/capture · enroll/result                    → SetupFlow steps (same names
                                                  EnrollFlow pushes; standalone
                                                  enroll/intro deleted — SetupFlow
                                                  is the only enrollment flow)
records/mine · records/mine/<course>            → records (in-tab identities)
debug/log                                       → filterable system log
```

Widget→route migration map (for screen tracks; no per-screen one-offs —
extend the shared widget instead of copying it):

- primary/secondary action → `ProxPrimaryButton` / `ProxSecondaryButton`
  (press-scale included; tertiary inline actions stay raw `TextButton`
  until a shared tertiary lands — do not invent a fourth button).
- course/session/student row → `ProxListTile` (`dense: true` for search
  hits); plain content block → `ProxCard`; live dot → `ProxDot(pulse:)`.
- waiting/active/marked/late pill → `ProxStateBadge` (`pulse:` breathes
  while live); "Section (n)" heading → `ProxSectionHeader`.
- sync/offline line → `ProxSyncNote`; error line → `ProxErrorNote`;
  spinner + label → `ProxLoadingRow`; list-empty → `ProxEmptyState`;
  screen shell → `ProxScreen`; full verdict → `VerdictBadge`.
- search field with the `prof-search` key and directory-search fields keep
  their keys and copy (widget-test contract); style via the shared input
  theme, not per-field decoration.

## Rules for all later phases

1. **Tokens first.** No hard-coded `Duration(...)`, `Curves.*`, state hex,
   button shape, or card padding in screens. Import `design/tokens.dart`.
2. **Shared components, no copies.** Button/card/badge/list-tile/empty-state
   already exist in `widgets/prox_*`. If a screen needs a variant, extend the
   shared widget — never duplicate it per-screen.
3. **Animation state is local.** `AnimationController`s live in the widget
   that owns the motion. Never push transient animation state into Riverpod
   providers.
4. **Never gate actions.** Buttons fire immediately. Entrance/stagger motion
   is visual only; the child is hittable on frame one.
5. **Motion vocabulary:**
   - user tapped → `ProxCurves.spring`, micro/small
   - system changed → `ProxCurves.standard`, small/medium
   - screen transition → `ProxCurves.emphasized`, medium/large
    - verdict pop → `VerdictBadge` only (elastic reserved for Marked)
6. **Verdicts differ by motion, not just color:** marked = spring pop,
   late = rise+fade, no-signal = breathing fade, error = one shake.
7. **Reduce-motion:** route durations through `ProxMotion.effective` (the
   `Prox*` widgets already do). Meaning must survive with motion off.
8. **Performance:** no blur/shadow/particle parties on live screens
   (BLE + camera + networking are already hot). One pulsing dot max per
   row; lists rebuild only on data change.
9. **Ambient motion is timer-driven, never an infinite ticker.** Repeating
   `AnimationController`s keep the frame scheduler busy forever and break
   `pumpAndSettle`-based widget tests (caught in Phase 4+5). Pulses and
   breathing use `Timer.periodic` + implicit animations (`AnimatedOpacity`,
   `AnimatedScale`), which settle between fires. One-shot entrance
   controllers (`ProxFadeSlideIn`, verdict pops/shakes) are fine.
10. **Behavior is frozen:** flows, timing guarantees, and security properties
   per `PROXIMITY_DESIGN.md` §7. Refactor freely under that constraint;
   flag anything uncertain for review instead of guessing.
11. **Tests are contracts:** `test/widget_test.dart` asserts on visible copy
    (`Start`, `Join`, `✓ Marked`, …) and field keys (`ipfield`, `direct-*`,
    `edit-*`, `prof-search`). Keep those strings/keys stable.

## Visual identity (Phase 1)

- **Fonts:** Space Grotesk (display/headings/hero) + Inter (body/labels).
- **Palette:** indigo primary `#4340D6`, teal live accent `#0E9F8A`, paper
  `#F5F6FA` / ink `#0E1220`; state colors in `ProxStateColors`.
- **Shape:** 14dp cards, 12dp buttons, pill badges; flat (border, ~0dp).
- **Type scale:** display 700 / title 600 / body Inter; section headers via
  `ProxSectionHeader`, never ad-hoc sizes.
