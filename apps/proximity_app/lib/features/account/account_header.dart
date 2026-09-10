// Account header section — moved verbatim from `account_screen.dart`
// (`_HeaderCard` → [AccountHeaderCard]; presentational split only).
library;

import 'package:flutter/material.dart';

import '../../core/auth.dart';
import '../../design/tokens.dart';
import '../../widgets/account_chip.dart';

/// Rounded Account header card. Tester fix (flat-square header): the
/// large-header wash rendered as an unbordered square — it now sits in a
/// token-driven card (spec card radius, flat elevation-border treatment,
/// zero shadow like the app card theme), clipped to the same radius. The
/// approved large-header gradient wash itself is untouched inside.
class AccountHeaderCard extends StatelessWidget {
  final SignedAccount acct;
  const AccountHeaderCard({required this.acct, super.key});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ProxSpacing.xs),
      child: Container(
        key: const Key('account-header-card'),
        decoration: BoxDecoration(
          color: c.surfaceRaised,
          borderRadius: ProxRadii.cardSpecRadius,
          border: Border.all(color: c.divider),
        ),
        clipBehavior: Clip.antiAlias,
        child: AccountChip(
          displayName: acct.displayName,
          email: acct.email,
          photoUrl: acct.photoUrl,
          largeHeader: true,
        ),
      ),
    );
  }
}
