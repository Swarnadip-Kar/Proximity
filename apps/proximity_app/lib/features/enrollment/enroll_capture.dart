// EnrollCapture — bundle step 2: the 3-still face capture (Tracks 2+3).
//
// GUTTED per spec: the 5 guided-pose slots, per-frame detectors,
// yaw/pitch gates, pair-consistency bars and hold-out math are gone (the
// plugin owns detection + matching passively, on-device). What remains is
// the shell + flow position: key check → capture 3 stills
// (centre/left/right) via FaceCaptureScreen → controller.enrollFace
// (plugin enroll + self-check) → result.
//
// Mobile-only (L2): records-only devices see the blocked card, never a
// camera. Fail-closed: a failed capture stores no face (controller), the
// error notice shows the controller message verbatim, Save stays blocked
// until the capture validates.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/enrollment.dart';
import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../features/face_identity/face_blocked.dart';
import '../../features/face_identity/face_verifier.dart';
import '../../screens/face_capture.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_cards.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_scaffold.dart';
import '../../widgets/prox_states.dart';
import 'enroll_flow.dart';
import 'enroll_widgets.dart';

class EnrollCaptureScreen extends ConsumerWidget {
  const EnrollCaptureScreen({super.key});

  Future<void> _scan(BuildContext context, WidgetRef ref) async {
    final ctl = ref.read(enrollmentControllerProvider.notifier);
    final st = ref.read(enrollmentControllerProvider);
    if (st.pkHex.isEmpty) {
      EnrollLog.face('scan refused: no device key yet');
      return;
    }
    EnrollLog.face('capture opened (3 stills)');
    final paths = await ref
        .read(stillCapturerProvider)
        .capture(context, captures: 3, autoFire: false);
    if (paths == null || paths.isEmpty) {
      EnrollLog.face('capture cancelled — progress kept');
      return;
    }
    EnrollLog.face('stills captured (${paths.length}) — enrolling');
    await ctl.enrollFace(paths);
    final after = ref.read(enrollmentControllerProvider);
    if (after.phase == EnrollPhase.faceDone) {
      EnrollLog.face('capture validated — continuing');
      if (context.mounted) EnrollFlow.openResult(context);
    } else {
      EnrollLog.face('controller: ${after.message}');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(enrollmentControllerProvider);
    // L2 assert: records-only devices never reach the camera.
    if (!canUseFace()) {
      return ProxScreen(
        title: 'Face capture',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const FaceBlockedCard(flow: 'Face enrollment'),
            const SizedBox(height: ProxSpacing.md),
            ProxSecondaryButton(
              label: const Text('Back'),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      );
    }
    final done = st.phase == EnrollPhase.faceDone ||
        st.phase == EnrollPhase.uploaded;
    return ProxScreen(
      title: 'Face capture',
      child: ProxStaggered(
        children: [
          EnrollProgress(done: done ? 3 : 0, total: faceEnrollSlots.length),
          const SizedBox(height: ProxSpacing.lg),
          Text(
            'Scan your face',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: ProxSpacing.xs),
          Text(
            'Three quick stills (centre, left, right) — hold still in good '
            'light. Matching runs on this phone only; stills and face data '
            'never leave the device.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: ProxSpacing.lg),
          ProxCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < faceEnrollSlots.length; i++)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: ProxSpacing.xs),
                    child: Row(
                      children: [
                        Icon(
                          done
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          color: done
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                        ),
                        const SizedBox(width: ProxSpacing.sm),
                        Text(
                          '${faceEnrollSlots[i][0].toUpperCase()}${faceEnrollSlots[i].substring(1)} still${done ? ' — captured' : ''}',
                        ),
                      ],
                    ),
                  ),
                if (st.faceScore > 0) ...[
                  const SizedBox(height: ProxSpacing.sm),
                  Text(
                    'Match score ${st.faceScore.toStringAsFixed(2)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                  ),
                ],
              ],
            ),
          ),
          if (st.phase == EnrollPhase.error && st.message.isNotEmpty) ...[
            const SizedBox(height: ProxSpacing.md),
            EnrollNotice(message: st.message, isError: true),
          ],
          const SizedBox(height: ProxSpacing.lg),
          ProxPrimaryButton(
            label: Text(st.pkHex.isEmpty ? 'Generate key first' : 'Scan face'),
            onPressed: st.pkHex.isEmpty ? null : () => _scan(context, ref),
          ),
          if (st.pkHex.isEmpty)
            const ProxSyncNote(
              'Generate the device key on the previous screen first — the '
              'face capture seals to it.',
            ),
          const SizedBox(height: ProxSpacing.sm),
          ProxSecondaryButton(
            label: const Text('Back'),
            expanded: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}
