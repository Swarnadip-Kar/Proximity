// Proving (student mark): the radio wait after the face passes. The
// student never sees a countdown or round timing — only what is happening
// right now, as a step tracker (Signed → Sent → Confirmed) whose dots fill
// on the existing driver status callbacks (same signals, componentized).
// The clock-drift banner sits above it as a thin banner — same honesty as
// today, never a dialog.
library;

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_states.dart';

/// Step index driven by the driver's status line (same callback, same
/// strings — the mapping only componentizes them):
/// - `Waiting for the class signal…` → step 0 active (signing);
/// - `Signal heard — proving…` → Signed done, step 1 active (sending);
/// - `Proof sent — confirming…` → Signed + Sent done, step 2 active.
int proveStepForStatus(String status) => switch (status) {
      'Signal heard — proving…' => 1,
      'Proof sent — confirming…' => 2,
      _ => 0,
    };

class ProvingView extends StatelessWidget {
  final String status;

  /// Clock-drift banner copy from the student driver's tracker (null when
  /// clocks agree): shown honestly instead of verdicting late silently.
  final String? driftBanner;

  const ProvingView({
    super.key,
    required this.status,
    this.driftBanner,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final drift = driftBanner;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(ProxSpacing.screenMargin),
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: ProxSpacing.maxContentWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (drift != null) ...[
                _DriftBanner(text: drift),
                const SizedBox(height: ProxSpacing.md),
              ],
              const ProxLoadingRow(label: 'Proving…'),
              const SizedBox(height: ProxSpacing.lg),
              _ProveSteps(active: proveStepForStatus(status)),
              const SizedBox(height: ProxSpacing.md),
              ProxSwitcher(
                child: Text(
                  status,
                  key: ValueKey<String>(status),
                  style: ProxType.body(color: c.contentPrimary),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Horizontal step tracker: Signed → Sent → Confirmed. Dots fill as the
/// corresponding driver status fires, so a student mid-lecture sees where
/// the proof is stuck without reading log lines. Icon + text always carry
/// the state (never motion or color alone).
class _ProveSteps extends StatelessWidget {
  /// Index of the currently active step (steps before it read done).
  final int active;

  const _ProveSteps({required this.active});

  static const _labels = ['Signed', 'Sent', 'Confirmed'];

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    // §10.1: the row is width-BOUNDED (max) with loose flexibles per step,
    // so long step words ellipsize inside their third instead of striping
    // a RenderFlex at narrow widths × large system type (measured 38px
    // overflow at 350dp/130% before this). Loose fit keeps the huddled
    // centered look at normal sizes — flex only caps, never stretches.
    // Full words survive via the Semantics label (screen readers); the
    // visible degradation is truncate (ellipsis), never clip (§9).
    return Semantics(
      label: 'Step ${active + 1} of 3: ${_labels[active.clamp(0, 2)]}',
      child: Row(
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < _labels.length; i++) ...[
            if (i > 0)
              Container(
                width: 32,
                height: 2,
                margin: const EdgeInsets.only(
                  left: ProxSpacing.sm,
                  right: ProxSpacing.sm,
                  top: 11,
                ),
                color: i <= active
                    ? c.statusMarked
                    : c.contentTertiary.withValues(alpha: 0.4),
              ),
            Flexible(
              fit: FlexFit.loose,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i < active
                          ? c.statusMarked
                          : i == active
                              ? c.accentBrand.withValues(alpha: 0.15)
                              : c.contentTertiary.withValues(alpha: 0.15),
                      border: Border.all(
                        color: i < active
                            ? c.statusMarked
                            : i == active
                                ? c.accentBrand
                                : c.contentTertiary,
                        width: 2,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: i < active
                        ? Icon(Icons.check, size: 14, color: c.surfaceRaised)
                        : i == active
                            ? Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: c.accentBrand,
                                ),
                              )
                            : null,
                  ),
                  const SizedBox(height: ProxSpacing.xs),
                  Text(
                    _labels[i],
                    textAlign: TextAlign.center,
                    style: ProxType.caption(
                      color: i <= active ? c.contentPrimary : c.contentTertiary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Thin clock-drift banner (honest, non-blocking): the driver's verbatim
/// copy, restyled as a banner instead of a dialog.
class _DriftBanner extends StatelessWidget {
  final String text;

  const _DriftBanner({required this.text});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Container(
      padding: const EdgeInsets.all(ProxSpacing.md),
      decoration: BoxDecoration(
        color: c.statusLate.withValues(alpha: 0.12),
        borderRadius: ProxRadii.cardSpecRadius,
        border: Border.all(
          color: c.statusLate.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.schedule_outlined, size: 20, color: c.statusLate),
          const SizedBox(width: ProxSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: ProxType.body(color: c.contentPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
