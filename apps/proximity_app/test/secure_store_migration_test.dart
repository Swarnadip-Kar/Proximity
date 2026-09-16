// SecureDeviceStore SE fixes: hardened options are actually wired (not just
// defined). Fresh-only: unknown at-rest keys are ignored, sealed-only docs
// read with no rewrite.
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

Map<String, dynamic> _doc({String sealedKeyHex = ''}) => {
      'email': 'a@x.in',
      'name': 'A',
      'roll': '1',
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

  test('unknown at-rest keys are ignored (no rewrite)', () async {
    final fake = _FakeSecure();
    final doc = _doc(sealedKeyHex: 'deadbeef')..['seedHex'] = 'ab' * 32;
    fake.backend['prox.enrollment.v1'] = jsonEncode(doc);
    final store = SecureDeviceStore(secure: fake);

    final back = (await store.readEnrollment())!;
    expect(back.sealedKeyHex, 'deadbeef');
    expect(fake.writeCount, 0);
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
