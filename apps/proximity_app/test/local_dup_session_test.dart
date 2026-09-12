// Local same-face duplicate path, end to end: two/three stock-app phones
// carrying one holder face prove into one live window; the professor's
// phone flags every involved entry (presence kept), the roster copy stays
// neutral, 1-tap override resolves + exempts, teardown wipes session
// state, and the cloud write path carries statuses only (no vectors).
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/core/sync/sessions.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_transport/transport.dart';

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

/// Sealed-only fixture (security §2): DKey-sealed envelope, never raw seed.
Future<InMemoryDeviceStore> _enrolledAs(String email, String seedByte) async {
  final s = InMemoryDeviceStore();
  final sealed = hexEncode(await FakeDeviceKey()
      .seal(Uint8List.fromList(hexDecode(seedByte * 32))));
  await s.writeEnrollment(StoredEnrollment(
    email: email,
    name: email.split('@').first.toUpperCase(),
    roll: '1',
    seedHex: '',
    pkHex: 'cd' * 30 + seedByte * 2,
    sealedKeyHex: sealed,
    faceId: 'face-$email',
    enrolledAt: DateTime.now().toUtc(),
    verifierVer: kFaceVerifierVer,
  ));
  return s;
}

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
  required List<double> embedding,
  required String email,
}) async {
  // ignore: invalid_use_of_visible_for_testing
  final server = host.debugServer!;
  final port = server.port;
  final engine = ProxBleEngine(radio: FakeBleRadio());
  final d = RealStudentDriver(
    store: store,
    verifier: FakeFaceVerifier(
        match: true, score: 0.85, scriptedEmbedding: embedding),
    deviceKey: FakeDeviceKey(),
    engine: engine,
  )..silenceCap = const Duration(seconds: 2);
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
      faceScore: 0.9,
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
    test('pair flags: both marked, both flagged, neutral groups',
        timeout: const Timeout(Duration(minutes: 3)), () async {
      final (:host, :engine) = _hosting();
      await host.startHosting(classLabel: 't', port: 0);
      await host.startWindow(1);
      try {
        final face = _vec(5);
        expect(
            await _mark(
                host: host,
                hostEngine: engine,
                store: await _enrolledAs('a@x.in', 'a1'),
                embedding: face,
                email: 'a@x.in'),
            StudentResult.marked);
        expect(
            await _mark(
                host: host,
                hostEngine: engine,
                store: await _enrolledAs('b@x.in', 'b2'),
                embedding: face,
                email: 'b@x.in'),
            StudentResult.marked);
        // Both marked (never auto-absent)…
        expect(host.tally.presentCount, 2);
        // …and both flagged with a symmetric neutral group.
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
        for (final e in ['a@x.in', 'b@x.in', 'c@x.in']) {
          expect(
              await _mark(
                  host: host,
                  hostEngine: engine,
                  store: await _enrolledAs(e, 'a1'),
                  embedding: face,
                  email: e),
              StudentResult.marked);
        }
        expect(
            await _mark(
                host: host,
                hostEngine: engine,
                store: await _enrolledAs('s@x.in', 'c3'),
                embedding: _vec(6),
                email: 's@x.in'),
            StudentResult.marked);
        expect(host.tally.presentCount, 4);
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
        for (final e in ['a@x.in', 'b@x.in']) {
          expect(
              await _mark(
                  host: host,
                  hostEngine: engine,
                  store: await _enrolledAs(e, 'a1'),
                  embedding: face,
                  email: e),
              StudentResult.marked);
        }
        expect(host.tally.flaggedEmails, ['a@x.in', 'b@x.in']);
        // 1-tap override: flags gone, presence kept.
        await host.resolveDupFlag('a@x.in');
        expect(host.tally.flaggedEmails, isEmpty);
        expect(host.dupGroups, isEmpty);
        expect(host.tally.presentCount, 2);
        // Retake: BOTH re-prove into a fresh vector map — the exempt pair
        // stays quiet while presence still counts.
        await host.stopWindow();
        await Future.delayed(const Duration(seconds: 1));
        await host.startWindow(2);
        for (final e in ['a@x.in', 'b@x.in']) {
          expect(
              await _mark(
                  host: host,
                  hostEngine: engine,
                  store: await _enrolledAs(e, 'a1'),
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
        for (final e in ['a@x.in', 'b@x.in']) {
          await _mark(
              host: host,
              hostEngine: engine,
              store: await _enrolledAs(e, 'a1'),
              embedding: face,
              email: e);
        }
        expect(host.tally.flaggedEmails, ['a@x.in', 'b@x.in']);
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
        // FLAGGED status present…
        expect(doc['faceFlags'], ['a@x.in', 'b@x.in']);
        expect((doc['windows'] as List).single['a@x.in'], isTrue);
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
          seedHex: 'ab' * 32,
          pkHex: 'cd' * 32,
          faceId: 'face-old@x.in',
          enrolledAt: DateTime.now().toUtc(),
          verifierVer: 'edgeface-xs-g06-tflite-1',
        ));
        final res = await _mark(
            host: host,
            hostEngine: engine,
            store: store,
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
