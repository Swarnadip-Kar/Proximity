# Proximity — UI/UX Overhaul Design Document

Status: proposal, presentation-layer only.
Authority: this document restructures **presentation** — copy, layout, motion,
components, navigation, theming. It does not change identity, crypto, transport,
trust tiers, or verdict semantics defined in `PROXIMITY_DESIGN.md` / `README.md`.
Anywhere this doc is silent on behavior, existing behavior wins. Anywhere it
conflicts with `SCREEN_MAP.md` route structure, `SCREEN_MAP.md` wins on *what
screens exist*; this doc governs *how they look and feel*.

**This is now the single, merged version of this document.** It contains
the original proposal in full — nothing below has been deleted — plus a
set of product-owner hard requirements integrated directly into the
relevant sections (marked **HARD REQUIREMENT** inline) and several new
sections added where the owner's instructions introduced structure the
original proposal didn't cover. Wherever a HARD REQUIREMENT marker
conflicts with older text nearby, the HARD REQUIREMENT wins — that
precedence is itself a hard requirement, not a judgment call left open
for a subagent to weigh. Sections with no such marker are unchanged from
the original proposal and carry the same authority they always did.

Non-negotiables carried over from the source docs (do not relitigate these
while doing visual work):
- Fail-closed face gate, single-shot marking, inconclusive-never-burns /
  mismatch-burns-one.
- No countdown during proving windows — status only.
- IP join / manual add / BLE hint are **fallback paths**, never the default
  affordance on the primary screen.
- Records-only builds hide native-only actions (Take attendance, retake,
  rename/delete, offline professor, enrollment) behind the existing banner —
  this redesign must not surface hidden affordances on web.
- No new dead routes. No new checkbox UI anywhere selection occurs.

---

## 1. Principles

1. **One primary action per screen.** Everything else is secondary weight or
   a fallback tucked behind a button/sheet.
2. **No unessential text.** If a label can be inferred from icon + position +
   context, delete it. Error and status copy stays terse and specific
   (existing verdict language is preserved verbatim — `marked / late /
   wrong-org / no-signal / needs-review` etc. — only chrome around it changes).
3. **Same shapes everywhere.** One `StudentCard`, one `VerdictBadge`, one
   `AccountChip`, one bottom-sheet fallback pattern, reused on every screen
   instead of screen-local variants.
4. **Hold-and-tap replaces checkboxes, everywhere, with no exception.**
   Tap = navigate/act on one item. Long-press = enter selection mode for
   that list; subsequent taps toggle membership; a second long-press or the
   system back gesture exits selection mode. Selection-mode state is scoped
   per list, never global.
5. **Screens can be regrouped — merged *or* split — routes cannot be
   invented or dropped.** Where several `SCREEN_MAP.md` screens describe
   one continuous user intent (e.g. sign-in → role → device → enroll),
   they may render as a single serialized flow with internal steps instead
   of separate full pushes — see §3.3. Conversely, where one screen has
   grown several unrelated static facts stacked in a scroll (account
   identity, enrollment status, face-ID status, device danger-zone), it
   should be *split* into a short menu plus one focused page per topic so
   each is read on its own — see §5. Either direction is layout
   consolidation, not route removal: every named screen in `SCREEN_MAP.md`
   still has an addressable state/step, so deep-links and the "no dead
   routes" rule still hold either way.
6. **Face data never becomes UI decoration.** The `face_verification`
   plugin's stills/embeddings exist for one purpose — matching — and never
   surface as an avatar, thumbnail, or preview anywhere in the product.
   Avatars are either the Google account's own OAuth profile photo (with
   the small Gmail badge, §4.3) — which is ordinary account metadata, not
   `face_verification` output, and is the one accepted source for a "real
   photo" avatar anywhere in the app — or a deterministic initials avatar
   when no Google photo is set. There is no code path in this redesign
   that reads from the face gallery for display, full stop, no exception.
7. **Every error is actionable.** An error state without a next step is
   incomplete — see §4.6.
8. **The debug log is a first-class, discoverable feature, not a hidden
   dev toggle.** See §4.5 for its one consistent entry point.
9. **Motion explains state change, it doesn't decorate.** A card doesn't
   bounce because animation is fun; it bounces because it just became
   `Marked` and the elastic reserved-for-Marked motion (already specified in
   `SCREEN_MAP.md`) is the signal.
10. **The attendance-marking screen carries the most UI weight in the app.**
    Everything else is comparatively plain. See §6.
11. **Gradients and glow are meaning-bearing accents, not global chrome.**
    The default surface is flat (§2.1). A gradient or glow effect earns its
    place the same way motion does (principle 9): it marks *the* highest-
    weight moment on a screen — the primary CTA, the live/active state, the
    one verdict that's worth celebrating — not every card, button, and app
    bar by default. See §2.5 for the token set and §4/§6 for where each one
    is actually used.
12. **HARD REQUIREMENT — three modes, one job each, applied at the tab
    level.** The app is Mark (or `Live`, professor) / Courses / Account,
    and "one primary action per screen" (principle 1) is extended to
    "one primary action per *tab*." Courses is records-only on both
    shells — no hosting/marking shortcut ever lives there, even as a
    convenience. See §3.1a.
13. **HARD REQUIREMENT — no unenrolled student ever sees a bare Mark
    screen.** Selecting Student mode / opening Mark with no completed
    enrollment routes straight into the setup flow, not `mark/browse`.
    See §3.4.
14. **Text minimalism is a component, not a guideline.** Principle 2's
    "no unessential text" and the error/detail patterns in §4.6/§9 are
    formalized into one shared `DetailsExpander` widget so every screen
    collapses secondary explanation by default instead of each author
    re-deciding what counts as unessential. See §4.7.
15. **Manual attendance is an isolated module.** The professor-side
    approve/reject/add flow is its own `features/manual_attendance/`
    module, composed into `live/<course>/inbox` and `.../add` rather than
    living as screen-local UI in either. See §4.8.

---

## 2. Design tokens

### 2.1 Color — Dark (default) / Light

Use semantic tokens, not raw hex, throughout the codebase (`ThemeExtension`
in Flutter). Suggested values:

