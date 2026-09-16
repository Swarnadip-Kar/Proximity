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
| Gap-fix close-out (orchestrator, in-tree) | Orchestrator | DONE 2026-09-10 — `flutter analyze`: 1 pre-existing info only (welcome_screen.dart:53); full `flutter test`: 417/417 pass; `flutter build web --no-pub`: Built build/web. Covers relink (entry_relink 3/3), back-intercept (take_back_intercept 2/2, exactly-once endHosting), tint contrast (16/16, light late 5.65/review 6.63 on tints), account photo (15/15). Task-1 agent's reported tokens conflict was a transient mid-write read — hashAll fix was already in place, no action needed |
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

## Task 3 tint contrast

Approach (D3 — darken foreground, backgrounds untouched): added two fixed-hex
`ProximityColors` fields `onTintLate` / `onTintReview`. Light values clear
4.5:1 on their tints and ≥3:1 as bare icons; dark values equal today's dark
status hexes so dark rendering is pixel-identical. Light late/review/pending
text + meaningful icons route through the new foregrounds via
`ProxIcons.statusForeground`; fills/borders keep the spec-frozen status hexes.
Pure-shape dots unchanged. No new states; no copy/timing/threshold/network
changes; spec hexes byte-identical.

Files:
- `apps/proximity_app/lib/design/tokens.dart` — new `onTintLate`/`onTintReview`
  fields wired through constructor, dark/light instances, `copyWith`, `lerp`,
  `==`, `hashCode` (hashCode moved to `Object.hashAll`, 21 fields > 20-arg
  `Object.hash` limit); new `ProxIcons.statusForeground` (`late → onTintLate`,
  `review/pending → onTintReview`, else `statusColor`).
- `apps/proximity_app/lib/widgets/verdict_badge.dart` — icon + word use
  `statusForeground`; fill/border keep `statusColor`.
- `apps/proximity_app/lib/widgets/student_card.dart` — new
  `studentAvatarForeground` (late/review avatar initials use on-tint in light,
  identical in dark); fill/border/`studentAvatarColor` untouched.
- `apps/proximity_app/lib/features/mark/proving_view.dart` — drift-banner icon
  uses `onTintLate`; fill/border/body copy untouched.
- `apps/proximity_app/test/tint_contrast_test.dart` — NEW (16 tests).

Audit (grep `statusLate|statusReview|statusColor\(` + `\.statusLate|`
`\.statusReview` + `ProxStateColors.of|ProxStatus.(late|review|pending)` +
`logCategoryColor` consumers):
- CHANGED: `widgets/verdict_badge.dart:129-154` (badge text+icon);
  `widgets/student_card.dart:86-87,205-209` (avatar initials text);
  `features/mark/proving_view.dart:191-200` (drift icon).
- AUDITED NO-CHANGE: `widgets/log_category.dart:26,29` + consumers
  `widgets/log_drawer.dart:275`, `features/debug/debug_log_screen.dart:163`
  (pure 8dp shape dots, labels use chip theme — "pure-shape dots unchanged");
  `widgets/prox_states.dart:85-111` ProxStateBadge (reads legacy
  `ProxStateColors`, not `ProximityColors`; late-light text on white is 5.18:1
  — left untouched so the legacy family and dark `0xFFFB923C` stay intact);
  `widgets/trust_cards.dart` DeviceTrustBadge (tiers map to
  marked/waiting/neutral, never late/review; WrongOrg icon is error — out of
  scope); `widgets/selection_toolbar.dart` + `ProxSectionHeader` (no status
  color); `widgets/prox_verdict.dart` late path (legacy `ProxStateColors`,
  untouched per above); `widgets/course_attendance.dart` (marked only);
  `features/setup/enroll_result.dart:308` (uncolored icon, inherits theme);
  `features/live/live_roster.dart:329` (waiting, not late/review).

Measured WCAG ratios (8-bit sRGB composite, pinned in `tint_contrast_test.dart`):
- Light late `#7A5A00`: 5.65:1 on badge tint `#F6F1E2` (12% over white),
  5.47:1 on avatar tint `#F4EDDB` (15%), 6.38:1 bare on white.
- Light review `#8A3D00`: 6.63:1 on badge tint `#F8EDE4`,
  6.37:1 on avatar tint `#F6E8DD`, 7.64:1 bare on white.
- Dark late `#E0B23A` (= status): 7.24:1 on tint `#2D2A20`, 8.98:1 bare.
- Dark review `#E0833A` (= status): 5.35:1 on tint `#2D2520`, 6.33:1 bare.
- Before (unchanged backgrounds): light statusLate 2.90:1 / statusReview 3.46:1
  on their tints (the filed gap); all ≥4.5:1 after via the on-tint foregrounds.

Verification:
- `flutter analyze` on the 5 touched/new files — No issues found; full
  `flutter analyze` — 1 pre-existing info only (`welcome_screen.dart:53`,
  untouched).
- `test/tint_contrast_test.dart` — 16/16 pass.
- Targeted suites (`proximity_colors`, `shared_components`, `app_theme`,
  `responsive_a11y`, `track5_states`) — all pass.
- Full `flutter test` — all pass (400/400 at time of run), 0 failures.
- Frozen guard: verdict strings, timing constants, thresholds, network calls,
  and all spec hex values untouched (spec-table test still pins the exact
  `statusLate`/`statusReview` hexes); no constructor call-sites outside the
  owned list edited; no existing tests edited.

## Task 1 relink

### Approach (D1 — repopulate linked identity on sign-in/continue)
- New `relinkLinkedIdentity(ref, acct)` helper in
  `apps/proximity_app/lib/features/entry/entry_flow.dart` (next to
  `entrySignOut`), mirroring the `main.dart` startup preseed rule
  (`initialLinked`, ~line 168) field-by-field: `LinkedIdentity(name:
  stored.name, gmail: stored.email, roll: stored.roll, org: stored.org)`.
  `readEnrollment()` fail-soft null; lowercased-email equality; mismatch /
  empty store / empty account email leaves state untouched (today's
  behavior; setup flow handles it). No heartbeat/touch call — no
  network-semantics change. Never throws (post-await provider touch on a
  dead screen is swallowed, same pattern as `entrySignOut`'s clearing
  touch).
- Call sites: `entrySignIn` on non-null account; `entryContinueWithRole`
  before branching (covers the silent-pickup path), mounted-guarded
  (`if (isMounted())`) per the file's law. `entrySignIn` keeps its
  signature (no `isMounted` param — changing it would touch
  `welcome_screen.dart`, out of scope); its safety comes from the
  helper's never-throws contract.
- Untouched as scoped: sign-out clearing, claim upload, gate predicate,
  join logic, strings, timings, thresholds, network calls.

### Files (owned: these two only)
- `apps/proximity_app/lib/features/entry/entry_flow.dart` (+48/−0: helper
  + two call sites, comments only otherwise).
- `apps/proximity_app/test/entry_relink_test.dart` (new, 3 tests, harness
  per `test/account_screen_test.dart`: FakeAuthService / FakeCloudSync
  (offline) / InMemoryDeviceStore, WidgetRef captured from a pumped
  Consumer).

### Evidence
- (a) enrolled store + same-Gmail sign-in (mixed-case seed
  `Student@Example.com`, proving lowercased equality) → linked non-null
  with stored name/gmail/roll/org.
- (b) different Gmail sign-in → linked stays null.
- (c) student `entryContinueWithRole` (offline cloud: gate skipped, stamp
  + goto run) → linked set from store AND mode == student, with a
  `container.listen` probe recording mode == unset at the moment linked
  was set — i.e. relink ran BEFORE goto, not after.

### Verification (exact results)
- `flutter analyze` on the 2 owned files — No issues found. Full
  `flutter analyze` — 1 pre-existing info only (`welcome_screen.dart:53`,
  untouched, plan-excepted).
- New `test/entry_relink_test.dart` — 3/3 pass.
- Related entry suites (`account_screen`, `device_identity`,
  `enroll_account_roll`, `setup_shell_gate`, `widget_test`,
  `face_identity`) — 83/83 pass.
- Full `flutter test` — 384/384 pass (381 baseline + 3 new), 0 failures.
- Method note: the shared tree currently does not compile at HEAD+all
  (concurrent Task 3 work in `lib/design/tokens.dart` — `Object.hash`
  with 21 args, exceeding the SDK max of 20 — breaks every suite that
  transitively imports tokens). Verification above ran in an isolated
  sandbox (HEAD base + only the two Task 1 files overlaid); the shared
  tree itself was not touched. Re-run `flutter test` here once Task 3
  lands its fix.

### Deviations
- None from the Task 1 scope. One scoping note: `entrySignIn` takes no
  mounted guard param (signature frozen); dead-screen safety is via the
  helper's never-throws contract, matching `entrySignOut` precedent.

## Account photo plumbing

### Approach (presentation of existing account metadata only, NOT a behavior change)
- `SignedAccount` gains `final String? photoUrl` (optional named, default
  null — constructor stays const-compatible; all existing construction
  sites compile unchanged). Doc pins it as the Google OAuth profile photo
  (ordinary account metadata, NOT `face_verification` output); renderers
  treat null/empty as the deterministic initials avatar.
- `FirebaseAuthService._map` gains optional `photoUrl` and a pure
  `_pickPhoto(google, firebase)` helper: prefer the Google-account photo,
  fall back to the Firebase `User.photoURL`, null when neither carries one
  (blanks count as absent). Mobile sign-in passes `acct.photoUrl`
  (both `_map` call sites, incl. the hd-refetch early return); web/popup
  passes nothing so the Firebase user photo flows automatically;
  `watchAccount`/`current` stream the mapped photo fresh with each auth
  state. Desktop/records builds unaffected (they throw/return-null before
  mapping). No DeviceStore/roles persistence — in-memory account object only.
- `FakeAuthService._withOrg` preserves `photoUrl` through org derivation
  (explicit-org instances pass through untouched), so tests seed photos via
  the existing `SignedAccount(photoUrl:)` constructor — no new API.
- `StudentAccountScreen` + `ProfAccountScreen` headers feed
  `photoUrl: acct.photoUrl` (null/empty → the chip's existing
  errorBuilder→initials fallback, no new branches). `AccountChip` reused
  as-is. Shell `_AccountTabIcon` (anchored edit only): photo branch renders
  a 20dp `ClipOval(Image.network)` with errorBuilder→initials fallback;
  null/empty renders the same bare `CircleAvatar` initial as before; same
  20dp avatar, same active-ring, no layout change. Never reads
  `face_verification` output for display (principle 6).
- Frozen per FEATURE_INVENTORY Appendix A: verdict strings, timing
  constants, thresholds, network calls untouched.

### Files (owned: these four only)
- `apps/proximity_app/lib/core/auth.dart` (photoUrl field + `_map`/`_pickPhoto`
  + mobile sign-in passthrough + fake passthrough).
- `apps/proximity_app/lib/features/account/account_screen.dart` (two
  `AccountChip` call sites: `photoUrl: acct.photoUrl` + comment refresh).
- `apps/proximity_app/lib/screens/shells.dart` (`_AccountTabIcon` block only).
- `apps/proximity_app/test/account_photo_test.dart` (new, 15 tests).

### Evidence
- Model: default null const-compatible; explicit URL preserved.
- Fake passthrough: constructor + `seedAccount` preserve photo through org
  derivation; explicit-org passes the same instance; null stays null.
- Chip: photo URL builds `Image.network` with that URL (pre-settle tree);
  null/blank render initials (`TU`) with no `Image`; invalid URL settles
  into initials (`AL`) with no broken-image icon.
- Screens: student + professor headers carry `acct.photoUrl`; null header
  keeps the no-`Image` fallback.
- Shell: photo account takes the `ClipOval` photo branch; null account
  renders the bare initial (`T`) with no `ClipOval`/`Image`.

### Verification (exact results)
- `flutter analyze` on the 4 owned files — No issues found. Full
  `flutter analyze` — 1 pre-existing info only (`welcome_screen.dart:53`,
  untouched, plan-excepted).
- New `test/account_photo_test.dart` — 15/15 pass.
- Targeted suites (`account_screen`, `account_photo`, `shared_components`,
  `enroll_account_roll`, `org`) — 102/102 pass.
- Full `flutter test` — 417/417 pass, 0 failures.

### Deviations
- None from scope. No existing test constructs `SignedAccount` in a way
  that breaks (new field is optional-default-null), so no existing test
  needed fixing. `widgets/` untouched (`account_chip.dart` reused as-is);
  `take_attendance`, `entry_flow`, tokens, routes, existing tests untouched.
  Concurrent sibling-agent files in the shared tree (`tokens.dart`,
  `entry_flow.dart`, `proving_view.dart`, `take_attendance.dart`,
  `student_card.dart`, `verdict_badge.dart`) were not touched.

## Task 2 back-intercept

### Approach (D2 — scoped back-intercept awaiting the existing `_leave` body)
- Extracted `_leave`'s teardown half (timers → awaited `_saveDraft` →
  awaited `endHosting`) into `_teardown({bool save = true})`; the default
  path is byte-equivalent to the old `_leave` body (same freeze-first
  order, same log line, same try/caught endHosting).
- `PopScope(canPop: false, onPopInvokedWithResult: ...)` wraps the take
  route body; the handler funnels into `_leave` via `_interceptBack`.
  BackButton (`() => _leave()`, unchanged line), the intercept, and the
  `_endAttendance` tail all run through `_teardown`.
- Guards: `_leaving` single-flights (second back-press mid-await ignored);
  `_bypass` is set before our own programmatic pops and checked in the
  handler. `_endAttendance` keeps its order (snapshot → clear → resets)
  and calls `_teardown(save: false)` — saving there would resurrect the
  just-cleared draft; its catch now releases `_leaving` so a failed End
  stays retryable (today a failed End leaves the screen usable, and a
  stuck flag under canPop:false would trap it).
- `dispose()` byte-identical backstop. No draft/snapshot/window/driver
  semantic changes, no strings, no mode/shell/routes/widgets changes
  (not the removed setMode pattern — shell still owns tab back).

### Files (owned: these two only)
- `apps/proximity_app/lib/screens/take_attendance.dart` (flags +
  `_teardown`/`_leave`/`_interceptBack`, `_endAttendance` tail, PopScope
  wrap + comment refresh; scaffold body re-indented only).
- `apps/proximity_app/test/take_back_intercept_test.dart` (new, 2 tests).

### Evidence
- Pushed take + marks → system-back via test back dispatcher → draft
  contains the marks, hosting down, exactly one pop (`NavigatorObserver`
  count 1), `endHosting` called exactly once (the awaited intercept
  teardown — no double-teardown).
- Double system-back with no settle between → still one teardown, one pop.
- SDK findings (Flutter 3.47.2, verified by throwaway spike tests,
  removed after): explicit `Navigator.pop()` under `canPop:false`
  completes and notifies `didPop:true` (no re-fire), so the constant
  `canPop:false` cannot trap the route; `ref.read` inside
  `State.dispose()` throws ("Cannot use ref after dispose") and is
  caught — dispose's driver call is a best-effort no-op in this Riverpod
  version (pre-existing, untouched per scope), which is why the
  no-double-teardown pin is exactly 1, not 2. Shell system-back still
  routes via `_shellBack`'s explicit tab pop (shells.dart untouched, out
  of scope) → dispose backstop path there is behavior-identical to today.

### Verification (exact results)
- `flutter analyze` on the 2 owned files — No issues found.
- New `test/take_back_intercept_test.dart` — 2/2 pass.
- Take/live suites (`widget_test`, `course_test`, `live_sections_test`,
  `live_manual_attendance_test`, `manual_add_test`, `recover_policy_test`,
  `offline_live_test`, `host_driver_test`, `course_attendance_test`,
  `records_rebuild_test`, `dup_flag_section_test`) — all pass.
- Full `flutter test` — 417/417 pass, 0 failures.

### Deviations
- `_teardown` takes a `save` flag (default true = exact old `_leave`
  body) so `_endAttendance` can share the tail without rewriting the
  cleared draft; and an `endHosting` throw inside `_endAttendance` now
  stays caught with the pop proceeding (uniform with `_leave`; previously
  it surfaced `serverError` and kept the screen mounted). Both called out
  above; no frozen string/timing/threshold/network touched.

## Live roster fix (2026-09-10)

Tester-reported Live-tab placement bug: the professor ROSTER section showed
manual-entry UI (direct-add form / add entry) belonging in its own add/inbox
sections behind the sub-nav. Roster now shows ONLY waiting + present +
partial + dup + search.

### Root cause
- The take host (`screens/take_attendance.dart`, sibling-owned, untouched)
  mounts every live section in ONE scroll (waiting → inbox → direct-add →
  marked) with the sub-nav acting as scroll-spy; the `live_roster.dart`
  header comment blessed that interleaving as the design ("the inbox stays
  near the top where approvals happen mid-class").
- The dedicated roster path (`LiveRosterScreen`, `live/<course>/roster`)
  was already free of manual-entry composition; the monolith risk was
  `MarkedRosterSection` (search + present + partial + filtering in one
  State), inviting future manual UI to land back in the roster path.

### Diff (owned files only)
- `lib/features/live/live_roster.dart` — presentational split, no behavior
  change: new `LiveRosterBody` thin composer (waiting + dup + marked);
  `MarkedRosterSection` (same `({key, tally})` constructor) keeps owning
  `_search` + the intersection-gated filtering and now renders via new
  single-purpose `RosterSearchField` (same `prof-search` key/label/icon),
  `PresentSection` (header + intersection rows, same no-entrance rule),
  `PartialSection` (header + partial rows; shrink when empty, same
  spacing). `WaitingListSection`/`DupFlagSection`/helpers untouched.
  Header comment corrected: manual inbox + direct add NEVER compose here.
- `lib/features/live/live_sections.dart` (roster path only):
  `LiveRosterScreen` composes `LiveRosterBody` (same order/spacing/reads);
  inbox/add/setup screens untouched, module logic unaltered.
- Radius audit: owned files contain zero corner-shaping code (one
  `InputDecoration`, no radii); all cards render via `StudentCard`/
  `ProxCard`, which already use `ProxRadii` tokens — no change needed.
- New `test/live_roster_fix_test.dart` (4 tests): roster renders no
  `ManualAddForm`/`Direct manual entry`/`Add & mark present`/`Manual
  requests`; inbox section approves through the driver (pending empties,
  snapshot path runs); add section queues an ID-only entry offline through
  its wiring; splits render standalone + `MarkedRosterSection` still
  composes search + present + partial.

### Verification (exact results)
- `flutter analyze` (owned files, plus full tree): 1 pre-existing info
  only (`welcome_screen.dart:53`, untouched, out of scope).
- New `test/live_roster_fix_test.dart` — 4/4 pass.
- Live suites (`live_sections_test`, `live_manual_attendance_test`,
  `dup_flag_section_test`, `identity_surface_test`, `manual_add_test`) —
  all pass (39/39 with the new file).
- Full `flutter test` — 422 pass, 6 fail in
  `enroll_beacon_boundary_test`/`enroll_guided_test` (enroll capture
  overlay); proven pre-existing by re-running those files with both owned
  lib files reverted to HEAD (still fail — sibling in-flight work in
  `enroll_capture`/`capture_overlay`/mark files, out of scope).

### Deviations
- The take host's single-scroll interleaving (`take_attendance.dart`
  lines ~1001-1035) still mounts inbox/add inline in the host scroll;
  NOT touched per file ownership (sibling back-intercept work lives
  there). Flag for the take-screen owner: filter the host scroll behind
  the sub-nav selection or keep scroll-spy deliberately. Frozen strings,
  timings, decision paths, draft/snapshot semantics untouched.

## Mark slimdown

Scope: tester-reported Mark-tab fixes, presentation/navigation only
(`features/mark/browse_classes.dart`, `verdict_view.dart`, 7 NEW
`features/mark/*` splits, `screens/student_home.dart`
composition/phase/back only, related mark tests). Frozen per Appendix A:
verdict strings, timing constants, thresholds, network calls — all
untouched. NOT touched: `face_check.dart` (sibling A — its working-tree
diff is sibling-owned), `setup/`, `live/`, `records/`, `account/`,
`shells.dart`, `routes.dart`, `widgets/`, `drivers`, `core/`.

### 1. Browse slim-down (records + enroll entries removed)
- `browse_classes.dart`: DELETED the `Enroll this device (face + ID)`
  button block (`linked == null && canUseFace()`), the records-only
  guidance block (`linked == null && !canUseFace()`), and the `My
  attendance records (synced)` button block. Constructor drops `linked`,
  `onEnroll`, `onViewRecords` (dead params removed, not deprecated);
  dropped now-unused `mode.dart` / `prox_buttons.dart` imports
  (`LinkedIdentity`/`StudentCard`/`VerdictBadge` uses moved to
  `browse_list.dart`). KEPT verbatim: ClockHeader, identityLine, join-error
  banner, `Live on this WiFi` + DetailsExpander/LadderLine, blocked
  banner, radar empty state, live tiles, `Enter IP manually`
  FallbackButton → one-field sheet (`JoinByIpSection` untouched, same
  keys/contract), foreground note, pull-refresh. IP fallback stays
  fallback-weight (button → sheet, never inline).
- Host (`student_home.dart` `_browsing`): dropped `linked` param and the
  `onEnroll` (`EnrollFlow.openBundle`) / `onViewRecords`
  (`MyAttendanceScreen` push) callbacks; removed the two imports (each
  used only there — verified by grep). `mode.dart` import stays
  (`canUseFace` L1 gate + `LinkedIdentity` types still used by `_scanFace`
  and signatures — gate logic untouched).

### 2. Back-after-marking (one step to browse, every verdict)
- Symptom: `marked`/`late` `onBack` were `() {}` no-ops AND neither
  verdict rendered any back button; `wrongOrg`/`needsReview`/`noSignal`
  only `setState` browsing (no shared teardown); system back fell through
  to the shell hint/leave path.
- `verdict_view.dart`: Marked and Late branches gain an explicit
  `VerdictBackToClasses` (`Back to classes`, frozen label already carried
  by wrong-org) wired to `onBack` — marked's sits OUTSIDE the wash so
  wash tap-to-skip never swallows it; late's mirrors the wrongOrg order
  (back, then manual fallback). wrongOrg's inline button replaced with
  the identical shared widget; needsReview `Back` + noSignal `Try again`
  kept inline (distinct frozen labels, same `onBack`).
- Host: all five terminal arms now build via `markVerdictSection()` with
  ONE shared `onBackToBrowsing: _cancelToBrowsing` (the existing
  runId++/stop-timers//leave teardown its doc already names "the
  system-back handler (same teardown everywhere)" — reused, body
  untouched; no new endpoints, no network-semantics change). Manual-pending
  `Back` already used it (unchanged). Paused keeps its byte-identical
  `setState → browsing` destination (extracted widget only).
- System-back path: new verdict-scoped `PopScope` in host `build`
  (`canPop: !_isVerdictPhase`, veto → `_cancelToBrowsing`). Intercepts
  ONLY marked/late/wrongOrg/needsReview/noSignal; waiting/face/listening
  stay pass-through (shell owns those backs; they still end only via
  explicit Cancel/Leave) and manual-pending/paused keep their own buttons.
  The §3.5 PopScope-removal comment lines are byte-untouched; the new
  exception is documented in its own comment below them.

### 3. Modularity (one purpose per file; orchestration stays)
New files under `features/mark/` (widget-building only; timers, drivers,
drafts, nav/gate logic untouched in the host, called out file-by-file):
- `browse_banner.dart` — `BrowseBanner` (was `_ThinBanner`, verbatim).
- `browse_empty.dart` — `BrowseEmptyState` + radar painter (verbatim).
- `browse_list.dart` — `signalBarsFor` (pure, verbatim) + `BrowseTile` +
  signal cluster (verbatim; 2px glyph-bar rounding documented as glyph,
  not card).
- `verdict_actions.dart` — `VerdictManualFallback` (was `_manualFallback`,
  verbatim sheet) + `VerdictBackToClasses` (shared back button).
- `marked_wash.dart` — `MarkedWash` + wash-ink override (verbatim move;
  the `#14161A` pair is the token-prescribed §9 dark-ink override, not a
  raw-color violation).
- `paused_view.dart` — `PausedView` (host's paused tree, verbatim incl.
  literal `8` gap).
- `verdict_section.dart` — `markVerdictSection()` (the five host verdict
  arms; retry/manual/back callbacks stay host-owned closures passed in).
`browse_classes.dart` (−~330 lines) and `verdict_view.dart` (−~120 lines)
are composers now; host switch verdict arms collapse to one call.

### 4. Corners audit (owned files)
Grep: zero `BorderRadius.zero` / `circular(0)` / `Colors.*` in owned
files; every card container uses `ProxRadii.cardSpecRadius`, pill, or
circle tokens (banner, wash, drift banner untouched, trail pills,
presence ring). The only `Color(0x…)` literals are the pre-existing
wash-ink pair (moved verbatim, §9-required). No changes needed; applied
by verification, not by edit.

### Tests
- Updated (constructor slim-down): `browse_banner_test.dart`,
  `identity_surface_test.dart` (dropped `linked`/`onEnroll`/`onViewRecords`
  args; asserts unchanged).
- NEW `test/mark_slimdown_test.dart` (11 tests): empty browse keeps
  chrome + drops records/enroll; populated browse keeps tile + both
  banners + drops extras; marked/late expose `Back to classes` wired to
  `onBack`; wrongOrg/needsReview(±attempts)/noSignal keep their backs;
  host marked-back → browse and stays (rewait dead, no waiting/face hop);
  host late-back → browse and stays; host manual-rejected Back → browse;
  host system-back (`handlePopRoute`) from marked → browse in one step
  (no verdict, no waiting on the way); `markVerdictSection` builds +
  rejects non-verdict phases.
- Existing no-signal host path (`Try again` → browse) still covers
  `widget_test.dart` unchanged.

### Verification (exact results)
- `flutter analyze` — 1 pre-existing info only
  (`features/setup/welcome_screen.dart:53`, untouched, Nav-logged). Zero
  in owned files/tests.
