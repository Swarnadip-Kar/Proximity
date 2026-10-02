// FaceCaptureScreen — still-capture shell (Tracks 2+3).
//
// GUTTED per spec: all face math is gone (no BlazeFace/EdgeFace detect,
// no pose gates, no liveness prompts, no score bars). What remains is the
// shell + flow position: front-camera preview (with a positioning oval
// overlay) → capture N stills to files → pop List<String> (image paths)
// for the FaceVerifier (enrollment takes 1 per guided angle, marking takes
// 1). Cancel pops null.
//
// Mobile-only (L2): records-only devices see the blocked card, never a
// camera. Capture cadence: one tap (or the auto-fire on open) grabs the
// stills ~350ms apart; no per-frame verdicts — match/mismatch/
// inconclusive come back from the driver's single verify call, which
// burns attempts per the 12s-session policy (one dead session = one
// attempt, never one frame).
library;

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/platformx.dart';
import '../design/tokens.dart';
import '../features/face_identity/face_blocked.dart';
import '../features/face_identity/face_verifier.dart';
import '../features/face_identity/liveness_gate.dart';
import '../features/setup/enroll_capture_sections.dart'
    show displayedPreviewAspect;
import '../features/setup/flash_assist.dart';
import '../routes.dart';

/// Still-capture seam (navigation plumbing, NOT face math): production
/// pushes [FaceCaptureScreen] (real camera plugin); widget tests override
/// with [FakeStillCapturer] (canned paths — the camera plugin has no test
/// double, and face verdicts come from the driver's FakeFaceVerifier).
///
/// In-preview retry (marking auto-retry stays on the SAME preview): when
/// [accept] is provided, the sheet captures one burst, asks `accept(paths)`
/// whether to keep it, and — on false — re-captures with the SAME camera
/// controller inside [acceptWindow] ([acceptGap] between bursts) instead of
/// popping and re-pushing the sheet. True pops with the burst; a spent
/// window pops with the last burst so the caller resolves it terminally.
/// Null [accept] keeps the legacy single-burst pop. Failures of `accept`
/// itself accept (pop) — verification errors must never trap the sheet.
///
/// [assist] (dark retry only): paints the flash-assist edge ring and maxes
/// the window brightness while the sheet is up (restored after) — the
/// host sets it when the previous verdict read dim, so the retry captures
/// lit instead of spinning dark again. Default off: bright sessions never
/// touch brightness.
///
/// [liveReadout] (marking live line): a host-owned notifier the sheet
/// renders under the prompt (`LIVE <score>/<bar> Brightness: <n>`, same
/// shape as the enrollment bottom-bar line). The host updates it from its
/// per-still verdicts; the sheet only listens, never writes or disposes.
/// Null hides the line (legacy callers render exactly as before).
abstract class StillCapturer {
  Future<List<String>?> capture(BuildContext context,
      {required int captures,
      required bool autoFire,
      String? prompt,
      Future<bool> Function(List<String> paths)? accept,
      Future<bool> Function(String path)? acceptStill,
      Duration acceptWindow = const Duration(seconds: 10),
      Duration acceptGap = const Duration(seconds: 1),
      bool assist = false,
      ValueNotifier<String>? liveReadout});
}

class RealStillCapturer implements StillCapturer {
  const RealStillCapturer();
  @override
  Future<List<String>?> capture(BuildContext context,
          {required int captures,
          required bool autoFire,
          String? prompt,
          Future<bool> Function(List<String> paths)? accept,
          Future<bool> Function(String path)? acceptStill,
          Duration acceptWindow = const Duration(seconds: 10),
          Duration acceptGap = const Duration(seconds: 1),
          bool assist = false,
          ValueNotifier<String>? liveReadout}) =>
      Navigator.of(context).push<List<String>>(MaterialPageRoute(
          settings: const RouteSettings(name: ProxRoutes.faceCapture),
          builder: (_) => FaceCaptureScreen(
              captures: captures,
              autoFire: autoFire,
              prompt: prompt,
              accept: accept,
              acceptStill: acceptStill,
              acceptWindow: acceptWindow,
              acceptGap: acceptGap,
              assist: assist,
              liveReadout: liveReadout)));
}

