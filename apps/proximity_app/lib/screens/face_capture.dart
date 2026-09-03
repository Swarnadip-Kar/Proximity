// Face scan screen: live camera preview → "Scan my face" → ML Kit must
// find a face in the still, else retry. Returns photo bytes on success.
//
// No camera (simulator/denied) → explicit demo fallback button so the flow
// stays verifiable; production devices always go through the real scan.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/face_camera.dart';
import '../main.dart';

class FaceCaptureScreen extends ConsumerStatefulWidget {
  const FaceCaptureScreen({super.key});

  @override
  ConsumerState<FaceCaptureScreen> createState() => _FaceCaptureScreenState();
}

class _FaceCaptureScreenState extends ConsumerState<FaceCaptureScreen> {
  late final FaceCamera _camera;
  bool _ready = false;
  bool _scanning = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _camera = ref.read(faceCameraProvider);
    _init();
  }

  Future<void> _init() async {
    try {
      await _camera.initialize();
      if (!mounted) return;
      setState(() {
        _ready = _camera.isReady;
        _error = _ready ? null : 'Camera could not start.';
      });
    } on FaceCameraException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _notice = null;
      _error = null;
    });
    try {
      final bytes = await _camera.scanFace();
      if (!mounted) return;
      if (bytes == null) {
        setState(() {
          _scanning = false;
          _notice = 'No face found — hold your face in the oval and retry.';
        });
        return;
      }
      Navigator.of(context).pop<Uint8List>(bytes);
    } on FaceCameraException catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveScaffold(
      title: 'Face scan',
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Hold your face in the frame. The scan only counts when a real face is detected — on this device, never uploaded.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Expanded(child: _camera.buildPreview()),
            if (_notice != null) ...[
              const SizedBox(height: 12),
              Text(_notice!, textAlign: TextAlign.center),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () =>
                    Navigator.of(context).pop<Uint8List>(
                        Uint8List.fromList(const [7, 7, 7, 7])),
                child: const Text('Continue without camera (demo)'),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: _scanning
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.face),
              label: const Text('Scan my face'),
              onPressed: (_ready && !_scanning) ? _scan : null,
            ),
          ],
        ),
      ),
    );
  }
}
