// SecureDeviceStore SE fixes: hardened options are actually wired (not just
// defined) + one-shot sealed+raw → raw-wiped migration on read.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/security/secure_store_options.dart';
import 'package:proximity_app/core/sync/store/secure_store.dart';

/// In-memory FlutterSecureStorage stand-in (platform channels are
/// unavailable in unit tests; SecureDeviceStore takes any instance).
class _FakeSecure extends FlutterSecureStorage {
  _FakeSecure()
      : super(
          aOptions: SecureStoreOptions.aOpts,
          iOptions: SecureStoreOptions.iOpts,
        );

  final Map<String, String?> backend = {};
  int writeCount = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      backend[key];

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
    writeCount++;
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

Map<String, dynamic> _doc({String seedHex = '', String sealedKeyHex = ''}) => {
      'email': 'a@x.in',
      'name': 'A',
      'roll': '1',
      'seedHex': seedHex,
      'pkHex': 'cd' * 32,
      'sealedKeyHex': sealedKeyHex,
      'enrolledAt': '2026-01-01T00:00:00.000Z',
    };

void main() {
  test('default storage uses hardened non-default options', () {
    final storage = SecureDeviceStore().debugSecureStorageForTest;
    // Wired to the §3 single source of truth …
    expect(storage.aOptions.toMap(), SecureStoreOptions.aOpts.toMap());
    expect(storage.iOptions.synchronizable, isFalse);
    expect(storage.iOptions.accessibility,
        KeychainAccessibility.first_unlock_this_device);
    // … not the dead-code defaults (`const FlutterSecureStorage()`).
    expect(storage.aOptions.toMap(),
        isNot(equals(const AndroidOptions().toMap())));
    expect(storage.iOptions.accessibility,
        isNot(IOSOptions.defaultOptions.accessibility));
  });

  test('sealed+raw doc is re-wiped on read (sealed wins)', () async {
    final fake = _FakeSecure();
    fake.backend['prox.enrollment.v1'] =
        jsonEncode(_doc(seedHex: 'ab' * 32, sealedKeyHex: 'deadbeef'));
    final store = SecureDeviceStore(secure: fake);

    final back = (await store.readEnrollment())!;
    expect(back.sealedKeyHex, 'deadbeef');
    // ignore: deprecated_member_use_from_same_package
    expect(back.seedHex, isEmpty); // wiped in memory too
    expect(fake.writeCount, 1);

    final atRest =
        jsonDecode(fake.backend['prox.enrollment.v1']!) as Map<String, dynamic>;
    expect(atRest['seedHex'], isEmpty);
    expect(atRest['sealedKeyHex'], 'deadbeef');

    // One-shot: a second read rewrites nothing.
    await store.readEnrollment();
    expect(fake.writeCount, 1);
  });

  test('pure-legacy raw-only doc stays readable and is never rewritten',
      () async {
    final fake = _FakeSecure();
    fake.backend['prox.enrollment.v1'] =
        jsonEncode(_doc(seedHex: 'ab' * 32));
    final store = SecureDeviceStore(secure: fake);

    final back = (await store.readEnrollment())!;
    expect(back.email, 'a@x.in');
    expect(back.sealedKeyHex, isEmpty);
    // Still parseable for the host ephemeral fallback …
    // ignore: deprecated_member_use_from_same_package
    expect(back.seedHex, 'ab' * 32);
    // … but never re-persisted.
    expect(fake.writeCount, 0);
    final atRest =
        jsonDecode(fake.backend['prox.enrollment.v1']!) as Map<String, dynamic>;
    expect(atRest['seedHex'], 'ab' * 32);
  });

  test('sealed-only doc reads with no rewrite', () async {
    final fake = _FakeSecure();
    fake.backend['prox.enrollment.v1'] =
        jsonEncode(_doc(sealedKeyHex: 'deadbeef'));
    final store = SecureDeviceStore(secure: fake);

    final back = (await store.readEnrollment())!;
    expect(back.sealedKeyHex, 'deadbeef');
    expect(fake.writeCount, 0);
  });
}