/// Test-only: returns [captures] canned paths (or [result] verbatim).
/// In-preview retry params are accepted for signature compat and ignored:
/// the canned burst resolves immediately, so callers fall back to their
/// legacy single-verify path.
class FakeStillCapturer implements StillCapturer {
  final List<String>? Function(int captures)? result;
  const FakeStillCapturer([this.result]);
  @override
  Future<List<String>?> capture(BuildContext context,
          {required int captures,
          required bool autoFire,
          String? prompt,
          Future<bool> Function(List<String> paths)? accept,
          Future<bool> Function(String path)? acceptStill,
          Duration acceptWindow = const Duration(seconds: 10),
          Duration acceptGap = const Duration(seconds: 1),
          bool assist = false,
          ValueNotifier<String>? liveReadout}) async =>
      result?.call(captures) ??
      List.generate(captures, (i) => 'test-still-$i.jpg');
}

final stillCapturerProvider =
    Provider<StillCapturer>((ref) => const RealStillCapturer());

/// Positioning oval drawn OVER the live camera preview (Android-face-
/// unlock-style framing guide) on the marking still-capture sheet. Pure
/// presentation: a dimmed surround + crisp oval border centred on the
/// preview, pointer-transparent so it never intercepts capture taps.
/// Marking-only: the guided-enrollment beacon/progress-oval branches were
/// dead here (no caller ever passed a sweep angle — enrollment uses
/// [CaptureOverlay]) and are removed. Extracted (not inline) so widget
/// tests pump it standalone — the camera plugin has no test double, so the
/// live Stack composition itself is verified on-device; CI asserts this
/// widget renders + repaints on progress.
class FaceCaptureOvalOverlay extends StatelessWidget {
  /// Shots taken / shots requested (0..1). Paints a theme-primary arc over
  /// the framing ring. Pure display — capture never gates on it.
  final double progress;

  /// Flash-assist edge ring (dark retry only — default off): two bright
  /// oval strokes hugging the preview edges, painted above the dim
  /// surround for uniform light. Ovals only (never a rounded rect — see
  /// the oval-landing source pin); static, no animation (settle-safe).
  final bool assist;

  const FaceCaptureOvalOverlay({super.key, this.progress = 0, this.assist = false});

  /// Framing oval fractions of the preview size. Same as the shared
  /// enrollment guide ([CaptureOverlay.guideRectForAspect] 0.60w x 0.55h)
  /// so the marking capture frames faces at the identical size —
  /// one face size everywhere, never a bigger oval here.
  static const beaconWidthFraction = 0.60;
  static const beaconHeightFraction = 0.55;

  /// Face width/height for the portrait clamp below (human-face
  /// proportion — width < height). Phone portrait previews already satisfy
  /// w < h so their pixels are byte-identical; wide/desktop boxes would
  /// otherwise compute w >= h and are narrowed to h * this ratio.
  static const faceWidthToHeight = 0.75;

  /// Framing rect. True oval via `drawOval` (never a rounded rect),
  /// taller than wide on every viewport (portrait clamp — see
  /// [faceWidthToHeight]). Paint-only geometry: preview sizing, capture
  /// logic, and thresholds below are untouched; static shape, no new
  /// animation (settle-safe).
  static Rect beaconRectFor(Size size) {
    var w = size.width * beaconWidthFraction;
    final h = size.height * beaconHeightFraction;
    if (w >= h) w = h * faceWidthToHeight;
    return Rect.fromCenter(
      center: size.center(Offset.zero),
      width: w,
      height: h,
    );
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _OvalOverlayPainter(
          progress: progress,
          color: Theme.of(context).colorScheme.primary,
          assist: assist,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _OvalOverlayPainter extends CustomPainter {
  final double progress;
  final Color color;
  final bool assist;
  _OvalOverlayPainter(
      {required this.progress, required this.color, this.assist = false});

  @override
  void paint(Canvas canvas, Size size) {
    // Dimmed surround (cheap fill, no blend ops — stays 60fps on low-end).
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0x73000000),
    );
    // Flash-assist edge ring first (directly above the surround, uniform
    // light): flat bands, no blur — the feed stays raw, the wide faint
    // band under the bright core reads as glow without any effect.
    if (assist) {
      // Contained edge ring (see CaptureOverlay.flashRingRRectFor): the
      // deflate clears the glow bleed top and bottom so the ring never
      // touches the prompt line or the button panel.
      final edge = (Offset.zero & size).deflate(34);
      canvas.drawOval(
          edge,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 60
            ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.35));
      canvas.drawOval(
          edge,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 28
            ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.95));
    }
    final beaconRect = FaceCaptureOvalOverlay.beaconRectFor(size);
    // Flat halo behind the crisp ring (framing rect, neutral — unchanged).
    canvas.drawOval(
        beaconRect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10
          ..color = color.withValues(alpha: 0.22));
    // Base ring (framing guide, neutral white — unchanged).
    canvas.drawOval(
        beaconRect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.85));
    // Progress arc over the framing ring (theme-primary, same rect).
    final p = progress.clamp(0.0, 1.0);
    if (p > 0) {
      canvas.drawArc(
          beaconRect,
          -3.141592653589793 / 2,
          2 * 3.141592653589793 * p,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5
            ..strokeCap = StrokeCap.round
            ..color = color);
    }
  }

  @override
  bool shouldRepaint(_OvalOverlayPainter old) =>
      old.progress != progress || old.color != color || old.assist != assist;
}

