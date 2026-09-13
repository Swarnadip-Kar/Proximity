// 1B: hardened secure-storage options compile + carry the §3 values.
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/security/secure_store_options.dart';

void main() {
  test('Android options enforce strong biometrics with AES-GCM', () {
    const aOpts = SecureStoreOptions.aOpts;
    expect(aOpts, isA<AndroidOptions>());
    final params = aOpts.toMap();
    expect(params['enforceBiometrics'], 'true');
    expect(params['biometricType'], AndroidBiometricType.strongBiometricOnly.name);
    // AndroidOptions.biometric pins both ciphers to AES-GCM internally.
    expect(params['keyCipherAlgorithm'], KeyCipherAlgorithm.AES_GCM_NoPadding.name);
    expect(params['storageCipherAlgorithm'], StorageCipherAlgorithm.AES_GCM_NoPadding.name);
    expect(params['biometricPromptNegativeButton'], isNotEmpty);
    // Namespace isolation (FSS v11): enrollment (AES-wrap) must never share
    // the default namespace with the seal store (RSA-wrap) — shared markers
    // flip and trigger migrate/reset wipes. Crash-resistant migration on.
    expect(params['storageNamespace'], 'prox_enroll');
    expect(params['migrateWithBackup'], 'true');
  });

  test('iOS options are this-device-only, unsynced, current-set bound', () {
    const iOpts = SecureStoreOptions.iOpts;
    expect(iOpts, isA<IOSOptions>());
    expect(iOpts.synchronizable, isFalse);
    expect(iOpts.accessibility, KeychainAccessibility.first_unlock_this_device);
    expect(iOpts.accessControlFlags, contains(AccessControlFlag.biometryCurrentSet));
  });

  test('prebuilt storage carries the hardened options', () {
    const storage = SecureStoreOptions.storage;
    expect(storage.aOptions.toMap(), SecureStoreOptions.aOpts.toMap());
    expect(storage.iOptions.synchronizable, isFalse);
    expect(
      storage.iOptions.accessibility,
      KeychainAccessibility.first_unlock_this_device,
    );
  });

  test('desktop/web fail closed', () {
    // Unit tests run with an Android default platform; override to a
    // records-only target: the gate must throw rather than hand out storage
    // that silently persists secrets weakly.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(SecureStoreOptions.isSupportedPlatform, isFalse);
    expect(SecureStoreOptions.newStorage, throwsStateError);
    expect(SecureStoreOptions.requireSupportedPlatform, throwsStateError);
  });
}
