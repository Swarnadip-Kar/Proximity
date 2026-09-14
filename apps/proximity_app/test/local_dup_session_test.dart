// Local same-face duplicate path, end to end: two/three stock-app phones
// carrying one holder face prove into one live window; the professor's
// phone red-flags every involved entry and auto-absents them by default
// (wins stashed + stripped, restorable), 1-tap override counts them again
// + exempts, teardown wipes session state, and the cloud write path
// carries statuses only (no vectors).
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/core/sync/sessions.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_transport/transport.dart';

import 'test_device.dart';

List<double> _vec(int seed) {
  final rng = Random(seed);
  final v =
      List<double>.generate(kFacePrintDim, (_) => rng.nextDouble() * 2 - 1);
  var n = 0.0;
  for (final x in v) {
    n += x * x;
  }
  return [for (final x in v) x / sqrt(n)];
}

/// Fresh-device fixture (security §2, full-fresh): HW test device (real
/// P-256 dSig + fake-DER chain) + AAD-sealed envelope + FULL store.
/// [salt] must differ per device (deterministic test keys).
Future<({InMemoryDeviceStore store, TestHwDevice hw})> _freshAs(
    String email, String seedByte, int salt) async {
  final hw = await freshHwDevice(
    email: email,
    seedBytes: Uint8List.fromList(hexDecode(seedByte * 32)),
    installId: 'inst-dup-$salt',
    salt: salt,
  );
  final store = await hwEnrolledStore(
    email: email,
    hw: hw,
    installId: 'inst-dup-$salt',
    faceId: 'face-$email',
  );
  return (store: store, hw: hw);
}

/// Test-root pins seen so far (one per fresh device): the host loopback
/// server ships production pins, so each mark re-points its test chain
/// gate at the accumulated test pins (closure substitutes — the server's
/// own pinset is untouched).
final List<Uint8List> _dupPins = [];

