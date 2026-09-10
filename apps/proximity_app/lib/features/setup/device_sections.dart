// Device & identity sections: account / key / move status.
//
// Split from device_identity_screen.dart (presentation only — same copy,
// same guards, same verdicts). The content state owns the store/gate
// reads and sign-out; sections own the layout. Refusal copy comes from
// studentClaimMessage verbatim; only the offline-professor note collapses
// behind a DetailsExpander (§4.7).
library;

import 'package:flutter/material.dart';

import '../../core/auth.dart';
import '../../core/cloud_sync.dart';
import '../../core/device_store.dart';
import '../../mode.dart';
import '../../design/tokens.dart';
import 'setup_details.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/trust_cards.dart';
import '../account/account_common.dart';
import '../entry/entry_flow.dart';

/// Signed-in account block (with the wrong-account warning when the
/// device enrollment belongs to a different Gmail).
class DeviceAccountSection extends StatelessWidget {
  final SignedAccount? account;
  final LinkedIdentity? linked;

  const DeviceAccountSection({
    super.key,
    required this.account,
    required this.linked,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final acct = account;
    final linkedId = linked;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ProxSectionHeader(
          title: 'Signed in',
          padding: EdgeInsets.zero,
        ),
        if (acct == null)
          const ProxSyncNote(
              'Not signed in — sign in from the welcome screen.')
        else ...[
          Text('Signed in as ${acct.displayName}',
              textAlign: TextAlign.center, style: text.titleMedium),
          Text(acct.email,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              )),
          if (linkedId != null &&
              linkedId.gmail.toLowerCase() != acct.email.toLowerCase()) ...[
            const SizedBox(height: ProxSpacing.sm),
            ProxErrorNote(
              'Note: this device is enrolled as ${linkedId.gmail} — different from the signed-in account. '
              'Wrong account? Switch below.',
            ),
          ],
        ],
      ],
    );
  }
}

/// This-device key block: enrollment badge or the no-key note.
class DeviceKeySection extends StatelessWidget {
  final Future<StoredEnrollment?> Function() loadEnrollment;

  const DeviceKeySection({super.key, required this.loadEnrollment});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ProxSectionHeader(title: 'This device'),
        FutureBuilder<StoredEnrollment?>(
          future: loadEnrollment(),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final e = snap.data;
            if (e == null) {
              return const ProxSyncNote(
                accountNoKeyNote,
              );
            }
            final shortPk = e.pkHex.length <= 12
                ? e.pkHex
                : '${e.pkHex.substring(0, 12)}…';
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ProxStateBadge(
                    state: ProxState.marked, label: 'Enrolled as ${e.email}'),
                ProxSyncNote(
                  '${e.name} · ${e.roll} · key $shortPk',
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Move-status block: the signed-in Gmail against the one-device rule.
/// The verdict body is shared with the enroll claim (same reasons the
/// server refuses); the binding's trust tier rides below every verdict.
class DeviceMoveSection extends StatelessWidget {
  final String? email;
  final Future<StudentGate?> Function(String? email) loadGate;

  const DeviceMoveSection({
    super.key,
    required this.email,
    required this.loadGate,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ProxSectionHeader(title: 'Move status'),
        if (email == null)
          const ProxSyncNote(
              'Sign in to check this Gmail against the one-device rule.')
        else
          FutureBuilder<StudentGate?>(
            future: loadGate(email),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final gate = snap.data;
              if (gate == null) {
                return const ProxSyncNote(
                  'Connect to check move status — one enrolled device per Gmail is checked online.',
                );
              }
              return _gateBody(gate);
            },
          ),
      ],
    );
  }

  /// Move-status body for a known gate verdict. Refusal copy comes from
  /// [studentClaimMessage] — the same words the enroll claim refuses with.
  /// The binding's trust tier rides below every verdict
  /// (Tracks 2+3 FULL/STD/STALE/NONE — never silent).
  Widget _gateBody(StudentGate gate) {
    final b = gate.binding;
    final trust = b == null
        ? null
        : DeviceTrustBadge(
            level: b.attestationLevel,
            attestedUntilMillis: b.attestedUntilMillis,
            pkDHex: b.pkDHex,
          );
    switch (gate.verdict.claim) {
      case StudentClaim.firstBind:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ProxStateBadge(
                state: ProxState.neutral, label: 'Not enrolled yet'),
            const ProxSyncNote(
                'This install is free to enroll — first bind takes it.'),
            if (trust != null) ...[
              const SizedBox(height: ProxSpacing.sm),
              trust,
            ],
          ],
        );
      case StudentClaim.sameDevice:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ProxStateBadge(
                state: ProxState.marked,
                label: 'This device holds the enrollment'),
            const ProxSyncNote('Re-keys and re-enrolls here are always free.'),
            if (trust != null) ...[
              const SizedBox(height: ProxSpacing.sm),
              trust,
            ],
          ],
        );
      case StudentClaim.allowedMove:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ProxStateBadge(
                state: ProxState.waiting, label: 'Eligible to move here'),
            const ProxSyncNote(
                'The 30 days since the last move have passed — enrolling here moves it (at most once a month).'),
            if (trust != null) ...[
              const SizedBox(height: ProxSpacing.sm),
              trust,
            ],
          ],
        );
      case StudentClaim.cooldownBlocked:
      case StudentClaim.installConflict:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ProxErrorNote(studentClaimMessage(gate.verdict, gate.binding)),
            if (trust != null) ...[
              const SizedBox(height: ProxSpacing.sm),
              trust,
            ],
          ],
        );
    }
  }
}

/// Offline-professor local-only note, collapsed (§4.7) — same sentence
/// verbatim. Rendered under the key/move blocks on capable devices.
class DeviceOfflineNote extends StatelessWidget {
  const DeviceOfflineNote({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return SetupDetails(
      title: 'Offline professors',
      child: Text(
        'Offline professors keep everything on this device. Sign in later '
        'to back up, sync across devices, and share CSVs from the cloud.',
        textAlign: TextAlign.center,
        style: text.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
