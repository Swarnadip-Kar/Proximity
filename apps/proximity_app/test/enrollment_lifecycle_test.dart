// Enrollment lifecycle policy contracts (transfer bound + lost-phone
// exemption + rules mirror).
//
// - Move cooldown is 30 days (verdict + mirrored rules pin below).
// - Lost-phone exemption: a STORED lastSeen past 60d allows an immediate
//   move. There is deliberately NO move-time "I've been offline" input —
//   the forged-stale attack is closed by construction (nothing to forge),
//   and rules re-gate on request.time + the fresh-stamp chain.
// - installConflict still refuses even when the binding is stale (the
//   exemption frees the Gmail's cooldown, never the install's one-Gmail).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/cloud_sync.dart';

const _email = 's@x.in';
const _dayMs = 24 * 60 * 60 * 1000;
final _now = DateTime.utc(2026, 9, 8);

StudentDeviceDoc _binding({
  required int lastMoveAgoMs,
  required int lastSeenAgoMs,
  String pk = 'aa',
  String inst = 'i1',
}) =>
    StudentDeviceDoc(
      email: _email,
      uid: 'u9',
      pkHex: pk,
      name: 'S',
      roll: '1',
      modelVer: 'v',
      installId: inst,
      lastMoveAtMillis: _now.millisecondsSinceEpoch - lastMoveAgoMs,
      lastSeenAtMillis: _now.millisecondsSinceEpoch - lastSeenAgoMs,
    );

