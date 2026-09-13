// sec-hwkey-storage hardening pins (audit 2026-09-13).
//
// Covers the gaps closed in this pass:
// - ID-edit fallback path stays sealed-only (never re-persists a raw seed)
//   and preserves the face-rescan stamp.
// - Software keys cannot enroll (Software-no-enroll at the controller).
// - Sealed-only restore on a clone/invalidated key reports
//   'restore detected — re-enroll' (controller _tryRestore path).
// - Host legacy branch: corrupt raw hex falls back to the ephemeral
//   lecture identity (never a hosting crash); valid raw still derives.
// - Prompt-free DEK store stays unsynced/this-device-only on iOS.
// - Heartbeat never rolls the window on a dead (invalidated) HW key.
// - HW sign maps invalidation to restore-detected; auth cancellations
//   propagate untouched for re-prompt.
// - bindEnrollment challenge binds lowercased email + install + pkS.
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/features/device_identity/hw_device_key.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';

const _acct =
    SignedAccount(email: 'a@gmail.com', displayName: 'A', uid: 'ua');

// --- Minimal HwKeyBackend / HwSealStore fakes (mirrors hw_device_key_test).

class _Backend implements HwKeyBackend {
  AttestationLevel level = AttestationLevel.full;
  final Uint8List pkD;
  Uint8List? lastChallenge;
  List<Uint8List> chain = const [];
  bool gone = false;

  /// When set, sign() throws it (models plugin errors).
  Object? signError;

  _Backend({Uint8List? pkD})
      : pkD = pkD ?? Uint8List.fromList(List.generate(64, (i) => i & 0xFF));

  @override
  Future<HwKeyHandle> generateKey(
      {required String alias,
      required Uint8List attestationChallenge}) async {
    lastChallenge = Uint8List.fromList(attestationChallenge);
    gone = false;
    return HwKeyHandle(pkDRaw: Uint8List.fromList(pkD), level: level);
  }

  @override
  Future<HwKeyHandle?> getKeyInfo({required String alias}) async {
    if (gone || lastChallenge == null) return null;
    return HwKeyHandle(pkDRaw: Uint8List.fromList(pkD), level: level);
  }

  @override
  Future<bool> containsKey({required String alias}) async => !gone;

  @override
  Future<Uint8List> sign(
      {required String alias, required Uint8List payload}) async {
    if (signError != null) throw signError!;
    final h1 = ProxCrypto.sha256Sync([...payload, ...pkD]);
    final h2 = ProxCrypto.sha256Sync([...pkD, ...payload]);
    return Uint8List.fromList([...h1, ...h2]);
  }

  @override
  Future<List<Uint8List>> attest(
      {required String alias, required Uint8List serverNonce}) async {
    chain = [Uint8List.fromList([...serverNonce, 0x06])];
    return [for (final c in chain) Uint8List.fromList(c)];
  }

  @override
  Future<void> deleteKey({required String alias}) async {
    gone = true;
    lastChallenge = null;
    chain = const [];
  }
}

class _Seal implements HwSealStore {
  final Map<String, Uint8List> deks = {};
  @override
  Future<Uint8List?> readDek({required String alias}) async =>
      deks[alias] == null ? null : Uint8List.fromList(deks[alias]!);
  @override
  Future<void> writeDek(
          {required String alias, required Uint8List dek32}) async =>
      deks[alias] = Uint8List.fromList(dek32);
  @override
  Future<void> deleteDek({required String alias}) async =>
      deks.remove(alias);
}

EnrollmentController _ctl(FakeAuthService auth, InMemoryDeviceStore store,
        {DeviceKey? deviceKey}) =>
    EnrollmentController(
      auth: auth,
      store: store,
      verifier: FakeFaceVerifier(),
      deviceKey: deviceKey ?? FakeDeviceKey(),
      livenessGate: FakeLivenessGate(),
    );

