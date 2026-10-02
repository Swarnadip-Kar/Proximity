// User-presence gate contract: explicit confirm at identity creation,
// actionable copy on every refusal, no raw plugin leaks.
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/security/user_presence.dart';

void main() {
  test('confirm passes silently and records the reason', () async {
    final gate = FakePresenceGate();
    await gate.confirm(reason: 'Save enrollment on this device');
    expect(gate.confirmReasons,
        ['Save enrollment on this device']);
  });

  test('cancelled confirm throws the actionable save copy', () async {
    final gate = FakePresenceGate()..willConfirm = false;
    Object? caught;
    try {
      await gate.confirm(reason: 'r');
    } catch (e) {
      caught = e;
    }
    expect(caught, isStateError);
    expect('$caught', contains('Save cancelled'));
    expect('$caught', isNot(contains('LocalAuth')));
  });

  test('unsupported device throws the setup copy', () async {
    final gate = FakePresenceGate()..unsupportedDevice = true;
    Object? caught;
    try {
      await gate.confirm(reason: 'r');
    } catch (e) {
      caught = e;
    }
    expect(caught, isStateError);
    expect('$caught', contains('no screen lock'));
  });
}
