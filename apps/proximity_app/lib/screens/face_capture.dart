// FaceCaptureScreen — still-capture shell (Tracks 2+3).
//
// GUTTED per spec: all face math is gone (no BlazeFace/EdgeFace detect,
// no pose gates, no liveness prompts, no score bars). What remains is the
// shell + flow position: front-camera preview → capture N stills to files
// → pop List<String> (image paths) for the FaceVerifier (enrollment takes
// 3: centre/left/right; marking takes 1). Cancel pops null.
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
import '../features/face_identity/face_blocked.dart';

/// Still-capture seam (navigation plumbing, NOT face math): production
/// pushes [FaceCaptureScreen] (real camera plugin); widget tests override
/// with [FakeStillCapturer] (canned paths — the camera plugin has no test
/// double, and face verdicts come from the driver's FakeFaceVerifier).
abstract class StillCapturer {
  Future<List<String>?> capture(BuildContext context,
      {required int captures, required bool autoFire});
}

class RealStillCapturer implements StillCapturer {
  const RealStillCapturer();
  @override
  Future<List<String>?> capture(BuildContext context,
          {required int captures, required bool autoFire}) =>
      Navigator.of(context).push<List<String>>(MaterialPageRoute(
          builder: (_) =>
              FaceCaptureScreen(captures: captures, autoFire: autoFire)));
}

/// Test-only: returns [captures] canned paths (or [result] verbatim).
class FakeStillCapturer implements StillCapturer {
  final List<String>? Function(int captures)? result;
  const FakeStillCapturer([this.result]);
  @override
  Future<List<String>?> capture(BuildContext context,
          {required int captures, required bool autoFire}) async =>
      result?.call(captures) ??
      List.generate(captures, (i) => 'test-still-$i.jpg');
}

final stillCapturerProvider =
    Provider<StillCapturer>((ref) => const RealStillCapturer());

/// Still-capture sheet. Pops `List<String>` (captured image paths, oldest
/// first) or null on cancel/close. [captures]: 3 for enrollment, 1 for
/// marking. [autoFire]: capture automatically once the preview is ready
/// (marking seamless unlock); false shows the button only (enrollment).
class FaceCaptureScreen extends ConsumerStatefulWidget {
  final int captures;
  final bool autoFire;
  const FaceCaptureScreen({super.key, this.captures = 1, this.autoFire = true});

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

  @override
  void initState() {
    super.initState();
    if (!canUseFace()) return; // build() shows the blocked card.
    unawaited(_start());
  }

  @override
  void dispose() {
    unawaited(_ctl?.dispose());
    super.dispose();
  }

  Future<void> _start() async {
    final perm = await Permission.camera.request();
    if (!mounted) return;
    if (!perm.isGranted) {
      setState(() {
        _denied = true;
        _status = 'Camera permission is needed for the face check.';
      });
      return;
    }
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw StateError('No camera found.');
      final front = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cams.first,
      );
      final ctl = CameraController(front, ResolutionPreset.medium,
          enableAudio: false);
      await ctl.initialize();
      if (!mounted) {
        await ctl.dispose();
        return;
      }
      setState(() {
        _ctl = ctl;
        _status = 'Ready';
      });
      if (widget.autoFire) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (mounted) await _captureAll();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _status = 'Camera unavailable: $e';
      });
    }
  }

  Future<void> _captureAll() async {
    final ctl = _ctl;
    if (_busy || ctl == null || !mounted) return;
    setState(() {
      _busy = true;
      _status = 'Capturing… hold still';
    });
    final paths = <String>[];
    try {
      for (var i = 0; i < widget.captures; i++) {
        if (!mounted) return;
        final shot = await ctl.takePicture();
        paths.add(shot.path);
        if (!mounted) return;
        setState(() => _taken = i + 1);
        if (i + 1 < widget.captures) {
          await Future.delayed(const Duration(milliseconds: 350));
        }
      }
      if (!mounted) return;
      Navigator.of(context).pop(paths);
    } catch (e) {
      if (!mounted) return;
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
                      : CameraPreview(ctl),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
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
