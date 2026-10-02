// Prove-path identity failures on HW keys: missing install identity and
// DKey rotation fail with honest copies (not 'clone?'), and a genuine
// tag mismatch still fails closed as restore-detected with a classified
// log line. Uses the real-P-256 fake HW backend (test_device.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_transport/transport.dart';

import 'test_device.dart';

const _email = 'hw-prove@x.in';

FakeFaceVerifier _verifier() => FakeFaceVerifier(match: true, score: 0.85);

Future<InMemoryDeviceStore> _proveStore({
  required TestHwDevice hw,
  required String sealedInstallId,
  required String storedPkDHex,
  String? storeInstallId,
}) async {
  final s = InMemoryDeviceStore();
  if (storeInstallId != null) await s.writeInstallId(storeInstallId);
  final sealed = await hw.deviceKey.sealWithAad(hw.seedBytes,
      aad: buildSealAad(
          emailLower: _email,
          installId: sealedInstallId,
          pkS: hw.pkS,
          pkD: hw.pkD));
  await s.writeEnrollment(StoredEnrollment(
    email: _email,
    name: 'S',
    roll: '1',
    pkHex: hexEncode(hw.pkS),
    sealedKeyHex: hexEncode(sealed),
    faceId: 'face-test-id',
    enrolledAt: DateTime.now().toUtc(),
    verifierVer: kFaceVerifierVer,
    pkDHex: storedPkDHex,
    attestationLevel: 'FULL',
    attestedAt: DateTime.now().toUtc().subtract(const Duration(days: 1)),
    attestedUntil: DateTime.now().toUtc().add(kDeviceAttestedValidity),
  ));
  return s;
}

Future<MarkedReceipt> _driveOnce(
    {required InMemoryDeviceStore store, required TestHwDevice hw}) async {
  final engine = ProxBleEngine(radio: FakeBleRadio());
  final d = RealStudentDriver(
    store: store,
    verifier: _verifier(),
    deviceKey: hw.deviceKey,
    engine: engine,
    livenessGate: FakeLivenessGate(),
  );
  Future.delayed(const Duration(milliseconds: 300), () {
    engine.handleSighting(BleSighting(
      type: kAirTypeChallenge,
      token8: randBytes(8),
      ipHost: '127.0.0.1',
      ipPort: 9,
      rssiDbm: -60,
      at: DateTime.now().toUtc(),
    ));
  });
  return d.listenAndProve(
    target: const ClassBeacon(
      classLabel: 't',
      host: '127.0.0.1',
      port: 9,
      rssiDbm: 0,
      displayCode: 'X',
    ),
    identity: const LinkedIdentity(name: 'S', gmail: _email, roll: '1'),
    faceScore: 0.85,
    faceValidAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
    verifierVer: kFaceVerifierVer,
    onStatus: (_) {},
  );
}

void main() {
  setUp(() => BleLog.clear());

  test('missing install identity refuses honestly (not a clone)', () async {
    final hw = await freshHwDevice(email: _email);
    final store = await _proveStore(
      hw: hw,
      sealedInstallId: kTestInstallId,
      storedPkDHex: hexEncode(hw.pkD),
      storeInstallId: null, // identity wiped post-enroll
    );
    final res = await _driveOnce(store: store, hw: hw);
    expect(res.result, StudentResult.error);
    expect(res.detail, contains('Install identity missing — re-enroll'));
  });

  test('rotated DKey refuses honestly (not a clone)', () async {
    final hw = await freshHwDevice(email: _email);
    final store = await _proveStore(
      hw: hw,
      sealedInstallId: kTestInstallId,
      storedPkDHex: hexEncode(randBytes(64)), // another key's pkD
      storeInstallId: kTestInstallId,
    );
    final res = await _driveOnce(store: store, hw: hw);
    expect(res.result, StudentResult.error);
    expect(res.detail, contains('Device key changed — re-enroll'));
  });

  test('tag mismatch with complete inputs stays restore-detected', () async {
    final hw = await freshHwDevice(email: _email);
    final store = await _proveStore(
      hw: hw,
      sealedInstallId: 'inst-seal-A',
      storedPkDHex: hexEncode(hw.pkD),
      storeInstallId: 'inst-prove-B', // forked identity: AAD differs
    );
    final res = await _driveOnce(store: store, hw: hw);
    expect(res.result, StudentResult.error);
    expect(res.detail, contains('restore detected — re-enroll'));
    expect(
        BleLog.history.any((e) => e.msg.contains('tag-mismatch')), isTrue);
  });
}
