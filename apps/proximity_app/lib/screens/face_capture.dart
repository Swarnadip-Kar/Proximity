// Live face-scan screen: continuous still analysis (lock-screen style)
// over a plain stock camera view with a thin oval framing marker (outline
// only — no dimming, glow, or filtering; capture always used the raw
// stills). Each still runs BlazeFace detection + geometric sanity +
// luminance + sharpness; good frames accumulate a streak, and [needStreak]
// consecutive good frames accept one still.
//
// ENROLLMENT CONTRACT (scoring mode, [scorer] set): the camera exits ONLY
// on success — every requested section clears its 0.70 best-pair — or on
// user Cancel (which hands back completed sections so progress is never
// lost). A section that cannot pair up keeps its camera across rounds with
// a "keep going" nudge instead of popping partial; the downstream
// controller drops only the single worst-scoring slot for a targeted
// rescan and repeats until every slot holds a 0.70 pair. One bad frame
// never wipes the section's good embeddings (only the stillness streak
// resets), so a blink or a shaky hand costs a second, never the angle.
// Enrollment may take a little longer; the fast path is marking (below).
//
// Marking runs a VERIFY SESSION ([verifier] set): every accepted still is
// checked against the template live, in-session, with score feedback and
// a countdown. A pass pops at once; failures accumulate and pop together
// so one dead 12s session burns exactly one attempt — a single bad frame
// never exits the camera nor burns a retry on its own. This is the fast
// face check (~1s on a pass): one good frontal frame, one embedding,
// cosine vs template at 0.60.
//
// No camera (simulator/denied) → explicit demo fallback button so the flow
// stays verifiable; the returned bytes are still verified by the real
// embedder downstream, so this path fails closed (needs-review) and can
// never mark. Production devices always go through the real scan.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ble_radio.dart';
import '../core/enrollment.dart' show kEnrollSectionScoreMin;
import '../core/face_camera.dart';
import '../core/face_detect.dart';
import '../core/student_driver.dart';
import '../design/tokens.dart';
import '../main.dart';
import 'package:proximity_face/face.dart';
import 'package:proximity_protocol/protocol.dart';

/// Minimum best-pair cosine completing a scoring section (each guided
/// enrollment angle must independently clear it before the page moves on).
/// Defaults to [kEnrollSectionScoreMin] — the enrollment screen passes the
/// same constant explicitly, and the controller re-validates with
/// [kSlotConsistencyMin] (same value), so the three can never drift apart
/// again (a camera/controller mismatch is what bricked Top in the field).
const kSectionScoreMin = kEnrollSectionScoreMin;

class FaceCaptureScreen extends ConsumerStatefulWidget {
  /// Accepted stills collected per section in streak mode (marking: 1).
  /// Ignored in scoring mode, where sections complete on pair score.
  final int captures;

  /// Consecutive good frames required to accept one still.
  final int needStreak;

  /// Max analyzed stills per auto-retry round before giving up the round.
  /// Frame-counted (not wall-clock) so pacing works under test fake-async
  /// too; 30 ≈ 45s at real-world still cadence.
  final int maxFrames;

  /// Pause between analyzed stills (lets exposure settle, caps cadence).
  final Duration frameGap;

  /// One head-pose zone per section, in order. Single-section callers
  /// (marking, tests) use the default `[any]`; guided enrollment passes
  /// one target per angle. Only in-zone good frames count — misposed
  /// frames steer the arrows without penalty and never reset the streak.
  final List<PoseTarget> sectionTargets;

  /// Per-section instruction lines (same order/length as [sectionTargets]).
  /// Missing entries fall back to a generic prompt.
  final List<String> sectionTitles;

  /// Live identity scorer (enrollment only). Each streak-counted frame is
  /// embedded; a section completes once its best pair reaches
  /// [sectionScoreMin], and only that best pair travels onward — so the
  /// downstream within-slot check always sees high agreement. Null
  /// (marking, tests) = pure streak mode, no scoring, no score display.
  final FaceEmbedder? scorer;

