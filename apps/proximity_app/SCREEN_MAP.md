# Proximity screen map (Track 5 rebuild — living doc)

One entry per screen: what exists / merged / split / removed + one-line
reason to exist. Authority: end goals in the task brief (anti-proxy,
speed, fully-offline flow, UX-first, consistent + modular + documented,
smaller codebase). Mechanism (Track E transport) and Tracks 1–4 hard
requirements are preserved — restructuring only, no weakening.

**Reorganized this pass** from "grouped by feature topic" to **grouped by
shell/audience** — pre-auth Entry, then each of the three authenticated
student tabs (Mark / Records / Account) as its own section, then the
Professor shell, then Shared. This matches how a person actually
experiences the app (one shell at a time) rather than how the backend
happens to be organized, and makes "what does the Account tab contain"
answerable by reading one section instead of hunting across the doc.
Where a screen picks up a specific visual treatment from
`PROXIMITY_UI_REDESIGN.md` (a gradient, a glow, a particular error/log
pattern) it's called out inline as **Visual:** — most screens have none,
per that doc's principle that effects are earned, not default, so absence
of a `Visual:` line is itself meaningful.

**This is now the single, merged version of this document.** The
original route tree below is unchanged except where marked **HARD
REQUIREMENT** — those are product-owner instructions integrated directly
in place (renames, the records-only Courses split, the enrollment gate,
the consolidated Account page, the confirmed professor bottom bar, the
manual-attendance module). Nothing has been deleted; where a route's
name or grouping changed, the original name/reasoning is kept alongside
the update so the mapping is traceable.

## Entry (unauthenticated → authenticated hub)

Rendered, together with Enroll below, as steps inside one `SetupFlowScreen`
orchestrator for new users (`PROXIMITY_UI_REDESIGN.md` §3.3) — returning
users with state already on file skip straight to whichever step applies,
never re-walked through steps they've cleared.
- `welcome` (features/entry/welcome_screen) EXISTS — reason: value prop +
  sign-in in one glance, zero-tap story.
- `roles` (features/entry/role_hub_screen) EXISTS — reason: resume
  last-mode-first; register/add role on one Gmail.
- `device` (features/entry/device_identity_screen) EXISTS — reason: which
  Gmail vs which install, key presence, move status, trust tier. This is
  a pre-auth, one-time-per-install identity check — distinct from the
  in-app Account device section below, which is the same underlying facts
  read again later, on demand, once signed in.
  **HARD REQUIREMENT — folded into Account:** per the product owner,
  Account now absorbs this identity/device read (see the revised Account
  tab section below) rather than keeping two separate presentations of
  the same facts. This screen's *content* is unchanged and its one-time
  pre-auth check still happens (semantics frozen); only where the read
  surfaces changes. If the codebase has a real reason this needs to stay
  a blocking pre-auth screen rather than read-on-demand post-auth, flag
  that before removing the standalone route.

## Enroll (mobile-only; desktop/web records-only — no dead routes)

Rendered this pass as internal steps of one `SetupFlowScreen` orchestrator
(`PROXIMITY_UI_REDESIGN.md` §3.3), together with `welcome`/`roles`/`device`
above — six named states, one continuous flow, not six full pushes. Each
step below is still its own file/route for deep-linking and testing; the
orchestrator (stepper index, skip-ahead-for-returning-users, transitions)
lives in `screens/setup_flow_screen.dart`, each step's content is a
presentational widget in `features/setup/` — same `features/`↔`screens/`
split the rest of the app already follows, just applied one level down
inside a single screen instead of across a whole route table.
- `enroll/intro` REMOVED — standalone intro route deleted with the legacy
  bundle entry; SetupFlowScreen is the only enrollment flow. Pre-context
  (2 min, online once, 1-device rule) + account + device key now live as
  SetupFlow steps (Confirm device → Account & key), not a separate push.
- `enroll/capture` EXISTS — reason: continuous 5-angle face session
  (centre/left/right/up/down, one camera open, ML Kit pose-gated per
  angle), plugin-owned matching, fail-closed. The 5 angles are one
  reusable `AnglePrompt` widget cycled by the capture controller (redesign
  §4.7), not five hardcoded near-duplicate screens — the actual camera-
  session logic here is unchanged by the stepper wrapper.
  **Overlay:** single framing oval + orbiting beacon/comet + progress bar
  + prompt (redesign §6.2 as revised — the two-oval rule is superseded).
  Counts resolved: 5 angles per the capture controller
  (`faceEnrollSlots.length`).
  **HARD REQUIREMENT — entry:** this step is now also entered when a
  student opens Mark with no completed enrollment, not only from a fresh
  install (redesign §3.4).
