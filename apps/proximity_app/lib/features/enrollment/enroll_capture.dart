// EnrollCapture — CONTINUOUS multi-angle face session
// (Android-face-unlock-style). ONE camera session opened once and closed
// on done/cancel. The preview subtree below — Scaffold > Column >
// Expanded > Center > message/spinner/camera-Stack, plus the bottom
// prompt bar — matches the FaceCaptureScreen boundary handling
// (lib/screens/face_capture.dart) line by line: same Scaffold defaults
// (no SafeArea in either camera path, resize true, extendBody false,
// same AppBar height, same Padding(16) bottom slot), because the displayed
// ratio IS the preview-area ratio: StackFit.expand lays non-positioned
// children tight(biggest) (SDK stack.dart) and CameraPreview's internal
// AspectRatio adopts tight sizes ignoring ratio (SDK proxy_box.dart), so a
// shorter bottom bar enlarges the area and visibly elongates the feed.
// Root cause was bottom-slot sizing (single prompt vs original
// prompt+status+button); fixed by invisibly reserving the original extra
// height below. A parity test pins the chain; the provenance note at the
// block lists each kept deviation with a one-line reason. Overlay stays
// strictly Positioned/IgnorePointer decoration with zero layout effect.
//
// Guidance is a slow rotating beacon on the oval rim (ONE bright head +
// SHORT fading tail, fully transparent well before a full revolution — no
// trails) on the blue inner oval, plus a green outer completion ring per
// bucket, plus ONE static prompt (rotate slowly, follow the glow) — no
// narrated checker state (narrating "turn more / checking" while the user
// had turned is what flickered). Provenance: Apple Face ID enrollment (one
// imperative + rim progress) and Tobii "follow the target" calibration (one
// target, 5 points, repeat missing). Under the paint, buckets keep filling
// opportunistically (EnrollBucketFill.classifyInto on one readPose per
// still); progress dots are the sole completion indicator. Rejects stay
// SILENT in-UI (BleLog only). Under reduced motion the beacon timer never
// starts and the rim shows a steady soft full glow.
//
// Gallery write is single + terminal (controller.enrollFace → plugin
// enroll + centre self-check); marking verify untouched. HONESTY: five
// pose-diverse templates buy robustness + spoof cost, NOT photo-spoof
// immunity (passive matcher residual, §4). Mobile-only (L2, blocked
// card); fail-closed save; cancel enrolls nothing and disposes camera.
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

