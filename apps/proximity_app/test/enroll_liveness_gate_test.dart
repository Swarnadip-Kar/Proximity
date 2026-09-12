// sec-liveness: enrollFace MEASURES passive liveness (fail-closed).
//
// - Spoof (low liveness, matching face) → error, gallery untouched, no
//   save (the claimed livenessVer is measured, never self-asserted).
// - Liveness throw/unreadable → error, nothing stored, no save.
// - Threshold boundary: exactly Tl passes, just below fails.
// - Success pins that the gate RAN on the centre still.
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';
import 'package:proximity_protocol/protocol.dart';

const _stills = ['c.jpg', 'l.jpg', 'r.jpg', 'u.jpg', 'd.jpg'];

EnrollmentController _ctl({
  required FakeFaceVerifier verifier,
  required FakeLivenessGate liveness,
}) =>
    EnrollmentController(
      auth: FakeAuthService(const SignedAccount(
          email: 's@x.in', displayName: 'S', uid: 'u1')),
      store: InMemoryDeviceStore(),
      verifier: verifier,
      deviceKey: FakeDeviceKey(),
      livenessGate: liveness,
    );

Future<EnrollmentController> _keyReady({
  required FakeFaceVerifier verifier,
  required FakeLivenessGate liveness,
}) async {
  final ctl = _ctl(verifier: verifier, liveness: liveness);
  await ctl.signIn();
  await ctl.generateKey();
  return ctl;
}

void main() {
  group('enrollFace passive liveness gate (before gallery write)', () {
    test('spoof (low liveness, matching face) fails, gallery untouched',
        () async {
      final verifier = FakeFaceVerifier(match: true, score: 0.9);
      final live = FakeLivenessGate(score: 0.31);
      final ctl =
          await _keyReady(verifier: verifier, liveness: live);
      await ctl.enrollFace(_stills);
      // Readable spoof: error naming liveness, score stays 0.
      expect(ctl.state.phase, EnrollPhase.error);
      expect(ctl.state.faceScore, 0);
      expect(ctl.state.message, contains('live'));
      // The gallery NEVER saw it: liveness gates first (fail-closed).
      expect(
          verifier.calls.where((c) => c.startsWith('enroll:')), isEmpty);
      // The centre still was MEASURED (not asserted).
      expect(live.calls, ['c.jpg']);
      // Save stays blocked.
      expect(await ctl.upload(), isNull);
    });

    test('liveness throw fails closed (nothing stored, no save)',
        () async {
      final verifier = FakeFaceVerifier(match: true, score: 0.9);
      final live = FakeLivenessGate(throwOnDetect: true);
      final ctl =
          await _keyReady(verifier: verifier, liveness: live);
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.error);
      expect(ctl.state.faceScore, 0);
      expect(
          verifier.calls.where((c) => c.startsWith('enroll:')), isEmpty);
      expect(await ctl.upload(), isNull);
    });

    test('threshold boundary: exactly Tl passes, just below fails',
        () async {
      for (final s in [kLivenessThreshold, kLivenessThreshold - 0.001]) {
        final verifier = FakeFaceVerifier(match: true, score: 0.9);
        final live = FakeLivenessGate(score: s);
        final ctl =
            await _keyReady(verifier: verifier, liveness: live);
        await ctl.enrollFace(_stills);
        if (s >= kLivenessThreshold) {
          expect(ctl.state.phase, EnrollPhase.faceDone,
              reason: 'liveness=$s vs Tl=$kLivenessThreshold');
          ctl.setRoll('1');
          expect(await ctl.upload(), isNotNull,
              reason: 'measured enrollment must save');
        } else {
          expect(ctl.state.phase, EnrollPhase.error,
              reason: 'liveness=$s vs Tl=$kLivenessThreshold');
          expect(ctl.state.faceScore, 0);
          expect(await ctl.upload(), isNull,
              reason: 'unmeasured enrollment cannot save');
        }
      }
    });

    test('success records the measured centre still', () async {
      final verifier = FakeFaceVerifier(match: true, score: 0.9);
      final live = FakeLivenessGate(score: 0.95);
      final ctl =
          await _keyReady(verifier: verifier, liveness: live);
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      expect(live.calls, ['c.jpg']);
    });
  });
}
