// EnrollCapture session driver — the camera-session owner for the
// continuous multi-angle face session (Android-face-unlock-style).
//
// SPLIT from enroll_capture.dart (2026-09-10 breakup):
//   enroll_capture_session.dart  (THIS file) — camera seam
//     (EnrollSessionCamera / Real / Fake / provider) + the session driver
//     (open/close, classify-fill loop, save, dispose, timers).
//   enroll_capture_sections.dart — single-purpose section widgets
//     (letterboxed preview surface, bottom bar, slot top-up, blocked card).
//   enroll_capture.dart — thin composer screen (build only, no driver).
//
// Verbatim relocation of the pre-split `_EnrollCaptureScreenState`
// implementation in enroll_capture.dart (699-line monolith) — same
// identifiers, same comments, same frozen copy/timings. The ONLY additions
// are the thin public accessors + the init/dispose entry points at the
// bottom, which are verbatim excerpts of the old initState/dispose bodies
// (minus the `super` calls, which stay on the screen).
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
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:proximity_protocol/protocol.dart';

import '../../core/enrollment.dart';
import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../features/face_identity/face_verifier.dart';
import '../../features/face_identity/liveness_gate.dart';
import '../../features/face_identity/pose_gate.dart';
import 'enroll_flow.dart';
import 'enroll_widgets.dart';
import 'setup_step_scope.dart';

