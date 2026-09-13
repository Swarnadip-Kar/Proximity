// Fresh-device fixtures for e2e prove tests (no legacy bodies confirm).
//
// A real-P-256 fake HW backend: genuine ECDSA dSig the professor verifies
// with real crypto, plus a fake-DER chain carrying the OID + recomputed V2
// challenge + pkD (verified through the REAL testChainGate stub —
// challenge/pkD containment + pin; X.509 signature math lives in protocol
// chain_verify_test on genuine fixtures). Mirrors transport_test's
// freshDevice. Test-only: never ships (dev_dependency pointycastle).
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:pointycastle/export.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/features/device_identity/hw_device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_protocol/protocol.dart';

/// Test installId (challenge binding input; stored + proved consistently).
const kTestInstallId = 'inst-e2e-1';

SecureRandom _testRand(int salt) {
  final r = SecureRandom('Fortuna');
  r.seed(KeyParameter(Uint8List.fromList(
      List.generate(32, (i) => (i * 11 + salt) & 0xFF))));
  return r;
}

/// Real-P-256 fake secure-hardware backend: genuine keys + genuine ECDSA,
/// fake-DER attestation chain embedding the enrollment challenge. Deterministic
/// per [salt] so parallel tests never share a key.
class TestHwBackend implements HwKeyBackend {
  final int salt;
  BigInt? _d;
  Uint8List? _pkD;
  Uint8List? _lastChallenge;
  Uint8List? _rootDer;
  List<Uint8List> _chain = const [];

  TestHwBackend({this.salt = 5});

  Uint8List get rootDer => Uint8List.fromList(_rootDer ?? Uint8List(0));

  @override
  Future<HwKeyHandle> generateKey(
      {required String alias, required Uint8List attestationChallenge}) async {
    final domain = ECDomainParameters('prime256v1');
    final gen = ECKeyGenerator()
      ..init(ParametersWithRandom(
          ECKeyGeneratorParameters(domain), _testRand(salt)));
    final pair = gen.generateKeyPair();
    _d = pair.privateKey.d!;
    final ECPublicKey pub = pair.publicKey;
    _pkD = Uint8List.fromList(pub.Q!.getEncoded(false).sublist(1));
    _lastChallenge = Uint8List.fromList(attestationChallenge);
    return HwKeyHandle(pkDRaw: Uint8List.fromList(_pkD!), level: AttestationLevel.full);
  }

  @override
  Future<HwKeyHandle?> getKeyInfo({required String alias}) async {
    if (_pkD == null) return null;
    return HwKeyHandle(
        pkDRaw: Uint8List.fromList(_pkD!), level: AttestationLevel.full);
  }

  @override
  Future<bool> containsKey({required String alias}) async => _pkD != null;

  @override
  Future<Uint8List> sign(
      {required String alias, required Uint8List payload}) async {
    final d = _d;
    if (d == null) throw StateError('no key (test)');
    final domain = ECDomainParameters('prime256v1');
    final signer = ECDSASigner(SHA256Digest())
      ..init(
          true,
          ParametersWithRandom(
              PrivateKeyParameter(ECPrivateKey(d, domain)),
              _testRand(salt + 1)));
    final sig = signer.generateSignature(payload) as ECSignature;
    Uint8List be(BigInt v) =>
        hexDecode(v.toRadixString(16).padLeft(64, '0'));
    return Uint8List.fromList([...be(sig.r), ...be(sig.s)]);
  }

  @override
  Future<List<Uint8List>> attest(
      {required String alias, required Uint8List serverNonce}) async {
    final pkD = _pkD;
    if (pkD == null) throw StateError('no key (test)');
    final leaf = Uint8List.fromList(
        [...kKeyAttestationOidDer, ...serverNonce, ...pkD, 0xAA, 0xBB]);
    _rootDer = Uint8List.fromList(
        List.generate(64, (i) => (i * 13 + salt) & 0xFF));
    _chain = [leaf, _rootDer!];
    return [for (final c in _chain) Uint8List.fromList(c)];
  }

  @override
  Future<void> deleteKey({required String alias}) async {
    _d = null;
    _pkD = null;
    _lastChallenge = null;
    _chain = const [];
  }
}

/// In-memory DEK store (one instance per device — a fresh instance models a
/// clone whose DEK never migrated).
class MemorySealStore implements HwSealStore {
  final Map<String, Uint8List> _deks = {};

  @override
  Future<Uint8List?> readDek({required String alias}) async =>
      _deks[alias] == null ? null : Uint8List.fromList(_deks[alias]!);

  @override
  Future<void> writeDek(
      {required String alias, required Uint8List dek32}) async {
    _deks[alias] = Uint8List.fromList(dek32);
  }

  @override
  Future<void> deleteDek({required String alias}) async {
    _deks.remove(alias);
  }
}

