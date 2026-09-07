// EnrollCapture — bundle step 2: the guided 5-angle face scan.
//
// One focused screen for Centre / Left / Right / Top / Bottom with progress,
// the pose-guidance dial, live scores, and resume that scans ONLY the
// missing slots. Behavioral law (preserved, not re-decided here):
// - each angle clears a 0.70 best-pair (kEnrollSectionScoreMin — the camera
//   gate and the controller re-validation share the constant);
// - yaw gates + Top/Bottom pitch gates live in the shared camera loop
//   (face_detect poseOkWithRef, enforced by FaceCaptureScreen, reused —
//   never forked); this screen only explains them;
// - finalize failures drop ONLY the weakest slot (never a wipe); the key is
//   always kept, even on Start over;
// - the camera stays open till the requested angles clear (bounded:
//   3 fruitless rounds surface the retry offer); Cancel always exits at
//   once with completed sections kept — a camera exit means success or the
//   holder's own Cancel;
// - fail-closed: no template, no save (Continue stays gated till 5/5).
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/enrollment.dart';
import '../../core/face_detect.dart';
import '../../design/tokens.dart';
import '../../screens/face_capture.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_cards.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_scaffold.dart';
import '../../widgets/prox_states.dart';
import 'enroll_flow.dart';
import 'enroll_widgets.dart';

/// Slot order matches [enrollSlotNames]: Centre/Left/Right/Top/Bottom.
const _slotTargets = [
  PoseTarget.front,
  PoseTarget.left,
  PoseTarget.right,
  PoseTarget.up,
  PoseTarget.down,
];

/// Holder-facing gate copy per slot: what counts, in one line. The numbers
/// stay in face_detect (kPoseSideMin/kPitchRelDelta…) — this is the human
/// twin, same contract as the live in-camera arrows.
String _gateNote(int slot) => switch (slot) {
      0 => 'Look straight at the camera and hold still.',
      1 => 'A slight turn left counts — no sharp angles.',
      2 => 'A slight turn right counts — no sharp angles.',
      // Pitch failure mode is OVER-tilting (a bigger tilt degrades the
      // embedding, which drops the slot again): ask for LESS tilt.
      3 => 'Tilt LESS — barely lift your chin, phone at eye level.',
      4 => 'Tilt LESS — barely lower your chin, phone at eye level.',
      _ => '',
    };

class EnrollCaptureScreen extends ConsumerStatefulWidget {
  const EnrollCaptureScreen({super.key});

  @override
  ConsumerState<EnrollCaptureScreen> createState() =>
      _EnrollCaptureScreenState();
}

