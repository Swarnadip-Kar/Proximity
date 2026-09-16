// Enroll-result sections: save status / refusal next-step / success.
//
// guards, same scope-aware navigation). The screen owns the save path
// ([EnrollmentController.upload]) and the pending/success dispatch;
// sections own the layout. Refusal classes are detected from the
// controller message (user-facing claim copy verbatim) — the message
// stays the source of truth; classification only picks the next-step
// card around it.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/enrollment.dart';
import '../../design/tokens.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_cards.dart';
import '../../widgets/verdict_badge.dart';
import 'enroll_widgets.dart';
import 'setup_step_scope.dart';

/// Refusal classes, detected from the controller message (which carries
/// the user-facing claim copy verbatim). Pure — the message stays the
/// source of truth; this only picks the next-step card around it.
enum EnrollRefusal {
  none,
  cooldown,
  installConflict,
  offline,
  pipeline,
  partial,
  roll,
  attestation,
  generic,
}

EnrollRefusal classifyEnrollRefusal(EnrollmentState st) {
  // faceDone carries no message by construction (enrollFace clears it on
  // success), but a validated capture must never render a refusal card even
  // if a stale message ever survives again — belt-and-braces with the
  // controller clear above.
  if (st.phase == EnrollPhase.uploaded ||
      st.phase == EnrollPhase.faceDone ||
      st.message.isEmpty) {
    return EnrollRefusal.none;
  }
  final m = st.message.toLowerCase();
  if (m.contains('another device')) return EnrollRefusal.cooldown;
  if (m.contains('already enrolled')) return EnrollRefusal.installConflict;
  if (m.contains('internet')) return EnrollRefusal.offline;
  if (m.contains('improved') || m.contains('scan your face again')) {
    return EnrollRefusal.pipeline;
  }
  if (m.contains('scan your face first')) return EnrollRefusal.partial;
  if (m.contains('id number')) return EnrollRefusal.roll;
  if (m.contains('hardware certificate is expired') ||
      m.contains('attestation window expired') ||
      m.contains('hardware proof doesn')) {
    return EnrollRefusal.attestation;
  }
  return EnrollRefusal.generic;
}

/// Save-status card: account + key/face progress + the readonly ID
/// flow-through from the single intro entry (Save reuses it, fail-closed
/// when empty).
class ResultStatusSection extends StatelessWidget {
  final EnrollmentState st;
  final bool hasFace;

  const ResultStatusSection({
    super.key,
    required this.st,
    required this.hasFace,
  });

  @override
  Widget build(BuildContext context) {
    return ProxCard(
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
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
    );
  }
}

/// Refusal notice + next-step card. The controller message (shown
/// verbatim) carries the details; the card adds the action.
class ResultRefusalSection extends StatelessWidget {
  final EnrollmentState st;
  final EnrollRefusal refusal;
  final EnrollmentController ctl;

