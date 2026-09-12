// Face crash hardening repro: empty-frame / null-return / uninitialized /
// disposed-camera-adjacent null paths must fail closed (inconclusive receipt
// or error state), never a throw and never a false pass.
//
// Written BEFORE the fix: tests (a1),(a2),(a3),(a4),(b1),(b3-cleanup) FAIL
// on the pre-fix code (false pass or uncaught throw); (a5),(b2),(b4) pin
// the already-correct fail-closed paths so they cannot regress.
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';
import 'package:proximity_ble/ble.dart';

import 'student_driver_test.dart' as helpers;

class _ThrowingStore extends InMemoryDeviceStore {
  @override
  Future<StoredEnrollment?> readEnrollment() async =>
      throw StateError('disk unreadable');
}

class _ThrowingVerSeal extends FakeFaceVerifier {
  @override
  String get verifierVer => throw StateError('model missing');
}

class _NoFaceThrowVerifier extends FakeFaceVerifier {
  @override
  Future<FaceVerifyResult> verify(String faceId, String imagePath,
      {double threshold = kFaceThreshold}) async {
    // Mirrors the real plugin's register-style no-face throw on the verify
    // path (empty frame / no detectable face in the still).
    throw StateError('No face detected');
  }
}

class _EnrollThrowVerifier extends FakeFaceVerifier {
  _EnrollThrowVerifier() : super(match: true, score: 0.9);
  @override
  Future<void> enroll(String faceId, List<String> imagePaths) async {
    calls.add('enroll:$faceId:${imagePaths.length}');
    throw StateError('No face detected');
  }
}

EnrollmentController _enrollCtl({
  required InMemoryDeviceStore store,
  required FaceVerifier verifier,
}) {
  final ctl = EnrollmentController(
    auth: FakeAuthService(const SignedAccount(
        email: 's@x.in', displayName: 'S', uid: 'u1')),
    store: store,
    verifier: verifier,
    deviceKey: FakeDeviceKey(),
    // enrollFace measures liveness: scripted pass so the (b) cases reach
    // the verifier throw they pin (liveness itself is pinned in
    // enroll_liveness_gate_test.dart).
    livenessGate: FakeLivenessGate(),
  );
  return ctl;
}

Future<EnrollmentController> _keyReadyCtl({
  required InMemoryDeviceStore store,
  required FaceVerifier verifier,
}) async {
  final ctl = _enrollCtl(store: store, verifier: verifier);
  await ctl.signIn();
  await ctl.generateKey();
  return ctl;
}

void main() {
  group('crash (a): marking-time verify never throws, never false-passes',
      () {
    test('(a1) empty imagePath is inconclusive, never a pass', () async {
      final d = helpers.testDriver(
        store: await helpers.enrolledStore(),
        engine: ProxBleEngine(radio: FakeBleRadio()),
      );
      final res = await d.checkFace('');
      expect(res.match, FaceMatch.inconclusive,
          reason: 'empty frame must rescan, never pass or burn');
      expect(res.faceValidAtMs, 0);
    });

    test('(a2) blank imagePath is inconclusive', () async {
      final d = helpers.testDriver(
        store: await helpers.enrolledStore(),
        engine: ProxBleEngine(radio: FakeBleRadio()),
      );
      final res = await d.checkFace('   ');
      expect(res.match, FaceMatch.inconclusive);
    });

    test('(a3) unreadable enrollment store is inconclusive, never a throw',
        () async {
      final d = helpers.testDriver(
        store: _ThrowingStore(),
        engine: ProxBleEngine(radio: FakeBleRadio()),
      );
      final res = await d.checkFace('still.jpg');
      expect(res.match, FaceMatch.inconclusive);
    });

    test('(a4) unreadable verifier version is inconclusive, never a throw',
        () async {
      final d = helpers.testDriver(
        store: await helpers.enrolledStore(),
        verifier: _ThrowingVerSeal(),
        engine: ProxBleEngine(radio: FakeBleRadio()),
      );
      final res = await d.checkFace('still.jpg');
      expect(res.match, FaceMatch.inconclusive);
    });

    test('(a5-pin) plugin no-face throw stays inconclusive', () async {
      final d = helpers.testDriver(
        store: await helpers.enrolledStore(),
        verifier: _NoFaceThrowVerifier(),
        engine: ProxBleEngine(radio: FakeBleRadio()),
      );
      final res = await d.checkFace('still.jpg');
      expect(res.match, FaceMatch.inconclusive);
      expect(res.faceValidAtMs, 0);
    });
  });

  group('crash (b): enrollment null paths fail closed, store nothing', () {
    test('(b1) empty slot still never enrolls', () async {
      final ctl = await _keyReadyCtl(
          store: InMemoryDeviceStore(), verifier: FakeFaceVerifier());
      await ctl.enrollFace(['a.jpg', '', 'c.jpg', 'd.jpg', 'e.jpg']);
      expect(ctl.state.phase, EnrollPhase.error);
      expect(ctl.state.faceScore, 0);
      // No face kept: Save stays blocked.
      expect(await ctl.upload(), isNull);
    });

    test('(b2-pin) wrong still count stays an error', () async {
      final ctl = await _keyReadyCtl(
          store: InMemoryDeviceStore(), verifier: FakeFaceVerifier());
      await ctl.enrollFace(['only-one.jpg']);
      expect(ctl.state.phase, EnrollPhase.error);
      expect(await ctl.upload(), isNull);
    });

    test('(b3) enroll throw leaves no partial gallery behind', () async {
      final verifier = _EnrollThrowVerifier();
      final ctl = await _keyReadyCtl(
          store: InMemoryDeviceStore(), verifier: verifier);
      await ctl.enrollFace(['a.jpg', 'b.jpg', 'c.jpg', 'd.jpg', 'e.jpg']);
      expect(ctl.state.phase, EnrollPhase.error);
      expect(ctl.state.faceScore, 0);
      // Best-effort cleanup of the half-registered slots.
      expect(
          verifier.calls.any((c) => c.startsWith('remove:')), isTrue,
          reason: 'slot0 orphan must be cleared after a mid-loop throw');
      expect(await ctl.upload(), isNull);
    });

    test('(b4-pin) uninitialized-plugin throw stays an error, never a throw',
        () async {
      final ctl = await _keyReadyCtl(
          store: InMemoryDeviceStore(),
          verifier: _NoFaceThrowVerifier()..match = true);
      // _NoFaceThrowVerifier throws on verify (self-check), enroll is a
      // no-op record: the controller must surface error, not propagate.
      await ctl.enrollFace(['a.jpg', 'b.jpg', 'c.jpg', 'd.jpg', 'e.jpg']);
      expect(ctl.state.phase, EnrollPhase.error);
    });
  });

  group('plugin guards throw before touching native (no init)', () {
    test('enroll rejects blank slots without init', () async {
      final v = PluginFaceVerifier();
      expect(
          () => v.enroll(
              'face-id', ['a.jpg', '', 'c.jpg', 'd.jpg', 'e.jpg']),
          throwsStateError);
    });

    test('enroll rejects wrong still count without init', () async {
      final v = PluginFaceVerifier();
      expect(() => v.enroll('face-id', ['only.jpg']), throwsArgumentError);
    });

    test('verify rejects empty frames without init', () async {
      final v = PluginFaceVerifier();
      expect(() => v.verify('face-id', '  '), throwsStateError);
    });
  });
}
