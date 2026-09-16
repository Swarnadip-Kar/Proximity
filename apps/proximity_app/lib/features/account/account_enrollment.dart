// Enrollment sections: status + editable ID row.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';

import '../../core/auth.dart';
import '../../core/cloud_sync.dart';
import '../../core/device_store.dart';
import '../../core/enrollment.dart';
import '../../design/tokens.dart';
import '../../mode.dart';
import '../../widgets/details_expander.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/trust_cards.dart';
import 'account_common.dart';

/// Enrollment section: date enrolled, organization, trust-tier badge +
/// plain-language explainer (collapsed), re-enroll entry when relevant.
class AccountEnrollmentSection extends ConsumerWidget {
  final SignedAccount acct;
  const AccountEnrollmentSection({required this.acct, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final linked = ref.watch(linkedIdentityProvider);
    return FutureBuilder<StoredEnrollment?>(
      future: readAccountEnrollment(ref),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final e = snap.data;
        // account counts — a previous account's stored enrollment is not
        // this account's enrollment, and an enrolled account gets no CTA.
        if (!enrolledForAccount(acct, linked, e)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Current account's org, so the page reflects the signed-in
              // account even before it enrolls (stale-account fix).
              AccountFactRow(
                'Organization',
                acct.org.isNotEmpty ? acct.org : 'Not set',
              ),
              const ProxSyncNote(
                accountNoKeyNote,
              ),
            ],
          );
        }
        final mine = storedForAccount(acct, e);
        final linkedOrg = linkedOrgForAccount(acct, linked);
        final org = mine != null && mine.org.isNotEmpty
            ? mine.org
            : (linkedOrg.isNotEmpty
                ? linkedOrg
                : (acct.org.isNotEmpty ? acct.org : 'Not set'));
        final badgeEmail = mine?.email ?? linked?.gmail ?? acct.email;
        // No enroll / re-enroll CTA while enrolled for this account
        // (re-enroll fix): re-scan lives on the face-id sub-page only.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ProxStateBadge(
                state: ProxState.marked, label: 'Enrolled as $badgeEmail'),
            if (mine != null) ...[
              AccountFactRow(
                  // Global date rule, display only: DD-MM-YYYY.
                  'Date enrolled',
                  displayDateOf(mine.enrolledAt.toUtc())),
              AccountFactRow('Organization', org),
              const SizedBox(height: ProxSpacing.md),
              DeviceTrustBadge(
                level: mine.attestationLevel,
                attestedUntilMillis:
                    mine.attestedUntil.toUtc().millisecondsSinceEpoch,
                pkDHex: mine.pkDHex,
              ),
              DetailsExpander(
                title: 'What this means',
                child: Text(
                  'FULL and STD mean this phone holds a hardware-backed device key — attendance is confirmed automatically. '
                  'STALE means the attestation is older than the 14-day grace period — attendance still confirms, re-attest soon. '
                  'NONE means a software key with no hardware tier claimed — attendance never auto-marks (manual approval path, every other check still run).',
                  style: ProxType.body(),
                ),
              ),
            ] else
              AccountFactRow('Organization', org),
          ],
        );
      },
    );
  }
}

/// business addition; overrides the gap-2 read-only verdict).
///
/// Flow: validate non-empty → uniqueness-check via the existing directory
/// ID search scoped to org (`searchStudents(rollPrefix:, org:)`; an exact
/// roll held by another Gmail → friendly "already held" copy, no overwrite)
/// → write via the NEW `CloudSync.updateStudentRoll` (fake + firestore;
/// client-side only — production needs the rules deploy noted on that
/// method; rules-denied → friendly error, never raw text) → on success
/// update local enrollment roll ([EnrollmentController.updateLocalRoll]) +
/// linked identity (+ the ID display reads both, so they stay consistent).
/// Historical session rolls/names untouched by design.
class AccountIdRow extends ConsumerStatefulWidget {
  final SignedAccount acct;
  const AccountIdRow({required this.acct, super.key});

  @override
  ConsumerState<AccountIdRow> createState() => _AccountIdRowState();
}

class _AccountIdRowState extends ConsumerState<AccountIdRow> {
  TextEditingController? _ctrl;
  bool _editing = false;
  bool _busy = false;
  String _status = '';
  String _lastRoll = '';

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  String _myOrg(SignedAccount acct) =>
      acct.org.isNotEmpty ? acct.org : orgOf(acct.email);

