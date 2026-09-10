// Account → Enrollment sub-page (enrollment facts + device/binding rules).
//
// page (§5.1) is split back into a compact menu + one-feature pushes.
// This page owns enrollment status + the editable ID row + the inline
// `AccountEnrollmentSection` + `AccountIdRow` widgets, same enroll-entry
// sheet + per-account scoping + re-enroll gating; rules are presentation
// only, inline here — no shared rules file).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth.dart';
import '../../core/cloud_sync.dart';
import '../../core/device_store.dart';
import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../widgets/prox_scaffold.dart';
import '../../widgets/prox_states.dart';
import '../entry/entry_flow.dart';
import 'account_common.dart';
import 'account_enrollment.dart';

/// Enrollment sub-page: status + editable ID + device rules. Pushed from
/// the Account menu.
class AccountEnrollmentPage extends ConsumerWidget {
  final SignedAccount acct;
  const AccountEnrollmentPage({required this.acct, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ProxScreen(
      title: 'Enrollment',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!canUseFace()) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: ProxSpacing.lg),
              child: Text(
                'Records view only here — enrollment, keys, and device moves live in the mobile app (Android/iOS).',
                textAlign: TextAlign.center,
              ),
            ),
          ] else ...[
            const SizedBox(height: ProxSpacing.sm),
            const ProxSectionHeader(title: 'Enrollment'),
            const SizedBox(height: ProxSpacing.sm),
            AccountEnrollmentSection(acct: acct),
            const SizedBox(height: ProxSpacing.xl),
            const ProxSectionHeader(title: 'ID'),
            const SizedBox(height: ProxSpacing.sm),
            AccountIdRow(acct: acct),
            const SizedBox(height: ProxSpacing.xl),
            const ProxSectionHeader(title: 'Device rules'),
            const SizedBox(height: ProxSpacing.sm),
            FutureBuilder<StudentGate?>(
              future: moveGateForAccount(ref, acct.email),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                return _EnrollmentDeviceRules(gate: snap.data);
              },
            ),
            const SizedBox(height: ProxSpacing.xl),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Inline device/binding rules (enrollment sub-page only — no shared file).
//
// with the EXACT re-enroll/next-eligible date where the gate data is
// already available, reinstall/app-data-clear to switch identity, manual
// attendance meanwhile. Days + why are explicit: 30-day move limit and
// 60-day lost-phone window (from [kStudentMoveCooldown] /
// [kStudentLostPhoneStale], never invented) with the fraud reason in plain
// language. Exact dates derive from the already-available gate
// ([StudentGate.verdict.retryAfter] + binding lastSeen) via [dateIsoOf].
// Refusal copy reuses [studentClaimMessage] verbatim — never paraphrased.
// Crucial highlight (one-device + 30-day date) uses existing tokens only
// (surfaceRaised + accentBrand border + cardSpecRadius).
// ---------------------------------------------------------------------------

/// Device/binding rules, inline in the Enrollment page.
class _EnrollmentDeviceRules extends StatelessWidget {
  final StudentGate? gate;
  const _EnrollmentDeviceRules({this.gate});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final g = gate;
    final binding = g?.binding;
    final retry = g?.verdict.retryAfter;
    final moveDays = kStudentMoveCooldown.inDays;
    final lostDays = kStudentLostPhoneStale.inDays;

    String? lastSeenIso;
    String? lostEligibleIso;
    if (binding != null && binding.lastSeenAtMillis > 0) {
      lastSeenIso = dateIsoOf(DateTime.fromMillisecondsSinceEpoch(
          binding.lastSeenAtMillis,
          isUtc: true));
      lostEligibleIso = dateIsoOf(DateTime.fromMillisecondsSinceEpoch(
          binding.lastSeenAtMillis + kStudentLostPhoneStale.inMilliseconds,
          isUtc: true));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          key: const Key('device-rules-important'),
          decoration: BoxDecoration(
            color: c.surfaceRaised,
            borderRadius: ProxRadii.cardSpecRadius,
            border: Border.all(color: c.accentBrand),
          ),
          padding: const EdgeInsets.all(ProxSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.star_outline, size: 16, color: c.accentBrand),
                  const SizedBox(width: ProxSpacing.xs),
                  Text(
                    'Most important',
                    style: ProxType.label(color: c.accentBrand),
                  ),
                ],
              ),
              const SizedBox(height: ProxSpacing.sm),
              Text(
                'One phone holds one student enrollment (app clones count as the same phone).',
                style: ProxType.body(color: c.contentPrimary),
              ),
              const SizedBox(height: ProxSpacing.sm),
              Text(
                retry != null
                    ? 'Moves are allowed once every $moveDays days — you can re-enroll this device on ${dateIsoOf(retry.toUtc())}.'
                    : 'Moves are allowed once every $moveDays days (unlimited times).',
                style: ProxType.body(color: c.contentPrimary),
              ),
            ],
          ),
        ),
        const SizedBox(height: ProxSpacing.md),
        Text(
          'Device rules',
          key: const Key('device-rules-title'),
          style: ProxType.title(color: c.contentPrimary),
        ),
        const SizedBox(height: ProxSpacing.sm),
        Text(
          'One phone holds one student enrollment — app clones count as the same phone, so the same phone can never hold two enrollments.',
          key: const Key('device-rules-one'),
          style: ProxType.body(color: c.contentPrimary),
        ),
        Padding(
          padding: const EdgeInsets.only(top: ProxSpacing.sm),
          child: Text(
            'A move to a new phone is allowed once every $moveDays days (unlimited times).',
            key: const Key('device-rules-30'),
            style: ProxType.body(color: c.contentPrimary),
          ),
        ),
        if (retry != null)
          Padding(
            padding: const EdgeInsets.only(top: ProxSpacing.sm),
            child: Text(
              'Next eligible date: ${dateIsoOf(retry.toUtc())}.',
              key: const Key('device-rules-next-date'),
              style: ProxType.body(color: c.contentPrimary),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: ProxSpacing.sm),
          child: Text(
            'Lost phone: if the old phone stays offline $lostDays days, you can move immediately.',
            key: const Key('device-rules-60'),
            style: ProxType.body(color: c.contentPrimary),
          ),
        ),
        if (lastSeenIso != null && lostEligibleIso != null)
          Padding(
            padding: const EdgeInsets.only(top: ProxSpacing.xs),
            child: Text(
              'Its last online activity was $lastSeenIso — if it stays offline, you can move on $lostEligibleIso.',
              key: const Key('device-rules-lost-date'),
              style: ProxType.body(color: c.contentPrimary),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: ProxSpacing.sm),
          child: Text(
            'To switch identity here, clear the app data / reinstall and enroll again.',
            style: ProxType.body(color: c.contentPrimary),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: ProxSpacing.sm),
          child: Text(
            'If you need attendance marked meanwhile, ask your professor for manual attendance.',
            style: ProxType.body(color: c.contentPrimary),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: ProxSpacing.sm),
          child: Text(
            'Why: this stops one phone marking attendance for many students.',
            key: const Key('device-rules-why-one'),
            style: ProxType.body(color: c.contentSecondary),
          ),
        ),
        Text(
          'Why: this stops shared-device fraud.',
          key: const Key('device-rules-why-shared'),
          style: ProxType.body(color: c.contentSecondary),
        ),
        if (g != null && !g.verdict.ok) ...[
          const SizedBox(height: ProxSpacing.md),
          ProxErrorNote(
            studentClaimMessage(g.verdict, g.binding),
            key: const Key('device-rules-refusal'),
          ),
        ],
      ],
    );
  }
}
