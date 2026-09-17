// Live session header (prof live, §7.1): the mid-class always-on block —
// LIVE/IDLE state, elapsed open time, session date/day line, present/
// waiting counters, and the Start ⇄ Stop control cluster. Nothing else
// is always-on mid-class.
//
// `gradient.brand` while state is LIVE and stays flat `surface.raised`
// while IDLE (§2.5) — the one flourish on the professor surface, since it
// answers "is this actually running" at a glance. Verdict vocabulary
// (`Start`/`Stop`/`Retake round N`/`Take another round`/`End attendance`),
// the elapsed `mm:ss` clock, and the present/waiting denominator rule are
// frozen (same copy, same clock, same rule as the pre-split screen).
//
// The date/day line (today) renders via the frozen records helpers (`fullDateOf` +
// `todayIso`, same formats as the session detail/roomy lines) so the
// Live page shows date/day like Courses does. Pure display, no lifecycle/
// draft/snapshot/timing change.
//
// Motion intent: the elapsed tick rebuilds in place (keyed rows elsewhere
// never replay entrances); the control cluster cross-fades via
// [ProxSwitcher] so Start ⇄ Stop reads as a continuation, not a hard
// swap. Actions fire immediately — only the visuals transition.
// Counters are fed at build time from the live tally, never cached, so
// they cannot go stale during transitions.
library;

import 'package:flutter/material.dart';

import '../../core/sync/store/record_helpers.dart';
import '../../design/app_theme.dart';
import '../../design/tokens.dart';
import '../../widgets/clock.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_cards.dart';
import '../../widgets/prox_motion.dart';

/// Open-window elapsed clock (mm:ss, unbounded — Stop ends it).
String liveElapsedLabel(Duration elapsed) {
  final s = elapsed.inSeconds;
  final mm = (s ~/ 60).toString().padLeft(2, '0');
  final ss = (s % 60).toString().padLeft(2, '0');
  return '$mm:$ss';
}

/// Gated prof photo for the live header (pure, unit-testable): the trimmed
/// account photoUrl iff the per-course opt-in is on, else '' (initials
/// disc). Same gating as the student-view preview + host publish path.
String liveHeaderPhotoUrl(
    {required bool sharePhoto, required String? accountPhotoUrl}) {
  if (!sharePhoto) return '';
  return (accountPhotoUrl ?? '').trim();
}

/// Leading initial for the live header avatar (pure, unit-testable):
/// first alphanum of the resolved display name, else '?'. Same
/// single-letter contract as the HostPreviewCard avatar block.
String liveHeaderInitial(String displayName) {
  for (final ch in displayName.trim().characters) {
    if (RegExp('[A-Za-z0-9]').hasMatch(ch)) return ch.toUpperCase();
  }
  return '?';
}

/// Compact status strip (modular block 1 of the live header): LIVE/IDLE
/// pill + tabular elapsed clock + present/waiting counters in one row.
/// Same elements as the old two-column layout, roughly half the height.
class LiveStatusStrip extends StatelessWidget {
  final bool live;
  final Duration elapsed;
  final int present;
  final int waiting;