- `enroll/result` EXISTS — reason: online claim outcome (done vs
  cooldown/install/offline/pipeline) with next step each.
  **Visual:** none — this is an error/status page, follows
  `PROXIMITY_UI_REDESIGN.md` §4.6 (every non-`done` outcome is paired with
  an explicit next step, no unexplained dead end), not a gradient/effect
  moment.
- Desktop enrollment UI REMOVED (not disabled): records-only devices render
  the blocked card only; entry points hidden; deep-links redirect to
  records guidance.

---

## Student shell — bottom bar (persistent, post-authentication)

Three destinations, per `PROXIMITY_UI_REDESIGN.md` §3.1: **Mark**,
**Courses**, **Account**. Everything below this line and above
"Professor" is reached from one of these three tabs; nothing in the
student shell is a fourth, hidden entry point.

**SUPERSEDED — label only:** this tab was `Records` in the original
map; it is labelled `Courses` now (redesign §3.1), and it is explicitly confirmed
**records-only** (redesign §3.1a) — no join/mark affordance renders here,
ever, even for a course with an open window. Routes stay `records/*`
(`records/mine`, `records/mine/<course>`). That affordance lives only
in `Mark` below.

### Mark tab (one continuation, phases not pages)

**HARD REQUIREMENT — entry guard:** tapping `Mark` with no completed
enrollment routes into `SetupFlowScreen` (Enroll section above), not the
browsing phase (redesign §3.4). Tapping `Mark` fully enrolled with no open
window lands on the `browsing` phase as below. Tapping `Mark` with an open
window for a joined class resumes directly into the
`waiting`/`faceCheck`/`listening` phases, unchanged. Mark has no named
routes — all phases below are in-tab view-states of the one Mark host
(`StudentPhase`: browsing/waiting/faceCheck/listening/marked/late/
wrongOrg/needsReview/noSignal/paused/manualPending).
- `browsing` — reason: discover (UDP beacons + BLE hints + typed
  IP) + join; degradation ladder + broadcast-blocked stated aloud.
  **Visual:** `effect.glow.live` behind the radar-sweep empty state
  (redesign §2.5, §6.1) — the one ambient effect that's allowed at rest,
  because it signals active scanning, not decoration. Typed IP is one
  field on browse (no separate join screen); surfaces as a
  `FallbackButton` → one-field sheet per redesign §4.4/§6.1, never inline.
- `waiting` — reason: park with presence heartbeat until the
  window opens; honest-unreachable stated, manual fallback offered.
  **Visual:** `effect.glow.live` behind the pulsing presence ring
  (redesign §2.5, §6.2).
- `faceCheck` — reason: single-shot holder check (zero-tap
  auto-scan, Scan fallback); inconclusive never burns, mismatch burns one.
  Static framing oval + one prompt line only (redesign §6.2 as revised).
  Transition in from `waiting` is the ring morphing into the camera
  frame (redesign §6.2), not a hard cut.
- `listening` — reason: radio wait with step status only (no
  countdown); clock-drift banner shown honestly.
- verdict (`marked`/`late`/`wrongOrg`/`noSignal`/`needsReview`) — reason: one outcome
  with per-round trail + next step.
  **Visual:** on `Marked` only — `gradient.marked` wash + `effect.glow.marked`,
  400ms, non-blocking, skippable (redesign §2.5, §6.3). Every other
  outcome is flat, per §4.6 (error states are actionable, not decorative).
  This is the single most gradient/glow-forward moment in the whole app,
  deliberately — see redesign principle 11.
- `manualPending` — reason: manual fallback branch (pending →
  approved/rejected) with professor contact path.

### Courses tab (student) — labelled `Courses`, HARD REQUIREMENT records-only
- `records/mine` EXISTS — reason: student's synced
  courses (course cards → sessions); offline shows last sync honestly
  (paired with a next step — "retry sync" — per redesign §4.6, not a bare
  "offline" label). **No join/mark affordance rendered here, ever** —
  even for a course with a currently-open window, per redesign §3.1a.
- `records/mine/<course>` EXISTS —
  reason: one student's course drill-down (sessions + totals).

