// KeyStore2-strict regression (field crash 2026-10-02, RZCR90BC14A):
// on devices that enforce Keystore auth at cipher.init time, the FSS v11
// native init throws UserNotAuthenticatedException BEFORE any
// BiometricPrompt shows, and misclassifies it as a key mismatch. With
// resetOnError:false (see SecureStoreOptions) that failure now surfaces
// as a PlatformException instead of wiping all data + recursing to a
// worker-thread StackOverflow FATAL. These tests pin the Dart side of
// that contract: the surfaced shape must route to dismissed/unavailable
// (park + retry, data preserved), never to null (phantom setup push),
// never to a raw platform leak, never to a crash.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/security/secure_store_options.dart';
import 'package:proximity_app/core/sync/store/secure_store.dart';
import 'package:proximity_app/core/sync/store/store_base.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Dart-visible init failure with resetOnError:false (verbatim FSS v11
/// handleKeyMismatch userMessage for an InvalidKeyException at init).
const _strictInitFailure =
    'PlatformException(Exception encountered, Key mismatch after '
    'algorithm change (Invalid key, key type incompatible with cipher). '
    'Enable migrateOnAlgorithmChange=true to preserve data, or '
    'resetOnError=true to delete., null)';

/// Raw cause shape, in case a future plugin surfaces it directly.
const _userNotAuthenticated =
    'PlatformException(Exception encountered, '
    'android.security.keystore.UserNotAuthenticatedException: User not '
    'authenticated, null)';

/// In-memory FSS stand-in with scripted failures (platform channels are
/// unavailable in unit tests; SecureDeviceStore takes any instance).
class _ScriptedSecure extends FlutterSecureStorage {
  _ScriptedSecure()
      : super(
          aOptions: SecureStoreOptions.aOpts,
          iOptions: SecureStoreOptions.iOpts,
        );

  final Map<String, String?> backend = {};
  final List<String> readKeys = [];
  final List<String> deletedKeys = [];
  Object? readError;
  Object? writeError;

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
    readKeys.add(key);
    final e = readError;
    if (e != null) throw e;
    return backend[key];
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
    final e = writeError;
    if (e != null) throw e;
    if (value == null) {
      backend.remove(key);
    } else {
      backend[key] = value;
    }
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
  }) async {
    deletedKeys.add(key);
    backend.remove(key);
  }
}

StoredEnrollment _doc() => StoredEnrollment(
      email: 'a@x.in',
      name: 'A',
      roll: '1',
      pkHex: 'cd' * 32,
      sealedKeyHex: 'ef' * 32,
      enrolledAt: DateTime.utc(2026, 1, 1),
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  for (final shape in [_strictInitFailure, _userNotAuthenticated]) {
    final tag = shape == _strictInitFailure ? 'mismatch-copy' : 'raw-unauth';

    test('strict-init failure ($tag): enrollment read parks dismissed, '
        'both slots tried, data kept', () async {
      final strong = _ScriptedSecure()
        ..readError = StateError(shape)
        ..backend['prox.enrollment.v1'] = jsonEncode(_doc().toJson());
      final cred = _ScriptedSecure()..readError = StateError(shape);
      final store = SecureDeviceStore(secure: strong, fallbackSecure: cred);

      // Never null: data may sit behind the lock (the native side refused
      // before any prompt) — null would push a phantom enrollment.
      await expectLater(
        store.readEnrollment(),
        throwsA(isA<SecureStoreDismissed>()),
      );
      // Auth/key failure (not a user skip): the scan falls through to the
      // other slot instead of stopping after one prompt.
      expect(strong.readKeys, contains('prox.enrollment.v1'));
      expect(cred.readKeys, contains('prox.enrollment.v1'));
      // Read path never deletes: the pre-existing doc survives for the
      // retry once the device authenticates.
      expect(strong.deletedKeys, isEmpty);
      expect(cred.deletedKeys, isEmpty);
      expect(strong.backend['prox.enrollment.v1'], isNotNull);
    });

    test('strict-init failure ($tag): install-id read parks dismissed, '
        'never mints a fork', () async {
      final strong = _ScriptedSecure()..readError = StateError(shape);
      final cred = _ScriptedSecure()..readError = StateError(shape);
      final store = SecureDeviceStore(secure: strong, fallbackSecure: cred);

      // Dismissed, not null: resolving null here would mint a FRESH
      // install over existing data (identity fork).
      await expectLater(
        store.readInstallId(),
        throwsA(isA<SecureStoreDismissed>()),
      );
    });

    test('strict-init failure ($tag): write surfaces sanitized copy, '
        'no raw leak', () async {
      final strong = _ScriptedSecure()..writeError = StateError(shape);
      final cred = _ScriptedSecure()..writeError = StateError(shape);
      final store = SecureDeviceStore(secure: strong, fallbackSecure: cred);

      Object? caught;
      try {
        await store.writeEnrollment(_doc());
      } catch (e) {
        caught = e;
      }
      expect(caught, isStateError);
      expect('$caught', contains('Secure storage rejected the save'));
      expect('$caught', isNot(contains('Key mismatch')));
      expect('$caught', isNot(contains('Invalid key')));
      expect('$caught', isNot(contains('PlatformException')));
      expect('$caught', isNot(contains('UserNotAuthenticated')));
    });
  }

  test('strict-init failure: immediate retry respects the cooldown '
      '(no prompt hammer)', () async {
    final strong = _ScriptedSecure()..readError = StateError(_strictInitFailure);
    final cred = _ScriptedSecure()..readError = StateError(_strictInitFailure);
    final store = SecureDeviceStore(secure: strong, fallbackSecure: cred);

    await expectLater(
      store.readEnrollment(),
      throwsA(isA<SecureStoreDismissed>()),
    );
    final strongTouches = strong.readKeys.length;
    final credTouches = cred.readKeys.length;
    await expectLater(
      store.readEnrollment(),
      throwsA(isA<SecureStoreDismissed>()),
    );
    expect(strong.readKeys, hasLength(strongTouches));
    expect(cred.readKeys, hasLength(credTouches));
  });
}