  const LiveStatusStrip({
    super.key,
    required this.live,
    required this.elapsed,
    required this.present,
    required this.waiting,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final ink = c.contentPrimary;
    final denom = waiting > 0 ? waiting : (present > 0 ? present : 0);
    return Row(
      children: [
        // LIVE/IDLE pill: transport state on ProximityColors (brand for
        // live, tertiary for idle) — not the legacy ProxState mapping.
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: ProxSpacing.sm,
            vertical: ProxSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: live
                ? c.accentBrand.withValues(alpha: 0.14)
                : c.contentTertiary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(ProxRadii.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ProxDot(
                size: 8,
                color: live ? c.accentBrand : c.contentSecondary,
                pulse: live,
              ),
              const SizedBox(width: 6),
              Text(
                live ? 'LIVE' : 'IDLE',
                style: ProxType.label(color: ink).copyWith(
                  letterSpacing: 2,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: ProxSpacing.sm),
        // Elapsed ticks every second — excluded from semantics so screen
        // readers announce LIVE/IDLE + counters once, not every tick.
        // Fixed-width mm:ss (5 chars) so it never competes with the count.
        ExcludeSemantics(
          child: Text(
            liveElapsedLabel(elapsed),
            style: ProxType.title(color: ink).copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              fontWeight: FontWeight.w700,
            ),
            overflow: TextOverflow.clip,
            maxLines: 1,
            softWrap: false,
          ),
        ),
        const SizedBox(width: ProxSpacing.sm),
        // Count never clips: Expanded reserves the remaining width, right-
        // aligned, and scales the ticker down instead of ellipsizing the
        // "n/m present" text off on narrow screens.
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: ProxSwitcher(
                child: Text(
                    '$present/$denom present',
                    key: ValueKey<int>(present),
                    style: proxTabular(context,
                        Theme.of(context).textTheme.headlineSmall),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    softWrap: false),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Session meta lines (modular block 2): date row + windows caption +
/// host line. Unconditional in both states so IDLE and LIVE read alike.
class LiveSessionMeta extends StatelessWidget {
  final int windowsTaken;
  final int windowNo;
  final int present;
  final int denom;
  final String? hostLine;

  const LiveSessionMeta({
    super.key,
    required this.windowsTaken,
    required this.windowNo,
    required this.present,
    required this.denom,
    required this.hostLine,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final ink = c.contentPrimary;
    final host = hostLine;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.calendar_today_outlined,
              size: 14,
              color: ink,
            ),
            const SizedBox(width: ProxSpacing.sm),
            Flexible(
              child: Text(
                fullDateOf(todayIso()),
                style: ProxType.label(color: ink),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        ProxSwitcher(
          child: Text(
            windowsTaken <= 1
                ? 'Window 1 · $present present / $denom waiting'
                : 'Windows 1–$windowNo ($windowsTaken taken) · intersection $present / $denom waiting',
            key: ValueKey<String>('$windowsTaken-$windowNo-$present-$denom'),
            style: ProxType.caption(color: ink),
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
          ),
        ),
        if (host != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              host,
              style: ProxType.caption(color: ink),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
      ],
    );
  }
}

/// Start ⇄ Stop control cluster (modular block 3): same verdict
/// vocabulary and enablement, cross-fading as a continuation.
class LiveControlCluster extends StatelessWidget {
  final bool live;
  final bool hosting;
  final int windowNo;
  final VoidCallback onStart;
  final VoidCallback onRetake;
  final VoidCallback onTakeAnother;
  final VoidCallback onStop;
  final VoidCallback onEnd;

  const LiveControlCluster({
    super.key,
    required this.live,
    required this.hosting,
    required this.windowNo,
    required this.onStart,
    required this.onRetake,
    required this.onTakeAnother,
    required this.onStop,
    required this.onEnd,
  });

  @override
  Widget build(BuildContext context) {
    // Stable 2-action cluster (never 1→2→3 stacking): exactly one primary
    // (Start / Take another / Stop) plus ONE quiet companion — End when
    // fresh, a More menu (Retake correction + End terminal) after rounds.
    // Terminal End behind the menu also prevents mid-class mis-taps.
    // Disabled always explains itself via the caption below.
    final c = ProximityColors.of(context);
    return ProxSwitcher(
      child: Column(
        key: ValueKey<bool>(live),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: ProxSpacing.sm,
            runSpacing: ProxSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (live) ...[
                ProxPrimaryButton(
                  label: const Text('Stop'),
                  onPressed: onStop,
                  expanded: false,
                ),
              ] else ...[
                if (windowNo == 0)
                  ProxPrimaryButton(
                    label: const Text('Start'),
                    onPressed: (!hosting) ? null : onStart,
                    expanded: false,
                  )
                else
                  ProxPrimaryButton(
                    label: const Text('Take another round'),
                    onPressed: (!hosting) ? null : onTakeAnother,
                    expanded: false,
                  ),
                if (windowNo == 0)
                  ProxDangerButton(
                    label: const Text('End attendance'),
                    onPressed: (!hosting) ? null : onEnd,
                  )
                else
                  _MoreActions(
                    enabled: hosting,
                    windowNo: windowNo,
                    onRetake: onRetake,
                    onEnd: onEnd,
                  ),
              ],
            ],
          ),
          if (!live && !hosting) ...[
            const SizedBox(height: ProxSpacing.xs),
            Text(
              'Hosting offline — actions resume when the server starts.',
              style: ProxType.caption(color: c.contentSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

/// Overflow companion for the idle-after-rounds cluster: Retake (same
/// number correction, marks merge) + End (terminal). Outlined pill in the
/// secondary metrics (48dp, button radius, brand border) labeled More;
/// items keep frozen copy, End in error red. Disabled with the cluster.
class _MoreActions extends StatelessWidget {
  final bool enabled;
  final int windowNo;
  final VoidCallback onRetake;
  final VoidCallback onEnd;

  const _MoreActions({
    required this.enabled,
    required this.windowNo,
    required this.onRetake,
    required this.onEnd,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final fg = enabled ? c.accentBrand : c.contentTertiary;
    return PopupMenuButton<String>(
      enabled: enabled,
      tooltip: 'More actions',
      offset: const Offset(0, ProxSpacing.minTap),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ProxRadii.cardSpec),
        side: BorderSide(color: c.divider),
      ),
      color: c.surfaceRaised,
      onSelected: (v) {
        if (v == 'retake') onRetake();
        if (v == 'end') onEnd();
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'retake',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.refresh, size: ProxIconSizes.md, color: fg),
              const SizedBox(width: ProxSpacing.sm),
              Text(
                'Retake round $windowNo',
                style: ProxType.body(color: c.contentPrimary),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'end',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.stop_circle_outlined,
                size: ProxIconSizes.md,
                color: c.statusError,
              ),
              const SizedBox(width: ProxSpacing.sm),
              Text(
                'End attendance',
                style: ProxType.body(color: c.statusError),
              ),
            ],
          ),
        ),
      ],
      child: Container(
        constraints: const BoxConstraints(minHeight: ProxSpacing.minTap),
        padding: const EdgeInsets.symmetric(
          horizontal: ProxSpacing.lg,
          vertical: ProxSpacing.md,
        ),
        decoration: BoxDecoration(
          border: Border.all(
            color: enabled
                ? c.accentBrand.withValues(alpha: 0.35)
                : c.contentTertiary.withValues(alpha: 0.3),
          ),
          borderRadius: ProxRadii.buttonRadius,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.more_horiz, size: ProxIconSizes.md, color: fg),
            const SizedBox(width: ProxSpacing.sm),
            Text(
              'More',
              style: ProxType.label(color: fg).copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class LiveSessionHeader extends StatelessWidget {
  final bool live;
  final Duration elapsed;
  final int present;
  final int waiting;
  final int windowsTaken;
  final int windowNo;
  final bool hosting;
  final String? hostLine;

  /// Gated Gmail photo ('' = opted-out/unknown → initials disc). Already
  /// gated by the caller (`_sharePhoto` + account photoUrl); this widget
  /// never reads stores. Same 40dp photo-or-initials contract as the
  /// HostPreviewCard avatar block, static (no timers/animation) so
  /// pumpAndSettle-safe.
  final String photoUrl;

  /// Display name for the initials fallback (prof name as typed).
  final String avatarName;

  final VoidCallback onStart;
  final VoidCallback onRetake;
  final VoidCallback onTakeAnother;
  final VoidCallback onStop;
  final VoidCallback onEnd;

  const LiveSessionHeader({
    super.key,
    required this.live,
    required this.elapsed,
    required this.present,
    required this.waiting,
    required this.windowsTaken,
    required this.windowNo,
    required this.hosting,
    required this.hostLine,
    this.photoUrl = '',
    this.avatarName = '',
    required this.onStart,
    required this.onRetake,
    required this.onTakeAnother,
    required this.onStop,
    required this.onEnd,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    // Denominator prefers the live waiting count (who could still mark);
    // falls back to present so the counter never reads 0/0 mid-round.
    final denom = waiting > 0 ? waiting : (present > 0 ? present : 0);
    final onWash = live;
    // Leading prof avatar (HostPreviewCard block, 40dp): gated Gmail photo
    // iff the per-course opt-in supplied a non-empty URL, else the initials
    // disc. Static — initials beneath while loading/offline + on error —
    // so the 1s elapsed tick + LIVE pulse stay the only motion here.
    final headerPhoto = photoUrl.trim();
    Widget headerInitials() => Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.accentBrand.withValues(alpha: 0.12),
          ),
          alignment: Alignment.center,
          child: Text(
            liveHeaderInitial(avatarName),
            style: ProxType.title(color: c.accentBrand),
            overflow: TextOverflow.clip,
            maxLines: 1,
          ),
        );
    final headerAvatar = headerPhoto.isEmpty
        ? headerInitials()
        : ClipOval(
            child: Image.network(
              headerPhoto,
              width: 40,
              height: 40,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => headerInitials(),
              frameBuilder: (context, child, frame, _) {
                if (frame == null) return headerInitials();
                return child;
              },
            ),
          );
    // Contrast (§9, checked against the DARKEST stop — no exemptions): a
    // full-opacity `gradient.brand` wash under `contentPrimary` body text
    // measures 2.85:1 (dark) / 3.49:1 (light) — both below AA body text —
    // and outlined-button labels on it fail outright (~1.4–1.6:1). So LIVE
    // renders the TOKEN gradient at 20% alpha over `surfaceRaised`
    // (stops/begin/end still the token's — never hand-authored), which
    // measures, against the effective surface: dark ink 11.99, dark
    // outlined-label 6.68, dark LIVE ring 4.21 (≥3 non-text); light ink
    // 13.76, light outlined-label 5.42, light ring 3.95. The gradient =
    // "running" signal (§2.5) is preserved as a brand tint + LIVE word +
    // pulsing dot; IDLE stays flat `surfaceRaised`.
    return AnimatedContainer(
      duration: ProxDurations.small,
      curve: ProxCurves.standard,
      padding: const EdgeInsets.all(ProxSpacing.md),
      decoration: BoxDecoration(
        // The one professor flourish (§2.5): gradient while LIVE, flat
        // raised surface while IDLE. Never a hand-authored gradient: the
        // LIVE wash reuses the token's own begin/end/stops at 20% alpha
        // over `surfaceRaised` (see the contrast note above).
        color: c.surfaceRaised,
        gradient: onWash
            ? LinearGradient(
                begin: c.gradientBrand.begin,
                end: c.gradientBrand.end,
                colors: [
                  for (final stop in c.gradientBrand.colors)
                    stop.withValues(alpha: 0.2),
                ],
              )
            : null,
        borderRadius: ProxRadii.cardSpecRadius,
        border: Border.all(
          color: onWash ? c.contentPrimary.withValues(alpha: 0.35) : c.divider,
        ),
        boxShadow: [c.elevationRaised],
      ),
      // Compact modular composition: status strip → meta lines →
      // controls. Same elements, same vocabulary, same enablement —
      // roughly half the vertical weight of the old two-column card.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          LiveStatusStrip(
            live: live,
            elapsed: elapsed,
            present: present,
            waiting: waiting,
          ),
          const SizedBox(height: ProxSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              headerAvatar,
              const SizedBox(width: ProxSpacing.md),
              Expanded(
                child: LiveSessionMeta(
                  windowsTaken: windowsTaken,
                  windowNo: windowNo,
                  present: present,
                  denom: denom,
                  hostLine: hostLine,
                ),
              ),
            ],
          ),
          const SizedBox(height: ProxSpacing.sm),
          LiveControlCluster(
            live: live,
            hosting: hosting,
            windowNo: windowNo,
            onStart: onStart,
            onRetake: onRetake,
            onTakeAnother: onTakeAnother,
            onStop: onStop,
            onEnd: onEnd,
          ),
        ],
      ),
    );
  }
}

/// Floating bottom controls (prof live): docked just above the shell nav
/// bar, replacing the old fixed top control-cluster card. Same vocabulary
/// + enablement, new placement — thumb-reachable, never covering the roster.
///
/// States (copy frozen):
/// - live: slim [LiveStatusStrip] + full-width `Stop` (primary).
/// - idle, windowNo == 0: full-width `Start` (primary).
/// - idle, windowNo > 0: 2x2 grid — `Discard round N` + `End attendance`
///   on top, `Resume round N` + `Take another round` below, four equal
///   corners. Resume re-opens the same round (marks merge); discard
///   drops it behind a confirm popup.
/// Disabled always explains itself via the caption below (same copy as the
/// old cluster). Sheet chrome per §2.5: flat `surfaceRaised`, `divider`
/// border, `elevationSheet` shadow — never a gradient fill.
class LiveFloatingControls extends StatelessWidget {
  final bool live;
  final bool hosting;
  final int windowNo;
  final Duration elapsed;
  final int present;
  final int waiting;

  final VoidCallback onStart;
  final VoidCallback onResume;
  final VoidCallback onDiscard;
  final VoidCallback onTakeAnother;
  final VoidCallback onStop;
  final VoidCallback onEnd;

  const LiveFloatingControls({
    super.key,
    required this.live,
    required this.hosting,
    required this.windowNo,
    required this.elapsed,
    required this.present,
    required this.waiting,
    required this.onStart,
    required this.onResume,
    required this.onDiscard,
    required this.onTakeAnother,
    required this.onStop,
    required this.onEnd,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: ProxRadii.cardSpecRadius,
        border: Border.all(color: c.divider),
        boxShadow: [c.elevationSheet],
      ),
      padding: const EdgeInsets.all(ProxSpacing.sm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ProxSizeGlide(
            stateKey: live
                ? 'live'
                : (windowNo == 0 ? 'fresh' : 'round-$windowNo'),
            child: ProxSwitcher(
              child: Column(
                key: ValueKey<String>(live
                    ? 'live'
                    : (windowNo == 0 ? 'fresh' : 'round-$windowNo')),
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (live) ...[
                    ProxPrimaryButton(
                      label: const Text('Stop'),
                      onPressed: onStop,
                      compact: true,
                    ),
                  ] else if (windowNo == 0) ...[
                    ProxPrimaryButton(
                      label: const Text('Start'),
                      onPressed: (!hosting) ? null : onStart,
                      compact: true,
                    ),
                  ] else ...[
                    Row(
                      children: [
                        Expanded(
                          child: ProxDangerButton(
                            label: Text('Discard round $windowNo'),
                            onPressed: (!hosting) ? null : onDiscard,
                          ),
                        ),
                        const SizedBox(width: ProxSpacing.xs),
                        Expanded(
                          child: ProxDangerButton(
                            label: const Text('End attendance'),
                            onPressed: (!hosting) ? null : onEnd,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: ProxSpacing.xs),
                    Row(
                      children: [
                        Expanded(
                          child: ProxSecondaryButton(
                            label: Text('Resume round $windowNo'),
                            onPressed: (!hosting) ? null : onResume,
                            expanded: true,
                            compact: true,
                          ),
                        ),
                        const SizedBox(width: ProxSpacing.xs),
                        Expanded(
                          child: ProxPrimaryButton(
                            label: const Text('Take another round'),
                            onPressed: (!hosting) ? null : onTakeAnother,
                            expanded: true,
                            compact: true,
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (!live && !hosting) ...[
                    const SizedBox(height: ProxSpacing.xs),
                    Text(
                      'Hosting offline — actions resume when the server starts.',
                      style: ProxType.caption(color: c.contentSecondary),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
