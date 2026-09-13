// sec-liveness: enrollFace MEASURES passive liveness (fail-closed).
//
// - Spoof (low liveness, matching face) → error, gallery untouched, no
//   save (the claimed livenessVer is measured, never self-asserted).
// - Liveness throw/unreadable → error, nothing stored, no save.
// - Threshold boundary: exactly Tl passes, just below fails (centre).
// - Per-slot bars: centre holds strict Tl, diversity slots hold the
//   relaxed kEnrollSideLivenessThreshold (field tilted-genuine 0.79).
// - C4: the gate runs on ALL 5 stills in slot order (fail-closed per
//   still) — success pins all 5 were measured; a first-still spoof still
//   aborts at the centre slot with the gallery untouched.
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';
import 'package:proximity_app/features/setup/result_sections.dart';
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

/// Per-still scripted vitality: FakeLivenessGate returns one constant for
/// every still, but the enroll bar is per-slot (strict centre, relaxed
/// sides) — this gate pops one score per detectPassive call in slot order
/// (centre, left, right, up, down), falling back to the last score.
class _ScriptedLivenessGate implements LivenessGate {
  final List<double> scores;
  final List<String> calls = [];
  _ScriptedLivenessGate(this.scores);

  @override
  Future<LivenessResult> detectPassive(String imagePath) async {
    calls.add(imagePath);
    final s = scores[calls.length <= scores.length
        ? calls.length - 1
        : scores.length - 1];
    return LivenessResult(score: s, ver: kLivenessVer);
  }
}

Future<EnrollmentController> _keyReadyScripted({
  required FakeFaceVerifier verifier,
  required _ScriptedLivenessGate liveness,
}) async {
  final ctl = EnrollmentController(
    auth: FakeAuthService(const SignedAccount(
        email: 's@x.in', displayName: 'S', uid: 'u1')),
    store: InMemoryDeviceStore(),
    verifier: verifier,
    deviceKey: FakeDeviceKey(),
    livenessGate: liveness,
  );
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
      // The centre still was MEASURED first (not asserted) — the
      // all-5 gate aborts at the first failing slot, so a spoof fails
      // here with the gallery untouched.
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

    test('success records all 5 measured stills in slot order', () async {
      final verifier = FakeFaceVerifier(match: true, score: 0.9);
      final live = FakeLivenessGate(score: 0.95);
      final ctl =
          await _keyReady(verifier: verifier, liveness: live);
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      // C4: every enrolled still carries a measured vitality score —
      // scoring order is slot order (centre, left, right, up, down).
      expect(live.calls, _stills);
    });
  });

  group('per-slot bars (field-relaxed centre 0.70, diversity slots 0.70)', () {
    test('field genuine spread passes: 0.90/0.95/0.89/0.79/0.88', () async {
      // 2026-09-13 field enrollment scored centre 0.90, left 0.95, right
      // 0.89, up 0.79 against a flat 0.85 bar and failed on up. The up
      // still is genuine vitality (same holder, same light) — tilted
      // captures systematically score lower.
      final verifier = FakeFaceVerifier(match: true, score: 0.9);
      final live =
          _ScriptedLivenessGate([0.90, 0.95, 0.89, 0.79, 0.88]);
      final ctl = await _keyReadyScripted(
          verifier: verifier, liveness: live);
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      expect(live.calls, _stills);
    });

    test('centre field-relaxed: 0.69 centre fails despite live sides',
        () async {
      // 2026-09-13 field relaxation: centre bar is Tl=0.70 (was strict
      // 0.85). 0.69 fails, 0.70 passes — same bar as attendance marking.
      final verifier = FakeFaceVerifier(match: true, score: 0.9);
      final live =
          _ScriptedLivenessGate([0.69, 0.95, 0.95, 0.95, 0.95]);
      final ctl = await _keyReadyScripted(
          verifier: verifier, liveness: live);
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.error);
      expect(ctl.lastFailedSlot, 'centre');
      expect(
          verifier.calls.where((c) => c.startsWith('enroll:')), isEmpty);
    });

    test('side bar boundary: 0.70 passes a side, 0.69 fails it', () async {
      for (final s in [kEnrollSideLivenessThreshold, 0.69]) {
        final verifier = FakeFaceVerifier(match: true, score: 0.9);
        // Centre strict-passes; the up slot probes the side boundary.
        final live = _ScriptedLivenessGate([0.95, 0.95, 0.95, s, 0.95]);
        final ctl = await _keyReadyScripted(
            verifier: verifier, liveness: live);
        await ctl.enrollFace(_stills);
        if (s >= kEnrollSideLivenessThreshold) {
          expect(ctl.state.phase, EnrollPhase.faceDone,
              reason: 'side liveness=$s vs side bar');
        } else {
          expect(ctl.state.phase, EnrollPhase.error,
              reason: 'side liveness=$s vs side bar');
          expect(ctl.lastFailedSlot, 'up');
        }
      }
    });

    test('spoof still fails every slot at the relaxed bar', () async {
      final verifier = FakeFaceVerifier(match: true, score: 0.9);
      final live = FakeLivenessGate(score: 0.31);
      final ctl =
          await _keyReady(verifier: verifier, liveness: live);
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.error);
      expect(ctl.lastFailedSlot, 'centre');
    });
  });

  group('stale error text (recapture success clears the message)', () {
    test('faceDone after a slot refusal carries no message', () async {
      // Field 2026-09-13: a "right capture was not live" refusal survived
      // into faceDone via copyWith and the result screen rendered the STALE
      // error above Save after a successful recapture.
      final verifier = FakeFaceVerifier(match: true, score: 0.9);
      final live = FakeLivenessGate(score: 0.31);
      final ctl =
          await _keyReady(verifier: verifier, liveness: live);
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.error);
      expect(ctl.state.message, contains('centre'));
      live.score = 0.95;
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      expect(ctl.state.message, isEmpty,
          reason: 'a validated capture must not carry refusal text');
      expect(ctl.lastFailedSlot, isNull);
    });
  });

  group('result classifier (stale-message hardening)', () {
    test('faceDone never renders a refusal card, even with text', () {
      // Belt-and-braces with the controller clear above: a validated
      // capture must reach Save with no refusal card.
      const st = EnrollmentState(
          phase: EnrollPhase.faceDone,
          faceScore: 0.7,
          message: 'The right capture did not look live — recapture it.');
      expect(classifyEnrollRefusal(st), EnrollRefusal.none);
    });

    test('error with liveness text still classifies (generic)', () {
      const st = EnrollmentState(
          phase: EnrollPhase.error,
          message: 'The right capture did not look live — recapture it.');
      expect(classifyEnrollRefusal(st), EnrollRefusal.generic);
    });
  });

  group('failed-slot tracking for single-slot recapture', () {
    test('liveness FAIL records the slot, success clears it', () async {
      final verifier = FakeFaceVerifier(match: true, score: 0.9);
      final live = FakeLivenessGate(score: 0.31);
      final ctl =
          await _keyReady(verifier: verifier, liveness: live);
      expect(ctl.lastFailedSlot, isNull);
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.error);
      expect(ctl.lastFailedSlot, 'centre');

      live.score = 0.95;
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      expect(ctl.lastFailedSlot, isNull);
    });

    test('liveness throw records the slot', () async {
      final verifier = FakeFaceVerifier(match: true, score: 0.9);
      final live = FakeLivenessGate(throwOnDetect: true);
      final ctl =
          await _keyReady(verifier: verifier, liveness: live);
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.error);
      expect(ctl.lastFailedSlot, 'centre');
    });
  });
}
