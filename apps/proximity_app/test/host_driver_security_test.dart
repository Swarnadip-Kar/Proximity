import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';

RealHostDriver makeDriver() => RealHostDriver(
      store: InMemoryDeviceStore(),
      engine: ProxBleEngine(radio: FakeBleRadio()),
    );

void main() {
  test('host allowlists mirror protocol gates (no silent drift)', () {
    expect(RealHostDriver.hostVerifierAllowlist, [kVerifierVerPrefix]);
    expect(RealHostDriver.hostLivenessAllowlist, [kLivenessVerPrefix]);
    expect(RealHostDriver.hostLivenessThreshold, kLivenessThreshold);
  });

  test('isIntegrityFlaggedReason parses piped server reasons', () {
    expect(RealHostDriver.isIntegrityFlaggedReason('ok'), isFalse);
    expect(RealHostDriver.isIntegrityFlaggedReason('ok|integrity-flagged'),
        isTrue);
    expect(
        RealHostDriver.isIntegrityFlaggedReason(
            'ok|direct-rssi|integrity-flagged|dupface:a@x.in'),
        isTrue);
    // Substring lookalikes must not match (exact token only).
    expect(
        RealHostDriver.isIntegrityFlaggedReason(
            'ok|integrity-flagged-evil'),
        isFalse);
    expect(RealHostDriver.isIntegrityFlaggedReason(''), isFalse);
  });

  test('integrity-flagged prove flags tally but keeps presence', () async {
    final driver = makeDriver();
    await driver.startHosting(classLabel: 'CS101', port: 0);
    await driver.startWindow(1);
    // Server marks before flagging: seed presence the way tally.mark does.
    await driver.addManualEntry(email: 't@x.in', name: 'Tainted');
    expect(driver.tally.flaggedEmails, isEmpty);
    driver.applyProveFlagsForTest('t@x.in', 'ok|direct-rssi|integrity-flagged');
    expect(driver.tally.flaggedEmails, ['t@x.in']);
    // Presence untouched (never auto-absent).
    expect(driver.tally.presentCount, 1);
    await driver.endHosting();
  });

  test('device-none-fallback never maps to roster flag (log-only)', () async {
    final driver = makeDriver();
    await driver.startHosting(classLabel: 'CS101', port: 0);
    await driver.startWindow(1);
    await driver.addManualEntry(email: 's@x.in', name: 'Soft');
    driver.applyProveFlagsForTest(
        's@x.in', 'ok|direct-rssi|device-none-fallback');
    // Fallback is the expected everyday signal until HW ships — flagging it
    // would mark the whole room, so it stays log-only.
    expect(driver.tally.flaggedEmails, isEmpty);
    expect(driver.tally.presentCount, 1);
    await driver.endHosting();
  });

  test('integrity flag on unknown email plants nothing', () async {
    final driver = makeDriver();
    await driver.startHosting(classLabel: 'CS101', port: 0);
    await driver.startWindow(1);
    // No tally row (invalid prove): setFaceFlag no-ops, no throw.
    driver.applyProveFlagsForTest('ghost@x.in', 'ok|integrity-flagged');
    expect(driver.tally.flaggedEmails, isEmpty);
    await driver.endHosting();
  });

  test('evaluateDeviceProof tier contract (host mirrors server gate)', () {
    final now = DateTime.utc(2026, 10, 1);
    // Fresh FULL confirms.
    final fresh = evaluateDeviceProof(
      level: AttestationLevel.full,
      attestedAt: DateTime.utc(2026, 9, 1),
      attestedUntil: DateTime.utc(2026, 12, 1),
      dSigValid: true,
      now: now,
    );
    expect(fresh.confirms, isTrue);
    // NONE never tiers (server falls back with the flagged confirm instead
    // of hard-invalidating live marking — host never re-gates it here).
    final none = evaluateDeviceProof(
      level: AttestationLevel.none,
      attestedAt: DateTime.utc(2026, 9, 1),
      attestedUntil: DateTime.utc(2026, 12, 1),
      dSigValid: true,
      now: now,
    );
    expect(none.confirms, isFalse);
    expect(none.reason, 'device-unproven');
  });
}
