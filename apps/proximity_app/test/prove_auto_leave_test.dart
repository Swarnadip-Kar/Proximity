// SYNC/TRANSITION-OWNED regression: marked-complete auto-exit at the
// transport layer. Widget-free on purpose: files that pump widgets run
// under TestWidgetsFlutterBinding, whose mock HttpClient answers 400 to
// every real request, so this loopback HTTPS test stays here with plain
// test() only (same split as student_driver_test.dart).
//
// The /prove verdict IS the waiting-area leave: after a confirmed mark the
// server's waiting count drops with zero extra requests (this test never
// calls leaveWaiting). Rewaits re-register via their normal presence POST.
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_transport/transport.dart';

import 'test_device.dart';

void main() {
  test('prove auto-leaves the server waiting room with zero extra requests',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    const email = 's@x.in';
    final prof = ProxCrypto.generateEdKeypair();
    final seed = randBytes(32);
    // Fresh FULL proof (HW test device + checkFace ticket + liveness).
    final hw = await freshHwDevice(email: email, seedBytes: seed, salt: 92);
    final store = await hwEnrolledStore(email: email, hw: hw);
    final server = ProxServer(
      classLabel: 't',
      profSk: prof.privateKey,
      profPk: prof.publicKey,
      sightings: (
              {required peerW,
              required expectedAirKey,
              required expectedUuid}) =>
          const RadioSighting(rssiDbm: -55, hop: 0),
      pinnedRoots: hw.pins,
      // ignore: cascade_invocations
    )..testChainGate = testChainGate;
    await server.start(port: 0);
    try {
      server.openWindow(
        WindowParams(
          sessionId: randBytes(16),
          windowId: randBytes(6),
          secret: randBytes(32),
          t0: DateTime.now().toUtc(),
          classLabel: 't',
        ),
        1,
      );
      final engine = ProxBleEngine(radio: FakeBleRadio());
      final driver = RealStudentDriver(
        store: store,
        verifier: FakeFaceVerifier(),
        deviceKey: hw.deviceKey,
        engine: engine,
        livenessGate: FakeLivenessGate(),
      );
      final check = await driver.checkFace('still.jpg');
      expect(check.match, FaceMatch.pass);
      final target = ClassBeacon(
        classLabel: 't',
        host: '127.0.0.1',
        port: server.port,
        rssiDbm: 0,
        displayCode: 'X',
      );
      const identity = LinkedIdentity(name: 'S', gmail: email, roll: '1');
      // Presence registers AND piggybacks the open-window sample.
      final sample =
          await driver.sendPresence(target: target, identity: identity);
      expect(sample.sent, isTrue);
      expect(sample.windowOpen, isTrue);
      expect(server.waitingCount, 1);
      // Live rotation over radio, then prove.
      Future.delayed(const Duration(milliseconds: 300), () {
        final w = server.window!;
        engine.handleSighting(BleSighting(
          type: kAirTypeChallenge,
          token8: w.challengeFor(w.jForTime(DateTime.now().toUtc())),
          ipHost: '127.0.0.1',
          ipPort: server.port,
          rssiDbm: -60,
          at: DateTime.now().toUtc(),
        ));
      });
      final receipt = await driver.listenAndProve(
        target: target,
        identity: identity,
        faceScore: check.score,
        faceValidAtMs: check.faceValidAtMs,
        verifierVer: check.verifierVer,
        livenessScore: check.livenessScore,
        livenessVer: check.livenessVer,
        // Clean verdict wire form (explicit → no native probe in tests).
        integrityFlag: '',
        integrityHash: '00000000',
        onStatus: (_) {},
      );
      expect(receipt.result, StudentResult.marked);
      expect(server.tally.presentCount, 1);
      // Auto-exit: the waiting entry is gone with NO explicit /leave call
      // anywhere in this test (the /prove verdict was the leave).
      expect(server.waitingCount, 0);
    } finally {
      await server.stop();
    }
  });
}
