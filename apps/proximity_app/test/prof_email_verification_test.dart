// Prof-email verification wiring (anti-fake-professor, offline-first).
//
// The email→key binding is the keypair proposal: the lecture public key is
// pinned server-side (`profDevices/{email}`, owner-only write) and the live
// Sig_p is checked against that pin BEFORE the student signs anything.
// Verdicts: known → verified badge; unknown → first-seen unverified banner
// + auto-verify queue; mismatch → NO proof is sent (fake class).
//
// Hosting stays offline-capable: publish is best-effort fire-and-forget,
// verify degrades cache → unknown (never blocks on network).
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/prof_pin_check.dart';
import 'package:proximity_app/core/sync/claim.dart';
import 'package:proximity_app/core/sync/fake_sync.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_transport/transport.dart';

/// Builds a gated /window descriptor the way the professor server does
/// (Sig_p over the radio challenge), carrying [profEmail] + [profPk].
WindowDescriptor _descriptor({
  required ed.KeyPair profKeys,
  required String profEmail,
  Uint8List? sessionId,
  Uint8List? windowId,
  int j = 3,
}) {
  final sess = sessionId ?? randBytes(16);
  final wid = windowId ?? randBytes(6);
  final secret = randBytes(32);
  final cj = ProxCrypto.challengeForSubEpoch(secret, wid, j);
  final sigP = ProxCrypto.signProfChallenge(
    profSk: profKeys.privateKey,
    sessionId: sess,
    windowId: wid,
    j: j,
    challenge: cj,
  );
  final fp = ProxCrypto.sha256Sync([1, 2, 3]);
  return WindowDescriptor(
    classLabel: 'CS201',
    sessionId: sess,
    windowId: wid,
    jNow: j,
    profPk: profKeys.publicKey,
    sigP: sigP,
    tlsFp: fp,
    display: 'KQ7',
    org: 'x.in',
    profEmail: profEmail,
  );
}

String _pkHex(ed.KeyPair kp) =>
    hexEncode(kp.publicKey.bytes.sublist(0, 32)).toLowerCase();

void main() {
  group('checkProfPin (email→key binding)', () {
    test('unknown on first sight pins on use (TOFU)', () async {
      final store = InMemoryDeviceStore();
      final keys = ProxCrypto.generateEdKeypair();
      final desc = _descriptor(
          profKeys: keys, profEmail: 'prof@x.in');
      final check = await checkProfPin(desc: desc, store: store);
      expect(check.verdict, ProfPinVerdict.unknown);
      // Pinned for the NEXT class.
      final rows = await store.readProfPin('prof@x.in');
      expect(
          profPinHexesFromRows(rows), contains(_pkHex(keys)));
      // Second sight of the same key is known.
      final again = await checkProfPin(desc: desc, store: store);
      expect(again.verdict, ProfPinVerdict.known);
    });

    test('mismatch refuses (fake class reuses a known email)', () async {
      final store = InMemoryDeviceStore();
      final real = ProxCrypto.generateEdKeypair();
      final first = _descriptor(
          profKeys: real, profEmail: 'prof@x.in');
      expect((await checkProfPin(desc: first, store: store)).verdict,
          ProfPinVerdict.unknown);
      // Attacker hosts as the same email with a fresh key.
      final fake = ProxCrypto.generateEdKeypair();
      final spoof = _descriptor(
          profKeys: fake,
          profEmail: 'prof@x.in',
          sessionId: first.sessionId,
          windowId: first.windowId);
      final check = await checkProfPin(desc: spoof, store: store);
      expect(check.verdict, ProfPinVerdict.mismatch);
    });

    test('online fetch verifies live and refreshes the cache', () async {
      final store = InMemoryDeviceStore();
      final cloud = FakeCloudSync();
      final keys = ProxCrypto.generateEdKeypair();
      await cloud.uploadProfKey(
        emailLower: 'prof@x.in',
        uid: 'uid-1',
        org: 'x.in',
        pkPHex: _pkHex(keys),
      );
      final desc = _descriptor(
          profKeys: keys, profEmail: 'prof@x.in');
      // Empty local cache + online fetch → known (live verified).
      final check = await checkProfPin(
        desc: desc,
        store: store,
        fetchRemote: cloud.fetchProfKeys,
      );
      expect(check.verdict, ProfPinVerdict.known);
      expect(check.liveRefreshed, isTrue);
      expect(profPinHexesFromRows(await store.readProfPin('prof@x.in')),
          contains(_pkHex(keys)));
    });

    test('offline fetch failure degrades to the cache (never throws)',
        () async {
      final store = InMemoryDeviceStore();
      final keys = ProxCrypto.generateEdKeypair();
      await store.writeProfPin('prof@x.in', [
        {
          'pkP': _pkHex(keys),
          'createdAtMillis':
              DateTime.now().toUtc().millisecondsSinceEpoch,
        }
      ]);
      final desc = _descriptor(
          profKeys: keys, profEmail: 'prof@x.in');
      final check = await checkProfPin(
        desc: desc,
        store: store,
        fetchRemote: (_) async => throw StateError('offline'),
      );
      expect(check.verdict, ProfPinVerdict.known);
      // Cache-only while offline must never claim a live fetch.
      expect(check.liveRefreshed, isFalse);
    });

    test('first-sight offline never claims live (unverified + queued)',
        () async {
      final store = InMemoryDeviceStore();
      final keys = ProxCrypto.generateEdKeypair();
      final desc = _descriptor(
          profKeys: keys, profEmail: 'newprof@x.in');
      final check = await checkProfPin(
        desc: desc,
        store: store,
        fetchRemote: (_) async => throw StateError('offline'),
      );
      expect(check.verdict, ProfPinVerdict.unknown);
      expect(check.liveRefreshed, isFalse);
    });

    test('pending queue round-trips (offline first-seen auto-verifies)',
        () async {
      final store = InMemoryDeviceStore();
      expect(await store.readPendingProfVerifications(), isEmpty);
      await store.writePendingProfVerifications({'Prof@X.in', ''});
      expect(
          await store.readPendingProfVerifications(), {'prof@x.in'});
    });
  });

  group('student key pins (professor-side email→key binding)', () {
    test('directory carries pkS through claim (fake backend)', () async {
      final cloud = FakeCloudSync();
      final kp = ProxCrypto.generateEdKeypair();
      final pkHex =
          hexEncode(kp.publicKey.bytes.sublist(0, 32)).toLowerCase();
      final now = DateTime.now().toUtc();
      await cloud.claimStudentDevice(
        doc: StudentDeviceDoc(
          email: 's@x.in',
          uid: 'u1',
          pkHex: pkHex,
          name: 'S',
          roll: '1',
          modelVer: 'v',
          org: 'x.in',
        ),
        installId: 'a' * 32,
        now: now,
      );
      final pins = await cloud.fetchStudentKeyPins(org: 'x.in');
      expect(pins['s@x.in'], pkHex);
      // Persistent professor cache round-trips the pin.
      final store = InMemoryDeviceStore();
      await store.writeStudentKeyPins(pins);
      expect(await store.readStudentKeyPins(), pins);
    });
  });
}
