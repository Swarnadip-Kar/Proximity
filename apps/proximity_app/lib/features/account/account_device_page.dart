// Account → Device sub-page (one essential feature).
//
// Product-owner override (Account overhaul, SUBMENUS + DEVICE FACTS):
// owns the device facts only — the existing `AccountDeviceSection`
// (student) / `AccountProfDeviceFacts` (prof) moved verbatim in behavior
// (same gating/scoping/move-status/refusal copy) plus the Device-ID +
// key-fingerprint facts. Trust stays truthful (real NONE on
// software-backed builds, never faked FULL).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth.dart';
import '../../core/cloud_sync.dart';
import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../widgets/prox_scaffold.dart';
import '../../widgets/prox_states.dart';
import 'account_device.dart';
import 'account_prof.dart';

/// Student Device sub-page.
class AccountDevicePage extends ConsumerWidget {
  final SignedAccount acct;
  const AccountDevicePage({required this.acct, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ProxScreen(
      title: 'Device',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!canUseFace())
            const Padding(
              padding: EdgeInsets.symmetric(vertical: ProxSpacing.lg),
              child: Text(
                'Records view only here — enrollment, keys, and device moves live in the mobile app (Android/iOS).',
                textAlign: TextAlign.center,
              ),
            )
          else ...[
            const SizedBox(height: ProxSpacing.sm),
            const ProxSectionHeader(title: 'Device'),
            const SizedBox(height: ProxSpacing.sm),
            AccountDeviceSection(acct: acct),
            const SizedBox(height: ProxSpacing.xl),
            _DeviceDaysWhy(),
            const SizedBox(height: ProxSpacing.xl),
          ],
        ],
      ),
    );
  }
}

/// Professor Device sub-page (device/key facts only, no trust tier —
// professors hold no enrollment, and none is invented).
class AccountProfDevicePage extends ConsumerWidget {
  final SignedAccount acct;
  const AccountProfDevicePage({required this.acct, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ProxScreen(
      title: 'Device',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: ProxSpacing.sm),
          const ProxSectionHeader(title: 'This device'),
          const SizedBox(height: ProxSpacing.sm),
          AccountProfDeviceFacts(acct: acct),
          const SizedBox(height: ProxSpacing.xl),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Inline days + why (Device page only — no shared file).
//
// Presentation only: explicit day counts from [kStudentMoveCooldown] /
// [kStudentLostPhoneStale] (never invented) with the plain-language fraud
// reason. Exact per-account dates live where the gate data is already
// available (enrollment sub-page inline block + the verdict rows above
// via `studentClaimMessage` verbatim).
// ---------------------------------------------------------------------------

/// Days + why note, inline in the Device page.
class _DeviceDaysWhy extends StatelessWidget {
  const _DeviceDaysWhy();

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final moveDays = kStudentMoveCooldown.inDays;
    final lostDays = kStudentLostPhoneStale.inDays;
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
          'Moves are limited to once every $moveDays days, and a lost phone frees its slot after $lostDays days offline.',
          key: const Key('device-days-line'),
          style: ProxType.body(color: c.contentPrimary),
        ),
        const SizedBox(height: ProxSpacing.sm),
        Text(
          'Why: this stops one phone marking attendance for many students.',
          key: const Key('device-why-one'),
          style: ProxType.body(color: c.contentSecondary),
        ),
        Text(
          'Why: this stops shared-device fraud.',
          key: const Key('device-why-shared'),
          style: ProxType.body(color: c.contentSecondary),
        ),
      ],
    );
  }
}
