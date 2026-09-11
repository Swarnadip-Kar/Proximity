// SetupFlow device/account-key pagination (§3.3 + ## Setup pagination).
//
// Two one-purpose pages so each fits one screen without long scrolls:
//
//   DeviceConfirmStep — Confirm device (which account, which device, move
//     status + sign-out; reuses DeviceIdentityContent verbatim) + a flow-only
//     Continue to account & key.
//   AccountKeyStep — Account & key (Google account + ID entry + device key
//     + Continue to face scan; reuses IntroAccountSection/IntroKeySection
//     with hasKey gating).
//
// SetupFlow is the only enrollment flow.
//
// Step content only: stepper chrome (progress overlay, step slides, back
// routing, start index, listeners, lazy camera mount) lives in
// screens/setup_flow_screen.dart. The standalone DeviceIdentityScreen
// route is untouched for deep-links — these steps are flow-only (scope
// present; scope-absent Continue is a no-op).
//
// Frozen: step order semantics, gate/refusal copy, timings, copy trim
// (DetailsExpanders stay inside sections).
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/enrollment.dart';
import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../features/face_identity/face_blocked.dart';
import '../../main.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_motion.dart';
import 'device_identity_screen.dart';
import 'enroll_widgets.dart';
import 'intro_sections.dart';
import 'setup_step_scope.dart';

/// Confirm device page: [DeviceIdentityContent] (which account, which
/// device, move status, offline note, sign-out) + a flow-only Continue.
///
/// The content's own guards/branches (mobile key/move vs records-only note,
/// Continue CTA is added (each page advances one page via scope.next()).
class DeviceConfirmStep extends StatelessWidget {
  const DeviceConfirmStep({super.key});

  @override
  Widget build(BuildContext context) {
    return AdaptiveScaffold(
      title: 'Confirm device',
      body: Center(
        child: SingleChildScrollView(
          key: const ValueKey('setup-device-scroll'),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              children: [
                const DeviceIdentityContent(),
                const SizedBox(height: ProxSpacing.lg),
                ProxPrimaryButton(
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text('Continue'),
                  onPressed: () {
                    final scope = SetupStepScope.of(context);
                    if (scope != null) {
                      scope.next();
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Account & key page: Google account + ID entry + device key + Continue
/// to face scan (presentation only — controller, guards, and scope
/// branches verbatim).
class AccountKeyStep extends ConsumerWidget {
  const AccountKeyStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!canUseFace()) {
      return AdaptiveScaffold(
        title: 'Account & key',
        body: Center(
          child: SingleChildScrollView(
            key: const ValueKey('setup-account-key-scroll'),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const FaceBlockedCard(flow: 'Face enrollment'),
                  const SizedBox(height: ProxSpacing.md),
                  ProxSecondaryButton(
                    label: const Text('Back'),
                    expanded: true,
                    onPressed: () {
                      final scope = SetupStepScope.of(context);
                      if (scope != null) {
                        scope.back();
                      } else {
                        Navigator.of(context).pop();
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final st = ref.watch(enrollmentControllerProvider);
    final hasKey = st.pkHex.isNotEmpty;
    return AdaptiveScaffold(
      title: 'Account & key',
      body: Center(
        child: SingleChildScrollView(
          key: const ValueKey('setup-account-key-scroll'),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: ProxStaggered(
              children: [
                if (kIsWeb)
                  const Text(
                    'Student registration needs the native app — the web '
                    'build is records-viewing only (no camera or '
                    'enrollment here).',
                    textAlign: TextAlign.center,
                  )
                else ...[
                  const IntroAccountSection(),
                  const SizedBox(height: ProxSpacing.md),
                  const IntroKeySection(),
                  const SizedBox(height: ProxSpacing.lg),
                  ProxPrimaryButton(
                    icon: const Icon(Icons.face),
                    label: const Text('Continue to face scan'),
                    // The scan needs the key first — never silently drop.
                    onPressed: !hasKey
                        ? null
                        : () {
                            EnrollLog.nav(
                                'intro → capture (key ${st.pkHex.length >= 8 ? st.pkHex.substring(0, 8) : st.pkHex}…)');
                            // STEP-SCOPE: inside SetupFlow, Continue advances
                            // the stepper instead of pushing the standalone
                            // route.
                            final scope = SetupStepScope.of(context);
                            if (scope != null) {
                              scope.next();
                            }
                          },
                  ),
                  if (!hasKey)
                    const Text(
                      'Sign in and generate the device key to continue.',
                      textAlign: TextAlign.center,
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
