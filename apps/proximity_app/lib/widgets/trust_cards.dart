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
import 'sync_badge.dart';
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

/// Device trust badge: tier + window + server verdict.
///
/// Tiers (protocol evaluateDeviceProof):
/// FULL/STD fresh → confirmed; STALE (14d grace) → confirmed + banner;
/// NONE → device-unproven → manual path. An anomaly flag never
/// invalidates past attendance — it routes to professor/admin review.
class DeviceTrustBadge extends StatelessWidget {
  final String level;
  final int attestedUntilMillis;
  final bool anomaly;
  final String serverReason;
  final int serverVerifiedAtMillis;
  final String pkDHex;

  const DeviceTrustBadge({
    super.key,
    required this.level,
    this.attestedUntilMillis = 0,
    this.anomaly = false,
    this.serverReason = '',
    this.serverVerifiedAtMillis = 0,
    this.pkDHex = '',
  });

  ProxState get _state {
    if (anomaly) return ProxState.error;
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
    if (anomaly) return 'Flagged for review · $l';
    return switch (l) {
      'FULL' => 'Device trust FULL',
      'STD' => 'Device trust STD',
      'STALE' => 'Device trust STALE — re-attest soon',
      _ => 'Device unproven — manual path',
    };
  }

  @override
  Widget build(BuildContext context) {
    final until = trustDateLabel(attestedUntilMillis);
    final verified = trustDateLabel(serverVerifiedAtMillis);
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
              if (verified.isNotEmpty)
                'Server checked $verified'
              else
                'Server check pending',
              if (serverReason.isNotEmpty) 'Reason: $serverReason',
            ].join(' · '),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          if (anomaly) ...[
            const SizedBox(height: ProxSpacing.xs),
            Text(
              'Past attendance stands — a professor reviews flagged devices '
              'and marks manually meanwhile.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
            ),
          ],
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

/// Honest-unreachable: the professor server did not answer.
/// States whether hosting likely ended (purge path) or the network holed.
class HonestUnreachableCard extends StatelessWidget {
  final String host;
  final bool likelyEnded;
  const HonestUnreachableCard(
      {super.key, required this.host, this.likelyEnded = false});

  @override
  Widget build(BuildContext context) {
    return ProxCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.wifi_off_outlined),
          const SizedBox(width: ProxSpacing.sm),
          Expanded(
            child: Text(
              likelyEnded
                  ? 'Class at $host is unreachable — hosting likely ended. '
                      'Back to the live list; nothing was marked.'
                  : 'Professor unreachable at $host — check the IP and that '
                      'both devices are on the same WiFi. Nothing was marked; '
                      'retry when reachable.',
            ),
          ),
        ],
      ),
    );
  }
}

/// SyncEngine status strip: unsynced badge count + online/offline +
/// backfill note. Thin wrapper over [UnsyncedBadge] counts so every
/// records/setup screen says the same thing.
class SyncStatusStrip extends StatelessWidget {
  final int pending;
  final bool online;
  final String? note;
  const SyncStatusStrip({
    super.key,
    required this.pending,
    required this.online,
    this.note,
  });

  @override
  Widget build(BuildContext context) {
    if (!online && pending <= 0) {
      return const ProxSyncNote('Offline — this device only.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Shared with the live badge (was a duplicated Chip).
        if (pending > 0) PendingCountChip(pending: pending, online: online),
        ProxSyncNote(
          note ??
              (online
                  ? (pending > 0
                      ? 'Synced with cloud ($pending still pending).'
                      : 'Synced with cloud.')
                  : 'Offline — $pending queued, syncs on reconnect.'),
        ),
      ],
    );
  }
}
