// Proven-empty hints: auto reads skip the biometric-gated prompt when a
// value is KNOWN absent (fresh-install sign-in must not pop fingerprint
// for data that cannot exist); explicit retries always scan.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/security/secure_store_options.dart';
import 'package:proximity_app/core/sync/store/secure_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal in-memory FSS stand-in (counts slot reads = prompts).
class _MemSecure extends FlutterSecureStorage {
  _MemSecure()
      : super(
          aOptions: SecureStoreOptions.aOpts,
          iOptions: SecureStoreOptions.iOpts,
        );

  final Map<String, String?> backend = {};
  final List<String> readKeys = [];

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

const _enrollJson =
    '{"email":"a@x.in","name":"A","roll":"1","pkHex":"cdcd","enrolledAt":"2026-01-01T00:00:00.000Z"}';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('fresh install: auto reads prompt once, then never again', () async {
    final strong = _MemSecure();
    final cred = _MemSecure();
    final store = SecureDeviceStore(secure: strong, fallbackSecure: cred);

    // First auto read proves emptiness (one preferred-slot prompt).
    expect(await store.readEnrollment(), isNull);
    expect(await store.readInstallId(), isNull);
    expect(strong.readKeys, contains('prox.enrollment.v1'));

    // Second auto read on a fresh process: proven empty, zero prompts.
    // (Install-id always scans both slots on a PROBE — anti-fork — but
    // the hint means no probe runs at all here.)
    final repo = SecureDeviceStore(secure: strong, fallbackSecure: cred);
    strong.readKeys.clear();
    cred.readKeys.clear();
    expect(await repo.readEnrollment(), isNull);
    expect(await repo.readInstallId(), isNull);
    expect(strong.readKeys, isEmpty);
    expect(cred.readKeys, isEmpty);
  });

  test('explicit retry still finds data a false hint would hide', () async {
    final strong = _MemSecure();
    final cred = _MemSecure();
    final store = SecureDeviceStore(secure: strong, fallbackSecure: cred);

    // Proven empty first (hint false persisted).
    expect(await store.readEnrollment(), isNull);

    // Data appears out-of-band (tier-wipe shape: prefs and secure diverge).
    cred.backend['prox.enrollment.v1'] = _enrollJson;

    // Auto still reports empty (hint); explicit retry scans and recovers.
    expect(await store.readEnrollmentRetry(), isNotNull);
    expect((await store.readEnrollmentRetry())?.email, 'a@x.in');
  });

  test('write flips the hint: next auto read probes again', () async {
    final strong = _MemSecure();
    final cred = _MemSecure();
    final store = SecureDeviceStore(secure: strong, fallbackSecure: cred);

    expect(await store.readEnrollment(), isNull); // hint false now
    await store.writeInstallId('ab12cd34ef56ab78'); // hint true

    final repo = SecureDeviceStore(secure: strong, fallbackSecure: cred);
    strong.readKeys.clear();
    expect(await repo.readInstallId(), 'ab12cd34ef56ab78');
    expect(strong.readKeys, contains('prox.install.v1'));
  });
}
