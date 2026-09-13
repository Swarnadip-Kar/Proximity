// Professor-email verification badge (anti-fake-professor, offline-first).
//
// The prof email travels ONLY on the gated /window unicast (never beacons
// / BLE), and the email→key binding is verified against the pinned lecture
// keys (`profDevices/{email}` cache + live fetch) BEFORE the student signs
// anything (see RealStudentDriver._prove). This badge renders that verdict:
//
//   verified (live)    — pinned key matched on a direct online fetch.
//   verified (cached)  — pinned key matched the persistent cache offline.
//   unverified         — first-seen email (TOFU): allowed with this banner,
//                        queued for auto-verify when the app returns online.
//   mismatch (blocked) — pin list exists but the presented key is absent:
//                        the driver sent NO proof; this badge explains why.
//   unknown host       — legacy host with no email; no claim is made.
//
// Never shows an email as verified from beacons/BLE alone — only from the
// gated unicast + pin verdict above.
library;

import 'package:flutter/material.dart';

import '../core/student_driver.dart'
    show ProfEmailVerification, ProfVerificationResult;

/// Compact verification badge for a professor email row.
class ProfVerifiedBadge extends StatelessWidget {
  final ProfVerificationResult? verification;
  const ProfVerifiedBadge({super.key, required this.verification});

  @override
  Widget build(BuildContext context) {
    final v = verification;
    if (v == null || v.profEmail.isEmpty) {
      return const SizedBox.shrink();
    }
    switch (v.state) {
      case ProfEmailVerification.verified:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              v.liveFetch ? Icons.verified : Icons.verified_outlined,
              size: 14,
              color: Colors.green.shade700,
            ),
            const SizedBox(width: 4),
            Text(
              v.liveFetch ? 'Verified · live' : 'Verified',
              style: TextStyle(
                fontSize: 12,
                color: Colors.green.shade700,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        );
      case ProfEmailVerification.unverified:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.help_outline,
              size: 14,
              color: Colors.amber.shade800,
            ),
            const SizedBox(width: 4),
            Text(
              'Unverified — first seen (auto-verifies online)',
              style: TextStyle(
                fontSize: 12,
                color: Colors.amber.shade800,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        );
      case ProfEmailVerification.mismatch:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.block, size: 14, color: Colors.red),
            const SizedBox(width: 4),
            const Text(
              'Blocked — key mismatch (no proof sent)',
              style: TextStyle(
                fontSize: 12,
                color: Colors.red,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        );
      case ProfEmailVerification.absent:
        return const SizedBox.shrink();
    }
  }
}