  Future<void> _save(String currentRoll) async {
    final acct = widget.acct;
    final want = (_ctrl?.text ?? '').trim();
    setState(() {
      _busy = true;
      _status = '';
    });
    try {
      if (want.isEmpty) {
        setState(() => _status = 'ID Number is required.');
        return;
      }
      if (want == currentRoll) {
        setState(() {
          _editing = false;
        });
        return;
      }
      final cloud = ref.read(cloudSyncProvider);
      final org = _myOrg(acct);
      // Uniqueness-check via the existing directory ID search, scoped to
      // org. Exact-roll match held by another Gmail → friendly copy, no
      // overwrite. Self-match (same Gmail) is fine — it is our own row.
      List<StudentDirectoryEntry> hits = const [];
      try {
        final online = cloud.available && await cloud.isOnline();
        if (!mounted) return;
        if (!online) {
          setState(() => _status =
              'You appear offline — connect to the internet to update your ID.');
          return;
        }
        hits = await cloud.searchStudents(
            rollPrefix: want, org: org, limit: 10);
        if (!mounted) return;
      } on StateError catch (e) {
        if (!mounted) return;
        final msg = '$e'.replaceFirst('StateError: ', '');
        if (isRulesDenialMessage(e.message)) {
          setState(() => _status = e.message);
        } else {
          setState(() => _status = msg);
        }
        BleLog.log('SYNC', 'id edit directory check failed');
        return;
      }
      final me = acct.email.toLowerCase();
      for (final h in hits) {
        if (h.roll.trim() == want &&
            h.email.trim().toLowerCase() != me) {
          setState(() => _status =
              'This ID is already held by another student in your organization — check the number and try again.');
          BleLog.log('SYNC', 'id edit collision — no overwrite');
          return;
        }
      }
      // Cloud write via the new method (client-side only — see its docs
      // for the rules-deploy requirement; denied → friendly, never raw).
      try {
        await cloud.updateStudentRoll(emailLower: me, newRoll: want);
      } on StateError catch (e) {
        // Rules-denied hint is already friendly/actionable (deploy line),
        // never raw Firebase text — surface verbatim.
        if (!mounted) return;
        setState(() => _status = e.message);
        BleLog.log('SYNC', 'id update refused (see screen message)');
        return;
      }
      // Local sync: stored enrollment roll + linked identity. Role display
      // reads the same sources so it stays consistent; history untouched.
      try {
        await ref
            .read(enrollmentControllerProvider.notifier)
            .updateLocalRoll(want);
      } catch (_) {
        // Controller missing in some harnesses: fall back to a direct
        // store write preserving every other field.
        try {
          final store = ref.read(deviceStoreProvider);
          final stored = await store.readEnrollment();
          if (stored != null &&
              stored.email.trim().toLowerCase() == me) {
            // Sealed-only (security §2 F1): the envelope + chain carry
            // the key. Preserves the face-rescan stamp (dropping it to 0
            // would lift the 30-day rescan cooldown).
            await store.writeEnrollment(StoredEnrollment(
              email: stored.email,
              name: stored.name,
              roll: want,
              pkHex: stored.pkHex,
              sealedKeyHex: stored.sealedKeyHex,
              chainDERHex: stored.chainDERHex,
              faceId: stored.faceId,
              enrolledAt: stored.enrolledAt,
              verifierVer: stored.verifierVer,
              org: stored.org,
              pkDHex: stored.pkDHex,
              attestationLevel: stored.attestationLevel,
              attestedAt: stored.attestedAt,
              attestedUntil: stored.attestedUntil,
              lastFaceRescanAtMillis: stored.lastFaceRescanAtMillis,
              appAttestRawHex: stored.appAttestRawHex,
              appAttestCredKeyHex: stored.appAttestCredKeyHex,
            ));
          }
        } catch (_) {}
      }
      try {
        final linked = ref.read(linkedIdentityProvider);
        if (linked != null &&
            linked.gmail.trim().toLowerCase() == me) {
          ref.read(linkedIdentityProvider.notifier).state = LinkedIdentity(
              name: linked.name,
              gmail: linked.gmail,
              roll: want,
              org: linked.org);
        }
      } catch (_) {}
      BleLog.log('SYNC', 'id edit ok');
      if (mounted) {
        setState(() {
          _editing = false;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final acct = widget.acct;
    final linked = ref.watch(linkedIdentityProvider);
    return FutureBuilder<StoredEnrollment?>(
      future: readAccountEnrollment(ref),
      builder: (context, snap) {
        final linkedRoll = linkedRollForAccount(acct, linked);
        final mine = storedForAccount(acct, snap.data);
        final roll = linkedRoll.isNotEmpty
            ? linkedRoll
            : (mine != null ? mine.roll : '');
        final seed = roll;
        if (_ctrl == null) {
          _ctrl = TextEditingController(text: roll);
          _lastRoll = seed;
        } else if (seed != _lastRoll && !_editing) {
          _ctrl!.text = roll;
          _lastRoll = seed;
        }
        if (!_editing) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              AccountFactRow(
                'ID number',
                roll.isNotEmpty ? roll : 'Not set',
                mono: roll.isNotEmpty,
                key: const Key('account-id-row'),
              ),
              const SizedBox(height: ProxSpacing.sm),
              TextButton.icon(
                key: const Key('account-id-edit'),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit'),
                onPressed: () => setState(() {
                  _editing = true;
                  _status = '';
                }),
              ),
              if (_status.isNotEmpty) ProxErrorNote(_status),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'ID number',
              style: ProxType.label(
                  color:
                      ProximityColors.of(context).contentSecondary),
            ),
            const SizedBox(height: ProxSpacing.xs),
            TextField(
              key: const Key('account-id-field'),
              controller: _ctrl,
              decoration: const InputDecoration(
                hintText: 'ID Number',
                helperText: 'Searches the online student directory',
              ),
            ),
            const SizedBox(height: ProxSpacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const Key('account-id-save'),
                    onPressed: _busy ? null : () => _save(roll),
                    child: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2),
                          )
                        : const Text('Save'),
                  ),
                ),
                const SizedBox(width: ProxSpacing.sm),
                TextButton(
                  key: const Key('account-id-cancel'),
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                            _editing = false;
                            _status = '';
                            _ctrl!.text = roll;
                          }),
                  child: const Text('Cancel'),
                ),
              ],
            ),
            if (_status.isNotEmpty) ...[
              const SizedBox(height: ProxSpacing.sm),
              ProxErrorNote(_status),
            ],
          ],
        );
      },
    );
  }
}