/// One full stock-app mark against the host's live loopback server: radio
/// challenge heard late (mirrors offline_live_test), fresh face, real
/// HTTPS prove carrying the LAN-only session vector.
///
/// Loopback air-gap bridge (test-only): each side has its own FakeBleRadio,
/// so the test re-airs both directions — the challenge into the student's
/// engine once (late, like a back row), and the student's response into
/// the HOST's engine every second per rotation (the host professors'
/// sighting the server gates on).
Future<StudentResult> _mark({
  required RealHostDriver host,
  required ProxBleEngine hostEngine,
  required InMemoryDeviceStore store,
  required TestHwDevice hw,
  required List<double> embedding,
  required String email,
}) async {
  final server = host.debugServer!;
  final port = server.port;
  // Fresh FULL proof: point the loopback server's test gate at every
  // test root pinned so far (including this device's; repeats harmless).
  _dupPins.addAll(hw.pins);
  server.testChainGate = ({
    required AttestationChain chain,
    required List<Uint8List> pinnedRootHashes,
    required Uint8List expectedChallenge,
    required Uint8List? expectedLeafPkD,
    required AttestationLevel level,
    String appAttestRawHex = '',
  }) =>
      testChainGate(
        chain: chain,
        pinnedRootHashes: List<Uint8List>.from(_dupPins),
        expectedChallenge: expectedChallenge,
        expectedLeafPkD: expectedLeafPkD,
        level: level,
      );
  final engine = ProxBleEngine(radio: FakeBleRadio());
  final d = RealStudentDriver(
    store: store,
    verifier: FakeFaceVerifier(
        match: true, score: 0.85, scriptedEmbedding: embedding),
    deviceKey: hw.deviceKey,
    engine: engine,
    livenessGate: FakeLivenessGate(),
  )..silenceCap = const Duration(seconds: 2);
  final check = await d.checkFace('still.jpg');
  if (check.match != FaceMatch.pass) return StudentResult.faceFailed;
  final airBridge = Timer.periodic(const Duration(seconds: 1), (_) {
    final w = server.window;
    if (w == null) return;
    final now = DateTime.now().toUtc();
    final cj = w.challengeFor(w.jForTime(now));
    hostEngine.handleSighting(BleSighting(
      type: kAirTypeResponse,
      token8: ProxCrypto.responseToken(cj, email.toLowerCase()),
      ipHost: '127.0.0.1',
      ipPort: port,
      rssiDbm: -55,
      at: now,
    ));
  });
  // Late + repeated (deduped by token): a one-shot injection is fragile
  // once several sequential marks shift sub-epochs under the test.
  final challengeBridge = Timer.periodic(const Duration(seconds: 1), (_) {
    final w = server.window;
    if (w == null) return;
    final now = DateTime.now().toUtc();
    engine.handleSighting(BleSighting(
      type: kAirTypeChallenge,
      token8: w.challengeFor(w.jForTime(now)),
      ipHost: '127.0.0.1',
      ipPort: port,
      rssiDbm: -60,
      at: now,
    ));
  });
  try {
    final res = await d.listenAndProve(
      target: ClassBeacon(
          classLabel: 't',
          host: '127.0.0.1',
          port: port,
          rssiDbm: 0,
          displayCode: 'X'),
      identity: LinkedIdentity(
          name: email.split('@').first.toUpperCase(), gmail: email, roll: '1'),
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
    return res.result;
  } finally {
    airBridge.cancel();
    challengeBridge.cancel();
  }
}

/// Hosting pair with a reachable engine (the test re-airs student
/// responses into [engine] — the loopback air-gap bridge in [_mark]).
({RealHostDriver host, ProxBleEngine engine}) _hosting() {
  final engine = ProxBleEngine(radio: FakeBleRadio());
  return (
    host: RealHostDriver(store: InMemoryDeviceStore(), engine: engine),
    engine: engine,
  );
}

/// Fails the test if any map key anywhere in [doc] is vector-shaped.
/// This is the grep-proof, in-code: cloud write paths must never see a
/// face vector under any key, present or future.
void _assertNoVectorKeys(Map<String, dynamic> doc) {
  const banned = {
    'vec',
    'faceVec',
    'faceVecB64',
    'embQ',
    'buckets',
    'embedding',
    'embeddings',
    'facePrint',
    'facePrints',
  };
  void walk(Object? node, String path) {
    if (node is Map) {
      for (final e in node.entries) {
        if (e.key is String && banned.contains((e.key as String))) {
          fail('vector-shaped key "${e.key}" reached cloud doc at $path');
        }
        walk(e.value, '$path.${e.key}');
      }
    } else if (node is List) {
      for (var i = 0; i < node.length; i++) {
        walk(node[i], '$path[$i]');
      }
    } else if (node is String && node.length == 684) {
      // 684 chars is exactly a base64 int8 512-d vector — no legit cloud
      // field looks like that.
      fail('vector-shaped 684-char string reached cloud doc at $path');
    }
  }

  walk(doc, '\$');
}

void main() {
  group('local same-face session (professor phone, in-memory)', () {
    test('pair flags: server accepts, prof auto-absents, red groups',
        timeout: const Timeout(Duration(minutes: 3)), () async {
      final (:host, :engine) = _hosting();
      await host.startHosting(classLabel: 't', port: 0);
      await host.startWindow(1);
      try {
        final face = _vec(5);
        final fa = await _freshAs('a@x.in', 'a1', 101);
        final fb = await _freshAs('b@x.in', 'b2', 102);
        expect(
            await _mark(
                host: host,
                hostEngine: engine,
                store: fa.store,
                hw: fa.hw,
                embedding: face,
                email: 'a@x.in'),
            StudentResult.marked);
        expect(
            await _mark(
                host: host,
                hostEngine: engine,
                store: fb.store,
                hw: fb.hw,
                embedding: face,
                email: 'b@x.in'),
            StudentResult.marked);
        // Server accepted both proves (student badges read marked)…
        // …but the professor auto-absents the pair by default: wins
        // stashed + stripped, both flagged with a symmetric group.
        expect(host.tally.presentCount, 0);
        expect(host.tally.winsOf('a@x.in'), isEmpty);
        expect(host.tally.winsOf('b@x.in'), isEmpty);
        expect(host.tally.flaggedEmails, ['a@x.in', 'b@x.in']);
        expect(host.dupGroups['a@x.in'], {'b@x.in'});
        expect(host.dupGroups['b@x.in'], {'a@x.in'});
      } finally {
        await host.endHosting();
      }
      // Teardown wipes session state: no groups survive hosting end.
      expect(host.dupGroups, isEmpty);
    });

    test('triple flags all three; stranger stays clean',
        timeout: const Timeout(Duration(minutes: 4)), () async {
      final (:host, :engine) = _hosting();
      await host.startHosting(classLabel: 't', port: 0);
      await host.startWindow(1);
      try {
        final face = _vec(5);
        final addrs = ['a@x.in', 'b@x.in', 'c@x.in'];
        final devs = <String, ({InMemoryDeviceStore store, TestHwDevice hw})>{};
        var salt = 103;
        for (final e in addrs) {
          devs[e] = await _freshAs(e, 'a1', salt++);
        }
        for (final e in addrs) {
          expect(
              await _mark(
                  host: host,
                  hostEngine: engine,
                  store: devs[e]!.store,
                  hw: devs[e]!.hw,
                  embedding: face,
                  email: e),
              StudentResult.marked);
        }
        final fs = await _freshAs('s@x.in', 'c3', 106);
        expect(
            await _mark(
                host: host,
                hostEngine: engine,
                store: fs.store,
                hw: fs.hw,
                embedding: _vec(6),
                email: 's@x.in'),
            StudentResult.marked);
        // Triple auto-absent; the stranger still counts.
        expect(host.tally.presentCount, 1);
        expect(host.tally.flaggedEmails, ['a@x.in', 'b@x.in', 'c@x.in']);
        expect(host.dupGroups['c@x.in'], {'a@x.in', 'b@x.in'});
        expect(host.dupGroups['s@x.in'], isNot(contains('a@x.in')));
      } finally {
        await host.endHosting();
      }
    });

    test('override clears the group and exempts the pair next round',
        timeout: const Timeout(Duration(minutes: 4)), () async {
      final (:host, :engine) = _hosting();
      host.scanLinger = const Duration(milliseconds: 300);
      await host.startHosting(classLabel: 't', port: 0);
      await host.startWindow(1);
      try {
        final face = _vec(5);
        final devs = <String, ({InMemoryDeviceStore store, TestHwDevice hw})>{};
        var salt = 107;
        for (final e in ['a@x.in', 'b@x.in']) {
          devs[e] = await _freshAs(e, 'a1', salt++);
          expect(
              await _mark(
                  host: host,
                  hostEngine: engine,
                  store: devs[e]!.store,
                  hw: devs[e]!.hw,
                  embedding: face,
                  email: e),
              StudentResult.marked);
        }
        expect(host.tally.flaggedEmails, ['a@x.in', 'b@x.in']);
        expect(host.tally.presentCount, 0);
        // 1-tap override: flags gone, stashed wins re-marked (counts them).
        await host.resolveDupFlag('a@x.in');
        expect(host.tally.flaggedEmails, isEmpty);
        expect(host.dupGroups, isEmpty);
        expect(host.tally.presentCount, 2);
        // Retake: BOTH re-prove into a fresh vector map — the exempt pair
        // stays quiet while presence still counts.
        await host.stopWindow();
        await Future.delayed(const Duration(seconds: 1));
        await host.startWindow(2);
        salt = 109;
        for (final e in ['a@x.in', 'b@x.in']) {
          devs[e] = await _freshAs(e, 'a1', salt++);
          expect(
              await _mark(
                  host: host,
                  hostEngine: engine,
                  store: devs[e]!.store,
                  hw: devs[e]!.hw,
                  embedding: face,
                  email: e),
              StudentResult.marked);
        }
        expect(host.tally.flaggedEmails, isEmpty);
        expect(host.dupGroups, isEmpty);
      } finally {
        await host.endHosting();
      }
    });

    test('cloud write path carries statuses only — never vectors',
        timeout: const Timeout(Duration(minutes: 3)), () async {
      final (:host, :engine) = _hosting();
      await host.startHosting(classLabel: 't', port: 0);
      await host.startWindow(1);
      try {
        final face = _vec(5);
        var salt = 111;
        for (final e in ['a@x.in', 'b@x.in']) {
          final fdev = await _freshAs(e, 'a1', salt++);
          await _mark(
              host: host,
              hostEngine: engine,
              store: fdev.store,
              hw: fdev.hw,
              embedding: face,
              email: e);
        }
        expect(host.tally.flaggedEmails, ['a@x.in', 'b@x.in']);
        // Production snapshots after Stop (noteWindow), so close the round
        // first — otherwise the still-open round with stripped wins leaves
        // windowNos empty and the window map omits the keys entirely.
        await host.stopWindow();
        final record = host.tally.toClassRecord(
          courseId: 't',
          classLabel: 't',
          dateIso: '2026-09-08',
          timestampIso: DateTime.now().toUtc().toIso8601String(),
        );
        expect(record.faceFlags, ['a@x.in', 'b@x.in']);
        final doc = sessionToDoc(
          profUid: 'u',
          profEmail: 'p@x.in',
          profName: 'P',
          record: record,
        );
        // FLAGGED status present, marks dropped (absent, not vanished)…
        expect(doc['faceFlags'], ['a@x.in', 'b@x.in']);
        expect((doc['windows'] as List).single['a@x.in'], isFalse);
        // …and zero face data under any key, at any depth.
        _assertNoVectorKeys(doc);
        _assertNoVectorKeys(
            jsonDecode(jsonEncode(record.toJson())) as Map<String, dynamic>);
      } finally {
        await host.endHosting();
      }
    });

    test('stale-template proof still fails closed (no mark, no flag)',
        timeout: const Timeout(Duration(minutes: 3)), () async {
      final (:host, :engine) = _hosting();
      await host.startHosting(classLabel: 't', port: 0);
      await host.startWindow(1);
      try {
        // Enrolled under a foreign pipeline: the holder gate fails closed
        // before any vector could matter.
        final store = InMemoryDeviceStore();
        await store.writeEnrollment(StoredEnrollment(
          email: 'old@x.in',
          name: 'OLD',
          roll: '9',
          pkHex: 'cd' * 32,
          faceId: 'face-old@x.in',
          enrolledAt: DateTime.now().toUtc(),
          verifierVer: 'edgeface-xs-g06-tflite-1',
        ));
        // Throwaway HW device: the stale template fails at the holder
        // gate (checkFace → staleTemplate → faceFailed) before any key
        // is touched.
        final dummy = await _freshAs('old@x.in', 'ab', 113);
        final res = await _mark(
            host: host,
            hostEngine: engine,
            store: store,
            hw: dummy.hw,
            embedding: _vec(5),
            email: 'old@x.in');
        expect(res, isNot(StudentResult.marked));
        expect(host.tally.presentCount, 0);
        expect(host.tally.flaggedEmails, isEmpty);
        expect(host.dupGroups, isEmpty);
      } finally {
        await host.endHosting();
      }
    });
  });
}
