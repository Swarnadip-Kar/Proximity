// EnrollCapture — CONTINUOUS multi-angle face session
// (Android-face-unlock-style).
//
// ONE camera session opened once and closed on done/cancel — the preview
// never falls out and back per angle. Guided centre → left → right → up →
// down with progress dots + a short instruction per angle + the positioning
// oval OVER THE LIVE PREVIEW. Each angle is REALLY gated: takePicture →
// PoseGate (ML Kit head-euler windows on the still file) → accept advances,
// retry keeps the slot with a targeted hint and the REST OF THE SESSION
// INTACT (retake one angle in-session, never restart). Accepted stills go
// to the FaceVerifier gallery only at the end (controller.enrollFace →
// plugin enroll + centre self-check); marking-time verify is untouched.
//
// HONESTY (do not oversell): five pose-diverse templates buy genuine-match
// robustness and raise the spoof cost (a single frontal print no longer
// suffices — the attacker needs five pose-consistent views), NOT
// photo-spoof immunity against the passive matcher, which still matches a
// good replay held at the right angle. The residual stands in
// PROXIMITY_DESIGN.md §4 and pose_gate.dart.
//
// Mobile-only (L2): records-only devices see the blocked card, never a
// camera. Fail-closed: save blocked until all 5 validate; a failed capture
// stores no face (controller); cancel disposes the camera and enrolls
// nothing.
import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/enrollment.dart';
import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../features/face_identity/face_blocked.dart';
import '../../features/face_identity/face_verifier.dart';
import '../../features/face_identity/pose_gate.dart';
import '../../screens/face_capture.dart';
import '../../widgets/animated.dart';
import '../../widgets/prox_buttons.dart';
import '../../widgets/prox_cards.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_scaffold.dart';
import '../../widgets/prox_states.dart';
import 'enroll_flow.dart';
import 'enroll_widgets.dart';

/// Session-camera seam (navigation/camera plumbing, NOT face math):
/// production opens the real front camera once per session; widget tests
/// override with [FakeEnrollSessionCamera] (scripted paths — the camera
/// plugin has no test double, and angle verdicts come from the injected
/// PoseGate + the driver's FakeFaceVerifier).
abstract class EnrollSessionCamera {
  /// Live preview source. Null until [open] completes (and always null in
  /// the fake, which renders the placeholder instead of CameraPreview).
  CameraController? get controller;

  /// Opens the front camera. Throws StateError on denied/unavailable —
  /// the screen maps those to fail-closed states, never a throw past it.
  Future<void> open();

  /// Captures one still, returning its file path. Throws StateError on
  /// failure/blank — the screen keeps the slot with a retry notice.
  Future<String> captureStill();

  /// Closes the session camera (idempotent; safe to re-[open] after).
  Future<void> close();
}

class RealEnrollSessionCamera implements EnrollSessionCamera {
  CameraController? _ctl;
  bool _closed = false;

  @override
  CameraController? get controller {
    final ctl = _ctl;
    if (ctl == null || !ctl.value.isInitialized) return null;
    return ctl;
  }

  @override
  Future<void> open() async {
    _closed = false;
    final perm = await Permission.camera.request();
    if (_closed) return;
    if (!perm.isGranted) {
      throw StateError('Camera permission is needed for the face check.');
    }
    final cams = await availableCameras();
    if (_closed) return;
    if (cams.isEmpty) throw StateError('No camera found.');
    final front = cams.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cams.first,
    );
    final ctl =
        CameraController(front, ResolutionPreset.medium, enableAudio: false);
    try {
      await ctl.initialize();
    } catch (e) {
      await ctl.dispose();
      rethrow;
    }
    if (_closed) {
      await ctl.dispose();
      return;
    }
    await _ctl?.dispose();
    _ctl = ctl;
  }

  @override
  Future<String> captureStill() async {
    final ctl = _ctl;
    if (_closed || ctl == null || !ctl.value.isInitialized) {
      throw StateError('Camera is not ready — try again.');
    }
    final shot = await ctl.takePicture();
    // Blank-frame guard: a capture that produced no path never reaches the
    // pose gate or the plugin (empty bytes crash native below the catch).
    if (shot.path.trim().isEmpty) {
      throw StateError('Capture produced no image — try again.');
    }
    return shot.path;
  }

  @override
  Future<void> close() async {
    _closed = true;
    final ctl = _ctl;
    _ctl = null;
    await ctl?.dispose();
  }
}

/// Test-only: scripted stills ([script] entries are paths to return or
/// StateErrors to throw per capture) with open/close counters for
/// dispose-safety assertions. Preview stays placeholder ([controller] null).
class FakeEnrollSessionCamera implements EnrollSessionCamera {
  final List<Object> _script;
  final bool failOpen;
  int openCount = 0;
  int closeCount = 0;
  int captures = 0;
  FakeEnrollSessionCamera(
      [List<Object> script = const [], this.failOpen = false])
      : _script = List.of(script);

  @override
  CameraController? get controller => null;

  @override
  Future<void> open() async {
    openCount++;
    if (failOpen) throw StateError('Camera unavailable: fake denial.');
  }