/// Session vitality gate: the platform MiniFASNet scorer, default-
/// constructed like [EnrollmentController] does (same copy idiom — no main
/// wiring needed). Widget tests override with [FakeLivenessGate] the same
/// way they override the camera + pose providers.
final enrollSessionLivenessProvider =
    Provider<LivenessGate>((ref) => HeuristicLivenessGate());

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
        // Medium resolution (see face_capture: max stalled old phones for
        // zero matcher gain — FaceNet embeds at ~160px).
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

  /// Guided walk position: index into [EnrollCaptureOrder.order]. Advances
  /// only on accept (wasted stills never move it). Buckets stay indexed
  /// by [faceEnrollSlots] — this drives the ask order only.
  int _orderPos = 0;

  /// Single-slot recapture target (set by [retrySlot] after a slot-naming
  /// refusal): served before the walk order, cleared on fill. The other
  /// buckets are kept — never a full rescan.
  String? _recaptureTarget;

  /// Latest live head angles (holder-perspective degrees) from the most
  /// recent successful pose read — accepted or wasted. Drives the wheel
  /// markers; null until the first read lands.
  double? _liveYaw;
  double? _livePitch;

  /// Marker smoothing: previous angles + stamp of the latest update. The
  /// overlay repaints on the beacon tick, so getters ease the marker from
  /// the previous reading to the current one instead of jumping per beat
  /// (no extra inference — same readings, presentation only). Disabled
  /// under reduced motion (markers jump, like the static beacon).
  double? _liveFromYaw;
  double? _liveFromPitch;
  DateTime? _liveStamp;
  bool _smoothMarkers = true;
  static const _markerEaseMs = 450.0;

  /// Latest measured vitality (liveness) score from the loop's pre-check,
  /// pass or fail (null until the first probe lands or when the last
  /// probe was unreadable). Drives the bottom-bar readout — the holder
  /// sees dim-light dips live instead of silent retries.
  double? _lastVitality;

  /// Bar the last probe was measured against (per-slot: Tl for centre,
  /// [kEnrollSideLivenessThreshold] otherwise). Stored alongside
  /// [_lastVitality] so the readout names the bar that judged the shown
  /// score (not the current target's bar after advancing). Null until the
  /// first probe lands.
  double? _lastBar;

  /// Machine-readable cause of the last unreadable probe (null when the
  /// last probe scored, or none ran yet). Drives the DIM/BLURRY/NO FACE
  /// suffix in the readout — warn-only presentation, never a gate.
  LivenessUnreadableReason? _lastQuality;

  /// Mean brightness (0-255) of the last SCORED probe's crop (null when
  /// the last probe was unreadable, unknown, or predates this field).
  /// Drives the warn-only DIM suffix on passing-but-dark probes — the
  /// throw-reason path above only fires below the 12.0 block floor, which
  /// auto-exposed phone frames almost never reach, so without this the
  /// hint would never appear in a real dark room.
  double? _lastBrightness;

  /// Consecutive dark probes (scored below [kLivenessDimHintBrightness]
  /// or unreadable-with-dim-reason). Reaches [darkStall] at 3, which
  /// promotes the hint from the small bottom-bar suffix to the overlay
  /// prompt — a dark room needs an unmissable line, not a mono caption.
  /// Resets on any bright scored probe (or unknown-brightness probe, which
  /// is tests-only — production always carries brightness); non-dim
  /// unreadable probes leave it unchanged. Presentation only, never a gate.
  int _darkStreak = 0;

  /// True once [_darkStreak] shows the holder is capturing in the dark.
  /// The composer swaps the overlay prompt for the move-to-light line.
  bool get darkStall => _darkStreak >= 3;

  /// Beats since the last bucket fill (any wasted beat — off-target,
  /// unreadable, failing — increments it; a fill resets it). Reaches
  /// [fillStall] at 8 (~5s of spinning), which promotes the overlay
  /// prompt to the stall nudge. This is the reported dark-room failure:
  /// dozens of wasted beats with zero guidance, where no scored probe
  /// ever runs so brightness-based hints cannot fire. Presentation only,
  /// never a gate — a slow-but-fine user just sees a nudge line.
  int _staleBeats = 0;

  /// Beat budget with no fill before the stall nudge (~5s at the steady
  /// 600ms cadence). Normal enrollments fill every 1-3 beats, so this
  /// never fires for a cooperating holder in workable conditions — but a
  /// dark-room spin with no scorable probes reaches it fast enough to
  /// guide instead of spinning silently (field: 35 wasted beats before
  /// the first probe).
  static const _stallBeats = 8;

  /// True once [_staleBeats] beats passed with no bucket fill. The
  /// composer swaps the overlay prompt for the stall nudge.
  bool get fillStall => _staleBeats >= _stallBeats;

  /// Consecutive beats with no readable face (pose gate returned null —
  /// detector saw nothing, the dark-room signature when even garbage
  /// boxes stop coming). Reaches [blindStall] at 4 (~3s): faster than the
  /// no-fill stall because facelessness IS light evidence, while a mere
  /// dry spell may just be a slow holder. Reset by any successful read.
  /// Presentation only, never a gate.
  int _blindBeats = 0;

  /// Faceless-beat budget before the stall nudge + flash assist (~3s).
  static const _blindThreshold = 4;

  /// True once [_blindBeats] faceless beats in a row. Drives the stall
  /// prompt and the flash assist alongside [fillStall].
  bool get blindStall => _blindBeats >= _blindThreshold;

  /// Fast assist trigger (see [flashAssist]): two consecutive dark probes
  /// (~1-2s) light the ring immediately, while the prompt override waits
  /// for the stabler three-probe [darkStall] so transient shadows never
  /// flicker the instruction line.
  bool get _darkGlow => _darkStreak >= 2;

  /// Total loop beats so far (every iteration, fills included) plus the
  /// beat index of the last scored probe. Brightness evidence goes stale:
  /// a bright probe from seconds ago must not veto a ring the room now
  /// needs (holder walked into a closet mid-session), so the graded level
  /// below only trusts brightness younger than [_brightFreshBeats].
  int _beats = 0;
  int _brightBeat = -1000000;

  /// Freshness window for brightness evidence (~2s at the steady cadence).
  static const _brightFreshBeats = 3;

  /// Eased ring intensity actually painted (see [flashLevel]): advances
  /// toward [_flashTarget] on every repaint beat so the ring breathes in
  /// over ~300ms instead of popping, and fades out the same way. Snaps
  /// under reduced motion (no sweep ticks there to ease on).
  double _flashShown = 0.0;

  /// Last measured level (see [_levelForBrightness]), held across beats
  /// with no fresh probe so the ring freezes at the last known darkness
  /// instead of jumping to the canned stall fallback mid-fade. Overwritten
  /// on every scored probe; reset on recapture.
  double _flashHeld = 0.0;

  /// Ease rate per repaint (~300ms to settle — responsive without a pop).
  static const _flashEase = 0.3;

  /// Snap threshold: closer than this to target counts as arrived (hides
  /// the ring fully instead of hovering near-invisible).
  static const _flashSnap = 0.02;

  /// Graded ring intensity 0..1 actually painted (0 = hidden): the darker
  /// the measured crop, the brighter the ring glows. Eased, never jumped.
  double get flashLevel => _flashShown;

  /// Flash-assist switch for the dark session (see flash_assist.dart):
  /// true once the eased ring level is visibly on. Single source of truth
  /// for ring + window brightness so the two never disagree (maxed screen
  /// with no ring, or ring with no light). The window max applies as soon
  /// as the fade starts (~one repaint) and restores as it finishes — light
  /// first, glow follows, both settle together. Pure derivation — no side
  /// effects here (application lives in [FlashAssistSync]).
  bool get flashAssist => _flashShown > 0.05;

  /// Darkness target the eased [flashLevel] chases: fresh measured
  /// brightness maps linearly below the warn hint (bright 70 → 0,
  /// near-black → ~1); without fresh evidence a stalled session holds the
  /// last measured level ([_flashHeld]) — or glows mid (0.5) when nothing
  /// was ever measured — and a readable session shows nothing.
  double _flashTarget() {
    final b = _lastBrightness;
    if (b != null && b.isFinite && (_beats - _brightBeat) <= _brightFreshBeats) {
      return _levelForBrightness(b);
    }
    if (_darkGlow || blindStall || fillStall) {
      return _flashHeld > 0 ? _flashHeld : 0.5;
    }
    return 0.0;
  }

  /// Pure brightness→level mapping (see [_flashTarget]): 0 at/above the
  /// warn hint, linear to 1 at black. Null/non-finite/bright reads 0
  /// (unknown brightness is never darkness evidence).
  double _levelForBrightness(double? b) {
    if (b == null || !b.isFinite || b >= kLivenessDimHintBrightness) {
      return 0.0;
    }
    return ((kLivenessDimHintBrightness - b) / kLivenessDimHintBrightness)
        .clamp(0.0, 1.0);
  }

  /// One ease step toward [target] (or a snap under reduced motion).
  double _stepFlash(double shown, double target, {required bool snap}) {
    if (snap) return target;
    final next = shown + (target - shown) * _flashEase;
    return (next - target).abs() < _flashSnap ? target : next;
  }

  /// True when the ring must jump instead of ease (no sweep ticks under
  /// reduced motion to ease on — beats snap, same as the markers).
  bool _snapFlash() {
    try {
      return ProxMotion.reduced(context);
    } catch (_) {
      return false;
    }
  }

  /// Anti-fluke shaping (NOT a threshold move — the bar is unchanged):
  /// probes clearing the bar at or above [_confirmMargin] in non-dim
  /// light accept immediately; anything weaker (below the margin) or
  /// dark (below the warn hint) only PARKS its slot here and discards
  /// the still. The bucket fills on the next consecutive passing probe
  /// for the SAME slot (with the fresh still); any intervening
  /// off-target / failing / unreadable probe clears the park. Dark-room
  /// lucky singles (field: 0.70-0.84 sightings) no longer fill on their
  /// own, while genuine bright passes (field 0.87-0.99) never park — good
  /// light costs zero extra beats. Unknown brightness (tests-only fakes;
  /// production always carries it) never counts as dim.
  String? _confirmSlot;

  /// Strong-pass line for [_confirmSlot]: at/above accepts immediately
  /// (with non-dim light). Sits between the 0.70 bar and genuine field
  /// passes; shaping only, never a ticket break.
  static const _confirmMargin = 0.85;

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

  /// Key-gate outcome: true when the last open found an enrollment doc
  /// for this account but no unlocked key (locked, retryable) as opposed
  /// to a genuinely keyless draft (generate-first copy). Reset on every
  /// open attempt; cleared on success.
  var _restoreLocked = false;

  /// See [_restoreLocked].
  bool get restoreLocked => _restoreLocked;

  /// In-place retry for the locked gate: re-runs restore + camera open.
  /// Explicit tap, so the restore re-prompts past the dismissal cooldown
  /// (mount-time opens stay silent on cooldown). No-op while
  /// opening/saving or after teardown. The composer shows this behind a
  /// Try-again button only in the locked branch — genuinely keyless
  /// drafts keep the static copy.
  Future<void> retryRestoreAndOpen() async {
    if (_done || _saving || _finished || _failed) return;
    if (mounted) {
      setState(() {
        _opening = true;
        _restoreLocked = false;
      });
    }
    unawaited(_openCamera());
  }

  /// Single-flight for the validated auto-advance: the terminal navigation
  /// (stepper advance or result push) fires at most once per driver, so an
  /// auto-advance racing a manual Continue cannot stack two results. The
  /// manual Continue latch lives on the screen; EnrollFlow drops any
  /// residual second push while a result is open.
  var _advanceBusy = false;

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

  /// Security §4 active-challenge walk for this session (one plan per
  /// open): blink+smile in per-session Fisher-Yates shuffled order
  /// ([EnrollLivenessPlan.fresh] with Random.secure — offline,
  /// unpredictable, the anti-replay property). Each newly accepted bucket
  /// calls [EnrollLivenessPlan.acknowledgeFill] for the current challenge
  /// (time-separated, pose-validated captures). Presence/order record
  /// only — NOT a measured blink/smile classifier (no eye/smile detector
  /// in the stills path; sparse stills cannot catch 200ms blinks), and the
  /// save decider stays the 5 validated buckets + the passive centre-slot
  /// still classifier in `enrollFace` (the plan never passes or fails a
  /// holder by itself; see the honesty note on [EnrollLivenessPlan]).
  /// Marking stays passive-only (single hold-still, no prompts — see
  /// liveness_gate.dart). Null until the session camera opens.
  EnrollLivenessPlan? _livenessPlan;

  int get _doneCount => _paths.where((p) => p != null).length;

  /// Next unfilled slot index — the live head-position target for the
  /// guided walk (recapture first, then walk order, then any straggler).
  /// Falls back to the last slot once the set is complete (the save
  /// runs, so the overlay is gone a beat later). Pure wiring over the
  /// driver's own buckets.
  int get _nextAngle {
    final at = faceEnrollSlots.indexOf(_currentTarget);
    return at == -1 ? _paths.length - 1 : at;
  }

  /// Slot the loop is currently asking for: an open recapture first,
  /// then the walk position, then the first still-unfilled bucket as a
  /// safety net (walk and buckets agree by construction — a recapture is
  /// the only way they diverge).
  String get _currentTarget {
    final recapture = _recaptureTarget;
    if (recapture != null) return recapture;
    if (_orderPos < EnrollCaptureOrder.order.length) {
      return EnrollCaptureOrder.order[_orderPos];
    }
    for (var i = 0; i < _paths.length; i++) {
      if (_paths[i] == null) return faceEnrollSlots[i];
    }
    return faceEnrollSlots.last;
  }

  /// Advances past a filled [slot]: clears a matching recapture, else
  /// steps the walk order (clamped — the straggler fallback covers any
  /// overshoot without touching bucket state).
  void _advanceTarget(String slot) {
    if (_recaptureTarget == slot) {
      _recaptureTarget = null;
      return;
    }
    if (_orderPos < EnrollCaptureOrder.order.length &&
        EnrollCaptureOrder.order[_orderPos] == slot) {
      _orderPos++;
    }
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
    // Rescan-after-restart (and the Accounts Re-scan entry): a fresh
    // controller holds no key (`_keys` null, `pkHex` empty) even though
    // this device stores one. Restore AFTER the camera is up (never
    // before): a slow secure store or blackholed token refresh must never
    // hold the preview hostage behind the opening spinner.
    // Same-account with loaded keys is a cheap no-op, a stored key
    // restores here, and a genuinely keyless draft still refuses honestly
    // below.
    // Deferred past initState via an event-queue hop (Riverpod forbids
    // provider modification inside widget lifecycles): awaited, so the
    // key gate below always reads settled state. Never throws out of
    // open (fail-soft: the gate below decides).
    try {
      await Future(() => ref
          .read(enrollmentControllerProvider.notifier)
          .refreshFromAuth());
    } catch (_) {}
    if (_done) return;
    final ctl = ref.read(enrollmentControllerProvider);
    final locked = ref
        .read(enrollmentControllerProvider.notifier)
        .restoreLockedForAccount;
    if (ctl.pkHex.isNotEmpty) {
      if (mounted) {
        setState(() {
          _opening = false;
          _restoreLocked = false;
        });
      }
    } else if (locked) {
      // Locked, not missing: an enrollment doc exists for this account
      // but the key stayed behind the prompt/failure — offer unlock +
      // retry IN PLACE (never the generate-first copy, never a dead end).
      EnrollLog.face('scan locked: key behind the lock, retry offered');
      if (mounted) {
        setState(() {
          _opening = false;
          _restoreLocked = true;
        });
      }
      return;
    } else {
      EnrollLog.face('scan refused: no device key yet');
      if (mounted) setState(() => _opening = false);
      return;
    }
    EnrollLog.face('session camera open — continuous to completion');
    // Prewarm the face + liveness models while the holder positions for
    // the first still (both loads are idempotent singletons; failures
    // retry on first use). Fail-soft: never throws out of open, never
    // touches the buckets or the save path.
    unawaited(Future(() async {
      try {
        await ref.read(enrollmentControllerProvider.notifier).verifier.init();
      } catch (_) {}
      try {
        HeuristicLivenessGate.prewarm();
      } catch (_) {}
    }));
    // Fresh active-challenge order per session (security §4): shuffled
    // before the first still, so no pre-recorded sequence can match it.
    _livenessPlan = EnrollLivenessPlan.fresh();
    EnrollLog.face(
        'liveness walk: ${_livenessPlan!.order.map((a) => a.name).join(' → ')}');
    _startLoop();
  }

  void _startLoop() {
    if (_loopStarted) return;
    _loopStarted = true;
    // Marker easing follows the motion setting (the sweep timer that
    // repaints between beats never starts under reduced motion, so eased
    // getters would lag a full beat there — jump instead).
    try {
      _smoothMarkers = !ProxMotion.reduced(context);
    } catch (_) {}
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
        // Ring fade lives on this tick (absent under reduced motion, where
        // beats snap instead — see [_flashShown]).
        _flashShown = _stepFlash(_flashShown, _flashTarget(), snap: false);
        setState(() {});
      });
    }
    unawaited(_autoLoop());
  }

  void _stopSweep() {
    _sweepTimer?.cancel();
    _sweepTimer = null;
  }

  /// The no-tap driver: take a still, read its pose ONCE, and fill the
  /// CURRENT guided target when the still passes it — then score vitality
  /// on the candidate BEFORE accepting it (same per-slot bar enrollFace
  /// enforces; non-live candidates are discarded silently and the loop
  /// continues, so the holder never taps Recapture mid-flow). Marginal
  /// passes (below [_confirmMargin]) and dark passes additionally need a
  /// back-to-back confirmation for the same slot (see [_confirmSlot]) —
  /// single lucky sightings in marginal light never fill alone. Targets walk
  /// [EnrollCaptureOrder.order] (bottom → centre → top → left → right),
  /// one angle at a time — never opportunistic: an off-target still is a
  /// quiet retry, and every successful pose read moves the wheel markers
  /// (accepted or not) so the holder steers live. Wasted stills (capture
  /// errors, unreadable, off-target, failing vitality) are SILENT in-UI —
  /// BleLog only — and the loop simply takes the next still. Stops on
  /// set-complete (save runs once), failure, or dispose — every await
  /// re-checks [_done]/[_finished].
  Future<void> _autoLoop() async {
    await Future.delayed(_initialBeat);
    while (!_done && !_finished && !_failed) {
      if (_doneCount == _paths.length) break;
      final target = _currentTarget;
      var filledThisBeat = false;
      var blindBeat = false;
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
        if (_done || _finished) return;
        // Wheels ride every successful read (accepted or wasted): the
        // marker tracks the holder's head live; the band marks the
        // target. setState per beat is the loop's normal paint cost
        // (the beacon already repaints far more often).
        final r = reading;
        if (r != null && mounted) {
          setState(() {
            _liveFromYaw = _smoothMarkers ? _liveYaw : r.yaw;
            _liveFromPitch = _smoothMarkers ? _livePitch : r.pitch;
            _liveYaw = r.yaw;
            _livePitch = r.pitch;
            _liveStamp = DateTime.now();
            _blindBeats = 0;
          });
        } else {
          // No readable face (or the unreachable L1 throw): a faceless
          // beat for the stall logic — and it breaks confirmation
          // consecutiveness (see [_confirmSlot]: a look-away between
          // sightings restarts the park).
          blindBeat = true;
          _confirmSlot = null;
        }
        final pass = r != null &&
            EnrollPoseWindows.check(
                    target, r.yaw, r.pitch, r.roll)
                .ok;
        if (pass) {
          // Vitality pre-check (auto-magic, 2026-09-13): score liveness
          // BEFORE accepting the bucket, with the SAME per-slot bar the
          // terminal enrollFace enforces (Tl for centre,
          // kEnrollSideLivenessThreshold for the diversity slots). A
          // pose-good but non-live still is discarded silently (file
          // deleted best-effort) and the loop simply takes the next still —
          // the holder keeps following the wheels, never taps Recapture.
          // Runs only on pose-accepted candidates (never on wasted stills)
          // so the scorer cost lands on ~5 stills per session, not every
          // beat. enrollFace re-scores everything at save anyway (defense
          // in depth — the loop can only ever reject early, never accept).
          final bar = target == 'centre'
              ? kLivenessThreshold
              : kEnrollSideLivenessThreshold;
          double vitality = -1;
          double? brightness;
          LivenessUnreadableReason? quality;
          try {
            final result = await ref
                .read(enrollSessionLivenessProvider)
                .detectPassive(still);
            vitality = result.score;
            brightness = result.meanBrightness;
          } catch (e) {
            EnrollLog.face(
                'slot $target vitality unreadable (silent, continuing): $e');
            quality = e is LivenessUnreadable
                ? e.reason
                : LivenessUnreadableReason.unknown;
          }
          if (_done || _finished) return;
          if (mounted) {
            // Readout tracks every measured probe (pass or fail) with the
            // bar that judged it; an unreadable probe clears the score
            // back to the placeholder but keeps its bar, so the holder
            // still sees what the next probe must clear. A scored probe
            // clears any prior throw hint and carries its crop brightness
            // for the warn-only DIM suffix; an unreadable one sets the
            // hint from the structured reason (no message parsing).
            final v = vitality;
            final b = brightness;
            final q = quality;
            // Dark streak for the stall prompt: scored-dark and dim-thrown
            // probes extend it, bright/unknown scored probes reset it,
            // other unreadable probes leave it (a no-face miss in good
            // light is not light evidence either way).
            final darkProbe = v < 0
                ? q == LivenessUnreadableReason.dim
                : (b != null &&
                    b.isFinite &&
                    b < kLivenessDimHintBrightness);
            final resetStreak = v >= 0 && !darkProbe;
            setState(() {
              _lastVitality = v < 0 ? null : v;
              _lastBar = bar;
              _lastQuality = v < 0 ? q : null;
              _lastBrightness = v < 0 ? null : b;
              _darkStreak = darkProbe ? _darkStreak + 1 : (resetStreak ? 0 : _darkStreak);
              if (v >= 0) {
                _brightBeat = _beats;
                _flashHeld = _levelForBrightness(b);
              }
              _flashShown = _stepFlash(_flashShown, _flashTarget(),
                  snap: _snapFlash());
            });
          }
          if (vitality < bar) {
            // A miss clears any parked confirmation (confirmation needs
            // back-to-back passes — a failure in between restarts it).
            _confirmSlot = null;
            EnrollLog.face('slot $target vitality '
                '${vitality < 0 ? 'unreadable' : vitality.toStringAsFixed(2)} '
                '< ${bar.toStringAsFixed(2)} (silent, continuing)');
            // Fire-and-forget (never awaited): async dart:io never
            // completes under the widget-test FakeAsync clock, and an
            // await here would stall the loop forever there; on-device it
            // completes normally. Best-effort either way — a leftover
            // temp still is harmless (cache dir, overwritten next run).
            unawaited(File(still).delete().then((_) {}, onError: (_) {}));
          } else {
            // Confirmation shaping (see [_confirmSlot]): strong bright
            // passes accept at once; marginal/dark passes park and need
            // the next consecutive pass for the same slot.
            final dim = brightness != null &&
                brightness.isFinite &&
                brightness < kLivenessDimHintBrightness;
            final strong = vitality >= _confirmMargin && !dim;
            if (_confirmSlot != target && !strong) {
              _confirmSlot = target;
              EnrollLog.face('slot $target marginal vitality '
                  '${vitality.toStringAsFixed(2)} '
                  '(awaiting confirm — silent, continuing)');
              unawaited(File(still).delete().then((_) {}, onError: (_) {}));
            } else {
              // The challenge this fill walks (logged before advancing, so
              // the record names the acknowledged challenge, not the next).
              final walked = _livenessPlan?.current;
              _confirmSlot = null;
              filledThisBeat = true;
              setState(() {
                _paths[faceEnrollSlots.indexOf(target)] = still;
                _staleBeats = 0;
                _flashShown = _stepFlash(_flashShown, _flashTarget(),
                    snap: _snapFlash());
              });
              _advanceTarget(target);
              _livenessPlan?.acknowledgeFill();
              EnrollLog.face(
                  'bucket $target filled ($_doneCount/${_paths.length})'
                  ' vitality=${vitality.toStringAsFixed(2)}'
                  '${walked == null ? '' : ' — challenge ${walked.name} walked'}');
            }
          }
        } else {
          // Looking away breaks consecutiveness (see [_confirmSlot]).
          _confirmSlot = null;
          EnrollLog.face('still off-target $target (silent, continuing)');
        }
      }
      // The save latches [_finished] synchronously at start, so an
      // in-flight still that lands during the terminal write is dropped
      // here (and at the two gates above) instead of filling a bucket
      // mid-save — the camera never takes another still once Processing
      // owns the set, and progress never moves under it.
      if (_done || _finished) return;
      if (_doneCount == _paths.length) {
        await _saveAll();
        return;
      }
      // Stale-beat accounting for the stall nudge (see [fillStall]) +
      // ring fade (see [_flashShown]): a beat that filled nothing counts;
      // a fill beat resets above and is excluded here. setState per wasted
      // beat matches the loop's existing paint cost (the beacon already
      // repaints far more often) and keeps the prompt switch responsive
      // under reduced-motion too (no sweep timer there to repaint or ease
      // on — beats snap instead).
      _beats++;
      if (!filledThisBeat && mounted) {
        setState(() {
          _staleBeats++;
          if (blindBeat) _blindBeats++;
          _flashShown = _stepFlash(_flashShown, _flashTarget(),
              snap: _snapFlash());
        });
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
    // Fail-closed completeness gate (C4): buckets alone never save — the
    // shuffled liveness walk must also be complete. Throws StateError so a
    // programmatic early call (incl. manual "Try again" before completion)
    // can never enroll a partial session; the loop only reaches here on
    // set-complete, so this is defense-in-depth, never the happy path.
    if (!bucketsComplete || !livenessChallengesDone) {
      EnrollLog.face('save refused: incomplete '
          '(buckets $_doneCount/${_paths.length}, '
          'liveness ${livenessChallengesDone ? 'done' : 'pending'})');
      throw StateError(
          'Enrollment incomplete — capture all ${faceEnrollSlots.length} angles and complete the liveness walk before saving.');
    }
    _stopSweep();
    final ctl = ref.read(enrollmentControllerProvider.notifier);
    setState(() {
      _saving = true;
      _finished = true;
    });
    try {
      EnrollLog.face('all buckets filled — enrolling');
      EnrollLog.face('liveness walk complete: '
          '${_livenessPlan!.order.map((a) => a.name).join(' → ')}');
      await ctl.enrollFace([for (final p in _paths) p ?? ''],
          challengeOrder: List<LivenessAction>.of(_livenessPlan!.order));
      if (_done) return;
      final after = ref.read(enrollmentControllerProvider);
      if (after.phase == EnrollPhase.faceDone) {
        EnrollLog.face('session validated — continuing');
        if (!mounted) return;
        // STEP-SCOPE: inside SetupFlow, Continue advances the stepper
        // instead of pushing the standalone result route. Single-flight
        // via _advanceBusy (auto vs manual Continue race).
        if (_advanceBusy) return;
        _advanceBusy = true;
        final scope = SetupStepScope.of(context);
        if (scope != null) {
          unawaited(scope.next().whenComplete(() => _advanceBusy = false));
        } else {
          try {
            final pushed = EnrollFlow.openResult(context);
            unawaited(pushed.whenComplete(() {
              if (!_done) _advanceBusy = false;
            }));
          } catch (_) {
            _advanceBusy = false;
            rethrow;
          }
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

  /// Next unfilled slot index (overlay head-position target).
  int get nextAngle => _nextAngle;

  /// Guided-walk target slot for the wheels overlay (recapture-aware).
  /// Null-safe by construction — always names a real slot.
  String get targetSlot => _currentTarget;

  /// Latest live head angles for the wheel markers (null until the first
  /// successful pose read lands). Eased from the previous reading over
  /// [_markerEaseMs] so the marker glides between beats instead of
  /// jumping (presentation only — verdicts use the raw reading).
  /// Reduced-motion jumps (no intermediate repaints exist there anyway).
  double? get liveYaw => _easedAxis(_liveFromYaw, _liveYaw);
  double? get livePitch => _easedAxis(_liveFromPitch, _livePitch);

  double? _easedAxis(double? from, double? to) {
    if (to == null || !to.isFinite) return null;
    final stamp = _liveStamp;
    if (!_smoothMarkers ||
        from == null ||
        !from.isFinite ||
        stamp == null) {
      return to;
    }
    final t = (DateTime.now().difference(stamp).inMilliseconds /
            _markerEaseMs)
        .clamp(0.0, 1.0);
    if (t >= 1.0) return to;
    final e = 1 - (1 - t) * (1 - t); // ease-out quad
    return from + (to - from) * e;
  }

  /// Bottom-bar live readout: latest measured vitality + the bar that
  /// judged it + measured crop brightness + guided target (e.g.
  /// `LIVE 0.93/0.70 B139 · DOWN`, or `LIVE —/0.70 · DOWN · DIM` after an
  /// unreadable dim probe, or `LIVE 0.99/0.70 B58 · DOWN · DIM` for a
  /// passing-but-dark probe). The brightness sits in the same line as the
  /// score (same probe the native gate logs as `bright=`) so the holder
  /// sees the number, not just the verdict. Placeholders until the first
  /// probe/read lands. No match score exists mid-walk (the matcher first
  /// runs at the terminal self-check — its boundary score lands on the
  /// result screen), so this line never invents one. The DIM/BLURRY/NO
  /// FACE suffix is warn-only presentation — it never gates anything, and
  /// file/timeout/unknown failures stay silent (no wrong hint). The
  /// scored-probe DIM comes from [kLivenessDimHintBrightness] (warn-only);
  /// the unreadable-probe DIM comes from the throw reason at the 12.0
  /// block floor.
  String get liveReadout {
    final v = _lastVitality;
    final score = v == null ? '—' : v.toStringAsFixed(2);
    final bar = _lastBar ??
        (_currentTarget == 'centre'
            ? kLivenessThreshold
            : kEnrollSideLivenessThreshold);
    final bright = _lastBrightness;
    final bTok = bright != null && bright.isFinite
        ? ' B${bright.round()}'
        : '';
    String? hint;
    if (v == null) {
      hint = LivenessUnreadable.shortLabel(
          _lastQuality ?? LivenessUnreadableReason.unknown);
    } else {
      if (bright != null &&
          bright.isFinite &&
          bright < kLivenessDimHintBrightness) {
        hint = 'DIM';
      }
    }
    final target = _currentTarget.toUpperCase();
    return hint == null
        ? 'LIVE $score/${bar.toStringAsFixed(2)}$bTok · $target'
        : 'LIVE $score/${bar.toStringAsFixed(2)}$bTok · $target · $hint';
  }

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

  /// Current active-liveness challenge for this session (null when the
  /// walk is complete or the session has not opened yet). Render slot for
  /// the future visible challenge cue — the overlay prompt copy stays
  /// frozen (out of scope), so nothing renders this yet; the walk is
  /// enforced driver-side regardless.
  LivenessAction? get currentLivenessChallenge => _livenessPlan?.current;

  /// True once both shuffled challenges have been walked (presence/order
  /// record — not a vitality verdict; see [EnrollLivenessPlan]).
  bool get livenessChallengesDone => _livenessPlan?.isComplete ?? false;

  /// Buckets complete: all 5 pose-validated stills accepted.
  bool get bucketsComplete => _doneCount == _paths.length;

  /// Session complete: 5 buckets AND the shuffled liveness walk. The
  /// [_saveAll] fail-closed gate below enforces this — never save on
  /// buckets alone.
  bool get isComplete => bucketsComplete && livenessChallengesDone;

  /// Manual "Try again" re-runs the terminal write without touching the
  /// accepted stills (forwards to [_saveAll]).
  Future<void> retrySave() => _saveAll();

  /// Single-slot recapture after a slot-naming refusal (the controller
  /// names the failed slot via [EnrollmentController.lastFailedSlot] and
  /// the message copy already says "recapture just that angle" — this is
  /// the action behind that copy). Clears the refused still (file deleted
  /// best-effort) and parks the slot as the loop's next target (served
  /// before the walk order); unlatches the save and restarts the classify
  /// loop. The set re-completes and saves again with the fresh still. The
  /// other four buckets are kept — never a full rescan. No-op for unknown
  /// slots, mid-save calls, or torn-down sessions.
  Future<void> retrySlot(String slot) async {
    final i = faceEnrollSlots.indexOf(slot);
    if (i == -1 || _done || _saving) return;
    final old = _paths[i];
    _paths[i] = null;
    if (old != null && old.isNotEmpty) {
      // Fire-and-forget like the in-loop discard above (an awaited
      // async delete never completes under the widget-test FakeAsync
      // clock; on-device it completes normally either way).
      unawaited(File(old).delete().then((_) {}, onError: (_) {}));
    }
    EnrollLog.face('slot recapture reopened: $slot (kept $_doneCount/'
        '${_paths.length} buckets)');
    _recaptureTarget = slot;
    // Stale readout would name the old probe's score against the new
    // target — clear back to the placeholder (presentation only).
    _lastVitality = null;
    _lastBar = null;
    _lastQuality = null;
    _lastBrightness = null;
    _darkStreak = 0;
    _blindBeats = 0;
    _flashHeld = 0.0;
    // A parked confirmation names the old target — recapture restarts it.
    _confirmSlot = null;
    _finished = false;
    if (mounted) setState(() => _saving = false);
    _loopStarted = false;
    _startLoop();
  }

  /// Verbatim excerpt of the pre-split initState body (minus `super`).
  /// The screen calls this from its own initState.
  void initCaptureSession() {
    // Keyboard-first entry (ID field on the account step): drop any open
    // keyboard before the camera opens, or the resize squishes the preview
    // on the first beats. Backed by resizeToAvoidBottomInset:false on the
    // screen Scaffold (belt-and-braces — no editable text lives here).
    FocusManager.instance.primaryFocus?.unfocus();
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
