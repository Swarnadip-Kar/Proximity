// Secure-store behavior: prompt-free single slot. Reads return null on
// clean miss (never throw for absence); platform failures throw a
// sanitized StateError (unknown/retryable, never empty); writes surface
// the sanitized persist copy with no raw platform text.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/security/secure_store_options.dart';
import 'package:proximity_app/core/sync/store/secure_store.dart';
import 'package:proximity_app/core/sync/store/store_base.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  test('single slot uses the prompt-free namespace', () {
    final storage = SecureDeviceStore().debugSecureStorageForTest;
    expect(storage.aOptions.toMap(), SecureStoreOptions.aOpts.toMap());
    expect(storage.aOptions.toMap()['storageNamespace'], 'prox_store');
  });

  test('roundtrip write/read + clearEnrollment', () async {
    final store = SecureDeviceStore(secure: _ScriptedSecure());
    expect(await store.readEnrollment(), isNull);
    await store.writeEnrollment(_doc());
    expect((await store.readEnrollment())?.email, 'a@x.in');
    await store.clearEnrollment();
    expect(await store.readEnrollment(), isNull);
  });

  test('corrupt doc reads as absent (re-enroll), never throws', () async {
    final fake = _ScriptedSecure()
      ..backend['prox.enrollment.v1'] = '{"email": 42}';
    final store = SecureDeviceStore(secure: fake);
    expect(await store.readEnrollment(), isNull);
  });

  test('read failure throws sanitized StateError (unknown, never empty)',
      () async {
    final fake = _ScriptedSecure()
      ..readError = StateError('PlatformException(Exception encountered, '
          'javax.crypto.IllegalBlockSizeException, null)');
    final store = SecureDeviceStore(secure: fake);
    Object? caught;
    try {
      await store.readEnrollment();
    } catch (e) {
      caught = e;
    }
    expect(caught, isStateError);
    expect('$caught', contains('temporarily unreadable'));
    expect('$caught', isNot(contains('PlatformException')));
    expect('$caught', isNot(contains('IllegalBlockSize')));
  });

  test('write failure throws sanitized copy, no raw stack', () async {
    final fake = _ScriptedSecure()
      ..writeError = StateError('PlatformException(Exception encountered, '
          'javax.crypto.BadPaddingException: pad, null)');
    final store = SecureDeviceStore(secure: fake);

    Object? caught;
    try {
      await store.writeEnrollment(_doc());
    } catch (e) {
      caught = e;
    }
    expect(caught, isStateError);
    expect('$caught', contains('Secure storage rejected the save'));
    expect('$caught', isNot(contains('PlatformException')));
    expect('$caught', isNot(contains('BadPadding')));
  });

  test('install id roundtrip; read failure throws (never mints over it)',
      () async {
    final fake = _ScriptedSecure();
    final store = SecureDeviceStore(secure: fake);
    expect(await store.readInstallId(), isNull);
    await store.writeInstallId('ab12cd34ef56ab78');
    expect(await store.readInstallId(), 'ab12cd34ef56ab78');

    fake.readError = StateError('disk I/O');
    Object? caught;
    try {
      await store.readInstallId();
    } catch (e) {
      caught = e;
    }
    expect(caught, isStateError);
  });
}
