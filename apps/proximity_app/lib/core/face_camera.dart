// Face camera facade: live preview + still capture. Face detection runs
// in Dart (BlazeFace short-range TFLite, see core/face_detect.dart), so the
// camera only ever returns raw stills — a capture succeeds whenever the
// shutter does. A capture only counts downstream when BlazeFace finds a
// readable, well-posed face in it.
// [FakeFaceCamera] drives widget tests and the no-camera fallback.
library;

import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import 'face_detect.dart';

class FaceCameraException implements Exception {
  final String message;
  const FaceCameraException(this.message);
  @override
  String toString() => 'FaceCameraException: $message';
}

abstract class FaceCamera {
  /// Opens the front camera. Throws [FaceCameraException] when unavailable
  /// (simulator, denied permission, no hardware).
  Future<void> initialize();
  bool get isReady;

  /// Live preview widget (or a placeholder when not ready).
  Widget buildPreview();

  /// Captures a raw still and returns its bytes. Detection, quality gates
  /// and alignment happen downstream in Dart (BlazeFace). Throws on camera
  /// failure.
  Future<Uint8List?> captureStill();
  void dispose();
}

class RealFaceCamera implements FaceCamera {
  CameraController? _ctl;

  @override
  bool get isReady => _ctl?.value.isInitialized ?? false;

  @override
  Future<void> initialize() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw const FaceCameraException('No camera found on this device.');
      }
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      _ctl = CameraController(front, ResolutionPreset.medium,
          enableAudio: false);
      await _ctl!.initialize();
    } on FaceCameraException {
      rethrow;
    } catch (e) {
      throw FaceCameraException('Camera unavailable: $e');
    }
  }

  @override
  Widget buildPreview() {
    final ctl = _ctl;
    if (ctl == null || !ctl.value.isInitialized) {
      return const Center(child: Icon(Icons.face, size: 96));
    }
    // Stock pixels, correct ratio: Center passes LOOSE constraints so the
    // preview takes its natural size instead of stretching to the window
    // (tight constraints squash it). The thin oval rides INSIDE the
    // preview (CameraPreview.child) so the marker always matches the
    // picture, never the window — outline only, no dimming or glow.
    return Center(
      child: CameraPreview(
        ctl,
        child: const IgnorePointer(child: _OvalMarker()),
      ),
    );
  }

  @override
  Future<Uint8List?> captureStill() async {
    final ctl = _ctl;
    if (ctl == null) {
      throw const FaceCameraException('Camera not initialized.');
    }
    try {
      final photo = await ctl.takePicture();
      return await photo.readAsBytes();
    } catch (e) {
      throw FaceCameraException('Capture failed: $e');
    }
  }

  @override
  void dispose() {
    _ctl?.dispose();
    _ctl = null;
  }
}

/// Test / no-camera fallback: simulates a cooperative still user.
/// Frames are textured (4px checker ±18 around mid-grey: mean ~128 so the
/// lighting gate passes, sharpness gate passes). Deterministic.
/// Test-only, never production.
class FakeFaceCamera implements FaceCamera {
  bool _ready = false;
  @override
  bool get isReady => _ready;

  @override
  Future<void> initialize() async => _ready = true;

  @override
  Widget buildPreview() => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.face, size: 96),
            SizedBox(height: 8),
            Text('Demo preview (no camera)'),
          ],
        ),
      );

  @override
  Future<Uint8List?> captureStill() async {
    final frame = img.Image(width: 96, height: 96);
    for (var y = 0; y < 96; y++) {
      for (var x = 0; x < 96; x++) {
        final v = 128 + (((x ~/ 4) + (y ~/ 4)) % 2 == 0 ? 18 : -18);
        frame.setPixel(x, y, img.ColorRgb8(v, v, v));
      }
    }
    return Uint8List.fromList(img.encodeJpg(frame));
  }

  @override
  void dispose() => _ready = false;
}

/// Mean frame luminance 0..255 of a JPEG still, or null when undecodable.
/// Powers the on-device lighting prompt ("too dark / too bright, retry").
/// Strided sampling keeps this to a few ms even on multi-MP stills.
double? estimateBrightness(List<int> bytes) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(Uint8List.fromList(bytes));
  } catch (_) {
    return null;
  }
  if (decoded == null || decoded.width == 0 || decoded.height == 0) {
    return null;
  }
  final stride =
      ((decoded.width * decoded.height) / 8000).ceil().clamp(1, 64);
  var sum = 0.0;
  var n = 0;
  for (var y = 0; y < decoded.height; y += stride) {
    for (var x = 0; x < decoded.width; x += stride) {
      final p = decoded.getPixel(x, y);
      sum += 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      n++;
    }
  }
  return n == 0 ? null : sum / n;
}

/// Lighting-gate starting points (tune per pilot hall lighting).
const kDarkFrameLuma = 50.0;
const kBrightFrameLuma = 205.0;

/// Live-frame verdict from one analyzed still. Only [good] frames advance
/// the capture streak; everything else only steers on-screen guidance —
/// it never consumes a retry attempt.
enum FrameQuality { noFace, badPose, tooDark, tooBright, tooBlurry, unclear, good }

/// Pure per-frame classifier: face-detector count, geometric sanity,
/// mean frame luminance, motion sharpness (null sharpness = not assessed,
/// e.g. unit tests — never a reject on its own).
FrameQuality analyzeFrame(
    {required int faces,
    required double? luma,
    bool sane = true,
    double? sharpness}) {
  if (faces <= 0) return FrameQuality.noFace;
  if (!sane) return FrameQuality.badPose;
  if (luma == null) return FrameQuality.unclear;
  if (luma < kDarkFrameLuma) return FrameQuality.tooDark;
  if (luma > kBrightFrameLuma) return FrameQuality.tooBright;
  if (sharpness != null && sharpness < kMinSharpness) {
    return FrameQuality.tooBlurry;
  }
  return FrameQuality.good;
}

/// One-line user guidance per frame verdict.
String frameGuidance(FrameQuality q) {
  switch (q) {
    case FrameQuality.noFace:
      return 'No face yet — fill the screen with your face.';
    case FrameQuality.badPose:
      return 'Face the camera straight on — no sharp angles.';
    case FrameQuality.tooDark:
      return 'Too dark — face a light source.';
    case FrameQuality.tooBright:
      return 'Too bright — move out of harsh direct light.';
    case FrameQuality.tooBlurry:
      return 'Too blurry — brace the phone and hold exactly still.';
    case FrameQuality.unclear:
      return 'Hold still — reading the camera…';
    case FrameQuality.good:
      return 'Good — hold still…';
  }
}

/// Thin oval framing marker drawn over the live preview: outline only —
/// no dimming, no glow, no filtering of the picture itself. Lives inside
/// [CameraPreview] so it always matches the photo, not the window.
class _OvalMarker extends StatelessWidget {
  const _OvalMarker();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _OvalMarkerPainter(
        color: Colors.white.withValues(alpha: 0.75),
      ),
    );
  }
}

class _OvalMarkerPainter extends CustomPainter {
  final Color color;
  _OvalMarkerPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: size.width * 0.72,
      height: size.height * 0.62,
    );
    canvas.drawOval(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_OvalMarkerPainter old) => old.color != color;
}

final faceCameraProvider = Provider<FaceCamera>((ref) {  throw UnimplementedError('Override with RealFaceCamera / FakeFaceCamera');
});
