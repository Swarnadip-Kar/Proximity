// Device & identity sections: account / key / move status.
//
// Split from the screen, one purpose per widget (same guards, same
// verdicts). The content state owns the store/gate reads and sign-out; sections own the layout. Refusal copy comes from
// studentClaimMessage verbatim; only the offline-professor note collapses
// behind a DetailsExpander (§4.7).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth.dart';
import '../../core/cloud_sync.dart';
import '../../core/device_store.dart';
import '../../mode.dart';
import '../../design/tokens.dart';
import 'setup_details.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/trust_cards.dart';
import '../account/account_common.dart';
import '../account/device_rules.dart';
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
///
/// Memoized: the future is created once per account (not per build) — an
/// inline `future: load()` would fire a new store read on every parent
/// rebuild. A locked store (transient failure) renders an explicit Retry;
/// success flips the linked identity, which is part of the memo key and
/// refreshes the read. Genuine absence still renders the no-key note.
class DeviceKeySection extends ConsumerStatefulWidget {
  final Future<StoredEnrollment?> Function() loadEnrollment;

  /// Signed-in account for the explicit unlock retry (null hides Retry).
  final SignedAccount? account;

  /// Linked-identity Gmail: part of the memo key, so an unlock performed
  /// anywhere refreshes this read (cache-warmed, prompt-free).
  final String? linkedGmail;

  const DeviceKeySection(
      {super.key,
      required this.loadEnrollment,
      this.account,
      this.linkedGmail});

  @override
  ConsumerState<DeviceKeySection> createState() => _DeviceKeySectionState();
}

class _DeviceKeySectionState extends ConsumerState<DeviceKeySection> {
  late Future<StoredEnrollment?> _future;
  late String _memoKey;
  var _retryBusy = false;

  String _key() =>
      '${widget.account?.email.trim().toLowerCase() ?? ''}|${widget.linkedGmail?.trim().toLowerCase() ?? ''}';

  @override
  void initState() {
    super.initState();
    _memoKey = _key();
    _future = widget.loadEnrollment();
  }

  @override
  void didUpdateWidget(DeviceKeySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final now = _key();
    if (now != _memoKey) {
      _memoKey = now;
      _future = widget.loadEnrollment();
    }
  }

  Future<void> _retry() async {
    final acct = widget.account;
    if (acct == null || _retryBusy) return;
    setState(() => _retryBusy = true);
    try {
      // Explicit retry: re-reads the stored enrollment (a transient
      // failure parked locked). Success sets linked → memo key flips →
      // fresh read.
      await attemptUnlockIdentity(ref, acct);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _retryBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ProxSectionHeader(title: 'This device'),
        FutureBuilder<StoredEnrollment?>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const ProxSyncNote(
                    'Couldn’t check the enrollment on this device.',
                  ),
                  const SizedBox(height: ProxSpacing.sm),
                  TextButton.icon(
                    icon: const Icon(Icons.lock_open_outlined),
                    label: Text(_retryBusy ? 'Checking…' : 'Retry unlock'),
                    onPressed:
                        (_retryBusy || widget.account == null) ? null : _retry,
                  ),
                ],
              );
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
///
/// Memoized like [DeviceKeySection] (one gate read per account, never
/// per rebuild). A locked store renders Retry, then the gate re-reads.
class DeviceMoveSection extends ConsumerStatefulWidget {
  final String? email;
  final Future<StudentGate?> Function(String? email) loadGate;

  /// Signed-in account for the explicit unlock retry (null disables it).
  final SignedAccount? unlockAccount;

  /// Linked-identity Gmail: part of the memo key (see [DeviceKeySection]).
  final String? linkedGmail;

  const DeviceMoveSection({
    super.key,
    required this.email,
    required this.loadGate,
    this.unlockAccount,
    this.linkedGmail,
  });

  @override
  ConsumerState<DeviceMoveSection> createState() => _DeviceMoveSectionState();
}

class _DeviceMoveSectionState extends ConsumerState<DeviceMoveSection> {
  late Future<StudentGate?> _future;
  late String _memoKey;
  var _retryBusy = false;

  String _key() =>
      '${widget.email?.trim().toLowerCase() ?? ''}|${widget.linkedGmail?.trim().toLowerCase() ?? ''}';

  @override
  void initState() {
    super.initState();
    _memoKey = _key();
    _future = widget.loadGate(widget.email);
  }

  @override
  void didUpdateWidget(DeviceMoveSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final now = _key();
    if (now != _memoKey) {
      _memoKey = now;
      _future = widget.loadGate(widget.email);
    }
  }

  Future<void> _retry() async {
    final acct = widget.unlockAccount;
    if (acct == null || _retryBusy) return;
    setState(() => _retryBusy = true);
    try {
      await attemptUnlockIdentity(ref, acct);
    } catch (_) {}
    // Re-read regardless of the outcome: success flips linked (memo key
    // also flips); another failure lands back on the Retry below, never
    // on the offline-looking "connect" note.
    if (!mounted) return;
    setState(() {
      _retryBusy = false;
      _memoKey = _key();
      _future = widget.loadGate(widget.email);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ProxSectionHeader(title: 'Move status'),
        if (widget.email == null)
          const ProxSyncNote(
              'Sign in to check this Gmail against the one-device rule.')
        else
          FutureBuilder<StudentGate?>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const ProxSyncNote(
                      'Couldn’t check move status on this device.',
                    ),
                    const SizedBox(height: ProxSpacing.sm),
                    TextButton.icon(
                      icon: const Icon(Icons.lock_open_outlined),
                      label:
                          Text(_retryBusy ? 'Checking…' : 'Retry unlock'),
                      onPressed: (_retryBusy || widget.unlockAccount == null)
                          ? null
                          : _retry,
                    ),
                  ],
                );
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
        final isReclaim = gate.verdict.isReclaim;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ProxStateBadge(
                state: ProxState.waiting,
                label: isReclaim
                    ? 'Same phone — re-enroll here'
                    : 'Eligible to move here'),
            ProxSyncNote(isReclaim
                ? deviceReclaimNote()
                : deviceAllowedMoveNote()),
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
