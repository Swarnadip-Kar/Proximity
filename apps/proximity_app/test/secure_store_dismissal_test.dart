// Secure-store dismissal contract: a back-press/cancel on the biometric
// prompt with nothing proven must throw SecureStoreDismissed (never null),
// so a dismissal can never read as "unenrolled" (shell enroll push) and a
// dismissed install-id read can never mint a forked identity. Immediate
// retries stay dismissed without re-prompting (anti-hammer).
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/security/secure_store_options.dart';
import 'package:proximity_app/core/sync/store/secure_store.dart';
import 'package:proximity_app/core/sync/store/store_base.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Slot whose reads always dismiss like a back-pressed BiometricPrompt.
class _CancelSlot extends FlutterSecureStorage {
  _CancelSlot({bool cred = false})
      : super(
          aOptions:
              cred ? SecureStoreOptions.aOptsFallback : SecureStoreOptions.aOpts,
          iOptions:
              cred ? SecureStoreOptions.iOptsFallback : SecureStoreOptions.iOpts,
        );

  int reads = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads++;
    throw StateError(
        'BiometricPrompt authentication error: canceled (user_cancel)');
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw StateError(
        'BiometricPrompt authentication error: canceled (user_cancel)');
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {}
}

/// Slot whose key exists but whose biometric-bound cipher cannot init —
/// the first launch after an app update, before the namespace re-binds.
class _FreshNamespaceSlot extends FlutterSecureStorage {
  _FreshNamespaceSlot({bool cred = false})
      : super(
          aOptions:
              cred ? SecureStoreOptions.aOptsFallback : SecureStoreOptions.aOpts,
          iOptions:
              cred ? SecureStoreOptions.iOptsFallback : SecureStoreOptions.iOpts,
        );

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw StateError(
        'IllegalStateException: Cipher not initialized');
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw StateError(
        'IllegalStateException: Cipher not initialized');
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {}
}

/// Slot whose platform side is not attached yet (first-frame race).
class _DetachedSlot extends FlutterSecureStorage {
  _DetachedSlot({bool cred = false})
      : super(
          aOptions:
              cred ? SecureStoreOptions.aOptsFallback : SecureStoreOptions.aOpts,
          iOptions:
              cred ? SecureStoreOptions.iOptsFallback : SecureStoreOptions.iOpts,
        );

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw MissingPluginException(
        'No implementation found for method read on channel plugins.it_nomad.flutter_secure_storage');
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw MissingPluginException(
        'No implementation found for method write on channel plugins.it_nomad.flutter_secure_storage');
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {}
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('dismissal contract (back-press with nothing proven)', () {
    test('readEnrollment throws dismissed, never null', () async {
      final strong = _CancelSlot();
      final cred = _CancelSlot(cred: true);
      final store =
          SecureDeviceStore(secure: strong, fallbackSecure: cred);

      await expectLater(
        store.readEnrollment(),
        throwsA(isA<SecureStoreDismissed>()),
      );
      // Both slots prompted exactly once each.
      expect(strong.reads, 1);
      expect(cred.reads, 1);

      // Immediate retry: still dismissed, no new prompts (anti-hammer).
      await expectLater(
        store.readEnrollment(),
        throwsA(isA<SecureStoreDismissed>()),
      );
      expect(strong.reads, 1);
      expect(cred.reads, 1);
    });

    test('readInstallId throws dismissed instead of resolving null',
        () async {
      final strong = _CancelSlot();
      final cred = _CancelSlot(cred: true);
      final store =
          SecureDeviceStore(secure: strong, fallbackSecure: cred);

      // Null here would make getOrCreateInstallId mint a forked identity.
      await expectLater(
        store.readInstallId(),
        throwsA(isA<SecureStoreDismissed>()),
      );
    });

    test('dismissal message is user-readable and matcher-visible', () {
      const e = SecureStoreDismissed();
      expect('$e', contains('user_cancel'));
      expect('$e', contains('Unlock and try again'));
    });
  });

  group('transient first-read failures (never empty, never a push)', () {
    test('fresh Keystore namespace reads dismissed, not empty', () async {
      final strong = _FreshNamespaceSlot();
      final cred = _FreshNamespaceSlot(cred: true);
      final store =
          SecureDeviceStore(secure: strong, fallbackSecure: cred);

      // First launch after an update: the key exists but the
      // biometric-bound cipher cannot init until the namespace re-binds.
      // Data may exist behind the lock — park dismissed with retry.
      await expectLater(
        store.readEnrollment(),
        throwsA(isA<SecureStoreDismissed>()),
      );
    });

    test('detached platform channel reads dismissed, not empty', () async {
      final strong = _DetachedSlot();
      final cred = _DetachedSlot(cred: true);
      final store =
          SecureDeviceStore(secure: strong, fallbackSecure: cred);

      await expectLater(
        store.readEnrollment(),
        throwsA(isA<SecureStoreDismissed>()),
      );
    });
  });

  group('transient platform failures (never empty, never a mint)', () {
    test('non-auth read failure throws unavailable, not null', () async {
      final strong = _IoFailSlot();
      final cred = _IoFailSlot(cred: true);
      final store =
          SecureDeviceStore(secure: strong, fallbackSecure: cred);

      // A transient I/O failure is unknown — reporting empty here would
      // push a phantom enrollment; resolving null on the install id
      // would mint a forked identity.
      await expectLater(
        store.readEnrollment(),
        throwsA(isA<SecureStoreUnavailable>()),
      );
      await expectLater(
        store.readInstallId(),
        throwsA(isA<SecureStoreUnavailable>()),
      );
    });

    test('unavailable carries no dismissal marker', () {
      const e = SecureStoreUnavailable();
      expect('$e'.toLowerCase(), isNot(contains('cancel')));
      expect('$e', contains('try again'));
    });
  });
}

/// Slot whose platform call fails transiently (no prompt involved).
class _IoFailSlot extends FlutterSecureStorage {
  _IoFailSlot({bool cred = false})
      : super(
          aOptions:
              cred ? SecureStoreOptions.aOptsFallback : SecureStoreOptions.aOpts,
          iOptions:
              cred ? SecureStoreOptions.iOptsFallback : SecureStoreOptions.iOpts,
        );

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw StateError('disk full');
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw StateError('disk full');
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {}
}
