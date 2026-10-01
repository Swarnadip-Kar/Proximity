// Secure-store dismissal contract: a back-press/cancel on the biometric
// prompt with nothing proven must throw SecureStoreDismissed (never null),
// so a dismissal can never read as "unenrolled" (shell enroll push) and a
// dismissed install-id read can never mint a forked identity. Immediate
// retries stay dismissed without re-prompting (anti-hammer).
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
}