- `flutter test test/mark_slimdown_test.dart test/browse_banner_test.dart
  test/identity_surface_test.dart test/track5_states_test.dart
  test/widget_test.dart test/responsive_a11y_test.dart` — 75/75 pass.
- Full `flutter test` — 449/449 pass, 0 failures.

### Deviations (called out)
- MARK-S1 (fix, tester-mandated): added `Back to classes` buttons to
  Marked/Late (previously button-less with no-op `onBack`) + wired every
  verdict back to the shared `_cancelToBrowsing` teardown (previously
  three arms only `setState` browsing). Same existing teardown, no new
  network surface; verdict strings/copy/styles otherwise frozen.
- MARK-S2 (surgical): verdict-scoped host `PopScope` for system-back from
  terminal verdicts only (shell still owns all other backs; §3.5 comment
  lines untouched). Without it, system-back from a verdict could never
  reach browsing (single-route phases, tab-root hint path).
- MARK-S3 (removal): browse constructor params `linked`/`onEnroll`/
  `onViewRecords` deleted outright (gate + Courses + Setup/Account own
  those now) rather than deprecated; two related tests updated.
- Pre-existing, NOT touched: `face_check.dart` / `proving_view.dart` /
  `shells.dart` / `core/auth.dart` / `widgets/*` working-tree diffs are
  sibling-owned (present before this task; verified via initial
  `git status`); `live_roster_fix_test.dart` flaked once in a full-suite
  run pre-change yet passes in isolation and in the final 449/449 run.

## Account fixes

### Root causes found
1. Re-enroll after enrollment: `_EnrollmentSection` keyed its branches on
   the bare presence of ANY stored enrollment — enrolled always rendered
   the `Re-enroll this device` fallback into the enroll chain, and the
   `Move to this device` entry in `_moveStatus` (allowedMove) never
   checked whether the device is already enrolled for the signed-in
   account. Neither entry consulted the linked identity at all.
2. Stale account after switch: two compounding causes. (a) The enrollment
   / ID / Face-ID / device sections rendered the device-store enrollment
   (and linked roll) unscoped — `entrySignOut` deliberately never wipes
   the stored enrollment, so after a switch the page showed the previous
   Gmail's `Enrolled as …`, org, roll, and Face-ID freshness. (b) The
   IndexedStack-kept Account Navigator preserves its tab root across
   sign-out/sign-in, so cached `FutureBuilder` snapshots survived the
   switch. (`Student/ProfAccountScreen` already `watch` the account
   stream; the watch alone was not the bug — the unscoped store reads
   were.)
3. Flat-square header: the large-header `AccountChip` wash (`Stack` +
   `Positioned.fill`, no clipping, no border) rendered as an unbordered
   square. Page audit: every other corner on the page comes from shared
   `widgets/` tiles/cards (out of scope, already radius-treated via the
   app card theme); the header was the only square.

### Approach (owned: `features/account/*` + Account-tab lines in
`screens/shells.dart` only; `entry_flow`, `widgets/`, tokens, routes,
all sibling areas untouched)
- `_enrolledForAccount(acct, linked, stored)`: enrolled-for-account =
  linked Gmail OR stored-enrollment email matches the signed-in Gmail
  (case-insensitive). Drives EVERY enroll entry on the page.
- Enrolled ⇒ enrolled state only, zero enroll CTAs: the `Re-enroll this
  device` fallback is deleted from the Account page (re-scan stays on the
  `account/face-id` sub-page, which is untouched); the `Move to this
  device` fallback is suppressed while enrolled (verdict badge + frozen
  note still render, so no verdict information is lost). Not enrolled ⇒
  the `Enroll this device` entry shows as before.
- `_storedForAccount` / `_linkedRollForAccount` / `_linkedOrgForAccount`:
  stored enrollment, linked roll, and linked org render only when filed
  under the CURRENT Gmail; a previous account's lingering enrollment
  renders as "no key for this account", never as this account's facts
  (enrollment section, ID row, Face-ID freshness, device section).
- Not-enrolled enrollment branch now leads with the CURRENT account's
  `Organization` row (existing label vocabulary, account-derived value)
  so the page reflects the signed-in account's email/org even before it
  enrolls — this is what the switch regression test pins for account B.
- `_HeaderCard` (both student + professor pages): `surfaceRaised` fill +
  `divider` 1dp border + `ProxRadii.cardSpecRadius` (spec 16, canonical
  for new cards) + `Clip.antiAlias`, zero shadow (flat per the app card
  theme). The approved large-header gradient wash is untouched inside,
  now clipped to the radius. Keyed `account-header-card` for tests.
- `shells.dart` (Account-tab lines only): student + professor Account tab
  roots keyed by signed-in Gmail
  (`student/prof-account-<lowercased-email>`, `signed-out` when signed
  out), watched from the live account stream — a switch unmounts the
  previous account's page (dropping cached reads) and mounts a fresh one;
  sign-out clears the displayed identity immediately.

### Files
- `apps/proximity_app/lib/features/account/account_screen.dart` (helpers,
  `_HeaderCard`, gated/scoped sections, both page headers).
- `apps/proximity_app/lib/screens/shells.dart` (two keyed tab roots +
  comments only; sibling `_AccountTabIcon` photo work left as-is).
- `apps/proximity_app/test/account_screen_test.dart` (2 tests updated:
  enrolled page now expects NO enroll/re-enroll/move entries by label and
  key; eligible-move test re-seeded with a foreign enrollment + no linked
  identity so it pins the move entry for the not-enrolled case, plus
  asserts the foreign enrollment never renders).
- `apps/proximity_app/test/account_fixes_test.dart` (new, 6 tests — see
  Evidence). Needs `SwitchableAuth`, a stream-backed auth fake: the
  single-shot `FakeAuthService` stream cannot emit twice, so account
  switching is exercised through real stream emissions + the real page
  sign-out action (`entrySignOut`).

### Evidence
- Fix 1: enrolled-for-account (stored + linked + sameDevice gate) shows
  `Enrolled as …` with no `account-enroll-entry` / `account-reenroll-entry`
  / `account-move-entry` by label or key; Account page carries no
  `Re-scan face` — the Face-ID row pushes `FaceIdScreen`, which keeps its
  `face-id-rescan` fallback; unenrolled account still gets the enroll
  entry + current org.
- Fix 2: sign in A → A email, `Enrolled as A`, `RA1001` shown; real
  sign-out tap → Welcome with zero trace of A (identity clears
  immediately); sign in B (A's enrollment still on file) → B email + B
  org shown, A email / `Enrolled as A` / roll / org all absent, enroll
  entry back for B.
- Fix 3: student + professor `account-header-card` containers assert
  `borderRadius == ProxRadii.cardSpecRadius`, non-null border, empty
  shadow, `Clip.antiAlias`, with the `AccountChip` wash inside.

### Verification (exact results)
- `flutter analyze` on the 4 owned files — No issues found. Full
  `flutter analyze` — 2 issues, both outside ownership and untouched:
  `marked_wash.dart:25` unused import (sibling in-flight file), plus the
  known pre-existing `welcome_screen.dart:53` info.
- New `test/account_fixes_test.dart` — 6/6 pass.
- Account suites (`account_screen`, `account_fixes`, `account_photo`,
  `enroll_account_roll`) — 48/48 pass.
- Full `flutter test` — 449/449 pass. (One earlier full run showed a
  single failure in the sibling-owned enroll-capture overlay area also
  flagged as in-flight in the Live-roster entry above; the rerun and the
  final full run are fully green.)

### Deviations
- `ProxRadii.cardSpecRadius` (16) chosen over legacy `cardRadius` (14):
  the brief says "card radius" via design tokens, and 16 is the redesign
  canonical for new cards; the frozen app card theme is untouched.
- Unenrolled branch shows the current account's `Organization` row (new
  row, existing label vocabulary, account-derived value) — required so
  the page shows the current account's org pre-enrollment; no frozen copy
  altered.
- Face-ID row keeps the frozen `Enrolled` / `Needs re-face` vocabulary
  with freshness now scoped to the current account; no new strings added
  anywhere (all verdict/claim/move copy byte-identical).
- `Re-enroll this device` has no replacement entry point on the Account
  page per the brief (enrolled ⇒ no enroll CTA); full re-enroll now
  routes through the setup/enroll chain outside this page, which is owned
  by the setup sibling — flagging the handoff explicitly.

## Overlay redesign (2026-09-10)

Product-owner override: tester reports the camera preview looks squished
with clutter. Applies to BOTH mark/face and enroll/capture. Supersedes
PROXIMITY_UI_REDESIGN.md §6.2 two-oval rule and the CaptureOverlay
two-oval contract — logged here as deviation OVD-1, old rule NOT followed.

### What changed (presentation ONLY)
- `lib/widgets/capture_overlay.dart` — rewritten to exactly three overlay
  elements: (1) ONE slim (`minHeight: 4`, pill-clipped) `LinearProgress-
  Indicator` pinned `top: ProxSpacing.sm` below the app bar (angle
  completion); (2) ONE static centered oval (`guideRectFor`, 0.70w×0.52h)
  + ONE glowing beacon dot travelling its perimeter (target direction by
  default, `sweepAngle` while classifying); (3) ONE prompt line
  (`ProxType.label`, `maxLines: 1`, ellipsis) below the oval. Scrim stays
  `gradientScrim`; beacon halo derives color/opacity/blur from
  `glowMarked` (§2.5 token-sourced — blur is `glowMarked.blurSigma / 3`,
  same token, dot-scale). Reduce-motion: beacon static at target
  (`sweepAngle` ignored when `ProxMotion.reduced`). `directionForAngle`,
  `largeRectFor`/`smallRectFor` (pure helpers), pulse cadence
  (`ProxDurations.dotPulse`) kept.
- `lib/features/mark/face_check.dart` — full-bleed preview surface
  (`StackFit.expand`, token `surfaceRaised`) + `CaptureOverlay` +
  `Scan face` fallback (`ProxPrimaryButton`, host-owned timing untouched).
  Removed: `ListeningDot`, `Professor started marking…` subline, card
  wrapper, `ringMorph` entrance. `signalForNotice` mapping byte-identical;
  props (`faceNotice/canScan/onScan/totalAngles/currentAngle/progress`)
  unchanged — `student_home.dart` untouched.
- `lib/features/setup/enroll_capture.dart` — presentation regions ONLY:
  preview is now `Expanded > StackFit.expand` full-bleed with
  `FittedBox(BoxFit.cover)` on the controller's own `aspectRatio` (squish
  fix: area changes crop, never stretch); `CaptureOverlay` carries
  `statusLine: enrollCapturePrompt`; mid-flow bottom bar is empty
  (`SizedBox.shrink`, no duplicate prompt); validated Continue /
  save-error Try-again + `_SlotTopUp` + save-error toast unchanged.
  Driver/timers/save/dispose byte-identical (verified: diff touches no
  `_initialBeat/_frameBeat/_sweepTick/_sweepRevolution`, `classifyInto`,
  `readPose`, `captureStill`, `enrollFace`, `_autoLoop/_captureOne/
  _saveAll/_cancel`, dispose latches — only comment lines mention them).

### New copy (one line, logged)
- `captureGuidePrompt = 'Rotate your face slowly with the green beacon.'`
  (`capture_overlay.dart`) — renders only when the caller passes no
  explicit line (mark/face at rest). Enroll keeps frozen
  `enrollCapturePrompt` verbatim (passed as `statusLine`, single
  instance); inconclusive/retry host notices keep rendering as the one
  line when present. No other strings added or altered.

### Deviations (override cites)
- OVD-1: §6.2 two-oval rule superseded per 2026-09-10 product-owner
  override (this entry). Single oval + beacon replaces small-target +
  large-progress rings in overlay, mark/face, and enroll/capture.
- OVD-2: old boundary-parity chain retired (`Center` wrapper + hidden
  reservation removed; area-equality pins dropped) — cover-fit makes area
  constancy unnecessary; feed can no longer elongate.
- OVD-3: `signalColorFor(neutral)` is now `statusMarked` (was
  `accentBrand`) — neutral must read as the glowing-green beacon spec.
  Inconclusive (`contentSecondary`) / mismatch (`statusError`) unchanged.
- OVD-4: spec "white oval" renders as `contentPrimary` (theme's light
  tone, near-white in dark) — no raw `Colors.white`/`Color(0x…)` per the
  tokens rule; audit grep confirms zero raw colors in owned files.
- OVD-5: fullscreen preview fills are edgeless (no radius) by design —
  no card/sheet corners exist to round; progress bar uses the pill radius
  token (`ProxRadii.chipRadius`); buttons are shared `ProxPrimaryButton`
  (radius token inside). Zero `BorderRadius.zero` in owned files.

### Tests
- New `test/overlay_redesign_test.dart` (12): guide/beacon pure geometry
  (perimeter, top-park), three-element render + bar-top/prompt-below
  placement + pill clip, default vs explicit line, reduce-motion static,
  `FaceCheckView` fullscreen + overlay + one prompt + Scan fallback + no
  `BLE listening`/professor-subline, notice-as-one-line, enroll consumer
  fullscreen + single prompt + no `Center` + cancel-dispose safety.
- Updated: `shared_components_test.dart` (neutral-green pin, three-element
  + default-prompt cases), `enroll_guided_test.dart` (cover-fit parity
  pins, overlay-owned prompt, chain without `Center`), `enroll_beacon_-
  boundary_test.dart` (reservation/area-equality retired, toast + chrome
  lifecycle, one-line Stack contents).
- Evidence: `flutter analyze` (owned 3 lib files + 3 affected test files)
  — No issues found. `flutter test test/overlay_redesign_test.dart
  test/shared_components_test.dart` — all pass. `flutter test
  test/enroll_guided_test.dart test/enroll_beacon_boundary_test.dart` —
  40/40 pass. Driver suites (`student_driver`, `enrollment_lifecycle`,
  `face_identity`) — 47/47 pass. Full `flutter test` — 449/449 pass.

## Claim-error root cause

Second-account-same-device enrolls surfaced raw Firestore text because a
cross-org install-doc read denies before the claim transaction ever runs,
so the client verdict never saw the evidence (deploy hint / raw denial
instead of the friendly refusal). Fixed by verdict-by-evidence scoping —
no new server semantics, no new copy, fake↔prod message identity (same
`studentClaimMessage` / `cloudRulesHint` sources everywhere):

- `core/sync/claim.dart`: `cloudRulesHint(op)` (single source; byte-identical
  to the old inline hint) + `isRulesDenialMessage(msg)` (true only for
  `security rules` + `permission-denied`; all friendly copies return false).
- `core/sync/firestore_sync.dart`: `_rulesError` delegates to
  `cloudRulesHint` (output unchanged); claim-transaction
  `permission-denied` now goes through `_scopedClaimDenial` (server-source
  probes): own-doc unreadable → deploy hint; own clean + install denied →
  friendly installConflict copy (`another account` fallback — the incumbent
  email is unreadable); both readable (write-time race) → deploy hint;
  offline probes → verbatim offline copy. No raw Firebase text escapes.
- `core/enrollment.dart` `upload()`: pre-claim evaluation before the
  transaction (clean own read + denied install read → installConflict
  verbatim; own denied → hint verbatim; unknown read failures skip the
  pre-claim and the transaction decides, as before); new
  `on FirebaseException` arm — permission-denied → installConflict copy,
  other transport codes → verbatim offline copy (retry-safe, capture kept).
  The generic `Save failed: $e` remains only for non-Firebase surprises.
- `features/entry/entry_flow.dart` `entryStudentGate`: denied install read
  after a clean own read flips an otherwise-ok verdict to installConflict
  (was: swallowed to null → misread as free-to-enroll); other failures
  unchanged. `entryRegisterStudent` refusal path untouched (already
  `studentClaimMessage`).

Tests: new `test/setup_claim_denial_test.dart` (10): hint/friendly
discrimination, denied-install-read → EXACT installConflict copy + stores
nothing, denied-own-read → EXACT hint, named-incumbent conflict unchanged,
cooldown pre-claim copy intact, happy first-bind unchanged, no raw
Firebase/grpc text on screen, gate install-denied → installConflict verdict,
gate own-denied still surfaces, gate happy → firstBind.

## Setup modularity

One-function-per-screen rebuild of the setup bundle (presentation only —
verdicts, timing, thresholds, network, refusal semantics untouched):

1. CLAIM-ERROR ROOT CAUSE — see `## Claim-error root cause` above (done).
2. Progress-bar placement (`screens/setup_flow_screen.dart` structure only,
   stepper behavior untouched): the per-page `Column[Progress, Expanded]`
   painted the blue line above the inner Scaffolds' top bars. Now one
   `SetupProgressOverlay` (`setup_progress.dart`: top-only SafeArea +
   platform nav-bar offset + IgnorePointer, same index/count→value
   semantics) floats on the app-bar/body seam for all steps including the
   sibling-owned capture step. Pinned by placement test (single line,
   dy ≥ AppBar bottom − 3.5).
3. Modularity: giant steps → thin composers + single-purpose sections —
   `welcome_sections.dart` (Hero/SignIn), `role_sections.dart`
   (Register/Resume/AddRole/Footer), `device_sections.dart`
   (Account/Key/Move/OfflineNote), `intro_sections.dart`
   (Overview/Online/OneDevice/Account/Key), `result_sections.dart`
   (Status/Refusal+next-step/Success + public `EnrollRefusal`/
   `classifyEnrollRefusal`). `device_intro_step.dart` untouched (already
   thin). Orchard: `SetupStepScope`, listeners, start-index, lazy camera
   mount, step-back byte-identical.
4. Copy trim: secondary prose collapsed behind DetailsExpanders —
   welcome `For professors`, role `About holding both roles` /
   `About the one-device rule` / `Lost your phone?` /
   `Why only professor here?`, intro `What the five angles involve` /
   `What goes over WiFi`, device `Offline professors`. All sentences
   verbatim (moved, split only at sentence boundaries — step-3 angles
   list + on-phone guarantee stay visible). Test-relevant + refusal copy
   stays visible with no expansion step. `setup_details.dart` wraps the
   shared expander with a `ProximityColors.light()` fallback so legacy
   themeless harnesses keep passing (themed production path is a pure
   passthrough).

Deviations: none in behavior/copy. Process notes: (a) deleted the orphaned
`claim_error.dart` UI-remap sketch from an earlier turn — superseded by the
verdict-by-evidence redirect, referenced nowhere; (b) two test-harness
learnings — `StateNotifierProvider.overrideWith` must create the
controller inside the closure (pre-created instances are silently
unobserved), and `AnimatedCrossFade` keeps collapsed text in-tree so
collapsed-by-default is pinned via `crossFadeState`, not findability.

### Tests
- New `test/setup_claim_denial_test.dart` (10) + `test/setup_bundle_rebuild_test.dart`
  (11: placement, 5× modularity-renders, refusal-renders, 4× trim).
- Evidence: `flutter analyze` — clean except 1 pre-existing info
  (welcome_screen.dart:52, HEAD code). Full `flutter test` — 470/470 pass,
  incl. enroll/entry/setup suites (widget enrollment flow, roll,
  lifecycle, cloud_sync, relink, shell-gate, guided, beacon-boundary,
  manual_add, shared_components, identity_surface, live_manual_attendance).

## Monolith-removal ledger execution (2026-09-10)

