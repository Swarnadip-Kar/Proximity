// EnrollCapture — bundle step 2: guided 3-angle face capture
// (Android-face-unlock-style).
//
// One angle at a time (centre → left → right): progress dots + a short
// instruction per angle + the positioning oval (the same oval language as
// the live camera overlay) + capture/retake per slot. The plugin owns
// detection + matching passively, on-device — these steps are UX guidance,
// never measurement gates. Samples go to the FaceVerifier gallery only
// (controller.enrollFace → plugin enroll + self-check); marking-time
// verify is untouched.
//
// Mobile-only (L2): records-only devices see the blocked card, never a
// camera. Fail-closed: a failed capture stores no face (controller), the
// error notice shows the controller message verbatim, continuing to the
// result stays blocked until the capture validates.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/enrollment.dart';
import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../features/face_identity/face_blocked.dart';
import '../../features/face_identity/face_verifier.dart';
import '../../screens/face_capture.dart';
import '../../widgets/animated.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_cards.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_scaffold.dart';
import '../../widgets/prox_states.dart';
import 'enroll_flow.dart';
import 'enroll_widgets.dart';

class EnrollCaptureScreen extends ConsumerStatefulWidget {
  const EnrollCaptureScreen({super.key});

  @override
  ConsumerState<EnrollCaptureScreen> createState() =>
      _EnrollCaptureScreenState();
}

class _EnrollCaptureScreenState extends ConsumerState<EnrollCaptureScreen> {
  /// One captured still per slot (null = not yet captured). Kept across
  /// failed saves so a retry re-captures only the failing angle.
  final List<String?> _paths =
      List<String?>.filled(faceEnrollSlots.length, null);
  var _busy = false;
  var _saving = false;
  String _notice = '';

  int get _doneCount => _paths.where((p) => p != null).length;

  /// First angle still missing a still (the guided cursor).
  int get _current {
    final i = _paths.indexWhere((p) => p == null);
    return i < 0 ? _paths.length - 1 : i;
  }