/// Orientation-adjusted sensor ratio for the cover box below (same
/// helper the enrollment feed sizes itself with — see
/// [displayedPreviewAspect]): null when unmeasurable (proven fallback
/// path, never a garbage box).
double? _coverAspect(CameraValue value) {
  try {
    final a = displayedPreviewAspect(value);
    if (a.isFinite && a > 0) return a;
  } catch (_) {}
  return null;
}

/// Full-bleed camera surface (same math as the enrollment feed):
/// explicit cover box, zero transforms. The inner box matches the
/// native frame ratio (no squish); [OverflowBox] centers it over the
/// area and [ClipRect] crops the bleed. The texture paints
/// untransformed — only larger. Null ratio (should not happen — the
/// build gate above requires initialized) renders the proven bare
/// preview instead of a garbage box.
class _CoverFeed extends StatelessWidget {
  final double? aspectRatio;
  final Widget child;
  const _CoverFeed({required this.aspectRatio, required this.child});

  @override
  Widget build(BuildContext context) {
    final ar = aspectRatio;
    if (ar == null) return child;
    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest;
      // Unbounded (should not happen — the feed fills the Expanded):
      // proven bare path, never a garbage box.
      if (!size.isFinite) return child;
      var w = size.width;
      var h = w / ar;
      if (h < size.height) {
        h = size.height;
        w = h * ar;
      }
      return ClipRect(
        child: SizedBox.fromSize(
          size: size,
          child: OverflowBox(
            maxWidth: w,
            maxHeight: h,
            child: SizedBox(width: w, height: h, child: child),
          ),
        ),
      );
    });
  }
}

/// Still-capture sheet. Pops `List<String>` (captured image paths, oldest
/// first) or null on cancel/close. [captures]: 1 per guided enrollment
/// angle, 1 for marking. [autoFire]: capture automatically once the preview
/// is ready (marking seamless unlock); false shows the button only
/// (enrollment). [prompt]: per-angle instruction shown under the preview
/// (guided enrollment); marking uses the default face-in-oval copy.
class FaceCaptureScreen extends ConsumerStatefulWidget {
  final int captures;
  final bool autoFire;
  final String? prompt;

  /// In-preview retry verdict (see [StillCapturer]): true pops with the
  /// burst, false re-captures on the SAME preview inside [acceptWindow].
  /// Null keeps the legacy single-burst pop.
  final Future<bool> Function(List<String> paths)? accept;

  /// Per-still early exit (optional): after each capture the sheet scores
  /// the still WITHOUT awaiting (overlapping the next capture) and settles
  /// the previous still's verdict first — at most one scoring call is ever
  /// in flight (the serial plugin gate). True pops immediately with the
  /// paths so far; false keeps capturing to the burst budget, where the
  /// whole-burst [accept] resolves terminally as before. Null disables
  /// (legacy burst-then-verify). Scoring errors never pop and never trap:
  /// they read as "keep capturing".
  final Future<bool> Function(String path)? acceptStill;

  /// Total budget for in-preview retries from the first burst.
  final Duration acceptWindow;

  /// Pause between in-preview retry bursts (the holder keeps holding
  /// still; the status line says so).
  final Duration acceptGap;

  /// Flash assist for a dark retry (see [StillCapturer.assist]): ring
  /// light + maxed window brightness while up, restored after. The host
  /// sets it when the previous verdict read dim. Default off.
  final bool assist;

  /// Marking live line (see [StillCapturer.liveReadout]): host-owned,
  /// sheet only listens. Null hides the line.
  final ValueNotifier<String>? liveReadout;
  const FaceCaptureScreen(
      {super.key,
      this.captures = 1,
      this.autoFire = true,
      this.prompt,
      this.accept,
      this.acceptStill,
      this.acceptWindow = const Duration(seconds: 10),
      this.acceptGap = const Duration(seconds: 1),
      this.assist = false,
      this.liveReadout});

