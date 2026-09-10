// Verdict (student mark): Marked / Late / No-signal / Wrong-org /
// Needs-review, each in the shared `VerdictBadge` shell (icon + word,
// never color alone).
//
// `Marked` is the single highest-weight moment in the app: the badge keeps
// its elastic scale-in plus a brief (400ms, non-blocking, skippable-by-tap)
// full-width `gradient.marked` wash with `effect.glow.marked` behind it,
// fading to the normal surface. That combination fires here and nowhere
// else. Every other outcome uses the same badge shell flat — no flourish.
// Non-Marked verdicts show the per-round trail as pill chips, the verbatim
// one-line next step, and the manual-request fallback button.
//
// Every verdict carries the per-round trail for the join so far. Marked
// parks here (stay-put copy) until the round ends, then the flow rejoins
// the waiting room automatically — zero taps, face re-checks every round.
// Hosting-ended (unreachable server) never parks: the badge leaves for the
// live list instead of a dead waiting room.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../widgets/fallback_button.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/trust_cards.dart';
import '../../widgets/verdict_badge.dart';
import 'waiting_room.dart' show RoundTrailPills;

enum MarkVerdict { marked, late, wrongOrg, needsReview, noSignal }

class MarkVerdictView extends StatelessWidget {
  final MarkVerdict kind;
  final String detail;
  final String infoDetail;

  /// Real orgs for the wrong-org card ('' keeps the generic fallback).
  final String classOrg;
  final String myOrg;
  final List<String> roundMarks;
  final int attemptsLeft;
  final VoidCallback onRetryFace;
  final VoidCallback onManualInstead;
  final VoidCallback onBack;

  const MarkVerdictView({
    super.key,
    required this.kind,
    required this.detail,
    this.infoDetail = '',
    this.classOrg = '',
    this.myOrg = '',
    required this.roundMarks,
    this.attemptsLeft = 0,
    required this.onRetryFace,
    required this.onManualInstead,
    required this.onBack,
  });

  /// Manual-request fallback at fallback weight (button → confirmation
  /// sheet, never inline): shown on non-Marked verdicts only, never
  /// competing with the primary verdict display.
  Widget _manualFallback() => FallbackButton(
        label: 'Request manual attendance',
        sheetTitle: 'Request manual attendance',
        icon: Icons.how_to_reg,
        sheetBuilder: (sheetContext) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton(
              onPressed: () {
                Navigator.of(sheetContext).pop();
                onManualInstead();
              },
              child: const Text('Request manual attendance'),
            ),
            const SizedBox(height: ProxSpacing.sm),
            TextButton(
              onPressed: () => Navigator.of(sheetContext).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );

  Widget _frame(BuildContext context, Widget child) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(ProxSpacing.screenMargin),
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(maxWidth: ProxSpacing.maxContentWidth),
            child: child,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return switch (kind) {
      MarkVerdict.marked => _frame(
          context,
          _MarkedWash(
            builder: (washContext) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const VerdictBadge(
                  status: ProxStatus.marked,
                  label: '✓ Marked',
                ),
                if (roundMarks.isNotEmpty) ...[
                  const SizedBox(height: ProxSpacing.sm),
                  RoundTrailPills(marks: roundMarks),
                  const SizedBox(height: ProxSpacing.xs),
                  Text(
                    'Stay put — the next round rejoins automatically.',
                    textAlign: TextAlign.center,
                    style: ProxType.body(
                      color: ProximityColors.of(washContext).contentSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      MarkVerdict.late => _frame(
          context,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const VerdictBadge(status: ProxStatus.late),
              if (detail.isNotEmpty) ...[
                const SizedBox(height: ProxSpacing.xs),
                Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: ProxType.body(color: c.contentPrimary),
                ),
              ],
              if (roundMarks.isNotEmpty) ...[
                const SizedBox(height: ProxSpacing.sm),
                RoundTrailPills(marks: roundMarks),
                const SizedBox(height: ProxSpacing.xs),
                Text(
                  'Stay put — the next round rejoins automatically.',
                  textAlign: TextAlign.center,
                  style: ProxType.body(color: c.contentSecondary),
                ),
              ],
              const SizedBox(height: ProxSpacing.md),
              _manualFallback(),
            ],
          ),
        ),
      MarkVerdict.wrongOrg => _frame(
          context,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const VerdictBadge(status: ProxStatus.wrongOrg),
              const SizedBox(height: ProxSpacing.sm),
              WrongOrgCard(
                classOrg: classOrg.isNotEmpty ? classOrg : 'this class',
                myOrg: myOrg.isNotEmpty ? myOrg : 'your account',
              ),
              const SizedBox(height: ProxSpacing.sm),
              Text(
                detail.isEmpty
                    ? 'No proof was sent — join your institute class instead.'
                    : detail,
                textAlign: TextAlign.center,
                style: ProxType.caption(color: c.contentSecondary),
              ),
              const SizedBox(height: ProxSpacing.md),
              ProxPrimaryButton(
                label: const Text('Back to classes'),
                onPressed: onBack,
                expanded: false,
              ),
              const SizedBox(height: ProxSpacing.xs),
              _manualFallback(),
            ],
          ),
        ),
      MarkVerdict.needsReview => _frame(
          context,
          ProxFadeSlideIn(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const VerdictBadge(status: ProxStatus.review),
                const SizedBox(height: ProxSpacing.sm),
                Text(
                  'Face check didn\'t match the enrolled face — try again in good light, holding still.',
                  textAlign: TextAlign.center,
                  style: ProxType.body(color: c.contentPrimary),
                ),
                const SizedBox(height: ProxSpacing.md),
                // 4 mismatch sessions, then the review queue. Anything
                // unreadable never reaches this screen (the verify
                // session keeps scanning; free auto-relaunches follow).
                if (attemptsLeft > 0)
                  ProxPrimaryButton(
                    icon: const Icon(Icons.refresh),
                    label: Text('Retry face scan ($attemptsLeft left)'),
                    onPressed: onRetryFace,
                    expanded: false,
                  )
                else
                  _manualFallback(),
                const SizedBox(height: ProxSpacing.sm),
                ProxSecondaryButton(
                  label: const Text('Back'),
                  onPressed: onBack,
                ),
              ],
            ),
          ),
        ),
      MarkVerdict.noSignal => _frame(
          context,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const VerdictBadge(status: ProxStatus.noSignal),
              if ((infoDetail.isNotEmpty ? infoDetail : detail).isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: ProxSpacing.xs),
                  child: Text(
                    infoDetail.isNotEmpty ? infoDetail : detail,
                    textAlign: TextAlign.center,
                    style: ProxType.body(color: c.contentPrimary),
                  ),
                ),
              const SizedBox(height: ProxSpacing.md),
              ProxPrimaryButton(
                label: const Text('Try again'),
                onPressed: onBack,
                expanded: false,
              ),
              const SizedBox(height: ProxSpacing.xs),
              _manualFallback(),
            ],
          ),
        ),
    };
  }
}

