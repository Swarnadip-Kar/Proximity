// Browse thin banner (student mark): recoverable, non-blocking conditions
// stay on-screen in words, never as a modal (§4.6).
//
// Single-purpose split from `browse_classes.dart` (Mark slim-down): the
// join-error and broadcast-blocked banners share this one dismissible
// inline banner. Copy strings live with the callers (verbatim, frozen);
// this file owns only the banner chrome on the card-radius token.
library;

import 'package:flutter/material.dart';

import '../../design/tokens.dart';

/// Thin dismissible inline banner (§4.6): recoverable, non-blocking
/// conditions stay on-screen in words, never as a modal.
class BrowseBanner extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback onDismiss;

  const BrowseBanner({
    super.key,
    required this.icon,
    required this.text,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Container(
      padding: const EdgeInsets.all(ProxSpacing.md),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: ProxRadii.cardSpecRadius,
        border: Border.all(color: c.divider),
        boxShadow: [c.elevationRaised],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: c.statusError),
          const SizedBox(width: ProxSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: ProxType.body(color: c.contentPrimary),
            ),
          ),
          const SizedBox(width: ProxSpacing.sm),
          SizedBox(
            width: ProxSpacing.minTap,
            height: ProxSpacing.minTap,
            child: IconButton(
              tooltip: 'Dismiss',
              padding: EdgeInsets.zero,
              onPressed: onDismiss,
              icon: Icon(Icons.close, size: 20, color: c.contentSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
