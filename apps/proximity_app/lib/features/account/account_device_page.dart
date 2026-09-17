// Account → Device sub-page (one essential feature).
//
// This page owns the device facts only — the existing `AccountDeviceSection`
// key-fingerprint facts. Trust stays truthful (real NONE on
// software-backed builds, never faked FULL).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth.dart';
import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../widgets/prox_scaffold.dart';
import '../../widgets/prox_states.dart';
import 'account_device.dart';
import 'account_prof.dart';
import 'device_rules.dart';
import 'device_verification.dart';

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
            const SizedBox(height: ProxSpacing.sm),
            // This phone's integrity standing (same probe as
            // enrollment/marking) with its explanation — one shared
            // card with the professor Device page.
            const DeviceVerificationCard(),
            const SizedBox(height: ProxSpacing.xl),
            const DeviceRulesCompact(),
            const SizedBox(height: ProxSpacing.xl),
          ],
        ],
      ),
    );
  }
}

/// Professor Device sub-page (device/key facts only, no trust tier —
// professors hold no enrollment, and none is invented). Nullable account
// for the offline local-only professor (facts stay local-only; the
// display-name row falls back honestly, never to another identity).
class AccountProfDevicePage extends ConsumerWidget {
  final SignedAccount? acct;
  const AccountProfDevicePage({this.acct, super.key});

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
          const SizedBox(height: ProxSpacing.sm),
          // Hosting standing (shared widget, professor copy — lecture-key
          // pin, ephemeral keys, signed windows, org writes — never the
          // student root/hook headline).
          const DeviceVerificationCard(forProfessor: true),
          const SizedBox(height: ProxSpacing.xl),
        ],
      ),
    );
  }
}