/// A bound test device: HW key enrolled (V2 challenge) + AAD-sealed SKey
/// envelope, ready to prove FULL against a server pinning [rootDer]. The
/// SKey seed is the single source: [pkS] derives from it, the enrollment
/// challenge binds it, and the seal wraps it — no mixed identities.
class TestHwDevice {
  final HwDeviceKey deviceKey;
  final TestHwBackend backend;
  final Uint8List pkS;
  final Uint8List pkD;
  final List<String> chainHex;
  final Uint8List rootDer;
  final Uint8List seedBytes;

  const TestHwDevice({
    required this.deviceKey,
    required this.backend,
    required this.pkS,
    required this.pkD,
    required this.chainHex,
    required this.rootDer,
    required this.seedBytes,
  });

  List<Uint8List> get pins => [ProxCrypto.sha256Sync(rootDer)];
}

/// Enrolls one test device: HW key bound to (email, installId, pkS) via the
/// V2 challenge + the SKey sealed AAD-bound under the same identity.
Future<TestHwDevice> freshHwDevice({
  required String email,
  Uint8List? seedBytes,
  String installId = kTestInstallId,
  int salt = 5,
}) async {
  final seed = seedBytes ?? randBytes(32);
  final pk = ed.public(ed.newKeyFromSeed(seed));
  final pkS = Uint8List.fromList(pk.bytes.sublist(0, 32));
  final backend = TestHwBackend(salt: salt);
  final device = HwDeviceKey(backend: backend, sealStore: MemorySealStore());
  await device.bindEnrollment(email: email, installId: installId, pkS: pkS);
  await device.sealWithAad(seed,
      aad: buildSealAad(
          emailLower: email,
          installId: installId,
          pkS: pkS,
          pkD: device.pkD));
  return TestHwDevice(
    deviceKey: device,
    backend: backend,
    pkS: pkS,
    pkD: device.pkD,
    chainHex: device.chainDERHex,
    rootDer: backend.rootDer,
    seedBytes: seed,
  );
}

/// Enrollment store matching [freshHwDevice]: FULL tier, pkD + chain bound,
/// AAD-sealed envelope, future window, same installId.
Future<InMemoryDeviceStore> hwEnrolledStore({
  required String email,
  required TestHwDevice hw,
  String installId = kTestInstallId,
  String verifierVer = kFaceVerifierVer,
  String faceId = 'face-test-id',
}) async {
  final s = InMemoryDeviceStore();
  await s.writeInstallId(installId);
  final sealed = await hw.deviceKey.sealWithAad(hw.seedBytes,
      aad: buildSealAad(
          emailLower: email,
          installId: installId,
          pkS: hw.pkS,
          pkD: hw.pkD));
  await s.writeEnrollment(StoredEnrollment(
    email: email,
    name: 'S',
    roll: '1',
    pkHex: hexEncode(hw.pkS),
    sealedKeyHex: hexEncode(sealed),
    chainDERHex: hw.chainHex,
    faceId: faceId,
    enrolledAt: DateTime.now().toUtc(),
    verifierVer: verifierVer,
    pkDHex: hexEncode(hw.pkD),
    attestationLevel: 'FULL',
    attestedAt: DateTime.now().toUtc().subtract(const Duration(days: 1)),
    attestedUntil:
        DateTime.now().toUtc().add(kDeviceAttestedValidity),
  ));
  return s;
}

/// Test-only chain gate for fake-DER fixtures (mirrors transport_test):
/// OID + challenge + pkD containment, then pin. No X.509 math.
ChainPinResult testChainGate({
  required AttestationChain chain,
  required List<Uint8List> pinnedRootHashes,
  required Uint8List expectedChallenge,
  required Uint8List? expectedLeafPkD,
  required AttestationLevel level,
}) {
  if (level == AttestationLevel.none) {
    return const ChainPinResult(
        ok: false, reason: 'level-none', flags: ['attest-level-none']);
  }
  if (chain.isEmpty) {
    return const ChainPinResult(
        ok: false, reason: 'empty-chain', flags: ['attest-empty-chain']);
  }
  final leaf = chain.leaf!;
  if (!attestationLeafHasKeyOid(leaf)) {
    return const ChainPinResult(
        ok: false,
        reason: 'missing-attestation-oid',
        flags: ['attest-missing-oid']);
  }
  if (expectedLeafPkD != null &&
      expectedLeafPkD.isNotEmpty &&
      !attestationLeafContainsChallenge(leaf, expectedLeafPkD)) {
    return const ChainPinResult(
        ok: false,
        reason: 'leaf-pkd-mismatch',
        flags: ['attest-leaf-pkd-mismatch']);
  }
  if (!attestationLeafContainsChallenge(leaf, expectedChallenge)) {
    return const ChainPinResult(
        ok: false,
        reason: 'challenge-mismatch',
        flags: ['attest-challenge-mismatch']);
  }
  final rootHash = ProxCrypto.sha256Sync(chain.root!);
  if (!pinnedRootHashes.any((h) => bytesEqual(h, rootHash))) {
    return const ChainPinResult(
        ok: false, reason: 'unknown-root', flags: ['attest-unknown-root']);
  }
  return const ChainPinResult(ok: true, reason: 'ok');
}