  @override
  Future<String> captureStill() async {
    captures++;
    if (_script.isEmpty) return 'fake-still-$captures.jpg';
    final next = _script.removeAt(0);
    if (next is StateError) throw next;
    return next as String;
  }

  @override
  Future<void> close() async {
    closeCount++;
  }
}

final enrollSessionCameraProvider =
    Provider<EnrollSessionCamera>((ref) => RealEnrollSessionCamera());

class EnrollCaptureScreen extends ConsumerStatefulWidget {
  const EnrollCaptureScreen({super.key});

  @override
  ConsumerState<EnrollCaptureScreen> createState() =>
      _EnrollCaptureScreenState();
}

class _EnrollCaptureScreenState extends ConsumerState<EnrollCaptureScreen> {
  /// One accepted still per slot (null = not yet validated). Kept across
  /// pose retries and failed saves: a retry re-captures only its own slot.
  late final List<String?> _paths =
      List<String?>.filled(faceEnrollSlots.length, null);

  /// Session camera, owned by this screen (opened once, closed on
  /// done/cancel). Null on records-only builds (blocked card, never a
  /// camera). Read eagerly in initState so dispose never touches `ref`
  /// after unmount (ref-after-dispose throws while finalizing the tree).
  EnrollSessionCamera? _camera;

  var _opening = true;
  var _denied = false;
  var _failed = false;
  var _status = 'Starting camera…';
  var _capturing = false;
  var _validating = false;
  var _saving = false;
  String _notice = '';

  /// Dispose latch: set synchronously in dispose; every await below
  /// re-checks it alongside [mounted] so no async work (takePicture, pose
  /// check, enroll, pop, setState) runs after dispose.
  bool _cancelled = false;
  bool get _done => _cancelled || !mounted;

  bool get _busy => _capturing || _validating;
  int get _doneCount => _paths.where((p) => p != null).length;

  /// First slot still missing a validated still (the guided cursor).
  int get _current {
    final i = _paths.indexWhere((p) => p == null);
    return i < 0 ? _paths.length - 1 : i;
  }

  @override
  void initState() {
    super.initState();
    if (!canUseFace()) return; // build() shows the blocked card.
    _camera = ref.read(enrollSessionCameraProvider);
    unawaited(_openCamera());
  }

  @override
  void dispose() {
    _cancelled = true;
    unawaited(_camera?.close());
    super.dispose();
  }

  Future<void> _openCamera() async {
    final cam = _camera;
    if (cam == null) return;
    try {
      await cam.open();
    } catch (e) {
      if (_done) return;
      final msg = '$e';
      setState(() {
        _opening = false;
        _denied = msg.contains('permission');
        _failed = true;
        _status = msg.contains('permission')
            ? 'Camera permission is needed for the face check.'
            : 'Camera unavailable: $e';
      });
      EnrollLog.face('session camera failed to open: $e');
      return;
    }
    if (_done) return;
    setState(() {
      _opening = false;
      _status = 'Ready';
    });
    EnrollLog.face('session camera open — continuous to completion');
  }

  /// Captures + pose-validates one slot inside the open session. Accept
  /// stores the still (auto-saving when the set completes); retry keeps the
  /// slot AND every other accepted still with a targeted hint.
  Future<void> _captureSlot(int slot) async {
    if (_busy || _saving || _opening || _failed) return;
    final cam = _camera;
    if (cam == null) return;
    final st = ref.read(enrollmentControllerProvider);
    if (st.pkHex.isEmpty) {
      EnrollLog.face('scan refused: no device key yet');
      return;
    }
    setState(() {
      _capturing = true;
      _notice = '';
      _status = 'Capturing ${faceEnrollSlots[slot]}… hold still';
    });
    late final String still;
    try {
      still = await cam.captureStill();
    } catch (e) {
      if (_done) return;
      EnrollLog.face('angle ${faceEnrollSlots[slot]} capture failed: $e');
      setState(() {
        _capturing = false;
        _notice = '$e';
        _status = 'Ready';
      });
      return;
    }
    if (_done) return;
    if (still.trim().isEmpty) {
      EnrollLog.face('angle ${faceEnrollSlots[slot]} blank — rescan');
      setState(() {
        _capturing = false;
        _notice =
            'The ${faceEnrollSlots[slot]} still came out blank — try that angle again.';
        _status = 'Ready';
      });
      return;
    }
    setState(() {
      _capturing = false;
      _validating = true;
      _status = 'Checking ${faceEnrollSlots[slot]} angle…';
    });
    PoseDecision decision;
    try {
      decision = await ref
          .read(poseGateProvider)
          .checkSlot(still, faceEnrollSlots[slot]);
    } catch (e) {
      // Records-only L1 (unreachable behind the screen gate) or any
      // unexpected gate throw: fail closed, session kept.
      if (_done) return;
      EnrollLog.face('angle ${faceEnrollSlots[slot]} gate error: $e');
      setState(() {
        _validating = false;
        _notice = '$e';
        _status = 'Ready';
      });
      return;
    }
    if (_done) return;
    if (!decision.ok) {
      EnrollLog.face(
          'angle ${faceEnrollSlots[slot]} rejected — progress kept ($_doneCount/${_paths.length})');
      setState(() {
        _validating = false;
        _notice = decision.hint;
        _status = 'Ready';
      });
      return;
    }
    setState(() {
      _paths[slot] = still;
      _validating = false;
      _status = 'Ready';
    });
    EnrollLog.face(
        'angle ${faceEnrollSlots[slot]} accepted ($_doneCount/${_paths.length})');
    if (_doneCount == _paths.length) {
      await _saveAll();
    }
  }