/// Hidden 52px top-up (prompt-height + gap + status-height + gap) shared by
/// the terminal bottom variants so every variant totals the mid-flow slot.
/// Same line heights as the visible pieces, hidden, no semantics, no
/// buttons — pure boundary parity, zero visible or interactive effect.
class _SlotTopUp extends StatelessWidget {
  const _SlotTopUp();
  @override
  Widget build(BuildContext context) {
    return Visibility(
      visible: false,
      maintainSize: true,
      maintainAnimation: true,
      maintainState: true,
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'X',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: ProxSpacing.xs),
            const Text('X'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

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
  /// periodic) so the capture loop always terminates — no stray timers
  /// past teardown. The beacon runs on its own short periodic timer
  /// (started/stopped with the loop, cancelled on save/dispose).
  static const _initialBeat = Duration(milliseconds: 600);
  static const _frameBeat = Duration(milliseconds: 600);

  /// Beacon pace: one calm clockwise revolution per 4.5s (80 ticks).
  static const _sweepTick = Duration(milliseconds: 50);
  static const _sweepRevolution = Duration(milliseconds: 4500);

  /// One accepted still per slot (null = bucket unfilled). Order matches
  /// [faceEnrollSlots] for the terminal gallery write.
  late final List<String?> _paths =
      List<String?>.filled(faceEnrollSlots.length, null);

  /// Beacon head angle (radians, east = 0, clockwise on screen). Advanced
  /// by the beacon timer; paint-only (never guidance state — buckets fill
  /// opportunistically regardless of where the beacon is).
  double _sweep = 0;
  Timer? _sweepTimer;

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
  /// dispose. The loop schedules nothing further once set.
  bool _finished = false;
  bool _loopStarted = false;

  /// Dispose latch: set synchronously in dispose; every await below
  /// re-checks it alongside [mounted] so no async work (takePicture, pose
  /// read, enroll, pop, setState) runs after dispose. The beacon timer is
  /// cancelled here too (same latch).
  bool _cancelled = false;
  bool get _done => _cancelled || !mounted;

  int get _doneCount => _paths.where((p) => p != null).length;
  Set<String> get _filled => {
        for (var i = 0; i < _paths.length; i++)
          if (_paths[i] != null) faceEnrollSlots[i],
      };

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
    _stopSweep();
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
    // Beacon: calm clockwise travel while classifying. Never started
    // under reduced motion (steady soft full-rim glow instead) and always
    // cancelled on save/dispose — a live periodic timer past teardown
    // fails widget tests, so its lifecycle is tied to the loop's.
    if (!ProxMotion.reduced(context)) {
      _sweepTimer?.cancel();
      _sweepTimer = Timer.periodic(_sweepTick, (_) {
        if (_done || _finished || _failed) return;
        _sweep +=
            2 * 3.141592653589793 * _sweepTick.inMilliseconds / _sweepRevolution.inMilliseconds;
        if (_sweep > 2 * 3.141592653589793) {
          _sweep -= 2 * 3.141592653589793;
        }
        setState(() {});
      });
    }
    unawaited(_autoLoop());
  }

  void _stopSweep() {
    _sweepTimer?.cancel();
    _sweepTimer = null;
  }

  /// The no-tap driver: take a still, read its pose ONCE, opportunistically
  /// fill ANY matching unfilled bucket. Wasted stills (unreadable /
  /// matching nothing unfilled / capture errors) are SILENT in-UI — BleLog
  /// only — and feed the stale budget that eventually moves the dot on.
  /// Guidance ([_target], dot, line) changes only inside fill/evict
  /// setStates below, never on per-frame output. Stops on set-complete
  /// (save runs once), failure, or dispose.
  /// The no-tap driver: take a still, read its pose ONCE, opportunistically
  /// fill ANY matching unfilled bucket. Wasted stills (capture errors,
  /// unreadable, matching nothing unfilled) are SILENT in-UI — BleLog
  /// only — and the loop simply takes the next still. No target, no
  /// eviction: with no dot to steer, every still is either progress or a
  /// quiet retry. Stops on set-complete (save runs once), failure, or
  /// dispose — every await re-checks [_done]/[_finished].
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
        // Fill is the ONLY setState in the loop: progress dots advance,
        // nothing else on screen ever changes mid-flow (the prompt is
        // static, the beacon is paint-driven).
        if (slot != null) {
          setState(() {
            _paths[faceEnrollSlots.indexOf(slot)] = still;
          });
          EnrollLog.face(
              'bucket $slot filled ($_doneCount/${_paths.length})');
        } else {
          EnrollLog.face('still classified nowhere (silent, continuing)');
        }
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

  /// Terminal gallery write (runs once per set; manual "Try again" re-runs
  /// it without touching the accepted stills). Stops the sweep first (the
  /// error/success UI is static). Fail-closed: anything but faceDone
  /// leaves the error on the controller with progress kept.
  Future<void> _saveAll() async {
    if (_saving) return;
    _stopSweep();
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
    final ctl = _camera?.controller;
    final reduced = ProxMotion.reduced(context);
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
          // Preview boundaries (audit vs FaceCaptureScreen in
          // lib/screens/face_capture.dart — Scaffold defaults identical: no
          // SafeArea in either camera path (no double-apply), resize true,
          // extendBody/extendBodyBehindAppBar false, same AppBar height,
          // same Padding(16) bottom slot, no edge-to-edge flags, nothing
          // drawing under/over system UI; shared chrome (theme/scaffold/nav)
          // clean — no change there): StackFit.expand lays non-positioned
          // children tight(biggest) and CameraPreview's internal AspectRatio
          // adopts tight sizes ignoring ratio, so displayed ratio IS
          // preview-area ratio — area set by this chain (Scaffold >
          // Column(max) > Expanded(flex 1) > Center >
          // message/spinner/camera-Stack) plus bottom-bar height. A parity
          // test pins the chain; kept deviations, one line each:
          // (a) AppBar title 'Face capture' (flow-specific, same height).
          // (b) Preview message covers denied/failed/no-key (fail-closed gate).
          // (c) Null-controller FaceOval placeholder (test fake only, never on-device).
          // (d) ONE Positioned dots overlay + beacon params (positioned/paint-only).
          // (e) Mid-flow single prompt + hidden status/button reservation (no flicker + parity).
          // (f) Validated Continue / save-error Try-again + shared hidden top-up (same total — back-nav stable).
          // (g) Blocked path uses ProxScreen (no camera, shared shell).
          // Save-error Notice rides as a toast overlay (same widget/message,
          // zero layout) so message length never moves the feed.
          // Layering (researched, deliberate): chrome stays OVERLAY — dots
          // Positioned in the preview Stack, prompt/buttons in the bottom
          // bar — never inline above the feed. Inline chrome would enter
          // the layout path, shrink and redistribute the preview area, and
          // re-elongate the feed through the same tight-stretch mechanism;
          // overlays have zero layout effect, so the area is set by the
          // bottom slot alone. Native viewfinders composite chrome the same
          // way (CameraX PreviewView overlay siblings —
          // developer.android.com/media/camera/camerax/preview; iOS
          // AVCaptureVideoPreviewLayer with sibling overlay views, never
          // subviews — developer.apple.com/avcapturevideopreviewlayer; the
          // Flutter camera Stack-over-CameraPreview pattern), and the
          // original screen used overlay + bottom bar too.
          // (original oval comment kept verbatim below).
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
                              const FaceOval(progress: 0, prompt: ''),
                            // The oval ACTUALLY renders on the preview: this
                            // overlay is inside the preview Stack (not beside
                            // it), pointer-transparent, repainting per shot.
                            FaceCaptureOvalOverlay(
                              progress: _doneCount / total,
                              sweepAngle: reduced ? 0.0 : _sweep,
                              sweepSpan: reduced
                                  ? 2 * 3.141592653589793
                                  : 1.047,
                            ),
                            // Overlay ONLY — progress dots, composited over
                            // the preview, transparent to touch, zero
                            // layout effect on the preview.
                            Positioned(
                              top: 0,
                              left: 0,
                              right: 0,
                              child: IgnorePointer(
                                child: Padding(
                                  padding:
                                      const EdgeInsets.only(top: 12),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      EnrollAngleDots(
                                        done: _doneCount,
                                        total: total,
                                        current: _doneCount,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            // Fail-closed error banner (save-error only):
                            // toast-pattern overlay — same Notice widget and
                            // message, zero layout effect, so the feed area
                            // never moves on the error transition and long
                            // messages wrap without resizing anything.
                            // Touch-transparent (info only; retry lives in
                            // the bottom bar); semantics kept so readers
                            // still announce the error.
                            if (saveError)
                              Positioned(
                                left: 16,
                                right: 16,
                                bottom: 12,
                                child: IgnorePointer(
                                  child: EnrollNotice(
                                      message: st.message, isError: true),
                                ),
                              ),
                          ],
                        ),
            ),
          ),
          // Bottom bar: the SAME slot height in EVERY lifecycle variant
          // (opening, capturing, message states, validated, save-error, and
          // validated-after-back-navigation) so transitions never resize the
          // feed. Mid-flow shows the single static prompt (the only visible
          // instructional text) plus a hidden status/button reservation;
          // validated shows Continue plus the shared hidden top-up, save-error
          // shows Try-again plus the same top-up — all to the same total.
          // The save-error Notice floats as a toast overlay (zero layout).
          // Keyboard: N/A — this page has no editable text, so viewInsets
          // stay zero in every variant.
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (validated) ...[
                  ProxPrimaryButton(
                    label: const Text('Continue'),
                    onPressed: () => EnrollFlow.openResult(context),
                  ),
                  const _SlotTopUp(),
                ] else if (saveError) ...[
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
                  const _SlotTopUp(),
                ] else ...[
                  Text(
                    enrollCapturePrompt,
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  // Boundary parity: original slot carries prompt + status +
                  // button; single prompt alone would enlarge the preview and
                  // stretch the feed — reserve the extra height invisibly.
                  Visibility(
                    visible: false,
                    maintainSize: true,
                    maintainAnimation: true,
                    maintainState: true,
                    child: ExcludeSemantics(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(height: ProxSpacing.xs),
                          const Text('X'),
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: null,
                            icon: const Icon(Icons.face),
                            label: const Text('X'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
