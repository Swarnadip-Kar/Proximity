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

import '../../core/auth.dart';
import '../../core/enrollment.dart';
import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../features/face_identity/face_blocked.dart';
import '../../main.dart';
import '../../mode.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_motion.dart';
import 'device_identity_screen.dart';
import 'enroll_widgets.dart';
import 'intro_sections.dart';
import 'setup_step_scope.dart';

/// Confirm device page: [DeviceIdentityContent] (which account, which
/// device, move status, offline note, sign-out) + a flow-only Continue.
///
/// When this device already holds the enrollment for the signed-in Gmail
/// (re-sign-in returner: linked identity matches), the button completes
/// the flow straight to the main app — no details/key/face screens again.
/// Otherwise it advances to account & key as before.
class DeviceConfirmStep extends ConsumerWidget {
  const DeviceConfirmStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final acct = ref.watch(accountProvider).valueOrNull;
    final linked = ref.watch(linkedIdentityProvider);
    final linkedMatch = acct != null &&
        linked != null &&
        linked.gmail.trim().toLowerCase() ==
            acct.email.trim().toLowerCase();
    // Restored-key exit: the controller HW-unsealed this Gmail's doc from
    // this device's store (stronger proof than a read — the seal opened),
    // but nothing set linked (only unlock/upload write it, and the shell
    // parked on a dismissal/contradiction instead of unlocking). Funneling
    // such a returner into account & key would re-keygen over a valid
    // enrollment; exiting to the app lets the shell's cache-warmed
    // re-resolve unlock with no new prompt. Fresh keygen stays on the
    // enroll path (`restored` is false there by construction).
    final ctl = ref.watch(enrollmentControllerProvider);
    final restoredForAcct = acct != null &&
        ctl.restored &&
        ctl.pkHex.isNotEmpty &&
        ctl.account?.email.trim().toLowerCase() ==
            acct.email.trim().toLowerCase();
    final alreadyEnrolled = linkedMatch || restoredForAcct;
    // Root cause of the behind-nav-bar CTA: the app is edge-to-edge
    // (transparent system bars + extendBody, see main + MainActivity) and
    // AdaptiveScaffold bodies own their insets — this scroll had a fixed
    // 16px bottom pad, so on tall content the Continue button scrolled to
    // the viewport edge hiding behind the Android gesture/nav bar with no
    // way to reveal it. The bottom pad absorbs the system inset instead.
    final bottomPad = 16 + MediaQuery.viewPaddingOf(context).bottom;
    return AdaptiveScaffold(
      title: 'Confirm device',
      body: Center(
        child: SingleChildScrollView(
          key: const ValueKey('setup-device-scroll'),
          padding: EdgeInsets.fromLTRB(24, 16, 24, bottomPad),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              children: [
                const DeviceIdentityContent(),
                const SizedBox(height: ProxSpacing.lg),
                ProxPrimaryButton(
                  icon: Icon(alreadyEnrolled
                      ? Icons.check
                      : Icons.arrow_forward),
                  label: Text(alreadyEnrolled
                      ? 'Continue to app'
                      : 'Continue'),
                  onPressed: () {
                    final scope = SetupStepScope.of(context);
                    if (scope != null) {
                      if (alreadyEnrolled) {
                        scope.complete();
                      } else {
                        scope.next();
                      }
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
    final hasRoll = st.roll.trim().isNotEmpty;
    // The scan seals to the key AND files under the ID — both required
    // before leaving this step (fail-closed; Save re-checks too).
    final canContinue = hasKey && hasRoll;
    // Same edge-to-edge bottom inset as DeviceConfirmStep above: without
    // it the Continue button hides behind the Android nav bar on tall
    // content with no way to scroll it clear.
    final bottomPad = 16 + MediaQuery.viewPaddingOf(context).bottom;
    return AdaptiveScaffold(
      title: 'Account & key',
      body: Center(
        child: SingleChildScrollView(
          key: const ValueKey('setup-account-key-scroll'),
          padding: EdgeInsets.fromLTRB(24, 16, 24, bottomPad),
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
                    // The scan needs the key + ID first — never silently drop.
                    onPressed: !canContinue
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
                  if (!canContinue)
                    Text(
                      !hasKey
                          ? 'Sign in and generate the device key to continue.'
                          : 'Enter your ID number to continue.',
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