void main() {
  group('ID-edit roll rewrite stays sealed-only', () {
    test('updateLocalRoll wipes raw seed, keeps envelope + rescan stamp',
        () async {
      final store = InMemoryDeviceStore();
      await store.writeEnrollment(StoredEnrollment(
        email: 'a@gmail.com',
        name: 'A',
        roll: '1',
        seedHex: 'ab' * 32,
        pkHex: 'cd' * 32,
        sealedKeyHex: 'deadbeef',
        chainDERHex: const ['ca11'],
        faceId: 'f',
        enrolledAt: DateTime.utc(2026, 1, 1),
        verifierVer: 'v',
        pkDHex: 'ee' * 32,
        attestationLevel: 'FULL',
        attestedAt: DateTime.utc(2026, 1, 1),
        attestedUntil: DateTime.utc(2026, 4, 1),
        lastFaceRescanAtMillis: 123456789,
      ));
      final ctl = _ctl(FakeAuthService(_acct), store);
      await ctl.updateLocalRoll('2');
      final back = (await store.readEnrollment())!;
      expect(back.roll, '2');
      // ignore: deprecated_member_use_from_same_package
      expect(back.seedHex, isEmpty);
      expect(back.sealedKeyHex, 'deadbeef');
      expect(back.chainDERHex, const ['ca11']);
      expect(back.pkDHex, 'ee' * 32);
      expect(back.lastFaceRescanAtMillis, 123456789);
    });
  });

  group('Software-no-enroll at the controller', () {
    test('generateKey with a software key refuses with Software-no-enroll',
        () async {
      final auth = FakeAuthService(_acct);
      final store = InMemoryDeviceStore();
      final ctl = _ctl(auth, store, deviceKey: SoftwareDeviceKey());
      await ctl.signIn();
      await ctl.generateKey();
      expect(ctl.state.phase, EnrollPhase.error);
      expect(ctl.state.message, contains('Software-no-enroll'));
    });
  });

  group('sealed-only restore on clone', () {
    test('_tryRestore reports restore detected after dropKey', () async {
      final deviceKey = FakeDeviceKey();
      final sealed =
          hexEncode(await deviceKey.seal(Uint8List.fromList(List.filled(32, 3))));
      final store = InMemoryDeviceStore();
      await store.writeEnrollment(StoredEnrollment(
        email: 'a@gmail.com',
        name: 'A',
        roll: '1',
        seedHex: '',
        pkHex: 'cd' * 32,
        sealedKeyHex: sealed,
        faceId: 'face-1',
        enrolledAt: DateTime.utc(2026, 1, 1),
        verifierVer: FakeFaceVerifier().verifierVer,
      ));
      deviceKey.dropKey(); // clone: fresh key cannot open the envelope
      final ctl = _ctl(FakeAuthService(_acct), store, deviceKey: deviceKey);
      await ctl.pickUpAccount();
      expect(ctl.state.message, contains('restore detected — re-enroll'));
    });
  });

  group('host legacy seed branch', () {
    RealHostDriver makeDriver({DeviceStore? store}) => RealHostDriver(
          store: store ?? InMemoryDeviceStore(),
          engine: ProxBleEngine(radio: FakeBleRadio()),
        );

    Future<InMemoryDeviceStore> storeWith(String seedHex) async {
      final store = InMemoryDeviceStore();
      await store.writeEnrollment(StoredEnrollment(
        email: 'prof@x.in',
        name: 'Prof',
        roll: '',
        seedHex: seedHex,
        pkHex: 'cd' * 32,
        enrolledAt: DateTime.utc(2026, 9, 1),
      ));
      return store;
    }

    test('corrupt raw hex falls back to ephemeral (hosting still starts)',
        () async {
      final driver = makeDriver(store: await storeWith('zzzz-not-hex'));
      await driver.startHosting(classLabel: 'CS101', port: 0);
      expect(driver.isHosting, isTrue);
      await driver.endHosting();
    });

    test('valid legacy raw seed still derives the hosting identity',
        () async {
      final driver = makeDriver(store: await storeWith('ab' * 32));
      await driver.startHosting(classLabel: 'CS101', port: 0);
      expect(driver.isHosting, isTrue);
      await driver.endHosting();
    });
  });

  group('DEK store posture (prompt-free, unsynced, this-device-only)', () {
    test('FlutterSealStore iOS options never sync', () {
      const seal = FlutterSealStore();
      expect(seal.storage.iOptions.synchronizable, isFalse);
      expect(seal.storage.iOptions.accessibility,
          KeychainAccessibility.first_unlock_this_device);
    });

    test('FlutterSealStore Android options stay prompt-free by design', () {
      // The enrollment doc (SecureStoreOptions.aOpts) is biometric-gated;
      // the DEK must NOT be: every 5s prove rotation unseals, and use is
      // already gated by the 4h HW-key grant + the face check.
      const seal = FlutterSealStore();
      expect(seal.storage.aOptions, isA<AndroidOptions>());
      expect(seal.storage.aOptions.toMap()['enforceBiometrics'], 'false');
    });
  });

  group('heartbeat + invalidation mapping', () {
    test('heartbeat is false once the HW key is gone', () async {
      final backend = _Backend();
      final d = HwDeviceKey(backend: backend, sealStore: _Seal());
      await d.bindEnrollment(
          email: 's@x.in',
          installId: 'i',
          pkS: Uint8List.fromList(List.filled(32, 1)));
      expect(await d.heartbeat(), isTrue);
      await backend.deleteKey(alias: kHwDeviceKeyAlias);
      expect(await d.heartbeat(), isFalse);
      final sealed = sealWithDek(
          dek32: Uint8List.fromList(List.filled(32, 9)),
          seed32: Uint8List.fromList(List.filled(32, 9)));
      expect(() => d.unseal(sealed),
          throwsA(isStateError.having((e) => e.message, 'message',
              contains('restore detected — re-enroll'))));
    });

    test('sign maps invalidation to restore-detected', () async {
      final backend = _Backend()
        ..signError = Exception('KeyPermanentlyInvalidatedException');
      final d = HwDeviceKey(backend: backend, sealStore: _Seal());
      await d.bindEnrollment(
          email: 's@x.in',
          installId: 'i',
          pkS: Uint8List.fromList(List.filled(32, 1)));
      expect(
          () => d.sign(Uint8List.fromList([1, 2, 3])),
          throwsA(isStateError.having((e) => e.message, 'message',
              contains('restore detected — re-enroll'))));
    });

    test('sign propagates auth cancellation untouched (re-prompt)', () async {
      final backend = _Backend()
        ..signError = Exception('UserNotAuthenticatedError: cancelled');
      final d = HwDeviceKey(backend: backend, sealStore: _Seal());
      await d.bindEnrollment(
          email: 's@x.in',
          installId: 'i',
          pkS: Uint8List.fromList(List.filled(32, 1)));
      expect(
          () => d.sign(Uint8List.fromList([1, 2, 3])),
          throwsA(predicate((Object e) =>
              e.toString().contains('UserNotAuthenticatedError') &&
              !e.toString().contains('restore detected'))));
    });
  });

  group('bindEnrollment challenge binding', () {
    test('email case-insensitive, install/pkS-sensitive', () async {
      final a = _Backend();
      final d1 = HwDeviceKey(backend: a, sealStore: _Seal());
      final pkS = Uint8List.fromList(List.filled(32, 5));
      await d1.bindEnrollment(
          email: 'Student@Example.COM', installId: 'inst-1', pkS: pkS);
      final mixed = Uint8List.fromList(a.lastChallenge!);

      final b = _Backend();
      final d2 = HwDeviceKey(backend: b, sealStore: _Seal());
      await d2.bindEnrollment(
          email: 'student@example.com', installId: 'inst-1', pkS: pkS);
      expect(b.lastChallenge, mixed);

      final c = _Backend();
      final d3 = HwDeviceKey(backend: c, sealStore: _Seal());
      await d3.bindEnrollment(
          email: 'student@example.com', installId: 'inst-2', pkS: pkS);
      expect(c.lastChallenge, isNot(mixed));
    });
  });
}
