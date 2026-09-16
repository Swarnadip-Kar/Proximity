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
import '../features/setup/enroll_capture_sections.dart'
    show displayedPreviewAspect;
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
abstract class StillCapturer {
  Future<List<String>?> capture(BuildContext context,
      {required int captures,
      required bool autoFire,
      String? prompt,
      Future<bool> Function(List<String> paths)? accept,
      Duration acceptWindow = const Duration(seconds: 10),
      Duration acceptGap = const Duration(seconds: 1)});
}

class RealStillCapturer implements StillCapturer {
  const RealStillCapturer();
  @override
  Future<List<String>?> capture(BuildContext context,
          {required int captures,
          required bool autoFire,
          String? prompt,
          Future<bool> Function(List<String> paths)? accept,
          Duration acceptWindow = const Duration(seconds: 10),
          Duration acceptGap = const Duration(seconds: 1)}) =>
      Navigator.of(context).push<List<String>>(MaterialPageRoute(
          settings: const RouteSettings(name: ProxRoutes.faceCapture),
          builder: (_) => FaceCaptureScreen(
              captures: captures,
              autoFire: autoFire,
              prompt: prompt,
              accept: accept,
              acceptWindow: acceptWindow,
              acceptGap: acceptGap)));
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
          Duration acceptWindow = const Duration(seconds: 10),
          Duration acceptGap = const Duration(seconds: 1)}) async =>
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

  const FaceCaptureOvalOverlay({super.key, this.progress = 0});

  /// Framing oval fractions of the preview size. Same as the shared
  /// enrollment guide ([CaptureOverlay.guideRectForAspect] 0.80w x 0.60h)
  /// so the marking capture frames faces at the identical size —
  /// one face size everywhere, never a bigger oval here.
  static const beaconWidthFraction = 0.80;
  static const beaconHeightFraction = 0.60;

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
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _OvalOverlayPainter extends CustomPainter {
  final double progress;
  final Color color;
  _OvalOverlayPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    // Dimmed surround (cheap fill, no blend ops — stays 60fps on low-end).
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0x73000000),
    );
    final beaconRect = FaceCaptureOvalOverlay.beaconRectFor(size);
    // Soft glow behind the crisp ring (framing rect, neutral — unchanged).
    canvas.drawOval(
        beaconRect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10
          ..color = color.withValues(alpha: 0.22)
          ..maskFilter =
              const MaskFilter.blur(BlurStyle.normal, 10));
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
      old.progress != progress || old.color != color;
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

  /// Total budget for in-preview retries from the first burst.
  final Duration acceptWindow;

  /// Pause between in-preview retry bursts (the holder keeps holding
  /// still; the status line says so).
  final Duration acceptGap;
  const FaceCaptureScreen(
      {super.key,
      this.captures = 1,
      this.autoFire = true,
      this.prompt,
      this.accept,
      this.acceptWindow = const Duration(seconds: 10),
      this.acceptGap = const Duration(seconds: 1)});

  @override
  ConsumerState<FaceCaptureScreen> createState() => _FaceCaptureScreenState();
}

class _FaceCaptureScreenState extends ConsumerState<FaceCaptureScreen> {
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
  /// [_start]/[_captureAll] re-checks it alongside [mounted] so no async
  /// work (takePicture, pop, setState) runs after dispose.
  bool _cancelled = false;

  bool get _done => _cancelled || !mounted;

  @override
  void initState() {
    super.initState();
    if (!canUseFace()) return; // build() shows the blocked card.
    unawaited(_start());
  }

  @override
  void dispose() {
    _cancelled = true;
    unawaited(_ctl?.dispose());
    _ctl = null;
    super.dispose();
  }

  Future<void> _start() async {
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
      final cams = await availableCameras();
      if (_done) return;
      if (cams.isEmpty) throw StateError('No camera found.');
      final front = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cams.first,
      );
      // Max sensor resolution (same contract as enrollment: preset
      // drives preview + stills; layout/overlays untouched).
      final ctl = CameraController(front, ResolutionPreset.max,
          enableAudio: false);
      await ctl.initialize();
      if (_done) {
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
    final deadline =
        accept == null ? null : DateTime.now().add(widget.acceptWindow);
    try {
      while (true) {
        if (_done) return;
        final paths = <String>[];
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
          setState(() => _taken = i + 1);
          if (i + 1 < widget.captures) {
            await Future.delayed(const Duration(milliseconds: 350));
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
      // Mobile edge-to-edge: background bleeds behind the transparent
      // system bars (in-tab route — the shell's _ShellEdgeBody already
      // seats this Scaffold above the nav bar, so no inner SafeArea here
      // which would double-pad). Preview math (AspectRatio + Stack + oval)
      // untouched.
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
          Expanded(
            child: Center(
              child: _denied || _failed
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_status, textAlign: TextAlign.center),
                    )
                  : ctl == null || !ctl.value.isInitialized
                      ? const CircularProgressIndicator()
                    : Center(
                        // Squish fix: the old StackFit.expand forced the
                        // feed to fill the body-minus-panel area (an
                        // arbitrary ratio), stretching faces whenever it
                        // differed from the sensor ratio. Size the box by
                        // the ORIENTATION-ADJUSTED ratio the plugin paints
                        // (see displayedPreviewAspect) so the feed is never
                        // stretched; leftovers become plain background, and
                        // the oval draws on the true video box.
                        child: AspectRatio(
                          aspectRatio:
                              displayedPreviewAspect(ctl.value),
                          child: Stack(
                            children: [
                              CameraPreview(ctl),
                              // The oval ACTUALLY renders on the preview:
                              // this overlay fills the aspect box above
                              // (not beside it), pointer-transparent,
                              // repainting per shot.
                              Positioned.fill(
                                child: FaceCaptureOvalOverlay(
                                  progress: widget.captures <= 1
                                      ? 1.0
                                      : _taken / widget.captures,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
            ),
          // In-tab route: the shell's _ShellEdgeBody already seats this
          // whole Scaffold above the system nav bar (live viewPadding);
          // no inner SafeArea here — it would double-pad. Preview
          // AspectRatio geometry untouched.
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
