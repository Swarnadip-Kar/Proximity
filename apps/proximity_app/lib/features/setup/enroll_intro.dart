// EnrollIntro — bundle step 1: pre-context + account + device key.
//
// Gives the squeezed enrollment room to breathe: what happens
// (account → key → 5 angles → online claim), the internet-once note, the
// one-device-per-30-days explainer with its manual-attendance pointer, and
// the friendly retry brief near the start. Then account pickup (silent —
// students signed in on the landing) and the device key. The face scan
// itself lives on EnrollCapture; the claim outcome on EnrollResult.
//
// Web: student registration stays a native-only pointer (no camera /
// enrollment on records builds).
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/enrollment.dart';
import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../features/face_identity/face_blocked.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_cards.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_scaffold.dart';
import '../../widgets/prox_states.dart';
import 'enroll_flow.dart';
import 'enroll_widgets.dart';
import 'intro_sections.dart';
import 'setup_step_scope.dart';

class EnrollIntroScreen extends ConsumerStatefulWidget {
  const EnrollIntroScreen({super.key});

  @override
  ConsumerState<EnrollIntroScreen> createState() => _EnrollIntroScreenState();
}

class _EnrollIntroScreenState extends ConsumerState<EnrollIntroScreen> {
  var _logged = false;

  @override
  void initState() {
    super.initState();
    // Silent account pickup (post-frame: pickup notifies listeners).
    // Fresh installs with no session keep the manual sign-in button below.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
          ref.read(enrollmentControllerProvider.notifier).pickUpAccount());
      if (!_logged) {
        _logged = true;
        EnrollLog.nav('enroll intro shown');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Standalone route: content is shared with the SetupFlow combined
    // device+intro step (see EnrollIntroBody below).
    return const EnrollIntroBody();
  }
}

/// Scaffold-less intro content, shared by the standalone route above and
/// the SetupFlow combined device+intro step (mechanical extraction — the
/// build below is verbatim, only the method owner changed).
class EnrollIntroBody extends ConsumerWidget {
  const EnrollIntroBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Standalone chrome; the content below is shared with the SetupFlow
    // combined device+intro step (see EnrollIntroContent).
    return ProxScreen(
      title: 'Enroll this device',
      child: EnrollIntroContent(),
    );
  }
}

/// Scroll-free intro content, shared by the standalone route above and the
/// SetupFlow combined device+intro step (mechanical extraction — the build
/// below is verbatim except the scope-aware branches marked STEP-SCOPE).
///
/// Thin composer over the [intro_sections] widgets: the explainer copy
/// lives in sections, account/key state in the controller.
class EnrollIntroContent extends ConsumerWidget {
  const EnrollIntroContent({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // all — the blocked card is the whole screen, never a disabled form.
    // Deep-links to enroll/* on records-only devices redirect to records
    // guidance (see ProxRoutes.mobileGuardRedirect); this is the second
    // gate for direct pushes.
    if (!canUseFace()) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const FaceBlockedCard(flow: 'Face enrollment'),
          const SizedBox(height: ProxSpacing.md),
          ProxSecondaryButton(
            label: const Text('Back'),
            expanded: true,
            onPressed: () {
              // STEP-SCOPE: inside SetupFlow, Back steps back instead of
              // popping the shell tab route (standalone pop preserved).
              final scope = SetupStepScope.of(context);
              if (scope != null) {
                scope.back();
              } else {
                Navigator.of(context).pop();
              }
            },
          ),
        ],
      );
    }
    final st = ref.watch(enrollmentControllerProvider);
    final hasKey = st.pkHex.isNotEmpty;
    // Scroll-free: scroll comes from ProxScreen above (standalone) or the
    // combined SetupFlow step.
    return ProxStaggered(
      children: [
          const IntroOverviewSection(),
          const SizedBox(height: ProxSpacing.md),
          const IntroOnlineSection(),
          const SizedBox(height: ProxSpacing.md),
          const IntroOneDeviceSection(),
          const SizedBox(height: ProxSpacing.lg),
          if (kIsWeb)
            const ProxCard(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline),
                  SizedBox(width: ProxSpacing.sm),
                  Expanded(
                    child: Text(
                      'Student registration needs the native app — the web '
                      'build is records-viewing only (no camera or '
                      'enrollment here).',
                    ),
                  ),
                ],
              ),
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
                      // STEP-SCOPE: inside SetupFlow, Continue advances the
                      // stepper instead of pushing the standalone route.
                      final scope = SetupStepScope.of(context);
                      if (scope != null) {
                        scope.next();
                      } else {
                        EnrollFlow.openCapture(context);
                      }
                    },
            ),
            if (!hasKey)
              const ProxSyncNote(
                'Sign in and generate the device key to continue.',
              ),
          ],
        ],
      );
  }
}