### Account tab (student)
This section originally proposed redesigning the old single-scroll
Account into **a menu plus one focused page per topic**
(`PROXIMITY_UI_REDESIGN.md` §5, original). **SUPERSEDED twice since:**
first (per owner instruction) into **one consolidated page**, then by the
shipped submenus overhaul into a **menu root + one-feature pushes**
(`INTEGRATION_LOG.md` Account overhaul) — that final structure is what
ships. `account/face-id` stays its own route (reason below). The bullets
below describe the *content* of the sub-pages, not sections of one page:

- Account menu (tab landing page) — reason:
  identity header + pushes to Enrollment / Device / Appearance /
  Face ID / System log rows, plus sign-out.
  - **Enrollment push** — date enrolled, organization, trust tier badge
    (tapping it opens the plain-language explainer), re-enroll/move
    entry point when relevant.
  - **ID row** — roll/student-ID, editable with Save (write path exists:
    `CloudSync.updateStudentRoll` + uniqueness guard; directory-denied
    saves fail open).
  - **Device push** — device model, install status, move-cooldown date,
    "Move to this device" fallback; offline/hosting note.
  - `Appearance` — Dark/Light/System segmented control.
  - `System log` row — opens `debug/log` directly, unchanged.
  - `Sign out` — bottom of the menu, visually separated, unchanged.
  - **Visual:** subtle `gradient.brand` wash behind the header only
    (redesign §2.5, §4.3) — unchanged from the original proposal.
- `account/face-id` EXISTS, **stays its own route** (not folded in) —
  reason unchanged from the original proposal: enrollment status +
  re-scan fallback only; **never** renders a thumbnail, embedding, or
  preview of face data — `face_verification` output exists to match, not
  to decorate a screen (redesign principle 6). Kept separate specifically
  so this hard "never preview" rule can't accidentally inherit a stray
  image widget from the shared Account page layout.
- `account/enrollment` and `account/device` as standalone routes are
  **removed as separate pushes** — their content lives on the sub-pages
  above now. See "Removed / merged" below.

---

## Professor shell

**Bottom bar:** `Live` / `Courses` / `Account`, mirroring the student
shell's 3-tab pattern (§3.1) for consistency. **HARD REQUIREMENT —
confirmed, no longer proposed/unconfirmed:** this was originally flagged
as new, unconfirmed scope in this map, since neither the original map nor
`PROXIMITY_UI_REDESIGN.md` described a professor-side bottom bar. The
product owner has settled this as a hard requirement — the design
decision is closed. The Navigation-shell/Foundation agents still confirm
what nav structure actually exists in the current tree before
implementing (that caution is about *implementation state*, not whether
to build it). **HARD REQUIREMENT — records-only split:** `Courses` here
is explicitly records-only (redesign §3.1a) — no Start/Stop, no
host-setup entry anywhere in it; hosting is reached exclusively through
`Live`, below. The professor `Account` tab is **not** the same structure
as the student `account` page by default — professors don't enroll a
face, so `account/face-id` doesn't apply to them; scope that page's
contents fresh against what a professor actually needs (device/sign-out/
theme at minimum), don't just copy the student page.

### `live/<course>` (one host, focused sections — in-tab, not sub-routes)
- `live/<course>` EXISTS — reason: the mid-class always-on block (LIVE/
  IDLE, elapsed, present/waiting, Start⇄Stop cluster).
  **Visual:** header picks up `gradient.brand` while state is `LIVE`,
  flat `surface.raised` while `IDLE` (redesign §2.5, §7) — the one
  flourish given to the professor surface, because it directly answers
  "is this actually running."
- roster section — reason: waiting + present (intersection) +
  partial + search, readable mid-lecture without the control cluster.
- inbox section — reason: manual approvals where they happen
  (near top, bulk approve/reject via hold-and-tap, not checkboxes).
  **HARD REQUIREMENT:** backed by the `features/manual_attendance/`
  module (redesign §4.8) rather than owning bespoke approve/reject UI
  inline — one implementation shared with `add` below.
- add section — reason: direct add (directory search fills
  the same fields) without scrolling past the roster.
  **HARD REQUIREMENT:** also backed by `features/manual_attendance/`
  (redesign §4.8), the add-form half of the same module.
