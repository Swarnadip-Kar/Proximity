// Secure-store crypto recovery: the field "Save failed:
// PlatformException(...IllegalBlockSizeException... at
// yb0.onSuccess ... BiometricPrompt.onAuthenticationSucceeded)" must never
// reach the UI, and the cred slot must live in its own namespace.
import 'dart:convert';

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

  /// Prompt-latency stand-in + overlap detector (prompt single-flight
  /// tests): concurrent slot readers must never overlap.
  Duration readDelay = Duration.zero;
  int activeReads = 0;
  int maxActiveReads = 0;

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
    activeReads++;
    if (activeReads > maxActiveReads) maxActiveReads = activeReads;
    try {
      if (readDelay > Duration.zero) await Future.delayed(readDelay);
      final e = readError;
      if (e != null) throw e;
      return backend[key];
    } finally {
      activeReads--;
    }
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

  test('clean miss on the preferred slot still serves the other slot',
      () async {
    // Reinstall shape: the unencrypted tier hint is wiped (prefers
    // strong) but the live doc sits in cred. A first-slot miss must not
    // report empty (that pushes a phantom enrollment over existing
    // data) — the scan continues and adopts the hitting slot.
    final strong = _ScriptedSecure();
    final cred = _ScriptedSecure()
      ..backend['prox.enrollment.v1'] = jsonEncode(_doc().toJson());
    final store = SecureDeviceStore(secure: strong, fallbackSecure: cred);

    final got = await store.readEnrollment();
    expect(got?.email, 'a@x.in');
    expect(strong.readKeys, contains('prox.enrollment.v1'));
    expect(cred.readKeys, contains('prox.enrollment.v1'));
    // Tier flipped AND persisted: a fresh process leads with cred and
    // never touches the dead strong slot (one prompt in steady state).
    final repo = SecureDeviceStore(secure: strong, fallbackSecure: cred);
    strong.readKeys.clear();
    expect((await repo.readEnrollment())?.email, 'a@x.in');
    expect(strong.readKeys, isEmpty);
  });

  test('clean miss on the preferred slot still serves the install id',
      () async {
    // Same reinstall shape for the install id: resolving null here would
    // mint a FRESH install over existing data (identity fork).
    final strong = _ScriptedSecure();
    final cred = _ScriptedSecure()
      ..backend['prox.install.v1'] = 'ab12cd34ef56ab78';
    final store = SecureDeviceStore(secure: strong, fallbackSecure: cred);

    expect(await store.readInstallId(), 'ab12cd34ef56ab78');
    expect(cred.readKeys, contains('prox.install.v1'));
  });

  test('concurrent enrollment reads cost one prompt total', () async {
    // Cold-open race shape (shell resolve + account entry firing
    // together): the slot readers serialize and the second serves the
    // warmed cache — one prompt, both callers unlocked, never a
    // prompt fight where the scanned prompt belongs to nobody.
    final strong = _ScriptedSecure()
      ..backend['prox.enrollment.v1'] = jsonEncode(_doc().toJson())
      ..readDelay = const Duration(milliseconds: 50);
    final cred = _ScriptedSecure()
      ..readDelay = const Duration(milliseconds: 50);
    final store = SecureDeviceStore(secure: strong, fallbackSecure: cred);

    final results = await Future.wait([
      store.readEnrollment(),
      store.readEnrollment(),
    ]);
    expect(results[0]?.email, 'a@x.in');
    expect(results[1]?.email, 'a@x.in');
    expect(strong.maxActiveReads, 1);
    expect(cred.maxActiveReads, 0); // hit on strong: cred never touched
    expect(cred.readKeys, isEmpty);
    // Second reader served the warmed cache: the preferred slot was
    // touched exactly once (one prompt total, not two).
    expect(strong.readKeys, hasLength(1));
  });

  test('concurrent failures prompt once and never wedge the chain',
      () async {
    // Both readers fail behind the prompt gate: the first coolstamps,
    // the queued second respects the cooldown (no re-prompt of a
    // just-dismissed user), both report dismissed — and a later
    // explicit retry still runs (the chain never carries errors).
    final strong = _ScriptedSecure()
      ..readError = StateError('user canceled')
      ..readDelay = const Duration(milliseconds: 50);
    final cred = _ScriptedSecure()
      ..readError = StateError('user canceled')
      ..readDelay = const Duration(milliseconds: 50);
    final store = SecureDeviceStore(secure: strong, fallbackSecure: cred);

    final outcomes = await Future.wait([
      store.readEnrollment().then((_) => 'value', onError: (e) => '$e'),
      store.readEnrollment().then((_) => 'value', onError: (e) => '$e'),
    ]);
    for (final o in outcomes) {
      expect(o, contains('dismissed'));
    }
    // One prompt total: the first skip stops its scan (no fall-through
    // to the other slot), and the queued reader respects the cooldown.
    expect(strong.readKeys, hasLength(1));
    expect(cred.readKeys, isEmpty);
    // Explicit retry still runs the slots (chain unwedged) — once.
    await expectLater(
      store.readEnrollmentRetry(),
      throwsA(isA<SecureStoreDismissed>()),
    );
    expect(strong.readKeys, hasLength(2));
    expect(cred.readKeys, isEmpty);
  });

  test('crypto mismatch still falls through to the live slot on read',
      () async {
    // Dismissal-stop must not break recovery: a slot that genuinely
    // cannot unwrap (post-auth cipher failure, NOT a user skip) still
    // hands off to the other slot, which serves.
    final strong = _ScriptedSecure()..readError = StateError(_fieldError);
    final cred = _ScriptedSecure()
      ..backend['prox.enrollment.v1'] = jsonEncode(_doc().toJson());
    final store = SecureDeviceStore(secure: strong, fallbackSecure: cred);

    expect((await store.readEnrollment())?.email, 'a@x.in');
  });

  test('install-id skip stops the scan (no second prompt)', () async {
    final strong = _ScriptedSecure()
      ..readError = StateError('user canceled');
    final cred = _ScriptedSecure()
      ..backend['prox.install.v1'] = 'ab12cd34ef56ab78';
    final store = SecureDeviceStore(secure: strong, fallbackSecure: cred);

    await expectLater(
      store.readInstallId(),
      throwsA(isA<SecureStoreDismissed>()),
    );
    expect(strong.readKeys, hasLength(1));
    expect(cred.readKeys, isEmpty);
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

  test('system cancel (no user marker) is transient, never a dismissal park',
      () async {
    // Overlapping BiometricPrompts / activity destroy report bare
    // `canceled` with no user marker. That must NOT park as a user
    // dismissal (5s cooldown + unlock nudge) — it retries transiently.
    final strong = _ScriptedSecure()
      ..readError = StateError('Authentication canceled by system');
    final cred = _ScriptedSecure()
      ..readError = StateError('Authentication canceled by system');
    final store = SecureDeviceStore(secure: strong, fallbackSecure: cred);

    await expectLater(
      store.readEnrollment(),
      throwsA(isA<SecureStoreUnavailable>()),
    );
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
