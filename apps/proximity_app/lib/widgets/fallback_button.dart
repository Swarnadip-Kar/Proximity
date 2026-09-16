// FallbackButton pattern (§4.4) + shared bottom-sheet chrome (§3.2, §6.4).
//
// Any path that is a fallback (manual IP entry, manual attendance request,
// directory manual-add, Bluetooth-off prompt) renders as a SINGLE
// low-emphasis text button — never a full-width primary button, never
// inline form fields on the main screen. Tapping opens a bottom sheet
// containing the actual field(s).
//
// Sheet chrome: `gradient.scrim` behind (its end-stop color — a barrier
// takes a color, not a gradient), `effect.elevation.sheet` on the sheet,
// `sheetTopRadius` top corners. Keyboard-safe per §10.1: the sheet is
// scroll-controlled, pads `MediaQuery.viewInsets` at the bottom, and wraps
// content in a scroll view so fields are never covered or clipped by the
// keyboard. Inner lists that size to content must use `shrinkWrap: true` +
// `NeverScrollableScrollPhysics` (or a bounded height) — never an
// unbounded-height exception.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// Opens a Proximity bottom sheet: scrim behind, elevated sheet, drag
/// handle, title, then [builder] content. Keyboard-safe (viewInsets-padded
/// + scrollable). Returned future completes with the sheet's pop value.
Future<T?> showProxSheet<T>({
  required BuildContext context,
  required String title,
  required Widget Function(BuildContext context) builder,
}) {
  // Dead-screen guard: callers awaiting a previous sheet/dialog may resume
  // after dispose — never open a sheet on an unmounted context.
  if (!context.mounted) return Future.value(null);
  final c = ProximityColors.of(context);
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // Scrim token end-stop: the barrier API takes a flat color, so the
    // token's own end color is used — never a hand-authored dim.
    barrierColor: c.gradientScrim.colors.last,
    // Transparent so the custom decoration below shows; the token's own
    // transparent stop (not a raw transparent constant).
    backgroundColor: c.gradientScrim.colors.first,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(ProxRadii.sheet),
      ),
    ),
    builder: (sheetContext) {
      final cc = ProximityColors.of(sheetContext);
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: SingleChildScrollView(
          // Landscape breathing (§10 ≥600dp rule): sheets stay bounded
          // and centered instead of stretching full width on wide
          // landscape phones. Portrait widths (<560) fill as before —
          // the ConstrainedBox only caps, never stretches — so portrait
          // rendering is pixel-identical.
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                  maxWidth: ProxSpacing.maxContentWidth),
              child: Container(
                decoration: BoxDecoration(
                  color: cc.surfaceRaised,
                  borderRadius: ProxRadii.sheetTopRadius,
                  boxShadow: [cc.elevationSheet],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: ProxSpacing.sm),
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: cc.divider,
                          borderRadius:
                              BorderRadius.circular(ProxRadii.pill),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        ProxSpacing.screenMargin,
                        ProxSpacing.md,
                        ProxSpacing.screenMargin,
                        ProxSpacing.sm,
                      ),
                      child: Text(
                        title,
                        style: ProxType.title(color: cc.contentPrimary),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        ProxSpacing.screenMargin,
                        0,
                        ProxSpacing.screenMargin,
                        ProxSpacing.screenMargin,
                      ),
                      child: builder(sheetContext),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Low-emphasis entry into a fallback sheet. Renders as a single text
/// button (optionally with a leading icon) — fallback weight, never
/// primary.
class FallbackButton extends StatelessWidget {
  /// Button label (e.g. `Enter IP manually`).
  final String label;

  /// Leading icon. Outlined family by default.
  final IconData icon;

  /// Sheet title shown after tap.
  final String sheetTitle;

  /// The actual fallback field(s) rendered inside the sheet.
  final Widget Function(BuildContext context) sheetBuilder;

  final Key? buttonKey;

  const FallbackButton({
    super.key,
    required this.label,
    required this.sheetTitle,
    required this.sheetBuilder,
    this.icon = Icons.more_horiz,
    this.buttonKey,
  });

  /// Opens the sheet directly (e.g. from tests or a secondary affordance).
  Future<void> openSheet(BuildContext context) => showProxSheet<void>(
        context: context,
        title: sheetTitle,
        builder: sheetBuilder,
      );

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    // Ghost brand treatment: brand border, transparent fill, 4% brand
    // tint on hover — fallback weight, never primary.
    return OutlinedButton.icon(
      key: buttonKey,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, ProxSpacing.minTap),
        foregroundColor: c.accentBrand,
        side: BorderSide(
          color: c.accentBrand.withValues(alpha: 0.4),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ProxRadii.pill),
        ),
      ).copyWith(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered)) {
            return c.accentBrand.withValues(alpha: 0.04);
          }
          return Colors.transparent;
        }),
      ),
      onPressed: () => openSheet(context),
      icon: Icon(icon, size: ProxIconSizes.md),
      label: Text(label, overflow: TextOverflow.ellipsis),
    );
  }
}
