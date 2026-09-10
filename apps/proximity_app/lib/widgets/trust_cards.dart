// Shared trust + honesty cards (Track 5).
//
// One place for every settled-design state that previously lived as ad-hoc
// copy across entry/mark/records screens:
//   - device trust tiers FULL/STD/STALE/NONE + attestation anomaly flags
//     (Tracks 2+3 dual-key model + §3.4 server re-verifier);
//   - org-scoped identity wrong-org refusals (Track 1);
//   - honest-unreachable (Track 4: unreachable is stated, never silent);
//   - SyncEngine status strip (unsynced badge counts, offline/online,
//     backfill — Track 4 §4).
//
// Presentation only: all verdicts arrive as plain args from the
// narrow domain interfaces (DeviceKey, StudentDeviceDoc, SyncEngine
// pendingCount, WindowProbe). No widget here signs, verifies, or mutates
// sync state.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import 'prox_cards.dart';
import 'prox_states.dart';
import '../core/sync/store/record_helpers.dart' as rh;

/// UTC epoch millis as yyyy-MM-dd ('' when 0).
String trustDateLabel(int millis) {
  if (millis <= 0) return '';
  return rh.dateIsoOf(DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true));
}

/// Short DKey fingerprint (first 12 hex + ellipsis).
String trustPkDFingerprint(String pkDHex) {
  final h = pkDHex.trim();
  if (h.isEmpty) return 'no key';
  return h.length <= 12 ? h : '${h.substring(0, 12)}…';
}

/// Device trust badge: tier + window + key. All offline and holder-local:
/// the level is self-asserted by the enrolling client (no server re-check
/// exists), so this badge is transparency about what THIS device claims —
/// trust decisions happen on the professor's side per proof (dSig +
/// ticket + sighting), not here.
///
/// Tiers (protocol evaluateDeviceProof + verifyProve NONE fallback):
/// FULL/STD fresh → confirmed; STALE (14d grace) → confirmed + banner;
/// NONE claims no tier but still marks via the flagged
/// `device-none-fallback` (same ticket/Sig_s/face/sighting checks) until
/// HW keys ship — the badge below stays honest about the claim.
class DeviceTrustBadge extends StatelessWidget {
  final String level;
  final int attestedUntilMillis;
  final String pkDHex;

  const DeviceTrustBadge({
    super.key,
    required this.level,
    this.attestedUntilMillis = 0,
    this.pkDHex = '',
  });

  ProxState get _state {
    switch (level.trim().toUpperCase()) {
      case 'FULL':
      case 'STD':
        return ProxState.marked;
      case 'STALE':
        return ProxState.waiting;
      default:
        return ProxState.neutral;
    }
  }

  String get _label {
    final l = level.trim().isEmpty ? 'NONE' : level.trim().toUpperCase();
    return switch (l) {
      'FULL' => 'Device trust FULL',
      'STD' => 'Device trust STD',
      'STALE' => 'Device trust STALE — re-attest soon',
      _ => 'Device NONE — no hardware tier (fallback-marked)',
    };
  }

  @override
  Widget build(BuildContext context) {
    final until = trustDateLabel(attestedUntilMillis);
    return ProxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ProxStateBadge(state: _state, label: _label),
          const SizedBox(height: ProxSpacing.xs),
          Text(
            [
              if (until.isNotEmpty) 'Attested until $until',
              'Key ${trustPkDFingerprint(pkDHex)}',
            ].join(' · '),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}

/// Wrong-org refusal: the class belongs to another institute org.
/// No proof is sent (no PII leaves); the student joins their own org class.
class WrongOrgCard extends StatelessWidget {
  final String classOrg;
  final String myOrg;
  const WrongOrgCard(
      {super.key, required this.classOrg, required this.myOrg});

  @override
  Widget build(BuildContext context) {
    return ProxCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.domain_outlined,
              color: ProxStateColors.of(context, ProxState.error)),
          const SizedBox(width: ProxSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Wrong organization for this class',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: ProxSpacing.xs),
                Text(
                  'This class is for $classOrg, but you are signed in as $myOrg. '
                  'No proof was sent. Join your institute class instead — '
                  'cross-org marking is refused by design.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
