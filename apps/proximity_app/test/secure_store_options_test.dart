// 1B: hardened secure-storage options compile + carry the §3 values.
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
    // flip and trigger migrate/reset wipes. Plugin-level migration stays
    // OFF (namespace-per-config is the migration strategy — the backup
    // path crashes on fresh biometric namespaces); crash-resistant flag
    // kept inert.
    expect(params['storageNamespace'], 'prox_enroll');
    expect(params['migrateOnAlgorithmChange'], 'false');
    expect(params['migrateWithBackup'], 'true');
  });

  test('iOS options are this-device-only, unsynced, current-set bound', () {
    const iOpts = SecureStoreOptions.iOpts;
    expect(iOpts, isA<IOSOptions>());
    expect(iOpts.synchronizable, isFalse);
    expect(iOpts.accessibility, KeychainAccessibility.first_unlock_this_device);
    expect(iOpts.accessControlFlags, contains(AccessControlFlag.biometryCurrentSet));
  });

  test('credential fallback uses a DISTINCT namespace (no alias clobber)', () {
    // Field root cause (IllegalBlockSizeException after biometric auth):
    // two FSS configs with different biometricType sharing one
    // storageNamespace share the KeyStore alias + IV + wrapped app-key
    // blob, so one side's write orphans the other's blob. The fallback
    // slot must never equal the strong slot (nor the seal slot).
    final strong = SecureStoreOptions.aOpts.toMap();
    final fallback = SecureStoreOptions.aOptsFallback.toMap();
    expect(fallback['storageNamespace'], 'prox_enroll_cred');
    expect(fallback['migrateOnAlgorithmChange'], 'false');
    expect(fallback['storageNamespace'],
        isNot(equals(strong['storageNamespace'])));
    expect(fallback['storageNamespace'], isNot(equals('prox_seal')));
    expect(fallback['biometricType'],
        AndroidBiometricType.biometricOrDeviceCredential.name);
  });
}
