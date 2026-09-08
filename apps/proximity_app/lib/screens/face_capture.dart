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

/// Still-capture seam (navigation plumbing, NOT face math): production
/// pushes [FaceCaptureScreen] (real camera plugin); widget tests override
/// with [FakeStillCapturer] (canned paths — the camera plugin has no test
/// double, and face verdicts come from the driver's FakeFaceVerifier).
abstract class StillCapturer {
  Future<List<String>?> capture(BuildContext context,
      {required int captures, required bool autoFire, String? prompt});
}

class RealStillCapturer implements StillCapturer {
  const RealStillCapturer();
  @override
  Future<List<String>?> capture(BuildContext context,
          {required int captures, required bool autoFire, String? prompt}) =>
      Navigator.of(context).push<List<String>>(MaterialPageRoute(
          builder: (_) => FaceCaptureScreen(
              captures: captures, autoFire: autoFire, prompt: prompt)));
}

/// Test-only: returns [captures] canned paths (or [result] verbatim).
class FakeStillCapturer implements StillCapturer {
  final List<String>? Function(int captures)? result;
  const FakeStillCapturer([this.result]);
  @override
  Future<List<String>?> capture(BuildContext context,
          {required int captures,
          required bool autoFire,
          String? prompt}) async =>
      result?.call(captures) ??
      List.generate(captures, (i) => 'test-still-$i.jpg');
}

final stillCapturerProvider =
    Provider<StillCapturer>((ref) => const RealStillCapturer());

/// Positioning oval drawn OVER the live camera preview (Android-face-
/// unlock-style framing guide). Pure presentation: a dimmed surround +
/// crisp oval border centred on the preview, pointer-transparent so it
/// never intercepts capture taps. Extracted (not inline) so widget tests
/// pump it standalone — the camera plugin has no test double, so the live
/// Stack composition itself is verified on-device; CI asserts this widget
/// renders + repaints on progress.
class FaceCaptureOvalOverlay extends StatelessWidget {
  final double progress; // 0..1 (angle progress inside this capture)

  /// Slow clockwise sweep segment on the rim (radians, east = 0, positive
  /// sweeps clockwise on screen). Null draws NO sweep — the marking-time
  /// default, so the check screen's pixels are unchanged. Guided
  /// enrollment advances it (~one revolution per several seconds, calm);
  /// under reduced motion the session passes a fixed angle with
  /// [sweepSpan] = full circle for a steady full-rim glow instead.
  final double? sweepAngle;

  /// Sweep segment length. Defaults to a short rim segment; full circle
  /// renders the steady reduced-motion glow.
  final double sweepSpan;
  const FaceCaptureOvalOverlay(
      {super.key, this.progress = 0, this.sweepAngle, this.sweepSpan = 1.047});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _OvalOverlayPainter(
          progress: progress,
          color: Theme.of(context).colorScheme.primary,
          sweepAngle: sweepAngle,
          sweepSpan: sweepSpan,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _OvalOverlayPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double? sweepAngle;
  final double sweepSpan;
  _OvalOverlayPainter(
      {required this.progress,
      required this.color,
      this.sweepAngle,
      this.sweepSpan = 1.047});

  @override
  void paint(Canvas canvas, Size size) {
    // Dimmed surround (cheap fill, no blend ops — stays 60fps on low-end).
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0x73000000),
    );
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: size.width * 0.72,
      height: size.height * 0.58,
    );
    // Soft glow behind the crisp ring.
    canvas.drawOval(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10
          ..color = color.withValues(alpha: 0.22)
          ..maskFilter =
              const MaskFilter.blur(BlurStyle.normal, 10));
    // Base ring.
    canvas.drawOval(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.85));
    // Progress arc (guided enrollment: fills per captured angle).
    final p = progress.clamp(0.0, 1.0);
    if (p > 0) {
      canvas.drawArc(
          rect,
          -3.141592653589793 / 2,
          2 * 3.141592653589793 * p,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5
            ..strokeCap = StrokeCap.round
            ..color = color);
    }
    // Rotating sweep (guided enrollment only; null at marking time): a
    // short bright segment travelling clockwise around the rim — the
    // "follow the glow" guide. Round caps, no blur (60fps note holds).
    // Reduced motion passes a full-circle span: steady full-rim glow.
    final sweep = sweepAngle;
    if (sweep != null) {
      canvas.drawArc(
          rect,
          sweep,
          sweepSpan,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 7
            ..strokeCap = StrokeCap.round
            ..color = color);
    }
  }

  @override
  bool shouldRepaint(_OvalOverlayPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.sweepAngle != sweepAngle ||
      old.sweepSpan != sweepSpan;
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
  const FaceCaptureScreen(
      {super.key, this.captures = 1, this.autoFire = true, this.prompt});

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
      final ctl = CameraController(front, ResolutionPreset.medium,
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
      if (widget.autoFire) {
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
      _status = 'Capturing… hold still';
    });
    final paths = <String>[];
    try {
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
      if (!mounted) return;
      Navigator.of(context).pop(paths);
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
      appBar: AppBar(
        title: const Text('Face check'),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
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
                      : Stack(
                          fit: StackFit.expand,
                          children: [
                            CameraPreview(ctl),
                            // The oval ACTUALLY renders on the preview: this
                            // overlay is inside the preview Stack (not beside
                            // it), pointer-transparent, repainting per shot.
                            FaceCaptureOvalOverlay(
                              progress: widget.captures <= 1
                                  ? 1.0
                                  : _taken / widget.captures,
                            ),
                          ],
                        ),
            ),
          ),
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
                  label: Text(widget.captures > 1
                      ? 'Capture ${widget.captures} stills'
                      : 'Capture still'),
                  onPressed: (_busy || ctl == null || _denied || _failed)
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
