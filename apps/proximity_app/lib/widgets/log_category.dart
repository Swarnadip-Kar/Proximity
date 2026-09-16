// Log tag-chip category colors (§4.5).
//
// Tag chips are colored by category from the `status.*`/`accent.brand`
// family. Log LINE colors stay on the frozen [ProxLogColors] terminal
// vocabulary — this mapping only tells subsystems apart on chips, in both
// the drawer and the full-screen terminal.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// Tag-chip dot color by category.
Color logCategoryColor(BuildContext context, String tag) {
  final c = ProximityColors.of(context);
  return switch (tag) {
    // Radio + transport path.
    ProxLogTags.ble ||
    ProxLogTags.mesh ||
    ProxLogTags.lan ||
    ProxLogTags.net ||
    ProxLogTags.transport =>
      c.accentBrand,
    // Trust + identity path.
    ProxLogTags.sec || ProxLogTags.crypto || ProxLogTags.face =>
      c.statusReview,
    // Data-flow path.
    ProxLogTags.sync || ProxLogTags.session || ProxLogTags.clock =>
      c.statusLate,
    // Meta path.
    _ => c.contentSecondary,
  };
}
