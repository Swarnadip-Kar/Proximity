// Secure-storage options: prompt-free Keystore/Keychain (§3), explicit
// presence one layer up. Storage reads/writes must never pop a system
// prompt on any device (the old auth-bound design crashed KeyStore2-
// strict devices); signing authority stays the HW DKey + face + claim.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/security/secure_store_options.dart';

void main() {
  test('Android options are prompt-free, namespaced, never-wiping', () {
    const aOpts = SecureStoreOptions.aOpts;
    expect(aOpts, isA<AndroidOptions>());
    final params = aOpts.toMap();
    // No Keystore user-auth binding: reads/writes never prompt.
    expect(params['enforceBiometrics'], 'false');
    // Fresh namespace (never the old AES-wrap biometric slots — their
    // markers must not be reinterpreted under RSA wrap).
    expect(params['storageNamespace'], 'prox_store');
    expect(params['storageNamespace'], isNot(equals('prox_seal')));
    // Namespace-per-config is the migration strategy; failures surface
    // as errors, never wipe (the 2026-10-02 worker-thread wipe loop).
    expect(params['migrateOnAlgorithmChange'], 'false');
    expect(params['resetOnError'], 'false');
  });

  test('iOS options are this-device-only, unsynced, prompt-free', () {
    const iOpts = SecureStoreOptions.iOpts;
    expect(iOpts, isA<IOSOptions>());
    expect(iOpts.synchronizable, isFalse);
    expect(iOpts.accessibility, KeychainAccessibility.first_unlock_this_device);
    // No biometric access-control flag: iOS must not prompt where
    // Android stays silent (no asymmetric cold-start ambush).
    expect(iOpts.accessControlFlags, isEmpty);
  });
}
