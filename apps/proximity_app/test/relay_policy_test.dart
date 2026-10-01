// Relay-policy unit proofs: pure memory decision + platform branches.
// The Android channel read itself is untestable here (no native side in
// flutter_test — MissingPluginException), so the fail-open fallback
// (unreadable → active) is pinned instead of the happy path.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/relay_policy.dart';

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    debugResetRelayPolicyForTest();
  });

  group('passiveForMemory (pure)', () {
    test('OS low-RAM flag wins regardless of size', () {
      expect(
          passiveForMemory(
              lowRamDevice: true,
              totalMemBytes: 8 * 1024 * 1024 * 1024),
          isTrue);
    });

    test('under 4 GiB is passive', () {
      expect(
          passiveForMemory(
              lowRamDevice: false,
              totalMemBytes: 3 * 1024 * 1024 * 1024),
          isTrue);
    });

    test('4 GiB boundary stays active', () {
      expect(
          passiveForMemory(
              lowRamDevice: false,
              totalMemBytes: kLowRamPassiveBytes),
          isFalse);
    });

    test('large RAM stays active', () {
      expect(
          passiveForMemory(
              lowRamDevice: false,
              totalMemBytes: 8 * 1024 * 1024 * 1024),
          isFalse);
    });

    test('unknown RAM without flag fails open to active', () {
      expect(
          passiveForMemory(lowRamDevice: false, totalMemBytes: 0),
          isFalse);
    });
  });

  group('shouldRelayPassively (platform)', () {
    test('iOS is always passive without touching the channel', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(await shouldRelayPassively(), isTrue);
    });

    test('desktop is never passive', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(await shouldRelayPassively(), isFalse);
    });

    test('android without a native side fails open to active', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      // No MethodChannel handler in flutter_test → MissingPluginException
      // → caught → active (today's behavior preserved).
      expect(await shouldRelayPassively(), isFalse);
    });

    test('android honors the injected memory reader', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      RelayMemReader.read = () async => <String, Object?>{
            'totalMemBytes': 2 * 1024 * 1024 * 1024,
            'lowRamDevice': false,
          };
      try {
        expect(await shouldRelayPassively(), isTrue);
      } finally {
        RelayMemReader.read = readRelayMemory;
        debugResetRelayPolicyForTest();
      }
    });
  });
}
