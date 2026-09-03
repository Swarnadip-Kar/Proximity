// Face camera facade: live preview + still capture + on-device face
// detection gate (first-party plugin: Vision on iOS, ML Kit on Android).
// A scan only succeeds when a real face is in frame — enrollment can no
// longer complete without one.
//
// Embedding is still a mock until the EdgeFace-XS model file lands
// (TODO P1-face); detection already runs on-device.
// [FakeFaceCamera] drives widget tests and the no-camera fallback.
library;

import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_face_detect/face_detect.dart';

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

  /// Captures a still and returns its bytes only if ML Kit finds ≥1 face.
  /// Returns null when no face is visible. Throws on camera failure.
  Future<Uint8List?> scanFace();
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: CameraPreview(ctl),
    );
  }

  @override
  Future<Uint8List?> scanFace() async {
    final ctl = _ctl;
    if (ctl == null) {
      throw const FaceCameraException('Camera not initialized.');
    }
    try {
      final photo = await ctl.takePicture();
      final faces = await FaceScan.detectFaces(photo.path);
      if (faces == 0) return null;
      return await photo.readAsBytes();
    } catch (e) {
      throw FaceCameraException('Scan failed: $e');
    }
  }

  @override
  void dispose() {
    _ctl?.dispose();
    _ctl = null;
  }
}

/// Test / no-camera fallback: pretends a face is always in frame.
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
  Future<Uint8List?> scanFace() async =>
      Uint8List.fromList(const [7, 7, 7, 7]);

  @override
  void dispose() => _ready = false;
}

final faceCameraProvider = Provider<FaceCamera>((ref) {
  throw UnimplementedError('Override with RealFaceCamera / FakeFaceCamera');
});