Cleanup + two copy corrections only. No structural/behavior changes. Giants
(enroll_capture, student_home, take_attendance) untouched as orchestration
owners; face_capture, manual_add shim, all mark/* splits, setup
composers/sections, badge/overlay/camera seams, session_edit ExpansionTile,
routes untouched.

1. STALE COMMENT `apps/proximity_app/lib/features/setup/enroll_flow.dart`
   (old lines 21-35 PROPOSALS block) — DELETED (16-line diff: block +
   its separator). Pre-delete evidence: `grep EnrollmentScreen` over
   `apps/proximity_app` → sole hit was the comment itself; `ls
   lib/screens/enrollment.dart` → No such file; `main.dart:342`
   `AppMode.enroll => SetupFlowScreen(` confirms PROX_MODE=enroll builds
   the flow; zero importers of the old screen. Imports + EnrollFlow kept.
2. UNUSED CLASS `ProxAnimatedCount` (`lib/widgets/prox_motion.dart`
   ~:165-200) — DELETED (28-line diff). Pre-delete evidence: `grep
   ProxAnimatedCount` over lib+test → definition only + one doc-mention
   (`animated.dart:7`); zero instantiations. Stale doc line
   `animated.dart:7` fixed words-only: dropped `Prefer
   [ProxAnimatedCount] in new code;`, now reads `Honors reduced motion
   (instant swap). Kept for the take-attendance header contract.`
3. COPY `role_sections.dart` ~:257-258 one-device rule — FIXED. Was
   `once a week (unlimited times)`; now `once a month (unlimited moves,
   at most one per 30 days)`, matching source of truth
   `core/sync/claim.dart:226` (`once a month (unlimited moves, at most
   one per 30 days)`) and in-file precedent `:131` (`once a month`).
   No test pins the old string (grep `3 stills|once a week|waits out the
   week` over test/ → zero hits for week variants; only
   `enrollment_lifecycle_test` `once a month` contains-assert, unaffected).
4. COPY `core/sync/firestore_sync.dart` 6x offline `your 3 stills are
   kept` — all 6 UPDATED to capture-neutral `your capture is kept`
   (492, 498, 520, 527, 541, 551). `core/enrollment.dart:574,681`
   (`your face capture is kept`) LEFT as instructed. Test-pin check:
   `grep needs internet|stills are kept|capture is kept` over test/ →
   sole hit `setup_claim_denial_test.dart:83` pins the enrollment.dart
   `face capture` variant (used as a non-denial example for
   `isRulesDenialMessage`), NOT the firestore `3 stills` strings — no
   test touched, none needed.

HYGIENE (analyzer-evidence only): post-delete `flutter analyze` proved
exactly one new unused import — `../design/app_theme.dart` in
`prox_motion.dart` (`proxTabular` left with the deleted class; `ProxMotion`
/`ProxDurations`/`ProxCurves` all resolve via `tokens.dart`) — REMOVED.
Re-ran analyze: clean except the pre-existing
`welcome_screen.dart:52 info` (`curly_braces_in_flow_control_structures`,
task cited it as :53 — same issue, line shifted). No other unused imports
tree-wide; nothing else removed on guesswork.

KEPT WITH REASON: `role_sections.dart:270` `waits out the week`
(lost-phone paragraph) — same week/month family but OUTSIDE the cited
`:257-258` lines and the two-correction budget, so left untouched and
flagged here as a residual. `pose_gate.dart:5` `3-still flow` comment —
historical note about the old flow, not user copy, untouched.
Orchestration giants + all KEEP-list files/tests untouched (zero test
edits this turn).

DEVIATION (docs, words-only): audit listed `animated.dart:7` as the only
doc-mention, but `ARCHITECTURE.md:18` also listed `ProxAnimatedCount`
under `prox_motion.dart`. Updated that listing to `ProxFadeSlideIn /
ProxStaggered / ProxSwitcher` so the arch doc does not reference a
deleted class. No code impact.

VERIFY: `flutter analyze` → 1 pre-existing info only
(welcome_screen.dart:52). Full `flutter test` → 470/470 pass
(`All tests passed!`).

## Tester batch 2 close-out (orchestrator, 2026-09-10)
Capture breakup (driver mixin verbatim + letterbox preview, B1–B2), Live courses
refresh-on-tab-select, Account mode-switch (reuses continue machinery) + section
split. Gates run in-tree: analyze 1 pre-existing info, full test 503/503,
web build green.

## Residual copy fix (orchestrator, 2026-09-10)
role_sections.dart lost-phone paragraph said "waits out the week" against the
60-day rule (kStudentLostPhoneStale = 60d, claim.dart:85) — corrected to
"can re-enroll once the lost device has been offline 60 days". No test pinned
the old string; setup suites 35/35 green, analyze clean. Comment-only
"week" mentions (device_identity_screen:7, cloud_sync.dart:17, pose_gate.dart:5)
left as provenance.

## Live courses bug (2026-09-10)

Root cause: `_LiveRootState` (`apps/proximity_app/lib/screens/shells.dart`)
cached `deviceStore.readCourses()` once in `initState` into
`late final _courses`. The shell's `IndexedStack` + per-tab `Navigator`
keeps that state alive and the `Navigator` caches its route, so parent
rebuilds (tab switches) never rebuild `_LiveRoot` — the snapshot stayed
stale forever and Courses-tab registrations (`ProfCoursesScreen._register`
→ `store.addCourse`, same `readCourses` source, no org/sync/mode filter)
never appeared on the Live tab. Proved by failing test first
(`test/live_courses_bug_test.dart`: register → Courses → Live showed no
course; refresh line disabled → 1 fail / enabled → pass).

Fix (presentation/navigation only, `shells.dart` `_LiveRoot` block):
`_ProfShellState` holds `GlobalKey<_LiveRootState>` (`_liveRootKey`),
passes it to `_LiveRoot` (`super.key` added), and `_selectTab(0)`
calls `_liveRootKey.currentState?.refresh()`; `refresh()` re-reads
`readCourses()` under `setState`. Init snapshot, empty-state copy
(`No courses yet — register one in Courses…` + `Go to Courses`), list
rows, and `live/<course>` push are byte-identical — empty state now shows
only when the catalog is truly empty. No hosting-lifecycle, draft,
snapshot, driver, timing, string, or network-semantic change; no touch to
take_attendance/host_driver/tokens/routes/account/mark/setup/records
write paths.

Verify: `flutter analyze` → 1 pre-existing info only
(`welcome_screen.dart:52`); new `test/live_courses_bug_test.dart` 2/2;
live/records/shell suites green; full `flutter test` → all green except
pre-existing `test/enroll_guided_test.dart` load failure (Dart parse
errors at :269-271 from concurrent working-tree edits, untouched by this
fix); suite minus that file → 475/475 pass.

## Account switch + breakup

### Fix 1 — Mode switch (Prof↔Student, both-held roles only)
- NEW `apps/proximity_app/lib/features/account/account_mode_switch.dart`:
  `AccountModeSwitch(acct)` (ConsumerStateful, composed INSIDE both Account
  pages — `shells.dart`, `entry_flow`, routes untouched). Loads the role via
  the EXISTING `entryRoleFor(ref, acct)` with a per-email future cache (same
  rule as the RoleHub), checks per-account scoping
  (`role['email'].lower == acct.email.lower`, same stale-account rule as the
  enrollment sections), and renders iff `roleSet` holds BOTH `prof`+`student`
  — single-role / none / foreign-email cache renders `SizedBox.shrink` (not
  even the `Mode` header). Buttons reuse the RoleHub resume labels verbatim
  (`Continue as Professor` / `Continue as Student`, keys
  `account-continue-prof` / `account-continue-student`, container
  `account-mode-switch`, lastMode-first ordering + `Last used — continues
  where you left off.` line) with the same `_busy`/`_status` wrapper
  (busy spinner, `ProxErrorNote` on `StateError`, `BleLog STATE` on failure).
  Taps CALL `entryContinueWithRole(ref, () => mounted, acct, role, which)` —
  never reimplemented — so switching runs the identical checks as the
  RoleHub continue: relink + prof merge + `entryStampLastMode` + `entryGoto`,
  student binding gate + `touchStudentDevice` heartbeat on the native path,
  web records skip inside the same function. Gate refusal surfaces the
  verbatim `studentClaimMessage` copy and flips nothing. No new role
  semantics, no new copy, no shell-level affordance.
- `account_screen.dart` (thin composer): both pages render
  `AccountModeSwitch(acct)` directly under the header (student: before
  Enrollment; prof: before This device).

### Fix 2 — Breakup (monolith → single-purpose sections)
- Presentational split only, mirroring the setup `*_sections` pattern;
  all gating/scoping logic relocated verbatim (bodies byte-identical,
  private → public renames only). Move map (called out):
  - shared row + store/gate reads + enroll entry/sheet + `enrolledForAccount`
    / `storedForAccount` / linked roll+org + short key → `account_common.dart`
    (`AccountFactRow`, `readAccountEnrollment`, `moveGateForAccount`,
    `openAccountEnrollEntry`, `accountEnrollSheetBody`, `enrolledForAccount`,
    `storedForAccount`, `linkedRollForAccount`, `linkedOrgForAccount`,
    `accountShortKey`)
  - `_HeaderCard` → `account_header.dart` (`AccountHeaderCard`)
  - `_EnrollmentSection`/`_IdRow`/`_FaceIdRow` → `account_enrollment.dart`
    (`AccountEnrollmentSection`, `AccountIdRow`, `AccountFaceIdRow`)
  - `_DeviceSection` (+ `_moveStatus`) → `account_device.dart`
    (`AccountDeviceSection`)
  - `_ThemeRow` → `account_theme.dart` (`AccountThemeRow`)
  - system-log + sign-out footer rows → `account_system.dart`
    (`AccountSystemLogRow`, `AccountSignOutButton`)
  - `_ProfDeviceFacts` → `account_prof.dart` (`AccountProfDeviceFacts`)
  - `account_screen.dart` keeps ONLY `StudentAccountScreen` +
    `ProfAccountScreen` composition (signed-out → Welcome branch + `ProxScreen`
    column order/headers/copy unchanged) + move-map header comment.
- Re-enroll gating (`enrolledForAccount` drives every CTA; enrolled ⇒ zero
  entries) and per-account scoping (`storedForAccount`/linked scoping +
  shell Gmail-keyed remount, untouched) preserved behavior-identical.

### Files
- `apps/proximity_app/lib/features/account/account_common.dart` (new),
  `account_header.dart` (new), `account_enrollment.dart` (new),
  `account_device.dart` (new), `account_theme.dart` (new),
  `account_system.dart` (new), `account_prof.dart` (new),
  `account_mode_switch.dart` (new), `account_screen.dart` (thin composer).
- `apps/proximity_app/test/account_switch_test.dart` (new, 18 tests).
- Owned tests only; `shells.dart`, `entry_flow`, routes, all sibling areas
  untouched. Existing `account_screen/fixes/photo` suites unmodified.

### Evidence
- Switch renders iff both held: both-roles student page + prof page show
  `account-mode-switch` + both continue buttons + last-used line; single
  prof / single student / none / foreign-email cache show no switch, no
  buttons, no continue labels.
- Continue machinery: prof tap flips `appModeProvider` unset→prof + stamps
  store `lastMode=prof`; student tap on `sameDevice` flips unset→student +
  stamps `lastMode=student` + heartbeats (`lastSeenAtMillis` non-decreasing);
  student tap on `cooldownBlocked` shows verbatim `You can re-enroll this
  device on…` and leaves mode unset.
- Sections standalone: header / enrollment-entry+org / id-row roll /
  face-id row / device model / theme control / log+sign-out / prof facts /
  mode-switch each pump standalone green.
- Prior fixes preserved: `account_screen` (13) + `account_fixes` (6) +
  `account_photo` (15) suites pass unmodified.

### Verification (exact results)
- `flutter analyze` (full app) — 1 pre-existing info only
  (`welcome_screen.dart:52`); `flutter analyze lib/features/account
  test/account_switch_test.dart` — No issues found.
- `flutter test test/account_switch_test.dart` — 18/18 pass.
- Account suites (`account_screen` + `account_fixes` + `account_photo` +
  `account_switch`) — 52/52 pass.
- Full `flutter test` — all green except pre-existing
  `test/enroll_guided_test.dart` load failure (Dart parse errors at :269-271
  from concurrent working-tree edits, untouched by this task); suite minus
  that file → 475/475 pass (matches the Live-courses entry's 475/475).

### Deviations
- None in behavior/copy/network/timing/thresholds (Appendix A untouched).
  Mode-switch button styling reuses the RoleHub `ProxPrimaryButton` (first,
  last-used) + `ProxSecondaryButton` (second, expanded) pairing rather than
  inventing an Account-specific switcher — layout reuse, not a semantic
  change. `ProxSectionHeader(title: 'Mode')` is a new header but uses the
  existing section-header vocabulary (no frozen string altered).

## Enroll capture breakup (2026-09-10)

Two tester-verified defects in `lib/features/setup/enroll_capture.dart`
(699-line monolith mixing camera-session driver + screen + overlay +
bottom bar): (1) never decomposed — one purpose per page/widget required;
(2) face preview severely squished (cover-fit distortion). Fixed by
mechanical split + letterboxed preview. Presentation + organization ONLY:
5-angle flow, auto-loop timings, retry/burn rules, STEP-SCOPE branches,
records-only blocked card, and all frozen copy byte-identical.

### Split map (mechanical, behavior-identical)
- `lib/features/setup/enroll_capture_session.dart` (NEW, driver owner) —
  camera seam VERBATIM (`EnrollSessionCamera`, `RealEnrollSessionCamera`,
  `FakeEnrollSessionCamera`, `enrollSessionCameraProvider`) + the session
  driver VERBATIM as `mixin EnrollCaptureSessionDriver` (`_openCamera`,
  `_startLoop`, `_stopSweep`, `_autoLoop`, `_captureOne`, `_saveAll`,
  beats `_initialBeat/_frameBeat 600ms`, `_sweepTick 50ms`,
  `_sweepRevolution 4500ms`, buckets, dispose latches, all EnrollLog lines,
  STEP-SCOPE branches). Mixin is `on ConsumerState`, so `ref`/`context`/
  `mounted`/`setState` resolve exactly as on the old State — zero body
  edits. ONLY additions: thin public accessors (`doneCount`, `filledSlots`,
  `nextAngle`, `slotTotal`, `sweepValue`, `previewController`, `isOpening`,
  `isDenied`, `isFailed`, `isSaving`, `retrySave`) + `initCaptureSession`/
  `disposeCaptureSession` (verbatim excerpts of the old initState/dispose
  bodies minus `super`, which stays on the screen). Public getters exist
  because privates are library-scoped — the single documented adaptation.
- `lib/features/setup/enroll_capture_sections.dart` (NEW, one purpose per
  widget, provider-free pure props) — `LetterboxedPreview` (zero-distortion
  surface), `EnrollCapturePreview` (preview region in all states + overlay
  + save-error toast), `EnrollCaptureBottomBar` (Continue / Try-again /
  empty mid-flow), `EnrollCaptureSlotTopUp` (public rename of `_SlotTopUp`,
  build byte-identical), `EnrollCaptureBlocked` (records-only card + Back).
- `lib/features/setup/enroll_capture.dart` (thin composer) — build ONLY:
  `EnrollCaptureScreen` + State `with EnrollCaptureSessionDriver`
  (init/dispose delegate, `_cancel` navigation kept, all frozen copy +
  STEP-SCOPE branches verbatim). Re-exports the session library so existing
  `enrollSessionCameraProvider`/`FakeEnrollSessionCamera` overrides in
  `mark_slimdown_test`/`widget_test`/routes/flow/setup-flow compile
  untouched. Controller, drivers, core, `face_check.dart`, overlay
  component, `setup_flow_screen`, routes, other setup files: untouched.

### Squish root cause + fix
- Root cause: the preview filled its box with `FittedBox(BoxFit.cover)` on
  the controller's aspect ratio — cover CROPs the feed to fill, discarding
  face-area edges whenever the screen ratio differs from the sensor ratio
  (testers read the cropped/distorted feed as "severely squished"); the
  pre-cover chain stretched instead. Both scale-to-fill strategies are
  wrong for a face guide.
- Fix: `LetterboxedPreview` — the ORIGINAL `CameraPreview` sized by an
  `AspectRatio` carrying `controller.value.aspectRatio`, `Center`ed over a
  plain flat bar fill (`ProximityColors.surfaceRaised`, never a gradient).
  No `FittedBox`, no `BoxFit` of any kind (cover/fill/contain/fitWidth/
  fitHeight all banned by test pin): ratio mismatches become letterbox bars,
  never stretch, never cover-crop. Overlay + toast stay pure decoration
  ABOVE the untouched surface; reduced-motion preserved (sweep timer still
  never starts; beacon static at target — driver + CaptureOverlay untouched).

### Tests
- New `test/enroll_capture_breakup_test.dart` (11): geometric ratio proof
  both orientations (child rect keeps 3:4 in an 800x400 box and 4:3 in a
  400x800 box, flat token bars, no FittedBox), no-distortion source pin,
  driver-identifier + screen-owns-build-only pins, relocated-driver smoke
  (open 1, sections render, Cancel pops, close 1), bottom-bar single-variant
  pins (Continue / Try-again / saving-disabled / mid-flow empty), top-up
  hidden-size pin, preview layering + fail-branch pins, blocked-card pin.
- Updated `test/enroll_guided_test.dart` parity group ONLY (2 tests): old
  cover-fit verbatim pins replaced by split-home pins (driver order in
  session file, letterbox chain in sections file, composer order in screen
  file, cover→letterbox delta flips incl. `BoxFit.fill/contain` bans).
- Unmodified where possible: `enroll_beacon_boundary_test.dart`,
  `overlay_redesign_test.dart`, and all 40+ session/widget tests
  (overlay-only, ancestor-chain, buckets-fill, blank-silent, Try-again,
  cancel-dispose, hanging-gate, open-failure, blocked, recapture) pass
  untouched — the letterbox `Center`/`AspectRatio` live in the preview-fill
  sibling subtree, never in the overlay's ancestor path, so the no-Center/
  no-constraining ancestor pins still hold.
- Evidence: `flutter analyze` — 1 pre-existing info only
  (`welcome_screen.dart:52`, untouched). `flutter test` full suite —
  503/503 pass (`All tests passed!`).

### Deviations
- B1 (intended by brief): cover-fit retired for letterbox — the overlay-
  redesign entry's OVD-2 rationale (cover-fit makes area constancy
  unnecessary) is superseded for the FACE AREA: cover crops it, so bars win
  over fill. Overlay contract (three elements, prompt, toast, timings) kept.
- B2 (mechanical): `_SlotTopUp` → public `EnrollCaptureSlotTopUp`
  (library-boundary rename, build identical); driver privates exposed via
  thin public getters; `_cancel`-family call sites read `doneCount`/
  `slotTotal` (same runtime values, same log string shape). No frozen
  string, timing, threshold, verdict, or network call altered.

## Account mode-switch follow-up

### Root cause
- `AccountModeSwitch` rendered iff the role cache held BOTH roles, so a
  PROF-mode tester holding (likely) only the prof role saw no switch at
  all — there was no path from one mode to the other without first
  visiting the RoleHub. Single-role accounts need the same
  add-the-other-role path the RoleHub already offers, through the same
  checks.

### Fix (owned: `account_mode_switch.dart` + its tests only)
- `account_mode_switch.dart`: the Mode section now always renders once
  roles resolve for an account holding ≥1 role. Held role → existing
  Continue buttons (`entryContinueWithRole`, unchanged, same keys
  `account-continue-prof/student`, lastMode-first + last-used line
  unchanged). MISSING role → Register entry reusing the EXISTING register
  machinery — `entryRegisterStudent` (claim gate inside) /
  `entryRegisterProf` (online requirement inside) with the RoleHub
  prof-name field pattern (`TextField` key `account-prof-name`, seeded
  once from `acct.displayName`, verbatim label/helper), buttons
  `account-register-prof/student` (`ProxSecondaryButton`, expanded) under
  the verbatim `Add the other role on this same sign-in:` line — called,
  never reimplemented; refusal copy verbatim via the shared `_run`
  (`ProxErrorNote` + `BleLog STATE`). Register guards mirror the RoleHub
  add-other-role section: nothing extra on web (`kIsWeb`); no student
  register on records-only desktops (`canUseFace()`). While roles load
  (`waiting` + no data) the section stays `SizedBox.shrink` (no layout
  jump); role-less / foreign-email caches keep today's behavior (hidden).
  Success drops the per-email cached future so the section refetches and
  reflects the new held set / lastMode ordering. `account_screen.dart`
  composition untouched (controller lives in the switch state).
- `account_switch_test.dart`: single-role visibility expectations updated
  to Continue-held + Register-missing (dual-role / loading / role-less /
  foreign-cache pins unchanged); new register group (4 tests).

### Evidence
- Single-role prof sees `account-continue-prof` + `account-register-student`
  (+ add-other-role line), no student Continue / prof Register; single-role
  student sees `account-continue-student` + `account-register-prof` +
  `account-prof-name` field.
- Prof-only Register-as-Student succeeds through the gate in fakes
  (empty cloud → `firstBind`): mode unset→student, store roles contain
  prof+student, `lastMode=student`.
- Student-only Register-as-Professor succeeds: mode unset→prof, store
  prof+student, `lastMode=prof`, `readHostName=Test User` (field value).
- Refusals verbatim, flips nothing: prof-only + cooldown cloud →
  `You can re-enroll this device on…`, store stays prof-only;
  student-only + `available:false` cloud →
  `professor registration needs internet once…`.
- Dual-role unchanged (both Continues + last-used line on both pages).
- Prior fixes preserved: per-account scoping (foreign cache hidden),
  re-enroll gating, header/photo untouched.

### Verification (exact results)
- `flutter analyze lib/features/account test/account_switch_test.dart` —
  No issues found. Full `flutter analyze` — 1 pre-existing info only
  (`welcome_screen.dart:52`).
- `flutter test test/account_switch_test.dart` — 22/22 pass.
- Account suites (`account_screen` 13 + `account_fixes` 6 + `account_photo`
  15 + `account_switch` 22, existing three unmodified) — 56/56 pass.
- Full suite minus pre-existing `test/enroll_guided_test.dart` load
  failure (Dart parse :269-271 from concurrent working-tree edits,
  untouched) — 479/479 pass.

### Deviations
- None in behavior/copy/network/timing/thresholds (Appendix A untouched).
  Single-held Continue renders primary (same as the RoleHub resume and the
  prior dual-role first-button rule) with the missing-role Register as
  secondary — button-weight reuse, not a semantic change.

## Capture preview fidelity (2026-09-10)

Tester-verified defect: the face-capture preview still rendered heavily
squished. The enroll screen had a letterbox fix; the defect persisted
because (a) the mark-side screen was never letterboxed and (b) the shared
overlay still derived its geometry from the full Stack size instead of the
actual video box. Fixed on BOTH capture screens with zero driver/copy/
timing changes (presentation + pure geometry only).

### Root cause per screen
- Enroll (`features/setup/enroll_capture_sections.dart`): the
  `LetterboxedPreview` video surface itself was correct (AspectRatio on
  the controller's own ratio, plain bars — no stretch, no cover-crop).
  But `EnrollCapturePreview` mounted `CaptureOverlay` as a full-Stack
  sibling while the video occupied only the centered letterboxed sub-box,
  and the overlay computed its oval/beacon/prompt from the full Stack
  size (`guideRectFor(size)`). Whenever bars were present (any sensor/
  screen mismatch) the guide drifted off the undistorted feed.
- Mark (`features/mark/face_check.dart`): the "full-bleed preview
  surface" was a flat `Container` inside a `StackFit.expand` Stack with
  no aspect preservation at all — any real frame painted into it would
  stretch to fill (or need cover-crop). Same overlay misalignment as
  enroll, since the overlay also used the full Stack size.

### Diff (owned files only; drivers/controllers/core/routes untouched)
- `lib/widgets/capture_overlay.dart` (geometry only): new optional
  `CaptureOverlay.previewAspectRatio` (null = legacy full-size
  behavior); new pure helpers `previewRectFor(size, aspect)` (largest
  centered aspect rect inside the Stack — the box the letterboxed
  surface actually paints into) and `guideRectForAspect(size, aspect)`
  (same 0.70w x 0.52h fractions applied to that video box);
  `guideRectFor(size)` kept as `guideRectForAspect(size, null)` for
  compatibility; build resolves the oval via `guideRectForAspect(size,
  widget.previewAspectRatio)` so oval/beacon/prompt track the
  undistorted feed. No BoxFit/FittedBox/Transform/filter added.
- `lib/features/setup/enroll_capture_sections.dart` (presentation):
  `EnrollCapturePreview` derives `previewAspect` from the controller's
  own initialized ratio (guarded, null-safe) and forwards it as
  `previewAspectRatio` to the overlay; the `CameraPreview` composition
  is unchanged (plain frame at true aspect, no filters/effects). Stack
  layering unchanged (Positioned.fill preview + non-Positioned overlay
  sibling + saveError-gated toast), so all ancestor/stack pins hold.
- `lib/features/mark/face_check.dart` (presentation): new optional
  `previewAspectRatio` + `preview` params (both default null —
  existing call sites incl. `screens/student_home.dart` compile
  untouched). Known aspect renders the same letterbox as enroll
  (`Container` bars + `Center` + `AspectRatio`, frame with no filters/
  effects/transforms) and forwards the aspect to the overlay; null
  aspect keeps the legacy flat placeholder with zero visual change.
  Signal mapping, Scan fallback, one-line prompt contract unchanged.
- `test/capture_preview_fidelity_test.dart` (new, 20 tests): geometric
  ratio proof at 4 ratios per screen (3:4, 4:3, tall 20:9 in a
  square-ish box, square-ish 1:1 — both orientations covered);
  source pins (no FittedBox/BoxFit.cover/fill/contain/fitWidth/
  fitHeight/scaleDown/Transform.scale and no ColorFiltered/
  ImageFiltered/BackdropFilter/ShaderMask/ColorFilter on either
  preview path + overlay); widget pins (no filter widgets in either
  live subtree; FaceCheckView forwards its aspect to the overlay);
  pure overlay-geometry pins (null == legacy; largest-centered-rect
  math both orientations; oval centered in + fully inside the video
  box at every aspect/size combo; distinct aspects give distinct
  ovals; beacon on the letterboxed perimeter; invalid aspects fall
  back to full size).

### Test evidence
- New `test/capture_preview_fidelity_test.dart` — 20/20 pass.
- Owned-file analyze (`capture_overlay.dart`, `face_check.dart`,
  `enroll_capture_sections.dart`, fidelity test) — No issues found.
- Suites driving the edited code paths — all pass: breakup +
  guided + beacon_boundary + overlay_redesign + shared_components
  87/87; mark_slimdown, track5, browse_banner, identity_surface,
  enroll_account_roll, enrollment_lifecycle, responsive_a11y green
  (combined run 102 pass, sole failure the sibling item below).
- Full `flutter test` — 544 pass, 1 fail. The single failure is
  `widget_test.dart` "enrollment: account pickup → key → face → upload
  → linked", which fails at the Confirm-device → About-to-enroll page
  advance (`About to enroll` copy owned by sibling-modified
  `device_intro_step.dart`, stepper owned by sibling-modified
  `setup_flow_screen.dart`/`setup_step_scope.dart`; `widget_test.dart`
  itself is sibling-modified for the new pagination). None of my
  files executes before that step (my code instantiates only at the
  capture step, line ~568, which the test never reaches), and the
  capture-step suites through my code are all green. Left for the
  setup-flow owner; no frozen copy/timing/threshold touched here.
- Full-tree `flutter analyze` — 1 error + 1 pre-existing info, both
  outside ownership and untouched: `result_sections.dart:271`
  `SetupStep.deviceIntro` undefined getter (sibling in-flight
  pagination work) and the long-standing `welcome_screen.dart:52`
  info. (A `setup_pagination_test` item failed once in a full-suite
  run and passes 18/18 in isolation and on rerun — ordering flake,
  not a code failure.)

### Deviations
- None in behavior/copy/network/timing/thresholds (Appendix A
  untouched). `FaceCheckView` gains two optional params (defaults
  preserve every existing call site); `CaptureOverlay` gains one
  optional param plus two pure helpers (legacy entry points kept).
  `screens/face_capture.dart` (legacy still-capture shell) deliberately
  untouched per file ownership — the mark-side fix lives in the
  phase view + shared overlay contract, which is what both consumers
  render through.

## Capture preview fidelity, hardened — bare surface + comet (2026-09-10)

Follow-up: the tester STILL saw a squished face-check page after the
letterbox pass. Stronger rule applied: the preview surface gets ZERO
treatment — a bare frame as a direct child of a loose, centered Stack —
and EVERYTHING else (oval, comet, prompt, progress, buttons) lives in
the overlay layer above it. Driver/timings/retries/copy byte-identical.

### What was still distorting it (investigation)
- `FaceCheckView` shows a PLACEHOLDER, never a live feed (verified:
  `screens/student_home.dart` `_scanFace` captures exclusively through
  the `stillCapturerProvider` modal, passing this view no controller
  and no frame — it is the sole `FaceCheckView` caller). The placeholder
  itself is flat, but the letterbox machinery around it (and on enroll)
  was the residual distortion source, two ways: (1) any force-fill
  ancestor (`StackFit.expand`, `Positioned.fill`, `FittedBox`/`BoxFit`)
  stretches the frame; (2) subtler — the wrapper carried the RAW sensor
  ratio while the plugin's `CameraPreview` paints the
  ORIENTATION-ADJUSTED ratio (verified in the camera-0.12.1 source:
  `AspectRatio(aspectRatio: landscape ? raw : 1/raw)`), so an outer
  ratio box double-boxes against the plugin internals and re-squishes
  the feed AND the overlay derived from it on portrait phones.
- Fix: delete the wrapper entirely (`LetterboxedPreview` removed).
  `CameraPreview` self-maintains its native aspect internally, so a
  loose, centered Stack lets it letterbox itself with nothing around
  it; the overlay aligns via the DISPLAYED ratio (new pure helper
  below), not the raw one.

### Diff (owned files only; drivers/controllers/core/routes untouched)
- `lib/features/setup/enroll_capture_sections.dart`: `LetterboxedPreview`
  DELETED; new pure `displayedPreviewAspect(CameraValue)` mirroring the
  plugin's orientation precedence (recording > pause > lock > device,
  landscape ? raw : 1/raw) from public fields only; `EnrollCapturePreview`
  renders `CameraPreview(ctl)` BARE as a direct child of
  `Stack(alignment:center, fit:loose)` (test fake → bare undecorated
  spacer), overlay sibling above with the displayed ratio; new optional
  `preview`/`previewAspectRatio` test seams (plugin has no test double).
  Fail/spinner/blocked branches, toast, bottom bar untouched.
- `lib/features/setup/enroll_capture.dart`: header docs only (stale
  wrapper reference → bare-surface contract + comet wording). No code.
- `lib/features/mark/face_check.dart`: wrapper machinery
  (Container/Center/AspectRatio) DELETED; `preview ?? SizedBox.expand()`
  bare as a direct child of the loose, centered Stack; `previewAspectRatio`
  still forwarded when known, `preview` still accepted for a future live
  feed. Signal mapping, Scan fallback, one-line prompt unchanged.
- `lib/widgets/capture_overlay.dart` (geometry + beacon paint only):
  the beacon DOT is now a COMET — same bright head dot + halo + tone,
  plus a short fading tail (arc ending at the head, opposite the
  increasing-angle travel direction): `cometTailSpan 0.55` travelling /
  `cometMinTailSpan 0.22` static, `cometSlices 8`, pure
  `cometTailAlphas()` (quadratic tip-0 → head-1 ramp); build resolves
  `sweeping` once and passes the span to the painter; `shouldRepaint`
  covers it. Target-direction semantics, pulse timing, signal colors,
  three-element layout, one-line prompt all unchanged.
- Tests (in ownership): rewrote `test/capture_preview_fidelity_test.dart`
  (22: displayed-ratio precedence ×5, bare-surface direct-child + zero-
  treatment pins both screens, native aspect at 3:4/4:3/20:9/1:1 both
  screens geometrically, comet alphas/spans/tail-behind-head/source-pin/
  travelling+static render, overlay-from-video-box geometry); updated
  stale structural pins to the new contract in
  `enroll_capture_breakup_test.dart` (bare-frame geometry + direct-child
  + source pin, dropped tokens import), `enroll_guided_test.dart`
  (parity group: bare-surface chain order, code-only distortion pins,
  loose+centered ancestor chain), `overlay_redesign_test.dart` (loose
  finders), `enroll_beacon_boundary_test.dart` (loose finder, zero
  Positioned mid-flow, comment provenance).

### Test evidence
- New fidelity suite — 22/22 pass.
- Capture/overlay suites — 110/110
  (`capture_preview_fidelity`, `enroll_capture_breakup`,
  `enroll_guided`, `enroll_beacon_boundary`, `overlay_redesign`,
  `shared_components`).
- Mark/enrollment support — 90/90 (`mark_slimdown`, `track5_states`,
  `browse_banner`, `identity_surface`, `enroll_account_roll`,
  `enrollment_lifecycle`, `responsive_a11y`, `tint_contrast`).
- Full `flutter test` — 561/561 pass, 0 failures (the prior run's lone
  sibling-owned setup-flow failure is gone — the sibling's pagination
  work has since landed green).
- `flutter analyze` on owned lib files — No issues found. Full-tree
  analyze — 2 issues, both outside ownership and untouched:
  `account_mode_switch.dart:25` unused import (sibling in-flight) and
  the pre-existing `welcome_screen.dart:52` info (the earlier
  `result_sections.dart` deviceIntro error has been fixed by its owner).

### Deviations
- None in behavior/copy/network/timing/thresholds (Appendix A
  untouched). `EnrollCapturePreview` gains two optional test-seam params
  (defaults preserve all existing call sites); `FaceCheckView` keeps its
  prior optional params with wrapper-free rendering; overlay gains
  constants + one pure helper + one painter field (legacy geometry entry
  points kept). `screens/face_capture.dart` still deliberately untouched
  per file ownership. Sibling-owned test files edited ONLY where they
  pinned the retired structure (see list above); no test logic weakened
  — every replaced pin asserts the stricter bare-surface contract.

## Setup pagination (2026-09-10)

Tester-verified defect: the enrollment flow still presented big scrolling
pages — notably the combined Confirm-device + About-to-enroll step (one
long scroll: DeviceIdentityContent + EnrollIntroContent stacked) — instead
of a one-purpose-per-page flow. Fixed by pagination only (presentation +
navigation; step order semantics, start-index computation, gate/refusal
copy, and timings frozen per FEATURE_INVENTORY.md §1–§2 + Appendix A).

### Page map before → after
- BEFORE (5 pages): 0 Sign in (WelcomeScreen) → 1 Pick role
  (RoleHubScreen) → 2 Confirm device + about-to-enroll (combined
  `DeviceIntroStep`, key `setup-combined-scroll`) → 3 Capture face
  (`EnrollCaptureScreen`) → 4 Done (`EnrollResultScreen`).
- AFTER (7 pages): 0 Sign in → 1 Pick role → 2 Confirm device
  (`DeviceConfirmStep`: DeviceIdentityContent + flow-only Continue, key
  `setup-device-scroll`) → 3 About to enroll (`AboutEnrollStep`:
  overview + online-once + one-device explainer only, key
  `setup-about-scroll`) → 4 Account & key (`AccountKeyStep`: Google
  account + ID entry + device key + gated `Continue to face scan`, key
  `setup-account-key-scroll`) → 5 Capture face → 6 Done.
- The old combined page becomes three pages (device facts / explainer /
  inputs) — each ~1/3 of the former scroll. Progress overlay is the same
  component (`SetupProgressOverlay` → `SetupProgressLine` semantics
  unchanged), now counting 7.

### Audit of every setup step (why each stays or splits)
- Welcome: STAYS one page (sign in is the single purpose; hero is
  context, secondary professor prose already collapsed behind
  DetailsExpander; conditional web branch unchanged).
- Role: STAYS one page (pick/continue role is the single purpose;
  register vs resume are conditional branches, never stacked; secondary
  prose already collapsed; footer is navigation, not a purpose).
- DeviceIdentityContent → Confirm device page (which account / which
  device / move status + sign-out, reused verbatim; only a flow-only
  Continue added — the combined step previously advanced via the intro's
  Continue).
- EnrollIntroContent → About page (overview + online + one-device,
  explainer only, always-enabled Continue) + Account & key page (account
  + key + the same hasKey-gated `Continue to face scan` with identical
  copy/log line). The standalone `EnrollIntroScreen`/`EnrollIntroContent`
  and `DeviceIdentityScreen`/`DeviceIdentityContent` are untouched for
  deep-links; the new steps are flow-only.
- Capture: STAYS one page (untouched `enroll_capture*.dart` per
  ownership; lazy mount `_seenCapture`, STEP-SCOPE branches, driver,
  timings byte-identical).
- Result: STAYS one page (untouched layout; only the roll-refusal
  `Back to account step` retargets `deviceIntro` → `accountKey`, where
  the ID field now lives; re-scan still targets capture via constant).

### Diff (owned files only; controller/entry_flow/routes/shells untouched)
- `lib/features/setup/setup_step_scope.dart`: `SetupStep` 5 → 7
  (welcome 0, role 1, device 2, about 3, accountKey 4, capture 5,
  result 6, count 7; `deviceIntro` removed). No API shape change.
- `lib/features/setup/device_intro_step.dart`: combined `DeviceIntroStep`
  replaced by `DeviceConfirmStep` / `AboutEnrollStep` / `AccountKeyStep`
  (each own AdaptiveScaffold + scroll + maxWidth 460; sections reused,
  no copy/timing/gate changes; records-only branches mirror the
  standalone intro's blocked card + Back).
- `lib/screens/setup_flow_screen.dart`: header map + `_page` for the 7
  pages; `setupStartIndex` logic identical (no-key → device 2,
  hasKey → capture, faceDone/uploaded → result — capture/result numbers
  shift 3→5 / 4→6, conditions unchanged); listeners, `_seenCapture`,
  `_next`/`_back` (one page), PopScope, overlay wiring untouched.
- `lib/features/setup/result_sections.dart` (2 lines): roll-refusal
  `goTo(deviceIntro)` → `goTo(accountKey)` + comment.
- Tests: new `test/setup_pagination_test.dart` (18); updated
  `test/setup_shell_gate_test.dart` (mapping asserts use `SetupStep`
  constants) and `test/widget_test.dart` (enrollment journey walks
  device → about → account&key → capture → result with per-page scroll
  keys).

### Test evidence
- New `test/setup_pagination_test.dart` — 18/18 pass (map order/count;
  start-index semantics for all 6 entry states; 7 single-purpose render
  pins incl. capture overlay + result status isolation; forward-one-page
  device → about; system-back about → device via `handlePopRoute`;
  progress 1/7 on welcome and 3/7 on device with count 7).
- Setup/entry suites (`setup_shell_gate`, `setup_bundle_rebuild`,
  `setup_pagination`, `enroll_account_roll`, `device_identity`,
  `entry_relink`, `setup_claim_denial`) — 70/70 pass.
- Journey + capture suites (`widget_test`, `enroll_guided`,
  `enroll_beacon_boundary`, `enroll_capture_breakup`) — 82/82 pass.
- `flutter analyze` (full tree) — 1 pre-existing info only
  (`welcome_screen.dart:52`, untouched, Nav-logged).
- Full `flutter test` — 545/545 pass, 0 failures.

### Deviations
- None in behavior/copy/network/timing/thresholds (Appendix A
  untouched). New user-visible chrome is two generic `Continue` buttons
  (device → about, about → account&key) reusing the existing
  `ProxPrimaryButton` + `Continue` vocabulary — pagination affordance,
  not new copy. `enroll_capture*.dart`, controller, `entry_flow`,
  routes, shells, and all sibling areas untouched.

## About-page removal (2026-09-10)

Product-owner decision: the "About to enroll" instruction page (the
numbered 1-2-3-4 explainer step, `AboutEnrollStep`) is removed from the
SetupFlow completely. Flow-only deletion (presentation + navigation);
gates, guards, capture, result, and refusal copy frozen per
FEATURE_INVENTORY.md Appendix A.

### Page map before → after
- BEFORE (7 pages): 0 Sign in → 1 Pick role → 2 Confirm device →
  3 About to enroll (explainer only) → 4 Account & key → 5 Capture face →
  6 Done.
- AFTER (6 pages): 0 Sign in (`WelcomeScreen`) → 1 Pick role
  (`RoleHubScreen`) → 2 Confirm device (`DeviceConfirmStep`:
  `DeviceIdentityContent` + flow-only Continue, key
  `setup-device-scroll`) → 3 Account & key (`AccountKeyStep`: Google
  account + ID entry + device key + gated `Continue to face scan`, key
  `setup-account-key-scroll`) → 4 Capture face (`EnrollCaptureScreen`,
  lazy mount unchanged) → 5 Done (`EnrollResultScreen`).
- Progress overlay is the same component (`SetupProgressOverlay` →
  `SetupProgressLine` semantics unchanged), now counting 6.
- Start-index conditions unchanged (first incomplete page wins):
  signed-out → welcome 0; no student role → role 1; no key → device 2;
  has key → capture (now 4); faceDone/uploaded → result (now 5).
  Device-confirm Continue advances exactly one page (now device →
  account&key via unchanged `scope.next()`); system back moves exactly
  one page (now account&key → device).

### Shared-content verdict (intro_sections.dart: ZERO deletions)
- `IntroOverviewSection` / `IntroOnlineSection` / `IntroOneDeviceSection`
  are still referenced by the standalone deep-linkable
  `EnrollIntroContent` (`lib/features/setup/enroll_intro.dart:128-132`),
  which keeps rendering all five sections (overview + online + one-device
  + account + key) — grep-proven live, so the file is untouched.
- Only `AboutEnrollStep` (flow-only, `device_intro_step.dart`) became
  unreferenced: post-removal grep for `AboutEnrollStep|SetupStep.about|
  setup-about-scroll` across `lib/` returns zero code hits (one
  explanatory comment only). No section deleted.

### Diff (owned files only; controller/entry_flow/routes/shells untouched)
- `lib/features/setup/setup_step_scope.dart`: `about = 3` removed;
  `accountKey` 4→3, `capture` 5→4, `result` 6→5, `count` 7→6; doc
  revised. All consumers reference constants, so no other lib change
  needed (`result_sections.dart` `goTo(accountKey/capture)` untouched).
- `lib/screens/setup_flow_screen.dart`: header map rewritten (6 pages +
  removal note); `case SetupStep.about` branch deleted.
  `setupStartIndex` logic byte-identical; listeners, `_seenCapture`,
  `_next`/`_back`, PopScope, overlay wiring untouched.
- `lib/features/setup/device_intro_step.dart`: `AboutEnrollStep` class
  deleted; header + `DeviceConfirmStep` comment retargeted (Continue to
  account & key). No import changes (every import still used by
  `AccountKeyStep`). `DeviceConfirmStep` / `AccountKeyStep` bodies
  byte-identical.
- `lib/features/setup/intro_sections.dart`: untouched (see verdict).
- Tests: `test/setup_pagination_test.dart` re-pinned (map 6, no about
  render test, device → account&key forward, account&key → device system
  back, progress 1/6 + 3/6); `test/widget_test.dart` journey walks
  device → account&key → capture → result (about scroll/asserts
  removed); `test/setup_shell_gate_test.dart` needed no edit (asserts
  via `SetupStep` constants); `test/setup_bundle_rebuild_test.dart`
  needed no edit (standalone intro five-section pins unchanged).

### Test evidence
- `flutter analyze` (8 owned files: flow screen, step scope,
  device_intro_step, intro_sections, pagination/gate/bundle/widget
  tests) — No issues found.
- `test/setup_pagination_test.dart` + `setup_shell_gate_test` +
  `setup_bundle_rebuild_test` — 41/41 pass (map order/count 6;
  start-index for all 6 entry states; device + account&key + role +
  welcome + capture + result single-purpose pins; forward-one-page
  device → account&key; system-back account&key → device;
  progress 1/6 + 3/6; standalone intro five sections + angle/wifi
  collapse intact).
- `test/widget_test.dart` — 29/29 pass (journey: register → Confirm
  device → Continue → Account & key → ID + key → face scan → capture →
  Save → linked).
- Enroll/entry adjacents (`enroll_account_roll`, `device_identity`,
  `entry_relink`, `setup_claim_denial`, `enroll_guided`,
  `enroll_capture_breakup`) — 68/68 pass.
- Full `flutter test` — +561, All tests passed.
- Full-tree `flutter analyze` lists 5 items, all outside ownership and
  untouched: 2 errors + 1 warning in sibling in-flight `features/
  account/account_enrollment*.dart` + `account_screen.dart:144`, and the
  pre-existing `welcome_screen.dart:52` info. A transient mid-run load
  failure citing the sibling `account_enrollment.dart` (same class as the
  prior-logged transient mid-write read) cleared on rerun with zero
  owned-file changes; final full suite is green.

### Deviations
- None in behavior/copy/network/timing/thresholds (Appendix A
  untouched). One user-visible page fewer (the removed explainer); the
  remaining device Continue button keeps its existing `Continue`
  vocabulary — now one hop instead of two. `enroll_capture*`,
  controller, `entry_flow`, routes, shells, `account/`, `mark/`,
  `live/`, `records/`, `widgets/`, `core` untouched.

## Account overhaul
- Scope: `features/account/*` + one new `CloudSync` method (+ fake +
  firestore impls) + minimal `core/enrollment` local-roll path + tests.
  Untouched as required: shells, routes, `entry_flow`,
  `take_attendance`, `setup/`, `mark/`, `live/`, `records/`, `widgets/`,
  tokens. `claim.dart`'s `cloudRulesHint`/`isRulesDenialMessage` helpers
  are reused as-is (pre-existing worktree change, not authored here).
- 1. SUBMENUS: Account root is now a compact menu — header chip + Mode
  tabs + plain rows (`Enrollment >`, `Device >`, `Appearance >`,
  `Face ID >`, `System log >`) + separated sign-out. Existing sections
  moved one level down verbatim in behavior (same widgets, gating,
  scoping, photo, refusal copy): enrollment+ID →
  `account_enrollment_page.dart`, device → `account_device_page.dart`,
  theme → `account_appearance_page.dart`, Face ID keeps the existing
  screen (student+enrolled only), log keeps the existing debug/log.
  Compactness follow-up applied and pinned: no explainer cards,
  embedded sections, or long prose on the root (only the records-only
  note and the missing-prof name field, both required by preserved
  behavior).
- 2. MODE TABS: `account_mode_switch.dart` replaces the
  Continue-button pairing with a Prof|Student `SegmentedButton`.
  Tapping a held role runs the identical `entryContinueWithRole`
  machinery (gate+stamp+heartbeat, refusal verbatim); tapping a missing
  role starts the existing register flow (`entryRegisterStudent` /
  `entryRegisterProf`, refusal verbatim). Current mode selected
  (live `appMode`, else `lastMode`, else single held role). No new
  role semantics.
- 3. ID EDIT (explicitly-requested business addition): `AccountIdRow`
  is editable with Save. Non-empty validation; uniqueness via the
  existing `searchStudents(rollPrefix:, org:)` scoped to org (exact
  roll held by another Gmail → friendly "already held" copy, no
  overwrite); write via new
  `CloudSync.updateStudentRoll(emailLower:, newRoll:)` (fake +
  firestore; CLIENT-SIDE ONLY — production needs
  `firebase deploy --only firestore:rules --project proximity-attendence`,
  noted in code comments; permission-denied → shared deploy hint,
  never raw text); success updates the local enrollment roll
  (`EnrollmentController.updateLocalRoll` — minimal called-out
  controller addition: rewrites only `roll`, keys/face/install/org/
  stamps untouched) + linked identity; historical session rolls/names
  untouched by design.
- 4. DEVICE FACTS + TRUST HONESTY: Device sub-page shows Device ID
  (abbreviated fact + full `SelectableText` + Copy) and the DKey
  fingerprint via the existing `trustPkDFingerprint` helper.
  Tier stays TRUTHFUL (software-backed builds report real NONE, never
  faked FULL); presentation only — bound facts first + a
  plain-language software-key/flagged-fallback note (`account-trust-note`).
  No attestation invented. Prof Device page gains the full install-ID
  line (was abbreviated-only); profs still show no key/trust tier.
- Preserved per prior ## Account entries: per-account scoping
  (enrollment/linked/role-cache all gated on signed-in Gmail),
  re-enroll gating (no enroll CTA while enrolled — now enforced in the
  sub-pages), photo passthrough (`AccountHeaderCard` → `AccountChip` +
  shell icon), switch behavior (per-account futures, hidden while
  loading/role-less/foreign-email).

### Test evidence
- New `test/account_overhaul_test.dart` — 11/11 pass (compact root;
  submenu navigation ×4; tabs both directions + refusal + current-mode
  selected; ID success/collision/rules-denied/empty + history
  untouched; device facts + trust honesty).
- Updated `account_screen_test` (16), `account_switch_test` (22),
  `account_fixes_test` (6) to the menu/tabs structure, behavior pins
  intact — account suites 70/70 pass.
- `flutter analyze` — clean (1 pre-existing info,
  `welcome_screen.dart:52`, untouched).
- Full `flutter test` — 561/561 pass, 0 failures.

### Deviations (product-owner overrides)
- SUBMENUS overrides `PROXIMITY_UI_REDESIGN.md` §5.1 consolidated-page
  direction (single sectioned page) — menu + one-feature pushes instead.
- MODE TABS replaces the Continue-button pairing (prior ## Account
  switch behavior) — same machinery, tab presentation.
- ID EDIT overrides the gap-2 read-only verdict — explicitly requested
  new business logic (new user-visible copy limited to the
  validation/collision/friendly-error strings above; all claim/move/
  refusal verdict strings, timings, thresholds, and verdict/network
  semantics per Appendix A untouched).

## One-button mode switch
- Scope (tester-directed simplification, presentation/navigation only):
  `features/account/account_mode_switch.dart` + its tests
  (`test/account_switch_test.dart` rewritten to the one-button contract;
  `test/account_overhaul_test.dart` mode-tabs group + compact-root pin
  updated to match). Untouched as required: `entry_flow`, shells, routes,
  `account_screen.dart` (composition lines `AccountModeSwitch(acct: acct)`
  stay — same widget, new internals), all other account files/sections.
  Frozen copy-semantics/timings/thresholds/network untouched.
- Mirrored path proof (call-for-call, nothing invented): the mark screen's
  top-right action (`screens/student_home.dart:1318-1322`, same action on
  `features/records/prof_courses_screen.dart:164-168`) is
  `IconButton(icon: switch_account, tooltip: 'Switch mode', onPressed: ()
  => setMode(ref, AppMode.unset))`. The new `AccountModeSwitch` is one
  compact `TextButton.icon` (existing button component — same component as
  the `AccountSignOutButton` footer row in `account_system.dart`) with the
  identical `switch_account` icon + identical `Switch mode` vocabulary (the
  mark action's tooltip, verbatim) running the identical
  `setMode(ref, AppMode.unset)` exit → landing hub.
- Deleted: Prof|Student `SegmentedButton` tabs, held→continue /
  missing→register tap branches, prof-name field, role-fetch/per-account
  future cache, busy/status machinery. No new role semantics, no new copy
  (button only, no prose, no header).
- Handoff: the hub owns acquire/switch checks from here on — landing→hub
  resume covers register + continue for both roles (`entry_flow.dart`,
  read-only context), so role checks live in exactly one place.
  Refusal/gate/enrollment semantics unchanged (all enforced downstream at
  the hub as today).
- Tests: one-button contract — renders for any signed-in account incl.
  single-role (both-held / single-prof / single-student / role-less /
  foreign-email cache all show the single button, zero tabs/segments/
  prof-name); icon+label mirror pin; press from prof/student/unset lands
  on `AppMode.unset`. Hub resume covered by the existing entry tests, not
  here.
- Verification: `flutter analyze` on the touched files — no issues; full
  `flutter analyze` — 1 pre-existing info only
  (`welcome_screen.dart:52`, untouched); `account_switch` + `account_overhaul`
  — 30/30 pass; remaining account suites (`account_screen` + `account_fixes`
  + `account_photo`) — 37/37 pass; full `flutter test` — 558/558 pass.

### Deviations (product-owner overrides)
- ONE-BUTTON MODE SWITCH overrides the ## Account overhaul MODE TABS
  design (Prof|Student segmented tabs + inline register entries) — same
  mode-exit destination, hub-owned acquire/switch from here on.

## Prof zero-intersection

Tester-verified prof-shell duplication bugs, presentation/navigation only
(`features/live/*` + `shells.dart` `_LiveRoot` block + `take_attendance`
composition regions + new tests). Frozen per FEATURE_INVENTORY Appendix A +
§4: hosting lifecycle, drafts/snapshots, decision paths, strings semantics,
timings, thresholds, network — all untouched (verified: `core/`, drivers,
routes, `account/`, `mark/`, `setup/`, `records/`, `widgets/`, tokens
unedited; take orchestration incl. back-intercept/dispose/drafts byte-
identical).

### 1. Zero-intersection map (grep-proven, then fixed)

Live header/controls (`live_session.dart`): LIVE/IDLE + elapsed + counters
+ Start/Stop/Retake/Take another/End + hostLine — had NO date/day (bug 2,
fixed below). No manual entry, no name field (grep: zero `ManualAddForm`,
zero `Your name` in this file).

Live roster (`live_roster.dart` + `LiveRosterScreen`): waiting + present
(intersection) + partial + dup + search (`WaitingListSection`,
`MarkedRosterSection` via `RosterSearchField` + `PresentSection` +
`PartialSection`, `DupFlagSection`, `LiveRosterBody`). Grep: zero
`ManualAddForm`/`ManualInboxView`/`LiveSetupSection`/`Your name` in this
file — already clean per the roster fix, verified again, no edit needed.

Live inbox (`manual_inbox.dart` + `LiveInboxScreen`): requests only
(`ManualInboxView`: `Manual requests (n)` + hold-and-tap +
`Approve N · Reject N · Select all · Cancel`). Grep: zero roster/add/
setup composition in these files — no edit needed.

Live add (`direct_add.dart` + `LiveAddScreen`): entry only (`Direct manual
entry` + unified `ManualAddForm` `direct-` keys + `Add & mark present`).
HOME for manual attendance-taking — kept. Grep: `ManualAddForm(` exactly
2 sites tree-wide after the fix: `direct_add.dart:44` (`direct-`) +
`session_edit_screen.dart:320` (`edit-`, kept with proof below).

Live setup (`live_setup.dart` + `LiveSetupScreen`): name/IP/discovery only
(`Your name (optional, shown to students)` field + serverLine +
`Announcing on <ip> · change` + Details discovery + serverError +
`Starting host…`). HOME for the editable prof display-name field — kept.
Grep: exactly 1 editable prof-name site tree-wide (`live_setup.dart:133`);
`account-prof-name` zero hits in `lib/` (one-button switch removed it);
`Display name` read-only fact only in `account_prof.dart:61` (not a field,
outside ownership — flagged, not removed). `LiveSetupScreen` carries no
name field (note + Back + System log only) — no edit needed.

Live recover (`draft_recovery.dart` + host banner): policy + `Recover old
session?` dialog + `DraftResumedBanner` (resumed/discard). Renders exactly
once on the host when `_resumed` (orchestration `_restoreDraft` untouched);
no duplication with setup — no edit needed.

Courses (read-only reference, verified not touched): picker
(`ProfCoursesScreen`: `My courses`, `Register new course`, `Host:` line,
`N sessions · lastDate` rows → overview) + overview (`people · sessions`,
`Review & export`, session rows via `sessionTightLabel`/`sessionRoomyLine`
+ `Partial (n)`, rename/delete) + detail (`fullDateOf` header, `Fix
marks`, `Export CSV`) + edit (`SessionEditScreen`: per-round checkboxes +
`Partial/Absent Mark present` + `Add person` `edit-` + `Save changes`) +
export (per-session CSV + matrix). Negative grep
`Take attendance|Retake|Take another|LIVE now|Go live|Hosting|hosting`
over `features/records/` → ZERO hits (records-only confirmed).

Account menu (read-only reference, verified not touched): compact menu
roots (header + one-button `Switch mode` + Enrollment/Device/Appearance/
Face ID/System log rows + sign-out) + sub-pages. No course lists, no
hosting, no manual entry — no overlap with Live/Courses.

Session-edit `Add person` verdict: KEPT as correction-scoped (not a second
attendance-taking home). Proof (grep + test, no records/ edit):
distinct copy (`Add person` vs `Direct manual entry`, each exactly once);
distinct keys (`edit-` vs `direct-`); distinct submit (`_add` local
`_windows/_names/_rolls` setState vs `_addDirectEntry`
`driver.addManualEntry` + draft + snapshot); distinct present-check
(local `_isPresent` over saved windows vs live `tally.confirmed`);
distinct context (per-round checkboxes + `Partial/Absent Mark present` +
`Save changes` + monotonic stamp vs live Start/Stop/Retake controls).

### 2. Live header date (bug: no date/day)

`features/live/live_session.dart` only: new imports (frozen helpers,
read-only sources — `widgets/clock.dart` for `fullDateOf`,
`core/sync/store/record_helpers.dart` for `todayIso`) + one caption line
`fullDateOf(todayIso())` under `PresentTicker` (same helper + format as
the session detail/roomy lines, so Live matches Courses). Shows today
(current hosting date). Pure display — no lifecycle/draft/timing change.
Header stays props-only otherwise (denominator rule, elapsed, controls
byte-identical).

### 3. Tab differentiation (bug: all prof tabs show the same thing)

`shells.dart` `_LiveRoot` block only: rows were bare `ListTile(title +
chevron)` — same silhouette as the Courses picker cards. Now host entry
only: leading `radio_outlined` (vs Courses folder icon) + title (unchanged,
still `Text(name)` so existing taps/logs/routes hold) + subtitle `Tap to
host live session` + trailing `Host` + play arrow (vs Courses `N sessions
· lastDate` + Register/sync/management). Push + `NAV live root → host`
log + `ProxRoutes.live(name)` route unchanged. Negative greps after the
fix: `Register|Rename|Delete course|Delete sessions|Review & export|
Export CSV|sessions ·|people ·` over `shells.dart` → ZERO (no management
on Live); hosting-affordance grep over `features/records/` → ZERO (no
hosting on Courses). New copy (`Tap to host live session`, `Host`) is the
spec-mandated host-action differentiation — called out in Deviations.

### 4. Take-scroll (single scroll kept, each section once, no cross)

`screens/take_attendance.dart` COMPOSITION regions only (orchestration
byte-identical — timers/drafts/dispose/back-intercept/`_leave`/
`_endAttendance`/`_start`/`_closeWindow`/`_saveSnapshot`/`_approveOne`/
`_rejectOne`/`_decideSelected`/`_addDirectEntry`/`_resolveDup`/`_selectSection`
untouched; verified by diff):
- REMOVED the take-scroll extra manual entry: `_openAddSheet` method
  (sheet `ManualAddForm` `sheet-` keys + `showProxSheet` + `take → add
  sheet` log) + AppBar `person_add`/`Add student` `IconButton` deleted.
  Manual entry now lives ONLY in the Add section (`DirectAddSection`,
  `direct-` keys, same `_addDirectEntry` submit path kept for it).
- REMOVED now-unused imports `features/manual_attendance/
  manual_attendance.dart` (`ManualAddForm` only used by the sheet) +
  `widgets/fallback_button.dart` (`showProxSheet` only used by the sheet).
- KEPT the single-scroll order split around the inbox on purpose
  (setup → waiting → inbox → add → dup → marked): grouping the roster via
  `LiveRosterBody` here was probed and reverted — it pushes the inbox
  below the first-build cache range and breaks the approve flow (same
  class as the a11y 560-wrap revert). The dedicated roster screen keeps
  using `LiveRosterBody`; the host composes the same pieces directly with
  identical wiring (`waitingRows`, `dupGroups`/`nameMap`/`_resolveDup`,
  `tally`, `manualPending`/`_approveOne`/`_rejectOne`/`_decideSelected`,
  `course`/`sessionId`/`_addDirectEntry`/`isPresent`). Each widget exactly
  once; roster files contain no inbox/add, inbox/add contain no roster.
- Comment-only: layout-contract header + zero-intersection notes updated
  (no code beyond the composition lines above).

### Tests

New `test/prof_zero_intersection_test.dart` (9 tests, duplication guards
asserting absence per section — all pass):
header today date (`fullDateOf(todayIso())`); roster path roster-only + no
manual/setup; inbox requests-only + no roster/add/setup; add entry-only +
no roster/inbox/setup; setup name-home + setup screen has no field; take
host each-section-once + no sheet extra (drag-until-found helper for the
lazy ListView cache range) + header date; Live rows host-only vs Courses
rows records-only (via `ProfShell`: Live shows `Host` + `Tap to host`,
no management; Courses shows `Register new course` + `sessions ·`, no
hosting); session-edit correction-scoped proof (`Add person` + `edit-` +
`Partial` + `Save changes`, no live copy/controls); `account-prof-name`
zero-lib-hits pin.
- `flutter analyze` — 1 pre-existing info only
  (`welcome_screen.dart:52`, untouched).
- Targeted suites (`live_roster_fix`, `live_sections`,
  `live_manual_attendance`, `manual_add`, `recover_policy`, `dup_flag`,
  `course`, `records_rebuild`, `course_attendance`, `live_courses_bug`,
  `take_back_intercept`, `responsive_a11y`, `widget_test`,
  `prof_zero_intersection`) — 101/101 pass.
- Full `flutter test` — 567/567 pass.

### Deviations (all called out)

- ZI-D1 (new copy, tester-mandated): Live rows add `Tap to host live
  session` + `Host` host-action copy (no frozen string altered — Courses
  copy, verdict vocabulary, timings, thresholds, network untouched).
- ZI-D2 (test-only): `widget_test.dart` prof-approve flow gains
  drag-until-found loops around the inbox header asserts (the header date
  line adds one caption of height, moving the inbox header below the
  first-build cache range on the 800px surface — same lazy-list class as
  the a11y revert; no lib behavior change, no frozen copy touched).
- ZI-D3 (revert with probe evidence): roster grouping via `LiveRosterBody`
  on the take host reverted to the split order (waiting above + dup/marked
  below keeps the inbox near the top for mid-class approvals; grouping
  pushed the inbox out of cache and broke the approve flow with zero
  exceptions — probed via drag steps). Dedicated roster screen still uses
  `LiveRosterBody`; wiring identical in both places.
- Outside ownership, flagged not fixed: `AccountProfDeviceFacts` `Display
  name` read-only fact (not an editable field) and any future account-side
  prof-name input live in `account/` (read-only per brief) — the editable
  field's single home is Live>Setup; session-edit `Add person` lives in
  `records/` (read-only) and is kept per the correction-scope proof above.

## Account content fixes

- Scope: `features/account/*` only + account tests. Touched nothing outside `features/account/` — `face_check`/`enroll_capture`/`overlay`, `entry_flow`, `mark/`, `setup/`, `live/`, `records/`, shells, routes, `widgets/`, tokens, core untouched (core `claim.dart`/`cloud_sync`/`device_store` read-only via existing import patterns; no core edits).
- Correction applied: DELETED the invented `lib/features/account/account_rules.dart` entirely (was created mid-task as a shared rules file). Face-capture rules now live INLINE in the student account's face-id section (`face_id_screen.dart::_FaceRescanRules`); device/binding rules + days/why live INLINE in the enrollment sub-page (`account_enrollment_page.dart::_EnrollmentDeviceRules`); days/why note inline in the Device page (`account_device_page.dart::_DeviceDaysWhy`). Grep-prove: zero refs to `account_rules`/`AccountFaceRulesCard`/`AccountDeviceRulesCard` in tree.
- Face-ID page rules (`face_id_screen.dart`, text-only, never any thumbnail/preview — no Image/avatar/gallery, comments pin principle 6): 5 angles from `faceEnrollSlots` (`Capture ${length} angles: centre · left · right · up · down`, key `face-rules-angles`), good light, hold still, one face in frame, look at camera, `kFaceMaxRetries` instant retries on unclear scans (`face-rules-retries`, unclear burns nothing), wrong-face burns one of `kFaceMaxSessions` attempts (`face-rules-burn`). Crucial highlight (`face-rules-important`) = good-light + hold-still + look-at-camera in a token-only "Most important" callout (surfaceRaised fill + accentBrand border + cardSpecRadius, ProxSpacing padding). Justification: these three are the verbatim actionable phrases repeated in every capture-failure copy (`recapture in good light, holding still`, `hold still in good light`, `look at the camera`/face-position prompt) — the in-the-moment behaviours deciding whether a scan reads at all; angle count/retries/burn are outcome bookkeeping. Alternates (one-face, 5-angles) are setup, not moment-to-moment.
- Enrollment page rules (inline, presentation only): one phone one enrollment incl. clones (`device-rules-one`), 30-day moves (`device-rules-30`, `once every ${kStudentMoveCooldown.inDays} days`), EXACT re-enroll/next-eligible date where gate data already available (`device-rules-next-date` from `verdict.retryAfter` via `dateIsoOf`), reinstall/app-data-clear to switch identity, manual attendance meanwhile, 60-day lost-phone window (`device-rules-60`, `${kStudentLostPhoneStale.inDays} days`) with computable lastSeen→eligible dates (`device-rules-lost-date`), whys (`device-rules-why-one`: one phone marking for many students; `device-rules-why-shared`: shared-device fraud). Non-ok verdicts render `studentClaimMessage` verbatim (`device-rules-refusal`) — never paraphrased. Durations derive from `kStudentMoveCooldown`/`kStudentLostPhoneStale`, never invented; dates from the already-available `StudentGate`.
- Device page: keeps frozen `_moveStatus` verdict rows untouched; adds inline `_DeviceDaysWhy` (30-day move limit + 60-day lost-phone window + both whys, keys `device-days-line`/`device-why-one`/`device-why-shared`).
- Appearance inline: theme selector moved to END of both Account roots (student + prof) above sign-out (`ProxSectionHeader Appearance` + `AccountThemeRow` with section gaps); appearance sub-page/row deleted (`account_appearance_page.dart` removed). Grep-prove: zero file/class/route refs (`AccountAppearancePage`/`account_appearance_page`/`account/appearance`); only `account-row-appearance` negative asserts (`findsNothing`) remain in tests by design.
- Spacing: generous `ProxSpacing` pass, no square/flat regressions (all cards keep `cardSpecRadius`/divider borders, no `BorderRadius.zero`/`circular(0)`, no raw colors). `AccountFactRow` top `sm→md`, gap `2→xs`; root header breathing room + `sm` row gaps + `md/lg/xl` section gaps; enrollment/device/face-id/prof pages get `sm/md/lg/xl` section gaps + header breathing room; raw `SizedBox(4)`/`(2)` → `ProxSpacing.xs`; `AccountModeSwitch`/`AccountSignOutButton` gain `ProxSpacing` padding + `minTap`; `ProxSpacing` present in all 12 account lib files.
- Sign-out: direct `entrySignOut` kept everywhere; re-sign-in guard dependency DROPPED per product-owner stop (sibling never wrote `confirmSignOutIfEnrolled` — verified zero references in tree). No reference, stub, or reimplementation of the helper. `AccountSignOutButton` pins direct call in a comment.
- Tests: new `test/account_content_fixes_test.dart` (8 tests: face rules + highlight + no preview; enrollment 30/60 + whys + lost-date; cooldown exact date + verbatim refusal; device days/whys; student + prof appearance inline; header radius + spacing; sign-out no-dialog direct). Updated `account_screen_test` + `account_overhaul_test` for inline appearance (row→`findsNothing`, theme control inline `findsOneWidget`) and `ensureVisible` on the 4 ID-edit Save taps (inline rules lengthened the enrollment page, pushing Save below the 600px test viewport — tap missed without scroll; no lib behavior change).
- Verify: `flutter analyze` clean (1 pre-existing info in `welcome_screen.dart` only); new test 8/8 pass; account suites 75/75 pass (`account_screen` + `account_overhaul` + `account_switch` + `account_fixes` + `account_photo` + `account_content_fixes`); full suite 575/575 pass.

## Face-id rescan clarity

- Code-true limit finding (verified in `core/enrollment.dart::restartFace`, lines 754-770): NO rescan limit exists in code. `restartFace` keeps the device key, clears only the in-memory face (`_faceId = null`), best-effort removes the old template via `verifier.remove(old)`, and lands on `keyReady` — no counter, no cap, no cooldown, callable unlimited times. The stored enrollment on disk is untouched until the new capture validates (attendance keeps working meanwhile). `kFaceMaxRetries = 2` / `kFaceMaxSessions = 4` (`packages/protocol/.../constants.dart`) are marking-time verify-session internals (FaceGate live-check budget), NOT rescan limits — so the copy states unlimitedness and never invents a number.
- Scope: `features/account/face_id_screen.dart::_FaceRescanRules` + `test/account_content_fixes_test.dart` face-id group ONLY. Nothing else touched (core, enrollment/device pages, shells, routes, widgets, tokens untouched; status `Enrolled · <verifierVer>` / `Needs re-face`, sync note, sheet copy, refusal wording frozen).
- Fix (presentation copy only, no behavior change): the old technical block (5 angles `faceEnrollSlots` line, `kFaceMaxRetries` retries line, `kFaceMaxSessions` burn line, 3-tip callout) is replaced with a short plain block above the Re-scan button: highlighted crucial line `You can re-scan as many times as you need on this device.` (`face-rules-important` callout styling unchanged: surfaceRaised + accentBrand border + cardSpecRadius, key `face-rules-rescans`), what a re-scan does `A re-scan replaces only your face template — your device key, ID, and enrollment stay the same.` (key `face-rules-what`), one tips line `Tip: use good light on your face and hold still while scanning.` (key `face-rules-tips`). Title is now `About re-scanning` (key `face-rules-title` kept). No angles/retries/burns/session internals in user copy; never any thumbnail/preview (no Image/avatar/gallery — pinned by test). Unused `proximity_protocol` import dropped (no more `faceEnrollSlots`/`kFace*` refs in the screen).
- Tests: `account_content_fixes_test.dart` face-id group rewritten to the plain block — asserts limit statement (`as many times as you need`), what-line (`replaces only your face template` + `device key`), tips (`good light` + `hold still`), `face-id-rescan` button intact, negative asserts (old keys `face-rules-angles/retries/burn` findsNothing; user copy `angles`/`burns`/`retries`/`attempts`/`centre` findsNothing), `Image` findsNothing.
- Verify: `flutter analyze lib/features/account/face_id_screen.dart test/account_content_fixes_test.dart` — No issues found; full `flutter analyze` — 1 pre-existing info only (`welcome_screen.dart:52`); `account_content_fixes_test` 8/8 pass; account suites pass (`account_screen` + `account_fixes` + `account_overhaul` + `account_photo` + `account_switch`); full `flutter test` — 575/575 pass.

## Face-id rescan clarity — scope trim (limit claim held)

- Per scope trim: the block states NO re-scan limit/frequency claim of any kind (no "unlimited", no numbers). The earlier "as many times as you need" line (`face-rules-rescans` key) is removed; the highlighted "Most important" callout now holds the what-it-does line instead (`A re-scan replaces the face template on this phone — your device key, ID, and enrollment stay untouched.`, key `face-rules-what`), followed by the tips line (`face-rules-tips`). Reason held: a pending anti-swap hardening decision will define the re-scan rule right after this work lands, so the copy must not pre-empt it. The code-truth note above (restartFace carries no counter/cap) stands as an internal finding only — it is NOT surfaced in user copy.
- Test pin updated: `face-rules-rescans` findsNothing plus `unlimited` / `as many times` findsNothing negative asserts alongside the existing internals negatives.
- Verify: targeted analyze clean; full analyze 1 pre-existing info only (`welcome_screen.dart:52`); `account_content_fixes_test` 8/8; full `flutter test` 575/575 pass.

## Rescan delta check — reverted

- Product-owner plan change (2026-09-10): the match-plus-better-score delta check is ABANDONED, superseded by the 30-day rescan rule. Implementation stopped mid-task per stop instruction; no delta-check behavior ships.
- Partial work reverted: the single touched file `apps/proximity_app/lib/core/sync/store/store_base.dart` (additive `faceScore` on `StoredEnrollment` + toJson/fromJson) was restored via `git checkout` to its pre-task state — verified zero diff on that file and zero `faceScore`/continuity/staging string remnants anywhere in `lib/` or `test/`. `core/enrollment.dart` was never edited in this session (its working-tree diff is sibling pre-claim-verdict work, confirmed free of delta-check terms); `face_verifier.dart` untouched (pending edit aborted before apply); no test files created or modified. Sibling areas (`account/*`, `setup/*`, `mark/*`, `live/*`) not touched.
- Verification on the reverted tree: `flutter analyze` — 1 pre-existing info only (`welcome_screen.dart:52`); full `flutter test` — 578 pass / 3 fail, all 3 failures in sibling in-flight Take/retake UI flows (`course_test` take-screen professor-name field; `widget_test` take→LIVE→close→end + retake-resumes-round), unrelated to enrollment/device-store/face (no delta-check code remains to cause them).

## 30-day rescan rule

- Rule mechanics (product-owner order): face re-scan is allowed ONCE EVERY 30 DAYS per account. Gate lives on the rescan-SAVE path only — `EnrollmentController.upload()` replacing an existing template. First enrollment never gated (no stored doc, different Gmail, or empty faceId). Started-but-unsaved rescans never stamp (`restartFace`/`enrollFace` touch memory + plugin gallery only). Zero stamp (never rescanned, incl. pre-upgrade docs missing the key) always allowed once, then stamps. Successful rescan save stamps `now`; failed saves return before the write so they never stamp. Per-account: a different Gmail's stamp never blocks this draft. No claim/rules/server change; no threshold/timing/network change (`kFaceThreshold` 0.70, Appendix A timings, claim verdicts untouched); old template handling otherwise byte-identical (same `writeEnrollment` shape + `enrolledAt`, same claim flow).
- Constant choice (logged): `kFaceRescanCooldown = Duration(days: 30)` in `core/sync/claim.dart` beside `kStudentMoveCooldown` but SEPARATE — same 30-day duration today by product choice, distinct declarations so changing one can never change the other (device moves vs face-template replaces). All durations derive from the constant (`inMilliseconds`/`inDays`); no `Duration(days: 30)` or `30 * 24 * 60 * 60 * 1000` literals in new code. Pure helpers in the same file: `faceRescanBlocked(stampMillis:, now:)` (`stamp <= 0` never blocks; `< cooldown` blocks, exact-boundary exclusive), `faceRescanEligibleAt(stamp)` (`stamp + cooldown`, UTC), `faceRescanCooldownMessage(eligible)` (single source of truth, returned verbatim by `upload`).
- Refusal string verbatim (ONE new string; no other strings changed): `You already updated your face scan recently. You can scan again on <YYYY-MM-DD> — face re-scans are allowed once every 30 days. Until then, ask your professor to mark your attendance manually (Request manual attendance in class).` (date via `dateIsoOf(eligible.toUtc())`, count via `kFaceRescanCooldown.inDays`, tail matches the move-cooldown manual-attendance voice). Refusal logs `BleLog FACE face rescan refused (cooldown until <date>)`.
- Diff (ownership: `core/enrollment.dart` + device-store `store_base.dart` + policy constant in `sync/claim.dart` + tests; `account/*`, `setup/*`, `mark/*`, `live/*`, shells, routes, tokens, drivers, claim verdicts untouched): `claim.dart` adds the constant + 3 pure helpers/message (≈60 lines, verdicts byte-identical); `store_base.dart` adds additive `StoredEnrollment.lastFaceRescanAtMillis` (int, default 0) + `lastFaceRescanAt` getter + toJson/fromJson round-trip with `?? 0` migration (memory + secure stores inherit via the JSON doc, no backend-body change); `enrollment.dart` adds the SAVE-path gate (read prev → `isFaceRescan` → refuse verbatim) + `rescanStampMillis` (rescan → now, same-account first-face → preserve, new account/fresh → 0) threaded into `writeEnrollment` + read-only UI accessor `faceRescanBlockedUntil({now})` (null = allowed now; documented as the account-copy follow-up source) + `updateLocalRoll` preserves the stamp. New test `test/face_rescan_cooldown_test.dart` (10 tests).
- UI accessor for the account copy follow-up: `EnrollmentController.faceRescanBlockedUntil({DateTime? now})` → `Future<DateTime?>` (eligible UTC date or null when allowed). Read-only, never stamps.
- Test evidence: new suite 10/10 pass (constant 30d + boundary; schema round-trip + legacy-missing-key defaults 0; first enroll leaves 0; rescan stamps now; within-window refused with EXACT `dateIsoOf` date + manual pointer + disk unchanged + accessor matches; post-window allowed + re-stamps; failed saves — no-face and no-roll — leave stamp/faceId untouched; pre-upgrade zero-stamp allowed once; cross-account stamp never gates). Owned enrollment suites green: rescan + `device_store` + `enrollment_lifecycle` + `enroll_account_roll` + `face_identity` + `face_crash_hardening` + `setup_claim_denial` + `enroll_guided` + `enroll_beacon_boundary` all pass; re-confirmed rescan/device/lifecycle/roll subset 52/52. `flutter analyze` clean except 1 pre-existing info (`welcome_screen.dart:52`). Full `flutter test`: 590 pass / 1 fail — sole failure `widget_test.dart: prof retake resumes the stopped round number` (`pumpAndSettle` timeout in the Take/retake host flow), outside owned files (zero rescan-symbol references in that test; screens/take_attendance + live hosting, sibling mid-flight as briefed — same family as the 3 pre-existing Take/retake failures on the reverted tree).
- Deviations: (1) policy constant lives in `sync/claim.dart` per the brief's "sits nearby but SEPARATE" instruction — counted as a policy-constant addition, not a claim-verdict change (verdicts/rules/server byte-identical); (2) first-face save for the same Gmail preserves (rather than resets) a pre-existing non-zero stamp — conservative anti-evasion choice, only observable in the impossible-unless-tampered empty-faceId-with-stamp state; (3) `enrolledAt` reuses the single `now` captured for the gate/stamp instead of a second `DateTime.now()` — same-millisecond equivalence, keeps gate + stamp + write on one clock read.

## Face-id 30-day rescan rule (copy follow-up)

- Rule landed upstream (`kFaceRescanCooldown = 30 days` + `faceRescanBlocked/faceRescanEligibleAt/faceRescanCooldownMessage` in `core/sync/claim.dart`, `StoredEnrollment.lastFaceRescanAtMillis`, `EnrollmentController.faceRescanBlockedUntil({now})` read-only accessor, SAVE-path gate in `upload`). This entry covers the account-copy follow-up ONLY.
- Scope: `features/account/face_id_screen.dart::_FaceRescanRules` + `test/account_content_fixes_test.dart` face-id group. Core untouched. `_FaceRescanRules` is now a `ConsumerWidget` (was `StatelessWidget`, hence the `const` drop at the call site) with a `FutureBuilder<_FaceRescanInfo>` combining the stored stamp (`deviceStore.readEnrollment().lastFaceRescanAtMillis`) + the documented accessor (`faceRescanBlockedUntil()`); unconditional rows render while loading/failing, dates + refusal appear with the data. New import: `core/sync/claim.dart` (pure-Dart policy source); `dateIsoOf` arrives via the existing `device_store.dart` export.
- Copy (presentation only, no behavior change): highlighted crucial line is the rule (`face-rules-rule`: `Face re-scans are allowed once every ${kFaceRescanCooldown.inDays} days.` — days from the constant, never a literal); kept what-line (`face-rules-what`) + tips (`face-rules-tips`); last-scan date when a stamp exists (`face-rules-last`: `Last face scan: <YYYY-MM-DD>.`); next-eligible date when blocked (`face-rules-next`: `You can scan again on <YYYY-MM-DD>.`); refusal verbatim from `faceRescanCooldownMessage` when blocked (`face-rules-refusal`) — never paraphrased. Null/zero-stamp = rule line only. Text-only, no Image/avatar/gallery; no angles/retries/burns internals; status/sync-note/sheet/refusal wording otherwise frozen.
- Tests: face-id group now 3 tests (rule/what/tips + no-restriction-past-rule; blocked → last + next + verbatim refusal incl. `find.text(faceRescanCooldownMessage(eligible))`; 31-day-old stamp → last date, no refusal/next). `_enrolledStore` gains optional `lastFaceRescanAt` (default 0, existing callers unaffected). Claim helpers reach the test via the existing `cloud_sync.dart` export chain — no import changes.
- Verify: targeted analyze clean; full analyze 1 pre-existing info only (`welcome_screen.dart:52`); `account_content_fixes_test` 10/10; account suites + `face_rescan_cooldown_test` 77/77; full `flutter test` 592 pass / 1 fail — the single failure is `widget_test.dart: prof retake resumes the stopped round number` (`pumpAndSettle` timeout), proven pre-existing and unrelated: it fails identically with this task's screen change stashed, its file carries another session's in-flight edits, and it holds zero references to `FaceIdScreen`/face-rules/rescan copy. Flagged, not fixed (outside ownership).

## Live subtabs + freshness

Tester-verified Live-tab defects (presentation/navigation only). Frozen untouched: hosting lifecycle, drafts/snapshots, decision paths, strings semantics, timings, thresholds, network (Appendix A + §4). Orchestration verified byte-identical as found (timers/drivers/drafts/dispose/back-intercept/`_leave`/`_endAttendance`/`_start`/`_closeWindow`/`_saveSnapshot`/`_approveOne`/`_rejectOne`/`_decideSelected`/`_addDirectEntry`/`_resolveDup` bodies; diff hunks in `take_attendance.dart` are composition-only — the sibling back-intercept `_teardown`/`_leaving`/`_bypass` refactor in the same file predates this task and is preserved verbatim).

### 1. Real sub-tabs (IndexedStack swap, product-owner order)

`screens/take_attendance.dart` COMPOSITION regions only: the single shared-scroll `ListView` (setup → waiting → inbox → add → dup → marked, with scroll-spy `_selectSection` via `ensureVisible`) is replaced by an `IndexedStack` (index `_section`) with four independent `SingleChildScrollView` children — Roster / Inbox / Add / Setup, the explicit product-owner order, overriding scroll-spy. Each sub-tab shows ONLY its view (no shared scroll, no intersection; default offstage-skipping finders see exactly one tab). All tabs stay mounted (state-preserving switch): roster search, mid-approve inbox hold-and-tap selection, and direct-add fields survive switches — this directly answers the reverted grouping probe (grouping broke the approve flow by unmounting; IndexedStack keeps the inbox mounted). Roster tab composes the same `LiveRosterBody` (waiting + dup + marked, identical wiring) as the dedicated roster screen. `_selectSection` is now `setState` only; the four scroll `GlobalKey`s are deleted; `_scrollCtrl` field is RETAINED (unused) because the frozen `dispose()` body still disposes it. M3 `SegmentedButton` chrome unchanged (same labels/roles; `Inbox (N)` count label kept).

### 2. Date visibility (proper header element, IDLE + LIVE)

`features/live/live_session.dart` only: the session date/day line (`fullDateOf(todayIso())` — same frozen helper + format as the records detail/roomy lines, text unchanged so `find.text(fullDateOf(todayIso()))` still resolves) is promoted from an 11px caption to a label-weight header row with a calendar icon, rendered unconditionally — IDLE and LIVE read identically, never absent in either state.

### 3. Post-End freshness (stale-link root cause + reload triggers)

Root cause: `ProfCoursesScreen` and `CourseOverviewScreen` read via `FutureBuilder` futures built inline from `store.readCourses()`/`readHistory()`, but both states live inside the shell `IndexedStack` + per-tab `Navigator`, which caches its route — tab switches never rebuild them, so the futures never re-read and the Courses tab serves its pre-End snapshot (new session missing without restart; same stale-link class as the `_LiveRoot` catalog bug). Fix, triggers only (data/filter/sort/union/rename logic byte-identical): new `features/live/live_refresh.dart` (`liveHistoryTick` ValueNotifier + `bumpLiveHistoryTick()`); the take host bumps it from `build`-level composition wrappers only (`onEnd`/`onStop`/approve/reject/decide/add/BackButton-leave via `whenComplete`, preserving error propagation — bodies untouched); both records screens subscribe in `initState` (listener `setState`s → inline futures re-created → fresh read, even while offstage) and unsubscribe in `dispose`. Verified end→courses shows the new session with no restart.

### Tests

- New `test/live_subtabs_freshness_test.dart` (6 tests, all pass): swap exclusivity per tab (Roster/Inbox/Add/Setup each shows only its view) + 4 mounted scrolls / 1 visible + `IndexedStack` present; state preservation across switches (roster search text via live `EditableText`, mid-approve `Approve 1` selection survives a round-trip — the probe case); date header + calendar icon in IDLE and LIVE; shell-level end→Courses shows `1 sessions` after End (no restart); picker + overview re-read on `bumpLiveHistoryTick`.
- Updated for the new interaction model (test-only, called out below): `prof_zero_intersection_test.dart` take-host test (segment taps replace drag-until-found; per-tab absence asserts); `widget_test.dart` prof approve flow (tap Inbox/Add segments; submit keeps one `scrollUntilVisible` — the Add tab scrolls independently and the button sits below the fold); `widget_test.dart` LIVE→close→end + retake (server line now asserted on the Setup tab); `course_test.dart` name-field (via Setup tab).
- `flutter analyze` clean (1 pre-existing info in untouched `welcome_screen.dart:52`). Targeted live/records suites green (subtabs 6/6, zero-intersection, live_sections, live_roster_fix, live_manual_attendance, manual_add, dup_flag, live_courses_bug, take_back_intercept, recover_policy, records_rebuild, course, course_attendance, widget 29/29, track5, identity_surface). Full `flutter test`: 600/600 pass.

### Deviations (all called out)

- L-D1 (test-only): existing single-scroll tests rewritten for tap-to-swap (files above). No lib behavior change beyond the briefed swap.
- L-D2 (test-only, sibling-precedent): the retake test's post-switch settle uses bounded fixed pumps — a settle still pumping when the live 800ms dot-toggle fires chains opacity flights and never observes idle (pre-existing live-regime constraint, same class as the roster stagger note; proven by instrumentation that settles exit before the first toggle and that chained flights never go quiet). Product code unchanged for this (dot pulse is by-design, documented in `prox_cards.dart`).
- L-D3 (probed and REVERTED, evidence kept): muting sub-nav tickers (`TickerMode`) and per-tab `primary: false` controllers were both probed as hang fixes — neither addresses the toggle-race above (the third-switch hang reproduced WITH `TickerMode`), so both were reverted; the shipped tree keeps the pure M3 sub-nav and shared primary controllers. Debug scratch tests removed (zero `zz_dbg` remnants).
- L-D4 (fixed en passant, same family siblings flagged): `widget_test.dart: prof retake resumes the stopped round number` (`pumpAndSettle` timeout) failed on arrival in this tree (also flagged pre-existing by the face-rescan session) — fixed here by L-D2's bounded pumps + the Setup-tab visit; now green.
- Outside ownership, flagged not fixed: a transient mid-session `tab_slide_test.dart` compile error (`AlwaysStopped`/`_slideDx` in sibling-owned `shells.dart`) observed while a sibling edited mid-run; resolved without my involvement — final full run includes all slide tests green. `shells.dart`, `prox_cards.dart` (beyond temporary reverted instrumentation), drivers, sync engine untouched.

## Tab slide animation

Tester-directed navigation upgrade (presentation/navigation only): bottom-nav tab switches in both shells now animate with a directional slide (WhatsApp-like) instead of the 120ms cross-fade. Frozen untouched: routes/stacks, Mark gate signal + behavior, shell back contract (pop-own-stack, double-back 2s hint/leave), `_LiveRoot`, take_attendance, entry/setup/mark/live/records/account content, drivers, core, badge/avatar rendering, icon-only <360dp rule, all strings/timings/thresholds. Sibling-owned concurrent changes in the same files (account-photo icon, on-tint tokens, live composition) are theirs — mine are the hunks below only.

### Diff (mine only)

- `apps/proximity_app/lib/design/tokens.dart` (additive, 1 const + doc): `ProxDurations.tabSlide = 220ms` (inside the required 200–250ms band). Kept separate from `push` (220ms, route transitions) — tab chrome gets its own named token per the brief. `tabCrossFade` (120ms) frozen in place: it still drives the 4dp `_SettleIcon`. Curve is the existing `ProxCurves.standard` (easeOutCubic) — no new curve token, no magic numbers.
- `apps/proximity_app/lib/screens/shells.dart` (tab-switcher regions only, same pattern both shells): new shared `_TabSlide` StatefulWidget + `_TabSlideState` (SingleTickerProvider) replacing the per-tab `AnimatedOpacity` wrapper in `StudentShell` and `ProfShell`. Fixed build shape in every state (`SlideTransition > AnimatedOpacity > Navigator`, same unkeyed slot): the tab Navigator (same GlobalKeys, same `_tabRoute` roots, same account-keyed roots) never reparents, so stacks + scroll survive exactly as before. Per-shell `_slideSeq`/`_slideDir` state; `_selectTab` bumps seq + sets dir = sign(new − old) on cross-tab taps only (same-tab taps: no animation; gate/refresh calls byte-identical). Restart happens in `didUpdateWidget` via `forward(from: 0)` — the same restart the framework's own implicit animations use there. Tap-triggered only; no swipe gesture, no new routes, no stack/guard/timing changes.
- New `apps/proximity_app/test/tab_slide_test.dart` (7 tests, see below).

### Motion spec

Direction follows tab order (tap right → slide in from right at `Offset(+1, 0)` → rest; tap left mirrors), 220ms `easeOutCubic`, interruptible (each switch restarts from its edge). Reduce-motion (`ProxMotion.reduced`): slide parked at rest, opacities `Duration.zero` — instant opacity, verified with zero mid-flight offset on the first frame after tap.

### Design correction made during work (keep-alive regression, caught by test)

First cut keyed a `TweenAnimationBuilder` by seq (varying build output type per active state). Direction asserts passed but the scroll probe regressed 380px → 0px across a round-trip while the original tree preserved it (verified by stashing: original 380 → 380). Root cause: changing the wrapper type reparents the GlobalKey Navigator and its route content rebuilds/clamps scroll. Reverted to the fixed-shape stateful design above; scroll preservation re-verified at the exact pre-change value. No other behavior was touched to fix this.

### Test evidence

- `test/tab_slide_test.dart` 7/7: token band (200–250ms) + easeOutCubic pin + frozen cross-fade pin; student rightward full-edge start → mid-flight (0, 1) → rest, same-tab no-op, leftward mirror; prof Live→Account (+1) / Account→Live (−1); Courses-tab `CourseOverviewScreen` push survives an Account round-trip (stack); Courses `ScrollPosition.pixels` (380.0) identical after round-trip (scroll); reduced-motion parks all 3 slides, all 3 tab opacities `Duration.zero`, switches land with zero mid-flight offset; unenrolled Mark gate round-trip (flow → Courses → flow) through the new `_selectTab`.
- Regression: `flutter analyze` clean (1 pre-existing info in untouched `welcome_screen.dart:52`); shell/nav suites green (`setup_shell_gate`, `widget_test`, `live_courses_bug`, `account_screen`, `account_photo`, `take_back_intercept` — 77/77); full `flutter test`: 600/600 pass.

### Deviations

- None from the brief. Notes: (1) `_SettleIcon` 4dp settle kept as-is (icon micro-motion, still on frozen `tabCrossFade`; removing it was never required to ship the content slide). (2) Slide is incoming-only (outgoing hides instantly under the IndexedStack) — the cross-slide alternative would duplicate GlobalKey Navigators mid-transition and risk exactly the keep-alive contract the brief hardens; direction, cadence, and curve match the brief either way. (3) Sibling log line above reports observing my mid-write `tab_slide_test.dart`/`shells.dart` states — that was this task's own in-progress tree, final state verified green here.

## Face-check single-shot (2026-09-10)

Tester-directed face-check correction: mark/face is an INSTANT single-shot
check, but it rendered enrollment multi-angle guidance (rotation
instruction + orbiting beacon/comet + angle progress bar — meaningless for
a one-shot verify). Fixed presentation-only. Frozen untouched: auto-scan
timing, retry/burn rules, verdict strings, FaceGate semantics
(FEATURE_INVENTORY.md §3.5 + Appendix A).

### Diff (owned files only; enroll_capture*/drivers/controller/core/other
### mark files/routes/tokens untouched)

