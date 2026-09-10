// FaceCaptureScreen aspect pins: the still-capture modal (the actual live
// camera surface in the marking flow) must never force-fill its area.
//
// Root cause, fixed: the preview lived in `Stack(fit: StackFit.expand)`,
// whose tight constraints stretched the feed to the body-minus-panel box
// (an arbitrary ratio) whenever it differed from the sensor ratio — the
// "little squish" on the mark face-check. The box is now sized by the
// orientation-adjusted ratio the plugin paints
// (`displayedPreviewAspect`, shared with the enroll chain), so leftovers
// become plain background and the oval draws on the true video box.
// If this fails, the modal drifted — do not "fix" the test, fix the block.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String modalLib() =>
      File('lib/screens/face_capture.dart').readAsStringSync();

  group('FaceCaptureScreen preview box', () {
    test('preview sized by the orientation-adjusted ratio', () {
      final src = modalLib();
      expect(src.contains('displayedPreviewAspect(ctl.value)'), isTrue);
      expect(src.contains('child: AspectRatio('), isTrue);
      expect(src.contains('CameraPreview(ctl)'), isTrue);
    });

    test('no forced-fill on the video path', () {
      final src = modalLib();
      expect(src.contains('Stack('), isTrue);
      expect(src.contains('fit: StackFit.expand'), isFalse);
      expect(src.contains('BoxFit.cover'), isFalse);
      expect(src.contains('BoxFit.fill'), isFalse);
    });

    test('oval fills the aspect box, capture flow untouched', () {
      final src = modalLib();
      expect(src.contains('Positioned.fill('), isTrue);
      expect(src.contains('FaceCaptureOvalOverlay('), isTrue);
      // Capture cadence + guards byte-identical.
      expect(src.contains('Future<void> _captureAll()'), isTrue);
      expect(
          src.contains('Capture produced no image — try again.'), isTrue);
      expect(src.contains('FaceBlockedCard(flow:'), isTrue);
    });
  });
}