- **HARD REQUIREMENT — no shortcut from `Courses`:** nothing under
  `live/<course>` is reachable from the `Courses` tab
  (`prof/courses/<course>` may show a read-only "LIVE now" status chip,
  but tapping it never jumps into hosting) — redesign §3.1a. Extra URL
  suffixes (`live/<course>/*`) resolve as unknown (exact-shape guard).
- setup section — reason: hosting setup (name, IP pick,
  discovery assumptions) before Start.
- recover section — reason: draft recovery decision (recover
  vs archive-then-fresh), data never dropped; stays on the flow-
  orchestration host screen, not a features/ presentational split, since
  it owns the draft (see "Removed / merged" notes below).

### Courses tab (professor) — renamed from "Professor setup / records", HARD REQUIREMENT records-only
- `prof/courses` EXISTS — reason: pick or register a course; cloud
  pull-merge converges other devices. **No "Start hosting" affordance
  here** (redesign §3.1a) — registering a course is a different action
  from going live with one.
- `prof/courses/<course>` (overview) EXISTS — reason: manage one course
  (sessions, rename/delete, review/export). May show a read-only "LIVE
  now" status chip if that session is currently hosting; tapping it does
  not enter hosting controls.
- `prof/courses/<course>/export` EXISTS — reason: review + export the past
  (per-session CSV, date-range matrix).
- session detail (in-tab push from the course overview) — reason: one saved session
  with per-round ticks.
- session edit (in-tab push) — reason: fix marks later (per-round
  checkboxes — professor-side correction is the one legitimate checkbox
  use in the app, distinct from the hold-and-tap selection pattern used
  for bulk actions elsewhere; partial/absent quick lists, unified
  manual-add). Neither is a named route (`prof/sessions/<id>` deep-links
  resolve as unknown).

---

## Shared (reachable from every shell)
- `debug/log` EXISTS — reason: filterable full-screen terminal (NAV/SYNC/
  FACE/STATE/BLE/MESH/LAN/SEC/NET/TRANSPORT/CRYPTO/SESSION/CLOCK). Two
  entry points, per `PROXIMITY_UI_REDESIGN.md` §4.5: a contextual
  quick-peek drawer on whichever screen is actively logging something
  relevant, and the permanent `System log` row on the `account` menu
  (above) for on-demand access when nothing is currently logging. No
  third, inconsistent entry point anywhere else.

## Removed / merged (no dead routes)
- Typed-IP join lives on the browsing phase (no separate join screen —
  one field on browse; see Mark tab above).
- Desktop enrollment UI removed (see above).
- `MarkedBadge` (widgets/animated) removed — superseded by
  `ProxVerdictBadge` (one verdict language, elastic reserved for Marked).
- `BleLogView` (widgets/ble_log_view) removed — superseded by the
  full-screen debug log + embedded terminal contract (single log vocabulary).
- The old single-scroll `Account` page removed — superseded by the
  `account` menu + `account/enrollment` + `account/face-id` +
  `account/device` split above (no data or fact dropped, only regrouped;
  see `PROXIMITY_UI_REDESIGN.md` §5 and §11 for the migration note).
- **HARD REQUIREMENT — that same split is now itself superseded:**
  `account/enrollment` and `account/device` as standalone pushed routes
  are folded back into sections on the one consolidated `account` page
  (redesign §5, revised). `account/face-id` is the only sub-route that
  survives both rounds of restructuring. No fact from either the
  original scroll or the four-route split is dropped — only where it's
  read changes, again.
- `records/mine` / `records/course/<course>` **renamed** to
  `records/mine` / `records/mine/<course>`; tab labelled `Records` →
  `Courses` (redesign §3.1, routes unchanged). Same screens, same data.
- Standalone pre-auth `device` screen — **folded into `Account`**, not
  deleted as a function; its facts are now read from the same Account
  sections that read them post-auth on demand.
- Professor manual-attendance UI (`live/<course>/inbox`, `.../add`) now
  explicitly backed by one `features/manual_attendance/` module
  (redesign §4.8) instead of screen-local widgets — routes unchanged,
  implementation module boundary only.
- Legacy `screens/` hosts (student_home, take_attendance) keep flow
  orchestration (timers, drivers, drafts — behavior frozen); presentational
  sections live in features/ (one purpose per file); live section
  deep-links (`roster`/`inbox`/`add`/`setup`) land on focused screens
  reading the same host driver, `recover` stays on the host (it owns the
  draft); mark phases stay one continuation (phases, not pages).
