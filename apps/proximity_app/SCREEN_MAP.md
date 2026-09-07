# Proximity screen map (Track 5 rebuild — living doc)

One line per screen: what exists / merged / split / removed + one-line
reason to exist. Authority: end goals in the task brief (anti-proxy,
speed, fully-offline flow, UX-first, consistent + modular + documented,
smaller codebase). Mechanism (Track E transport) and Tracks 1–4 hard
requirements are preserved — restructuring only, no weakening.

## Entry (unauthenticated → authenticated hub)
- `welcome` (features/entry/welcome_screen) EXISTS — reason: value prop +
  sign-in in one glance, zero-tap story.
- `roles` (features/entry/role_hub_screen) EXISTS — reason: resume
  last-mode-first; register/add role on one Gmail.
- `device` (features/entry/device_identity_screen) EXISTS — reason: which
  Gmail vs which install, key presence, move status, trust tier.

## Enroll (mobile-only; desktop/web records-only — no dead routes)
- `enroll/intro` EXISTS — reason: pre-context (2 min, online once,
  1-device rule) + account + device key.
- `enroll/capture` EXISTS — reason: 3-still face capture (centre/left/
  right), plugin-owned matching, fail-closed.
- `enroll/result` EXISTS — reason: online claim outcome (done vs
  cooldown/install/offline/pipeline) with next step each.
- Desktop enrollment UI REMOVED (not disabled): records-only devices render
  the blocked card only; entry points hidden; deep-links redirect to
  records guidance.

## Student mark (one continuation, phases not pages)
- `mark/browse` EXISTS — reason: discover (UDP beacons + BLE hints + typed
  IP) + join; degradation ladder + broadcast-blocked stated aloud.
- `mark/join` MERGED into browse — reason: typed IP is one field on browse,
  not a separate screen (removes a hop mid-lecture).
- `mark/waiting` EXISTS — reason: park with presence heartbeat until the
  window opens; honest-unreachable stated, manual fallback offered.
- `mark/face` EXISTS — reason: single-shot holder check (zero-tap
  auto-scan, Scan fallback); inconclusive never burns, mismatch burns one.
- `mark/proving` EXISTS — reason: radio wait with step status only (no
  countdown); clock-drift banner shown honestly.
- `mark/verdict` EXISTS — reason: one outcome (marked/late/wrong-org/
  no-signal/needs-review) with per-round trail + next step.
- `mark/manual` EXISTS — reason: manual fallback branch (pending →
  approved/rejected) with professor contact path.

## Professor live (one host, focused sections)
- `live/<course>` EXISTS — reason: the mid-class always-on block (LIVE/
  IDLE, elapsed, present/waiting, Start⇄Stop cluster).
- `live/<course>/roster` SPLIT — reason: waiting + present (intersection) +
  partial + search, readable mid-lecture without the control cluster.
- `live/<course>/inbox` SPLIT — reason: manual approvals where they happen
  (near top, bulk approve/reject).
- `live/<course>/add` SPLIT — reason: direct add (directory search fills
  the same fields) without scrolling past the roster.
- `live/<course>/setup` SPLIT — reason: hosting setup (name, IP pick,
  discovery assumptions) before Start.
- `live/<course>/recover` SPLIT — reason: draft recovery decision (recover
  vs archive-then-fresh), data never dropped.

## Professor setup / records
- `prof/courses` EXISTS — reason: pick or register a course; cloud
  pull-merge converges other devices; flagged-devices entry lives here.
- `prof/courses/<course>` (overview) EXISTS — reason: manage one course
  (Take, sessions, rename/delete, review/export).
- `prof/courses/<course>/export` EXISTS — reason: review + export the past
  (per-session CSV, date-range matrix).
- `prof/sessions/<id>` (detail, read) EXISTS — reason: one saved session
  with per-round ticks.
- `prof/sessions/<id>/edit` EXISTS — reason: fix marks later (per-round
  checkboxes, partial/absent quick lists, unified manual-add).
- `prof/flagged` NEW (Track 5 required) — reason: professor/admin review
  list for attestationAnomaly-flagged devices (email/platform/claimed-vs-
  derived level/reason/verified-at/DKey fingerprint); no manual clear by
  design (re-verify clears, re-enroll resets).
- `records/mine` EXISTS — reason: student's synced courses (course cards →
  sessions); offline shows last sync honestly.
- `records/course/<course>` EXISTS — reason: one student's course drill-
  down (sessions + totals).

## Shared
- `debug/log` EXISTS — reason: filterable full-screen terminal (NAV/SYNC/
  FACE/STATE/BLE/MESH/LAN/SEC/NET/TRANSPORT/CRYPTO/SESSION/CLOCK).

## Removed / merged (no dead routes)
- `mark/join` merged into browse (see above).
- Desktop enrollment UI removed (see above).
- `MarkedBadge` (widgets/animated) removed — superseded by
  `ProxVerdictBadge` (one verdict language, elastic reserved for Marked).
- `BleLogView` (widgets/ble_log_view) removed — superseded by the
  full-screen debug log + embedded terminal contract (single log vocabulary).
- Legacy `screens/` hosts (student_home, take_attendance) thinned to flow
  coordinators; presentational sections live in features/ (one purpose per
  file); deep-links land on the right phase/section via initial args.