  /// Best-pair cosine completing a scoring section.
  final double sectionScoreMin;

  /// Extra full rounds after a zero-progress timeout before offering the
  /// manual retry button (marking: keep retrying automatically; Cancel is
  /// always available). Attempts are never consumed here either way.
  final int autoRetries;

  /// Live identity verifier (marking only, never with [scorer]). Every
  /// streak-accepted still is checked against the enrolled template
  /// in-session: a pass completes immediately and pops just the passing
  /// frame; a mismatch is kept (popped together at the end so the caller
  /// burns exactly ONE attempt per failed session) with live score
  /// feedback; an inconclusive frame is dropped and scanning continues.
  /// A stale template pops at once so the caller surfaces re-enroll.
  /// Null (enrollment, tests) = pure streak mode, no verification.
  final Future<FaceCheckResult> Function(Uint8List bytes)? verifier;

  /// Wall-clock budget for a verify session (marking: 12s of live
  /// keep-trying with feedback instead of an instant single-frame
  /// verdict). [maxFrames] still bounds the loop — and drives it under
  /// test fake-async, where wall-clock never advances — whichever hits
  /// first ends the session. Ignored without [verifier].
  final Duration verifyWindow;

  /// First section to run (resume). The enrollment screen passes the first
  /// incomplete angle so a repeat tap scans ONLY what remains — completed
  /// angles are never re-captured. Returned pairs stay in order, so the
  /// caller maps pair k to slot (startSection + k). Display (titles,
  /// progress) always counts against the FULL section list.
  final int startSection;

  /// Stay open across rounds until every requested section completes
  /// (enrollment): a mismatched section keeps its camera with a "keep
  /// going" nudge instead of popping partial after [maxFrames]. Bounded —
  /// 3 consecutive rounds with zero new sections fall back to the timeout
  /// offer — and Cancel always exits at once with completed sections.
  /// Default true: enrollment exits ONLY on success or Cancel. Marking
  /// keeps its verify budget and streak scans pop regardless.
  final bool stayOpen;

  const FaceCaptureScreen({
    super.key,
    this.captures = 1,
    this.needStreak = 2,
    this.maxFrames = 30,
    this.frameGap = const Duration(milliseconds: 700),
    this.sectionTargets = const [PoseTarget.any],
    this.sectionTitles = const [],
    this.scorer,
    this.sectionScoreMin = kSectionScoreMin,
    this.autoRetries = 0,
    this.verifier,
    this.verifyWindow = const Duration(seconds: 12),
    this.startSection = 0,
    this.stayOpen = true,
  }) : assert(scorer == null || verifier == null,
            'verifier is marking-only; scoring sections use scorer');

  @override
  ConsumerState<FaceCaptureScreen> createState() => _FaceCaptureScreenState();
}

class _FaceCaptureScreenState extends ConsumerState<FaceCaptureScreen> {
  late final FaceCamera _camera;
  bool _ready = false;
  bool _running = false;
  bool _timedOut = false;
  String? _error;
  String _guidance = 'Starting camera…';
  String _sectionTitle = 'Line up your face in the oval and hold still.';
  // Latest in-session verify verdict (marking): outranks the stock
  // guidance on good frames so the holder sees what to do next
  // ("close — hold still" vs "look straight at the camera"). Reset on
  // quality breaks and retries, never survives a pop.
  String? _verifyNote;
  // Completed sections (pop-ready). Streak mode appends every accepted
  // still; scoring mode appends only each section's best pair. Survives
  // manual + automatic retries: progress is never thrown away.
  final List<List<Uint8List>> _doneSections = [];
  // Current-section partials. Scoring embeds reset with the streak, so
  // pairs always span consecutive good frames.
  List<Uint8List> _secBytes = [];
  List<List<double>> _secVecs = [];
  double _secBest = 0;
  int _runId = 0;

  @override
  void initState() {
    super.initState();
    _camera = ref.read(faceCameraProvider);
    _init();
  }