- `lib/widgets/capture_overlay.dart` (additive only): new `showProgress`
  + `showBeacon` flags, both default true. `showProgress: false` hides the
  slim top angle-completion bar; `showBeacon: false` hides the travelling
  comet entirely (painter returns after the static oval; `_syncPulse`
  never starts its timer with no beacon to pulse; `shouldRepaint` covers
  the flag). Defaults true render byte-identical, so enroll is unchanged.
- `lib/features/mark/face_check.dart`: new `faceCheckPrompt =
  'Look at the camera.'` (the ONE at-rest line — replaces the rotation
  copy, which never renders here now). Build passes `statusLine:
  faceNotice.isNotEmpty ? faceNotice : faceCheckPrompt` plus
  `showProgress: false, showBeacon: false` — exactly two overlay elements
  (ONE static framing oval + ONE prompt line). Preview surface unchanged
  (same bare native-aspect undistorted treatment as enrollment: frame as a
  DIRECT child of the loose, centered Stack, zero treatment — no
  decoration/effect/fit). `signalForNotice`, `canScan`/`onScan` fallback,
  host-owned zero-tap auto-scan, radio-under-camera composition untouched.
  Retained `totalAngles`/`currentAngle`/`progress` params are API-compat
  only (no visual effect in this mode).
- `test/face_check_single_shot_test.dart` (new, 16): single-shot prompt
  pin (contains look-at-the-camera, no Rotate/beacon/glow; at-rest renders
  it, host notice replaces it); no beacon/rotation/progress pins (no
  LinearProgressIndicator, overlay flags false, CustomPaint oval still
  present, Scan fallback kept, source pin); bare undistorted preview pins
  (placeholder + provided frame are direct Stack children, loose+centered,
  no Container/ColoredBox/DecoratedBox/FittedBox, native aspect 3:4/4:3/
  20:9/1:1, source pin bans fit/decoration/effect/outer-ratio); enroll
  unchanged pins (defaults true, default overlay still bar + rotation
  prompt, source pins for gated beacon/bar, live enroll consumer still bar
  + beacon + `enrollCapturePrompt`, never the single-shot line).