/// Wash-local dark ink for [_MarkedWash] content (see its contrast note).
/// Only the two fields wash content reads are overridden — badge + trail
/// pills (`statusMarked`), stay-put line (`contentSecondary`) — so nothing
/// outside the wash can observe the override.
ProximityColors _washInk(ProximityColors c) => c.copyWith(
      statusMarked: const Color(0xFF14161A),
      contentSecondary: const Color(0xFF14161A),
    );

/// The one celebratory wash in the app (§6.3, single-use): a full-width
/// `gradient.marked` wash with `effect.glow.marked` behind the badge,
/// fading over `verdictWash` (400ms). Non-blocking (pure decor beneath the
/// content), skippable by tap, and never rendered anywhere else. Under
/// reduce-motion it collapses to a flat `status.marked` fill for the same
/// beat, then clears — meaning stays on the badge's icon + word.
///
/// Contrast (§9, darkest stop — no exemptions): status-green badge text on
/// the green wash measures ~1.1:1 (unreadable), so wash content renders in
/// the token-prescribed dark ink `#14161A` via a wash-local
/// [ProximityColors] override (badge, trail pills, stay-put line all read
/// the override — no component API changes): 8.27:1 on dark's darkest stop
/// `#33C77A` (10.60 on the light stop), 5.03:1 on light's darkest stop
/// `#1E9A5C` (7.09 on the light stop). Transient 400ms reinforcement, same
/// single-use rule.
class _MarkedWash extends StatefulWidget {
  /// Builds the wash content. The build context carries the wash-local
  /// dark-ink [ProximityColors] — read colors from it, not from above.
  final WidgetBuilder builder;

  const _MarkedWash({required this.builder});

  @override
  State<_MarkedWash> createState() => _MarkedWashState();
}

class _MarkedWashState extends State<_MarkedWash> {
  var _visible = true;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    // Single-use, self-clearing: the wash always lifts, whether or not the
    // fade plays (timer-driven so widget tests still settle).
    _hide = Timer(ProxDurations.verdictWash, () {
      if (!mounted) return;
      setState(() => _visible = false);
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Wash lifted: normal surface, normal token colors (the dark-ink
    // override only ever applies while the wash is behind the content).
    if (!_visible) return Builder(builder: widget.builder);
    final c = ProximityColors.of(context);
    final reduced = ProxMotion.reduced(context);
    final wash = Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        vertical: ProxSpacing.xl,
        horizontal: ProxSpacing.md,
      ),
      decoration: BoxDecoration(
        gradient: reduced ? null : c.gradientMarked,
        color: reduced ? c.statusMarked.withValues(alpha: 0.15) : null,
        borderRadius: ProxRadii.cardSpecRadius,
        boxShadow: reduced ? null : [c.glowMarked.toShadow()],
      ),
      // Wash-local dark ink (see class docs): the builder context reads
      // the override, so badge + trail + line all render in `#14161A`.
      child: Theme(
        data: Theme.of(context).copyWith(
          extensions: <ThemeExtension<dynamic>>[_washInk(c)],
        ),
        child: Builder(builder: widget.builder),
      ),
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Skippable-by-tap: one tap lifts the wash early.
      onTap: () {
        _hide?.cancel();
        setState(() => _visible = false);
      },
      child: reduced
          ? wash
          : TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.0, end: 1.0),
              duration: ProxDurations.verdictWash,
              curve: ProxCurves.standard,
              builder: (context, t, child) => Opacity(
                opacity: t,
                child: child,
              ),
              child: wash,
            ),
    );
  }
}