  Future<void> _saveAll() async {
    final ctl = ref.read(enrollmentControllerProvider.notifier);
    setState(() => _saving = true);
    try {
      EnrollLog.face('all angles accepted — enrolling');
      await ctl.enrollFace([for (final p in _paths) p ?? '']);
      if (_done) return;
      final after = ref.read(enrollmentControllerProvider);
      if (after.phase == EnrollPhase.faceDone) {
        EnrollLog.face('session validated — continuing');
        if (!mounted) return;
        EnrollFlow.openResult(context);
      } else {
        EnrollLog.face('controller: ${after.message}');
      }
    } finally {
      if (!_done) setState(() => _saving = false);
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
    final total = _paths.length;
    // Count copy never overflows: while capturing it names the next angle;
    // a full-but-unvalidated set (save failed) names review instead.
    final countLabel = validated
        ? '$total of $total angles captured'
        : _doneCount < total
            ? 'Angle ${_doneCount + 1} of $total'
            : '$total of $total captured — review below';
    final ctl = _camera?.controller;
    return ProxScreen(
      title: 'Face capture',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ProxStaggered(
            children: [
              EnrollProgress(done: _doneCount, total: total),
          const SizedBox(height: ProxSpacing.sm),
          // Angle progress dots + count (the guided cursor).
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              EnrollAngleDots(
                done: _doneCount,
                total: total,
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
          // ONE live preview for the whole session (never falls out and
          // back): the real CameraPreview once open, the oval illustration
          // while opening / in tests (fake camera has no controller).
          Center(
            child: SizedBox(
              height: 300,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (ctl != null)
                    CameraPreview(ctl)
                  else
                    FaceOval(
                      progress: _doneCount / total,
                      prompt: _opening
                          ? 'Starting camera…'
                          : validated
                              ? 'All angles captured'
                              : instruction.title,
                    ),
                  // The oval ACTUALLY renders over the preview: inside the
                  // preview Stack (not beside it), pointer-transparent,
                  // repainting per accepted angle.
                  FaceCaptureOvalOverlay(
                    progress: _doneCount / total,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: ProxSpacing.xs),
          Text(
            _status,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
          // Per-slot rows: accepted angles offer in-session retake (the rest
          // stay); the current angle offers capture. No camera round-trip.
          ProxCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < total; i++)
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
                                : () => _captureSlot(i),
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
        ],
      ),
          // Session feedback lives BELOW the entrance stagger, on purpose:
          // retry hints answer a just-taken still and must present
          // instantly, never wait behind a re-triggered entrance delay —
          // and late-mounting staggered children race pumpAndSettle in
          // widget tests (400ms cap vs 200ms shake), flaking teardown.
          // The notices keep their own motion (slide/shake in EnrollNotice).
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
                    : _failed
                        ? 'Camera unavailable'
                        : _opening
                            ? 'Starting camera…'
                            : _saving
                                ? 'Checking…'
                                : _busy
                                    ? 'Checking angle…'
                                    : _doneCount == 0
                                        ? 'Capture ${faceEnrollSlots[current]} still'
                                        : 'Capture ${faceEnrollSlots[current]} still ($_doneCount/$total done)',
              ),
              onPressed: (st.pkHex.isEmpty ||
                      _busy ||
                      _saving ||
                      _opening ||
                      _failed ||
                      _denied)
                  ? null
                  : () => _captureSlot(current),
            ),
          if (st.pkHex.isEmpty)
            const ProxSyncNote(
              'Generate the device key on the previous screen first — the '
              'face capture seals to it.',
            ),
          if (!validated && !_failed && _doneCount == 0 && st.pkHex.isNotEmpty)
            const ProxSyncNote(
              'One continuous session — the camera stays open till all 5 '
              'angles validate. Retake any angle without losing the rest.',
            ),
          if (_failed)
            ProxSyncNote(
              _denied
                  ? 'Allow camera access in system settings, then come back — '
                      'nothing is enrolled yet.'
                  : 'The camera did not start — nothing is enrolled yet. '
                      'Go back and try again.',
            ),
          const SizedBox(height: ProxSpacing.sm),
          ProxSecondaryButton(
            label: const Text('Cancel'),
            expanded: true,
            // Cancel disposes the open session camera and enrolls nothing
            // (fail-closed); accepted stills never leave this screen.
            onPressed: (_busy || _saving)
                ? null
                : () {
                    EnrollLog.face(
                        'session cancelled — nothing enrolled ($_doneCount/$total accepted, discarded)');
                    Navigator.of(context).pop();
                  },
          ),
        ],
      ),
    );
  }
}