void main() {
  group('30-day move cooldown boundary', () {
    test('29d23h59m blocked with exact retry date; 30d+1s allowed', () {
      const cooldown = 30 * _dayMs;
      final blocked = evaluateStudentClaim(
        localPkHex: 'zz',
        localInstallId: 'i2',
        binding: _binding(
            lastMoveAgoMs: cooldown - 1000, lastSeenAgoMs: cooldown - 1000),
        installEmail: null,
        email: _email,
        now: _now,
      );
      expect(blocked.claim, StudentClaim.cooldownBlocked);
      // Exact retry date preserved: lastMove + 30d.
      expect(blocked.retryAfter?.millisecondsSinceEpoch,
          _now.millisecondsSinceEpoch - (cooldown - 1000) + cooldown);
      expect(studentClaimMessage(blocked, null), contains('once a month'));
      expect(studentClaimMessage(blocked, null), contains('re-enroll'));

      final allowed = evaluateStudentClaim(
        localPkHex: 'zz',
        localInstallId: 'i2',
        binding: _binding(
            lastMoveAgoMs: cooldown + 1000, lastSeenAgoMs: cooldown + 1000),
        installEmail: null,
        email: _email,
        now: _now,
      );
      expect(allowed.claim, StudentClaim.allowedMove);
    });
  });

  group('lost-phone exemption (stored lastSeen only)', () {
    test('forged-stale at move time still waits: fresh stored value blocks',
        () {
      // Attacker's story ("my old phone has been offline for months") has
      // no input slot: the verdict reads the STORED lastSeen (5d fresh),
      // so the 5d-old move still waits out the 30d bound.
      final r = evaluateStudentClaim(
        localPkHex: 'zz',
        localInstallId: 'i2',
        binding: _binding(
            lastMoveAgoMs: 5 * _dayMs, lastSeenAgoMs: 5 * _dayMs),
        installEmail: null,
        email: _email,
        now: _now,
      );
      expect(r.claim, StudentClaim.cooldownBlocked);
    });

    test('genuinely-stale stored value passes inside the cooldown', () {
      // Moved 5d ago (inside 30d) but the old phone silent 61d: lost.
      final r = evaluateStudentClaim(
        localPkHex: 'zz',
        localInstallId: 'i2',
        binding: _binding(
            lastMoveAgoMs: 5 * _dayMs, lastSeenAgoMs: 61 * _dayMs),
        installEmail: null,
        email: _email,
        now: _now,
      );
      expect(r.claim, StudentClaim.allowedMove);
    });

    test('59d silence still waits; unknown (zero) lastSeen never exempts',
        () {
      final almost = evaluateStudentClaim(
        localPkHex: 'zz',
        localInstallId: 'i2',
        binding: _binding(
            lastMoveAgoMs: 5 * _dayMs, lastSeenAgoMs: 59 * _dayMs),
        installEmail: null,
        email: _email,
        now: _now,
      );
      expect(almost.claim, StudentClaim.cooldownBlocked);

      final unknown = evaluateStudentClaim(
        localPkHex: 'zz',
        localInstallId: 'i2',
        binding: StudentDeviceDoc(
          email: _email,
          uid: 'u9',
          pkHex: 'aa',
          name: 'S',
          roll: '1',
          modelVer: 'v',
          installId: 'i1',
          lastMoveAtMillis: _now.millisecondsSinceEpoch - 5 * _dayMs,
          lastSeenAtMillis: 0,
        ),
        installEmail: null,
        email: _email,
        now: _now,
      );
      expect(unknown.claim, StudentClaim.cooldownBlocked);
    });

    test('MoveIntent instant move preserved; legacy migration preserved',
        () {
      final intent = evaluateStudentClaim(
        localPkHex: 'zz',
        localInstallId: 'i2',
        binding: _binding(
            lastMoveAgoMs: 5 * _dayMs, lastSeenAgoMs: 5 * _dayMs),
        installEmail: null,
        email: _email,
        now: _now,
        moveIntentValid: true,
      );
      expect(intent.claim, StudentClaim.allowedMove);

      const legacy = StudentDeviceDoc(
        email: _email,
        uid: 'u9',
        pkHex: 'aa',
        name: 'S',
        roll: '1',
        modelVer: 'v',
        installId: 'i1',
      );
      expect(
          evaluateStudentClaim(
                  localPkHex: 'zz',
                  localInstallId: 'i2',
                  binding: legacy,
                  installEmail: null,
                  email: _email,
                  now: _now)
              .claim,
          StudentClaim.allowedMove);
    });

    test('stale binding never frees the install one-Gmail rule', () {
      final r = evaluateStudentClaim(
        localPkHex: 'zz',
        localInstallId: 'i2',
        binding: _binding(
            lastMoveAgoMs: 5 * _dayMs, lastSeenAgoMs: 90 * _dayMs),
        installEmail: 'other@x.in',
        email: _email,
        now: _now,
      );
      expect(r.claim, StudentClaim.installConflict);
    });
  });

  group('stampOlderThan', () {
    test('zero never old; exact boundary exclusive', () {
      expect(
          stampOlderThan(
              stampMillis: 0, now: _now, age: kStudentLostPhoneStale),
          isFalse);
      final edge = _now.millisecondsSinceEpoch -
          kStudentLostPhoneStale.inMilliseconds;
      expect(
          stampOlderThan(stampMillis: edge, now: _now, age: kStudentLostPhoneStale),
          isFalse);
      expect(
          stampOlderThan(
              stampMillis: edge - 1, now: _now, age: kStudentLostPhoneStale),
          isTrue);
    });
  });

  group('firestore.rules mirror pin (text contract, not CEL execution)', () {
    // No emulator in CI: this pins the mirror literals so the Dart verdict
    // and the rules cannot silently desync. Full CEL verification is the
    // manual redeploy drill (README checklist).
    late String rules;
    setUpAll(() {
      final f = File('firestore.rules');
      expect(f.existsSync(), isTrue,
          reason: 'rules pin test runs from the app package dir');
      rules = f.readAsStringSync();
    });

    test('30-day cooldown mirrored server-side', () {
      expect(rules, contains('30 * 24 * 60 * 60 * 1000'));
      expect(rules, isNot(contains('7 * 24 * 60 * 60 * 1000')));
    });

    test('lost-phone exemption on stored lastSeen with request.time', () {
      expect(rules, contains('isLostPhone()'));
      expect(rules, contains('request.time.toMillis()'));
      expect(rules, contains('60 * 24 * 60 * 60 * 1000'));
      // Stored value, not the incoming write:
      expect(rules, contains('resource.data.lastSeenAtMillis'));
    });

    test('fresh-stamp chain closes the forgery hole', () {
      expect(rules, contains('incomingStampsFresh()'));
      expect(rules, contains('storedMoveKeptOrFresh()'));
      // 1h skew both directions on both stamps:
      expect(rules, contains('60 * 60 * 1000'));
    });
  });
}