- `test/overlay_redesign_test.dart` (mark/face pins only): at-rest now
  expects `faceCheckPrompt` + no bar + no Rotate/beacon copy; notice test
  also expects no single-shot/rotation copy alongside the notice. Generic
  + enroll pins untouched.

### Test evidence

- New `test/face_check_single_shot_test.dart` — 16/16 pass.
- Targeted: single-shot + overlay_redesign + capture_preview_fidelity +
  shared_components — 72/72 pass.
- Mark/enrollment support: overlay_redesign + fidelity + shared_components
  + mark_slimdown + enroll_guided + enroll_beacon_boundary +
  enroll_capture_breakup — 121/121 pass.
- Full `flutter test` — 616/616 pass.
- `flutter analyze` (owned 4 files) — No issues found. Full-tree analyze —
  3 issues, all outside ownership and untouched: `session_edit_screen.
  dart:71` unused `_tab` (warning + info, sibling in-flight) and the
  pre-existing `welcome_screen.dart:52` info.

### Deviations (from the shared-overlay uniformity in `## Overlay redesign`)

- FCD-1: mark/face no longer renders the shared three-element overlay
  (bar + oval/comet + rotation line). It renders static oval + one
  single-shot line only (`showProgress: false, showBeacon: false`).
  Justification: tester-directed product-owner order — progress/beacon/
  rotation guide a multi-angle session and are meaningless for an instant
  single-shot check. Enroll keeps the full three-element rendering.
