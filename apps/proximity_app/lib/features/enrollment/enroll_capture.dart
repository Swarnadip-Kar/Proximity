// EnrollCapture — CONTINUOUS multi-angle face session
// (Android-face-unlock-style).
//
// ONE camera session opened once and closed on done/cancel. The preview is
// a FULL-PAGE camera view at its TRUE ratio: CameraPreview sizes itself
// (it is an AspectRatio internally) inside loose Center constraints — the
// certified-good construction from the marking-time FaceCaptureScreen,
// copied here verbatim. The ONLY additions inside the preview Stack are
// Positioned overlay children (thin oval marker + dots + ONE instruction
// line), which never affect Stack sizing, so the ratio cannot regress:
// preview sizes itself, chrome overlays, never contains.
//
// No taps per angle: once the camera opens, an auto-capture loop takes one
// still per slot and pose-gates it (PoseGate: ML Kit head-euler windows on
// the still file). Accept advances, reject shows the targeted hint as the
// overlay line and auto-retries the same slot after a short cooldown — the
// rest of the session stays intact. Accepted stills go to the FaceVerifier
// gallery ONCE at the end (controller.enrollFace → plugin enroll + centre
// self-check); marking-time verify is untouched.
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
import '../../widgets/prox_scaffold.dart';
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
  /// failure/blank — the loop keeps the slot and auto-retries it.
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
  /// Auto-loop beats: settle beat after open, breather after an accept,
  /// repositioning cooldown after a reject (hint stays readable).
  /// One-shot Future.delayeds (never periodic) so the loop always
  /// terminates: completion, save, failure, or dispose schedules nothing
  /// further — no stray timers past teardown.
  static const _initialBeat = Duration(milliseconds: 600);
  static const _acceptBeat = Duration(milliseconds: 400);
  static const _rejectCooldown = Duration(milliseconds: 1200);

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
  var _capturing = false;
  var _validating = false;
  var _saving = false;

  /// Current retry hint (a reject verdict); shown as THE overlay line until
  /// the next attempt. Empty while on-instruction.
  String _notice = '';

  /// Set when the loop must not continue: set complete (save ran) or
  /// dispose. The loop schedules nothing further once set — one-shot
  /// delays only, never a periodic timer.
  bool _finished = false;
  bool _loopStarted = false;

  /// Dispose latch: set synchronously in dispose; every await below
  /// re-checks it alongside [mounted] so no async work (takePicture, pose
  /// check, enroll, pop, setState) runs after dispose.
  bool _cancelled = false;
  bool get _done => _cancelled || !mounted;

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
      });
      EnrollLog.face('session camera failed to open: $e');
      return;
    }
    if (_done) return;
    if (ref.read(enrollmentControllerProvider).pkHex.isEmpty) {
      EnrollLog.face('scan refused: no device key yet');
      setState(() => _opening = false);
      return;
    }
    setState(() => _opening = false);
    EnrollLog.face('session camera open — continuous to completion');
    _startLoop();
  }

  void _startLoop() {
    if (_loopStarted) return;
    _loopStarted = true;
    unawaited(_autoLoop());
  }

  /// The no-tap driver: capture the cursor slot, pose-gate it, accept and
  /// move on or show the hint and auto-retry after a cooldown. Stops on
  /// set-complete (save runs once), failure, or dispose — every await
  /// re-checks [_done]/[_finished] so a late beat never touches UI.
  Future<void> _autoLoop() async {
    await Future.delayed(_initialBeat);
    while (!_done && !_finished && !_failed) {
      if (_doneCount == _paths.length) break;
      final slot = _current;
      await _captureSlot(slot);
      if (_done || _finished || _failed) return;
      if (_doneCount == _paths.length) {
        await _saveAll();
        return;
      }
      await Future.delayed(
          _paths[slot] != null ? _acceptBeat : _rejectCooldown);
    }
  }

  /// Captures + pose-validates one slot inside the open session. Accept
  /// stores the still; retry keeps the slot AND every other accepted still
  /// with the hint as the overlay line (the loop auto-retries it).
  Future<void> _captureSlot(int slot) async {
    if (_capturing || _validating || _saving || _opening || _failed) return;
    final cam = _camera;
    if (cam == null) return;
    if (ref.read(enrollmentControllerProvider).pkHex.isEmpty) return;
    setState(() {
      _capturing = true;
      _notice = '';
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
      });
      return;
    }
    if (_done) return;
    if (still.trim().isEmpty) {
      EnrollLog.face('angle ${faceEnrollSlots[slot]} blank — rescan');
      setState(() {
        _capturing = false;
        _notice =
            'The ${faceEnrollSlots[slot]} still came out blank — hold still.';
      });
      return;
    }
    setState(() {
      _capturing = false;
      _validating = true;
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
      });
      return;
    }
    setState(() {
      _paths[slot] = still;
      _validating = false;
    });
    EnrollLog.face(
        'angle ${faceEnrollSlots[slot]} accepted ($_doneCount/${_paths.length})');
  }

  /// Terminal gallery write (runs once per set; manual "Try again" re-runs
  /// it without touching the accepted stills). Fail-closed: anything but
  /// faceDone leaves the error on the controller with progress kept.
  Future<void> _saveAll() async {
    if (_saving) return;
    final ctl = ref.read(enrollmentControllerProvider.notifier);
    setState(() {
      _saving = true;
      _finished = true;
    });
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

  void _cancel() {
    EnrollLog.face(
        'session cancelled — nothing enrolled ($_doneCount/${_paths.length} accepted, discarded)');
    Navigator.of(context).pop();
  }

  /// THE overlay line (single line, over the preview): retry hint while
  /// one stands, else a transient status, else the current instruction.
  /// Empty in terminal-failure states (the bottom note owns those).
  String _overlayLine(bool validated, bool saveError, bool noKey) {
    if (_failed || noKey) return '';
    if (validated) return 'All angles captured';
    if (_notice.isNotEmpty) return _notice;
    if (_saving) return 'Checking…';
    if (_capturing) return 'Hold still…';
    if (_validating) return 'Checking angle…';
    if (_opening) return 'Starting camera…';
    if (saveError) return '';
    return enrollAngleInstructions[_current].title;
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
    final noKey = st.pkHex.isEmpty;
    final saveError = st.phase == EnrollPhase.error &&
        st.message.isNotEmpty &&
        _doneCount == _paths.length;
    final total = _paths.length;
    final line = _overlayLine(validated, saveError, noKey);
    final ctl = _camera?.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Face capture'),
        actions: [
          // Cancel is label-truthful in every state: dispose the session
          // camera and enroll nothing (fail-closed). Dispose-safe: pop
          // latches _cancelled, the loop/awaits all re-check it.
          TextButton(
            onPressed: _cancel,
            child: const Text('Cancel'),
          ),
        ],
      ),
      body: Column(
        children: [
          // FULL-PAGE preview at its TRUE ratio: Expanded gives the area,
          // Center passes LOOSE constraints, CameraPreview (an AspectRatio
          // internally) sizes itself — the certified-good FaceCaptureScreen
          // construction. ONE Stack always (camera or placeholder inside,
          // identical sizing path): the oval + the dots/line overlay ride
          // along, so guidance is visible even while opening. The only
          // children beyond the certified two are Positioned, which never
          // affect Stack sizing — the ratio cannot regress.
          Expanded(
            child: Center(
              child: _failed || (!_opening && noKey)
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _failed
                            ? (_denied
                                ? 'Camera permission is needed for the face check — allow it in settings, then come back. Nothing is enrolled yet.'
                                : 'The camera did not start — nothing is enrolled yet. Go back and try again.')
                            : 'Generate the device key on the previous screen first — the face capture seals to it.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        if (ctl != null)
                          CameraPreview(ctl)
                        else
                          FaceOval(
                            progress: _doneCount / total,
                            prompt: _opening ? 'Starting camera…' : line,
                          ),
                        // The oval ACTUALLY renders over the preview:
                        // inside the preview Stack (not beside it),
                        // pointer-transparent, repainting per angle.
                        FaceCaptureOvalOverlay(
                          progress: _doneCount / total,
                        ),
                        // Overlay ONLY: dots + ONE instruction line,
                        // composited over the preview, transparent to
                        // touch, zero layout effect on the preview.
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: IgnorePointer(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  EnrollAngleDots(
                                    done: _doneCount,
                                    total: total,
                                    current: _current,
                                  ),
                                  if (line.isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    Container(
                                      margin: const EdgeInsets.symmetric(
                                          horizontal: 24),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: Colors.black54,
                                        borderRadius:
                                            BorderRadius.circular(16),
                                      ),
                                      child: Text(
                                        line,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                            color: Colors.white),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          // Slim bottom bar, ONLY in terminal states (the session itself
          // is chrome-free: Cancel lives in the AppBar, guidance in the
          // overlay line). Never squeezes the preview mid-session.
          if (validated)
            Padding(
              padding: const EdgeInsets.all(16),
              child: ProxPrimaryButton(
                label: const Text('Continue'),
                onPressed: () => EnrollFlow.openResult(context),
              ),
            )
          else if (saveError)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  EnrollNotice(message: st.message, isError: true),
                  const SizedBox(height: ProxSpacing.sm),
                  ProxPrimaryButton(
                    label: Text(_saving ? 'Checking…' : 'Try again'),
                    onPressed: _saving ? null : _saveAll,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
