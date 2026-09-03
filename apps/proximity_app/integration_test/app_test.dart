// Two-device window (fakes) proving end-to-end mark + export signature verify.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_storage/storage.dart';
import 'package:proximity_transport/transport.dart';

void main() {
  test('P0 loop: BLE UUID heard → face (mock) → signed POST → ACK → CSV+SIG verifies',
      () async {
    // Professor sets up window.
    final profKeys = ProxCrypto.generateEdKeypair();
    final stuKeys = ProxCrypto.generateEdKeypair();
    const studentId = 'aarav@institute.ac.in'; // Gmail identity (no institute ID)
    final window = WindowParams(
      sessionId: randBytes(16),
      windowId: randBytes(6),
      secret: randBytes(32),
      t0: DateTime.now().toUtc(),
      classLabel: 'CS201-Room301',
    );
    const j = 0;
    final cj = window.challengeFor(j);

    // BLE: prof advertises UUID_P, student hears it (fake radios).
    final profRadio = FakeBleRadio();
    final stuRadio = FakeBleRadio();
    final profEngine = ProxBleEngine(radio: profRadio);
    Uint8List? heardCj;
    final stuEngine = ProxBleEngine(
      radio: stuRadio,
      onChallengeHeard: (s) {
        heardCj = UuidCodec.lo8Of(s.uuid);
      },
    );
    await profEngine.startProfRotation(window);
    await stuEngine.startScanning();
    // deliver advertisement prof → student
    stuRadio.inject(BleSighting(
      uuid: profRadio.advertisingUuid!,
      rssiDbm: -55,
      at: DateTime.now().toUtc(),
    ));
    expect(heardCj, isNotNull);
    expect(Uint8List.fromList(heardCj!), cj);

    // Face (mocked): holder passes, gate fresh.
    final gate = FaceGate();
    expect(
        gate.evaluate(score: 0.85, livenessPass: true, now: DateTime.now().toUtc()),
        FaceDecision.pass);
    gate.requireFreshForSign();

    // Student builds Sig_s + UUID_S + peerW; advertises response.
    final stuPk32 =
        Uint8List.fromList(stuKeys.publicKey.bytes.sublist(0, 32));
    final peerW = ProxCrypto.peerAlias(stuPk32, window.windowId);
    final sigS = ProxCrypto.signStudentProve(
      studentSk: stuKeys.privateKey,
      sessionId: window.sessionId,
      windowId: window.windowId,
      j: j,
      challenge: cj,
      studentId: studentId,
      faceScore: 0.85,
    );
    await stuEngine.advertiseStudentResponse(studentId, cj, j, peerW);
    expect(UuidCodec.isResponseUuid(stuRadio.advertisingUuid!), isTrue);

    // Professor verifies POST + BLE sighting (direct, -55 dBm).
    final once = SingleUseTracker();
    final now = DateTime.now().toUtc();
    final body = buildProveBody(
      id: studentId,
      windowId: window.windowId,
      j: j,
      challenge: cj,
      sigS: sigS,
      faceScore: 0.85,
      peerW: peerW,
    );
    expect(body['ID'], studentId);
    final outcome = verifyProve(
      req: VerifyRequest(
        id: studentId,
        windowId: window.windowId,
        j: j,
        cClaimed: cj,
        sigS: sigS,
        faceScore: 0.85,
        faceValidAt: now,
        peerW: peerW,
        rssiDbm: -55,
        relayHop: 0,
        now: now,
      ),
      expectedCj: cj,
      sessionId: window.sessionId,
      windowIdExpected: window.windowId,
      studentPk: stuKeys.publicKey,
      revoked: false,
      freshWindow: window.isFresh(j, now),
      singleUseOk: once.claim(studentId, j),
    );
    expect(outcome.decision, ProveDecision.confirmed);

    // Signed ACK.
    final ackSig = ProxCrypto.sign(
      profKeys.privateKey,
      ProxCrypto.ackPreimage(
        sessionId: window.sessionId,
        windowId: window.windowId,
        j: j,
        studentId: studentId,
        decision: 0,
        serverTimeMs: now.millisecondsSinceEpoch,
      ),
    );
    expect(
        ProxCrypto.verify(
          profKeys.publicKey,
          ProxCrypto.ackPreimage(
            sessionId: window.sessionId,
            windowId: window.windowId,
            j: j,
            studentId: studentId,
            decision: 0,
            serverTimeMs: now.millisecondsSinceEpoch,
          ),
          ackSig,
        ),
        isTrue);

    // Tally + export + detached sig verifies.
    final tally = TallyStore();
    tally.mark(studentId, 'Aarav S', 1);
    tally.mark(studentId, 'Aarav S', 2);
    final csv = tally.exportCsv(
        classLabel: 'CS201-Room301', dateIso: '2026-09-03');
    final csvSig = signExport(profKeys.privateKey, csv);
    expect(verifyExport(profKeys.publicKey, csv, csvSig), isTrue);

    await profEngine.stop();
    await stuEngine.stop();
  });
}