  @override
  ConsumerState<FaceCaptureScreen> createState() => _FaceCaptureScreenState();
}

class _FaceCaptureScreenState extends ConsumerState<FaceCaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _ctl;
  String _status = 'Starting camera…';
  bool _busy = false;
  int _taken = 0;
  bool _denied = false;
  bool _failed = false;
  // Single-flight for the auto-fire scan: the 500ms delayed auto-fire in
  // [_start] fires at most once per mount, so a manual tap racing the delay
  // can never stack a second capture sequence on top of it ([_busy] in
  // [_captureAll] owns the manual/auto mutual exclusion once firing).
  bool _autoFired = false;
  /// Dispose latch: set synchronously in dispose; every await in
  // [_start]/[_captureAll] re-checks it alongside [mounted] so no async
  // work (takePicture, pop, setState) runs after dispose.
  bool _cancelled = false;

  bool get _done => _cancelled || !mounted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Keyboard-first entry (manual Scan after typing elsewhere): drop any
    // open keyboard before the camera opens, or the resize squishes the
    // preview. Backed by resizeToAvoidBottomInset:false below (no editable
    // text lives on this sheet).
    FocusManager.instance.primaryFocus?.unfocus();
    if (!canUseFace()) return; // build() shows the blocked card.
    unawaited(_start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cancelled || !mounted) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      // Park the preview while backgrounded (a live controller keeps the
      // sensor locked and the OS may kill the surface anyway). setState so
      // build() drops the preview instead of holding a disposed handle.
      final ctl = _ctl;
      _ctl = null;
      if (ctl != null) {
        setState(() => _status = 'Paused — returning…');
        unawaited(ctl.dispose());
      }
    } else if (state == AppLifecycleState.resumed) {
      // The pause path above always nulls _ctl, so a null controller here
      // means "needs restart" — the old guard (return when _ctl == null)
      // could never reach this branch and reopening stranded on black.
      if (_ctl == null) {
        unawaited(_start());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelled = true;
    unawaited(_ctl?.dispose());
    _ctl = null;
    super.dispose();
  }

  bool _starting = false;

  /// Explicit retry for a failed start (the failed branch owns its own
  /// Try-again — the bottom Capture button stays disabled with no
  /// controller, so without this the sheet stranded on black). Re-arms
  /// the open from scratch, including the auto-fire when configured.
  void _retryStart() {
    if (_starting || _done) return;
    setState(() {
      _failed = false;
      _denied = false;
      _status = 'Starting camera…';
      if (widget.autoFire) _autoFired = false;
    });
    unawaited(_start());
  }

  Future<void> _start() async {
    // Single-flight: initState + a rapid pause/resume pair (or double
    // resume) must never build two controllers — the loser leaks the
    // sensor lock and the preview attaches to a disposed handle (black).
    if (_starting) return;
    _starting = true;
    try {
      await _startInner();
    } finally {
      _starting = false;
    }
  }

  Future<void> _startInner() async {
    // Prewarm the face + liveness models while the permission sheet,
    // camera init, and holder positioning run (idempotent singleton
    // loads; failures retry on first use — never throws out of open).
    unawaited(Future(() async {
      try {
        await ref.read(faceVerifierProvider).init();
      } catch (_) {}
      try {
        HeuristicLivenessGate.prewarm();
      } catch (_) {}
    }));
    final perm = await Permission.camera.request();
    if (_done) return;
    if (!perm.isGranted) {
      setState(() {
        _denied = true;
        _status = 'Camera permission is needed for the face check.';
      });
      return;
    }
    try {
      // Bounded camera list: a hung plugin call used to strand the sheet
      // on the spinner forever (white page). Past the budget it throws
      // into the failed branch below, where Try-again re-runs the open.
      // Side-effect-free (no controller yet), so timing out is safe —
      // initialize() below stays unbounded (a timeout there could orphan
      // a live controller holding the sensor lock).
      final cams =
          await availableCameras().timeout(const Duration(seconds: 15));
      if (_done) return;
      if (cams.isEmpty) throw StateError('No camera found.');
      final front = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cams.first,
      );
      // Medium resolution: the preset drives BOTH preview + stills.
      // Max (8-12MP on old phones) stalled takePicture/decode/ML Kit and
      // OOMed low-RAM devices for zero matcher gain (FaceNet embeds at
      // ~160px). Layout/overlays untouched.
      final ctl = CameraController(front, ResolutionPreset.medium,
          enableAudio: false);
      await ctl.initialize();
      if (_done) {
        await ctl.dispose();
        return;
      }
      // Initialized while backgrounded (pause raced init): the surface is
      // gone — drop it so resume restarts clean instead of showing black.
      if (WidgetsBinding.instance.lifecycleState !=
          AppLifecycleState.resumed) {
        await ctl.dispose();
        return;
      }
      setState(() {
        _ctl = ctl;
        _status = 'Ready';
      });
      if (widget.autoFire && !_autoFired) {
        _autoFired = true;
        await Future.delayed(const Duration(milliseconds: 500));
        if (_done) return;
        await _captureAll();
      }
    } catch (e) {
      if (_done) return;
      setState(() {
        _failed = true;
        _status = 'Camera unavailable: $e';
      });
    }
  }

  Future<void> _captureAll() async {
    final ctl = _ctl;
    if (_busy || ctl == null || _done) return;
    setState(() {
      _busy = true;
      // A transient takePicture error set _failed and disabled this very
      // button — a new capture must re-arm it, or the sheet strands on
      // `Capture failed` with no way forward except Cancel.
      _failed = false;
      _status = 'Capturing… hold still';
    });
    // In-preview retry loop: every burst reuses the SAME controller (the
    // preview never tears down), so holder auto-retries never flash the
    // camera. Legacy single-burst callers (accept == null) pop at once.
    final accept = widget.accept;
    final acceptStill = widget.acceptStill;
    final deadline =
        accept == null ? null : DateTime.now().add(widget.acceptWindow);
    try {
      while (true) {
        if (_done) return;
        final paths = <String>[];
        // In-flight per-still verdict (see [FaceCaptureScreen.acceptStill]:
        // at most one scoring call runs at a time — the serial plugin
        // gate — while the next capture overlaps it).
        Future<bool>? scoring;
        for (var i = 0; i < widget.captures; i++) {
          if (_done) return;
          final shot = await ctl.takePicture();
          if (_done) return;
          // Blank-frame guard: a capture that produced no path never leaves
          // this screen (the plugin crashes on empty bytes below its catch).
          if (shot.path.trim().isEmpty) {
            throw StateError('Capture produced no image — try again.');
          }
          paths.add(shot.path);
          if (_done) return;
          // Settle the previous still first (serial scoring gate), then
          // score this still while the next capture runs. A settled pass
          // pops immediately with the paths so far — the common genuine
          // case leaves after 1–2 stills instead of the whole burst.
          if (scoring != null) {
            var done = false;
            try {
              done = await scoring;
            } catch (_) {}
            scoring = null;
            if (_done) return;
            if (done) {
              if (!mounted) return;
              Navigator.of(context).pop(paths);
              return;
            }
          }
          if (acceptStill != null) {
            final path = shot.path;
            scoring = acceptStill(path);
          }
          setState(() => _taken = i + 1);
          if (i + 1 < widget.captures) {
            await Future.delayed(const Duration(milliseconds: 350));
          }
        }
        if (_done) return;
        // Drain the last still's verdict before the whole-burst accept.
        if (scoring != null) {
          var done = false;
          try {
            done = await scoring;
          } catch (_) {}
          scoring = null;
          if (_done) return;
          if (done) {
            if (!mounted) return;
            Navigator.of(context).pop(paths);
            return;
          }
        }
        if (_done) return;
        if (accept == null) {
          if (!mounted) return;
          Navigator.of(context).pop(paths);
          return;
        }
        if (!mounted) return;
        setState(() => _status = 'Checking… hold still');
        bool accepted = true;
        try {
          accepted = await accept(paths);
        } catch (_) {
          // Verification errors accept (pop): a throwing verifier must
          // never trap the sheet in a retry loop.
          accepted = true;
        }
        if (_done) return;
        if (accepted) {
          if (!mounted) return;
          Navigator.of(context).pop(paths);
          return;
        }
        // Rejected burst: spent window pops with the last burst (the
        // caller resolves it terminally); otherwise the SAME preview
        // re-captures after the gap — never a pop/re-push flash.
        if (deadline == null || !DateTime.now().isBefore(deadline)) {
          if (!mounted) return;
          Navigator.of(context).pop(paths);
          return;
        }
        if (_done) return;
        setState(() {
          _taken = 0;
          _status = 'Scan unclear — hold still, retrying automatically…';
        });
        await Future.delayed(widget.acceptGap);
      }
    } catch (e) {
      if (_done) return;
      setState(() {
        _busy = false;
        _failed = true;
        _status = 'Capture failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // L1 assert: records-only devices never reach the camera.
    if (!canUseFace()) {
      return Scaffold(
        appBar: AppBar(title: const Text('Face check')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              const FaceBlockedCard(flow: 'Face check'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Back'),
              ),
            ],
          ),
        ),
      );
    }
    final ctl = _ctl;
    final prompt = widget.prompt ?? 'Position your face in the oval';
    return Scaffold(
      // No editable text lives on this sheet: the keyboard must never
      // resize/squish the preview (entry unfocuses in initState too).
      resizeToAvoidBottomInset: false,
      // Camera-black chrome: the preview COVERS its area (no letterbox
      // bars) and every non-preview state (spinner, denied, failed)
      // renders on black, so a slow bind never reads as a white page
      // and side gaps can never show white borders. The bottom action
      // panel keeps the themed surface (prompt + capture stay readable).
      backgroundColor: Colors.black,
      // Mobile edge-to-edge: background bleeds behind the transparent
      // system bars (in-tab route — the shell's _ShellEdgeBody already
      // seats this Scaffold above the nav bar, so no inner SafeArea here
      // which would double-pad).
      extendBody: isMobile,
      appBar: AppBar(
        title: const Text('Face check'),
        actions: [
          // Cancel stays live through the in-preview auto-retry loop:
          // every await in _captureAll re-checks the dispose latch, so a
          // mid-retry pop never double-pops or verifies afterwards. A
          // disabled Cancel during the 7s window read as a stuck screen.
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
      body: Column(
        children: [
          // Brightness shell for a flash-assisted retry: maxes the window
          // while up, restores after (renders nothing itself).
          FlashAssistSync(
            active: widget.assist,
            control: ref.read(enrollScreenBrightnessProvider),
          ),
          Expanded(
            child: Container(
              color: Colors.black,
              child: _denied || _failed
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _status,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white),
                            ),
                            // A failed start used to dead-end here (the
                            // Capture button below stays disabled with no
                            // controller): an explicit retry re-runs the
                            // open instead of stranding on black.
                            if (_failed && !_denied) ...[
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                icon: const Icon(Icons.refresh),
                                label: const Text('Try again'),
                                onPressed: _starting ? null : _retryStart,
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  : ctl == null || !ctl.value.isInitialized
                      ? const Center(child: CircularProgressIndicator())
                      : Stack(
                          children: [
                            // Full-bleed cover (same contract as the
                            // enrollment feed): the sensor frame COVERS the
                            // area center-cropped at a uniform scale — never
                            // squished, no letterbox bars, no white edges.
                            // The oval draws on the visible area above it.
                            Positioned.fill(
                              child: _CoverFeed(
                                aspectRatio:
                                    _coverAspect(ctl.value),
                                child: CameraPreview(ctl),
                              ),
                            ),
                            Positioned.fill(
                              child: FaceCaptureOvalOverlay(
                                progress: widget.captures <= 1
                                    ? 1.0
                                    : _taken / widget.captures,
                                assist: widget.assist,
                              ),
                            ),
                          ],
                        ),
            ),
          ),
          // In-tab route: the shell's _ShellEdgeBody already seats this
          // whole Scaffold above the system nav bar (live viewPadding);
          // no inner SafeArea here — it would double-pad. The bottom
          // panel keeps the themed surface; only the preview area above
          // is camera-black.
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  prompt,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: ProxSpacing.xs),
                Text(
                  _busy
                      ? 'Captured $_taken of ${widget.captures}… hold still'
                      : _status,
                ),
                // Marking live line (see [StillCapturer.liveReadout]):
                // host-owned notifier, rendered even while empty so the
                // first update never moves the panel.
                if (widget.liveReadout != null) ...[
                  const SizedBox(height: ProxSpacing.xs),
                  ValueListenableBuilder<String>(
                    valueListenable: widget.liveReadout!,
                    builder: (_, line, __) => Text(
                      line,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.color
                                ?.withValues(alpha: 0.75),
                          ),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                FilledButton.icon(
                  icon: const Icon(Icons.face),
                  // _failed no longer disables: it labels the retry (a
                  // failed capture re-arms inside _captureAll). Only a
                  // denied permission or a missing controller blocks.
                  label: Text(_failed
                      ? 'Try again'
                      : widget.captures > 1
                          ? 'Capture ${widget.captures} stills'
                          : 'Capture still'),
                  onPressed: (_busy || ctl == null || _denied)
                      ? null
                      : _captureAll,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