| Token | Dark | Light | Use |
|---|---|---|---|
| `surface.base` | `#0B0D10` | `#FAFAFA` | Scaffold background |
| `surface.raised` | `#15181D` | `#FFFFFF` | Cards, sheets |
| `surface.overlay` | `#1D2128` | `#F0F1F3` | Selection-mode card bg |
| `content.primary` | `#F2F3F5` | `#14161A` | Titles, IDs |
| `content.secondary` | `#9AA0AA` | `#5B6270` | Metadata, timestamps |
| `content.tertiary` | `#5C626C` | `#9AA0AA` | Disabled, placeholder |
| `accent.brand` | `#5B8CFF` | `#3A63E0` | Primary CTA, active tab (flat contexts; see `gradient.brand`, §2.5, for the CTA fill upgrade) |
| `status.marked` | `#33C77A` | `#1E9A5C` | Present / verified |
| `status.late` | `#E0B23A` | `#B4870F` | Late |
| `status.review` | `#E0833A` | `#C4661A` | Needs-review / manual pending |
| `status.error` | `#E85D5D` | `#C43E3E` | Wrong-org / no-signal / burned attempt |
| `divider` | `#22262D` @ 60% | `#000000` @ 8% | Hairlines |

Both themes ship at parity — no theme is a stripped-down afterthought. Follow
system theme by default, override in Account tab.

### 2.2 Typography

Single family, 3 weights only (Regular/Medium/Semibold). Scale:
`display 28/34`, `title 20/26`, `body 15/22`, `label 13/16`, `caption 11/14`.
IDs, tokens, hex, and log output use a monospace face at `body`/`caption`
size — this is the *only* place monospace appears (the debug terminal and
any short code/ID string, e.g. faceId prefix, install ID tail, IP address).

### 2.3 Spacing & radius

8pt grid. Card radius `16`, sheet radius `24` (top corners only), chip/badge
radius `999` (pill). Screen horizontal margin `20`. Card internal padding
`16`. Minimum tap target `48×48` regardless of visual size (hold-and-tap
targets need generous hitboxes since long-press timing is unforgiving on
small chips).

### 2.4 Iconography

One icon set, outlined by default, filled on active/selected state. No mixed
icon families. Status uses color + shape (dot / check / clock / triangle),
never color alone (see §9 accessibility).

### 2.5 Gradients & effects

Flat surfaces stay flat (§2.1) almost everywhere — this section exists to
name the small, specific set of places gradients/glow/blur *are* worth
using, and to stop each screen author from inventing their own. Every
gradient below is a token on the same `ThemeExtension`, dark/light pair,
never a one-off `LinearGradient(...)` hand-authored inline on a screen.

| Token | Dark | Light | Use |
|---|---|---|---|
| `gradient.brand` | `#5B8CFF → #8F6BFF`, 135° | `#3A63E0 → #6A4FD9`, 135° | Primary CTA fill (one per screen, §1.1), active `Live` state header |
| `gradient.marked` | `#33C77A → #2FE0A0`, 120° | `#1E9A5C → #22B87E`, 120° | The one-shot verdict color-wash in §6.3, and only there |
| `gradient.scrim` | `#0B0D10 @0% → #0B0D10 @72%` | `#14161A @0% → #14161A @55%` | Bottom-sheet/modal scrim, image-caption legibility overlay (session thumbnails, if any) |
| `effect.glow.live` | `accent.brand` blur `24`, 24% opacity | `accent.brand` blur `16`, 14% opacity | Soft halo behind the pulsing presence ring (`mark/waiting`) and the radar-sweep empty state (`mark/browse`) — reinforces "this is actively working," not static |
| `effect.glow.marked` | `status.marked` blur `32`, 30% opacity, fades over 400ms | `status.marked` blur `20`, 18% opacity, fades over 400ms | Rides along with `gradient.marked`'s wash in §6.3 — one glow, same event, never triggered independently |
| `effect.elevation.raised` | shadow `0 1 2 rgba(0,0,0,0.4)` | shadow `0 1 2 rgba(0,0,0,0.08)` | `surface.raised` cards/sheets — a hairline lift, not a drop-shadow floating look |
| `effect.elevation.sheet` | shadow `0 -2 12 rgba(0,0,0,0.5)` | shadow `0 -2 12 rgba(0,0,0,0.1)` | Bottom sheets only, paired with `gradient.scrim` behind them |

