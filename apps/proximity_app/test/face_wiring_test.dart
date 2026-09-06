import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/edgeface.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_face/face.dart';

/// Proves the shipped app runs the REAL face check:
/// `loadFaceEmbedder()` (used by `main.dart` for both drivers) never hands
/// out a mock, and an unloadable model fails closed everywhere — enrollment
/// errors out, marking returns null (needs-review), SK never signs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loadFaceEmbedder never returns a mock embedder', () async {
    final embedder = await loadFaceEmbedder();
    expect(embedder, isNot(isA<MockFaceEmbedder>()));
    if (embedder.isLoaded) {
      embedder.close();
    } else {
      // Model unavailable here: must fail closed, never pass.
      await expectLater(
        embedder.embed(const [1, 2, 3]),
        throwsA(isA<FaceModelMissing>()),
      );
    }
  });

  test('enrollment with unloadable model fails closed (never faceDone)',
      () async {
    final ctl = EnrollmentController(
      auth: FakeAuthService(
          SignedAccount(email: 'a@x.in', displayName: 'A')),
      store: InMemoryDeviceStore(),
      embedder: EdgeFaceEmbedder(), // never loaded: model missing
    );
    await ctl.signIn();
    await ctl.generateKey();
    expect(ctl.state.phase, EnrollPhase.keyReady);
    await ctl.captureSlot(0, const [
      [7, 7, 7, 7]
    ]);
    expect(ctl.state.phase, EnrollPhase.error);
    expect(ctl.state.message, contains('FaceModelMissing'));
    expect(await ctl.upload(), isNull);
  });

  test('student checkFace with unloadable model is inconclusive (no pass)',
      () async {
    final store = InMemoryDeviceStore();
    await store.writeEnrollment(StoredEnrollment(
      email: 's@x.in',
      name: 'S',
      roll: '1',
      seedHex: 'ab' * 32,
      pkHex: 'cd' * 32,
      templateCsv: '1.0,0.0,0.0,0.0',
      enrolledAt: DateTime.now().toUtc(),
      modelVer: kFacePipelineVer,
    ));
    final d = RealStudentDriver(
      store: store,
      embedder: EdgeFaceEmbedder(), // never loaded: model missing
      engine: ProxBleEngine(radio: FakeBleRadio()),
    );
    expect(
        (await d.checkFace(Uint8List.fromList(const [7, 7, 7, 7]))).match,
        FaceMatch.inconclusive);
  });

  test('demo fallback bytes cannot pass a loaded real embedder', () async {
    final embedder = await loadFaceEmbedder();
    if (!embedder.isLoaded) {
      // No TFLite runtime on this machine: covered by the fail-closed
      // tests above; nothing real to probe here.
      return;
    }
    try {
      await embedder.embed(const [7, 7, 7, 7]);
      fail('undecodable demo bytes must not embed');
    } catch (e) {
      expect(e, isA<StateError>());
    } finally {
      embedder.close();
    }
  });
}
