// EnrollCapture session driver — the camera-session owner for the
// continuous multi-angle face session (Android-face-unlock-style).
//
// SPLIT from enroll_capture.dart (2026-09-10 breakup — see
//   enroll_capture_session.dart  (THIS file) — camera seam
//     (EnrollSessionCamera / Real / Fake / provider) + the session driver
//     (open/close, classify-fill loop, save, dispose, timers).
//   enroll_capture_sections.dart — single-purpose section widgets
//     (letterboxed preview surface, bottom bar, slot top-up, blocked card).
//   enroll_capture.dart — thin composer screen (build only, no driver).
//
// the pre-split `_EnrollCaptureScreenState` implementation in
// enroll_capture.dart (699-line monolith) — same identifiers, same
// comments, same frozen copy/timings. The ONLY additions are the thin
// public accessors + the init/dispose entry points at the bottom, which
// are verbatim excerpts of the old initState/dispose bodies (minus the
// `super` calls, which stay on the screen). Called out in full in
//
// The driver is a mixin (`on ConsumerState`) so `ref` / `context` /
// `mounted` / `setState` resolve exactly as they did on the old State —
// no signature changes, no behavior changes. Public getters expose the
// private buckets to the composer screen + section widgets across the
// library boundary (privates stay private to this library, as before).
//
// Frozen (do NOT change here): 5-angle slots ([faceEnrollSlots]), loop
// beats, sweep cadence, classify-fill semantics, retry/burn rules (rejects
// SILENT in-UI, BleLog only), STEP-SCOPE branches, all refusal/status
// copy, controller boundary (core/enrollment.dart untouched).
library;

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/enrollment.dart';
import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../features/face_identity/face_verifier.dart';
import '../../features/face_identity/pose_gate.dart';
import 'enroll_flow.dart';
import 'enroll_widgets.dart';
import 'setup_step_scope.dart';

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

/// Continuous-session driver (relocated verbatim from the pre-split
/// `_EnrollCaptureScreenState` — see file header). Owns: camera open/close,
/// the classify-fill auto loop, the terminal gallery write, dispose, and
/// all timers. Owns NO widgets: the composer screen + section widgets read
/// it through the public getters below and trigger retries via
/// [retrySave]. Reduced-motion behavior lives here (the sweep timer never
/// starts under [ProxMotion.reduced], the beacon renders statically).
mixin EnrollCaptureSessionDriver<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
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

  /// Next unfilled slot index — the live head-position target for the small
  /// oval. Falls back to the last slot once the set is complete (the save
  /// runs, so the overlay is gone a beat later). Pure wiring over the
  /// driver's own buckets; the loop above never reads it.
  int get _nextAngle {
    final at = _paths.indexWhere((p) => p == null);
    return at == -1 ? _paths.length - 1 : at;
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
        _sweep += 2 *
            3.141592653589793 *
            _sweepTick.inMilliseconds /
            _sweepRevolution.inMilliseconds;
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
          EnrollLog.face('bucket $slot filled ($_doneCount/${_paths.length})');
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
        // STEP-SCOPE: inside SetupFlow, Continue advances the stepper
        // instead of pushing the standalone result route.
        final scope = SetupStepScope.of(context);
        if (scope != null) {
          scope.next();
        } else {
          EnrollFlow.openResult(context);
        }
      } else {
        EnrollLog.face('controller: ${after.message}');
      }
    } finally {
      if (!_done) setState(() => _saving = false);
    }
  }

  // --- Composer boundary (NEW thin accessors over the verbatim driver
  // above — the only identifiers the screen + section widgets may touch).
  // Added by the breakup; driver bodies above are untouched.

  /// Accepted-still count (drives the overlay progress bar).
  int get doneCount => _doneCount;

  /// Filled slot names (kept for completeness; the overlay reads
  /// [nextAngle], the loop reads [_filled] internally).
  Set<String> get filledSlots => _filled;

  /// Next unfilled slot index (overlay head-position target).
  int get nextAngle => _nextAngle;

  /// Slot count (== [faceEnrollSlots.length]; drives progress + logs).
  int get slotTotal => _paths.length;

  /// Current beacon head angle (paint-only). The composer passes null
  /// under reduced motion so the overlay renders its static target.
  double get sweepValue => _sweep;

  /// Live preview controller (null until open completes / in the fake).
  CameraController? get previewController => _camera?.controller;

  /// Fail-closed camera states for the preview region.
  bool get isOpening => _opening;
  bool get isDenied => _denied;
  bool get isFailed => _failed;

  /// Terminal-write busy flag (disables the Try-again button).
  bool get isSaving => _saving;

  /// Manual "Try again" re-runs the terminal write without touching the
  /// accepted stills (forwards to [_saveAll]).
  Future<void> retrySave() => _saveAll();

  /// Verbatim excerpt of the pre-split initState body (minus `super`).
  /// The screen calls this from its own initState.
  void initCaptureSession() {
    if (!canUseFace()) return; // build() shows the blocked card.
    _camera = ref.read(enrollSessionCameraProvider);
    unawaited(_openCamera());
  }

  /// Verbatim excerpt of the pre-split dispose body (minus `super`).
  /// The screen calls this first from its own dispose.
  void disposeCaptureSession() {
    _cancelled = true;
    _stopSweep();
    unawaited(_camera?.close());
  }
}
