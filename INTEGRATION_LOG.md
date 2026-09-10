# Proximity UI rebuild — integration log (Phase 5 running record)

Append-only. One entry per section completion + every flagged gap + every spec deviation with justification.

## Status board

| Section | Owner | State | Shared API consumed/produced |
|---|---|---|---|
| Foundation (tokens + ThemeExtension + motion + gradient/glow/elevation) | Foundation subagent | DONE 2026-09-10 (verified: additive only, analyze clean per report, artifacts present) | produces: `ProximityColors.of(context)` (`surfaceBase/Raised/Overlay`, `contentPrimary/Secondary/Tertiary`, `accentBrand`, `statusMarked/Late/Review/Error`, `divider`, `gradientBrand/Marked/Scrim`, `glowLive/Marked`, `elevationRaised/Sheet`), `ProxType` (+mono), `ProxLayout`, `ProxRadii.cardSpecRadius/sheetTopRadius/pill`, `ProxDurations.tabCrossFade/push/sheet/step/verdictWash/ringMorph/reducedFade`, `ProxIcons.statusIcon/statusColor`. Legacy theme defaults frozen (D3–D5); new code uses new tokens, old screens migrate per-section |
| Shared components (StudentCard, VerdictBadge, AccountChip, FallbackButton, SelectionToolbar, DetailsExpander, two-oval overlay, selection provider, log drawer + terminal restyle) | Shared subagent | DONE 2026-09-10 (verified: 10 new widget files present, zero Checkbox/face-gallery/raw-color hits, old prox_* untouched, debug_log restyle in place; full suite 330/330 per report) | APIs: `StudentCard` (+`studentInitials/ColorIndex/AvatarColor`), `VerdictBadge` (+`labelFor`), `AccountChip` (+`largeHeader`), `FallbackButton` + `showProxSheet`, `SelectionController` + autoDispose provider + `SelectionScope`, `SelectionToolbar`, `DetailsExpander`, `CaptureOverlay` (angle-count-agnostic) + `CaptureSignal`, `showLogDrawer` (+`Expand` w/ tag filter), `log_category`. Gap 3 verified: controller is 5 slots, README 3-still stale. D6–D10 logged (badge backing, scrim barrier, haptic, spacing, no long-press tooltip) |
| Navigation shell + Setup flow (IndexedStack shells, transitions, Mark gate, PopScope removal, SetupFlowScreen, two-oval enroll wiring, M1) | NavSetup subagent | DONE 2026-09-10 (verified: shells.dart + setup_flow_screen.dart + features/setup/ + setup_shell_gate 13 tests present; PopScope pattern gone except setup stepper's own; courses/* aliases + _MarkGate in routes; suite 343/343 per report) | APIs: `StudentShell`/`ProfShell` (tab children: StudentHome/MyAttendance/RoleHub-interim; _LiveRoot/ProfCourses/RoleHub-interim), `proxSharedAxisRoute`, `SetupFlowScreen` (+`setupStartIndex`, `SetupStep`), gate = linkedIdentity (best-candidate, flagged). Residuals for owners: overlay swap orphan (mark/face→Mark section; enroll/capture→integration); `_changed` removal → Courses verifies hide-reload; RoleHub interim tabs → Account replaces; take-dispose residual → Live; M1 partial accepted (driver stays with capture step) |
| Mark flow (browse→verdict, gradient moment, CaptureOverlay swap) | Mark subagent | DONE 2026-09-10 (verified: 6 mark files rewritten, FaceOval→CaptureOverlay 5-angle, Marked wash+glow single-use, sibling compile errors fixed, Appendix-A grep passed, mark suites green; full suite +351/−15 all in others' in-flight files) | APIs consumed as planned; JoinByIpSection reused verbatim as sheet content; no file moves. MARK-D1–D7 logged (headline kept, manual wiring late/noSignal/wrongOrg, trail pills verbatim, no CTA-gradient w/o shared button, BT-off unchanged) |
| Account (consolidated page + face-id, replaces interim tabs) | Account subagent | DONE 2026-09-10 (features/account/: theme_mode, account_screen student+prof, face_id_screen, 13 tests; tab lines swapped; main.dart +3 theme wiring) | Gap 2 RESOLVED read-only (no server write path; pinned by test); gap 6 resolved (once-a-month copy); avatar-initials flag stands; ACC-D1–D3 logged (theme wiring, face-id deep-link needs routes-owner line, re-enroll pushes preserved enroll chain) |
| Courses tab both shells (records-only, Take/Retake removal) | Courses subagent | DONE 2026-09-10 (7 records files rewritten/restyled; Take/Retake + import deleted; hold-and-tap multi-delete; edit-page per-round boxes stay; hide-reload + matrix golden pinned in records_rebuild_test) | Gap 4 RESOLVED (negative-check grep zero hits); COURSES-D1–D5 logged. Residual: CourseAttendanceRouteLoader hidden-filter + full-suite rerun once Live/Mark trees compile (blocked at load by sibling errors at report time — Mark's fixed since) |
| Live tab + manual_attendance module (M3, _LiveRoot, dispose residual) | Live subagent | DONE 2026-09-10 (module created: manual_directory + manual_add_form + manual_inbox + barrel; live sections rewritten; take_attendance composition-only; manual_add.dart now shim w/ identical() proof; full suite 365/1, sole failure Records-owned Partial-duplicate) | M3 DONE (move list logged); dispose-residual stays OPEN (behavior change to move); LIVE-D1–D5 logged (toolbar routing, static Late badge w/ Shared flag, harness, ClockHeader drop, no shells edit) |
| Integration fixes (enroll overlay swap, failing-test fix, face-id route line, full green) | Integration subagent | DONE 2026-09-10 (enroll_capture→CaptureOverlay controller-derived 5, dots usage removed; Partial-duplicate source-fixed 3-line; faceId route const+entry; analyze 1 pre-existing info; full test 366/366; flutter build web green) | Orphans left for Phase 6: unused FaceOval/EnrollAngleDots classes. Live dispose-residual stays OPEN |
| Responsive/accessibility pass (§9 + §10/§10.1) | A11y subagent | DONE 2026-09-10 (16 files touched/created, responsive_a11y 16/16, full suite 382/382; coach-mark implemented w/ persisted flags; contrast measured vs darkest stop) | Take-host 560-wrap reverted w/ proof (breaks frozen widget_test); light flat badge tints flagged for Foundation (spec-frozen hex, meaning carried by icon+word) |
| Phase 5 tree-wide verification (orchestrator) | Orchestrator | DONE 2026-09-10 via grep: Checkbox only session_edit; records zero hosting words; gradients token-sourced only (tokens/live-header/capture-scrim/verdict-wash/account — all c.gradient*); FaceOval zero non-test uses; zero gallery reads in widgets/account; Mark gate on linkedIdentity; faceId route entry present |
| Phase 6 dead-code cleanup | Cleanup subagent | DONE 2026-09-10 (deleted FaceOval+_OvalPainter, EnrollAngleDots + its 2 dead tests; kept PresentTicker/face_capture/entry_flow/shim w/ ref evidence; analyze 1 pre-existing info; full test 381/381; web build green) | Pass complete — no second design pass held |
| Navigation shell (IndexedStack 3-tab both shells, transitions, Mark gate, PopScope removal) | — | blocked on Foundation | consumes tokens (+ AccountChip for Account tab icon); produces tab/shell API + enrollment-gate signal |
| Setup flow (SetupFlowScreen + steps, two-oval enroll capture) | — | blocked on Foundation + Shared + Shell | consumes gate signal, overlay, stepper chrome; resolves M1 move |
| Mark flow (browse→verdict, one gradient moment) | — | blocked on all above; last among screens | consumes everything; owns `mark/verdict → Marked` gradient moment |
| Account (consolidated page + account/face-id) | — | blocked on Foundation + Shared | produces consolidated account page; ID-edit read-only unless write path confirmed |
| Courses tab both shells (records-only + negative check) | — | blocked on Foundation + Shared | negative check: no hosting/marking affordance |
| Live tab professor + manual_attendance module | — | blocked on Foundation + Shared | produces `features/manual_attendance/`; resolves M3 move |
| Responsive/accessibility pass (overflow §10.1, gradient contrast §9) | — | blocked on all sections | cross-cutting final |

## Gaps flagged (unresolved until noted; never silently guess)

1. Enrollment-signal gap (§3.4): no doc states the concrete "not enrolled" signal or where the Mark-tab guard lives. Assignee (Navigation shell) must reuse RoleHub's existing signal; if none covers cleanly, surface. Status: OPEN.
2. ID-edit write-path gap (§5.1): confirm server-side write path exists before wiring edit; else read-only + report. Status: OPEN.
3. 3-vs-5-angle mismatch (§6.2): README says 3 stills, SCREEN_MAP + code say 5. Two-oval overlay must match the actual capture-controller code; report which count. Status: OPEN.
4. Take/Retake on CourseOverview diverges from §3.1a records-only. Rebuild removes. Status: OPEN (Courses section).
5. Manual inbox checkboxes diverge from hold-and-tap rule. Rebuild replaces via manual_attendance module. Status: OPEN (Live section).
6. Move-cadence copy (`once a month` vs `once a week`); code is 30-day. Rebuild uses month-accurate copy behind DetailsExpander. Status: OPEN (Account/Setup sections).

## Deviations from spec with justification

- D1 (2026-09-10): Phase 2 bulk wipe deferred into section-scoped delete-then-rebuild. Justification: same end state (all old presentation replaced), avoids an uncompilable intermediate with no safety benefit; FEATURE_INVENTORY.md is the proof of what must come back; preservation checklist per section in Phase 2 record. Not a scope cut.
- D2 (2026-09-10): Phase 1 forced no splits. `features/records/*` exempt (no timers/drivers; hosts don't exist); `entry_flow.dart` exempt on no-widget-trees condition; M1/M3 moves deferred to their sections as mechanical, called-out moves. Justification: split-everything-now risked semantics for zero isolation gain.

## Verification checklist (applied per section before marked done)

Tokens (no raw colors) · component reuse (no bespoke tiles/checkboxes) · no dead routes · fallback affordances low-emphasis · verdict vocabulary + timing/threshold constants byte-for-byte · gradients/glows confined to §2.5 exceptions · overflow rules applied · Courses no hosting/marking affordance · Mark gate blocks unenrolled · overlay exactly two ovals · avatar Gmail-photo-only.

*(Append-only below this line.)*

## Foundation completion (2026-09-10)

- Landed: `ThemeExtension<ProximityColors>` (dark/light, §2.1 + §2.5 full set:
  12 semantic colors, `gradientBrand/gradientMarked/gradientScrim`,
  `glowLive/glowMarked` via `ProxGlow`, `elevationRaised/elevationSheet`
  as `BoxShadow`), wired via `extensions` on both `proxLightTheme()` /
  `proxDarkTheme()` (`lib/design/app_theme.dart`); `MaterialApp.theme` /
  `.darkTheme` + `ThemeMode.system` already in `lib/main.dart`, unchanged.
  Plus `ProxType` (§2.2 scale, Inter, 400/500/600, mono body/caption),
  `ProxLayout`/`cardSpec`/`sheetTopRadius`/`pill` (§2.3 spec values,
  additive), `ProxDurations.tabCrossFade/push/sheet/step/verdictWash/
  ringMorph/reducedFade` (§3.2/§3.3/§6.3), `ProxStatus` + `ProxIcons`
  outlined-default/filled-active + status color+shape map (§2.4/§4.2).
  Contrast-vs-darkest-stop documented per gradient on `ProximityColors`
  with measured ratios (brand-light white 5.20:1 pass; brand-dark white
  3.16:1 large-text/UI only → header wash must stay subtle; marked-dark
  needs dark ink 8.27:1, white 2.19:1 FAIL → badge content on wash is dark
  ink; scrim carries no text ever). No orchestration moved (nothing to
  move in Foundation scope). Tests: `test/proximity_colors_test.dart`
  (7, new) + `test/app_theme_test.dart` (2) + `track5_states_test` +
  `widget_test` all pass; `flutter analyze`: no issues.
- Raw-`Colors.*` migration NOT complete (flagged, not fixed — section
  owners migrate their screens onto `ProximityColors`): `features/debug/
  debug_log_screen.dart` terminal chrome (`Colors.black/grey.shade700/
  grey.shade900/white70/white38` — terminal stays brightness-independent
  by design; Shared-components owner decides terminal-chrome tokens vs
  `content.*`); `screens/face_capture.dart` scrim dim `Color(0x73000000)`
  + ring white → `gradientScrim`/content tokens (Mark/Setup sections);
  `features/enrollment/enroll_widgets.dart` `Colors.transparent` is
  allowlisted (absence of color, not a theme color). Enforcement is the
  documented grep in `lib/design/tokens.dart` header (no lint infra added
  per scope). Status: OPEN (per-section).
- D3 (2026-09-10): `ProxType` declares single-family Inter 400/500/600;
  live `textTheme` keeps Space Grotesk+Inter + Bold 700. Justification:
  flipping the theme font now would restyle every screen (out of
  Foundation scope); consolidation happens in Shared-components with a
  pubspec/asset check. Not a behavior change.
- D4 (2026-09-10): `ProxSpacing.screen` (16) + `ProxRadii.card` (14) stay
  frozen; spec values land as additive `ProxLayout`/`cardSpec`/`sheet`/
  `pill` tokens for new code. Justification: same as D3 — no silent
  global restyle; sections migrate screen-by-screen. Not a behavior change.
- D5 (2026-09-10): `ThemeData` scheme/scaffold/card/divider defaults keep
  legacy `ProxPalette`-derived values; Foundation wires ONLY the new
  `extensions`. Justification: re-deriving defaults now would shift every
  current screen's surfaces (spec surfaces differ: `#FAFAFA` vs `#F5F6FA`,
  `#0B0D10` vs `#0E1220`); sections adopt `ProximityColors` as they
  rebuild. `ProxPalette`/`ProxStateColors`/`ProxLogColors` frozen as hard
  deps (terminal colors kept verbatim per scope rule). Not a behavior change.
- Gap (enrollment-signal §3.4), gap (ID-edit write path §5.1), 3-vs-5
  angle mismatch: untouched by Foundation, remain OPEN for their owners.

## Shared-components completion (2026-09-10)

- Landed (all new files, old `prox_*` untouched for Phase 6):
  `lib/widgets/student_card.dart` (`StudentCard` + `RoundTick` +
  `studentInitials`/`studentColorIndex`/`studentAvatarColor` pure helpers),
  `lib/widgets/verdict_badge.dart` (`VerdictBadge`, `labelFor`, elastic
  flip-to-Marked inside), `lib/widgets/account_chip.dart` (`AccountChip`,
  `largeHeader` wash flag), `lib/widgets/fallback_button.dart`
  (`FallbackButton` + `showProxSheet`), `lib/widgets/selection_controller.dart`
  (`SelectionController` + `selectionControllerProvider` autoDispose +
  `SelectionScope`), `lib/widgets/selection_toolbar.dart`
  (`SelectionToolbar` + `SelectionToolbarAction`),
  `lib/widgets/details_expander.dart` (`DetailsExpander`),
  `lib/widgets/capture_overlay.dart` (`CaptureOverlay` + `CaptureSignal`),
  `lib/widgets/log_category.dart` (`logCategoryColor`),
  `lib/widgets/log_drawer.dart` (`showLogDrawer` + `LogDrawerContent`),
  `test/shared_components_test.dart` (23 tests, new).
- Restyled in place: `lib/features/debug/debug_log_screen.dart`
  (tokens only + additive `initialTags`; data contract byte-identical:
  `BleLog` stream/tags, 500-entry ring, 200ms flush, stick <100px,
  All+13 chips, `Clear`, verbatim empty/count copy, no entrance
  animation). Resolves Foundation's OPEN terminal-chrome flag for this
  screen: well stays brightness-independent black via
  `ProxPalette.terminalBlack`, lines on frozen `ProxLogColors`, chrome on
  `ProximityColors`.
- Downstream APIs: Live section consumes `SelectionScope` (one per list)
  + `selectionControllerProvider` + `SelectionToolbar` (+ `showProxSheet`
  for its sheets) to build `features/manual_attendance/` (NOT built here);
  Mark/Setup sections consume `CaptureOverlay(progress,currentAngle,
  totalAngles,targetDirection?,signal,statusLine?,sweepAngle?)` for
  `mark/face` + `enroll/capture`; all screens consume `StudentCard`,
  `VerdictBadge`, `AccountChip`, `FallbackButton`, `DetailsExpander`;
  wave-3 wiring sections call `showLogDrawer(context)` from logging
  screens (drawer NOT wired into any screen here — components only).
- No orchestration moved (nothing to move in components scope). No
  screen rewrites, no route changes, no `lib/design`/`lib/core`/
  `lib/main.dart` touches. `features/manual_attendance/` NOT built
  (Live section owns it).
- Gap 3 (3-vs-5 angles) verified against code: the actual controller is
  5 (`faceEnrollSlots = centre/left/right/up/down` in
  `features/face_identity/face_verifier.dart`, enforced in
  `core/enrollment.dart` + plugin adapter); the README 3-still note is
  stale. `CaptureOverlay` takes any total (tested 1/2/3/5/7, clamps
  out-of-range) — gap stays OPEN only as a docs fix, not a build
  question.
- D6 (2026-09-10): Gmail badge backing uses the `surfaceRaised` token,
  not a literal white circle. Justification: the no-hardcoded-colors +
  dark/light-parity constraints win over the literal "white" — same job
  (reads on any photo) in both themes. Not a behavior change.
- D7 (2026-09-10): sheet barriers use the `gradientScrim` end-stop color
  (`barrierColor` takes a flat color, not a gradient) + `elevationSheet`
  shadow on the sheet body. Justification: closest token-faithful use of
  the scrim behind a modal barrier; no hand-authored dim. Not a behavior
  change.
- D8 (2026-09-10): the 12ms hold-select haptic is
  `HapticFeedback.lightImpact()` (platform selection tick —
  `HapticFeedback` exposes no duration parameter). Not a behavior change.
- D9 (2026-09-10): the brief names `ProxLayout`; the repo has
  `ProxSpacing` (spec values live there: `screenMargin` 20,
  `cardPadding` 16, `minTap` 48). New code uses `ProxSpacing`. Naming
  only, not a behavior change.
- D10 (2026-09-10): `StudentCard` long emails truncate with ellipsis but
  carry no long-press tooltip — long-press is owned by hold-and-tap
  selection with no exception (§4.1 beats §10 here). Not a behavior
  change.
- Verify: `flutter analyze` — no issues. `test/shared_components_test.dart`
  — 23/23 pass. Scoped existing: `proximity_colors_test` +
  `app_theme_test` + `track5_states_test` + `widget_test` — 42/42 pass.
  Full `flutter test` — 330/330 pass.

## 2026-09-10 — Nav-shell + Setup-flow section (shells, gate, flow, PopScopes)

### Mechanical moves (git mv; content verbatim except noted extractions/branches)
- NAV-M1: `features/entry/welcome_screen.dart` → `features/setup/welcome_screen.dart` (untouched).
- NAV-M2: `features/entry/role_hub_screen.dart` → `features/setup/role_hub_screen.dart` (untouched; import path fix only).
- NAV-M3: `features/entry/device_identity_screen.dart` → `features/setup/device_identity_screen.dart` (+ scaffold/body/content extraction, NAV-M9).
- NAV-M4: `features/enrollment/enroll_intro.dart` → `features/setup/enroll_intro.dart` (+ extraction NAV-M9, STEP-SCOPE branches).
- NAV-M5: `features/enrollment/enroll_capture.dart` → `features/setup/enroll_capture.dart` (STEP-SCOPE nav branches ONLY — camera/session/overlay/dots/status lines untouched; the `enroll_guided_test.dart` parity pins still hold).
- NAV-M6: `features/enrollment/enroll_result.dart` → `features/setup/enroll_result.dart` (STEP-SCOPE nav branches ONLY).
- NAV-M7: `features/enrollment/enroll_widgets.dart` → `features/setup/enroll_widgets.dart` (untouched, incl. `EnrollNav.finish`).
- NAV-M8: `features/enrollment/enroll_flow.dart` → `features/setup/enroll_flow.dart` (untouched — `openBundle/openCapture/openResult` chain preserved for standalone routes/tests).
- `features/entry/entry_flow.dart` STAYS (M2 exempt, decisions-only). `features/enrollment/` dir removed (emptied).
- Import updates from the moves: `lib/{main,routes,screens/landing,screens/student_home}.dart` + `test/{widget,enroll_account_roll,enroll_beacon_boundary,enroll_guided}_test.dart` (incl. the two `File('lib/features/enrollment/enroll_capture.dart')` provenance strings).
### Step-content extractions (same file, standalone rendering identical)
- NAV-M9: `DeviceIdentityScreen` → `DeviceIdentityBody` (scroll wrapper) → `DeviceIdentityContent` (scroll-free `ProxStaggered` content, state impl verbatim).
- NAV-M10: `EnrollIntroScreen` → `EnrollIntroBody` (`ProxScreen` chrome) → `EnrollIntroContent` (scroll-free content, build verbatim).
- NAV-M11 (new): `features/setup/device_intro_step.dart` — combined Confirm-device step (`DeviceIdentityContent` + `EnrollIntroContent`, one scroll, intro's own Continue CTA).
### New orchestration (mine, screens/ + setup-step scope)
- NAV-N1 (new): `lib/screens/setup_flow_screen.dart` — `SetupFlowScreen` (one flow, two triggers). PageView, NeverScrollable, 150ms step slides (`ProxDurations.step`, reduced-motion jumps), `SetupProgressLine` per page (no numbers/labels; titles stay in each step's own app bar), start index from account → role cache → device key → controller phase (pure `setupStartIndex`, unit-tested), silent `pickUpAccount` mirror of the standalone intro, state listeners (sign-in advance / sign-out reset / faceDone+uploaded fast-forward), PopScope step-back with first-step → `onFirstBack`. Capture page mounts lazily (`_seenCapture`) so the flow never opens the camera on the sign-in step.
- NAV-N2 (new): `lib/screens/shells.dart` — `StudentShell` (Mark/Courses/Account) + `ProfShell` (Live/Courses/Account). IndexedStack + one Navigator per tab (stack + scroll preserved), token bar (surfaceRaised + hairline divider, active filled + accent.brand, inactive outlined, icon-only <360dp), 120ms cross-fade + 4dp icon settle, `proxSharedAxisRoute` (§3.2: 220ms slide+fade in, outgoing →60% + 98%, exact reverse, reduced → 100ms opacity; used for gate-flow + Live→host pushes), tab navigators resolve names exactly like the root router (same table + guards + unknown placeholder), shell back = pop-own-stack else double-back hint/leave (2s window, UI affordance only), Mark gate pushes the flow when `linkedIdentityProvider` is null, `_LiveRoot` (register-free course list → host; web = records guidance, never hosting).
- NAV-N3 (new): `features/setup/{setup_step_scope.dart (SetupStep indices 0-4 + scope), setup_progress.dart}`.
- NAV-N4: `AdaptiveScaffold` gains optional `leading` (additive; existing callers unaffected) so TakeAttendance's explicit leave has a bar button.
- NAV-N5: routes — `courses/mine` + `courses/course/<course>` aliases (records/* retained, no dead routes); all `mark/*` builders → `_MarkGate` (unenrolled → SetupFlow with first-back → roles replacement, complete → pop; enrolled → StudentHome); `main.dart` home → shells + enroll-home flow (sync triggers untouched).
### Gate signal (GAP 1 audit — best-candidate wired + flagged)
- NAV-G1: gate signal = `linkedIdentityProvider` (a set linked identity = this device completed the claim). Audited candidates: role cache = registration (registered ≠ enrolled — insufficient alone); `EnrollmentController` phase = session-only (lost on restart); `store.readEnrollment()` = persisted truth but async (linked mirrors it: set at startup-restore + upload-success, cleared on sign-out). Same signal the Mark browse card + join gate already use, so gate and card can never disagree. Imperfection (flagged, pre-existing): account-switch without restart can leave linked null for an enrolled device — browse card behaves identically today.
### Overlay (gap 3 + Shared TODO)
- NAV-G2: capture = 5 angles confirmed in code (`faceEnrollSlots` centre/left/right/up/down; controller requires 5 paths). Capture step keeps CURRENT `FaceOval` + `EnrollAngleDots` (parity test pins `FaceOval(` — untouched).
- NAV-TODO1 (Shared): swap BOTH mark/face (`screens/student_home.dart`) and enroll/capture (`features/setup/enroll_capture.dart`) `FaceOval` usages for the spec two-oval `CaptureOverlay` once it lands (angle-count-agnostic: pass totalAngles 5 for enroll; capture file edits must keep `enroll_guided_test.dart` green).
### PopScope sites (pattern deletion only; timers/drivers/drafts/relays untouched)
- NAV-P1 `screens/student_home.dart`: browsing → `setMode(unset)` + non-browsing leave-to-browsing removed. Shell owns back now.
- NAV-P2 `screens/take_attendance.dart`: `→ _leave` removed; `_leave` (autosave + endHosting) preserved and now explicit via the bar BackButton; system-back pops through the unchanged dispose path. §3.5 residual (flagged for Live section): popping the host still tears it down via dispose — full hint-only needs the host lifecycle moved off the route; teardown-on-pop equals today's explicit-pop behavior.
- NAV-P3 `features/records/prof_courses_screen.dart` (PopScope lines ONLY — Courses section: preserve this deletion on rewrite).
- NAV-P4 `features/records/course_attendance_detail_screen.dart` (PopScope lines + now-dead `_changed` flag ONLY — Courses section: preserve deletion; re-adopt always-refresh-on-return since back now yields null).
### Gaps/deviations
- NAV-G3 (avatar): `SignedAccount` has no photo field — Account tab uses the initial (+ accent ring when active). Gmail-photo needs auth plumbing (not invented).
- NAV-G4 (badge): no existing new-session-arrival signal (`pendingCount` = outbound unsynced) — Courses badge dot omitted.
- NAV-D1: fresh-install first-step back = hint Snackbar (`Complete setup to continue`) — no Account exists yet; never bare mark.
- NAV-D2: web Live tab = records guidance line under the exact `WebRecordsBanner` copy (live/* stays native-only; desktop unaffected).
- NAV-D3: Account tabs host `RoleHubScreen` as interim content pending the Account-section consolidated page (no face content for profs; RoleHub already satisfies).
- NAV-D4 (M1 partial): capture session driver stays colocated with the capture step (parity-test lock + camera lifecycle tied to step visibility); the stepper owns the step graph/transitions/progress only. Full driver extraction deferred.
- NAV-D5: `SetupFlowScreen` pages are the existing screens (own AppBars = current-step titles); the thin progress line is prepended per page — no double chrome, no step labels.
### Tests migrated (structure-only; all verdict/timing/copy contracts intact)
- New `test/setup_shell_gate_test.dart` — 13/13 pass (pure `setupStartIndex` ×6; student shell gate ×2; prof shell ×1; flow start + progress ×1; courses alias + mark gate ×3).
- `test/widget_test.dart` migrated: `openTab` helper (offstage tabs); prof-take tests enter via the Live root (overview `Take attendance` taps removed; post-End expects target the Live root); catalog/session-edit tests tap Courses first; join-gate tests pump `StudentHomeScreen` directly (new `testScope(home:)` param); enrollment journey follows the flow (combined-scroll key `setup-combined-scroll`); transient-lifecycle test sends the OS-faithful sequence (inactive→hidden→paused→hidden→inactive→resumed) because the shell keeps offstage tab fields mounted and their framework listeners enforce the valid order (app handler treats hidden as backgrounded already — expectations unchanged).
- NAV-D6: shell widget tests use stepped 500ms pumps, not single long pumps — lets each periodic tick's async tail settle before the next step (single long pumps race stagger one-shots at teardown).
- Verify: `flutter analyze` — clean (1 pre-existing info in untouched `welcome_screen.dart:53`). Full `flutter test` — 343/343 pass (incl. `widget_test` 29/29, `enroll_guided` parity 27/27, `setup_shell_gate` 13/13, `proximity_colors` intact).

## 2026-09-10 — Account section (consolidated page + face-id, interim tabs replaced)

### Files created (mine, `apps/proximity_app/lib/features/account/`)
- `theme_mode.dart` — `themeModeProvider` (`StateNotifierProvider<ThemeModeController, ThemeMode>`, default system) + `themeModePrefsKey = 'prox.themeMode.v1'` + pure `themeModeFromName/ToName`. SharedPreferences-backed, best-effort load/persist, never throws. THE called-out addition (§5.1 theme row; no switcher exists today — `main.dart` was fixed `ThemeMode.system`).
- `account_screen.dart` — `StudentAccountScreen` (header, Enrollment, read-only ID, Face-ID row, Device, Theme, System log, separated Sign-out) + `ProfAccountScreen` (header, device/key facts, Theme, System log, Sign-out; NO Face-ID, NO enrollment section) + private `_FactRow`/`_EnrollmentSection`/`_IdRow`/`_FaceIdRow`/`_DeviceSection`/`_ThemeRow`/`_ProfDeviceFacts`. Presentational only: reads account stream, linked identity, `StoredEnrollment`, `entryStudentGate` verdict, install/host-name store reads; decisions stay in `entry_flow.dart`/controller (calls `entrySignOut`, `entryStudentGate`, `studentClaimMessage` verbatim).
- `face_id_screen.dart` — `FaceIdScreen` (`account/face-id`): status line only (`Enrolled · <verifierVer>` / `Needs re-face`), low-emphasis `Re-scan face` FallbackButton. Built WITHOUT `AccountChip`/`StudentCard`/any avatar layout — plain text rows only, so no stray image widget can leak in. Re-scan calls the SAME controller function the enroll-result screen calls (`restartFace`, key kept) then continues into the preserved standalone capture chain (`EnrollFlow.openCapture` → result). Records-only devices get `FaceBlockedCard(flow: 'Face ID')`.
- `test/account_screen_test.dart` — 13 tests (sections render; ID read-only pin — value shown, `TextField` findsNothing; cooldown verbatim date + no move entry; allowedMove fallback; face-id push + never-preview `Image` findsNothing; stale → Needs re-face; records-only blocked card; signed-out → Welcome; sign-out clears auth+linked; theme persists to prefs; prof page has no face content; shell Account tabs host the consolidated pages).

### Tab lines swapped (ONLY these two lines in `shells.dart`, +1 import)
- Student shell root `const RoleHubRoute(),` → `const StudentAccountScreen(),`; prof shell root `const RoleHubRoute(),` → `const ProfAccountScreen(),`. `RoleHubRoute` itself untouched (setup flow + role hub still use it). Nothing else in that file changed.
- Wiring (mechanical, same called-out addition as the provider): `main.dart` gains `import 'features/account/theme_mode.dart'` + `final themeMode = ref.watch(themeModeProvider)` → `themeMode: themeMode` (was fixed `ThemeMode.system`). 3 lines; no other `main.dart` change.

### ID-edit verdict (gap 2 → RESOLVED as read-only)
- NO server-side write path exists: `CloudSync` exposes roll writes ONLY via the atomic `claimStudentDevice(doc: StudentDeviceDoc…)` enrollment transaction; `FirestoreCloudSync.writeStudentDevice` deliberately throws (`use claimStudentDevice (atomic verdict + cooldown), not a raw write`); `StudentDirectoryEntry` is "written by the claim transaction, never by hand"; `EnrollmentController.setRoll` stages the pre-claim draft only. A post-enrollment ID edit would need a new server write + rules change = new business logic, out of scope. ID row renders the linked/stored roll read-only (mono, `account-id-row` key) + the gap is pinned by test (no `TextField`). No edit control wired.

### Theme implementation
- `_ThemeRow`: `SegmentedButton<ThemeMode>` System/Light/System-first order (System, Light, Dark), 48dp min height, inline on the row (the one row that's a control, not a push — no checkboxes anywhere). Persists via `themeModeProvider.set` → prefs; `ProximityApp` watches it. Verified by test (tap Dark → provider dark + prefs `dark`).

### Avatar / device-model flags (stands, both same class — not invented)
- `SignedAccount` carries no photo field (verified `core/auth.dart`: email/displayName/uid/org only) → `AccountChip(photoUrl: null, largeHeader: true)` renders the deterministic initials avatar via its own errorBuilder→initials fallback (same flag as NAV-G3). 56dp avatar + subtle `gradient.brand` wash come from the Shared `largeHeader` implementation — the ONLY gradient on these pages.
- No device-info plumbing exists anywhere → Device "model" row renders the existing claim-stamped `binding.platform` (else local `defaultTargetPlatform.name`), labeled `Device model`. Same-install free wording, 30-day/`once a month` move copy, refusal strings, trust labels, offline/hosting note, records-only note, and `Switch account (sign out)` label are all verbatim from existing copy.

### Web hiding (exactly as today)
- `!canUseFace()` → enrollment/ID/face/device sections replaced by the verbatim records-only note (same branch shape as the pre-auth device screen); header/theme/log/sign-out stay. `FaceIdScreen` gates to `FaceBlockedCard` on records-only. `WebRecordsBanner` tops both pages (no-op on native).

### Gaps/deviations
- Gap 2 (ID write path): RESOLVED — read-only + reported (see verdict above).
- Gap 6 (move cadence): RESOLVED — all move copy uses `once a month` (code is 30-day `kStudentMoveCooldown`); the one `once a week` RoleHub note lives in Setup scope, untouched.
- ACC-D1 (mechanical, called-out): `main.dart` themeMode wiring (3 lines, part of the theme-persistence addition above). No attendance semantics touched.
- ACC-D2 (ownership residual, NOT worked around): `account/face-id` is pushed in-tab with `RouteSettings(name: 'account/face-id')` but has no `routes.dart` table entry — the table is outside Account ownership, so deep-links to it land on the unknown-route placeholder until the routes owner adds the one-line entry. In-tab navigation is unaffected.
- ACC-D3 (no-orchestration-moved confirmation): re-enroll/move entries push the preserved standalone `enroll/intro` chain (`intro → capture → result` via the existing `EnrollFlow.open*` methods); no flow logic moved or copied.

### Verification
- PENDING at log time (tree blocked by sibling in-progress work — see note below); filled before marked done.

## 2026-09-10 — Courses section (records-only rebuild, both shells)

### Status vs prior work
- Already done by NavSetup (untouched here): PopScope-line removals in `prof_courses_screen.dart` + `course_attendance_detail_screen.dart` (incl. `_changed` flag removal), `shells.dart` shells + register-free `_LiveRoot`, `courses/*` route aliases, `_MarkGate`, Foundation tokens, Shared widgets.
- Done here: full presentation rebuild of all 7 `features/records/*` screens onto tokens + Shared components, Divergence-4 (Take/Retake) removal, overview checkboxes → hold-and-tap, log-drawer entry, test updates + new regression tests.

### Files changed (mine)
- `apps/proximity_app/lib/features/records/my_attendance_screen.dart` — rewrite: token course cards (progress RING `accentBrand` primary + `x/y days` fraction caption verbatim via `summarizeCourse.line`), totals header verbatim, `DetailsExpander` for cache/convergence prose, log icon → `showLogDrawer`, parent ALWAYS reloads on detail return (see COURSES-D2). Data logic (`_load`, grouping A–Z, totals) byte-identical.
- `apps/proximity_app/lib/features/records/course_attendance_detail_screen.dart` — rewrite: totals header ring-large + `P present · Pa partial · A absent · S days taken` verbatim, session tiles as `StudentCard` reduced variant (name=`sessionDateTimeLine`, subtitle=status · rounds · label · org verbatim, `VerdictBadge` with `sessionStatusOf` word, round-trail chips) + device-only hide `IconButton` verbatim tooltip/snackbar/log. No PopScope (preserved deletion).
- `apps/proximity_app/lib/features/records/prof_courses_screen.dart` — rewrite: token picker cards (folder icon + `N sessions · lastDate` verbatim), register dialog verbatim (`Register course`/`Course name`/`CS201`/`Cancel`/`Register`), sync strings verbatim, `Host:` identity line verbatim, Switch-mode untouched, `DetailsExpander` for pull-merge prose, log icon → drawer. Registration STAYS (management, not hosting — `_LiveRoot` is register-free, verified `lib/screens/shells.dart:478-585`, unmodified).
- `apps/proximity_app/lib/features/records/course_overview_screen.dart` — rewrite: Take-attendance + Retake + `take_attendance` import REMOVED (gap 4 resolved); union header `people · sessions` verbatim; `Partial (n)` marker verbatim (as `VerdictBadge` pill, see COURSES-D1); X/Y warning dialogs verbatim; rename dialog verbatim; bulk delete via one `SelectionScope` + `SelectionToolbar` (`Delete N · Select all · Cancel`), zero `Checkbox`; per-session Export entry kept; NO `LIVE now` chip (omitted entirely per brief); web hiding as today (rename/delete-selection/delete-course gone on web, export stays); `DetailsExpander` for union prose; log icon → drawer.
- `apps/proximity_app/lib/features/records/session_detail_screen.dart` — rewrite: header/totals/`Partial (n)` copy verbatim, `Fix marks` (native) + `Export CSV` (always) verbatim, person rows as `StudentCard` (name + `ticks · roll · email` verbatim), web-banner-only-on-web preserved, `_reload` after edit preserved, log icon → drawer. Dead `_isPartial` helper removed (COURSES-D4).
- `apps/proximity_app/lib/features/records/session_edit_screen.dart` — log icon → drawer ONLY; per-round `Checkbox`/`CheckboxListTile` tristate + partial/absent quick lists + `Mark present` + unified `ManualAddForm(edit-*)` + `Save changes` + monotonic-stamp save all byte-identical (the one confirmed checkbox exception).
- `apps/proximity_app/lib/features/records/export_center_screen.dart` — rewrite: per-session CSV + date-range matrix logic byte-identical (`withOrgLine`, filenames, subjects, `…` range label, `No classes took place in …` verbatim, `Close/Save/Share` via `showCsvPreviewDialog`, web Save-download path intact), token rows, `DetailsExpander` for matrix-key prose, log icon → drawer.
- `apps/proximity_app/test/course_test.dart` — overview test is now records-only (no Take/Retake/Checkbox asserts); delete test uses long-press → `Delete 1` toolbar + X/Y warning; stale Live-root comment corrected.
- `apps/proximity_app/test/widget_test.dart` — `prof enlists new course` now expects `Review & export` and no `Take attendance`; 4 stale overview-button comments corrected (behavior unchanged).
- `apps/proximity_app/test/records_rebuild_test.dart` — NEW: hide-inside-detail reloads parent end-to-end, matrix golden bytes, overview records-only UI (no Take/Retake/Checkbox/LIVE; tap opens detail; long-press → Delete; Cancel exits).

### Take/Retake removal evidence
- Deleted from `course_overview_screen.dart`: `_takeAttendance()` method, `Take attendance` `ProxPrimaryButton`, per-row `Retake attendance` `IconButton`, `import '../../screens/take_attendance.dart'`.
- Hosting still works via the untouched `_LiveRoot` (`shells.dart:483-585`): register-free course list → `TakeAttendanceScreen` push; empty state points at Courses for registration. Verified by reading only; zero edits outside `features/records/*` + tests.

### Negative-check grep output (`apps/proximity_app/lib/features/records/`)
- Strict affordance grep `Take attendance|Retake|Take another|LIVE now|live/|Go live|go live|Hosting|hosting|Join|join now|'Start'|"Start"|'Stop'|"Stop"` → ZERO HITS.
- `take_attendance|features/live|features/mark|features/setup|screens/student_home|screens/take_attendance` imports → ZERO HITS (nothing under `live/*` reachable).
- `Colors\.|Color(0x|LinearGradient|glowLive|glowMarked|gradientBrand|gradientMarked` → only `ProximityColors.of` call sites (token reads, no raw colors, no gradients/glows anywhere in the tab).
- `Checkbox` → `session_edit_screen.dart` ONLY (per-round correction exception).
- `PopScope` → comment mentions only ("No PopScope", preservation notes for the NavSetup deletion); zero widgets.
- Triage (non-affordance residues, all pre-existing or display-only): `Host:` identity display line (no control, no `live/*` route); `totalTaken` variable name; `live drafts excluded` sync-engine domain term; `take-attendance`/`Live partial` pre-existing comments in the untouched edit screen; `Live tab` words in compliance comments.

### Verification (exact results)
- `flutter analyze` → ZERO issues in `lib/features/records/*`, `test/records_rebuild_test.dart`, `test/course_test.dart` (remaining 9 issues all in sibling-owned `mark/`/`manual_attendance/`/`student_home`/unrelated tests).
- `packages/storage` `dart test` → 11/11 pass (matrix/CSV builders untouched).
- Matrix golden bytes proven via scratch storage test (removed after): `buildDateRangeMatrix` → `Name,ID Number,Email,2026-09-04,2026-09-05\nA,1,a@x.in,P,A\nB,2,b@x.in,P,A\n` — PASS (same bytes pinned in `records_rebuild_test.dart`).
- Widget tests (`records_rebuild_test`, `course_test`, full suite) BLOCKED at load by sibling in-progress compile errors OUTSIDE Courses ownership (not touched): `lib/features/manual_attendance/manual_add_form.dart:63` (`WidgetRef` vs `Ref`), `lib/features/mark/browse_classes.dart:75` + `lib/screens/student_home.dart:1229` (`ipFieldKey`), plus `test/browse_banner_test.dart` / `test/identity_surface_test.dart`. Courses requests re-run once Live/Mark trees compile; the new tests are written to the final UI.

### Gaps
- Gap 4 (Take/Retake on overview vs §3.1a): RESOLVED — removed, hosting exclusively via Live `_LiveRoot`.
- Stale-threshold note: no staleness threshold exists in code (offline → `Offline — showing last synced records.` unconditionally); kept current offline/online copy verbatim, restyled only.
- Residual (routes-owned, pre-existing, untouched): `CourseAttendanceRouteLoader` does not filter device-hidden sessions (deep-link path can show a hidden session; `MyAttendanceScreen` filters correctly).
- NAV-G4 badge dot: untouched (no arrival signal exists).

### Deviations (mechanical, called out — never bundled silently)
- COURSES-D1: overview row subtitle `\n`-joined roomy line → single-line `·`-joined (StudentCard subtitle is one line) + `Partial (n)` marker moved into a `VerdictBadge` pill with the marker verbatim. Layout only; marker/ Counts/X-Y words unchanged.
- COURSES-D2: `MyAttendance._openCourse` re-adopts always-refresh-on-return (back yields null after the PopScope removal; `changed==true` gate dropped). The hide-reload path is pinned by the new test.
- COURSES-D3: register/rename stay `AlertDialog`s (not sheets) — primary management actions with test-pinned `Course name` field keys, not fallbacks.
- COURSES-D4: removed dead `_isPartial` helper in session detail (header uses `_partialCountOf`); no behavior change.
- COURSES-D5: student session tiles pass `sessionStatusOf` words (`Present`/`Partial p/t`/`Absent`) as `VerdictBadge` labels — the documented compound-display override; no verdict renamed.

### Verification (Account section, filled 2026-09-10 ~08:10 UTC)
- `flutter analyze lib/features/account lib/screens/shells.dart lib/main.dart test/account_screen_test.dart` — No issues found.
- `flutter test test/account_screen_test.dart` — 13/13 pass (sections render; ID read-only pin; cooldown verbatim + no move entry; allowedMove fallback; face-id push + `Image` findsNothing never-preview; stale → Needs re-face; records-only blocked card + records note; signed-out → Welcome; sign-out clears auth+linked; theme persists `dark` to prefs; prof page has zero face content; shell Account tabs host the consolidated pages).
- Full `flutter test` (all files except Mark-owned `test/identity_surface_test.dart`, which does not compile — sibling syntax-incomplete mid-rebuild): +310 / −43. All 43 failures are in sibling-owned Mark / Records-Courses / Live / Manual-attendance tests failing against their owners' in-progress lib changes (browse/mark/join/IP/course/manual-form/live suites); zero failures in Account, Setup-gate, shared-components, or any suite touching the files this section owns. Re-run the full suite once the Mark/Live sections land to confirm green.
- Full-repo `flutter analyze` at delivery: only pre-existing info (`welcome_screen.dart:53`, noted in the Nav log) + sibling-owned items (Mark `ipFieldKey` test refs, Live manual-attendance, in-progress `identity_surface_test.dart`). Nothing in `features/account/*`, `shells.dart`, or `main.dart`.

## 2026-09-10 — Mark-flow section (presentation + navigation-structure rebuild, features/mark/* + screens/student_home.dart)

### Status vs prior turns
- Prior turns completed: full verbatim reads (redesign §6.1–§6.4, SCREEN_MAP mark/entry/removed notes, inventory §0/§3/gaps-1/3, tokens + all shared widgets, all mark views, student_home, Appendix-A-adjacent tests). No code had landed.
- This turn landed the complete rebuild + test migration + verification below. The Courses-log-cited compile errors (`browse_classes.dart:75`, `student_home.dart:1229` `ipFieldKey`, `browse_banner_test`/`identity_surface_test`) were this section's own mid-rebuild state and are now resolved — all Mark-owned files compile and all Mark-owned tests pass.

### Files rewritten (mine, `apps/proximity_app/lib/features/mark/`)
- `browse_classes.dart` — discovered classes as lightweight `StudentCard` variant (class name, prof display name + gated Gmail + host + `Code` + org subtitle construction verbatim, tap → waiting, `Open` waiting-tone badge when window-open / `idle` caption otherwise); 3-bar recency glyph (`signalBarsFor`: open→3, heard within `kDiscoveryExpiry`→2, else 1 — never raw dBm) + chevron in a trailing cluster; typed-IP as `FallbackButton("Enter IP manually")` → one-field sheet whose content is the UNTOUCHED `JoinByIpSection` (same `IpJoinField`, same keys `ipfield`/`ipport`, same `Join`, same last-host prefill, same verbatim errors — errors surface as a thin banner on the list since the sheet pops on Join); empty state = radar illustration + `glow.live` + 2400ms timer-driven sweep (settle-safe, static under reduce-motion) + spec headline `Looking for a class…` with the previous guidance kept verbatim as subline; broadcast-blocked + join-error thin dismissible banners (verbatim copy); ladder `LadderLine` inside `DetailsExpander("Details")`; enroll/records/identity/foreground rows verbatim; 20dp margins + 560 max-width centering; no `Join`/IP field inline.
- `waiting_room.dart` — centered `_PresenceRing` (96dp, `glow.live` halo always, timer-driven pulse only while connected, static under reduce-motion) + `Connected`/`Not connected` as the only two states via `VerdictBadge(waiting)` + all verbatim lines (waiting line, host line, honest-unreachable, trail); per-round trail as `RoundTrailPills` (pill chips carrying the host's FULL verbatim `R<n> · <detail>` strings + ✓, so the `R1 · KQ7` contract still matches); manual + Cancel as bottom low-emphasis `TextButton`s (direct callbacks, no sheet — sheet-confirm is verdicts-only per §6.4). `RoundTrailPills` is shared with the verdict view (same-section import).
- `face_check.dart` — `FaceOval` SWAPPED for the shared two-oval `CaptureOverlay` (small = live head-target slot 0, large = overall progress, `totalAngles: 5` = the verified controller count per gap-3, `progress: 0` honest for single-shot, `signalForNotice` maps auto-retry/could-not-read lines → `inconclusive` else `neutral`, mismatch never renders here — it routes to needs-review); host notice is the overlay's ONE short line (screen-level duplicate removed); prompt + `BLE listening` + `Scan face` fallback kept verbatim; 300ms `ringMorph` scale+fade entrance (one-shot, never gates the host-owned zero-tap auto-scan); no timers in this view.
- `proving_view.dart` — `Signed → Sent → Confirmed` step tracker (`proveStepForStatus` maps the three verbatim driver status strings to steps 0/1/2 — same signals, componentized; icon+text carry state); `Proving…` + status lines verbatim; clock-drift copy as a thin warning banner (never a dialog); no countdown.
- `verdict_view.dart` — all five outcomes in the `VerdictBadge` shell: Marked keeps `✓ Marked` as a compound-display label (frozen string preserved) + single-use `_MarkedWash` (`gradient.marked` + `glow.marked`, `verdictWash` 400ms, timer-cleared, tap-skips, reduced-motion collapses to a flat `status.marked` fill — pure decor, never gates actions); Late flat + detail + trail + stay-put; Wrong-org badge + `WrongOrgCard` + verbatim next-step line + `Back to classes`; Needs-review badge + verbatim lines + attempts logic; No-signal badge + `Try again`; per-round `RoundTrailPills` on Marked/Late; `FallbackButton("Request manual attendance")` → confirm sheet (label-reuse, no new copy) on all four non-Marked verdicts, never on Marked.
- `manual_status.dart` — restyled only (560 centering): `Pending` badge while polling, all four branch strings + `Waiting…` + `Back` verbatim, poll logic untouched.
- UNTOUCHED (byte-identical): `join_by_ip.dart` (mechanical preservation — reused verbatim as the sheet content), `mark_phase.dart`, `mark_flow.dart` (existing medium cross-fade continuation kept; the waiting→face morph moment is the face entrance).

### Host edits (`screens/student_home.dart` — composition/status-mapping/drawer wiring ONLY)
- MARK-H1: `_openLog` now calls `showLogDrawer(context)` (overlay drawer — proving/face keep listening; no route push); terminal action + tooltip unchanged; `debug_log_screen` import → `log_drawer` import. Covers browse/waiting/face/proving/verdict via the single scaffold action.
- MARK-H2: late/wrongOrg/noSignal `onManualInstead: () {}` → `_requestManual` (existing driver path wired to the spec-mandated verdict fallback buttons; needsReview already had it; Marked keeps the noop — no button rendered there).
- MARK-H3: browse call drops `ipFieldKey`; `_fieldNonce` field + bump removed (sheets build fresh with `ipInitial` = last-host prefill); `_typedHostPort`/`_fieldInitial`/join gating/parse-target unchanged.
- All timers/drivers/drafts/nav/probes/`PopScope`-removal comments/log tags/strings/thresholds byte-identical (`core/` diff: zero). `screens/shells.dart`, routes, setup/, live/, records/, widgets/, design/, `student_driver.dart`, FaceGate untouched.

### Gaps/deviations (called out, never bundled silently)
- MARK-D1 (new copy, spec-mandated): empty-state headline `Looking for a class…` (§6.1) — old guidance kept as subline; no frozen string altered.
- MARK-D2 (wiring, spec-mandated): MARK-H2 enables manual-request from late/noSignal/wrongOrg verdicts via the existing `_requestManual` path (previously reachable only from waiting/needsReview).
- MARK-D3 (chips carry full strings): trail pills render the full verbatim `R<n> · <detail>` entries (not split labels) so the `R1 · KQ7` contract matches unchanged.
- MARK-D4 (late next step): Late reuses the verbatim stay-put line (it also parks for rewait); no new next-step copy invented.
- MARK-D5 (primary-CTA gradient not applied): buttons stay Material (theme-driven, no hardcode) — no shared button component exists and inventing one is out of scope.
- MARK-D6 (BT-off): no mark-side change — the host/core `Bluetooth is off` dialog + verbatim joinError line already keep BT-off at fallback weight; test still green.
- MARK-D7 (drive-by, test-only): three Live-owned pumps in `identity_surface_test.dart` (`WaitingListSection`, `MarkedRosterSection`, `ManualInboxSection`) wrapped in the themed helper — the Live section's token migration made them throw under bare `MaterialApp`. No live lib code touched.
- Gap 1/3: unchanged by Mark (gate owned by shell; 5-angle count consumed as `totalAngles: 5`; enroll `FaceOval` + its parity pin untouched).

### Tests migrated (copy/timing contracts intact)
- `widget_test.dart`: `enterIp` opens the fallback sheet (scroll-into-view + tap) before typing; last-IP + iOS tests ditto; `Try again`/`Back to join` now expect `Enter IP manually` on browse (the `Join` button lives in the sheet).
- `track5_states_test.dart`: themed pumps (rebuilt views read `ProximityColors`); constructor signatures unchanged.
- `browse_banner_test.dart`: themed pumps; ladder `Path:` asserted after expanding `Details` (collapsed `AnimatedCrossFade` child stays in tree — the pre-expand `findsNothing` assert was wrong and removed).
- `identity_surface_test.dart`: themed pumps; `ipFieldKey` removed; paren repair after a bulk-edit mishap (one over-matched closer restored).

### Verification (exact results)
- `flutter analyze` — clean except 2 pre-existing sibling-owned items: info `welcome_screen.dart:53` (untouched) + warning `live_manual_attendance_test.dart:22` unused import (Live-owned). Zero in Mark-owned files.
- Mark-scoped: `widget_test` 25/29 (all 4 failures are prof/session-edit tests in sibling-owned `take_attendance`/`session_edit` flows — settle-timeout, never mount mark code, none of my files in their stacks; recorded below); `track5` + `browse_banner` + `identity_surface` + `shared_components` + `setup_shell_gate` + `enroll_guided` + `proximity_colors` 89/89 pass.
- Full `flutter test` — +351/−15; ALL 15 failures are Courses/Records/prof-Live suites (`course_test` ×6, `records_rebuild` ×2, `course_attendance` ×1, prof/session-edit `widget_test` ×4 +2) failing against their owners' in-flight lib changes; zero failures in any suite touching Mark-owned files. Re-run once Live/Records/Courses land.
- Frozen-string grep (`features/mark` + `student_home` + `verdict_badge`): `✓ Marked`, all three proving statuses, `No signal`, `Needs review`, `Wrong org`, `Stay put`, `Request manual attendance`, `Enter IP manually`, `Scan face`, `Connected`/`Not connected`, `Try again`, `Back to classes`, `R1 · KQ7` all present; `verdictWash`/`ringMorph` wired from `ProxDurations`; `core/` untouched so all driver timings hold.

## 2026-09-10 — Live-tab rebuild (Live section; M3 manual-attendance module)

### Status vs prior turns
- Prior turns completed: full verbatim reads (redesign §§2.5/3.1a/4.1/4.7/4.8/7.1–7.2, SCREEN_MAP professor-shell + removed/merged, inventory §4 + Appendix A + Phase 1 M3 + gaps 4/5, tokens + all shared widgets, take_attendance + all live/* + shells `_LiveRoot`). No Live code had landed (working-tree take_attendance diff was NavSetup's PopScope→explicit-leave + format only).
- This turn landed the complete rebuild + test migration + verification below. The sibling-reported compile error (`manual_add_form.dart` WidgetRef-vs-Ref) was this section's own mid-rebuild state and is resolved — `flutter analyze` is clean for all Live-owned files.

### M3 move, file-by-file (mechanical, §4.8)
Source was `apps/proximity_app/lib/widgets/manual_add.dart` (513 lines: `ManualAddForm` + inline search/queue orchestration + queue re-export):
- Search/queue orchestration (`_debounce` 400ms timer, 15s/6s online-probe cache, `searchStudents` queries incl. name-≥2-char rule, stale-generation drop, 10s failure-log throttle, `matchRollExact` exact-ID resolve, `writePendingAdds` offline-queue writes, all four submit paths, `_userMessage`) → `features/manual_attendance/manual_directory.dart` (`ManualDirectoryController`, same windows/queries/writes/copy; `manualAddUserMessage` = old `_userMessage` verbatim).
- `ManualAddForm` UI (same ctor `fieldPrefix/course/sessionId/onAdd/isPresent`, same `<prefix>-roll|-name|-email` keys, same copy; token colors + `StudentCard` hits) → `features/manual_attendance/manual_add_form.dart`.
- Inbox approve/reject UI (own `SelectionScope` instance per list; hold-and-tap + `SelectionToolbar Approve N · Reject N · Select all · Cancel`; single→`onApproveOne`/`onRejectOne`, bulk→`onDecide`) → `features/manual_attendance/manual_inbox.dart` (`ManualInboxView`).
- Barrel → `features/manual_attendance/manual_attendance.dart` (also re-exports the queue API so the old `widgets/manual_add.dart` queue re-export keeps resolving).
- `widgets/manual_add.dart` → re-export shim over the barrel (NOT deleted — Phase 6 owns deletions; converted via edits). Proven identical: `identical(shim.ManualAddForm, ma.ManualAddForm)` test.
- Submit-path parity proven: `manual_add_test.dart` (shim path, 8 tests incl. debounce/name-gating/offline-queue/exact-ID/already-present/failure-surface) passes UNCHANGED in behavior; `live_manual_attendance_test.dart` re-proves ID-required/offline-queue/exact-ID through the module path.

### Files rewritten (mine)
- `features/live/live_session.dart` — same props/labels/counts (incl. `Window 1 ·`/`Windows 1–N … intersection` denominator rule, `mm:ss`, Start/Stop/`Retake round N`/`Take another round`/`End attendance` incl. disabled-when-!hosting); `gradient.brand` while LIVE, flat `surface.raised` while IDLE (§2.5); tokens only; overflow-safe (Expanded/ellipsis).
- `features/live/live_setup.dart` — same API (`showAnnounceIpDialog` signature, `Announce on`/`Cancel`, `Starting host…`, name label verbatim, server line monospace verbatim, `Announcing on <ip> · change`, error line); idle guidance collapses the discovery/ladder paragraph into `DetailsExpander("Details")` + `formatLadderLine(-1)`; `LadderLine` widget import dropped (formatter used directly).
- `features/live/live_roster.dart` — same filters/copies/keys (`prof-search`, `Waiting area (n)`, present/partial headers + empty lines, intersection gate + search narrowing, partials suppressed during search); rows are `StudentCard` (waiting = `Waiting` badge, present = Late badge when late + `RoundTick` pills, partial = pills); `DupFlagSection` + `distinctGroups` + `rosterTicksFor` kept byte-identical.
- `features/live/manual_inbox.dart` — same ctor; now composes module `ManualInboxView` (checkbox list gone).
- `features/live/direct_add.dart` — same ctor/copy (`Direct manual entry`, `direct-` prefix); imports the module form.
- `features/live/live_sections.dart` — same classes/ctors/reasons/cold deep-link guidance/`_decide` bodies (incl. section-local no-snapshot shape); roster/inbox/add shells gain terminal→`showLogDrawer`; setup keeps `System log` push + back. `draft_recovery.dart` UNTOUCHED (policy/prompts/banner byte-identical).
- `screens/take_attendance.dart` — composition ONLY: fixed control-cluster header + `_LiveSubNav` (Roster/Inbox(n)/Add/Setup, scroll-to-section, all sections stay mounted) + `Expanded` section scroll; terminal→`showLogDrawer` (drawer `Expand` pushes debug/log — replaces `_openLog` push); person-add icon→`showProxSheet` add form (`sheet-` keys, same onAdd/isPresent). All orchestration preserved byte-identical (host/start/stop/end/`_leave`/dispose top-up+`endHosting`/drafts/snapshots/wakelock/polls/`_logWaitingDelta`/all log tags). Consolidation: `ClockHeader` + pre-window WiFi-note/`LadderLine` removed from the scroll (elapsed lives in the fixed header; discovery prose lives in the setup expander) — LIVE-D4.
- `screens/shells.dart` — UNTOUCHED (no edit needed: register-free list→host flow already works; verified by green Live-root widget tests). Nothing under `live/*` reachable from Courses (grep: no records/setup/mark importer; Courses overview carries no take entry — gap 4 already closed tree-wide) — LIVE-D5.
- `core/` (host_driver et al), routes, setup/, mark/, records/, design/, widgets/ (except the shim): untouched.

### Dispose-residual verdict (NavSetup flag)
- LEFT OPEN, deliberately: popping the host still tears down via `dispose` (best-effort top-up + port close + `endHosting` preserved byte-identical). Moving the host lifecycle off the route (hint-only teardown) would change teardown timing/visit semantics — a behavior change, forbidden. Only addition is the sync `_scrollCtrl.dispose()`. Flag stays open for a future behavior-approved pass.

### Gaps/deviations (called out, never bundled silently)
- LIVE-D1 (trigger mapping, UI-side): toolbar Approve/Reject with exactly 1 selected routes to `onApproveOne`/`onRejectOne` (single path incl. its log + per-row clear), N>1 routes to `onDecide` (bulk path). Host sequences (`decideManual` + draft + snapshot + logs) unchanged; only which host entry the UI calls depends on selection size.
- LIVE-D2 (motion/settle, spec-aligned): present rows render the STATIC `Late` badge when late and NO badge when marked (pills + header carry presence). The marked elastic pop must not mount under the take screen's 1s-ticking parent — bisected: shell/pills/static-badges all settle, marked-pop times out `pumpAndSettle` (round-1 LIVE settles, round-2 does not). One-shot on mount is fine on device (no refire path: pop arms once, `didUpdateWidget` early-returns on same status), but replaying transition motion on a screen that rebuilds every second violates "updates in place" (§7.1). Shared-section note: `VerdictBadge(marked)` under a ticking parent never settles — may warrant a shared look; no shared code touched.
- LIVE-D3 (test-only harness): bare-`MaterialApp` pumps need `theme: proxLightTheme()` wherever rebuilt token widgets mount (`manual_add_test` ×6, `live_sections_test` ×2, new `live_manual_attendance_test` ×6, `widget_test` session-edit ×2, `course_test` `wrap`, plus Records-owned `records_rebuild_test`/`course_attendance_test` harnesses — same one-line pattern to unblock the shared suite). Precedent: `shared_components_test` `_app` helper.
- LIVE-D4 (consolidation, take screen): dropped `ClockHeader` + pre-window WiFi note/`LadderLine` from the scroll (elapsed in fixed header; discovery prose in setup `DetailsExpander`). No frozen string relied on by tests was removed (server line, name label, all verdict/window strings intact).
- LIVE-D5 (verify-only): no `shells.dart` edit; Courses reachability grep clean.
- Gap 4/5: unchanged by Live (overview take-entry already absent tree-wide; per-round-checkbox exception untouched — session editor keeps its boxes, owned by Courses).

### Tests migrated (copy/timing contracts intact)
- `widget_test.dart` approve flow: `Select all`→`Approve selected` becomes long-press `M One` → `Approve 1` → `Select all` → `Approve 2` → `Manual requests (0)`; direct-entry half unchanged.
- New `test/live_manual_attendance_test.dart` (7 tests): shim identity, single-approve routing, bulk-reject routing, Cancel exit, ID-required, offline queue, online exact-ID resolve.
- Recover/draft semantics: untouched code + green `recover_policy_test` + green take draft widget tests (`back preserves draft`, `end clears draft`).

### Verification (exact results)
- `flutter analyze` — clean except 1 pre-existing Setup-owned info (`welcome_screen.dart:53` curly-braces, untouched). Zero in Live-owned files/tests.
- Live-scoped: `live_manual_attendance` 7/7, `manual_add` 8/8, `live_sections` 2/2, `recover_policy` 1/1, `dup_flag` 3/3, `identity_surface` (Live pumps) green, `widget_test` 29/29, `course_test` 9/9, `host_driver` + `shared_components` + `offline_live` green.
- Full `flutter test` — +365/−1; the single failure is Records-owned `course_attendance_test.dart` `StudentCourseScreen shows totals + sessions` (their rebuilt tile renders `Partial 1/2` twice vs `findsOneWidget` — no Live file in that tree; left for Records).
- Greps: no `Checkbox`/`CheckboxListTile` widgets in `features/live` + `features/manual_attendance` (one comment mentions the removed pattern); no `Colors.`/`Color(0x` literals in Live-owned files (token reads only); `live/*` importers outside router: none.

## 2026-09-10 — Integration fixes (enroll overlay swap, Partial-duplicate, face-id route; full green)

### FIX 1 — enroll overlay swap (`features/setup/enroll_capture.dart`)
- Replaced `FaceOval` placeholder + `FaceCaptureOvalOverlay` + `EnrollAngleDots` positioned overlay with the shared two-oval `CaptureOverlay` (small oval = live head target at `_nextAngle` = first unfilled bucket, large oval = `_doneCount/total` progress, `totalAngles: faceEnrollSlots.length` = controller-derived 5, never hardcoded; `sweepAngle: reduced ? null : _sweep`, null-static under reduce-motion per the overlay contract).
- `EnrollAngleDots` usage removed under the §6.2 two-ovals-only rule (separate progress/dots violate it); the widget class stays in `features/setup/enroll_widgets.dart` (shared with intro/result, Phase 6 owns deletion) with its standalone widget test intact.
- Exactly two ovals + one short line: the bottom-bar `enrollCapturePrompt` remains the single prompt; overlay `statusLine` stays null mid-flow (rejects are BleLog-silent by driver contract); the save-error `EnrollNotice` toast + `Try again`/`Continue` bottom bar are unchanged (fail-closed terminal states, not progress chrome).
- Driver byte-identical: `_initialBeat/_frameBeat/_sweepTick/_sweepRevolution`, `_openCamera/_startLoop/_autoLoop/_captureOne/_saveAll/_cancel`, dispose latch, STEP-SCOPE branches, bottom-slot boundary parity (hidden reservations, `_SlotTopUp`) untouched — only imports (drop `screens/face_capture` + `widgets/animated`, add `widgets/capture_overlay`), the preview-Stack overlay block, and overlay-describing comments changed.
- Parity-test updates (called-out `FaceOval(` pin change): `test/enroll_guided_test.dart` deltas test now pins `CaptureOverlay(` + `faceEnrollSlots.length` present, `FaceOval(`/`FaceCaptureOvalOverlay(`/`EnrollAngleDots(` usages absent, `Positioned(` count 2→1, `sweepSpan` absent; overlay widget tests now target `CaptureOverlay`; three progress-semantics pumps replaced with bounded fixed pumps (progress rides the paint-only arc now); both enroll harnesses gain `theme: proxLightTheme()` (shared overlay reads `ProximityColors` — same LIVE-D3 pattern).
- `test/enroll_beacon_boundary_test.dart` (second parity pin on this screen): preview-stack finder + chain tests retargeted to `CaptureOverlay`; `mid-flow` test asserts overlay-present/dots-absent; layering test asserts zero `Positioned` chrome mid-flow (save-error toast still `Positioned` + saveError-gated, pinned); beacon-painter unit tests untouched (legacy widget still exists, Screens-owned).
- `test/widget_test.dart` enrollment journey: `EnrollAngleDots findsWidgets` → `CaptureOverlay findsOneWidget` (+ import swap `enroll_widgets` → `capture_overlay`; `face_capture` import retained for `FakeStillCapturer`).
- Gap 3 note: overlay consumes the verified 5 (`faceEnrollSlots` centre/left/right/up/down); agnostic to any N via `faceEnrollSlots.length`.

### FIX 2 — `Partial 1/2` duplicate (source bug, minimal Records diff — called out)
- Verdict: SOURCE bug, not test bug. The rebuilt `CourseAttendanceDetailScreen` tile rendered the frozen `Partial 1/2` string twice (subtitle prefix + `VerdictBadge` label override), so `textContaining` found 2 vs `findsOneWidget`. Pre-rebuild `StudentSessionTile` rendered status once (subtitle text + icon, no second text).
- Fix (3-line diff in `features/records/course_attendance_detail_screen.dart`, Records-owned): `_tileSubtitle` drops the status prefix (badge already carries the exact `sessionStatusOf` word) → subtitle is now `rounds · label · org`. Every verbatim token still present exactly once; no test file changed for this fix (the `proxLightTheme` harness in that test is Live's earlier LIVE-D3 drive-by, retained).

### FIX 3 — `account/face-id` deep-link (ACC-D2, routes-table line)
- `lib/routes.dart` only: import `features/account/face_id_screen.dart` + `ProxRoutes.faceId = 'account/face-id'` const + `ProxRoutes.faceId: (_) => const FaceIdScreen()` table entry + IA header comment line. Mirrors the existing static-route pattern; no guard changes (screen self-gates records-only via `FaceBlockedCard`). In-tab push (`RouteSettings(name: 'account/face-id')` in `account_screen.dart`) untouched.
- Proven by ephemeral test (removed after): table contains `account/face-id` → builds `FaceIdScreen`. In-tab path already covered by `account_screen_test.dart` (green).

### Verification (exact results)
- `flutter analyze` — 1 pre-existing info only (`features/setup/welcome_screen.dart:53` curly-braces, untouched, Nav-logged). Zero in owned files.
- Full `flutter test` — 366/366 pass, 0 failures (was 365/1; the single Records failure from the Live log is fixed).
- `flutter build web --no-pub` — ✓ Built build/web (web-guard green).
- Frozen grep on `features/setup/enroll_capture.dart`: no `FaceOval(`/`FaceCaptureOvalOverlay(`/`EnrollAngleDots(`, no `Hold still`/`Checking angle`/`enrollAngleInstructions`; driver timing consts + verdict/threshold strings untouched.

### Residuals / OPEN
- `FaceOval` (`widgets/animated.dart`, Shared-owned) and `EnrollAngleDots` (`features/setup/enroll_widgets.dart`) are now unused by any screen but left defined (out of ownership; Phase 6 deletion). Their standalone widget tests still pass.
- Live's dispose-residual (host teardown on pop) stays OPEN per the Live section (behavior change, not attempted).
- A11y agent owns cross-cutting files concurrently — no conflicts encountered (owned files disjoint by brief).

## 2026-09-10 — Responsive/accessibility pass (§9 + §10 + §10.1, final cross-cutting)

### Scope kept
- Did NOT edit `features/setup/enroll_capture.dart`, `routes.dart`, or any existing test file. No string, timing, threshold, network, or component-API changes (one ADDITIVE optional-behavior note below: none — `SelectionCoachMark` is a new widget, `ProxLayout` a new class, `_MarkedWash` builder is file-private; all existing call sites untouched).
- New tests only: `apps/proximity_app/test/responsive_a11y_test.dart` (16 tests).

### Fixes implemented (minimal diffs, each with the §9/§10.1 rule in a code comment)
- `ProxLayout` (NEW in `lib/design/tokens.dart`): `narrowBreakpoint` 360, `wideBreakpoint` 600, `isNarrow/isWide`, `cardPadding` (16→12 below 360dp). The class the brief names did not exist — created, nothing else in tokens touched.
- `StudentCard`: padding now `ProxLayout.cardPadding` (16→12 <360dp); name/subtitle already Expanded+ellipsis; hold-and-tap whole-card ≥48dp opaque region verified by test.
- `app_theme.dart`: theme-level 48dp floor — `minimumSize Size(64,48)` on filled/outlined/text button themes + `iconButtonTheme` 48×48. Carries §9 tree-wide incl. dialog/sheet actions (MARK-D5 keeps buttons Material theme-driven — this IS that theme).
- LIVE header (`live_session.dart`): full-opacity `gradient.brand` wash measured 2.85:1 dark / 3.49:1 light under `contentPrimary` body text (both below AA) and ~1.4–1.6:1 for outlined labels — replaced with the TOKEN gradient (same begin/end/stops) at 20% alpha over `surfaceRaised`. The gradient=running signal stays (tint + LIVE word + pulsing dot).
- Marked wash (`verdict_view.dart`): status-green badge text on the green wash measured ~1.1:1 — wash content (badge, trail pills, stay-put line) now renders via a wash-local dark-ink `#14161A` `ProximityColors` override (file-private `_MarkedWash` switched child→builder; override applies only while the wash is up, normal colors return after the 400ms lift — both states pinned by test).
- `SelectionCoachMark` (NEW in `selection_controller.dart`, IMPLEMENTED per §9): one-time dismissible "Hold to select" hint, persisted `prox.coachMark.<listType>.v1` via SharedPreferences, colocated with the selection controller. List-type vocabulary: `inbox` (ManualInboxView) + `sessions` (course-overview multi-delete); roster/waiting rows are not selectable → no entry. Hides while selecting; fail-silent (unreadable prefs → hidden, never nagging). Wired into `ManualInboxView` + `_OverviewBody` (web multi-delete has no selection → mark omitted there). New copy: hint words are the spec-verbatim "Hold to select"; dismiss action "Got it".
- Browse radar: `sweepAngle` nullable — static rings+halo under reduce-motion (was: static sweep arc head).
- `_ProveSteps`: Row is now width-bounded (max, centered) with loose-Flexible steps — labels ellipsize inside their third instead of striping (the new test caught a REAL 38px overflow at 350dp/130% before this fix). Full words preserved in the Semantics label.
- `live_setup.dart` announce-IP TextButton label + `ProxSectionHeader` title: ellipsis/maxLines added (trailing/header safety).
- Account theme `SegmentedButton`: label-only segments below 360dp (icon+label triple overflows narrow at large type).
- Shell bar (`shells.dart`): wrapped in `SafeArea(top:false)` — verified in SDK `_ScaffoldLayout` that `bottomNavigationBar` is laid flush at screen height with NO system-inset padding of its own; the bar background still fills the inset behind the bar.
- REVERTED (deviation from my own plan, called out): take-attendance 560-center wrap. Probe evidence: constraining the host list to 560 on the 800px test surface wraps setup prose taller and pushes `Manual requests (2)` below the ListView first-build cache range → `widget_test.dart: prof manual approve` failed (0 sections built, no exception). The host is a control console (fixed cluster + sections), not a ProxScreen list screen; the ≥600 rule stays verified via ProxScreen-560 (account/live-sections/debug/setup), records Center+ConstrainedBox-560 (mine/overview/export/prof-courses/detail), self-constraining student-home phases, and 460 shells/device/role-hub. File restored byte-equivalent (diff shows only Live-section work).

### §10.1 overflow checklist — per-item evidence
- Row/Column + variable text → Expanded/Flexible + ellipsis: grepped every `Row(` site tree-wide (records/setup/account/live/mark/widgets/screens); all variable-text rows already Expanded+ellipsis (student_card, roster rows, export rows, course rows, trust cards, enroll result/intro rows, web_banner, log drawer/terminal titles, toolbar count). Fixed 3: section header, announce-IP label, prove-step labels. `ListTile`-based rows (`ProxListTile`, ExpansionTile, CheckboxListTile) constrain internally and grow vertically — compliant by construction, no clip.
- Sheets keyboard-safe: `showProxSheet`/`showFallbackSheet`/`showLogDrawer` all `isScrollControlled` + `SingleChildScrollView` + `Padding(bottom: viewInsets)` + zero `minHeight` clamps — pinned by test (400px inset: inset-Padding present, TextField visible, no overflow). Single-field sheets (`IpJoinField`, `ManualAddForm`) are Columns, never nested scrollables.
- No fixed-height text clipping at 130%: every fixed height tree-wide is art/dots/rings/progress (welcome hero 148/72 art-only, dots 24, rings 48–96, radar 120, ladders) — zero text inside fixed-height clips; `StudentCard` is minHeight-only (test: 130% long-name settles, ellipsis on name). FaceOval fixed box is dead code (no lib usages; Phase 6 owns deletion).
- Long unbroken tokens: NO full-length token renders anywhere — all keys/IDs truncated to 12 chars + … (`_shortKey`, `trustPkDFingerprint`, `shortPk`; verified by grep for pkHex/installId displays). CSV preview already uses `SelectableText`; debug-log rows stay plain Text (perf, pre-existing documented exception). So the SelectableText-full-token branch is N/A with evidence.
- Nested scrollables: none — Columns-in-scrolls, PageView(NeverScrollable)+Expanded pages (setup flow), DraggableScrollableSheet+Expanded list (log drawer), horizontal chip scroller (debug log). Verified by grep (shrinkWrap hits: zero in lib outside comments).
- Network imagery errorBuilder: single site — `AccountChip` Google photo (has `errorBuilder` → initial). Shells tab icon is text-initials only, never a photo. Verified by grep (`Image.network|NetworkImage|photoUrl`: one lib hit).
- Orientation: zero `OrientationBuilder`/orientation branches tree-wide (grep). Mark/face letterboxes via AspectRatio (never crops overlay); real camera preview lives in sibling-owned enroll_capture (untouched).

### §9 — per-item evidence
- Status icon+color+text: `VerdictBadge`, `ProxStateBadge`, `DeviceTrustBadge`, `WrongOrgCard`, prove dots+labels, waiting ring+Connected badge — all icon+word; test pumps every `ProxStatus` and asserts Icon + verbatim word. Signal bars are glyph+adjacent Open/idle word + Semantics label (declared exception, meaning never color-only). LIVE-D2 static Late badge + MARK-D5 Material buttons: contrast/targets only, not relitigated.
- Targets ≥48×48: theme floor (above) + test-measured TextButton/FilledButton/OutlinedButton/IconButton all ≥48; StudentCard hold region = whole ≥48 card, long-press enters selection without tap (test). FilterChips/segmented controls get 48 via theme + explicit styles; log-drawer icon buttons pin 48 constraints; DetailsExpander row minHeight 48.
- Coach-mark: IMPLEMENTED (above), 3 tests (show→dismiss→persist; per-list-type independence; hidden-while-selecting).
- Dynamic type 130%: StudentCard / ProvingView+narrow / marked-verdict-with-trail all settle exception-free at 130% (tests); degradation is truncate/wrap, never clip.
- Reduce-motion: verified static paths — VerdictBadge (returns plain content), CaptureOverlay (sweep null), welcome hero (static 0.35), radar (null sweep — fixed), waiting ring (no pulse when not connected; AnimatedScale duration 0), toolbar (returns bar, test asserts no AnimatedSlide/Opacity), setup-flow PageView (jump, no slide), stagger/fade-slide/switcher (instant), debug-log screen (no entrance by construction), ProxVerdictBadge legacy (plain content).
- Contrast, per gradient/glow surface against DARKEST stop (measured WCAG, also pinned in `responsive_a11y_test.dart`):
  - AccountChip brand wash (0.14 over surfaceBase): primary copy 15.08 dark / 14.56 light — PASS body.
  - LIVE header 20%-alpha token wash over surfaceRaised (FIXED): dark ink 11.99, dark outlined-label 6.68, dark ring 4.21 (≥3 non-text); light ink 13.76, light outlined-label 5.42, light ring 3.95 — PASS. (Was: 2.85 / 3.49 / ~1.5 FAIL.)
  - Marked wash, dark-ink content (FIXED): 8.27 dark (`#33C77A`), 5.03 light (`#1E9A5C`) — PASS body. Reduced-motion flat 15% fill even higher.
  - Sheets: content on opaque surfaceRaised (dark 15.5 / light 15.2 PASS); scrim dims backdrop only, text never sits on it.
  - Glows (`glow.live/marked`, ring shadows, hero shadow): pure BoxShadow, no text — N/A by construction.
  - Primary-CTA gradient fill: NOT implemented (MARK-D5 — buttons stay Material); no gradient surface → N/A, contrast is the theme's.
  - Capture statusLine on live video: supplementary line over scrim-darkened preview; oval color is the primary signal — documented limitation, no change (overlay element count frozen).
  - Observation (NOT changed — token hexes are §2.1 spec-frozen, meaning carried by icon+word): LIGHT-theme flat badge tints below AA body text (Late 2.90, Review 3.46, Marked 3.60, Error 4.31 on near-white); dark theme all pass (≥4.56). Flagged for Foundation, not relitigated.

### Breakpoints
- <360dp: icon-only bar wired (`showSelectedLabels=false` + labels null + tooltips intact, all three shell bars); StudentCard 16→12 padding (test-pinned at 350px); trail Wrap wraps (test with 2 ticks at 130% narrow).
- ≥600dp: max-width-center verified at every true list screen (inventory above); take-host intentionally full-width (deviation with probe evidence).
- SafeArea bottom: shell bar (fixed), SelectionToolbar (already), log drawer (already `SafeArea(top:false)`); sub-pages ride above the shell bar inside tab navigators; no custom nav under system gestures (stock BottomNavigationBar only).

### Verification (exact results)
- `flutter analyze` on all 16 touched/new files — No issues found.
- New `test/responsive_a11y_test.dart` — 16/16 pass.
- Targeted existing suites — shared_components + app_theme + proximity_colors, track5/live_sections/live_manual/manual_add, records_rebuild/course/course_attendance/account, widget_test + browse_banner/dup_flag/identity_surface/device_identity — all pass.
- Full `flutter test` — 382/382 pass (366 prior + 16 new), 0 failures.
- Regression caught & resolved during pass: take-host 560 wrap broke `widget_test: prof manual approve` (cache-range, no exception) — reverted with probe evidence (sections 0→1 on revert), test green again, full suite confirms.

### Gaps / deviations (all called out)
1. Take-host 560 wrap REVERTED (evidence above) — the one spec-tension item; list-screen coverage documented instead.
2. Light flat badge tints below AA (observation only, spec-frozen hex).
3. Capture statusLine over live video (supplementary; overlay element count frozen).
4. `ProxListTile` still renders legacy theme text (migrates with its screens; layout-safe: grows, never clips).
5. Dead `FaceOval`/`EnrollAngleDots` classes remain (Phase 6).
6. New user-visible copy: "Hold to select" (spec-verbatim) + "Got it" (required dismiss action).

## 2026-09-10 — Phase 6 dead-code cleanup (deletions only, no restyles/behavior/moves)

### STEP 0 reads
- INTEGRATION_LOG tail (orphans FaceOval/EnrollAngleDots left for Phase 6; Live dispose-residual OPEN; MARK-D7/LIVE-D3 harness notes), FEATURE_INVENTORY Phase 1 (M1/M2/M3, records exemption) + Phase 2 (do-not-delete: screens hosts, core drivers, EnrollmentController, entry_flow, plugin/pose-gate, ManualAddForm logic until M3, records data, tokens) + Appendix A (frozen strings/timings), PROXIMITY_UI_REDESIGN §11 (refactor boundary, no behavior/string/timing/threshold/network changes), SCREEN_MAP Removed/merged (mark/join merged, MarkedBadge/BleLogView removed, account split superseded, courses rename, device folded, manual_attendance module, hosts keep orchestration).

### Deletions (each verified zero non-test refs before delete; no file moves, no widget-tree changes)
1. `FaceOval` + `_OvalPainter` in `apps/proximity_app/lib/widgets/animated.dart` — DELETED. Zero-ref evidence pre-delete: `rg FaceOval lib` → only definition + trailing comment + `face_check.dart:6` historical note; zero production constructions (mark/face uses CaptureOverlay, enroll/capture uses CaptureOverlay); test refs only string-absence checks (`enroll_guided_test.dart:310 session.contains('FaceOval(') isFalse`), no type constructions. Also removed now-unused `import 'dart:math' as math` (paint-only) + updated trailing comment to Phase 6 note (comment-only). `PresentTicker` KEPT — referenced by `features/live/live_session.dart:153`.
2. `EnrollAngleDots` in `apps/proximity_app/lib/features/setup/enroll_widgets.dart` — DELETED (rest of file kept: EnrollLog/enrollRetryBrief/enrollCapturePrompt/EnrollRollField/EnrollNav/EnrollNotice all live). Zero-ref evidence pre-delete: `rg EnrollAngleDots lib` → only class definition; zero production constructions (enroll_capture uses CaptureOverlay totalAngles faceEnrollSlots.length). Test updates (called-out exception: tests asserting removed dead symbol): `test/enroll_guided_test.dart` — deleted standalone `dots label tracks captured count` widget test (tested deleted class itself), deleted `find.byType(EnrollAngleDots) findsNothing` assert (line 411), updated `two-oval deltas` comment (was "class stays for Phase 6"); `test/enroll_beacon_boundary_test.dart` — deleted `find.byType(EnrollAngleDots) findsNothing` assert (line 173). Both files still import `enroll_widgets.dart` (enrollCapturePrompt/EnrollNotice live). String-absence checks (`session.contains('EnrollAngleDots(') isFalse`) retained — still pass vacuously.
3. Unused imports — NONE deleted (nothing flagged). `flutter analyze` pre-delete showed only pre-existing info `welcome_screen.dart:53` (Nav-logged, untouched); Live-owned `live_manual_attendance_test.dart:22` unused-import warning from Mark log no longer flags (already clean). Post-delete analyze confirms no new unused imports (dart:math removal was part of FaceOval delete).
4. Orphaned files — NONE deleted. `features/entry/` holds only `entry_flow.dart` (M2 exempt decisions-only, per Phase 1 — keep). `features/enrollment/` dir already gone (emptied by NavSetup git-mv, verified absent). `screens/face_capture.dart` KEPT — production ref exists: `screens/student_home.dart:41` imports it + `:942` reads `stillCapturerProvider` (defined in face_capture.dart:61-62); `StillCapturer/FaceCaptureScreen/FaceCaptureOvalOverlay` also drive still capture + parity/beacon tests. Never guessed — grep proves live.
5. Superseded widgets — ALL KEPT with reason (keep-by-default; delete requires zero prod + zero test refs, none met): `prox_*` (prox_scaffold/buttons/cards/states/motion all imported across mark/records/live/setup/routes/shells — grep lists dozens of production importers); `ProxVerdictBadge` (one production use `features/setup/enroll_result.dart:120` + tokens docs); `FaceBlockedCard` (production uses in routes/face_capture/enroll_intro/enroll_capture/enroll_result/account/face_id); `widgets/manual_add.dart` shim (production importers `features/records/session_edit_screen.dart:24` + `:320 ManualAddForm` construction; test importers `manual_add_test.dart` + `live_manual_attendance_test.dart` shim-identity proof — M3 shim stays).
6. Stale comments — comment-only edits (never surrounding code): `enroll_widgets.dart` prompt doc `rim sweep + dots` → `rim sweep` (dots usage gone); `animated.dart` trailing `FaceOval + PresentTicker are live contract` → Phase 6 removed-note + PresentTicker stays; `enroll_guided_test.dart` `class stays for Phase 6` → `class removed in Phase 6`. KEPT as accurate provenance (not stale): `capture_overlay.dart:13` no-corner-brackets design rule; `shells.dart:11` PopScope→setMode gone note (shells still has new step-back PopScopes :334/:423, not the deleted pattern); `manual_inbox.dart:5` old checkbox-list gone note; `course_overview_screen.dart:328` no-checkbox note + header records-only note (gap 4 closed); `face_check.dart:6` old-FaceOval-replaced note (history, out of the four-pattern scope).

### Verification (exact results)
- `flutter analyze` — 1 pre-existing info only (`features/setup/welcome_screen.dart:53` curly_braces, untouched, Nav-logged). Zero in owned files. No unused-import warnings.
- Full `flutter test` — 381/381 pass, 0 failures (baseline was 382/382; delta −1 is the deleted `EnrollAngleDots` standalone widget test `dots label tracks captured count` — the dead class's own test, removed with the class per the called-out test exception; all other suites green incl. enroll_guided, beacon_boundary, live_manual_attendance, manual_add, widget_test).
- `flutter build web --no-pub` — ✓ Built build/web (web-guard green).
- Frozen-list guard: no lib/core, lib/design, routes, shells, drivers, docs edits (except allowed test asserts + comment-only updates above); no file moves; no widget-tree changes (deletions are dead classes + their own test only).
