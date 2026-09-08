// EnrollCapture — CONTINUOUS multi-angle face session
// (Android-face-unlock-style). ONE camera session opened once and closed
// on done/cancel. The preview block below follows the 5186c65
// FaceCaptureScreen construction (Expanded > Center > loose-constraint
// self-sizing CameraPreview); the ratio-critical lines are byte-identical
// (parity test) — see the provenance note at the block for the three
// documented deltas. Overlay and loop adapt to IT, never the reverse.
//
// Guidance is follow-the-dot, never narrated checker state (narrating
// "turn more / checking" while the user had already turned is what
// flickered). Provenance: Apple Face ID enrollment (one stable imperative
// + green rim progress) and Tobii "follow the dot" calibration (one
// target at a time, 5 points, switch focus only on completion). The loop
// captures continuously, reads each still's pose ONCE, and fills ANY
// matching unfilled bucket; the green dot rides the oval at the current
// missing bucket and travels as buckets complete. Rejects stay SILENT
// in-UI (BleLog only).
//
// STABILITY (hysteresis with memory): guidance derives from bucket-fill
// state — the target moves ONLY on fill or stale eviction, so alternating
// per-frame classifications cannot flip-flop dot or line; filled buckets
// never re-request. Gallery write is single + terminal (controller
// .enrollFace → plugin enroll + centre self-check); marking verify
// untouched. HONESTY: five pose-diverse templates buy robustness + spoof
// cost, NOT photo-spoof immunity (passive matcher residual, §4).
// Mobile-only (L2, blocked card); fail-closed save; cancel enrolls
// nothing and disposes the camera.
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
  /// failure/blank — the loop logs it and takes the next still.
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
  /// Loop beats (behavior timing, not motion — private consts per the
  /// tokens vocabulary note): settle beat after open, steady still
  /// cadence while classifying. One-shot Future.delayeds (never
  /// periodic) so the loop always terminates — no stray timers past
  /// teardown.
  static const _initialBeat = Duration(milliseconds: 600);
  static const _frameBeat = Duration(milliseconds: 600);

  /// Stale budget: wasted stills (unreadable / matching nothing unfilled)
  /// before the dot moves on from a target the user cannot hit. ~30
  /// stills ≈ 45–60s of steady trying — generous, deterministic, and
  /// fake-clock testable (no wall-clock timers). The evicted bucket stays
  /// fillable opportunistically; ANY fill clears evictions.
  static const _staleBudget = 30;

  /// One accepted still per slot (null = bucket unfilled). Order matches
  /// [faceEnrollSlots] for the terminal gallery write.
  late final List<String?> _paths =
      List<String?>.filled(faceEnrollSlots.length, null);

  /// Buckets the dot has moved on from (stale). Classification ignores
  /// this set — evicted buckets still fill from lucky stills.
  final Set<String> _skipped = {};
  int _stale = 0;

  /// Dot travel plumbing: [_dotTween] is replaced (new instance) ONLY on
  /// target change, so unrelated rebuilds never restart the travel;
  /// [_dotShown] caches the latest animated anchor for the next tween's
  /// start (plain field, never triggers builds itself).
  Tween<Offset> _dotTween =
      Tween(begin: Offset.zero, end: Offset.zero);
  Offset _dotShown = Offset.zero;

  /// Session camera, owned by this screen (opened once, closed on
  /// done/cancel). Null on records-only builds (blocked card, never a
  /// camera). Read eagerly in initState so dispose never touches `ref`
  /// after unmount (ref-after-dispose throws while finalizing the tree).
  EnrollSessionCamera? _camera;

  var _opening = true;
  var _denied = false;
  var _failed = false;
  var _saving = false;

  /// Set when the loop must not continue: set complete (save ran) or
  /// dispose. The loop schedules nothing further once set — one-shot
  /// delays only, never a periodic timer.
  bool _finished = false;
  bool _loopStarted = false;

  /// Dispose latch: set synchronously in dispose; every await below
  /// re-checks it alongside [mounted] so no async work (takePicture, pose
  /// read, enroll, pop, setState) runs after dispose.
  bool _cancelled = false;
  bool get _done => _cancelled || !mounted;

  int get _doneCount => _paths.where((p) => p != null).length;
  Set<String> get _filled => {
        for (var i = 0; i < _paths.length; i++)
          if (_paths[i] != null) faceEnrollSlots[i],
      };

  /// Latched guidance target (hysteresis: MEMORY, not per-frame output):
  /// first unfilled, unevicted slot. Changes ONLY on bucket fill or stale
  /// eviction — alternating per-frame classifications cannot move it.
  String get _target {
    final filled = _filled;
    for (final s in faceEnrollSlots) {
      if (!filled.contains(s) && !_skipped.contains(s)) return s;
    }
    for (final s in faceEnrollSlots) {
      if (!filled.contains(s)) return s;
    }
    return faceEnrollSlots.first; // complete (line shows captured)
  }

  int get _targetIndex => faceEnrollSlots.indexOf(_target);

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

  /// The no-tap driver: take a still, read its pose ONCE, opportunistically
  /// fill ANY matching unfilled bucket. Wasted stills (unreadable /
  /// matching nothing unfilled / capture errors) are SILENT in-UI — BleLog
  /// only — and feed the stale budget that eventually moves the dot on.
  /// Guidance ([_target], dot, line) changes only inside fill/evict
  /// setStates below, never on per-frame output. Stops on set-complete
  /// (save runs once), failure, or dispose.
  Future<void> _autoLoop() async {
    await Future.delayed(_initialBeat);
    while (!_done && !_finished && !_failed) {
      if (_doneCount == _paths.length) break;
      final still = await _captureOne();
      if (_done || _finished || _failed) return;
      if (still != null) {
        PoseReading? reading;
        try {
          reading = await ref.read(poseGateProvider).readPose(still);
        } catch (e) {
          // Records-only L1 (unreachable behind the screen gate): fail
          // closed and silent — the loop simply wastes this still.
          if (_done) return;
          EnrollLog.face('pose read error (silent, continuing): $e');
        }
        if (_done) return;
        final slot = reading == null
            ? null
            : EnrollBucketFill.classifyInto(
                reading.yaw, reading.pitch, reading.roll, _filled);
        if (slot != null) {
          setState(() {
            _paths[faceEnrollSlots.indexOf(slot)] = still;
            _stale = 0;
            _skipped.clear();
            _retarget();
          });
          EnrollLog.face(
              'bucket $slot filled ($_doneCount/${_paths.length})');
        } else {
          EnrollLog.face('still classified nowhere (silent, continuing)');
          _noteStale();
        }
      } else {
        _noteStale();
      }
      if (_done) return;
      if (_doneCount == _paths.length) {
        await _saveAll();
        return;
      }
      await Future.delayed(_frameBeat);
    }
  }

  /// One still, no UI of its own: null on capture failure/blank/missing
  /// key (all BleLog-only — the loop wastes the beat and continues).
  Future<String?> _captureOne() async {
    final cam = _camera;
    if (cam == null) return null;
    if (ref.read(enrollmentControllerProvider).pkHex.isEmpty) return null;
    try {
      final still = await cam.captureStill();
      if (still.trim().isEmpty) {
        EnrollLog.face('blank still (silent, continuing)');
        return null;
      }
      return still;
    } catch (e) {
      EnrollLog.face('capture failed (silent, continuing): $e');
      return null;
    }
  }

  /// Stale accounting: after [_staleBudget] wasted stills the dot moves on
  /// from a target the user cannot hit (eviction, NOT acceptance — the
  /// bucket still fills opportunistically later). Guidance moves here or
  /// on fill; nowhere else.
  void _noteStale() {
    _stale++;
    if (_stale < _staleBudget || _done) return;
    _stale = 0;
    final evicted = _target;
    setState(() {
      _skipped.add(evicted);
      _retarget();
    });
    EnrollLog.face(
        'target $evicted stale ($_staleBudget wasted) — dot moves on');
  }

  /// Recompute the latched target and swing the dot if it moved. Called
  /// ONLY from fill/evict setStates — never from per-frame output.
  void _retarget() {
    final unit = guideDotUnit(_target);
    if (_dotTween.end != unit) {
      _dotTween = Tween(begin: _dotShown, end: unit);
    }
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
      EnrollLog.face('all buckets filled — enrolling');
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
        'session cancelled — nothing enrolled ($_doneCount/${_paths.length} filled, discarded)');
    Navigator.of(context).pop();
  }

  /// THE overlay line: one short stable imperative naming the latched
  /// target (changes only on fill/evict), or the captured state. NEVER a
  /// narration of checker internals — no hold-still/checking/verifying
  /// text anywhere user-facing (those states live in BleLog only).
  String _overlayLine(bool validated, bool noKey) {
    if (_failed || noKey || _opening) return '';
    if (validated || _doneCount == _paths.length) return 'All angles captured';
    return enrollAngleInstructions[_targetIndex].title;
  }

  /// Travelling dot: tweens between bucket anchors on target change
  /// (that travel IS the revolving motion). Duration zero under reduced
  /// motion (meaning is carried by dots + line, never motion alone).
  Widget _guideOval(double fraction, bool complete, bool reduced) {
    return TweenAnimationBuilder<Offset>(
      tween: _dotTween,
      duration: reduced ? Duration.zero : ProxDurations.medium,
      curve: ProxCurves.standard,
      builder: (context, unit, _) {
        _dotShown = unit;
        return FaceCaptureOvalOverlay(
          progress: fraction,
          dotUnit: complete ? null : unit,
        );
      },
    );
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
    final complete = _doneCount == total;
    final line = _overlayLine(validated, noKey);
    final ctl = _camera?.controller;
    // Message for the preview's fail branch (denied / failed / no-key).
    final previewMessage = _failed
        ? (_denied
            ? 'Camera permission is needed for the face check — allow it in settings, then come back. Nothing is enrolled yet.'
            : 'The camera did not start — nothing is enrolled yet. Go back and try again.')
        : 'Generate the device key on the previous screen first — the face capture seals to it.';
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
          // Preview provenance: this block follows the 5186c65
          // FaceCaptureScreen construction — Expanded gives the area,
          // Center passes LOOSE constraints, CameraPreview (an AspectRatio
          // internally) sizes itself, loading spinner while not ready. A
          // parity test pins the ratio-critical lines byte-identical;
          // documented deltas, all outside the sizing path:
          // (a) message text covers denied/failed/no-key (one extra state
          //     vs the original's single status);
          // (b) post-open with a null controller (tests use a
          //     controller-less fake; on real devices open success implies
          //     a non-null initialized controller) renders the FaceOval
          //     placeholder as the Stack's first child, so guidance and
          //     dots render identically in tests and production;
          // (c) the camera Stack gains ONE Positioned overlay child (dots
          //     + stable line) and the oval gains dotUnit — positioned
          //     children never affect Stack sizing, so the ratio is
          //     untouched (the original oval comment is kept verbatim).
          Expanded(
            child: Center(
              child: _denied || _failed || (!_opening && noKey)
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(previewMessage,
                          textAlign: TextAlign.center),
                    )
                  : _opening
                      ? const CircularProgressIndicator()
                      : Stack(
                          fit: StackFit.expand,
                          children: [
                            if (ctl != null)
                              CameraPreview(ctl)
                            else
                              FaceOval(
                                progress: _doneCount / total,
                                prompt: line,
                              ),
                            // The oval ACTUALLY renders on the preview: this
                            // overlay is inside the preview Stack (not beside
                            // it), pointer-transparent, repainting per shot.
                            _guideOval(_doneCount / total, complete,
                                ProxMotion.reduced(context)),
                        // Overlay ONLY — dots + ONE stable imperative
                        // naming the latched target, composited over
                        // the preview, transparent to touch, zero
                        // layout effect on the preview.
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
                                    current: _targetIndex,
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
          // overlay line + travelling dot). Never squeezes the preview
          // mid-session.
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
                    icon: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                    label: const Text('Try again'),
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