  Future<void> _init() async {
    try {
      // Camera is requested here (not in the BLE gate) so a denied camera
      // reports as a camera error, never a Bluetooth error (Bug 1).
      final camOk = await ref.read(cameraPermissionProvider)();
      if (!mounted) return;
      if (!camOk) {
        setState(() => _error =
            'Camera permission is required for the face scan. Enable it in Settings, then retry.');
        return;
      }
      await _camera.initialize();
      if (!mounted) return;
      setState(() {
        _ready = _camera.isReady;
        _error = _ready ? null : 'Camera could not start.';
      });
      if (_ready) unawaited(_run(++_runId));
    } on FaceCameraException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  @override
  void dispose() {
    _runId++;
    _camera.dispose();
    super.dispose();
  }

  /// Continuous analyze loop: still → BlazeFace detect + sanity +
  /// luminance + sharpness + pose zone → guidance → streak counting →
  /// section completion → auto-return when every section is done.
  /// Streak mode (no scorer): each section collects [captures] accepted
  /// stills. Verify mode (marking: [verifier] set, [scorer] null): every
  /// streak-accepted still is checked live with score feedback and a
  /// countdown until [verifyWindow] elapses — a pass pops just the passing
  /// frame at once, failures accumulate and pop together (one burned
  /// attempt per dead session, never per frame). Scoring mode
  /// (enrollment): each section completes once its best embedded pair
  /// reaches [sectionScoreMin], and only that pair travels onward.
  /// Timeouts auto-retry ([autoRetries] rounds) while no section has
  /// completed; attempts are consumed downstream only on a confident
  /// mismatch, never here.
  Future<void> _run(int run) async {
    var streak = 0;
    var analyzed = 0;
    var retriesLeft = widget.autoRetries;
    // Stay-open bookkeeping (enrollment): consecutive maxFrames rounds
    // with zero new sections before the timeout offer returns.
    var sectionsAtLastRound = 0;
    var fruitlessRounds = 0;
    // Frontal pitch calibration: median pitch of counted front-section
    // frames this session; up/down gates measure from the holder's own
    // straight-ahead (see poseOkWithRef). Resume scans without a front
    // section (e.g. a Top-only retry) have no frontal frames — then the
    // median of recent counted frames stands in: the holder spends most
    // of the session near neutral while finding the pose, and any error
    // errs LAX (a near-frontal frame clearing Top is harmless — same
    // person, same session), whereas the bare absolute fallback demanded
    // exaggerated tilts that blurred and degraded past any pair bar.
    final frontPitches = <double>[];
    final recentPitches = <double>[];
    double? medianOf(List<double> xs) {
      if (xs.isEmpty) return null;
      final s = List.of(xs)..sort();
      return s[s.length ~/ 2];
    }

    double? pitchRef() =>
        medianOf(frontPitches) ??
        (recentPitches.length >= 3 ? medianOf(recentPitches) : null);
    final targets = widget.sectionTargets;
    final scorer = widget.scorer;
    final verifier = widget.verifier;
    final verifyMode = verifier != null && scorer == null;
    var verifyStart = DateTime.now();
    final start = widget.startSection.clamp(0, targets.length);
    // Seconds left in the verify budget (marking countdown display).
    int verifyLeft() {
      final left = widget.verifyWindow.inSeconds -
          DateTime.now().difference(verifyStart).inSeconds;
      return left < 0 ? 0 : left;
    }
    List<Uint8List> popReady() => [
          for (final s in _doneSections) ...s,
          if (scorer == null) ..._secBytes,
        ];
    setState(() => _running = true);
    final detector = ref.read(faceDetectorProvider);
    while (mounted && run == _runId) {
      // Absolute section number (resume-aware): display, titles and the
      // caller's slot mapping all count against the full list.
      final sectionIndex = start + _doneSections.length;
      if (sectionIndex >= targets.length) break; // every section done
      // Verify sessions also end on wall-clock budget (marking: 12s of
      // live keep-trying). Zero-progress rounds still auto-retry with a
      // fresh budget; rounds holding mismatch frames pop them so the
      // caller burns exactly one attempt for the whole session.
      final verifySpent = verifyMode &&
          DateTime.now().difference(verifyStart) >= widget.verifyWindow;
      if (analyzed >= widget.maxFrames || verifySpent) {
        // Stay-open (enrollment scoring): a mismatched section keeps its
        // camera — new round, same sections, progress intact — instead of
        // popping partial and forcing a re-tap per angle. Bounded by
        // fruitless rounds so a hopeless section still surfaces the
        // timeout offer; Cancel always exits at once regardless.
        if (widget.stayOpen &&
            scorer != null &&
            !verifyMode &&
            start + _doneSections.length < targets.length) {
          if (_doneSections.length > sectionsAtLastRound) {
            sectionsAtLastRound = _doneSections.length;
            fruitlessRounds = 0;
          } else {
            fruitlessRounds++;
          }
          if (fruitlessRounds <= 3) {
            analyzed = 0;
            if (!mounted || run != _runId) return;
            setState(() {
              _guidance =
                  'Keep going — ${_titleFor(start + _doneSections.length)} still needs a clear pair…';
            });
            continue;
          }
        }
        if (retriesLeft > 0 && popReady().isEmpty) {
          retriesLeft--;
          analyzed = 0;
          verifyStart = DateTime.now();
          if (!mounted || run != _runId) return;
          setState(() {
            _verifyNote = null;
            _guidance = 'Still looking — hold steady…';
          });
          continue;
        }
        break;
      }
      Uint8List? bytes;
      try {
        bytes = await _camera.captureStill();
      } on FaceCameraException catch (e) {
        if (!mounted || run != _runId) return;
        setState(() {
          _running = false;
          _error = e.message;
        });
        return;
      }
      if (!mounted || run != _runId) return;
      analyzed++;
      // BlazeFace detection + geometric sanity on this still.
      List<FaceDetection> dets = const [];
      try {
        if (bytes != null) dets = await detector.detect(bytes);
      } on StateError catch (e) {
        // Detector model missing: fail closed, never a pass.
        if (!mounted || run != _runId) return;
        setState(() {
          _running = false;
          _error = 'Face model unavailable: $e';
        });
        return;
      }
      // Back pressed during inference: the route is gone — never touch
      // state after this point without the guard (was a crash).
      if (!mounted || run != _runId) return;
      final target = targets[sectionIndex];
      final best = dets.isEmpty ? null : dets.first;
      final luma = bytes == null ? null : estimateBrightness(bytes);
      final sharp = bytes == null ? null : estimateSharpness(bytes);
      final q = analyzeFrame(
        faces: best == null ? 0 : 1,
        luma: luma,
        sane: best == null || saneGeometry(best),
        sharpness: sharp,
      );
      final yaw = best == null ? null : poseYawOf(best);
      final pitch = best == null ? null : posePitchOf(best);
      // Single live instruction: pose arrows for EVERY guided angle
      // (front/left/right/up/down) come from the same live measurement,
      // so the holder watches ONE line — never top-vs-bottom guesswork.
      // Up/down measure from the session's own frontal reading when one
      // exists (same face, same light), else absolute bands.
      final ref = pitchRef();
      final poseNote = yaw == null
          ? null
          : poseGuidanceWithRef(target, yaw, pitch, ref);
      final poseOk =
          yaw != null && poseOkWithRef(target, yaw, pitch, ref);
      if (q == FrameQuality.good && bytes != null && best != null && poseOk) {
        streak++;
        // Counted frames calibrate the up/down reference: front-section
        // frames ARE straight-ahead (absolute front gate), and every
        // counted frame feeds the recent-pitch fallback that Top/Bottom-
        // only resumes calibrate from (see pitchRef).
        if (pitch != null) {
          recentPitches.add(pitch);
          if (recentPitches.length > 10) recentPitches.removeAt(0);
          if (target == PoseTarget.front) frontPitches.add(pitch);
        }
        if (scorer != null) {
          try {
            _secVecs.add(await scorer.embed(bytes));
            _secBytes.add(bytes);
            // Rolling window: the section pairs over the latest good frames
            // only. Unbounded history would make the best-pair scan O(n²)
            // per frame and let stale light/pose linger; 24 frames hold
            // 276 pairs — far more than any 0.70 pair needs.
            while (_secVecs.length > 24) {
              _secVecs.removeAt(0);
              _secBytes.removeAt(0);
            }
            var bestPair = 0.0;
            for (var i = 0; i < _secVecs.length; i++) {
              for (var j = i + 1; j < _secVecs.length; j++) {
                final c = cosineSimilarity(_secVecs[i], _secVecs[j]);
                if (c > bestPair) bestPair = c;
              }
            }
            _secBest = bestPair;
          } catch (_) {
            // Unscorable frame: streak still counts it, scoring skips it.
          }
        } else if (verifyMode) {
          // Verify session: check every streak-accepted still live. A pass
          // pops just the passing frame at once; a mismatch is kept for
          // the end-of-session single burned attempt; an inconclusive
          // frame is dropped and scanning continues. Nothing pops early
          // and no attempt burns per frame.
          if (streak >= widget.needStreak) {
            FaceCheckResult? vr;
            try {
              vr = await verifier(bytes);
            } catch (_) {
              vr = null;
            }
            // Back pressed during the check: route gone, never touch state.
            if (!mounted || run != _runId) return;
            final left = verifyLeft();
            if (vr?.match == FaceMatch.pass) {
              _secBytes = [];
              _doneSections.add([bytes]);
              break; // any one pass is enough: pop at once
            } else if (vr?.match == FaceMatch.mismatch) {
              _secBytes.add(bytes);
              final s = vr!.score.toStringAsFixed(2);
              _verifyNote = vr.score >= 0.45
                  ? 'Close match ($s) — hold perfectly still, face the light…'
                  : 'Not matching yet ($s) — look straight at the camera, hold still…';
            } else if (vr?.match == FaceMatch.staleTemplate) {
              // Template incomparable: surface re-enroll at once, never
              // loop a dead comparison for the whole window.
              _secBytes = [bytes];
              _verifyNote = null;
              break;
            } else {
              _verifyNote = 'Could not read that frame — hold still…';
            }
            // Pass and stale-template both break above: anything reaching
            // here keeps scanning, with the seconds remaining live.
            _verifyNote = '$_verifyNote ${left}s left';
          }
        } else {
          _secBytes.add(bytes);
        }
        final sectionDone = scorer == null
            ? (!verifyMode && _secBytes.length >= widget.captures)
            : (streak >= widget.needStreak && _secBest >= widget.sectionScoreMin);
        if (sectionDone) {
          _doneSections.add(scorer == null
              ? List.of(_secBytes)
              : _bestPairBytes(_secBytes, _secVecs));
          _secBytes = [];
          _secVecs = [];
          _secBest = 0;
          streak = 0;
          if (start + _doneSections.length >= targets.length) {
            break; // all done: pop at once, no trailing ghost frame
          }
        }
      } else if (q != FrameQuality.good) {
        // One bad frame costs a second, never the angle: only the
        // stillness streak resets. The section's good embeddings are KEPT —
        // wiping them here (old behaviour) meant a single blink/shake
        // discarded the pair progress and the section looped forever.
        streak = 0;
        _verifyNote = null;
      }
      setState(() {
        final idx = start + _doneSections.length;
        final baseTitle = _titleFor(idx);
        // Quality problems outrank pose: fix light/blur first, then turn.
        final note = q == FrameQuality.good ? poseNote : null;
        // In-session verdicts outrank stock copy on good frames (the
        // holder acts on the latest check); quality problems always win.
        var g = (verifyMode && _verifyNote != null && q == FrameQuality.good)
            ? _verifyNote!
            : (note ?? frameGuidance(q));
        if (verifyMode && q != FrameQuality.good) {
          g += ' ${verifyLeft()}s left';
        }
        if (scorer != null && targets.length > 1 && _secVecs.length >= 2) {
          g += ' Best match ${_secBest.toStringAsFixed(2)}'
              ' / need ${widget.sectionScoreMin.toStringAsFixed(2)}.';
        }
        // Live pitch readout (scoring): the holder sees the number move
        // as they tilt, and field reports can quote it — top/bottom
        // stop being guesswork.
        if (scorer != null && pitch != null) {
          g += ' Pitch ${pitch.toStringAsFixed(2)}'
              '${ref != null ? ' (straight ${ref.toStringAsFixed(2)})' : ''}.';
        }
        _guidance = g;
        // Unified live title: the section instruction PLUS the live pose
        // arrow in one place (top). All five angles behave identically —
        // the holder never chooses between a top title and a bottom hint.
        // When the pose is right, confirm with hold-still + live score.
        if (targets.length > 1 && q == FrameQuality.good && note != null) {
          _sectionTitle = '$baseTitle — $note';
        } else if (targets.length > 1 &&
            q == FrameQuality.good &&
            scorer != null &&
            _secVecs.length >= 2) {
          _sectionTitle =
              '$baseTitle — hold still… ${_secBest.toStringAsFixed(2)}/${widget.sectionScoreMin.toStringAsFixed(2)}';
        } else {
          _sectionTitle = baseTitle;
        }
      });
      await Future.delayed(widget.frameGap);
    }
    if (!mounted || run != _runId) return;
    setState(() => _running = false);
    final out = popReady();
    if (out.isEmpty) {
      // Nothing usable in time: offer an explicit retry, never a pass.
      setState(() {
        _timedOut = true;
        _guidance = 'Could not get a clear scan — try again in better light.';
      });
      return;
    }
    Navigator.of(context).pop<List<Uint8List>>(out);
  }

  /// Section instruction line: per-section title when provided, else a
  /// generic prompt (single-section scans keep the old copy). The
  /// idx >= total arm is load-bearing: after the final angle completes,
  /// the title must never read "Section 6 of 5" for a frame.
  String _titleFor(int idx) {
    final total = widget.sectionTargets.length;
    if (idx >= total) return 'All angles captured — finishing…';
    if (idx < widget.sectionTitles.length) return widget.sectionTitles[idx];
    if (total > 1) {
      return 'Section ${idx + 1} of $total — hold still.';
    }
    return 'Line up your face in the oval and hold still.';
  }

  /// The two frames behind the best embedded pair (parallel to [vecs]).
  List<Uint8List> _bestPairBytes(
      List<Uint8List> frames, List<List<double>> vecs) {
    var bi = 0, bj = 1;
    var best = -2.0;
    for (var i = 0; i < vecs.length; i++) {
      for (var j = i + 1; j < vecs.length; j++) {
        final c = cosineSimilarity(vecs[i], vecs[j]);
        if (c > best) {
          best = c;
          bi = i;
          bj = j;
        }
      }
    }
    return [frames[bi], frames[bj]];
  }

  /// Frames to hand back on Cancel: completed sections plus, in plain
  /// streak mode only, the current partial buffer. Scoring-mode partials
  /// are unverified pairs and stay behind (callers chunk by pair);
  /// verify-mode mismatch frames stay behind too, so Cancel never burns
  /// an attempt — only a spent session does.
  List<Uint8List> _cancelPop() => [
        for (final s in _doneSections) ...s,
        if (widget.scorer == null && widget.verifier == null) ..._secBytes,
      ];

  void _retry() {
    setState(() {
      _timedOut = false;
      _verifyNote = null;
      _guidance = 'Starting camera…';
    });
    unawaited(_run(++_runId));
  }

  /// Instruction chip drawn OVER the preview (not in the layout flow):
  /// dark pill, light text, readable over any background. Wrapping inside
  /// the chip only grows the chip itself — the preview box underneath
  /// never changes size.
  Widget _overlayChip(String text, {TextStyle? style}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: (style ?? Theme.of(context).textTheme.bodyMedium)
              ?.copyWith(color: Colors.white),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final total = widget.sectionTargets.length;
    // Absolute progress (resume-aware): a resumed session counts its
    // start offset, so "Section 5 of 5" never becomes "Section 6".
    final start = widget.startSection.clamp(0, total);
    final repoDone = (start + _doneSections.length).clamp(0, total);
    // Progress: sections for guided scans, frames for single scans.
    final progress = total > 1
        ? repoDone / total
        : (_secBytes.length + repoDone * widget.captures) /
            (widget.captures * total);
    final popCount =
        _doneSections.fold<int>(0, (n, s) => n + s.length) + _secBytes.length;
    return AdaptiveScaffold(
      title: 'Face scan',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: _AnimatedScanProgress(value: progress.clamp(0.0, 1.0)),
          ),
          // The preview owns all remaining space at a FIXED size: every
          // instruction lives as an overlay on the camera module, never in
          // the Column flow. The old layout put the title/guidance Texts
          // above/below the preview, so each word-wrap grew the text block
          // and shrank the preview mid-scan — the "slight zoom" jump.
          // Nothing in this Column changes height while scanning now (the
          // progress bar and Cancel button are fixed), so the preview box
          // never resizes under the holder's face.
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _camera.buildPreview(),
                // Pose-guidance oval: thin outline only (no dimming, glow,
                // or filtering — capture uses raw stills). Progress sweeps
                // the ring; a slow breathing scale coaches "hold still".
                // Overlay-only and pointer-transparent: never moves layout,
                // never intercepts taps.
                IgnorePointer(
                  child: Center(
                    child: _PoseOval(
                      progress: progress.clamp(0.0, 1.0),
                      active: _running && _error == null && !_timedOut,
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  left: 12,
                  right: 12,
                  child: _overlayChip(
                    _sectionTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 8,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (total > 1)
                        _overlayChip(
                          repoDone >= total
                              ? 'All $total sections — done'
                              : 'Section ${repoDone + 1} of $total',
                          style: Theme.of(context).textTheme.labelLarge,
                        )
                      else if (widget.captures > 1)
                        _overlayChip(
                          'Captured $popCount of ${widget.captures}',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      const SizedBox(height: 6),
                      _overlayChip(_guidance),
                    ],
                  ),
                ),
                if (_error != null)
                  Center(
                    child: _ErrorCard(
                      message: _error!,
                      onDemo: () => Navigator.of(context)
                          .pop<List<Uint8List>>([_demoBytes()]),
                    ),
                  )
                else if (_timedOut)
                  Center(
                    child: _TimeoutCard(onRetry: _retry),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: OutlinedButton(
              onPressed: () {
                final out = _cancelPop();
                Navigator.of(context)
                    .pop<List<Uint8List>>(out.isEmpty ? null : out);
              },
              child: Text(_running ? 'Cancel' : 'Back'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bytes returned by the no-camera demo fallback. Deliberately not a valid
/// photo: downstream decode + embedding reject them (fail-closed), so the
/// demo path can exercise error UI but never a pass.
Uint8List _demoBytes() => Uint8List.fromList(const [7, 7, 7, 7]);

/// Animated scan progress: sweeps toward the new value over
/// [ProxDurations.medium] instead of jumping per analyzed still.
class _AnimatedScanProgress extends StatelessWidget {
  final double value;
  const _AnimatedScanProgress({required this.value});

  @override
  Widget build(BuildContext context) {
    if (ProxMotion.reduced(context)) {
      return LinearProgressIndicator(value: value);
    }
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: value),
      duration: ProxDurations.medium,
      curve: ProxCurves.standard,
      builder: (context, v, _) => LinearProgressIndicator(value: v),
    );
  }
}

/// Pose-guidance oval: thin outline + progress sweep, drawn with
/// CustomPainter + a slow breathing scale (pure Flutter, no assets).
/// Outline only — never dims, glows, or filters the preview beneath.
class _PoseOval extends StatefulWidget {
  final double progress;
  final bool active;
  const _PoseOval({required this.progress, required this.active});

  @override
  State<_PoseOval> createState() => _PoseOvalState();
}

class _PoseOvalState extends State<_PoseOval>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath;

  @override
  void initState() {
    super.initState();
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    if (widget.active) _breath.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_PoseOval old) {
    super.didUpdateWidget(old);
    if (widget.active && !_breath.isAnimating) {
      _breath.repeat(reverse: true);
    } else if (!widget.active && _breath.isAnimating) {
      _breath.stop();
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ring = Theme.of(context).colorScheme.primary;
    final child = SizedBox(
      width: 220,
      height: 280,
      child: CustomPaint(
        painter: _OvalRingPainter(progress: widget.progress, color: ring),
      ),
    );
    if (ProxMotion.reduced(context) || !widget.active) return child;
    return AnimatedBuilder(
      animation: _breath,
      builder: (context, c) {
        final s = 1.0 + _breath.value * 0.025;
        return Transform.scale(scale: s, child: c);
      },
      child: child,
    );
  }
}

class _OvalRingPainter extends CustomPainter {
  final double progress;
  final Color color;
  _OvalRingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: size.width - 16,
      height: size.height - 16,
    );
    // Base outline: thin white, readable over any preview.
    canvas.drawOval(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.85),
    );
    // Progress sweep in the theme ring color.
    if (progress > 0.005) {
      canvas.drawArc(
        rect,
        -3.141592653589793 / 2,
        2 * 3.141592653589793 * progress.clamp(0.0, 1.0),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round
          ..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_OvalRingPainter old) =>
      old.progress != progress || old.color != color;
}

/// Camera error card: red, one short shake — reads as "session failed",
/// unmistakable from the amber timeout slide below.
class _ErrorCard extends StatefulWidget {
  final String message;
  final VoidCallback onDemo;
  const _ErrorCard({required this.message, required this.onDemo});

  @override
  State<_ErrorCard> createState() => _ErrorCardState();
}

class _ErrorCardState extends State<_ErrorCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: ProxDurations.small)
      ..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final card = Container(
      margin: const EdgeInsets.symmetric(horizontal: 32),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.red.withValues(alpha: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.error_outline, size: 18, color: Colors.red),
              const SizedBox(width: 8),
              Expanded(
                child: Text(widget.message,
                    style: const TextStyle(color: Colors.red)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: widget.onDemo,
            child: const Text('Continue without camera (demo)'),
          ),
        ],
      ),
    );
    if (ProxMotion.reduced(context)) return card;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = _c.value.clamp(0.0, 1.0);
        final dx = t < 1.0 ? (1 - t) * 8 * _sin(t * 3 * 6.28318530718) : 0.0;
        return Transform.translate(
          offset: Offset(dx, 0),
          child: Opacity(opacity: t < 0.25 ? t / 0.25 : 1, child: child),
        );
      },
      child: card,
    );
  }

  double _sin(double x) {
    var n = x % 6.283185307179586;
    if (n > 3.141592653589793) n -= 6.283185307179586;
    if (n < -3.141592653589793) n += 6.283185307179586;
    final x2 = n * n;
    return n * (1 - x2 / 6 + x2 * x2 / 120);
  }
}

/// Timeout card: amber, slides up gently — reads as "retry this scan",
/// distinct from the red error shake above.
class _TimeoutCard extends StatefulWidget {
  final VoidCallback onRetry;
  const _TimeoutCard({required this.onRetry});

  @override
  State<_TimeoutCard> createState() => _TimeoutCardState();
}

class _TimeoutCardState extends State<_TimeoutCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: ProxDurations.medium)
      ..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final card = Container(
      margin: const EdgeInsets.symmetric(horizontal: 32),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.refresh, size: 18, color: Colors.amber),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Could not get a clear scan — try again in better light.',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
            onPressed: widget.onRetry,
          ),
        ],
      ),
    );
    if (ProxMotion.reduced(context)) return card;
    return FadeTransition(
      opacity: CurvedAnimation(parent: _c, curve: ProxCurves.standard),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.3),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _c, curve: ProxCurves.standard)),
        child: card,
      ),
    );
  }
}