  const ResultRefusalSection({
    super.key,
    required this.st,
    required this.refusal,
    required this.ctl,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EnrollNotice(
          message: st.message,
          isError: refusal != EnrollRefusal.partial,
        ),
        // Debug-only attestation detail (per-cert dates + expired index,
        // no key material): shown only with the attestation refusal (the
        // only class that sets it) so a lingering detail can never render
        // under an unrelated error. Field use: paste this line.
        if (st.attestationDebug.isNotEmpty &&
            refusal == EnrollRefusal.attestation) ...[
          const SizedBox(height: ProxSpacing.sm),
          ProxCard(
            child: Text(
              'Debug: ${st.attestationDebug}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
        const SizedBox(height: ProxSpacing.sm),
        _nextStep(context),
      ],
    );
  }

  /// Next-step card per refusal. The controller message (shown above,
  /// verbatim) carries the details; this adds the action.
  Widget _nextStep(BuildContext context) {
    switch (refusal) {
      case EnrollRefusal.cooldown:
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
                  'unlimited, at most one per 30 days. Until then, ask your '
                  'professor to mark your attendance manually (Request '
                  'manual attendance in class).',
                ),
              ),
            ],
          ),
        );
      case EnrollRefusal.installConflict:
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
      case EnrollRefusal.offline:
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
      case EnrollRefusal.pipeline:
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
                onPressed: () {
                  // STEP-SCOPE: inside SetupFlow, back steps within the
                  // flow instead of popping (standalone pop preserved).
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
      case EnrollRefusal.partial:
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
                onPressed: () {
                  // STEP-SCOPE: inside SetupFlow, back steps within the
                  // flow instead of popping (standalone pop preserved).
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
      case EnrollRefusal.roll:
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
                onPressed: () {
                  // STEP-SCOPE: inside SetupFlow, the account step is the
                  // Account & key page (ID entry lives there after the
                  // Setup pagination split). Standalone pops back to the
                  // rescan entry — 'enroll/intro' is a dead target here,
                  // so never push; a plain pop returns to the caller.
                  final scope = SetupStepScope.of(context);
                  if (scope != null) {
                    scope.goTo(SetupStep.accountKey);
                  } else {
                    Navigator.of(context).pop();
                  }
                },
              ),
            ],
          ),
        );
      case EnrollRefusal.attestation:
        // Retrying the SAME key cannot pass (a fresh key mints a fresh 90d
        // window but reuses the provisioned chain): the fix is update +
        // online refresh, then Generate anew on the account step.
        return ProxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Next step: update Android + Play Services, stay online a '
                'few minutes, then Generate a new device key on the account '
                'step and Save again. Until then, ask your professor to '
                'mark your attendance manually.',
              ),
              const SizedBox(height: ProxSpacing.sm),
              ProxSecondaryButton(
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back to account step'),
                expanded: true,
                onPressed: () {
                  final scope = SetupStepScope.of(context);
                  if (scope != null) {
                    scope.goTo(SetupStep.accountKey);
                  } else {
                    Navigator.of(context).pop();
                  }
                },
              ),
            ],
          ),
        );
      case EnrollRefusal.generic:
      case EnrollRefusal.none:
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

/// Success verdict: ✓ Done + identity card + re-scan + Done. Key kept
/// across re-scans; the saved enrollment is untouched until new stills
/// validate.
class ResultSuccessSection extends StatelessWidget {
  final EnrollmentState st;
  final EnrollmentController ctl;

  const ResultSuccessSection({
    super.key,
    required this.st,
    required this.ctl,
  });

  @override
  Widget build(BuildContext context) {
    final restored = st.restored && st.faceScore <= 0;
    // Single-flight per button: a double-tap fires one stepper move only
    // (the orchestrator drops overlaps; standalone pop/finish is gone
    // after the first tap). Per-build latches suffice — the first tap
    // navigates away, so a second tap shares this build only in the
    // same-frame double case.
    var rescanBusy = false;
    var doneBusy = false;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: ProxSpacing.lg),
        // Single badge system: enroll-success uses the standard
        // VerdictBadge(marked) pill with a custom '✓ Done' label — the
        // same status + label idiom as the present/highlighted counts —
        // with the success copy as plain text below (never a second
        // verdict widget).
        const Center(
          child: VerdictBadge(
            status: ProxStatus.marked,
            label: '✓ Done',
          ),
        ),
        const SizedBox(height: ProxSpacing.sm),
        Text(
          restored
              ? 'Key restored from this device — no fresh face match yet.'
              : 'Identity linked for attendance.',
          textAlign: TextAlign.center,
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
                  'Face matched on this phone — '
                  'face data never leaves this phone.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
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
            if (rescanBusy) return;
            rescanBusy = true;
            EnrollLog.face('re-scan from result — key kept, slots cleared');
            ctl.restartFace();
            // STEP-SCOPE: inside SetupFlow, re-scan returns to the
            // capture step instead of popping (standalone pop preserved).
            final scope = SetupStepScope.of(context);
            if (scope != null) {
              unawaited(
                  scope.goTo(SetupStep.capture).whenComplete(() {
                rescanBusy = false;
              }));
            } else {
              Navigator.of(context).pop();
            }
          },
        ),
        const SizedBox(height: ProxSpacing.sm),
        ProxPrimaryButton(
          label: const Text('Done'),
          onPressed: () {
            // STEP-SCOPE: inside SetupFlow, Done exits via the flow
            // (lands on mark/browse, never the roles hub). Single-flight:
            // Done double-tap completes once.
            if (doneBusy) return;
            doneBusy = true;
            final scope = SetupStepScope.of(context);
            if (scope != null) {
              unawaited(scope.complete().whenComplete(() {
                doneBusy = false;
              }));
            } else {
              EnrollNav.finish(context);
            }
          },
        ),
      ],
    );
  }
}
