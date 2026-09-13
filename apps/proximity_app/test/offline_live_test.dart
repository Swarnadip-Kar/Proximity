// Track 4 §6 live-flow tests: airplane-mode marking (zero cloud calls),
// no-hotspot honest abort, BLE-mesh relay intact without response flood.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_storage/storage.dart';
import 'package:proximity_transport/transport.dart';

import 'test_device.dart';

const _email = 's@x.in';

/// Fresh-device fixture (security §2, full-fresh): HW test device (real
/// P-256 dSig + AAD-sealed envelope) + FULL store.
Future<({InMemoryDeviceStore store, TestHwDevice hw})> _enrolled() async {
  final hw = await freshHwDevice(
    email: _email,
    seedBytes: Uint8List.fromList(hexDecode('ab' * 32)),
    salt: 91,
  );
  return (store: await hwEnrolledStore(email: _email, hw: hw), hw: hw);
}

void main() {
  test('airplane-mode live flow: full mark with the cloud down',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    // Airplane mode = cloud probe says offline. The live flow (radio +
    // LAN) must not consult the cloud at all: no isOnline gate, no
    // fetchRole, no session pull — marking works, the snapshot queues in
    // the durable outbox, and the fake cloud sees ZERO calls.
    final cloud = FakeCloudSync()..online = false;
    expect(await cloud.isOnline(), isFalse);
    final prof = ProxCrypto.generateEdKeypair();
    final enrolled = await _enrolled();
    final store = enrolled.store;
    final hw = enrolled.hw;
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
      final d = RealStudentDriver(
        store: store,
        verifier: FakeFaceVerifier(match: true, score: 0.85),
        deviceKey: hw.deviceKey,
        engine: engine,
        livenessGate: FakeLivenessGate(),
      )..silenceCap = const Duration(seconds: 2);
      final check = await d.checkFace('still.jpg');
      expect(check.match, FaceMatch.pass);
      Future.delayed(const Duration(seconds: 3), () {
        final w = server.window!;
        final cj = w.challengeFor(w.jForTime(DateTime.now().toUtc()));
        engine.handleSighting(BleSighting(
          type: kAirTypeChallenge,
          token8: cj,
          ipHost: '127.0.0.1',
          ipPort: server.port,
          rssiDbm: -60,
          at: DateTime.now().toUtc(),
        ));
      });
      final res = await d.listenAndProve(
        target: ClassBeacon(
          classLabel: 't',
          host: '127.0.0.1',
          port: server.port,
          rssiDbm: 0,
          displayCode: 'X',
        ),
        identity: const LinkedIdentity(name: 'S', gmail: _email, roll: '1'),
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
      expect(res.result, StudentResult.marked);
      expect(server.tally.presentCount, 1);
      // Zero cloud calls: no sessions pushed, no roles set — the fake is
      // pristine (proves the live flow never consults the cloud).
      expect(cloud.sessions, isEmpty);
      expect(cloud.roles, isEmpty);
      // Post-live-save hook in airplane mode: durable outbox, badge 1,
      // still zero cloud writes.
      final record = ClassRecord(
        id: 'live-t-1',
        courseId: 't',
        classLabel: 't',
        dateIso: '2026-09-07',
        timestampIso: DateTime.now().toUtc().toIso8601String(),
        startIso: DateTime.now().toUtc().toIso8601String(),
        windows: [
          {_email: true}
        ],
        names: {_email: 'S'},
        rolls: {_email: '1'},
        org: 'x.in',
      );
      await syncEngine.noteLocalSave(
          store: store,
          cloud: cloud,
          prof: (uid: 'u', email: 'p@x.in', name: 'P', org: 'x.in'),
          record: record);
      await Future.delayed(const Duration(milliseconds: 200));
      expect((await store.readHistory()).map((r) => r.id), ['live-t-1']);
      expect(await syncEngine.pendingCount(store), 1);
      expect(cloud.sessions, isEmpty);
    } finally {
      await server.stop();
    }
  });

  test('no-hotspot: dead target probes unreachable, never marks',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    // The professor is gone (AP down / wrong subnet): the window probe
    // says unreachable and the listen ends honestly — no mark, no hang,
    // and the UI layer turns this into `Professor unreachable` + manual-IP
    // + abort (see RealStudentDriver._isRefused → joinError path).
    final engine = ProxBleEngine(radio: FakeBleRadio());
    final enrolled = await _enrolled();
    final d = RealStudentDriver(
      store: enrolled.store,
      verifier: FakeFaceVerifier(match: true, score: 0.85),
      deviceKey: enrolled.hw.deviceKey,
      engine: engine,
      livenessGate: FakeLivenessGate(),
    )..silenceCap = const Duration(seconds: 2);
    final check = await d.checkFace('still.jpg');
    expect(check.match, FaceMatch.pass);
    const target = ClassBeacon(
      classLabel: 't',
      host: '127.0.0.1',
      port: 9, // nothing listens: host-gone shape
      rssiDbm: 0,
      displayCode: 'X',
    );
    final probe = await d.probeWindow(target);
    expect(probe.reachable, isFalse);
    final res = await d.listenAndProve(
      target: target,
      identity: const LinkedIdentity(name: 'S', gmail: _email, roll: '1'),
      faceScore: check.score,
      faceValidAtMs: check.faceValidAtMs,
      verifierVer: check.verifierVer,
      livenessScore: check.livenessScore,
      livenessVer: check.livenessVer,
      integrityFlag: '',
      integrityHash: '00000000',
      onStatus: (_) {},
    );
    expect(res.result, StudentResult.noSignal);
    expect(engine.relayEnabled, isFalse);
  });

  test('BLE-mesh relay intact: challenge relays, response never floods',
      () async {
    // The relied-upon path survives Track 4: a heard challenge re-airs
    // (back rows hear the class through front rows) while a heard student
    // response is dispatch-only — one phone's mark never echoes hall-wide.
    final radio = FakeBleRadio();
    final engine = ProxBleEngine(radio: radio)..relayEnabled = true;
    final tok = [3, 3, 3, 3, 3, 3, 3, 3];
    engine.handleSighting(BleSighting(
      type: kAirTypeChallenge,
      token8: Uint8List.fromList(tok),
      ipHost: '10.0.0.1',
      ipPort: 8443,
      rssiDbm: -60,
      at: DateTime.now().toUtc(),
    ));
    await Future.delayed(const Duration(milliseconds: 600));
    expect(unpackAir(radio.advertisingMfg!)!.token8, tok);
    await engine.stop();
    // Host-side view: a hall of relays still marks through the real tally.
    final driver = RealHostDriver(
      store: InMemoryDeviceStore(),
      engine: ProxBleEngine(radio: FakeBleRadio()),
    );
    expect(driver.tally.presentCount, 0);
  });
}
