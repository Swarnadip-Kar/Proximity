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
import '../../widgets/prox_cards.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_scaffold.dart';
import '../../widgets/prox_states.dart';
import '../../widgets/prox_verdict.dart';
import 'enroll_widgets.dart';

/// Refusal classes, detected from the controller message (which carries the
/// user-facing claim copy verbatim). Pure — the message stays the source of
/// truth; this only picks the next-step card around it.
enum _Refusal {
  none,
  cooldown,
  installConflict,
  duplicate,
  offline,
  pipeline,
  partial,
  roll,
  generic,
}

_Refusal _classify(EnrollmentState st) {
  if (st.phase == EnrollPhase.uploaded || st.message.isEmpty) {
    return _Refusal.none;
  }
  final m = st.message.toLowerCase();
  if (m.contains('another device')) return _Refusal.cooldown;
  if (m.contains('already enrolled')) return _Refusal.installConflict;
  if (m.contains('looks very similar')) return _Refusal.duplicate;
  if (m.contains('internet')) return _Refusal.offline;
  if (m.contains('improved') || m.contains('scan your face again')) {
    return _Refusal.pipeline;
  }
  if (m.contains('scan your face first')) return _Refusal.partial;
  if (m.contains('id number')) return _Refusal.roll;
  return _Refusal.generic;
}

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
    // Records-only devices never save enrollment (see EnrollIntro guard).
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
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      );
    }
    final st = ref.watch(enrollmentControllerProvider);
    final ctl = ref.read(enrollmentControllerProvider.notifier);
    if (st.phase == EnrollPhase.uploaded) {
      return _success(context, ref, st, ctl);
    }
    return _pending(context, ref, st, ctl);
  }

  Widget _success(BuildContext context, WidgetRef ref, EnrollmentState st,
      EnrollmentController ctl) {
    final restored = st.restored && st.faceScore <= 0;
    return ProxScreen(
      title: 'Enrolled',
      child: ProxStaggered(
        children: [
          const SizedBox(height: ProxSpacing.lg),
          ProxVerdictBadge(
            kind: ProxVerdictKind.marked,
            title: '✓ Done',
            detail: restored
                ? 'Key restored from this device — no fresh face match yet.'
                : 'Identity linked for attendance.',
          ),
          const SizedBox(height: ProxSpacing.lg),
          ProxCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (st.account != null)
                  Text(
                    '${st.account!.displayName}\n${st.account!.email}',
                  ),
                if (st.roll.isNotEmpty) ...[
                  const SizedBox(height: ProxSpacing.xs),
                  Text('ID: ${st.roll}'),
                ],
                if (!restored) ...[
                  const SizedBox(height: ProxSpacing.xs),
                  // Honest: the plugin returns identity only (match vs
                  // non-match), so there is no measured score to show —
                  // the boundary value lives in the FACE debug log only.
                  Text(
                    'Face matched on this phone — a compact face-code is '
                    'stored online for duplicate checks (see enrollment '
                    'info); photos never leave this phone.',
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
          const SizedBox(height: ProxSpacing.md),
          ProxSecondaryButton(
            icon: const Icon(Icons.face),
            label: const Text('Re-scan face'),
            expanded: true,
            onPressed: () {
              // Key kept; the saved enrollment is untouched (attendance
              // still works) until 3 new stills validate.
              EnrollLog.face('re-scan from result — key kept, slots cleared');
              ctl.restartFace();
              Navigator.of(context).pop();
            },
          ),
          const SizedBox(height: ProxSpacing.sm),
          ProxPrimaryButton(
            label: const Text('Done'),
            onPressed: () => EnrollNav.finish(context),
          ),
        ],
      ),
    );
  }

  Widget _pending(BuildContext context, WidgetRef ref, EnrollmentState st,
      EnrollmentController ctl) {
    final hasFace = st.phase == EnrollPhase.faceDone ||
        st.phase == EnrollPhase.uploaded;
    final refusal = _classify(st);
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
          ProxCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (st.account != null)
                  Text(
                    '${st.account!.displayName}\n${st.account!.email}',
                  ),
                const SizedBox(height: ProxSpacing.xs),
                // Honest: progress state (angles captured) stays user-visible;
                // the numeric boundary lives in the FACE debug log only.
                Text(
                  'Key: ${st.pkHex.length >= 16 ? st.pkHex.substring(0, 16) : st.pkHex}… · '
                  'Face: ${hasFace ? '5 of 5 stills captured' : 'capture pending'}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: ProxSpacing.sm),
                // Readonly flow-through of the single intro entry (no
                // second prompt): Save reuses it, fail-closed when empty.
                Text(
                  st.roll.isNotEmpty
                      ? 'ID: ${st.roll}'
                      : 'ID: not entered — go back to the account step to '
                          'enter it, then continue (your capture is kept).',
                ),
              ],
            ),
          ),
          if (refusal != _Refusal.none) ...[
            const SizedBox(height: ProxSpacing.md),
            EnrollNotice(
              message: st.message,
              isError: refusal != _Refusal.partial,
            ),
            const SizedBox(height: ProxSpacing.sm),
            _nextStep(context, ctl, refusal),
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
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  /// Next-step card per refusal. The controller message (shown above,
  /// verbatim) carries the details; this adds the action.
  Widget _nextStep(
      BuildContext context, EnrollmentController ctl, _Refusal refusal) {
    switch (refusal) {
      case _Refusal.cooldown:
        // Message names the exact re-enroll date + old-device last-online +
        // manual pointer; the action is patience + the manual fallback.
        return const ProxCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.schedule_outlined),
              SizedBox(width: ProxSpacing.sm),
              Expanded(
                child: Text(
                  'Next step: wait for the re-enroll date above — moves are '
                  'unlimited, at most one per 7 days. Until then, ask your '
                  'professor to mark your attendance manually (Request '
                  'manual attendance in class).',
                ),
              ),
            ],
          ),
        );
      case _Refusal.installConflict:
        return const ProxCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.phonelink_erase_outlined),
              SizedBox(width: ProxSpacing.sm),
              Expanded(
                child: Text(
                  'Next step: to switch identity here, clear the app data / '
                  'reinstall and enroll again — one phone holds one student '
                  'enrollment. If you need attendance marked meanwhile, ask '
                  'your professor for manual attendance.',
                ),
              ),
            ],
          ),
        );
      case _Refusal.duplicate:
        // Message carries the non-accusation + options; the action is
        // recapture (key kept, borderline flags sometimes clear in
        // different light) + the manual fallback that always works.
        return ProxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Next step: your device key was kept — go back and recapture '
                'in different light, then Save again. Or ask your professor '
                'to mark your attendance manually in class (Request manual '
                'attendance) — that always works, and nothing is recorded '
                'against you either way.',
              ),
              const SizedBox(height: ProxSpacing.sm),
              ProxSecondaryButton(
                icon: const Icon(Icons.face),
                label: const Text('Back to face scan'),
                expanded: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        );
      case _Refusal.offline:
        return ProxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Next step: connect to the internet and tap Save again — '
                'your capture is kept, no re-scan needed.',
              ),
              const SizedBox(height: ProxSpacing.sm),
              ProxSecondaryButton(
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
                expanded: true,
                onPressed: ctl.dismissError,
              ),
            ],
          ),
        );
      case _Refusal.pipeline:
        // Stale template, valid key: fresh face capture, key kept.
        return ProxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Next step: your device key was kept — scan your face again '
                'on the previous screen. Attendance on the saved enrollment '
                'keeps working meanwhile.',
              ),
              const SizedBox(height: ProxSpacing.sm),
              ProxSecondaryButton(
                icon: const Icon(Icons.face),
                label: const Text('Back to face scan'),
                expanded: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        );
      case _Refusal.partial:
        return ProxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Next step: go back and capture the 5 stills — '
                'a failed capture stores nothing, so just retry.',
              ),
              const SizedBox(height: ProxSpacing.sm),
              ProxSecondaryButton(
                icon: const Icon(Icons.face),
                label: const Text('Back to face scan'),
                expanded: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        );
      case _Refusal.roll:
        return ProxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Next step: go back to the account step and enter your ID '
                'number once, then continue — your capture is kept, no '
                're-scan needed.',
              ),
              const SizedBox(height: ProxSpacing.sm),
              ProxSecondaryButton(
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back to account step'),
                expanded: true,
                onPressed: () => Navigator.of(context).popUntil(
                    (route) =>
                        route.isFirst ||
                        route.settings.name ==
                            '${EnrollNav.routePrefix}intro'),
              ),
            ],
          ),
        );
      case _Refusal.generic:
      case _Refusal.none:
        return ProxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Next step: review the note above and try again.'),
              const SizedBox(height: ProxSpacing.sm),
              ProxSecondaryButton(
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
                expanded: true,
                onPressed: ctl.dismissError,
              ),
            ],
          ),
        );
    }
  }
}