- FCD-2: new copy `faceCheckPrompt = 'Look at the camera.'` (one line,
  renders only on mark/face at rest; host inconclusive/retry notices still
  replace it when present). Justification: the shared rotation line
  (`captureGuidePrompt`) instructs a slow rotation the user must NOT do
  here; enroll keeps frozen `enrollCapturePrompt` verbatim. No other
  strings added or altered.

## Session-edit subtab (2026-09-10)

Tester-directed layout change, presentation/navigation only. The session-edit
page (`prof/sessions/<id>/edit`) showed the Add-person form inline below the
marks list; it is now two sub-tabs — Marks (person rows + partial + absent
quick lists + Save) and Add person (the ManualAddForm edit-* + queue
behavior, unchanged).

### Files changed (mine)

- `apps/proximity_app/lib/features/records/session_edit_screen.dart` ONLY
  (lib). Header comment documents the sub-tab contract + draft-preservation
  rule. Data logic byte-identical (`_windows/_names/_rolls` copies,
  `_toggleWindow/_toggle/_remove/_markPresent/_add`, `_draft`, `_absent`,
  monotonic-stamp `_save` with startIso/org preservation, `_personTile`
  tri-state + per-round checkboxes). Build-only reorganization:
  - Fixed header (classLabel · dateIso, present count, readOnly banner)
    stays above the tabs; the sub-nav SWAPS content via an IndexedStack
    (same pattern as the take-attendance host: each sub-tab shows ONLY its
    view, no shared scroll, inactive views stay mounted).
  - Marks tab = partial card + absent card + person tiles + Save (verbatim
    widgets, moved only). Save stays on Marks only.
  - Add tab = the same `ManualAddForm(fieldPrefix: 'edit', course,
    sessionId, onAdd: _add, isPresent: _isPresent)` in its own scroll —
    no duplicate `Add person` section header (the segment label carries the
    frozen copy, so `find.text('Add person')` still matches exactly once).
  - New navigation copy is the two segment labels `Marks` / `Add person`
    only. All FEATURE_INVENTORY.md §5.6 + Appendix A copy untouched.
- `apps/proximity_app/test/session_edit_subtab_test.dart` — NEW (mine, 5
  tests): two tabs render correct content (Marks default, IndexedStack
  mount, Add offstage); Add draft survives tab switches; save path
  unchanged (Add on Add tab → Save on Marks → history upsert, id/startIso
  stable, offline queue flush); readOnly parity (no tabs, no form, no
  Save); absent quick list on Marks only.

### Draft-preservation contract (documented, no silent loss)

Switching tabs preserves the unsent Add-person input (IndexedStack keeps
the form mounted — controllers never clear on switch). Save lives on Marks
only and persists the *marked* state; it does NOT consume a
typed-but-unsent Add draft — the professor must tap `Add & mark present`
on the Add tab first, then Save on Marks. Same rule as the old inline
layout (Save never consumed un-added typing there either); the tabs only
make the two steps explicit. Documented in the screen header comment.

### Web readOnly parity (verified)

`readOnly` hides the Add tab entirely (no SegmentedButton, no
ManualAddForm, no Save) — exactly the old inline parity (`if (!readOnly)`
gated the form + Save; toggles/Remove already null). Pinned by the
readOnly test (Marks content still reads view-only).

### Mechanical test migration (existing suites, navigation only)

The sub-tab move required tab taps in 3 pre-existing edit tests (no
assertions weakened, no data expectations changed):

- `test/widget_test.dart` `saved session edits later from the course
  page`: Round-1 unmark on Marks → tap `Add person` → enter edit-* → `Add
  & mark present` → tap `Marks` → `Save changes`.
- `test/widget_test.dart` `prof session edit: typing searches, card fills
  the same fields`: tap `Add person` before the directory search; tap
  `Marks` before Save.
- `test/prof_zero_intersection_test.dart` `session-edit Add person is
  correction-scoped`: asserts both segments + IndexedStack; Save on Marks
  (form offstage); edit-* keys after tapping `Add person`; partial chrome
  back on Marks. `session edit lists partial + absent` needed no changes
  (Marks default).

### Verification (exact results)

- `flutter analyze` — 1 pre-existing info only
  (`welcome_screen.dart:52`, noted in prior logs); zero in owned files.
  (A sibling log entry citing `session_edit_screen.dart:71 unused _tab`
  was a transient mid-write read — the field is consumed by the
  SegmentedButton + IndexedStack; current analyze is clean for this file.)
- `test/session_edit_subtab_test.dart` — 5/5 pass.
- `test/prof_zero_intersection_test.dart` — all pass (incl. migrated
  session-edit group).
- `test/widget_test.dart` edit trio — 3/3 pass (2 migrated + partial/absent
  unchanged).
- Records + manual suites (`course_test`, `records_rebuild_test`,
  `course_attendance_test`, `manual_add_test`,
  `live_manual_attendance_test`) — 32/32 pass.
- Full `flutter test` — 632/632 pass.

### Deviations

- SED-D1 (navigation label, spec-mandated): new visible copy `Marks` (the
  Marks-tab segment label). `Add person` reuses the frozen section header
  verbatim as its segment label; no other strings added or altered.
- SED-D2 (test migration, mechanical): 3 pre-existing edit tests gained
  `Add person`/`Marks` tab taps (see above). No lib file outside
  `features/records/session_edit_screen.dart` was touched.

## Date visibility (2026-09-10)

Tester-verified date-visibility defects, presentation only. Frozen kept frozen:
date FORMAT helpers + output strings (`sessionDateTimeLine`, `fullDateOf`,
`lastDateLabel`, `sessionTightLabel` — reused, never altered), verdict/status
strings (`Present`/`Partial p/t`/`Absent` carried verbatim on the badge via the
documented compound-display override), data/filter/sort logic
(FEATURE_INVENTORY.md §5 + Appendix A — byte-identical).

### FIX 1 — Student session tiles (dense rows truncated the full date)
- `lib/widgets/course_attendance.dart` — `StudentSessionTile` layout
  restructured (same data, better hierarchy): frozen `sessionDateTimeLine`
  date as its own prominent first line (`ProxType.body`, `softWrap`,
  `maxLines: 3`, `TextOverflow.visible` — NEVER ellipsized, wraps instead of
  clipping at 360dp + 130% type); status as a `VerdictBadge` carrying the
  exact `sessionStatusOf` word on its own line (Present→marked,
  Partial→review, Absent→waiting — the COURSES-D5 compound-display override);
  `studentSessionSecondary` (NEW pure helper: `rounds · label · org`, status
  no longer duplicated in text — same FIX-2 dedupe the detail screen
  already had) as the ellipsis line below (`maxLines: 2`); round-trail chips
  as a wrapping line (NEW optional `roundTrail` param, same `RoundTick`
  shape as `StudentCard`). Tokens only (`surfaceRaised`, `cardSpecRadius`,
  `divider`, `elevationRaised`, `ProxLayout.cardPadding`); §10.1: ellipsis
  lives ONLY on the non-date secondary text. `ProxListTile` no longer used
  here (`CourseSummaryHeader` keeps the `prox_cards` import for `ProxCard`).
- `lib/features/records/course_attendance_detail_screen.dart` — tile body now
  composes the shared `StudentSessionTile` (date line + badge + secondary +
  `_trailFor` chips via the new `roundTrail` param + `onHide` delete with the
  verbatim tooltip/snackbar/log). Deleted the now-redundant `_statusFor` +
  `_tileSubtitle` (logic moved verbatim into the tile: `_statusKindFor` +
  `studentSessionSecondary`); summary header, hide semantics, grouping —
  untouched. `student_card.dart` import kept (`RoundTick`); `prox_states` /
  `verdict_badge` imports dropped (badge ownership moved into the tile).
