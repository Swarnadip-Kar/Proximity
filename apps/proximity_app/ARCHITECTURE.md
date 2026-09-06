# Proximity app architecture (Phase 1 — UI foundation)

## Layout

```
lib/
  design/
    tokens.dart      # THE source of truth: durations, curves, spacing,
                     # radii, state colors, palette, reduce-motion helper
    app_theme.dart   # Material light/dark themes (Space Grotesk + Inter)
  widgets/
    prox_scaffold.dart  # ProxScreen: app bar + max-width body (wraps AdaptiveScaffold)
    prox_buttons.dart   # ProxPrimaryButton / ProxSecondaryButton (press-scale, never gated)
    prox_cards.dart     # ProxCard / ProxListTile / ProxDot (pulse opt-in)
    prox_states.dart    # ProxStateBadge / SectionHeader / Empty / Loading / Sync+Error notes
    prox_motion.dart    # ProxFadeSlideIn / ProxStaggered / ProxSwitcher / ProxAnimatedCount
    prox_verdict.dart   # Verdict badges with distinct motion per kind
    animated.dart       # LEGACY: FaceOval / PresentTicker / MarkedBadge (kept for compat;
                        #   new code prefers prox_*; removal is a later-phase cleanup)
    ble_log_view.dart / manual_add.dart / ip_join.dart / clock.dart / ...
  screens/           # one file per route; behavior per PROXIMITY_DESIGN.md §7
  core/              # drivers, sync, face, BLE (no UI)
  main.dart          # app entry + AdaptiveScaffold (Cupertino nav on Apple OS)
  mode.dart          # AppMode + linked identity
```

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
   - verdict pop → `ProxVerdictBadge` only (elastic reserved for Marked)
6. **Verdicts differ by motion, not just color:** marked = spring pop,
   late = rise+fade, no-signal = breathing fade, error = one shake.
7. **Reduce-motion:** route durations through `ProxMotion.effective` (the
   `Prox*` widgets already do). Meaning must survive with motion off.
8. **Performance:** no blur/shadow/particle parties on live screens
   (BLE + camera + networking are already hot). One pulsing dot max per
   row; lists rebuild only on data change.
9. **Behavior is frozen:** flows, timing guarantees, and security properties
   per `PROXIMITY_DESIGN.md` §7. Refactor freely under that constraint;
   flag anything uncertain for review instead of guessing.
10. **Tests are contracts:** `test/widget_test.dart` asserts on visible copy
    (`Start`, `Join`, `✓ Marked`, …) and field keys (`ipfield`, `direct-*`,
    `edit-*`, `prof-search`). Keep those strings/keys stable.

## Visual identity (Phase 1)

- **Fonts:** Space Grotesk (display/headings/hero) + Inter (body/labels).
- **Palette:** indigo primary `#4340D6`, teal live accent `#0E9F8A`, paper
  `#F5F6FA` / ink `#0E1220`; state colors in `ProxStateColors`.
- **Shape:** 14dp cards, 12dp buttons, pill badges; flat (border, ~0dp).
- **Type scale:** display 700 / title 600 / body Inter; section headers via
  `ProxSectionHeader`, never ad-hoc sizes.
