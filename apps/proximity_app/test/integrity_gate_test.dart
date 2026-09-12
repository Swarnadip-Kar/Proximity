// 2C: IntegrityGate verdict / enroll-block / marking-flag units (+ entry
// pre-enroll/prove helpers). Fake-probe units stay hermetic; the closing
// group pins the REAL backends' fail-open contract (missing plugin →
// debug-only signals; App Check activation never throws).
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/app_config/force_update.dart';
import 'package:proximity_app/core/security/integrity.dart';
import 'package:proximity_app/features/entry/entry_flow.dart';

class _FakeProbe implements IntegrityProbe {
  final IntegritySignals signals;
  int calls = 0;
  _FakeProbe(this.signals);
  @override
  Future<IntegritySignals> check() async {
    calls++;
    return signals;
  }
}

class _ThrowingProbe implements IntegrityProbe {
  @override
  Future<IntegritySignals> check() async => throw StateError('no plugin');
}

IntegrityVerdict _verdict({
  bool rooted = false,
  bool hooked = false,
  bool tampered = false,
  bool emulator = false,
  bool debug = false,
}) =>
    IntegrityVerdict(
      rooted: rooted,
      hooked: hooked,
      tampered: tampered,
      emulator: emulator,
      debug: debug,
      hash: IntegrityGate.verdictHashOf(
        rooted: rooted,
        hooked: hooked,
        tampered: tampered,
        emulator: emulator,
        debug: debug,
      ),
    );

