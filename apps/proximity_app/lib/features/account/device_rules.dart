// Device rules: the ONE source for the 30/60-day student device copy.
//
// Unifies the previously triplicated presentation copy behind a single
// file so the strings/keys cannot drift:
//
// - [DeviceRules] — the full enrollment block (important callout + rows,
//   exact next-eligible / lost-phone dates where the gate data is already
//   available, verbatim refusal). Rendered by the enrollment sub-page
//   (`_EnrollmentDeviceRules` is a thin wrapper).
// - [DeviceRulesCompact] — the compact days + why note (same days, same
//   whys, same `device-days-line` / `device-why-*` keys). Rendered by the
//   Device sub-page (`_DeviceDaysWhy` is a thin wrapper).
// - [deviceAllowedMoveNote] — the eligible-move sentence reused by the
//   move-status bodies (`DeviceMoveSection` in setup + `AccountDeviceSection`
//   move status), so the 30-day wording has one definition.
//
// FROZEN (never invent, never paraphrase, never reformat dates):
// - days derive from [kStudentMoveCooldown] (30d) / [kStudentLostPhoneStale]
//   (60d), never literals (except the verbatim allowed-move sentence, which
//   interpolates the same constant so it still reads "30 days" today);
// - refusal copy is [studentClaimMessage] verbatim;
// - user-visible dates use [displayDateOf] (DD-MM-YYYY, display only);
// - all pinned widget keys (`device-rules-*`, `device-days-line`,
//   `device-why-*`) and their copy are preserved verbatim from the
//   pre-unification widgets — same strings, same keys, same layout/tokens.
library;

import 'package:flutter/material.dart';

import '../../core/cloud_sync.dart';
import '../../core/device_store.dart';
import '../../design/tokens.dart';
import '../../widgets/prox_states.dart';
import '../entry/entry_flow.dart' show StudentGate;

/// Shared "why" line: stops one phone marking for many students.
/// Same string under both `device-rules-why-one` (full) and
/// `device-why-one` (compact) — one definition, two keys (keys stay pinned
/// per surface; only the copy is shared).
const deviceWhyOneText =
    'Why: this stops one phone marking attendance for many students.';

/// Shared "why" line: stops shared-device fraud.
/// Same string under both `device-rules-why-shared` (full) and
/// `device-why-shared` (compact) — one definition, two keys.
const deviceWhySharedText = 'Why: this stops shared-device fraud.';

/// Compact days line (`device-days-line`): 30-day move limit + 60-day
/// lost-phone window. Days derive from the frozen constants, never literals.
String deviceDaysLineText() =>
    'Moves are limited to once every ${kStudentMoveCooldown.inDays} days, '
    'and a lost phone frees its slot after ${kStudentLostPhoneStale.inDays} days offline.';

/// Eligible-move sentence shared by the move-status bodies (setup
/// `DeviceMoveSection` + account `AccountDeviceSection`). Interpolates the
/// frozen cooldown so it still reads "The 30 days since …" today — same
/// words the pre-unification bodies rendered verbatim.
String deviceAllowedMoveNote() =>
    'The ${kStudentMoveCooldown.inDays} days since the last move have passed '
    '— enrolling here moves it (at most once a month).';

/// Full device/binding rules (enrollment surfaces): important callout +
/// rows, with the EXACT re-enroll/next-eligible date where the gate data is
/// already available, reinstall/app-data-clear to switch identity, manual
/// attendance meanwhile. Days + why are explicit: 30-day move limit and
/// 60-day lost-phone window (from [kStudentMoveCooldown] /
/// [kStudentLostPhoneStale], never invented) with the fraud reason in plain
/// language. Exact dates derive from the already-available gate
/// ([StudentGate.verdict.retryAfter] + binding lastSeen) via [displayDateOf]
/// (DD-MM-YYYY, display only). Refusal copy reuses [studentClaimMessage]
/// verbatim — never paraphrased. Crucial highlight (one-device + 30-day
/// date) uses existing tokens only (surfaceRaised + accentBrand border +
/// cardSpecRadius).
class DeviceRules extends StatelessWidget {
  final StudentGate? gate;
  const DeviceRules({this.gate, super.key});

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
      // Global date rule, display only: DD-MM-YYYY.
      lastSeenIso = displayDateOf(DateTime.fromMillisecondsSinceEpoch(
          binding.lastSeenAtMillis,
          isUtc: true));
      lostEligibleIso = displayDateOf(DateTime.fromMillisecondsSinceEpoch(
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
                    ? 'Moves are allowed once every $moveDays days — you can re-enroll this device on ${displayDateOf(retry.toUtc())}.'
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
              'Next eligible date: ${displayDateOf(retry.toUtc())}.',
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
            deviceWhyOneText,
            key: const Key('device-rules-why-one'),
            style: ProxType.body(color: c.contentSecondary),
          ),
        ),
        Text(
          deviceWhySharedText,
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

/// Compact days + why note (Device page): same days, same whys as [DeviceRules]
/// (copy owned here via [deviceDaysLineText]/[deviceWhyOneText]/
/// [deviceWhySharedText]), same pinned keys (`device-days-line`,
/// `device-why-one`, `device-why-shared`). Exact per-account dates live where
/// the gate data is already available (enrollment block above + verdict rows
/// via `studentClaimMessage` verbatim).
class DeviceRulesCompact extends StatelessWidget {
  const DeviceRulesCompact({super.key});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Why these limits exist',
          style: ProxType.label(color: c.contentSecondary),
        ),
        const SizedBox(height: ProxSpacing.sm),
        Text(
          deviceDaysLineText(),
          key: const Key('device-days-line'),
          style: ProxType.body(color: c.contentPrimary),
        ),
        const SizedBox(height: ProxSpacing.sm),
        Text(
          deviceWhyOneText,
          key: const Key('device-why-one'),
          style: ProxType.body(color: c.contentSecondary),
        ),
        Text(
          deviceWhySharedText,
          key: const Key('device-why-shared'),
          style: ProxType.body(color: c.contentSecondary),
        ),
      ],
    );
  }
}