- Regression caught by the new tests and fixed in the same turn: badge +
  secondary text side-by-side in one Row overflowed 43px at 360dp/130% once
  the delete button + 8-chip trail shrank the column — badge now sits on its
  own line (matches the brief's "secondary lines/badges" hierarchy), both
  fit with room to spare. Proven by the bisect (tile-with-trail+onHide at
  320px repro → fixed).

### FIX 2 — Live tab root dates (course rows showed no date/time)
- `lib/screens/shells.dart` `_LiveRoot` block only: future is now
  `Future.wait([readCourses(), readHistory()])` (the history read the Courses
  picker already uses — read-only reuse, no new query/semantics; `refresh()`
  re-reads both on every Live-tab select, init-snapshot rule unchanged).
  Per-course `_lastDateFor` uses the picker's membership + newest-first rule
  (`courseId` match, legacy empty-`courseId` falls back to class-label).
  - Row: `Last hosted ${lastDateLabel(dateIso)}` (frozen picker format) or
    honest `Not hosted yet` when absent — date line wraps, never ellipsizes
    (§10.1); verbatim `Tap to host live session` kept as the second subtitle
    line (zero-intersection host-entry contract intact: radio + host lines +
    `Host` action, NO session counts — `sessions ·` still absent on Live).
  - Tab header: `fullDateOf(todayIso())` calendar-icon label row (same frozen
    helper + format + label-weight treatment as the take-screen header).
  - Take-screen header (`live_session.dart`) UNTOUCHED — read-only
    consistency check: same helper/format, different screens, so consistent
    with no conflict and no duplication (single `findsOneWidget` on each
    screen pinned by test). Web records-only branch untouched.
- New imports in `shells.dart`: `widgets/clock.dart` (`fullDateOf`,
  `lastDateLabel`) + `package:proximity_storage/storage.dart` (`Course`,
  `ClassRecord` casts); `todayIso` resolves via the existing `device_store`
  barrel (record_helpers re-export).

### Tests
- NEW `test/date_visibility_test.dart` (4): tile full-date at 360dp + 130%
  with longest labels (8-round Partial 4/8, 60-char classLabel, 70-char org —
  date `findsOneWidget`, date `overflow != ellipsis` + `softWrap`, no
  exception); detail same conditions with trail; Live rows last-hosted +
  today + `Not hosted yet` + host-only negatives; take-header unchanged pin.
- Drive-by harness (LIVE-D3 precedent, called out): two
  `identity_surface_test.dart` history-tile pumps gained `theme:
  proxLightTheme()` — the tile now reads `ProximityColors` like every other
  rebuilt widget, so bare-`MaterialApp` throws. No asserts changed.

### Verification (exact results)
- `flutter analyze` (full tree) — 1 pre-existing info only
  (`features/setup/welcome_screen.dart:52`, untouched, Nav-logged).
- New `test/date_visibility_test.dart` — 4/4 pass.
- Records/shell suites (`course_attendance`, `records_rebuild`,
  `identity_surface`, `prof_zero_intersection`, `live_subtabs_freshness`,
  `live_courses_bug`, `responsive_a11y`, `course_test`) — 66/66 pass.
- Full `flutter test` — 653/653 pass (one first-run flake in sibling-owned
  `enroll_beacon_boundary_test` also passes in isolation 14/14 and passed on
  the immediate full-suite rerun — same suite-ordering flake family logged in
  the Live-roster / Mark-slimdown entries; no owned file in its tree).

### Deviations
- DATE-D1 (layout, tester-mandated): badge-on-own-line + date-never-ellipsis
  stacking (see regression above) — same strings, same fields, wrapping
  instead of truncating. No frozen string/timing/threshold/network touched.
- DATE-D2 (test-only): `identity_surface_test.dart` themed-harness lines
  (above); `StudentSessionTile` gained the additive optional `roundTrail`
  param + `studentSessionSecondary` pure helper (no existing call-site
  signature broken — all params beyond the original four are defaulted).

## Edge-to-edge capture (2026-09-10)

Tester-verified residual defect: the face-check page was STILL lightly
squished — scaffold chrome (app bar + Column/Expanded boxing) constrained
the preview. This entry takes the preview fullscreen: the direct camera
frame is the FULLSCREEN background with chrome floating above it as
SafeArea-seated positioned overlays (chrome avoids the notch; the VIDEO
goes under it). Presentation only — auto-scan timing/retries, FaceGate
semantics, prompts, thresholds frozen (FEATURE_INVENTORY.md §3.5 +
Appendix A).

### What was still constraining it
- Mark (`features/mark/face_check.dart`): the view's own
  `Column[Expanded(preview Stack), Padding(Scan button)]` — the preview
  Stack only ever got the body-minus-button area, and the button row boxed
  it from below.
- Enroll (`features/setup/enroll_capture.dart` composer): opaque AppBar +
  body-below-it Scaffold defaults (`extendBody` /
  `extendBodyBehindAppBar` false) — the preview started under the app bar
  and the top progress bar sat at `top: 8` of that reduced body.

### Fix (owned files only)
- `features/mark/face_check.dart`: Column/Expanded/Padding → fullscreen
  outer Stack (default loose fit, never a force-fill) holding THE preview
  Stack (loose + centered, frame first + overlay second, zero treatment —
  placeholder still `SizedBox.expand`, a provided frame still a direct
  child) plus the Scan fallback as a bottom-`Positioned` `SafeArea`
  overlay. The button lives beside the preview Stack (outer Stack) so
  button internals never enter the video path. Single-shot semantics
  unchanged: `showProgress/showBeacon: false`, host-notice-else-
  `faceCheckPrompt` one-liner, `signalForNotice` mapping untouched.
- `features/setup/enroll_capture.dart` (chrome/scaffold only): Scaffold
  gains `extendBodyBehindAppBar: true` + `extendBody: true`; AppBar turns
  transparent overlay (`backgroundColor: transparent`, `elevation: 0`,
  `scrolledUnderElevation: 0`) keeping title `Face capture` + Cancel wired
  to the existing `_cancel` nav (STEP-SCOPE intact); preview gets
  `overlayTopInset: kToolbarHeight` so the top bar clears the app bar.
  Body Column + `Expanded(preview)` + bottom bar structure kept.
- `widgets/capture_overlay.dart` (additive option only): new `topInset`
  (default `0.0` = byte-identical); the slim top bar sits at
  `topInset + sm` inside a `SafeArea(bottom: false)`. Beacon/progress
  semantics, prompt copy, signal tones, comet geometry, and reduce-motion
  behavior untouched.
- `features/setup/enroll_capture_sections.dart` (presentation only): new
  `EnrollCapturePreview.overlayTopInset` (default `0.0`) forwarded to the
  overlay; save-error toast + bottom bar seated in `SafeArea(top: false)`.
  The preview surface itself is untouched (bare `CameraPreview` direct
  child, loose Stack, no wrapper of any kind).
- Untouched per ownership: session driver, controller, core, routes, host
  shells (`student_home.dart`, `main.dart` AdaptiveScaffold/Cupertino
  SafeArea), the still-capture modal (`screens/face_capture.dart`), other
  mark/setup files, tokens. Residual (documented, not fixed here): the
  mark view fills its body edge-to-edge but cannot paint behind the
  parent shell's app bar without touching the host shell — follow-up
  outside this ownership if true under-app-bar video is wanted there.

### Tests
- NEW `test/edge_to_edge_capture_test.dart` (17/17 pass): enroll Scaffold
  extend flags + transparent AppBar + `topInset == kToolbarHeight`
  full-screen; mark fullscreen structure (inner preview Stack has zero
  `Positioned` children, Scan floats as `Positioned`+`SafeArea` overlay)
  + no-`Column`/`Expanded`/`Padding` source pin; zero-treatment widget +
  source pins both screens; `SafeArea` chrome pins (top bar, toast,
  bottom bar, Scan) + source; native-aspect geometry 3:4/4:3/20:9/1:1
  both screens; single-shot vs beacon pins (mark flags/line/signal,
  overlay `topInset` default `0.0`, full-screen enroll bar + beacon +
  enroll prompt).
- Targeted: single-shot + fidelity + overlay_redesign + breakup = 60/60;
  enroll/mark driver batch (guided, beacon-boundary, lifecycle,
  student_driver, rescan-cooldown, face_identity, account-roll) = 113/113.
- Full `flutter analyze` — 1 pre-existing info only
  (`features/setup/welcome_screen.dart:52`, untouched, sibling-owned); all
  owned files clean.
- Full `flutter test` — 653/653 pass, 0 fail.

### Deviations
- EDGE-D1 (test-only, brief-mandated): `enroll_beacon_boundary_test.dart`
  `Scaffold defaults` pin now expects `extendBody` /
  `extendBodyBehindAppBar` true — the old pin encoded the pre-edge-to-edge
  body-below-AppBar layout the brief explicitly replaces. Resize + default
  toolbar-height asserts kept; no other assert in that suite touched.
- EDGE-D2 (layout): enroll terminal Continue/Try-again stay in the bottom
  bar (now `SafeArea`-seated), not positioned overlays — mid-flow capture
  chrome is overlay-only (bar + oval + comet + prompt + toast); the
  terminal buttons are post-capture navigation. Preserves the
  Expanded-ancestor + bottom-bar-variant pins.
- EDGE-D3 (scope): mark carries no overlay app bar of its own — the
  faceCheck phase never had one (host shell owns nav), so there is no back
  control to float; the view is edge-to-edge within its body (see
  residual above). No frozen string/timing/threshold/network touched.

## Landscape support (2026-09-10)

Tester report: no orientation lock exists anywhere (no SystemChrome lock,
no Android screenOrientation, iOS allows landscape) — yet the app never
goes landscape-usable. Fixed presentation/navigation only. Frozen per
FEATURE_INVENTORY.md Appendix A: strings, timings, thresholds,
verdict/network semantics — all untouched (no driver, controller, core,
claim, routes, tokens, or sync-engine edits).

### AUDIT (failing tests first, 740x360 + 844x390 + 130% text)
New `apps/proximity_app/test/landscape_support_test.dart` (20 tests) was
written before any fix and run green-minus-3:
- FAIL `face-check prompt never hides under Scan at 740x360 130%`:
  prompt Rect(20,240,720,261) overlapped Scan Rect(300,247,464,265)
  (`overlaps == true`) — the bottom-overlay button sat on top of the
  overlay prompt in short-height landscape.
- FAIL `face-check prompt reachable at 844x390 130%`: same overlap class
  on the second landscape size.
- FAIL `fallback sheet never stretches past 560 at 740x360`: TextField
  Rect(70,285,670,340) width 600 > 560 — sheets stretched full width
  instead of the §10 max-width-center rule.
- PASS (pins, no fix needed): both shells render 3 tabs with the bar above
  the bottom edge; waiting/proving/verdict + student browse settle;
  device/account-key/result + welcome settle with CTAs reachable via
  scroll; enroll feed preserves ratio height-first with the oval inside
  the video box; take host settles with inbox reachable via sub-nav;
  records + account screens settle; alert dialog actions reachable; long
  StudentCard ellipsizes without exception.

### FIX (layout regions only)
- `lib/features/mark/face_check.dart` (chrome re-seat only): new
  `shortLandscape` gate (`width > height && height < 500` — landscape
  phones only; default 800x600 test surface + all portrait sizes keep the
  byte-identical Stack path). In that shape the SAME bare preview Stack
  (loose + centered, frame first + overlay second, zero treatment;
  geometry still from `previewAspectRatio` via the existing
  orientation-adjusted path — no new aspect logic) fills the row height
  first while Scan rides BESIDE it in a 200px side panel
  (`SafeArea > Center > SingleChildScrollView > ProxPrimaryButton`,
  same icon/label/disabled semantics) instead of floating over the video.
  Signal mapping, single-shot flags, prompt contract untouched.
- `lib/widgets/fallback_button.dart` (`showProxSheet` chrome only):
  content wrapped in `Align(topCenter) > ConstrainedBox(maxWidth: 560)`
  inside the existing `SingleChildScrollView` (keyboard-safe viewInsets +
  scroll untouched). Portrait widths (<560) fill as before — the box only
  caps, never stretches — so portrait rendering is pixel-identical.
  Log drawer, routes, tokens, drivers untouched.
- Verified no-change (with evidence): enroll preview already fills height
  first (740x250 box + 4:3 feed → 333x250 centered, ratio exact); overlay
  oval already tracks the video box (`previewRectFor`/`guideRectForAspect`
  pins pass); browse/waiting/proving/verdict already
  `Center+SingleChildScrollView+ConstrainedBox(560)`; setup/account/records
  already `maxWidth 460/560` + scroll; tab bar already
  `SafeArea(top:false)` with labels fitting 740 width at 130%; dialogs
  already Material-bounded with actions reachable. Take host stays
  full-width by the prior a11y control-console exception (constraining it
  broke the approve flow — same lazy-cache class, not re-attempted).

### Tests
- New `test/landscape_support_test.dart` — 20/20 pass after the fix
  (shells/tabs, mark phases, setup steps, capture geometry + prompt
  separation at both sizes, take inbox, records breathing, account pages,
  sheet/dialog bounds, no fixed-height clipping).
- Updated `test/edge_to_edge_capture_test.dart` source pin ONLY (called
  out): `Expanded(` ban → landscape allowlist (`shortLandscape` present +
  exactly one `Expanded`, in that branch). Portrait Stack path, zero
  `Column`/`Padding`-widget/`StackFit.expand`, single-shot flags intact.
- Verify: `flutter analyze` — 1 pre-existing info only
  (`welcome_screen.dart:52`, untouched); targeted capture/mark/sheet
  suites green; `test/widget_test` + records + account suites green;
  full `flutter test` — all pass; `flutter build web --no-pub` — green.

### Deviations
- LAND-D1 (layout, tester-mandated): face-check gains a short-landscape
  Row side panel (Scan beside the preview instead of over it) gated on
  `width > height && height < 500`. No frozen string/timing/threshold/
  network touched; portrait path byte-identical.
- LAND-D2 (layout, spec-mandated §10): fallback sheets gain max-width 560
  centering. No copy/behavior change; portrait pixel-identical (cap only).
- LAND-D3 (test-only): edge-to-edge source pin allowlists the single
  landscape `Expanded` (see above). No production contract weakened —
  the portrait zero-boxing pins still hold.

## Records date + refresh (2026-09-10)

Tester-verified student-records defects, presentation/read-path only. Frozen kept frozen:
date FORMAT helpers + output strings (`sessionDateTimeLine`, `fullDateOf`,
`lastDateLabel`, `sessionTightLabel` — reused, never altered), verdict/status
strings (`Present`/`Partial p/t`/`Absent` carried verbatim on the badge),
sync merge/tombstone semantics (engine untouched — read-only, see below),
data logic (FEATURE_INVENTORY.md §5 + Appendix A — grouping, totals, hidden
filter, newest-first order, cache contents byte-identical).

### FIX 1 — day missing (tiles showed TIME with no DAY)

Root cause: cloud docs read via `docToRecord` default a missing `dateIso` to
`''` (old/hand-written docs), while the timestamps survive. The frozen
`sessionDateTimeLine` then yields `' · HH:MM'` (TIME with no DAY) or `''`
(empty line) — pinned as the unfixed-helper shape in the new tests. Every
normal record already rendered its date on the tile's prominent first line
(prior `## Date visibility` restructure), so the day was dropped only on this
edge shape, never buried in a secondary line.

- `lib/widgets/course_attendance.dart` — new pure composition
  `studentSessionDateLine` (helper untouched): `dateIso` present → frozen
  `sessionDateTimeLine` verbatim (normal path byte-identical); `dateIso`
  empty but start/timestamp parseable → day restored from the same timestamp
  the helper itself uses for the time, in the identical `'yyyy-MM-dd · HH:MM'`
  shape; nothing parseable → the record's own `classLabel` (then `id`, which
  the constructor always generates) so the prominent line is never empty. No
  invented copy — every fallback is a field already on the record. The tile
  first line now calls it (same body style, same wrap-never-ellipsis rules).
- `lib/features/records/course_attendance_detail_screen.dart` — untouched
  (already composes the shared tile; inherits the fix).

### FIX 2 — late refresh (pull-to-refresh did not update promptly)

Root cause (three stacked stalls in `MyAttendanceScreen._load`, all verified
in-tree): (1) the drag awaited the 8s `isOnline` probe BEFORE pulling — up to
8s of spinner before the pull even started; (2) `pullStudentSessions` had NO
bound, so a dropped radio held the indicator indefinitely; (3)
pull-then-cache-write ordering awaited `writeStudentSessions` BEFORE
`setState`, so a slow cache write held the visible update hostage. Ruled OUT
with evidence: the "list future isn't reassigned" suspect does not apply
(this screen re-reads via `_sessions` + `setState`, not a `FutureBuilder`
future — the re-read happened, just late); the "awaits a long-timeout flush"
suspect does not apply — this screen NEVER references the engine (no
`syncEngine`/`flush` import or call; student mode pulls directly, flush is the
professor push path), so `engine.dart` is READ-ONLY here, zero call-sequence
change, no semantic change.

- `lib/features/records/my_attendance_screen.dart` only: new `_refresh` wired
  to the `RefreshIndicator` — pulls bounded at 10s (same bound as the
  Firestore query itself) with NO probe gate, applies the UI first
  (`_applyPulled`), cache write trails (`unawaited(_writeCache)`), stale list
  stays visible under the indicator (no `_loading` swap). `_load` (init +
  detail-return) keeps its probe-first honesty path but shares the same
  helpers, gains the 10s pull bound, UI-before-cache ordering, and a
  probe-pass-but-pull-fail fallback to the cached copy (previously raw
  transport text). New `_gen` last-starter-wins guard: a stale init finishing
  after a refresh (e.g. its 8s probe timing out late) drops silently instead
  of clobbering fresher UI. Offline honesty copy (`Offline — showing last
  synced records.` / `You appear offline — connect…`) + online footer +
  last-sync semantics unchanged; no background polling invented.

### Tests

- NEW `test/records_date_refresh_test.dart` (11, all pass): frozen-helper
  day-missing pin (`' · '` prefix) + verbatim-normal pin; day restored from
  startIso / timestampIso fallback (TZ-agnostic expectations); never-empty
  total-loss fallback; tile derived-day prominent at 360dp + 130% (findsOnce,
  non-ellipsis, softWrap); detail shows the day for a dateless session;
  refresh completes while the online probe NEVER answers (hanging-probe
  double) incl. cache convergence + stale-init non-clobber after the 8s
  timeout fires; refresh picks up a newly synced course; failed refresh keeps
  the offline copy (cached and empty-cache variants).
- Drive-by test lesson (called out): `RefreshIndicatorState.show()` must NOT
  be awaited directly in tests (it needs pumped frames for its dismiss
  animation — deadlock); the file uses `unawaited(show())` + settle.

### Verification (exact results)

- `flutter analyze` (full tree) — 1 pre-existing info only
  (`features/setup/welcome_screen.dart:52`, untouched).
- New `test/records_date_refresh_test.dart` — 11/11 pass.
- Records/sync suites (`records_date_refresh`, `course_attendance`,
  `records_rebuild`, `date_visibility`, `cloud_sync`, `sync_engine`) — 44/44
  pass.
- Full `flutter test` — 695/695 pass.

### Deviations

- REC-D1 (read-path orchestration, tester-mandated): new `_refresh` path +
  `_gen` guard + success-state clearing (`_error`/`_offlineNote` now cleared
  where the pull lands — the init path previously relied on its entry reset;
  refresh keeps the list up so it must clear there) + probe-pass-pull-fail
  honesty fallback. Same pull/filter/order/cache/strings; no frozen value
  touched.
- REC-D2 (composition, tester-mandated): new `studentSessionDateLine`
  fallback chain (above). Frozen `sessionDateTimeLine` byte-identical; normal
  tiles render pixel-identical output.
- File ownership kept: `features/records/my_attendance_screen.dart` +
  `widgets/course_attendance.dart` (the allowed tile file) + new test.
  Drivers, claim, take_attendance, shells, routes, tokens, other widgets/,
  selection/inbox files, engine — untouched.

## Swipe tab switching

WhatsApp-style swipe left/right on tab content switches tabs, synced with the bottom bar (follow-up to `## Tab slide animation`, same session). Presentation/navigation only; frozen untouched: routes/stacks, Mark gate signal + behavior, shell back contract, `_LiveRoot`, take_attendance, entry/setup/mark/live/records/account content, drivers, core, tokens (no token changes at all this round), badge/avatar rendering, icon-only <360dp rule, all strings/timings/thresholds.

### Design (how swipe + tap animation coexist)

One motion, two triggers — no double-animation by construction. Both shells keep the `IndexedStack` + `_TabSlide` structure from the slide round: every switch, tap or swipe, funnels through the same `_selectTab` → single `_TabSlide` controller restart (220ms `tabSlide` + easeOutCubic). Swipe adds no animation of its own: a per-tab `GestureDetector` (`translucent`, `onHorizontalDragEnd` only) wraps each tab `Navigator` and translates a fling into a `_swipeTo(target)` call. No `PageView`, no extra `Scrollable`, no `NavigatorObserver` (see S-D1 for why the fuller design was probed and reverted).

- Direction: fling-velocity sign — finger left pages forward (`i+1`), finger right pages back (`i−1`); edges (0 rightward, 2 leftward) and sub-threshold drags are ignored. Floor is a documented `200px/s` const (`_minSwipeVelocity`: above touch-slop noise, below deliberate flings; tests drive 800px/s). Vertical lists win their own axis in the gesture arena, so scrolling never misfires; grep-verified no horizontal-drag handlers (`onHorizontalDrag`, `Dismissible`, `Slider`/`Switch`, nested `PageView`) anywhere in tab-root content, so nothing competes.
- Root-only (hard constraint 2): the handler reads the live tab `NavigatorState.canPop()` at gesture time — a pushed sub-page (course overview, capture/overlay screens, setup flow, account sub-routes) swallows both swipe directions and keeps its own gestures/back. No observer/rebuild needed because the check is per-gesture, not per-frame.
- Gate (hard constraint 1): `_swipeTo(0)` unenrolled runs `_gateMark()`, travels to Mark (flow covers it from the first frame — never bare mark), and snaps back to the origin tab on the next frame via post-frame `_selectTab(origin)`. End state: origin tab + setup route live on the Mark stack. Taps keep the old land-and-cover behavior byte-identically.
- Reduce-motion (hard constraint 4): swipe reuses `_selectTab`, whose `_TabSlide` parks at rest with zero-duration opacity — switches land on the first frame.
- Capture/overlay (hard constraint 5): pushed routes ⇒ `canPop()` true ⇒ swipe locked; verified by the pushed-overview test plus the handler grep above.

### Diff (mine only, `shells.dart` tab-switcher regions + `tab_slide` tests)

- `apps/proximity_app/lib/screens/shells.dart`: `_minSwipeVelocity` const + doc; per-tab `GestureDetector` around each tab `Navigator` (both shells, same pattern); `_onTabFling` (velocity floor → root check → `_swipeTo`) and `_swipeTo` (range/identity guards; student gate branch with travel + post-frame snap-back; professor plain delegate) per shell. `_TabSlide`, `_selectTab`, gate, back, bar, keep-alive structure otherwise untouched.
- `apps/proximity_app/test/tab_slide_test.dart`: 13 tests (was 7) — restored slide/token/gate/stack/scroll/reduced tests unchanged, plus: student flings both directions with mid-flight `[1.0]`/`[-1.0]` slide asserts + bar sync + first-edge hold; slow drag (~100px/s timed) never pages; unenrolled swipe-to-Mark ends on origin with bar synced, no visible flow, flow present offstage on the Mark stack; reduced swipe lands instantly with no slide in flight; prof full sweep Live→Courses→Account→Courses→Live with bar sync + both edges held; flings over a pushed `CourseOverviewScreen` swallowed both directions with stack intact.

### Test evidence

- `test/tab_slide_test.dart` 13/13 pass.
- `flutter analyze` clean (1 pre-existing info in untouched `welcome_screen.dart:52`).
- Shell/nav suites green (`widget_test`, `setup_shell_gate`, `live_courses_bug`, `account_screen`, `account_photo`, `take_back_intercept`, `live_subtabs_freshness`, `prof_zero_intersection` — 92/92).
- Full `flutter test`: 698/698 pass.

### Deviations

- S-D1 (probed and REVERTED, evidence kept): first implementation replaced the `IndexedStack` with a `PageView` (keep-alive pages + root-only physics via a tab-nav observer + tap/swipe arrival funnel). It satisfied every swipe requirement in isolation (all 11 pager-semantics tests green) but broke 11 `widget_test.dart` IP-join tests I do not own and must not touch: a shell-level `PageView` adds an ambient `Scrollable` (and keeps adjacent tabs' scrollables finder-visible), so `scrollUntilVisible(finder, delta)` without an explicit scrollable — which resolves `find.byType(Scrollable)` expecting exactly one — throws "Too many elements". `IndexedStack`'s offstage-skipping is load-bearing for the whole suite. Reverted to the fling-to-switch design above (zero finder-visibility change at rest); the previously-failing suites pass unmodified. No interactive finger-following: accepted trade — the brief's "same directional motion language" and bar-sync requirements are met literally by the shared single animation, and the gate snap-back reads identically.
- S-D2 (test-only): swipe finders match the slide chain through the new detector (`slide > opacity > detector > Navigator`); restored slide assertions updated to the stateful-`_TabSlide` position-value semantics from the slide round. No lib change.
- `_LiveRoot.refresh()` doc still names the `IndexedStack` (line ~737): left stale deliberately — `_LiveRoot` block is outside ownership (sibling Live agent); the mechanism sentence remains true in substance (per-tab Navigator caching).

## LOC wave: lib deletions

Scope: deletions + comment/copy fixes ONLY — no behavior, string-semantics, timing, threshold, or network changes. Giants (enroll_capture, student_home, take_attendance), tokens, drivers/orchestration untouched. Tests untouched by this wave (zero test edits).

- D1: `lib/widgets/trust_cards.dart` trailing block DELETED (71 lines + 1 unused import = 72 removed): `HonestUnreachableCard` + `SyncStatusStrip` classes. Pre-delete grep: `HonestUnreachableCard` → definition only; `SyncStatusStrip` → definition only + one plain-text doc mention in `sync_badge.dart:3` (no brackets, no code ref). Keeps intact: `DeviceTrustBadge` (live uses in `account_enrollment:98`, `account_device:156,200`, `device_sections:169`), `WrongOrgCard` (live use `verdict_view:161`), `PendingCountChip` (lives in `sync_badge.dart`, used by `UnsyncedBadge`). Hygiene: removed now-unused `import 'sync_badge.dart'` (nothing else in file used it; `ProxCard`/`ProxStateBadge` still used by the kept badges). Outcome: file 223 → 151 lines.
- D2: `lib/widgets/course_attendance.dart` `CourseSummaryHeader` (+ `compact` param) DELETED (37 lines + 1 unused import = 38 removed). Pre-delete grep `CourseSummaryHeader` → definition only (2 hits, same file); `compact` hits elsewhere are `VisualDensity.compact`/unrelated prose. Keeps intact: `summarizeCourse` (live: `my_attendance:263`, `course_attendance_detail:83`, `course_attendance_test`), `StudentSessionTile` (+ `studentSessionSecondary`, `_statusKindFor`, trail chips; live in detail screen + 4 test files). Hygiene: removed now-unused `import 'prox_cards.dart'` (`ProxCard` only used by the header). Outcome: file 305 → 267 lines.
- D3+D4 (chain): `lib/routes.dart` `ProxNav.openCourse/openLive/openWelcome` DELETED (11 lines) + 6 orphaned `ProxRoutes` builders DELETED (7 lines): `courseOverview`, `sessionDetail`, `sessionEdit`, `exportCenter`, `courseAttendance`, `courseCourse`. Pre-delete grep: builders → definitions only; `openCourse/openLive/openWelcome` → definitions only (`my_attendance._openCourse` is a private method, unrelated name). Router internals match on string literals (`prof/courses/…`, `prof/sessions/…`, `records/course/…`), never the builders — deep-link paths unchanged. Keeps intact: `pushNamed`, `openDebugLog` (live use `account_system:28`), `live()` (live use `shells:930` + `openLive` was the only other caller, itself orphaned), `liveRoster/liveInbox/liveAdd/liveSetup/liveRecover` (pinned by `live_sections_test:15-19`), all consts (`welcome/roles/device/profCourses/myAttendance/coursesMine/faceId/debugLog/mark/*`). Outcome: file 653 → 635 lines (18 removed).
- D5: `lib/widgets/prox_verdict.dart:37-50` named ctors + docs DELETED (14 lines): `ProxVerdictBadge.marked` / `.late`. Pre-delete grep: named ctors → definitions only; base ctor live use `result_sections:324` (`kind:/title:/detail:` named args, untouched). Keeps: base ctor + `_ProxVerdictBadgeState` (kind/state/icon/motion incl. `verdictPop`/`breath`/`shake`). Outcome: file 194 → 180 lines.
- D6: `lib/widgets/log_drawer.dart:32` dead re-export `export 'log_category.dart';` DELETED (1 line + 1 blank = 2 removed). Pre-delete grep: `logCategoryColor` producers/consumers are `log_category.dart:14` (def), `log_drawer.dart:275` (via direct `import 'log_category.dart'`), `debug_log_screen.dart:163` (via direct `import '../../widgets/log_category.dart'`); zero files import the symbol via the drawer barrel. Internal `import 'log_category.dart'` kept (still used). Outcome: file 344 → 342 lines.
- D7: `lib/core/cloud_sync.dart:29-35` duplicated `classSessions` doc block — second copy DELETED (3 lines). First copy kept verbatim; doc-only, zero code impact.
- C1: `lib/widgets/animated.dart:30-34` stale deletion-history NOTE DELETED (5 lines + 1 blank = 6 removed). `PresentTicker` kept (live use `live_session.dart:162`); file is now the ticker only (28 lines).
- C2: `lib/core/sync/store/store_base.dart:209` stale path comment, words-only: `widgets/manual_add.dart` → `core/sync/queue.dart` (verified `queue.dart` exists and owns `processPendingAdds:224`; `manual_add.dart` is now a shim). No code touched.
- B1: shared `'No student key…'` copy extracted to `const accountNoKeyNote` in existing home `lib/features/account/account_common.dart` (+5 lines: doc + const), 3 duplicate literals replaced with the const: `account_enrollment.dart:60`, `account_device.dart:142`, `device_sections.dart:96` (each `'…online once).'` → `accountNoKeyNote`; `const ProxSyncNote(…)` shape kept so all three stay `const`). Pre-replace grep confirmed exactly 3 lib literals (+ the new const). `device_sections.dart` gains `import '../account/account_common.dart'` (already imported by the other two consumers). String-semantics byte-identical (same const value, no rewording).

LOC: lib-only `git diff --numstat` = 157 deletions / 10 insertions across 12 lib files (net −147; target ~140). Gross removed per file: trust_cards 72, course_attendance 38, routes 18, prox_verdict 14, animated 6, cloud_sync 3, log_drawer 2, store_base 1 (changed line), account_device/account_enrollment/device_sections 1 each (literal → const). Insertions are the B1 const (5) + its import (1) + 4 changed-line counterparts — no new logic.

Verify: `flutter analyze` → 1 pre-existing info only (`features/setup/welcome_screen.dart:52 curly_braces_in_flow_control_structures`, untouched, Nav-logged). Full `flutter test` → 698/698 pass (`All tests passed!`).

Kept-with-reason (KEEP list + near-dups, all grep-proven live, untouched): manual_add shim, device_identity barrel, re-exports (except the single dead D6 line), live builders, platform facades, `VerdictBadge`/`ProxVerdictBadge`-base/empty-state/session-tile family (KEEP-distinct), drivers/orchestration/timings, tokens. `sync_badge.dart:3` doc mention of `SyncStatusStrip` left as plain-text provenance (no brackets → no analyzer link; editing it is outside the item list). `DeviceTrustBadge`/`WrongOrgCard`/`summarizeCourse`/`StudentSessionTile`/`pushNamed`/`openDebugLog`/`live*`/`ProxVerdictBadge`-base/`PresentTicker` all re-verified live post-edit (see evidence above).

Deviations: (1) two hygiene import removals (`sync_badge.dart` from trust_cards, `prox_cards.dart` from course_attendance) — forced by the deletions (otherwise `flutter analyze` unused-import warnings); no behavior change. (2) `device_sections.dart` gains one import (`account_common.dart`) — required by the B1 brief (const lives in the existing home). (3) Working tree contains sibling in-flight test edits NOT authored here (`test/mark_slimdown_test.dart`, `test/widget_test.dart` — harness dedupe, e.g. `import 'widget_test.dart' as helpers`); left untouched per the no-tests rule; suite is green with them (698/698).

## LOC wave: test dedup

Scope: TEST FILES ONLY — zero lib/ edits (verified `git status`: all lib diffs in tree are the sibling lib-deletions wave above + prior in-flight work, untouched here). No assertion weakening: every test asserts exactly what it asserted before (only scaffolding — helpers, shims, imports — added/removed/renamed; zero test bodies, zero expects, zero finds touched). No tests deleted. Per-file test runs after each file's edit, all green before moving on.

- A1 (mark_slimdown `_enterIp` → shared `enterIp`): DONE. `_enterIp` was byte-identical to widget_test's `enterIp` (same finder, same `scrollUntilVisible 300`, same `ipfield` key, same pumps) except the underscore. Deleted the duplicate + renamed its 4 call sites to the shared helper, following the `skip_audit_test imports student_driver_test as helpers` precedent (`import 'widget_test.dart' as helpers;` → `helpers.enterIp`). Enabling change (test-file-only, no semantics): widget_test's `enterIp` lived nested inside `main()` so it was unimportable — hoisted to top-level with its body/comment intact (internal call sites resolve unchanged; 29/29 green after hoist, before any other edit).
- A2 (`_markScope` → `testScope`): DONE. `_markScope` mapped 1:1 onto `testScope` (same auth email/uid/displayName, same cloud/store/face/key/still/camera/pose/student/ble/perm/bt indifferent defaults, same unconditional linked `Test User/student@example.com/12342210` → `linked:` param, same `probeOpen`/`studentDriver` fallthrough, same `StudentHomeScreen` home via `home:` param). Kept a thin delegating wrapper (`_markScope({studentDriver, probeOpen}) => helpers.testScope(...)`) so the 4 host call sites read unchanged — allowed by brief. Only delta: `testScope` additionally overrides `hostDriverProvider` with `FakeHostDriver()` (student flows never read it; 11/11 green proves inert). 11 dead imports removed with the old body (hygiene, otherwise unused-import warnings).
- A3 (4-step settle unify, live_subtabs vs tab_slide): DONE. Both `_settle` bodies byte-identical (`pump` + 4×500ms). Canonical kept in `tab_slide_test.dart`, renamed to public `steppedSettle` (private names cannot cross library boundaries); its 29 internal call sites renamed mechanically (13/13 green). `live_subtabs_freshness_test.dart` `_settle` DELETED; its 1 call site now `slide_helpers.steppedSettle` (second helper import needs a distinct prefix — `helpers` is taken by widget_test — deviation logged below). `_openTab` variants NOT touched anywhere (KEEP-distinct: widget_test `pumpAndSettle` vs shell stepped-settle is deliberate per brief). Other files' local `_settle` (live_courses_bug, prof_zero take-host) NOT touched — outside the listed pair.
- A4 (per-file shims → `testScope`): DONE except one KEEP (see below). Mechanical param mapping in each file; every migrated pump passes the shim's exact params through (`store`→`store`, `host`→`hostDriver`, `cloud`→`cloud` with the shim's offline default made explicit `FakeCloudSync(online: false)` where the shim defaulted offline, explicit `MaterialApp(theme: proxLightTheme(), home: ...)` home). Files: setup_shell_gate (`_shellOverrides`+`_shellApp` → 3 shell pumps; 13/13), prof_zero (`_scoped`+`_profShellApp` → 4 pumps; 9/9), course_test (`wrap` → 8 pumps; 9/9), mark_slimdown (via A2 wrapper; 11/11), live_subtabs (`_scoped` → 4 pumps; 6/6), live_courses_bug (`_profShellApp` → 2 pumps; 2/2), desktop_select (`_scopedSessions` → 1 pump; 5/5). Dead imports removed per file (5/7/3/11/9 respectively — hygiene, otherwise warnings). widget_test internals stay (only the A1 hoist).

