// Secure-store crypto recovery: the field "Save failed:
// PlatformException(...IllegalBlockSizeException... at
// yb0.onSuccess ... BiometricPrompt.onAuthenticationSucceeded)" must never
// reach the UI, and the cred slot must live in its own namespace.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/security/secure_store_options.dart';
import 'package:proximity_app/core/sync/store/secure_store.dart';
import 'package:proximity_app/core/sync/store/store_base.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Verbatim shape of the field failure (post-auth app-key unwrap in
/// FSS v11 `StorageCipherImplementationAES23`).
const _fieldError =
    'PlatformException(Exception encountered, '
    'javax.crypto.IllegalBlockSizeException, java.lang.Exception: '
    'javax.crypto.IllegalBlockSizeException, null)';

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
  final List<String> writtenKeys = [];
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
    writtenKeys.add(key);
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
    SecureStoreOptions.usedCredentialFallback = false;
    SharedPreferences.setMockInitialValues({});
  });

  test('strong-slot IllegalBlockSize write falls back and stays honest',
      () async {
    final strong = _ScriptedSecure()..writeError = StateError(_fieldError);
    final cred = _ScriptedSecure();
    final store = SecureDeviceStore(secure: strong, fallbackSecure: cred);

    await store.writeEnrollment(_doc());

    expect(cred.backend['prox.enrollment.v1'], isNotNull);
    expect(SecureStoreOptions.usedCredentialFallback, isTrue);
    // Corrupted entry best-effort cleared before switching slots.
    expect(strong.deletedKeys, contains('prox.enrollment.v1'));
  });

  test('read serves the answering slot when strong throws crypto', () async {
    final strong = _ScriptedSecure()..readError = StateError(_fieldError);
    final cred = _ScriptedSecure()
      ..backend['prox.install.v1'] = 'ab12cd34ef56ab78';
    final store = SecureDeviceStore(secure: strong, fallbackSecure: cred);

    expect(await store.readInstallId(), 'ab12cd34ef56ab78');
    // Tier flipped AND persisted: a fresh process skips the dead strong
    // slot entirely (no prompt there) and serves from cred.
    final repo = SecureDeviceStore(secure: strong, fallbackSecure: cred);
    expect(await repo.readInstallId(), 'ab12cd34ef56ab78');
    expect(strong.readKeys, hasLength(1)); // the first failed attempt only
  });

  test('both slots failing throws sanitized copy, no raw stack', () async {
    final strong = _ScriptedSecure()..writeError = StateError(_fieldError);
    final cred = _ScriptedSecure()
      ..writeError = StateError('javax.crypto.BadPaddingException: pad');
    final store = SecureDeviceStore(secure: strong, fallbackSecure: cred);

    Object? caught;
    try {
      await store.writeEnrollment(_doc());
    } catch (e) {
      caught = e;
    }
    expect(caught, isStateError);
    final msg = '$caught';
    expect(msg, contains('Secure storage rejected the save'));
    expect(msg, isNot(contains('PlatformException')));
    expect(msg, isNot(contains('IllegalBlockSize')));
    expect(msg, isNot(contains('yb0')));
  });

  test('non-crypto errors rethrow untouched (no slot switch)', () async {
    final strong = _ScriptedSecure()
      ..writeError = StateError('disk full (no space left)');
    final cred = _ScriptedSecure();
    final store = SecureDeviceStore(secure: strong, fallbackSecure: cred);

    await expectLater(
      store.writeEnrollment(_doc()),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('disk full'),
        ),
      ),
    );
    expect(cred.writtenKeys, isEmpty);
    expect(SecureStoreOptions.usedCredentialFallback, isFalse);
  });

  test('tier sticks to the live slot (one prompt in steady state)', () async {
    final strong = _ScriptedSecure()..writeError = StateError(_fieldError);
    final cred = _ScriptedSecure();
    final store = SecureDeviceStore(secure: strong, fallbackSecure: cred);

    await store.writeEnrollment(_doc());
    // Strong slot heals later — the store must still lead with cred.
    strong.writeError = null;
    await store.writeInstallId('ab12cd34ef56ab78');

    expect(strong.writtenKeys, hasLength(1)); // the first failed attempt only
    expect(cred.writtenKeys, hasLength(2));
  });

  test('tier hint loads from prefs (fresh process skips the dead slot)',
      () async {
    SharedPreferences.setMockInitialValues({'prox.secure.tier.v1': 'cred'});
    final strong = _ScriptedSecure();
    final cred = _ScriptedSecure();
    final store = SecureDeviceStore(secure: strong, fallbackSecure: cred);

    await store.writeInstallId('ab12cd34ef56ab78');

    expect(strong.writtenKeys, isEmpty);
    expect(cred.writtenKeys, hasLength(1));
    expect(SecureStoreOptions.usedCredentialFallback, isTrue);
  });

  test('clearEnrollment wipes both slots and resets tier', () async {
    final strong = _ScriptedSecure()..writeError = StateError(_fieldError);
    final cred = _ScriptedSecure();
    final store = SecureDeviceStore(secure: strong, fallbackSecure: cred);
    await store.writeEnrollment(_doc());
    expect(SecureStoreOptions.usedCredentialFallback, isTrue);

    strong.writeError = null;
    await store.clearEnrollment();
    expect(strong.backend, isEmpty);
    expect(cred.backend, isEmpty);

    await store.writeInstallId('ab12cd34ef56ab78');
    expect(strong.writtenKeys, contains('prox.install.v1'));
  });
}
