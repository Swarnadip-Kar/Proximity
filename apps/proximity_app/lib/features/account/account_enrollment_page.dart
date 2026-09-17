// Account → Enrollment sub-page (enrollment facts + device/binding rules).
//
// The consolidated Account page (§5.1) is split back into a compact menu +
// one-feature pushes. This page owns enrollment status + the editable ID row + the inline
// `AccountEnrollmentSection` + `AccountIdRow` widgets, same enroll-entry
// sheet + per-account scoping + re-enroll gating; rules render from the
// shared `device_rules.dart` source (same strings, same keys).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth.dart';
import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../widgets/prox_scaffold.dart';
import '../../widgets/prox_states.dart';
import '../entry/entry_flow.dart';
import 'account_common.dart';
import 'account_enrollment.dart';
import 'device_rules.dart';

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
                return DeviceRules(gate: snap.data);
              },
            ),
            const SizedBox(height: ProxSpacing.xl),
          ],
        ],
      ),
    );
  }
}
