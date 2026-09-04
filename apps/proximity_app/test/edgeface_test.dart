import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/edgeface.dart';

void main() {
  test('missing model file raises a clear, actionable error', () async {
    final e = EdgeFaceEmbedder();
    expect(e.isLoaded, isFalse);
    await expectLater(e.load(), throwsA(isA<FaceModelMissing>()));
    await expectLater(
        e.embed(const [1, 2, 3]), throwsA(isA<FaceModelMissing>()));
  });
}
