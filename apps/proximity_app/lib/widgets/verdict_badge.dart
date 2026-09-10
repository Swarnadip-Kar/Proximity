// VerdictBadge — the one verdict pill (§4.2).
//
// Pill, icon + short word, color from `status.*` tokens. Exhaustive set,
// copied verbatim from the existing verdict vocabulary — this component only
// standardizes rendering, never invents new states. Supersedes the old
// `MarkedBadge` per SCREEN_MAP.md: the elastic "just marked" motion lives
// INSIDE this component as a transition-in animation when its state flips
// to `Marked`, not as a separate widget.
//
// - `Marked` (statusMarked, check) — elastic scale-in on flip-to-Marked.
// - `Late` (statusLate, clock).
// - `Wrong org` (statusError, triangle).
// - `No signal` (statusError, wifi-off slash).
// - `Needs review` (statusReview, flag).
// - `Waiting` (contentSecondary, dot, static).
// - `Pending` (statusReview, dot-pulsing — animated only while pending).
//
// Status is always icon + color + text, never color alone (§9). All motion
// degrades under reduce-motion (meaning carried by icon + label).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// Pill verdict badge for the frozen verdict vocabulary (§4.2).
class VerdictBadge extends StatefulWidget {
  /// Verdict state. See [labelFor] for the verbatim word per state.
  final ProxStatus status;

  /// Override word. Defaults to [labelFor] — pass a custom label only for
  /// compound display (e.g. a session tile), never to rename a verdict.
  final String? label;

  /// Filled icon variant (active/selected contexts, §2.4). Defaults to
  /// outlined.
  final bool active;

  const VerdictBadge({
    super.key,
    required this.status,
    this.label,
    this.active = false,
  });

  /// Verbatim verdict word per state. Frozen vocabulary — rendering only.
  static String labelFor(ProxStatus status) => switch (status) {
        ProxStatus.marked => 'Marked',
        ProxStatus.late => 'Late',
        ProxStatus.wrongOrg => 'Wrong org',
        ProxStatus.noSignal => 'No signal',
        ProxStatus.review => 'Needs review',
        ProxStatus.waiting => 'Waiting',
        ProxStatus.pending => 'Pending',
      };

  @override
  State<VerdictBadge> createState() => _VerdictBadgeState();
}

class _VerdictBadgeState extends State<VerdictBadge>
    with SingleTickerProviderStateMixin {
  Timer? _pulse;
  var _dim = false;
  AnimationController? _pop;
  var _popArmed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery is readable here (not in initState). Reduced motion leaves
    // both the pulse and the pop disarmed — the badge never rebuilds.
    if (_popArmed) return;
    _popArmed = true;
    if (ProxMotion.reduced(context)) return;
    if (widget.status == ProxStatus.marked) _armPop(run: true);
    if (widget.status == ProxStatus.pending) _armPulse();
  }

  @override
  void didUpdateWidget(VerdictBadge old) {
    super.didUpdateWidget(old);
    if (old.status == widget.status || ProxMotion.reduced(context)) return;
    // Elastic just-marked transition lives INSIDE the component: it fires
    // when the state flips TO Marked, never as a separate widget.
    if (widget.status == ProxStatus.marked) _armPop(run: true);
    if (widget.status == ProxStatus.pending) {
      _armPulse();
    } else {
      _disarmPulse();
    }
  }

  void _armPop({required bool run}) {
    _pop ??= AnimationController(
      vsync: this,
      duration: ProxDurations.verdictPop,
    );
    if (run) _pop!.forward(from: 0);
  }

  void _armPulse() {
    if (_pulse != null) return;
    // Timer-driven toggle + implicit fade (never an infinite ticker), so
    // widget tests still settle and idle lists stay cheap.
    _pulse = Timer.periodic(ProxDurations.dotPulse, (_) {
      if (!mounted) return;
      setState(() => _dim = !_dim);
    });
  }

  void _disarmPulse() {
    _pulse?.cancel();
    _pulse = null;
    _dim = false;
  }

  @override
  void dispose() {
    _disarmPulse();
    _pop?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = ProxIcons.statusColor(context, widget.status);
    final icon = ProxIcons.statusIcon(widget.status, active: widget.active);
    final word = widget.label ?? VerdictBadge.labelFor(widget.status);

    Widget badge = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: ProxSpacing.md,
        vertical: ProxSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(ProxRadii.pill),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: ProxSpacing.xs),
          Flexible(
            child: Text(
              word,
              style: ProxType.label(color: color),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
    badge = Semantics(label: word, child: badge);

    if (ProxMotion.reduced(context)) return badge;

    // Pending dot-pulse: animated ONLY while actually pending.
    if (widget.status == ProxStatus.pending) {
      return AnimatedOpacity(
        duration: ProxDurations.dotPulse,
        curve: ProxCurves.standard,
        opacity: _dim ? 0.5 : 1.0,
        child: badge,
      );
    }
    // Elastic reserved for Marked (proves it just became Marked).
    final pop = _pop;
    if (widget.status == ProxStatus.marked && pop != null) {
      return ScaleTransition(
        scale: CurvedAnimation(parent: pop, curve: ProxCurves.verdictSpring),
        child: badge,
      );
    }
    return badge;
  }
}
