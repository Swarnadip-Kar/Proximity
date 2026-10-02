// User-presence gate contract: explicit confirm at identity creation,
// actionable copy on every refusal, no raw plugin leaks.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:proximity_app/core/security/user_presence.dart';

/// Fake platform: scripts support + prompt outcome, records whether the
/// device-credential fallback was allowed (pattern/PIN phones enroll
/// through it — the old credential-slot fix, now a single prompt flag).
class _FakeLocalAuthPlatform
    with MockPlatformInterfaceMixin
    implements LocalAuthPlatform {
  bool supported = true;
  bool approved = true;
  bool? seenBiometricOnly;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    required Iterable<AuthMessages> authMessages,
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    seenBiometricOnly = options.biometricOnly;
    return approved;
  }

  @override
  Future<bool> deviceSupportsBiometrics() async => true;

  @override
  Future<List<BiometricType>> getEnrolledBiometrics() async => const [];

  @override
  Future<bool> isDeviceSupported() async => supported;

  @override
  Future<bool> stopAuthentication() async => true;
}

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

  group('LocalAuthPresenceGate (real gate, fake platform)', () {
    late _FakeLocalAuthPlatform platform;
    late LocalAuthPlatform oldInstance;

    setUp(() {
      platform = _FakeLocalAuthPlatform();
      oldInstance = LocalAuthPlatform.instance;
      LocalAuthPlatform.instance = platform;
    });

    tearDown(() {
      LocalAuthPlatform.instance = oldInstance;
    });

    test('allows the device-credential fallback (pattern/PIN phones)',
        () async {
      // biometricOnly:false is the old credential-slot fix in a single
      // flag: without it, pattern/PIN-only phones get no prompt at all.
      await LocalAuthPresenceGate().confirm(reason: 'Save enrollment');
      expect(platform.seenBiometricOnly, isFalse);
    });

    test('prompt cancel throws the save copy, never a plugin leak',
        () async {
      platform.approved = false;
      Object? caught;
      try {
        await LocalAuthPresenceGate().confirm(reason: 'Save enrollment');
      } catch (e) {
        caught = e;
      }
      expect(caught, isStateError);
      expect('$caught', contains('Save cancelled'));
      expect('$caught', isNot(contains('LocalAuth')));
    });

    test('unsupported device throws the setup copy', () async {
      platform.supported = false;
      Object? caught;
      try {
        await LocalAuthPresenceGate().confirm(reason: 'Save enrollment');
      } catch (e) {
        caught = e;
      }
      expect(caught, isStateError);
      expect('$caught', contains('no screen lock'));
    });
  });
}