class _EnrollCaptureScreenState extends ConsumerState<EnrollCaptureScreen> {
  @override
  void initState() {
    super.initState();
    // Deep-link safe: pickup is a no-op when Intro already ran it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
          ref.read(enrollmentControllerProvider.notifier).pickUpAccount());
    });
  }

  /// One tap, one camera page over ONLY the missing slots. Completed angles
  /// are never re-captured: pairs chunk in order, pair k belongs to slot
  /// missing[k]. Cancel (null/empty) keeps progress — nothing burns.
  Future<void> _scan() async {
    final st = ref.read(enrollmentControllerProvider);
    final ctl = ref.read(enrollmentControllerProvider.notifier);
    if (st.pkHex.isEmpty) {
      EnrollLog.face('scan refused: no device key yet');
      return;
    }
    final missing = missingSlots(st.angleSlots);
    if (missing.isEmpty) return;
    EnrollLog.face(
        'rescan slots ${missing.map((m) => enrollSlotNames[m]).join(', ')} '
        '— missing only, kept slots untouched');
    final targets = [for (final m in missing) _slotTargets[m]];
    final titles = [
      for (final m in missing) '${enrollSlotNames[m]} — ${enrollSlotHints[m]}'
    ];
    final frames = await Navigator.of(context).push<List<Uint8List>>(
      MaterialPageRoute(
        settings: const RouteSettings(name: 'enroll/scan'),
        builder: (_) => FaceCaptureScreen(
          // Five angles need headroom (~18 stills per angle at real-world
          // cadence). Stay-open: a weak angle keeps its camera across
          // rounds until its pair clears the shared 0.70 bar — exits ONLY
          // on success or Cancel (which keeps completed angles).
          maxFrames: 90,
          stayOpen: true,
          sectionScoreMin: kEnrollSectionScoreMin,
          sectionTargets: targets,
          sectionTitles: titles,
          scorer: ctl.embedder,
        ),
      ),
    );
    if (!mounted) return;
    if (frames != null && frames.isNotEmpty) {
      final pairs = slotPairs(frames);
      EnrollLog.face(
          'scan returned ${pairs.length} pair(s) for ${missing.length} missing slot(s)');
      for (var k = 0; k < pairs.length && k < missing.length; k++) {
        await ctl.captureSlot(missing[k], pairs[k]);
      }
      if (!mounted) return;
      final after = ref.read(enrollmentControllerProvider);
      if (after.message.isNotEmpty) {
        // Controller names the dropped slot + why (mixed faces / odd-one-
        // out / weakest hold-out) — mirrored to the log for field reports.
        EnrollLog.face('controller: ${after.message}');
      } else {
        EnrollLog.face('slots landed clean');
      }
    } else {
      final kept =
          ref.read(enrollmentControllerProvider).angleSlots.where((d) => d).length;
      EnrollLog.face(
          'scan cancelled by holder — progress kept ($kept/5), nothing burned');
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(enrollmentControllerProvider);
    final ctl = ref.read(enrollmentControllerProvider.notifier);
    final hasKey = st.pkHex.isNotEmpty;
    // Explicit step gate (never phase.index: EnrollPhase.error sorts last
    // and must NOT read as done).
    final hasFace = st.phase == EnrollPhase.faceDone ||
        st.phase == EnrollPhase.uploaded;
    final doneCount = st.angleSlots.where((d) => d).length;
    final firstMissing = firstMissingSlot(st.angleSlots);
    final activeSlot = firstMissing < 0 ? 0 : firstMissing;
    final targeted =
        st.message.isNotEmpty && _isTargetedRescan(st.message);
    return ProxScreen(
      title: 'Face scan',
      child: ProxStaggered(
        children: [
          Text(
            'Scan your face',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: ProxSpacing.xs),
          const Text(
            enrollRetryBrief,
            style: TextStyle(fontStyle: FontStyle.italic),
          ),
          const SizedBox(height: ProxSpacing.lg),
          ProxCard(
            child: Row(
              children: [
                EnrollPoseGuide(
                  target: _slotTargets[activeSlot],
                  progress:
                      enrollSlotNames.isEmpty ? 0 : doneCount / enrollSlotNames.length,
                ),
                const SizedBox(width: ProxSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hasFace
                            ? 'All angles captured — finishing…'
                            : '${enrollSlotNames[activeSlot]} — '
                                '${enrollSlotHints[activeSlot]}',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: ProxSpacing.xs),
                      Text(
                        _gateNote(activeSlot),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: ProxSpacing.md),
          EnrollProgress(done: doneCount, total: enrollSlotNames.length),
          const SizedBox(height: ProxSpacing.xs),
          Text(
            '$doneCount of ${enrollSlotNames.length} angles captured',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          if (st.faceScore > 0)
            Text(
              'Match score ${st.faceScore.toStringAsFixed(2)} — '
              'template never leaves this phone.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color:
                        Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          const SizedBox(height: ProxSpacing.sm),
          for (var i = 0; i < enrollSlotNames.length; i++)
            EnrollAngleRow(
              done: st.angleSlots[i],
              label: '${enrollSlotNames[i]} — ${enrollSlotHints[i]}',
              delay: Duration(
                  milliseconds: (i *
                          ProxDurations.staggerStep.inMilliseconds)
                      .clamp(
                          0, ProxDurations.staggerCap.inMilliseconds)),
            ),
          ProxSyncNote(
            'Each angle clears at '
            '${kEnrollSectionScoreMin.toStringAsFixed(2)} pair agreement.',
          ),
          const SizedBox(height: ProxSpacing.md),
          ProxPrimaryButton(
            icon: const Icon(Icons.face),
            label: Text(scanButtonLabel(st.angleSlots)),
            // Never silently drop: Scan needs the key first.
            onPressed: !hasKey ? null : _scan,
          ),
          if (!hasKey)
            const ProxSyncNote(
              'Generate the device key on the previous screen, then scan.',
            ),
          // Escape hatch: one angle stuck in a drop→rescan loop must never
          // trap the holder. Clears ALL slot progress (key kept) so the
          // next tap re-scans all five from a fresh start.
          if (st.angleSlots.any((d) => d) && !hasFace) ...[
            const SizedBox(height: ProxSpacing.sm),
            ProxSecondaryButton(
              icon: const Icon(Icons.refresh),
              label: const Text('Start over (clear all angles)'),
              expanded: true,
              onPressed: () {
                EnrollLog.face(
                    'start-over: cleared $doneCount slot(s), key kept');
                ctl.restartFace();
              },
            ),
          ],
          if (st.message.isNotEmpty) ...[
            const SizedBox(height: ProxSpacing.md),
            EnrollNotice(
              message: st.message,
              isError: st.phase == EnrollPhase.error && !targeted,
            ),
            if (targeted) ...[
              const SizedBox(height: ProxSpacing.sm),
              const Text(
                enrollRetryBrief,
                style: TextStyle(fontStyle: FontStyle.italic),
              ),
            ],
            const SizedBox(height: ProxSpacing.sm),
            ProxSecondaryButton(
              label: Text(st.phase == EnrollPhase.error && !targeted
                  ? 'Try again'
                  : 'Dismiss'),
              onPressed: ctl.dismissError,
            ),
          ],
          const SizedBox(height: ProxSpacing.lg),
          ProxPrimaryButton(
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Continue to save'),
            // Fail-closed UI: disabled until all 5 angles validate (the
            // controller re-validates for programmatic callers too).
            onPressed: !hasFace
                ? null
                : () {
                    EnrollLog.nav(
                        'capture → result ($doneCount/5 angles, score ${st.faceScore.toStringAsFixed(2)})');
                    EnrollFlow.openResult(context);
                  },
          ),
          if (!hasFace)
            const ProxSyncNote(
              'Complete all 5 face angles above to enable Save.',
            ),
        ],
      ),
    );
  }
}

bool _isTargetedRescan(String message) {
  final m = message.toLowerCase();
  return m.contains('rescan') ||
      m.contains('retry') ||
      m.contains('angle') ||
      m.contains('weakest');
}