LOC (test-only `git diff --numstat`): 342 deletions / 204 insertions across the 9 touched files, net −138 (target ~200; gross deletions 342 clear it, net trails because mechanical call sites spell out explicit homes + offline clouds + two helper imports). Per file (+added/−deleted): mark_slimdown +19/−68 (net −49), setup_shell_gate +14/−51 (−37), prof_zero +30/−61 (−31), live_courses_bug +16/−41 (−25), desktop +11/−19 (−8), live_subtabs +34/−33 (−1: twin helper imports + longer call sites ≈ shim removal), tab_slide +33/−32 (+1: pure rename churn), course_test +41/−33 (+8: 8 expanded call sites vs 14-line `wrap`), widget_test +6/−4 (+2: hoist + doc).

Per-file pass counts, before → after (identical, zero weakening): mark_slimdown 11→11, widget_test 29→29, live_subtabs 6→6, tab_slide 13→13, account_photo 15→15, setup_shell_gate 13→13, prof_zero 9→9, course_test 9→9, live_courses_bug 2→2, desktop_select 5→5 (affected-files total 112→112). Full `flutter test` → 698/698 pass, matching the tree's last-logged total (698/698, lib-wave entry above) — both waves green together.

Kept-with-reason: (1) `account_photo_test.dart` `_overrides({photoUrl})` KEPT entire file unchanged — `testScope` has no `photoUrl`/org params, so the photo-bearing auth override cannot be mapped exactly. (2) One-off inline ProviderScopes KEPT (not named shared helpers, each pins a distinct shape `testScope` cannot express exactly): setup_shell_gate signed-out flow (`FakeAuthService()` null auth — `testScope` always constructs an account) + 2 router-alias blocks (minimal auth/cloud/store[/enrollment] shapes); live_subtabs ProfShell end-to-end block (prof `displayName: Prof` + offline cloud + full stack); desktop self-refresh block (host-only override). (3) `_openTab` variants everywhere KEPT-distinct per brief. (4) `live_courses_bug`/`prof_zero` local `_settle` KEPT (A3 scoped to the live_subtabs/tab_slide pair only). (5) tab_slide `_overrides`/`_studentApp`/`_profApp` KEPT (not in the A4 file list; `_profApp`/`_studentApp` also carry reduced-motion MediaQuery branches with no `testScope` equivalent). (6) `widget_test.dart` internals otherwise untouched.

Deviations (all test-scaffolding, called out): (i) `enterIp` hoisted from inside `main()` to top-level in `widget_test.dart` (body identical + share-doc) — without this the A1 import is impossible (locals are unimportable); internal call sites unchanged. (ii) Thin `_markScope` wrapper kept delegating to `testScope` (brief-allowed; full inline replacement would bloat 4 call sites and net fewer removals). (iii) `live_subtabs_freshness_test.dart` carries two helper prefixes (`helpers` = widget_test, `slide_helpers` = tab_slide) — one prefix per import is forced (both export `main`; unprefixed import would clash), `slide_helpers` spelling forced by the `library_prefixes` lint. (iv) Prof-shell mappings (`prof_zero`, `live_courses_bug`) pass `email: prof@example.com` through `testScope`, whose displayName hardcodes `Test User` where the old shims used `Prof` — no test asserts displayName (rows/tabs/counts only); 9/9 + 2/2 green prove inert. (v) `testScope` additive extras where shims overrode less (camera/still/enroll/pose/host fakes on records/live pumps; auth on previously auth-less `_scoped` pumps; online-default cloud kept only where the shim had none — offline shims pass explicit offline) — all green per-file before moving on.

Verify: `flutter analyze` on all 9 touched test files — No issues found (dead imports removed as part of each edit). Full-tree `flutter analyze` → 2 items, both outside ownership and untouched: repo-root `analysis_options.yaml` include-not-found (root-level artifact; app-level runs do not report it) + pre-existing `welcome_screen.dart:52` info (Nav-logged). Full `flutter test` → 698/698 pass. Frozen guard: no lib/ edits, no test-body/expect/finder edits (diff is imports + helper defs + pump lines only), no tests added/deleted.

Concurrency note: this entry ran interleaved with the sibling lib-deletions wave above (their D-deviation-3 observes this wave's mid-write `import 'widget_test.dart' as helpers` state). Clarification: those harness-dedupe edits ARE this wave's A1/A2, authored here — the sibling's "left untouched" still holds (they edited no test files); both waves verify green together at 698/698 with each other's changes in-tree.

## Face trust + hands-free capture (2026-09-13)

Scope: liveness pipeline correction, hands-free enrollment/marking, trust-law tightening, debug emulator. All green (affected suites re-run per change; sole failure anywhere is the pre-existing student_driver BLE-timing flake, reproduced on the clean tree).

- Liveness /255 → raw255 root cause: the vendored MiniFASNetV2 TFLite expects BGR 0-255 raw (APK from_pixels path), but the app fed BGR /255 — every live face scored confident replay [0.000,0.005,0.995], bit-identical to uniform gray. Field shadow raw255=0.975 vs production 0.005; Lena BGR-raw live 0.984 vs BGR-/255 0.005; moire-replay raw 0.026, recapture-blur raw 0.243. Packer fixed, tag bumped to `liveness/minifasnet-v2-27-80x80-raw255+4ff758f4`, raw255 regression test pinned. Live field scores after fix: centre 0.90, left 0.95, right 0.89, up 0.79.
- Enroll bars: centre holds strict Tl=0.85 (vitality decider, re-checked at marking); diversity slots hold app-local 0.70 (tilted captures score systematically lower; joint-5/5 at 0.85 failed ~1 genuine enrollment in 4). App-local only, no ticket break.
- Front-camera mirror: file-space yaw negated to holder-perspective in MlkitPoseGate (own-left filled RIGHT bucket); landmarks/contours off (kills Unknown-landmark-type spam, unused signals).
- Hands-free: session scores vitality pre-accept per still (same per-slot bars; discards silent, holder follows prompts, terminal enrollFace re-scores); marking captures a 2-still burst deciding on the MAX + near-miss band 0.10 under Tl degrades to inconclusive (free rescan) instead of mismatch; inconclusive auto-retries ~1s apart in a 10s window (pure nextAutoFaceRetryDelay, pinned; mismatch never loops). Async-File.delete never completes under the widget-test FakeAsync clock (probed) — deletions are fire-and-forget in-loop and in retrySlot.
- Trust tightening: debug NONE-tier allowance REMOVED (debug enrolls like release, wires the real HW key; Software-no-enroll single law pinned). Stale-error fix: enrollFace/upload success clears message (old slot refusal rendered above Save after recapture); classifier treats faceDone as never-a-refusal.
- Platform: MainActivity FlutterActivity → FlutterFragmentActivity (biometric-gated Keystore signing crashed prove with KeyOperationError). Desktop records-only disables Continue-as-Student (role kept, reason inline).
- Debug backend: PROX_EMULATOR=1 dart-define → local Firestore+Auth emulators (fresh backend, no single-device/cooldown friction); release ignores it; rules untouched. Recipe in PROXIMITY_DEPLOYMENT §3e; firebase.json gains emulator ports.

## Field-fix batch: attendance reliability + same-phone reclaim (2026-09-13)

Scope: 9-item field bug report (liveness variance, camera preview churn, keypair/verify logging, BAD-sig/unknown-pkS split-brain, enroll progress honesty, face-vs-liveness copy, waiting-room unverified banner, reinstall cooldown, docs). Prior half-done liveness work (no-fallback scoring + sharpness floor, dirty at intake) kept and completed with tests.

- Liveness wild scores (0.08 vs 0.95 on a real face): root causes were scored-non-evidence — faceless crops (no/ambiguous detection fell back to centre-square and scored background as confident spoof) and severe blur. Dirty tree already threw unreadable on no-face + sharpness < 10.0; this wave keeps that, adds the exposure sibling (mean brightness outside 12–244 throws unreadable — lens-covered/flash-blown frames), pins `cropSharpnessRgba`/`cropMeanBrightnessRgba`/`livenessCropRect` unit tests, and extends the gate headers. Mapping unchanged: unreadable → free rescan (marking) / silent skip (enroll loop) / slot recapture (terminal enrollFace), never a burn.
- Camera preview persists across auto-retry: the verify moved INSIDE the open sheet. `StillCapturer.capture`/`FaceCaptureScreen` take an `accept` verdict (true pops, false re-captures on the SAME controller inside a 10s window, 1s gaps, status line narrates); the student mark flow runs `checkFaceAny` per burst in-modal and pops only on terminal verdicts. Fakes ignore `accept` (legacy single-verify path preserved for widget tests).
- Keypair/verify logging: `generateKey` now logs under CRYPTO with the SKey public-half prefix + install prefix + bound level (seed never logs); prof pin publish logs the pkP prefix; first-seen TOFU on both sides is visible (student `unverified` banner + queue log; professor `first-seen` log token on TOFU marks, `pin-mismatch` suffix on stale-pin refusals).
- BAD-sig/unknown-pkS split-brain (root-caused, both sides): the `org-mismatch` and `unknown-pkS` early gates returned ZERO `sigAck`, so the student logged `BAD prof signature` while the professor logged `unknown-pkS` — one event, two stories. Every early invalid is now SIGNED (helper `signedInvalid`); only `window-closed` stays unsigned (nothing to bind) and the driver maps it to prove-next-rotation pre-ACK-check. Prove-path `org-mismatch` returns the structured wrongOrg receipt. Semantics clarified: UNPINNED offline first-seen still marks (TOFU, not fatal — `first-seen` token); PINNED mismatch fails closed as `unknown-pkS` with a `pin-mismatch` log suffix (stale pin after student re-enroll, not "unknown"). Professors re-prefetch directory pins on every window start so mid-class enrollments/re-keys converge. Transport regression test pinned (signed early invalids verify; first-seen marks; window-closed parses).
- Enroll progress honesty: buckets were always kept (`retrySlot` clears only the refused slot) and the overlay bar already advances per fill — the gap was the terminal write (5× re-score + gallery + self-checks, seconds of empty button slot reading as a hang). The bottom bar now shows a disabled `Processing…` spinner state while saving (same height, feed never moves), then Continue / Recapture / Try-again.
- Face-fail vs liveness-fail copy: `FaceCheckResult.livenessFailed` flags vitality failures (below Tl outside the near-miss band); the needs-review verdict names photo/screen then, keeping the frozen wrong-face copy otherwise. Enroll already distinguished the two.
- Waiting-room unverified banner: YES, now — when the gated prof email lands with an empty pin cache (first-seen by definition), the room shows the provisional `unverified` banner (prove-time `checkProfPin` still owns the honest verified/mismatch verdict and always wins when present). Cached-pin rooms stay silent until prove (a cached pin is not a match).
- Same-phone reclaim (implements the proposal, rules change included): claim stamps `deviceId` (ANDROID_ID / identifierForVendor via `device_info_plus ^13.2.0`, fail-soft `''`); a cooldown-blocked move presenting the STORED id reclaims instantly (`allowedMove` + `isReclaim`, move clock restamped — Gmail auth + fresh face + fresh HW key still required); rules enforce the match (`isSamePhoneReclaim` + `deviceId` type-lock — client assertion alone moves nothing). Face still never survives true uninstall by design. Residual: rooted id spoof + Gmail + live face = fully compromised account anyway.
- Docs: SECURITY field-fix entry + pubspec list + DEPLOYMENT rules note (deploy `firestore.rules` with this build); this log entry.

Verify: `flutter analyze` app → 1 pre-existing warning (`test_device.dart` unused field, also on clean tree). `flutter test` app → 1149 pass, 1 pre-existing BLE-timing flake (`student_driver_test` unheard-response, fails identically on clean tree). `dart test` transport → 67/67 (2 exact-match `proved` assertions updated for the intended `first-seen` token + 1 new signed-invalid test). `dart test` protocol → 189/189. Operator: `firebase deploy --only firestore:rules --project proximity-attendence` + rules-drill re-run (JDK 21).

## Follow-up: stale-pin convergence + dedup visibility + loop race (2026-09-13)

Field report back: (1) `unknown-pkS|pin-mismatch` still blocked marking; (2) no prof-side dedup/vector logs; (3) enroll self-check + FaceDetector spam repeating, suspicion the camera keeps capturing during Processing.

- (1) Root cause: `pinStudentKeys` first-seen-wins meant the live server NEVER updated a stale pin — the per-window re-prefetch merged fresh keys into the persistent cache while the live server kept refusing the re-enrolled key. Fix: hydration forces overwrite (`pinStudentKeys(..., force: true)`; source is the authenticated same-org directory, never LAN, so overwriting is safe). Pinned transport convergence test: stale pin refuses signed-`unknown-pkS`, force-repin + new window confirms. Field action: start a NEW window after updating (online) — offline stale pins still fail closed to manual attendance, by design.
- (2) Dedup was wired end-to-end (student `embeddingFor` → `face:{vec}` → server compare-then-plant → `dupface:` token → roster flags + 1-tap override) but silent on success, AND no vector ever flowed while the pin gate refused first — missing vector logs diagnosed upstream refusal, not a drop. Added: student `session vector attached` log (length only) + server `vec-ok` log-only token per marked prove that plants with no match. Existing `dupface` substring assertions unaffected (`vec-ok` carries no such substring).
- (3) Two real things, neither runaway capture: (a) the self-check lines + `Unknown landmark type` spam are EXPECTED per-save work — terminal `enrollFace` re-scores all 5 stills and each plugin verify runs the plugin's INTERNAL detector with landmarks on (both app gates run landmarks-off; the spam is not ours); the "×3" is the per-still verifies progressing (or recapture cycles re-running all 5). (b) One genuine race: an in-flight still during save start could still score vitality + fill a bucket mid-save and move progress under Processing — post-pose, post-vitality, and loop-bottom gates now drop on `_finished` too. The camera takes no still once Processing owns the set.

Verify: transport 67/67 (incl. extended convergence test); app enroll/host suites 66/66 green; analyze clean on touched files.

## Field batch 2: device-unproven + identity UX + suites green (2026-09-13)

Seven field bugs, all closed. Suites: protocol 189, transport 67, storage 18, ble 38, app 1159 — 1471/1471 green, including the previously-failing `unheard response` test (fixed, see g).

- (1) `device-unproven|attest-reused-face,attest-unknown-root`: two separable findings. Pins re-verified complete against Google's live `roots.json` (exactly the RSA + EC HW roots — current), and the gate order proves the chain is COMPLETE (OID/leaf-pkD/challenge/signatures all passed; only the pin failed on a self-signed non-Google root) — so the holder's key attested under emulator/software/ROM/non-GMS attestation, fail-closed by design. New `core/attestation_self_check.dart` pre-runs the professor's gate at enroll upload (refuses the binding with the named remedy copy) and at mark time (specific detail instead of a burned POST + rate budget); HW-DER-shaped chains only (synthetic/test chains skip; server stays final). Host log gains `root=<sha256-prefix>` on unknown-root. `attest-reused-face` was retry noise: the stamp set was global/never-cleared, so every same-ticket retry across rotations (j=34!) flagged — rescoped to window-scoped stamp→first-ID with other-IDs-only anomaly scope (only a cross-Gmail transplant flags now).
- (2) Verification highlight tags: browse class tiles carry the pin-verdict tag (`browseVerifyTag` — Verified green / Unverified yellow incl. first-seen / Blocked red on mismatch; `known` stays caption-only) beside the Open pill; the waiting-room prof card already rendered the inline verified/unverified banner (now fed pre-prove by the provisional first-seen verdict — confirmed present, no change needed).
- (3) Prof key publishes at registration itself: `armProfKeyPublisher` (role hub + Take open) + `publishCurrentProfKey` (registration + every hosting); every outcome logs, including the three skips (unarmed / no email / no lecture key yet — fresh registrations log the deferral since the lecture key is ephemeral per hosting). Lecture keys stay ephemeral by theft analysis (a per-install key would let a stolen phone host trusted classes; pins accumulate to 8 either way).
- (4) Desktop prof switch-account one-click: `entrySignOut` now unsets the mode whenever no session remains (was: only when none at entry) — no more '?' logo on a remounted account-less shell, no second tap. The pinning test updated to the new contract.
- (5) Proving steps centering: loose label-width flexes pushed the last dot off-center — bounded-320 tight equal thirds, dots equidistant, 38px-overflow guard preserved (tight thirds still shrink + ellipsize).
- (6) Fixed the stall (was mislabeled flake): the test's "next rotation" inject at 6s never crossed the 10s rotation (j stayed 0; `_waitNewChallenge` correctly skips same-token echoes; silenceCap probe found the window open and looped to the 2min timeout). Inject moved to 12s — passes in ~12s with `j=1 (confirmed)`. Product loop correct, no lib change.
- (7) Course avatar: class-titled cards mixed into the person-initials path (`DSL506 - …` → `D-`). `StudentCard.isCourse` routes the disc to `courseInitials` (`DS`) + course hues (browse tiles pass true); `studentInitials` additionally skips bare separators as defense (`DI`, never `D-`).

Verify: `flutter analyze` app → only the pre-existing `test_device.dart` warning; transport analyze clean; full `flutter test` 1159/1159 (was 1149/1148 + flake).

## Field batch 3: attestation validity + enrollment nav + role actions (2026-09-15)

Scope: iQOO field failure (`expired-cert chain=5 root=6d9db4ce`) root-caused live over adb + enrollment back/role dead-ends found while debugging it. Eight commits, all pushed to `First-Release`.

- RFC 5280 century fix (protocol, `chain_verify.dart`): the validity gate read dates from the `x509` package, which inherits asn1lib's non-conformant UTCTime cutoff (75: year 70 → 2070). RFC 5280 + BoringSSL + OpenSSL + Go mandate 50 (70 → 1970) — matching Android itself and Google's own blueline reference leaf, which encodes the same epoch-anchored `700101000000Z`. Field effect: genuine Trustonic leaves (1970→2048) phantom-failed. Dates now come from the positional TBS Validity field via a strict parser (seconds + Z required, calendar-real days, leap-second/offset/fraction shapes fail closed); unparseable dates still fail closed. Proven: old path yields 2070 on identical fixture bytes (temp test, deleted after the run); the full genuine-chain pin gate with `checkValidity` passes post-fix. No trust change (signatures/pins/challenge/leaf-pkD untouched); short-lived RKP intermediates stay validity-gated per Google's threat model (the field 12-day intermediate correctly expires).
- Attestation debug detail (app): self-check carries per-cert dates + EXPIRED markers + flags + phone time (no key material) into the CRYPTO/SEC log lines, `EnrollmentState.attestationDebug`, and a Debug card on the save refusal screen (attestation class only, phased out under other refusals). A raw leaf time-string scan (`leafTimes=[…@offset]`) exonerated the parser during the investigation. Save screen also gains the standard terminal System-log action (it had no log entry point).
- Stale refusal cleared on Generate: an earlier Save refusal survived onto the fresh key (old error above new key + Face pending).
- Back-nav strand: back from the role step while signed in landed on welcome with no forward path (re-sign-in is a same-email no-op) — role is now the first step while signed in (back exits via `onFirstBack`), regression-tested.
- Role actions dead (register-student-then-prof): the RoleHub cached its role future and never invalidated it (Register buttons survived their own success); in-flow student registration never advanced the stepper; a shell-pushed flow kept covering the new home after a mode flip (retries logged `mode prof → prof`). Now: cache dropped + rebuilt post-action, in-flow student registration steps to device, mode flip yields the pushed flow. Three regression tests.
- Refusal copy split: shared `expired-cert`/`device-expired` copy blamed both causes — now certificate remedy (update + online RKP refresh + Generate anew) vs window remedy (one online heartbeat), plus a dedicated `EnrollRefusal.attestation` next-step card (Back to account step) instead of the dead-end generic Try again.

Verify: `dart test` protocol 219/219 (incl. 7 new century/gate tests); app suites — setup/entry/account/attestation/enrollment 133+ green incl. new back-nav/role-action/rendering tests; `flutter analyze` clean on every touched file. Residual: RKP pool refresh still needs the charging-idle job (field intermediate expires 2026-09-19); refusal copy kept fail-closed throughout.

## Reference-verifier parity: leaf-skip + factory-expired ignore (2026-09-16)

Scope: field photo proved the iQOO still runs a pre-`0bb9216` binary (`cert0:2070…EXPIRED` is only producible by the old `x509`-package parser; `now=` is tap-time clock, never build date) — plus the gate still diverged from Google's `android/keyattestation` reference in two validity rules.

- Leaf never gates (`chain_verify.dart`): `verifyChainSignaturesLeafFirst` skips leaf-first index 0 under `checkValidity` (reference: final-cert dates are device-set/tamperable/clock-skew); debug renders `unchecked-leaf`. Trustonic epoch leaves can never refuse alone.
- Factory-expired ignored (same file): `_chainIsFactoryProvisioned` copies `provisioningMethod` (child-of-root subject carries serialNumber OID 2.5.4.5 → factory); expired forgiven, not-yet-valid still fails, RKP intermediates fully enforced. Debug renders `expired-ignored-factory`; revocation stays advisory (`RevocationCache`).
- Build fingerprint (app, `attestation_self_check.dart`): `AttestationSelfCheck.debugLine` gains `eng=rkf50-leafSkip-factoryExpIgnore` so the next field photo proves its binary.
- Enroll render fixture updated to the realistic post-fix refusal (spent RKP `attest-cert-1`, leaf `unchecked-leaf`).

Verify: `dart test` protocol 224/224 (incl. 4 new factory/leaf tests); app attestation 12/12; `dart analyze` clean on touched files. OPERATOR: ship a fresh APK from this tree to the iQOO and re-tap Save; expect `eng=rkf50-leafSkip-factoryExpIgnore` + `unchecked-leaf`.
