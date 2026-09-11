//
// Device section (Account menu): local key facts + move status. It
// also shows the Device ID (install id, SelectableText abbreviated + full)
// and the DKey fingerprint via the existing trust helper
// (`trustPkDFingerprint`). The trust tier stays TRUTHFUL — a
// software-backed build still reports its real NONE level, never a faked
// FULL; only the presentation improves (bound facts first + a
// plain-language software-key note). No attestation invented.
library;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth.dart';
import '../../core/cloud_sync.dart';
import '../../core/device_store.dart';
import '../../design/tokens.dart';
import '../../widgets/details_expander.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/trust_cards.dart';
import '../entry/entry_flow.dart';
import 'account_common.dart';
import 'device_rules.dart';

/// Device section: local key facts + move status + collapsed
/// offline/hosting note. Refusal copy comes from `studentClaimMessage`
/// verbatim — the same words the enroll claim refuses with.
class AccountDeviceSection extends ConsumerWidget {
  final SignedAccount acct;
  const AccountDeviceSection({required this.acct, super.key});

  Future<String> _installId(WidgetRef ref) async {
    // Read-only: viewing Device must not create an install id (same rule
    // as the prof facts — `readInstallId`, never `getOrCreateInstallId`).
    try {
      return await ref.read(deviceStoreProvider).readInstallId() ?? '';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<StoredEnrollment?>(
      future: readAccountEnrollment(ref),
      builder: (context, enrollSnap) {
        // Scoped to the current account (stale-account fix): a previous
        // account's stored enrollment renders as "no key for this
        // account", never as this account's facts.
        final e = storedForAccount(acct, enrollSnap.data);
        return FutureBuilder<StudentGate?>(
          future: moveGateForAccount(ref, acct.email),
          builder: (context, gateSnap) {
            final loading =
                enrollSnap.connectionState == ConnectionState.waiting ||
                    gateSnap.connectionState == ConnectionState.waiting;
            if (loading) {
              return const Center(child: CircularProgressIndicator());
            }
            final gate = gateSnap.data;
            final binding = gate?.binding;
            // Device model: no device-info plumbing exists anywhere (same
            // class as the photo gap — not invented). The existing signal
            // is the claim-stamped platform label, else the local one.
            final platform =
                (binding != null && binding.platform.trim().isNotEmpty)
                    ? binding.platform
                    : defaultTargetPlatform.name;
            // Bound facts first: prefer the cloud binding's DKey/level when
            // present, else the local enrollment's — both are the device's
            // own claims, never invented tiers.
            final pkDHex = (binding != null && binding.pkDHex.isNotEmpty)
                ? binding.pkDHex
                : (e?.pkDHex ?? '');
            final level = (binding != null && binding.attestationLevel.isNotEmpty)
                ? binding.attestationLevel
                : (e?.attestationLevel ?? 'NONE');
            final untilMillis = (binding != null && binding.attestedUntilMillis != 0)
                ? binding.attestedUntilMillis
                : (e != null
                    ? e.attestedUntil.toUtc().millisecondsSinceEpoch
                    : 0);
            return FutureBuilder<String>(
              future: _installId(ref),
              builder: (context, idSnap) {
                final installId = (idSnap.data ?? '').trim();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AccountFactRow('Device model', platform),
                    // Device ID: abbreviated fact + full SelectableText for
                    // copy-paste (support/debugging). Read-only display.
                    AccountFactRow(
                      'Device ID',
                      installId.isEmpty
                          ? 'Not assigned yet'
                          : accountShortKey(installId),
                      mono: installId.isNotEmpty,
                      key: const Key('account-device-id-row'),
                    ),
                    if (installId.isNotEmpty) ...[
                      const SizedBox(height: ProxSpacing.xs),
                      SelectableText(
                        installId,
                        key: const Key('account-device-id-full'),
                        style: ProxType.monoBody(
                            color: ProximityColors.of(context)
                                .contentSecondary),
                      ),
                      const SizedBox(height: ProxSpacing.xs),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const Key('account-device-id-copy'),
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('Copy'),
                          onPressed: () {
                            Clipboard.setData(
                                ClipboardData(text: installId));
                          },
                        ),
                      ),
                    ],
                    // Key fingerprint via the existing trust helper (DKey).
                    AccountFactRow(
                      'Key fingerprint',
                      trustPkDFingerprint(pkDHex),
                      mono: true,
                      key: const Key('account-device-key-row'),
                    ),
                    if (e == null)
                      const ProxSyncNote(
                        accountNoKeyNote,
                      )
                    else ...[
                      const SizedBox(height: ProxSpacing.md),
                      ProxStateBadge(
                          state: ProxState.marked, label: 'Enrolled as ${e.email}'),
                      const SizedBox(height: ProxSpacing.sm),
                      ProxSyncNote(
                        '${e.name} · ${e.roll} · key ${accountShortKey(e.pkHex)}',
                      ),
                    ],
                    const SizedBox(height: ProxSpacing.lg),
                    // Truthful trust tier (never faked): the badge reports
                    // the bound level verbatim (software builds read NONE).
                    DeviceTrustBadge(
                      level: level.isEmpty ? 'NONE' : level,
                      attestedUntilMillis: untilMillis,
                      pkDHex: pkDHex,
                    ),
                    const SizedBox(height: ProxSpacing.sm),
                    ProxSyncNote(
                      'This build uses software-backed keys — attendance still marks through the flagged fallback, with every other check still run.',
                      key: Key('account-trust-note'),
                    ),
                    const SizedBox(height: ProxSpacing.lg),
                    _moveStatus(gate),
                    const SizedBox(height: ProxSpacing.md),
                    DetailsExpander(
                      title: 'Offline & hosting',
                      child: Text(
                        'Offline professors keep everything on this device. Sign in later to back up, sync across devices, and share CSVs from the cloud.',
                        style: ProxType.body(),
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  /// Move-status body for a known gate verdict. Trust tier rides below
  /// every verdict when a binding exists (never silent).
  Widget _moveStatus(StudentGate? gate) {
    if (gate == null) {
      return const ProxSyncNote(
        'Connect to check move status — one enrolled device per Gmail is checked online.',
      );
    }
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ProxStateBadge(state: ProxState.marked, label: 'Active'),
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ProxStateBadge(
                state: ProxState.waiting, label: 'Eligible to move here'),
            ProxSyncNote(deviceAllowedMoveNote()),
            if (trust != null) ...[
              const SizedBox(height: ProxSpacing.sm),
              trust,
            ],
          ],
        );
      case StudentClaim.cooldownBlocked:
      case StudentClaim.installConflict:
        final retry = gate.verdict.retryAfter;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (gate.verdict.claim == StudentClaim.cooldownBlocked &&
                retry != null)
              ProxStateBadge(
                state: ProxState.waiting,
                // Global date rule, display only: DD-MM-YYYY.
                label: 'Move cooldown until ${displayDateOf(retry.toUtc())}',
              ),
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
