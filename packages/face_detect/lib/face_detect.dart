// First-party face-presence detection channel.
// iOS/macOS: Apple Vision VNDetectFaceRectangles (system, on-device).
// Android: ML Kit face detection (on-device, Play-services-free base SDK).
// Returns the number of faces found in the still at [imagePath].
import 'package:flutter/services.dart';

class FaceScan {
  static const MethodChannel _channel =
      MethodChannel('proximity_face_detect');

  static Future<int> detectFaces(String imagePath) async {
    final n =
        await _channel.invokeMethod<int>('detectFaces', {'path': imagePath});
    return n ?? 0;
  }
}