  Future<void> _captureAngle(int slot) async {
    if (_busy || _saving) return;
    final st = ref.read(enrollmentControllerProvider);
    if (st.pkHex.isEmpty) {
      EnrollLog.face('scan refused: no device key yet');
      return;
    }
    setState(() {
      _busy = true;
      _notice = '';
    });
    try {
      EnrollLog.face(
          'capture opened for angle ${faceEnrollSlots[slot]} ($slot+1/${_paths.length})');
      final instruction = enrollAngleInstructions[slot];
      final paths = await ref.read(stillCapturerProvider).capture(
            context,
            captures: 1,
            autoFire: false,
            prompt: '${instruction.title} — ${instruction.detail}',
          );
      if (!mounted) return;
      if (paths == null || paths.isEmpty) {
        EnrollLog.face(
            'angle ${faceEnrollSlots[slot]} cancelled — progress kept ($_doneCount/${_paths.length})');
        return;
      }
      final still = paths.first.trim();
      if (still.isEmpty) {
        EnrollLog.face('angle ${faceEnrollSlots[slot]} blank — rescan');
        setState(() => _notice =
            'The ${faceEnrollSlots[slot]} still came out blank — try that angle again.');
        return;
      }
      setState(() => _paths[slot] = still);
      EnrollLog.face(
          'angle ${faceEnrollSlots[slot]} captured ($_doneCount/${_paths.length})');
      if (_doneCount == _paths.length) {
        await _saveAll();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveAll() async {
    final ctl = ref.read(enrollmentControllerProvider.notifier);
    setState(() => _saving = true);
    try {
      EnrollLog.face('all angles captured — enrolling');
      await ctl.enrollFace([for (final p in _paths) p ?? '']);
      if (!mounted) return;
      final after = ref.read(enrollmentControllerProvider);
      if (after.phase == EnrollPhase.faceDone) {
        EnrollLog.face('capture validated — continuing');
        if (mounted) EnrollFlow.openResult(context);
      } else {
        EnrollLog.face('controller: ${after.message}');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
    final validated =
        st.phase == EnrollPhase.faceDone || st.phase == EnrollPhase.uploaded;
    final current = _current;
    final instruction = enrollAngleInstructions[current];
    // Count copy never overflows: while capturing it names the next angle;
    // a full-but-unvalidated set (save failed) names review instead.
    final countLabel = validated
        ? '3 of 3 angles captured'
        : _doneCount < _paths.length
            ? 'Angle ${_doneCount + 1} of ${_paths.length}'
            : '3 of 3 captured — review below';
    return ProxScreen(
      title: 'Face capture',
      child: ProxStaggered(
        children: [
          EnrollProgress(done: _doneCount, total: _paths.length),
          const SizedBox(height: ProxSpacing.sm),
          // Angle progress dots + count (the guided cursor).
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              EnrollAngleDots(
                done: _doneCount,
                total: _paths.length,
                current: current,
              ),
              const SizedBox(width: ProxSpacing.sm),
              Text(
                countLabel,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
          const SizedBox(height: ProxSpacing.md),
          // Positioning oval with the current instruction (same oval
          // language as the live camera overlay).
          Center(
            child: FaceOval(
              progress: _doneCount / _paths.length,
              prompt: validated ? 'All angles captured' : instruction.title,
            ),
          ),
          const SizedBox(height: ProxSpacing.sm),
          if (!validated)
            ProxCard(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.face_outlined),
                  const SizedBox(width: ProxSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Step ${current + 1}: ${instruction.title}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: ProxSpacing.xs),
                        Text(instruction.detail),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: ProxSpacing.md),
          // Per-slot rows: captured angles offer retake (failing-slot-only
          // rescan); the current angle offers capture.
          ProxCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < _paths.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: ProxSpacing.xs),
                    child: Row(
                      children: [
                        Icon(
                          _paths[i] != null
                              ? Icons.check_circle
                              : i == current
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                          color: _paths[i] != null
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                        ),
                        const SizedBox(width: ProxSpacing.sm),
                        Expanded(
                          child: Text(
                            '${faceEnrollSlots[i][0].toUpperCase()}${faceEnrollSlots[i].substring(1)}'
                            '${_paths[i] != null ? ' — captured' : i == current ? ' — now' : ''}',
                          ),
                        ),
                        if (_paths[i] != null && !validated)
                          TextButton(
                            onPressed: (_busy || _saving)
                                ? null
                                : () => _captureAngle(i),
                            child: const Text('Retake'),
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
          if (_notice.isNotEmpty) ...[
            const SizedBox(height: ProxSpacing.md),
            EnrollNotice(message: _notice, isError: false),
          ],
          if (st.phase == EnrollPhase.error && st.message.isNotEmpty) ...[
            const SizedBox(height: ProxSpacing.md),
            EnrollNotice(message: st.message, isError: true),
          ],
          const SizedBox(height: ProxSpacing.lg),
          if (validated)
            ProxPrimaryButton(
              label: const Text('Continue'),
              onPressed: () => EnrollFlow.openResult(context),
            )
          else
            ProxPrimaryButton(
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.face),
              label: Text(
                st.pkHex.isEmpty
                    ? 'Generate key first'
                    : _saving
                        ? 'Checking…'
                        : _busy
                            ? 'Capturing…'
                            : _doneCount == 0
                                ? 'Capture ${faceEnrollSlots[current]} still'
                                : 'Capture ${faceEnrollSlots[current]} still ($_doneCount/${_paths.length} done)',
              ),
              onPressed: (st.pkHex.isEmpty || _busy || _saving)
                  ? null
                  : () => _captureAngle(current),
            ),
          if (st.pkHex.isEmpty)
            const ProxSyncNote(
              'Generate the device key on the previous screen first — the '
              'face capture seals to it.',
            ),
          if (!validated && _doneCount > 0 && !_saving)
            const ProxSyncNote(
              'Progress is kept — cancel any time and only the missing angle stays.',
            ),
          const SizedBox(height: ProxSpacing.sm),
          ProxSecondaryButton(
            label: const Text('Back'),
            expanded: true,
            onPressed: (_busy || _saving)
                ? null
                : () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}