Where each one actually appears (exhaustive — if it's not on this list, it
doesn't get a gradient):

- **`AccountChip` header background (§4.3), large size only** — a very
  subtle `gradient.brand` wash behind the avatar on the Account menu header
  (§5.1), full-bleed to the screen edges, low enough contrast that
  `content.primary` text sitting on it still passes contrast checks (§9).
  Nowhere else does `AccountChip` get a background treatment — the small
  inline version (device screen, role hub) stays flat, this is a "you've
  arrived at your own page" accent, not a component default.
- **Primary CTA buttons** — `gradient.brand` fill, replacing a flat
  `accent.brand` fill, but still *one per screen* (principle 1) — secondary
  buttons and `FallbackButton`s (§4.4) stay flat/outlined, so the gradient
  keeps meaning "this is the one thing to tap."
- **`live/<course>` header, while `LIVE`** — the fixed control-cluster
  header (§7) picks up `gradient.brand` only in the `LIVE` state; `IDLE`
  stays flat `surface.raised`. This is the professor-side equivalent of
  the student presence-ring glow: gradient = "this is currently running."
- **`mark/waiting` presence ring + `mark/browse` radar-sweep empty state**
  — `effect.glow.live` behind the ring/sweep animation already specified
  in §6.1/§6.2. The glow rides on the same ambient loop, it isn't a
  separate effect layered on top; under reduce-motion it's dropped to a
  static soft halo, never fully removed (removing it would make the ring
  look inert rather than "connected").
- **`mark/verdict` → `Marked` wash (§6.3)** — upgrade the flat
  `status.marked` color-wash already specified there to `gradient.marked` +
  `effect.glow.marked` together, same 400ms non-blocking skippable timing,
  same single-use rule (this exact combination never appears anywhere
  else in the app — that's what keeps it meaningful the one time it fires).
- **Bottom sheets (§3.2, §6.4)** — `gradient.scrim` behind,
  `effect.elevation.sheet` on the sheet itself. This is the one place a
  shadow is allowed to read as "floating," because a sheet genuinely is
  temporary/overlaid content.
- **Cards and list rows** — flat `surface.raised` + `effect.elevation.raised`
  only (a 1–2dp hairline lift so cards read as separate from the
  background on both themes), never a gradient fill. `StudentCard`,
  `VerdictBadge` (non-Marked states), and every list tile stay flat — this
  is what keeps the gradient/glow moments above legible as "special."

Everything in this table degrades under reduce-motion/reduce-transparency
exactly like §9 already requires for animation: glows collapse to their
static halo (no pulse/fade), the `Marked` gradient+glow combo becomes a
flat `status.marked` fill with no fade-in, scrims/elevation are unaffected
(they're not motion). No gradient or glow is ever the *only* signal for a
state — color-plus-shape (§2.4, §9) still carries the meaning; the effect
is reinforcement, not the message itself.

---

## 3. Navigation shell

### 3.1 Bottom bar (3 destinations, persistent on authenticated student shell)

`Mark` · `Courses` · `Account`

**HARD REQUIREMENT — rename:** this tab was originally proposed as
`Records`; it is renamed **`Courses`** here (and throughout this document
and `SCREEN_MAP.md`) to read the same way on both shells and to make
explicit the tab's one job is "look at a course," not merely "see a list."
Routes rename accordingly: `records/mine` → `courses/mine`,
`records/course/<course>` → `courses/course/<course>`. This is a rename +
scope clarification, not a new route — see §3.1a and §8.

- **Mark** — icon: proximity/radar glyph. Lands on `mark/browse` or, if a
  window is currently open for a joined class, resumes directly into
  `mark/waiting` / `mark/face` / `mark/proving` (no re-browse on relaunch
  mid-session — matches existing autosave/resume behavior). **If the
  student has not completed enrollment, Mark does not land on
  `mark/browse` at all — see the enrollment gate, §3.4.**
- **Courses** — icon: layered cards/stack. Lands on `courses/mine`.
  **HARD REQUIREMENT: records-only, see §3.1a.**
- **Account** — icon slot is **not a generic icon** — it renders the
  signed-in Gmail account's avatar/initial inside the tab itself (see §5.1).
  This is the one nav item that's a live photo, not a glyph.

Professor shell uses the same 3-slot bar: **`Live` · `Courses` ·
`Account`**. This is now **confirmed, not proposed** — an earlier version
of `SCREEN_MAP.md` flagged this bar as unconfirmed scope; the product
owner has settled it as a hard requirement. Implementers still confirm
*what currently exists in the codebase* before assuming the bar is
already wired (that caution is about implementation state, not the design
decision, which is closed). `Live` carries the same "highest weight,
last-built" treatment for the professor side that `Mark` gets for the
student side — see §7.

#### 3.1a Courses tab is records-only — no live controls, ever

**HARD REQUIREMENT**, both shells:

- **Student `Courses`:** `courses/mine` → `courses/course/<course>`. No
  entry point into `Mark` from here, and no "join now" affordance on a
  course card even when that course currently has an open window — that
  affordance lives only in `Mark`.
- **Professor `Courses`:** `prof/courses` → `prof/courses/<course>` →
  `prof/sessions/<id>` → `prof/sessions/<id>/edit` + `export`. **No
  Start/Stop, no "go live," no host-setup entry anywhere in this tab.**
  Hosting is reached exclusively through `Live`. `prof/courses/<course>`
  may show a **read-only** "LIVE now" status chip, but tapping it does
  not jump into hosting controls — it's information, not a shortcut
  around the tab boundary.
- `live/<course>` and everything under it (`roster`, `inbox`, `add`,
  `setup`, `recover`) is owned entirely by the `Live` tab. See §7.

Deep-links to `live/<course>/*` and `mark/*` still work exactly as before
— no dead routes, this is a tab-*placement* decision, not a route
removal. The point: viewed on its own, `Courses` answers exactly one
question ("what happened / what's my status") and never becomes a second
on-ramp into the primary action.

Bar behavior:
- Elevates 2dp above `surface.base` with a hairline top divider, not a hard
  shadow.
- Active tab: filled icon + label, `accent.brand`. Inactive: outlined icon,
  label hidden below a width breakpoint (icon-only on narrow devices — see
  §10).
- Switching tabs cross-fades content (120ms) with a 4dp vertical settle on
  the incoming tab's icon — no full-screen slide between bottom-bar
  destinations (slides are reserved for push navigation, see §4).
- Badge dot (no number) on `Records` when a new session posts while the app
  was backgrounded; clears on tab open.

### 3.2 Push navigation transitions

- **Forward (drill into a screen):** shared-axis horizontal slide, 220ms,
  standard easing, outgoing screen fades to 60% opacity and scales to 0.98
  concurrently (depth cue, not a hard cut).
- **Sheet-style fallbacks** (IP entry, manual add, filters — see §6.4):
  bottom sheet, 200ms spring, drag-to-dismiss enabled, scrim fades in
  parallel.
- **Verdict arrival** (`mark/proving` → `mark/verdict`): this is not a
  generic push. See §6.3.
- **Back gesture / system back:** reverses the forward transition exactly;
  never a different animation than its forward pair.
- Respect `prefers-reduced-motion` / platform reduce-motion setting by
  collapsing all of the above to opacity-only cross-fades at 100ms.

### 3.3 Serialized entry + enrollment flow

Today `welcome` → `roles` → `device` → `enroll/intro` → `enroll/capture` →
`enroll/result` are six separate routes, each a full push. For a brand-new
student these are not six independent decisions, they're one continuous
setup — so present them as **one serialized flow** with a persistent step
indicator, instead of six discrete screens each with their own transition
weight:

- A single `SetupFlowScreen` hosts an internal `PageView`/stepper. Steps:
  `Sign in → Pick role → Confirm device → About to enroll → Capture face → Done`.
  Forward motion is a horizontal step-slide *inside* this one screen
  (150ms, lighter than the app's normal push transition — these are steps,
  not destinations); back moves the same way in reverse.
- Each step still corresponds 1:1 to an existing `SCREEN_MAP.md` entry —
  this is a container change, not a removal. `enroll/capture`'s own
  internal camera-session logic is untouched; it simply renders inside the
  shared stepper chrome instead of owning a full separate scaffold.
- **Returning users skip straight past steps that don't apply** (an
  already-signed-in student with a device on file lands directly on
  `roles`/mode-resume, never re-walked through steps 1–3) — the stepper
  computes its starting index from existing state, it does not force
  users through steps they've already cleared.
- The step indicator itself is minimal: a thin progress line at the top,
  no numbered circles, no step labels visible except the current one's
  title in the app bar — keeps with "no unessential text."
- `device` (identity/key/trust-tier display) and the pre-capture context in
  `enroll/intro` are naturally adjacent reads for the user — they can share
  one step screen (single scroll, key facts then a "Continue" CTA) rather
  than two full pushes, since neither requires independent input, only
  acknowledgement.
- This same serialized pattern is *not* applied to the in-class marking
  flow (§6) — marking is state-driven and radio-driven, not a linear form,
  so it keeps its existing screen-per-phase structure. Serialization is
  reserved for onboarding, which genuinely is a linear wizard.
- **HARD REQUIREMENT — widened entry trigger:** this flow is now entered
  from two places, not one — the normal fresh-install path, *and*
  whenever a student selects Student mode / opens `Mark` with no
  completed enrollment on file (§3.4). Same flow either way; there is
  exactly one setup flow, two triggers.

### 3.4 Enrollment gate on the Mark tab — HARD REQUIREMENT

A student who has **not** completed enrollment must never land on
`mark/browse` (or any bare Mark screen). Selecting Student mode / tapping
`Mark` for the first time with no completed enrollment routes directly
into `SetupFlowScreen` (§3.3), resuming from whichever step is
incomplete, exactly like a brand-new install. On completion, the flow
lands the student on `mark/browse` (or resumes an in-progress window,
per existing behavior) — never back on `roles`/RoleHub.

**Open gap, flagged rather than resolved here:** none of the source
documents state *where* this check happens or what "not enrolled" means
as a concrete state (no device claim on file? no face-gallery entries?
claim exists but `enroll/result` never reached success?). The
Navigation-shell/Foundation implementer must:
1. Locate the existing enrollment-status signal the app already uses
   somewhere — it must exist, since `roles`/RoleHub already does
   last-mode-first resume per `README.md`, so *some* signal already
   distinguishes enrolled vs. not — and
2. Wire the **same** signal as the Mark-tab guard rather than inventing a
   new enrollment-detection mechanism. If no single existing signal
   covers this cleanly, that is a real gap — surface it rather than
   guess.

This guard is routing-only — it does not change what "enrolled" means or
any claim/retry semantics.

### 3.5 Navigation, tabs, and back behavior — HARD REQUIREMENT

- Both shells use `IndexedStack` (or equivalent) for the 3-tab body so
  each tab preserves its own navigation stack and scroll position when
  switching tabs — switching tabs is never a rebuild.
- **In-tab back** pops that tab's own sub-page stack only. It never
  crosses tabs and never leaves the shell.
- **Tab-root back** (back pressed with no sub-page open on the current
  tab) never exits the app shell and never silently ends a live session:
  - If `Mark` currently has an open window (`waiting`/`face`/`proving`)
    or `Live` currently has an active hosting session, tab-root back does
    nothing except perhaps a platform-standard "press back again to
    leave the app" hint — it must never silently tear down a live window
    as a side effect of navigation. Ending a session is only ever the
    result of an explicit `Leave`/`End` action inside that screen.
  - From an in-progress `SetupFlowScreen` step, back moves one step
    backward inside the stepper (already specified in §3.3 internally);
    back from the *first* step goes to `Account`/RoleHub, **never** to a
    bare/unenrolled `mark/browse` (which would contradict §3.4).
- **Remove the old `PopScope` → `setMode(unset)` exit pattern** wherever
  it exists in the current codebase. Explicit deletion instruction, not
  "leave it if it still works" — it is the mechanism most likely to be
  silently ending live sessions via back-navigation today. Removing it is
  presentation/navigation-layer work; it does not touch the underlying
  timer/driver/session logic it currently interrupts.

---

## 4. Core reusable components

Build these once in a shared `widgets/` layer and use everywhere — this is
the actual "refactor" surface. Screens compose these; they do not
reimplement card/list/badge layout locally.

### 4.1 `StudentCard` (the one card shape, used on rosters, waiting lists,
inbox, manual-add results, records)

Fixed layout, three lines max:
```
[avatar]  Name                         [status]
          ID · Email (truncated)
          (optional) round trail: R1 ✓ · R2 ✗
```
- Avatar: **initials on a deterministic color from name hash — never
  anything derived from `face_verification` data.** The plugin's stills and
  FaceNet embeddings exist solely to produce a match ticket; they are never
  read back out for display, on this card or anywhere else in the app.
  This applies even on the viewer's own `StudentCard`-style row in the
  Account tab (§5) — same initials-avatar rule, no exception for "it's my
  own face."
- Status slot: `VerdictBadge` (pill, see 4.2) right-aligned, vertically
  centered on line 1.
- Round trail (only shown where the existing data model has rounds —
  professor roster / student marked-late cards) renders as small pill chips,
  not raw text like today — same information, componentized.
- **No checkbox ever renders on this card.** Selection state is a full-card
  affordance: long-press → card scales to 0.96 with a 12ms haptic tick and a
  filled ring appears around the avatar; subsequent taps toggle the ring on
  any card in that list. A selection toolbar slides up from the bottom
  ("Approve N · Reject N · Select all · Cancel") replacing the bottom bar
  temporarily on screens that have one (inbox, sessions list for
  multi-delete).
- One `StudentCard` widget serves: professor roster, inbox, manual-add
  results, session multi-delete list, records session tiles (reduced
  variant, name/email replaced by session date/summary — same shell).

### 4.2 `VerdictBadge`

Pill, icon + short word, color from `status.*` tokens. Exhaustive set,
copied verbatim from existing verdict vocabulary — this component only
standardizes rendering, never invents new states:
`Marked` (status.marked, check), `Late` (status.late, clock),
`Wrong org` (status.error, triangle), `No signal` (status.error, slash),
`Needs review` (status.review, flag), `Waiting` (content.secondary, dot),
`Pending` (status.review, dot-pulsing — animated only while actually
pending). This supersedes the old `MarkedBadge` widget per
`SCREEN_MAP.md` — the elastic "just marked" motion lives *inside*
`VerdictBadge` as a transition-in animation when its state flips to
`Marked`, not as a separate widget.

### 4.3 `AccountChip` (the Gmail card)

Used in the Account tab header and anywhere account identity needs
showing (device screen, role hub). Shows the Google account's own
avatar/photo circle with **the Gmail logo as a small badge overlapping the
bottom-right of the avatar** (16dp, white circle backing so it reads on any
photo), display name, email — no other chrome, no card border, sits
directly on `surface.base`. At large size on the Account menu header
(§5.1) only, it sits on a subtle `gradient.brand` wash per §2.5 — every
other placement (device screen, role hub) stays flat, no background
treatment.

### 4.4 `FallbackButton` pattern

Any path that is a fallback (manual IP entry, manual attendance request,
directory manual-add, Bluetooth-off prompt) renders as a **single
low-emphasis text button or icon button**, never a full-width primary
button, never inline form fields on the main screen. Tapping opens a
bottom sheet containing the actual field(s). See §6.4 for the concrete
placements. This is the direct fix for "IP section is a fallback, not part
of the main flow."

### 4.5 System log terminal — placement

Data contract unchanged (`BleLog` stream, same tags: `BLE/MESH/LAN/SEC/NET/
SYNC/CLOCK` etc.). This is a real debugging feature, so it gets **one
consistent, always-findable entry point**, not a hidden gesture:

- **Global entry point:** a small terminal-glyph icon in the app bar of
  every screen that is actually producing log activity right now — per
  `README.md` that's the student browsing/waiting/face/proving screens and
  the professor `live/<course>` screen. The icon only appears where there's
  something to show (no dead icon on static screens like Records).
- Tapping it opens the **collapsible drawer** from the bottom edge (peek
  height ~30% of screen, draggable to full height) — monospace, autoscroll,
  tag chips colored by category from the `status.*`/`accent.brand`
  family, live while the drawer is open, still writing to the ring buffer
  while closed.
- **`debug/log` remains the dedicated, filterable, full-screen view**
  (per `SCREEN_MAP.md`) for a deliberate deep-dive session — reached from
  the drawer's "Expand" action, *and* from its own top-level `System log`
  row on the Account menu (§5.1) so it's discoverable even when nothing is
  currently logging. This is the "right place": contextual quick-peek
  where the activity is happening, plus one permanent, always-reachable
  entry point in Account for when a student/professor wants it on demand —
  now a first-class menu row rather than something to scroll down to.
- The drawer never blocks the primary content or radio-facing UI beneath
  it (§6 proving/face screens keep listening while the drawer is open —
  it's an overlay, not a route push, so no navigation/lifecycle
  interruption occurs).

### 4.6 Error states — always paired with a suggestion

One `ErrorState` component, two renderings, both required to carry a
specific next step (never a bare "Something went wrong"):

- **Inline/banner** — thin, dismissible, top-of-screen, for recoverable or
  non-blocking conditions (matches the existing honest-banner pattern for
  things like broadcast-blocked, stale sync, rules-denied search).
- **Blocking/sheet** — for conditions that stop the current action (camera
  permission denied, Bluetooth off outside the existing inline prompt,
  claim/enrollment refusal), rendered as a bottom sheet with icon, one-line
  cause, and 1–2 concrete actions as buttons — never just an "OK" dismiss
  with no path forward.

### 4.7 `DetailsExpander` — HARD REQUIREMENT, text minimalism as a component

Build one shared `DetailsExpander` widget: collapsed by default, shows a
single disclosure row ("Details"), expands in place to reveal secondary
explanation copy that today sits inline (discovery/ladder explanations,
org/trust-tier prose, sync mechanics, offline/hosting notes). Every
screen that currently has more than the terse status + next-action line
uses this component instead of inline paragraphs. Rules:
- Default (collapsed) view is status + next action only — this is the
  actual "too much text" fix, not a restyle of the existing paragraphs.
- Widget-test-relevant copy (`Start`, `Join`, `Marked`, field keys, exact
  verdict strings) stays exactly as-is and is never moved inside the
  expander — only *explanatory* prose (the "why"/"how it works" copy) is
  collapsible.
- A `DetailsExpander` may simply link out to `debug/log` instead of
  containing its own prose, when the underlying detail really is log
  data rather than user-facing explanation.
- Applies wherever this document already gestured at "collapsed"/
  "caption" framing (Courses tab offline note, §8; `account`'s trust-tier
  explainer, §5.1; professor directory rules-denied banner, §4.6) — those
  become instances of this one component instead of one-off treatments.

### 4.8 Manual attendance — its own module — HARD REQUIREMENT

Professor manual attendance (`live/<course>/inbox` for approve/reject,
plus the manual-add path referenced from `live/<course>/add`) becomes an
isolated feature module: `features/manual_attendance/` — its own
widgets, its own selection-mode provider instance (scoped to that list
only, per the per-list-selection rule above), imported by `Live`'s
`inbox` and `add` routes rather than those routes owning bespoke
manual-attendance UI inline. This is a code-organization instruction
(module boundary), not a route change — `live/<course>/inbox` and
`live/<course>/add` still exist exactly where `SCREEN_MAP.md` puts them;
they now *compose* the manual-attendance module instead of each
hand-rolling their own approve/reject or add-form UI. Same-severity
requirement as the shared `widgets/` layer in §11: one implementation,
imported everywhere it's needed, not duplicated.

Every error surface in the app maps existing source-of-truth messaging
onto this shape without changing the wording, only the presentation:

| Condition (existing behavior/message, unchanged) | Rendering | Suggested action(s) shown |
|---|---|---|
| Camera / Bluetooth permission denied | Blocking sheet | `Open settings` |
| Bluetooth off | Inline banner (per §6.4) | `Turn on` |
| Wrong-org verdict | `VerdictBadge` + one line (already specified) | none needed — verdict is terminal, not recoverable by the student |
| No-signal / dead-air timeout | `VerdictBadge` + next-window guidance | `Try next round` / manual fallback button |
| Directory search rules-denied | Inline banner | `Redeploy needed` text exactly as today (professor-facing, informational) |
| Directory search: empty result | Inline, non-error tone (not `status.error`) | "No matches" stated plainly, not styled as a failure |
| Offline queue (manual add queued) | Inline banner, `status.review` tone | "Will apply when back online" — no action needed, informational |
| Second-device / re-enroll refusal | Blocking sheet | exact re-enroll date + last-online day, verbatim from existing copy |
| Network timeout on a POST/window fetch | Inline banner | `Retry` (next rotation already retries automatically per existing behavior — button surfaces manual retry for impatience, doesn't change the retry logic) |
| Face capture: unreadable frame (inconclusive) | In-frame color pulse, not a sheet (must not block the still-listening radio) | "Hold still, retrying" — automatic, no user action |
| Face capture: 4 mismatch sessions → needs-review | Blocking sheet only at that terminal point | "Ask your professor to review" |

No condition in this table changes when it fires or what it means — the
table only fixes *how* it's shown and confirms every row has a next step.

---

## 5. Account tab (student)

**HARD REQUIREMENT — revised structure.** This section originally proposed
a menu-plus-four-full-pages layout (`account` menu → `account/enrollment`,
`account/face-id`, `account/device` as separate pushes). The product
owner's explicit instruction is that Account should be **one consolidated
page** owning: signed-in profile header, enrollment status + re-enroll
entry, ID edit, device key (short form) + move status, offline/hosting
note (collapsed), Switch account (sign out), System log — absorbing the
old pre-auth `device`/identity read into the same fact set, with `roles`
reduced to a pure role-picker. That pulls against the original "one
question per page" reasoning above (which is *why* this document proposed
the split in the first place) — this is resolved below by keeping the
whole thing as one page, sectioned, with `DetailsExpander` (§4.7) doing
the "don't show everything at once" job that separate pushed pages used
to do, **except** for Face ID, which keeps its own separate page for a
reason that still holds (see 5.2). Nothing in the original content below
is dropped — every fact from the old `account/enrollment` and
`account/device` sub-pages is still here, just laid out as sections on
one page instead of destinations behind a menu.

### 5.1 `account` (one sectioned page, the tab's landing page)

- **Header** — `AccountChip` at large size (56dp avatar), Gmail OAuth
  photo (§4.3, §1 principle 6 — never `face_verification` output),
  tapped nowhere (identity display only, not a button). Sits on the
  subtle `gradient.brand` wash per §2.5.
- **Enrollment** section — `Date enrolled`, `Organization`, `Trust tier`
  (FULL/STD/STALE/NONE, `VerdictBadge`-style pill; tapping it opens a
  one-paragraph plain-language explainer via `DetailsExpander`, §4.7,
  rather than a separate sheet route) plus a re-enroll/move entry point
  shown inline as a row when relevant. This is the full content of the
  original `account/enrollment` page, now a section instead of a push.
- **ID** row — roll/student-ID, editable. **HARD REQUIREMENT, flagged for
  verification, not an assumption to build blind:** if the current data
  model treats this ID as immutable (resolved once from directory/claim
  data, never written back), exposing an edit control here is new
  business logic, not a presentation change, and is out of scope for a
  presentation-only pass. Check whether a write path already exists
  server-side before wiring the control; if it doesn't, render the row
  read-only and report the gap.
- **Device** section — device model, install status (Active /
  Move-cooldown-until-`<date>`), abbreviated key facts, `Move to this
  device` fallback when eligible (else the exact re-enroll date,
  verbatim). This is the full content of the original `account/device`
  page, now a section instead of a push. The offline/hosting note goes
  inside this section's `DetailsExpander`, collapsed by default.
- `System log` — row that opens `debug/log` directly (the permanent,
  always-reachable home for the log described in §4.5).
- `Theme` — Dark/Light/System 3-way segmented control, inline on this row
  (the one row that's a control, not a push — no reason to spend a whole
  page on three options).
- `Sign out` — small text action, bottom of the page, separated by extra
  spacing so it doesn't sit shoulder-to-shoulder with normal sections.
- No unessential copy anywhere on this page: every section is `label` +
  value by default, descriptive paragraphs live behind `DetailsExpander`
  (§4.7), not inline. The page is expected to need scrolling on a
  standard device given how much it now owns on one page — that's an
  accepted tradeoff of consolidating, unlike the original per-page design
  which avoided scrolling by splitting.

### 5.2 `account/face-id` — stays a separate pushed page

Unlike Enrollment and Device above, Face ID keeps its own route rather
than folding into the one-page layout. Reason: this page carries a hard
"never render a preview" rule (principle 6) that is worth isolating from
the rest of Account so it can't accidentally inherit a stray image widget
from a shared section layout. Content unchanged from the original
proposal: status line only (`Enrolled · verifier v0.3.9` or `Needs
re-face` if version mismatch), a `Re-scan face` fallback button (low
emphasis — rare, not primary), and — critically — **no thumbnail, no
embedding, no preview ever rendered**, consistent with "embeddings never
leave the device." This page never grows a second purpose.

### 5.3 Professor Account tab

Same consolidated-page pattern as 5.1, scoped to what a professor
actually needs — **not a copy of the student page**: profile header,
device/key facts, theme, system log, sign out. No `Face ID` section
(professors don't enroll a face) and no student enrollment-status
section. If professor-only settings exist in the current app that don't
map to this list, add them here rather than forcing a professor fact into
a student-shaped section.

---

## 6. Attendance-marking flow — highest UI weight

This is the screen the student looks at most and the one place extra visual
investment is justified. Still governed by "no unessential text" — the
weight comes from motion, spatial clarity, and status choreography, not
from added copy or clutter.

### 6.1 `mark/browse`

- Full-bleed list of discovered classes as a lightweight variant of
  `StudentCard` (course name, professor display name if given, signal
  strength as a 3-bar glyph derived from beacon/BLE-hint recency — not a
  raw dBm number).
  Tap → straight into `mark/waiting`(existing behavior: typed-IP is a field
  on this screen per `SCREEN_MAP.md`; visually it becomes the
  `FallbackButton` "Enter IP manually" opening a one-field sheet — the
  screen itself shows only the discovered list).
- Empty state: single centered illustration + "Looking for a class…" with a
  subtle radar-sweep loop animation and `effect.glow.live` (§2.5) behind
  it (this is the one screen where an ambient animation is allowed at
  rest, since it communicates active scanning, not decoration) — and the
  same `Enter IP manually` fallback button beneath it.
- Broadcast-blocked banner: thin top banner, dismissible, plain language,
  not a modal.

### 6.2 `mark/waiting` → `mark/face`

- Waiting: a single centered presence indicator (pulsing ring, with
  `effect.glow.live` behind it per §2.5) with `Connected` / `Not connected`
  as the only two states, "waiting for professor to start" beneath.
  Manual-fallback button bottom, low emphasis.
- Transition into face scan is automatic (per existing behavior) and
  animated as the ring **morphing into the camera viewfinder frame**
  (shared-element transition, ~300ms) rather than a hard cut — this is the
  first "big" moment of the flow.
- **Face scan overlay — HARD REQUIREMENT, supersedes the corner-bracket
  design originally specified here:** full-bleed camera preview with
  exactly two overlay elements, nothing else:
  - **Small oval** — a live head-position target. The user is told once,
    briefly (not persistent copy), to rotate their head; the small oval
    tracks/indicates the target direction in sync with the current
    capture angle in the sequence. This is the only element telling the
    user *what to do right now*.
  - **Large oval** — a progress ring around the capture frame showing
    *overall* progress through the angle sequence (filling as each angle
    is captured). This is the only element telling the user *how far
    along they are*.
  - No other overlay of any kind: no corner brackets, no separate
    progress bar, no per-angle text labels stacked on screen, no extra
    chrome. The camera preview renders without additional graphics that
    could distort or obscure it beyond these two ovals.
  - Inconclusive vs. mismatch are communicated by color change **on these
    same two ovals** (neutral pulse vs. `status.error` flash) plus one
    short line of copy, never a dialog/modal — modals interrupt a flow
    that must keep listening on radio. This preserves the original
    intent of "communicated by frame color," just carried by the ovals
    instead of a bracket frame.
  - Zero-tap auto-scan is unchanged; `Scan` fallback button only appears
    if auto-scan hasn't resolved after a short delay, unchanged.
  - **Applies identically to `enroll/capture`** (the enrollment-side
    version of this same capture UI) — one overlay design, not two.
  - **Open gap, flagged rather than resolved here:** `README.md`
    describes enrollment capture as 3 stills (Centre/Left/Right);
    `SCREEN_MAP.md` describes it as 5 angles (centre/left/right/up/down).
    This is a pre-existing mismatch between the source docs, not
    introduced by this requirement. Build the two-oval overlay to match
    whatever the actual capture-controller code does, and report which
    count/sequence it turned out to be — the two-oval design itself works
    identically regardless of which is correct.

### 6.3 `mark/proving` → `mark/verdict`

- Proving: no countdown (preserved). Visual is a **step tracker**, not a
  spinner — three ambient states rendered as a horizontal progress of dots
  (`Signed → Sent → Confirmed`), each dot filling as the corresponding log
  event fires, so a student mid-lecture gets an honest sense of where the
  proof is stuck without reading log lines. Clock-drift banner sits above
  it, same honesty as today, just restyled as a thin banner not a dialog.
- Verdict is the single highest-weight moment in the whole app:
  - `Marked`: the step tracker collapses into `VerdictBadge` with the
    elastic scale-in specified in `SCREEN_MAP.md`, plus a brief
    (400ms, non-blocking, skippable-by-tap) full-width `gradient.marked`
    wash with `effect.glow.marked` behind the badge (§2.5), fading to
    normal surface — this is the one purely celebratory treatment in the
    app, deliberately reserved for this single event so it stays
    meaningful.
  - `Late`/`Needs review`/`No signal`/`Wrong org`: same badge shell, no
    color-wash flourish (flourish is reserved for the positive outcome),
    per-round trail shown beneath if applicable, "next step" line exactly
    as specified in `SCREEN_MAP.md` (one line, plain language, e.g. contact
    professor / retry next round).
  - Manual fallback ("Request manual attendance") is a `FallbackButton`
    only shown on non-Marked verdicts, never competing with the primary
    verdict display.

### 6.4 Fallbacks recap (explicit placement, matches user's requirement)

| Fallback | Where it lives | Trigger |
|---|---|---|
| Enter IP manually | `mark/browse`, low-emphasis text button below the list/empty state | Opens 1-field bottom sheet |
| Manual attendance request | `mark/verdict` (non-Marked states only) | Opens confirmation sheet |
| Manual student add (professor) | `live/<course>/add`, icon button in app bar, not inline fields on roster | Opens `ManualAddForm` sheet |
| Bluetooth-off prompt | Inline thin banner with a single "Turn on" tap-target, not a modal | Appears contextually |

---

## 7. Professor screens (secondary weight, same components)

Not the focus of this pass, but must reuse §4 components so the app is
visually one product. **HARD REQUIREMENT — the professor shell is now
explicitly split across two tabs, `Live` and `Courses`, per §3.1a; this
was previously bundled together as one "Professor screens" section and
is unbundled here:**

### 7.1 `Live` tab — hosting (the professor's "Mark" equivalent)

- `live/<course>` — the always-on control cluster (Start/Stop, elapsed,
  present/waiting counts) as a fixed header; `roster`/`inbox`/`add`/`setup`
  reached via a lightweight segmented sub-nav under that header (per
  `SCREEN_MAP.md` split), each rendered as a plain list of `StudentCard`s
  with hold-and-tap selection where bulk action applies (`inbox`, session
  multi-delete on the course page). Header background is `gradient.brand`
  while state is `LIVE`, flat `surface.raised` while `IDLE` (§2.5) — the
  one piece of visual flourish this pass gives the professor surface,
  since it directly answers "is this actually running" at a glance.
- `live/<course>/inbox` and `live/<course>/add` — **composed from the
  `features/manual_attendance/` module (§4.8)** rather than owning
  bespoke approve/reject or add-form UI inline.
- **Nothing under `Live` is reachable from `Courses`** (§3.1a) —
  `prof/courses/<course>` may show a read-only "LIVE now" status chip,
  but tapping it does not jump into these routes.

### 7.2 `Courses` tab — records-only

`prof/courses`, `prof/courses/<course>`, `export`, `sessions/<id>`,
`sessions/<id>/edit` — standard list/detail screens, same tokens, no
special treatment, and **no Start/Stop or hosting-setup affordance
anywhere in this tab** (§3.1a) — registering/managing a course is a
different action from going live with one, and this pass separates them
navigationally, not just visually.

### 7.3 Professor Account tab

See §5.3.

---

## 8. Courses tab (student) — renamed from "Records tab"

**HARD REQUIREMENT — rename + confirmation:** this tab was originally
named `Records`; it's `Courses` now (§3.1) and is explicitly confirmed
records-only (§3.1a) — no join/mark affordance renders here even for a
course with an open window.

- `courses/mine` (was `records/mine`): course cards (`x/y days attended`,
  progress ring instead of a raw fraction as the primary visual, fraction
  as caption beneath).
- Drill-down `courses/course/<course>` (was `records/course/<course>`):
  totals header (same progress ring, larger), then a plain vertical list
  of session tiles (date, verdict badge reused from §4.2) — no
  calendar-grid gimmick, a scroll list reads faster.
- Offline: "last synced <time>" as a caption under the header via
  `DetailsExpander` (§4.7) rather than always-visible banner text, unless
  data is stale beyond a threshold, then it becomes a thin top banner
  (consistent with the honesty principle already in the source docs).

---

## 9. Accessibility & content

- Status is always icon + color + text, never color alone.
- All interactive targets ≥48×48dp; hold-and-tap targets get a slightly
  larger invisible hit region than their visual bounds.
- Long-press-to-select has a discoverability affordance for first-time
  users only: a one-time, dismissible coach-mark ("Hold to select") shown
  once per list-type per install, never repeated, never a persistent hint.
- Dynamic type: respect system text scaling up to 130% without breaking the
  3-line `StudentCard` layout (truncate email first, then wrap to a 4th
  line only at the largest scale step).
- Every celebratory/ambient animation (radar sweep, color wash, elastic
  badge) degrades to a static equivalent under reduce-motion settings.
- Any text or icon sitting on a `gradient.*`/glow surface (§2.5) is checked
  against the gradient's *darkest* stop, not its average, for contrast —
  gradients never get a contrast exemption just because part of the
  surface is lighter.

---

## 10. Device ratios, safe areas, overflow

- Bottom bar respects the host device's own gesture/nav-bar area
  (`SafeArea` bottom inset honored, no custom nav bar drawn under system
  gesture regions — "borrow nav button of host device" means: do not draw a
  custom back/home affordance that duplicates or fights the OS one).
- Narrow width breakpoint (< 360dp logical): bottom bar goes icon-only,
  card padding drops from 16→12, `StudentCard` third line (round trail)
  wraps instead of overflowing.
- Wide/tablet breakpoint (≥ 600dp): list screens (`records`, `live` roster,
  `mark/browse`) gain a max content width (560dp) and center, rather than
  stretching cards edge-to-edge — prevents absurd line lengths, no
  new layout code path needed beyond a `ConstrainedBox`.
- Camera preview screen (`mark/face`) always fills available height first,
  letterboxing width if the device is unusually wide (foldable/tablet),
  never cropping the capture-frame overlay off-screen.
- Long emails/course names always truncate with ellipsis + full value on
  long-press tooltip — never wrap and break the fixed card height that
  hold-and-tap depends on.

### 10.1 Flutter-specific overflow & layout robustness

These are implementation-level rules, not just visual guidance — they
prevent the `RenderFlex overflow` / yellow-black-stripe class of bug that
tends to reappear screen-by-screen if left to each author's judgment:

- Every `Row`/`Column` that can receive variable-length text (names,
  emails, course titles, log lines) wraps the text child in `Expanded` or
  `Flexible` + `overflow: TextOverflow.ellipsis` — never a bare `Text` next
  to a fixed-width sibling (avatar, badge, chevron).
- Any screen with a text field near the bottom (IP-entry sheet, manual-add
  sheet) is wrapped so the keyboard doesn't cover it or force a hidden
  overflow: bottom sheets use `resizeToAvoidBottomInset`-equivalent
  behavior (the sheet content scrolls/resizes with `MediaQuery.viewInsets`
  padding at the bottom), never a fixed-height sheet that clips the field.
- `Text` widgets that must render system-scaled type (§9, up to 130%)
  never sit inside a fixed-height `SizedBox`/`Container` with `clipBehavior`
  that would silently cut a scaled line — height is intrinsic
  (`Wrap`/`Column` sizing) except where a card's fixed height is the
  explicit design (`StudentCard`'s 3-line contract, §4.1), which instead
  degrades via the truncate/wrap rule already specified in §9, not via
  clipping.
- Long, unbroken tokens that aren't meant to truncate (device install IDs,
  hashes, IPs shown in full on a detail page rather than a card) use
  `SelectableText` with monospace + explicit `softWrap: true`, not a
  scrolling `Row`, so they can't force horizontal overflow on a narrow
  device.
- Any `ListView`/`GridView` embedded inside another scrollable (e.g. a
  short list inside a bottom sheet) gets `shrinkWrap: true` +
  `NeverScrollableScrollPhysics` if it's meant to size-to-content, or is
  given an explicit bounded height via `Expanded` inside the sheet's own
  `Column` — never an unbounded-height exception left for the
  implementer to discover at runtime.
- Network-sourced imagery (Google account photo in `AccountChip`) always
  has an `errorBuilder`/fallback that renders the initials-avatar, so a
  failed image load never leaves a broken-image icon or blank circle in
  the nav bar or Account header.
- Orientation/rotation: only the camera preview screen (`mark/face`) has
  any orientation-specific layout; every other screen uses the same
  portrait layout rules as the wide/tablet breakpoint above rather than a
  bespoke landscape path, to avoid doubling the screens that need testing.

---

## 11. Implementation guidance (refactor boundary)

- Build `widgets/student_card.dart`, `widgets/verdict_badge.dart`,
  `widgets/account_chip.dart`, `widgets/fallback_button.dart`,
  `widgets/selection_toolbar.dart`, `widgets/details_expander.dart`
  (§4.7), and the two-oval capture-overlay widget (§6.2) as the shared
  layer; `features/manual_attendance/` (§4.8) as its own module; every
  screen under `features/` imports from here instead of hand-rolling list
  tiles. This directly retires the redundant per-screen list-tile code the
  current screens carry, without touching the `screens/` host drivers
  (`student_home`, `take_attendance`) that own timers/sync/drafts —
  presentational-only swap, per the existing `features/` vs `screens/`
  split in `SCREEN_MAP.md`.
- Both shells' bottom-bar body uses `IndexedStack` (§3.5); remove the old
  `PopScope` → `setMode(unset)` exit pattern wherever it exists (§3.5) —
  explicit deletion, not a "leave if it still works."
- Selection-mode state is a small local `ChangeNotifier`/`Riverpod`
  provider scoped to the screen that owns the list — do not lift it to a
  global provider; multiple lists (roster vs inbox) must never share
  selection state.
- Theming: a single `ThemeExtension<ProximityColors>` with dark/light
  instances wired through `MaterialApp.theme` / `.darkTheme`; no
  screen reads raw `Colors.*` — enforce via lint or code review, since
  scattered raw colors are what makes future theme changes expensive.
- No behavior, verdict string, timing constant, threshold, or network call
  changes as part of this pass. If a screen's current logic must move to
  fit the new component boundary, the move is mechanical (same function,
  new location) — flagged explicitly in the PR description, not silently
  bundled with a visual change.
- **HARD REQUIREMENT, revises the note above:** Account (§5) is now one
  consolidated page (`account`) sectioned for enrollment/ID/device/theme/
  log/sign-out, plus exactly one addressable sub-route, `account/face-id`
  (§5.2), and the existing `debug/log`. This is a reduction in navigation
  depth from what this document originally proposed, not new depth — the
  underlying data (enrollment record, face-ID status, device/trust-tier
  state) is still read from exactly the same sources; only the widget
  tree and route table change. Wire the router/deep-link table to match
  `SCREEN_MAP.md` exactly, and treat the old `account/enrollment` and
  `account/device` routes as folded into `account`, not deleted content
  — the facts they held are now sections on that one page.
