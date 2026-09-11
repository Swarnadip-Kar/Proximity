// DetailsExpander — text minimalism as a component (§4.7).
//
// Collapsed by default: shows a single disclosure row, expands in place to
// reveal secondary explanation copy that today sits inline
// (discovery/ladder explanations, org/trust-tier prose, sync mechanics,
// offline/hosting notes). Every screen with more than the terse status +
// next-action line uses this instead of inline paragraphs.
//
// HARD RULE: widget-test-relevant copy (`Start`, `Join`, `Marked`, field
// keys, exact verdict strings) stays exactly as-is and is NEVER moved
// inside the expander — only explanatory prose (the "why"/"how it works"
// copy) is collapsible. A DetailsExpander may link out to `debug/log`
// instead of containing prose, when the detail really is log data.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// Collapsed-by-default in-place disclosure for secondary explanation.
class DetailsExpander extends StatefulWidget {
  /// Disclosure row label. Defaults to `Details`.
  final String title;

  /// Explanatory prose (never test-relevant copy — see file docs).
  final Widget child;

  /// Open on first build. Defaults to false (collapsed).
  final bool initiallyExpanded;

  const DetailsExpander({
    super.key,
    this.title = 'Details',
    required this.child,
    this.initiallyExpanded = false,
  });

  @override
  State<DetailsExpander> createState() => _DetailsExpanderState();
}

class _DetailsExpanderState extends State<DetailsExpander> {
  late var _open = widget.initiallyExpanded;

  @override
  void didUpdateWidget(DetailsExpander old) {
    super.didUpdateWidget(old);
    if (old.initiallyExpanded != widget.initiallyExpanded) {
      _open = widget.initiallyExpanded;
    }
  }

  void _toggle() => setState(() => _open = !_open);

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: _toggle,
          borderRadius: BorderRadius.circular(ProxRadii.chip),
          child: AnimatedContainer(
            duration:
                ProxMotion.effective(context, ProxDurations.small),
            curve: ProxCurves.standard,
            constraints:
                const BoxConstraints(minHeight: ProxSpacing.minTap),
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(
              horizontal: ProxSpacing.sm,
              vertical: ProxSpacing.xs,
            ),
            decoration: BoxDecoration(
              color: _open
                  ? c.accentBrand.withValues(alpha: 0.07)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(ProxRadii.chip),
            ),
            child: Row(
              children: [
                // Brand accent tick mirrors the section-header language.
                AnimatedContainer(
                  duration: ProxMotion.effective(
                      context, ProxDurations.small),
                  width: 2,
                  height: _open ? 16 : 12,
                  decoration: BoxDecoration(
                    gradient: _open ? c.gradientBrand : null,
                    color: _open ? null : c.divider,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
                const SizedBox(width: ProxSpacing.sm),
                Expanded(
                  child: Text(
                    widget.title,
                    style: ProxType.label(
                      color:
                          _open ? c.contentPrimary : c.contentSecondary,
                    ).copyWith(
                      fontWeight:
                          _open ? FontWeight.w600 : FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                AnimatedRotation(
                  turns: _open ? 0.5 : 0.0,
                  duration: ProxMotion.effective(
                    context,
                    ProxDurations.small,
                  ),
                  child: Icon(
                    Icons.expand_more,
                    size: 20,
                    color:
                        _open ? c.accentBrand : c.contentSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: Padding(
            padding: const EdgeInsets.only(bottom: ProxSpacing.sm),
            child: widget.child,
          ),
          crossFadeState: _open
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration:
              ProxMotion.effective(context, ProxDurations.small),
          sizeCurve: ProxCurves.standard,
        ),
      ],
    );
  }
}