void main() {
  tearDown(() {
    IntegrityGate.probe = const PlatformIntegrityProbe();
  });

  group('verdictHashOf', () {
    test('stable 8-hex, deterministic', () {
      final a = IntegrityGate.verdictHashOf(
          rooted: false,
          hooked: false,
          tampered: false,
          emulator: false,
          debug: false);
      final b = IntegrityGate.verdictHashOf(
          rooted: false,
          hooked: false,
          tampered: false,
          emulator: false,
          debug: false);
      expect(a, equals(b));
      expect(RegExp(r'^[0-9a-f]{8}$').hasMatch(a), isTrue);
    });

    test('sensitive to every signal', () {
      final clean = IntegrityGate.verdictHashOf(
          rooted: false,
          hooked: false,
          tampered: false,
          emulator: false,
          debug: false);
      for (final v in [
        IntegrityGate.verdictHashOf(
            rooted: true,
            hooked: false,
            tampered: false,
            emulator: false,
            debug: false),
        IntegrityGate.verdictHashOf(
            rooted: false,
            hooked: true,
            tampered: false,
            emulator: false,
            debug: false),
        IntegrityGate.verdictHashOf(
            rooted: false,
            hooked: false,
            tampered: true,
            emulator: false,
            debug: false),
        IntegrityGate.verdictHashOf(
            rooted: false,
            hooked: false,
            tampered: false,
            emulator: true,
            debug: false),
        IntegrityGate.verdictHashOf(
            rooted: false,
            hooked: false,
            tampered: false,
            emulator: false,
            debug: true),
      ]) {
        expect(v, isNot(equals(clean)));
      }
    });
  });

  group('enroll gate', () {
    test('clean + debug-only proceed (debug never blocks)', () {
      expect(IntegrityGate.enrollBlockReason(_verdict()), isEmpty);
      expect(IntegrityGate.enrollBlockReason(_verdict(debug: true)), isEmpty);
      expect(_verdict(debug: true).blocksEnroll, isFalse);
    });

    test('privileged/hooked/tampered/emulator hard-block with copy', () {
      expect(
          IntegrityGate.enrollBlockReason(_verdict(rooted: true)), isNotEmpty);
      expect(
          IntegrityGate.enrollBlockReason(_verdict(hooked: true)), isNotEmpty);
      expect(IntegrityGate.enrollBlockReason(_verdict(tampered: true)),
          isNotEmpty);
      expect(IntegrityGate.enrollBlockReason(_verdict(emulator: true)),
          isNotEmpty);
      expect(_verdict(rooted: true).blocksEnroll, isTrue);
      expect(_verdict(emulator: true).blocksEnroll, isTrue);
    });

    test('block order names privileged first', () {
      final reason = IntegrityGate.enrollBlockReason(
          _verdict(rooted: true, hooked: true, tampered: true, emulator: true));
      expect(reason.toLowerCase(), contains('root'));
    });
  });

  group('marking flag', () {
    test('clean → empty, tainted → integrity-flagged (never absent)', () {
      expect(IntegrityGate.markingFlag(_verdict()), isEmpty);
      expect(IntegrityGate.markingFlag(_verdict(debug: true)), isEmpty);
      for (final v in [
        _verdict(rooted: true),
        _verdict(hooked: true),
        _verdict(tampered: true),
        _verdict(emulator: true),
      ]) {
        expect(IntegrityGate.markingFlag(v), 'integrity-flagged');
        expect(v.flagForMarking, 'integrity-flagged');
      }
      expect(IntegrityGate.flaggedValue, 'integrity-flagged');
    });
  });

  group('IntegrityGate with fake probe', () {
    test('rooted enroll blocks, marking flags', () async {
      IntegrityGate.probe = _FakeProbe(const IntegritySignals(rooted: true));
      final verdict =
          await IntegrityGate.verifyBeforeSensitiveOp(IntegrityOp.enroll);
      expect(verdict.rooted, isTrue);
      expect(IntegrityGate.enrollBlockReason(verdict), isNotEmpty);
      expect(verdict.hash, hasLength(8));
      final marking =
          await IntegrityGate.verifyBeforeSensitiveOp(IntegrityOp.prove);
      expect(IntegrityGate.markingFlag(marking), 'integrity-flagged');
    });

    test('clean enroll passes, marking unflagged (offline preserved)',
        () async {
      IntegrityGate.probe = _FakeProbe(const IntegritySignals());
      final verdict =
          await IntegrityGate.verifyBeforeSensitiveOp(IntegrityOp.enroll);
      expect(IntegrityGate.enrollBlockReason(verdict), isEmpty);
      expect(IntegrityGate.markingFlag(verdict), isEmpty);
    });

    test('performCheck caches lastVerdict; sensitive ops re-probe fresh',
        () async {
      final probe = _FakeProbe(const IntegritySignals());
      IntegrityGate.probe = probe;
      await IntegrityGate.performCheck();
      expect(IntegrityGate.lastVerdict, isNotNull);
      expect(probe.calls, 1);
      await IntegrityGate.verifyBeforeSensitiveOp(IntegrityOp.prove);
      await IntegrityGate.verifyBeforeSensitiveOp(IntegrityOp.host);
      expect(probe.calls, 3);
    });

    test('probe failure yields clean verdict, never throws', () async {
      IntegrityGate.probe = _ThrowingProbe();
      final startup = await IntegrityGate.performCheck();
      expect(IntegrityGate.enrollBlockReason(startup), isEmpty);
      final prove =
          await IntegrityGate.verifyBeforeSensitiveOp(IntegrityOp.prove);
      expect(IntegrityGate.markingFlag(prove), isEmpty);
    });
  });

  group('entry_flow integrity helpers', () {
    test('pre-enroll throws on rooted, passes clean', () async {
      IntegrityGate.probe = _FakeProbe(const IntegritySignals(rooted: true));
      expect(entryRequireEnrollIntegrity, throwsStateError);
      IntegrityGate.probe = _FakeProbe(const IntegritySignals());
      final verdict = await entryRequireEnrollIntegrity();
      expect(IntegrityGate.enrollBlockReason(verdict), isEmpty);
    });

    test('pre-prove never throws; flags tainted (never absent)', () async {
      IntegrityGate.probe = _FakeProbe(const IntegritySignals(hooked: true));
      final tainted = await entryMarkingIntegrity();
      expect(tainted.flagForMarking, 'integrity-flagged');
      IntegrityGate.probe = _ThrowingProbe();
      final clean = await entryMarkingIntegrity();
      expect(clean.flagForMarking, isEmpty);
    });

    test('pre-host never throws (advisory, offline-capable)', () async {
      IntegrityGate.probe = _ThrowingProbe();
      final verdict = await entryHostIntegrity();
      expect(verdict.hash, hasLength(8));
    });

    test('startup reuses cache when present', () async {
      final probe = _FakeProbe(const IntegritySignals());
      IntegrityGate.probe = probe;
      await IntegrityGate.performCheck();
      final callsAfterCheck = probe.calls;
      final verdict = await entryIntegrityStartup();
      expect(probe.calls, callsAfterCheck);
      expect(verdict.hash, IntegrityGate.lastVerdict!.hash);
    });
  });

  group('entryRequireFreshBuild (§6 floor, H3)', () {
    ForceUpdateResult fresh() => const ForceUpdateResult(
          checked: true,
          updateRequired: false,
          currentVersion: '0.2.0',
          config: ForceUpdateConfig(minVersion: '0.2.0', force: true),
        );
    ForceUpdateResult stale() => const ForceUpdateResult(
          checked: true,
          updateRequired: true,
          currentVersion: '0.1.0',
          config: ForceUpdateConfig(
              minVersion: '0.2.0',
              force: true,
              message: 'Update to continue.'),
        );
    ForceUpdateResult unchecked() => const ForceUpdateResult(
          checked: false,
          updateRequired: false,
          currentVersion: '0.1.0',
        );

    test('verified-fresh passes', () async {
      await entryRequireFreshBuild(checkNow: () async => fresh());
    });

    test('verified-stale throws with update copy', () async {
      expect(
        entryRequireFreshBuild(checkNow: () async => stale()),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('too old'))),
      );
    });

    test('unchecked (offline/missing floor) never throws', () async {
      // Offline marking preserved: only a VERIFIED floor blocks.
      await entryRequireFreshBuild(checkNow: () async => unchecked());
    });

    test('live checkNow degrades to unchecked in tests (never throws)',
        () async {
      // No platform plugins in unit tests: the real checkNow converts to
      // unchecked instead of throwing.
      await entryRequireFreshBuild();
    });
  });

  group('real backends (fail-open, never throw)', () {
    test('PlatformIntegrityProbe degrades to debug-only without a plugin',
        () async {
      // Unit tests have no native plugin: the MethodChannel read must fail
      // OPEN (clean signals + observed debug), never throw, never taint —
      // the same posture as a records-only build or a hung channel.
      const probe = PlatformIntegrityProbe();
      final signals = await probe.check();
      expect(signals.rooted, isFalse);
      expect(signals.hooked, isFalse);
      expect(signals.tampered, isFalse);
      expect(signals.emulator, isFalse);
      expect(signals.debug, kDebugMode);
    });

    test('performCheck with the real probe never throws', () async {
      final verdict = await IntegrityGate.performCheck();
      expect(verdict.hash, hasLength(8));
      expect(IntegrityGate.lastVerdict, isNotNull);
    });

    test('IntegrityAppCheck.ensureActivated never throws', () async {
      // No Firebase app in unit tests: activation degrades to a log line —
      // App Check absence never blocks offline marking.
      await IntegrityAppCheck.ensureActivated();
      await IntegrityAppCheck.ensureActivated();
    });
  });
}
