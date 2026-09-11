// EnrollResult — bundle step 3: save + the claim outcome.
//
// Success (✓ Done) vs refusal states, each with its next step:
// - cooldown refusal: exact re-enroll date + old-device last-online +
//   manual-attendance pointer (the controller message already carries all
//   three — shown verbatim, never paraphrased past the date);
// - install-as-other-Gmail refusal: wipe-to-switch;
// - pipeline recapture: key kept, fresh face scan;
// - offline retry: progress kept, Save again on reconnect.
// Fail-closed throughout: Save needs the validated 5-still capture
// (controller re-validates); a refused claim stores nothing locally.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/enrollment.dart';
import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../features/face_identity/face_blocked.dart';
import '../../mode.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_scaffold.dart';
import '../../widgets/prox_states.dart';
import 'enroll_widgets.dart';
import 'result_sections.dart';
import 'setup_step_scope.dart';

/// Refusal classes live in [result_sections] ([EnrollRefusal] +
/// [classifyEnrollRefusal]) alongside the next-step cards; the controller
/// message stays the source of truth there too.

class EnrollResultScreen extends ConsumerWidget {
  const EnrollResultScreen({super.key});

  Future<void> _save(WidgetRef ref) async {
    final ctl = ref.read(enrollmentControllerProvider.notifier);
    EnrollLog.sync('claim attempt started');
    final id = await ctl.upload();
    final st = ref.read(enrollmentControllerProvider);
    if (id != null) {
      ref.read(linkedIdentityProvider.notifier).state = id;
      EnrollLog.sync('claim ok — identity linked for ${id.gmail}');
    } else {
      EnrollLog.sync('claim refused: ${st.message}');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Records-only devices never save enrollment (see AccountKeyStep guard).
    if (!canUseFace()) {
      return ProxScreen(
        title: 'Save enrollment',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const FaceBlockedCard(flow: 'Face enrollment'),
            const SizedBox(height: ProxSpacing.md),
            ProxSecondaryButton(
              label: const Text('Back'),
              expanded: true,
              onPressed: () {
                // STEP-SCOPE: inside SetupFlow, Back steps back instead of
                // popping (standalone pop preserved).
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
      );
    }
    final st = ref.watch(enrollmentControllerProvider);
    final ctl = ref.read(enrollmentControllerProvider.notifier);
    if (st.phase == EnrollPhase.uploaded) {
      return ProxScreen(
        title: 'Enrolled',
        child: ProxStaggered(
          children: [
            ResultSuccessSection(st: st, ctl: ctl),
          ],
        ),
      );
    }
    final hasFace =
        st.phase == EnrollPhase.faceDone || st.phase == EnrollPhase.uploaded;
    final refusal = classifyEnrollRefusal(st);
    return ProxScreen(
      title: 'Save enrollment',
      child: ProxStaggered(
        children: [
          Text(
            'Save enrollment',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: ProxSpacing.xs),
          Text(
            'One tap claims this Gmail\u2019s single student-device slot '
            'online — then attendance works fully offline.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: ProxSpacing.lg),
          ResultStatusSection(st: st, hasFace: hasFace),
          if (refusal != EnrollRefusal.none) ...[
            const SizedBox(height: ProxSpacing.md),
            ResultRefusalSection(st: st, refusal: refusal, ctl: ctl),
          ],
          const SizedBox(height: ProxSpacing.lg),
          ProxPrimaryButton(
            label: const Text('Save enrollment'),
            // Fail-closed UI: disabled until all 5 angles validate.
            onPressed: !hasFace ? null : () => _save(ref),
          ),
          if (!hasFace)
            const ProxSyncNote(
              'Complete the 5-angle face session on the previous screen '
              'to enable Save — a failed capture cannot save.',
            )
          else
            const ProxSyncNote(
              'Needs internet once (one enrolled device per Gmail is '
              'checked online). Your capture is kept — reconnect and '
              'tap Save again.',
            ),
          const SizedBox(height: ProxSpacing.sm),
          ProxSecondaryButton(
            icon: const Icon(Icons.arrow_back),
            label: const Text('Back to face scan'),
            expanded: true,
            onPressed: () {
              // STEP-SCOPE: inside SetupFlow, back steps within the flow
              // instead of popping (standalone pop preserved).
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
    );
  }
}
