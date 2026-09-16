import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart'
    show kLivenessVer;
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_storage/storage.dart';

StudentDeviceDoc dev(
  String email,
  String pk,
  String inst, {
  String pkDHex = '',
  String level = 'NONE',
  int until = 0,
  List<String> chain = const [],
  String livenessVer = '',
  String integrityFlag = '',
  String deviceId = '',
}) {
  final now = DateTime.now().toUtc().millisecondsSinceEpoch;
  return StudentDeviceDoc(
    email: email,
    uid: 'u-$email',
    pkHex: pk,
    name: 'S',
    roll: '1',
    modelVer: 'face_verification/0.3.9+b45ab893',
    installId: inst,
    platform: 'android',
    org: 'x.in',
    pkDHex: pkDHex,
    attestationLevel: level,
    attestedAtMillis: now,
    attestedUntilMillis: until == 0 ? now + 90 * 24 * 60 * 60 * 1000 : until,
    attestationChain: List<String>.of(chain),
    livenessVer: livenessVer,
    integrityFlag: integrityFlag,
    deviceId: deviceId,
  );
}

void main() {
  test('claim persists pkD/level/window + chain/liveness/integrity', () async {
    final fake = FakeCloudSync();
    await fake.claimStudentDevice(
      doc: dev('s@x.in', 'aa', 'iA',
          pkDHex: 'bb' * 32,
          level: 'FULL',
          chain: ['ab12', 'cd34'],
          livenessVer: kLivenessVer,
          integrityFlag: ''),
      installId: 'iA',
    );
    final back = (await fake.fetchStudentDevice('s@x.in'))!;
    expect(back.pkDHex, 'bb' * 32);
    expect(back.attestationLevel, 'FULL');
    expect(back.attestedUntilMillis, greaterThan(0));
    expect(back.attestationChain, ['ab12', 'cd34']);
    expect(back.livenessVer, kLivenessVer);
    expect(back.integrityFlag, '');
  });

  test('legacy field-less claim reads migration-safe defaults', () async {
    final fake = FakeCloudSync();
    // Legacy constructor defaults (no security kwargs) must compile + store.
    await fake.claimStudentDevice(
      doc: StudentDeviceDoc(
        email: 'legacy@x.in',
        uid: 'u1',
        pkHex: 'aa',
        name: 'L',
        roll: '2',
        modelVer: 'v',
        installId: 'iL',
      ),
      installId: 'iL',
    );
    final back = (await fake.fetchStudentDevice('legacy@x.in'))!;
    expect(back.pkDHex, '');
    expect(back.attestationLevel, 'NONE');
    expect(back.attestationChain, isEmpty);
    expect(back.livenessVer, '');
    expect(back.integrityFlag, '');
  });

  test('heartbeat preserves security fields, ignores strangers', () async {
    final fake = FakeCloudSync();
    await fake.claimStudentDevice(
      doc: dev('s@x.in', 'aa', 'iA',
          pkDHex: 'bb' * 32,
          level: 'STD',
          chain: ['ab12'],
          livenessVer: kLivenessVer,
          integrityFlag: 'integrity-flagged'),
      installId: 'iA',
    );
    expect(
        await fake.touchStudentDevice(
            emailLower: 's@x.in', pkHex: 'aa', installId: 'iA'),
        isTrue);
    final back = (await fake.fetchStudentDevice('s@x.in'))!;
    // Touch bumps lastSeen only — binding + security audit fields survive.
    expect(back.pkDHex, 'bb' * 32);
    expect(back.attestationChain, ['ab12']);
    expect(back.livenessVer, kLivenessVer);
    expect(back.integrityFlag, 'integrity-flagged');
    expect(
        await fake.touchStudentDevice(
            emailLower: 's@x.in', pkHex: 'cc', installId: 'iB'),
        isFalse);
  });

  test('MoveIntent instant move + 30d cooldown untouched by security fields',
      () async {
    // H5: genuine old-SKey signature required — no boolean bypass.
    final kp = ed.generateKey();
    final prevPkHex =
        hexEncode(Uint8List.fromList(kp.publicKey.bytes.sublist(0, 32)));
    final fake = FakeCloudSync();
    await fake.claimStudentDevice(
        doc: dev('s@x.in', prevPkHex, 'iA'), installId: 'iA');
    // Different device inside cooldown refuses without MoveIntent.
    var refused = '';
    try {
      await fake.claimStudentDevice(
          doc: dev('s@x.in', 'cc', 'iB',
              pkDHex: 'cc' * 32, level: 'FULL', chain: ['ff']),
          installId: 'iB');
    } on StateError catch (e) {
      refused = e.message;
    }
    expect(refused, contains('another device'));
    // Same move with a valid old-SKey MoveIntent succeeds instantly.
    final atMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final sig = ed.sign(
        kp.privateKey, Uint8List.fromList(utf8.encode('iB|$atMs')));
    final moved = await fake.claimStudentDevice(
        doc: dev('s@x.in', 'cc', 'iB',
            pkDHex: 'cc' * 32, level: 'FULL', chain: ['ff']),
        installId: 'iB',
        moveIntent: MoveIntent(
            prevPkSHex: prevPkHex,
            newInstallId: 'iB',
            atMillis: atMs,
            sigHex: hexEncode(sig)));
    expect(moved.isMove, isTrue);
    expect((await fake.fetchStudentDevice('s@x.in'))?.pkDHex, 'cc' * 32);
  });

  test('same-phone reclaim skips the cooldown; mismatch still waits', () async {
    // Reinstall wipes the installId, so a same-phone reinstall looks like a
    // device move. Presenting the STORED hardware id reclaims instantly;
    // anything else (or nothing) waits the 30 days.
    final fake = FakeCloudSync();
    await fake.claimStudentDevice(
        doc: dev('s@x.in', 'aa', 'iA', deviceId: 'phone-1'),
        installId: 'iA');
    // Same phone, fresh install (reinstall): instant move, flagged reclaim.
    final reclaimed = await fake.claimStudentDevice(
        doc: dev('s@x.in', 'bb', 'iB', deviceId: 'phone-1'),
        installId: 'iB');
    expect(reclaimed.isMove, isTrue);
    expect(reclaimed.isReclaim, isTrue);
    expect((await fake.fetchStudentDevice('s@x.in'))?.installId, 'iB');
    // The reclaim restamps the move clock: a DIFFERENT phone now waits.
    var refused = '';
    try {
      await fake.claimStudentDevice(
          doc: dev('s@x.in', 'cc', 'iC', deviceId: 'phone-2'),
          installId: 'iC');
    } on StateError catch (e) {
      refused = e.message;
    }
    expect(refused, contains('another device'));
    // Unknown hardware id ('') never reclaims either.
    refused = '';
    try {
      await fake.claimStudentDevice(
          doc: dev('s@x.in', 'cc', 'iC'), installId: 'iC');
    } on StateError catch (e) {
      refused = e.message;
    }
    expect(refused, contains('another device'));
  });

  test('reclaim verdict is pure: evaluateStudentClaim matrix', () {
    final now = DateTime.now().toUtc();
    final base = now.millisecondsSinceEpoch - 24 * 60 * 60 * 1000;
    // Cooldown-blocked without ids.
    final bindingDoc = StudentDeviceDoc(
      email: 's@x.in',
      uid: 'u',
      pkHex: 'aa',
      name: 'S',
      roll: '1',
      modelVer: 'v',
      installId: 'iA',
      org: 'x.in',
      lastMoveAtMillis: base,
      lastSeenAtMillis: base,
      deviceId: 'phone-1',
    );
    expect(
        evaluateStudentClaim(
            localInstallId: 'iB',
            binding: bindingDoc,
            installEmail: null,
            email: 's@x.in',
            now: now),
        predicate<StudentClaimResult>(
            (r) => r.claim == StudentClaim.cooldownBlocked && !r.isReclaim));
    // Same hardware id reclaims.
    expect(
        evaluateStudentClaim(
            localInstallId: 'iB',
            binding: bindingDoc,
            installEmail: null,
            email: 's@x.in',
            now: now,
            localDeviceId: 'phone-1'),
        predicate<StudentClaimResult>((r) =>
            r.claim == StudentClaim.allowedMove && r.isReclaim && r.ok));
    // Different hardware id still waits.
    expect(
        evaluateStudentClaim(
            localInstallId: 'iB',
            binding: bindingDoc,
            installEmail: null,
            email: 's@x.in',
            now: now,
            localDeviceId: 'phone-2'),
        predicate<StudentClaimResult>(
            (r) => r.claim == StudentClaim.cooldownBlocked && !r.isReclaim));
    // Stored doc without an id never reclaims (pre-upgrade docs).
    final legacy = StudentDeviceDoc(
      email: 's@x.in',
      uid: 'u',
      pkHex: 'aa',
      name: 'S',
      roll: '1',
      modelVer: 'v',
      installId: 'iA',
      org: 'x.in',
      lastMoveAtMillis: base,
      lastSeenAtMillis: base,
    );
    expect(
        evaluateStudentClaim(
            localInstallId: 'iB',
            binding: legacy,
            installEmail: null,
            email: 's@x.in',
            now: now,
            localDeviceId: 'phone-1'),
        predicate<StudentClaimResult>(
            (r) => r.claim == StudentClaim.cooldownBlocked && !r.isReclaim));
  });

  test('findDoublePkD flags shared pkD across Gmails (clone signal)', () {
    final devices = {
      'a@x.in': dev('a@x.in', 'aa', 'iA', pkDHex: 'dd' * 32),
      'b@x.in': dev('b@x.in', 'bb', 'iB', pkDHex: 'DD' * 32), // case-insensitive
      'c@x.in': dev('c@x.in', 'cc', 'iC', pkDHex: 'ee' * 32),
      'd@x.in': dev('d@x.in', 'dd', 'iD'), // unbound legacy skipped
    };
    final groups = findDoublePkD(devices);
    expect(groups.keys, hasLength(1));
    expect(groups.values.single, ['a@x.in', 'b@x.in']);
  });

  test('sync carries PRESENT/ABSENT/FLAGGED only — zero face vectors', () async {
    final fake = FakeCloudSync();
    await fake.claimStudentDevice(
        doc: dev('s@x.in', 'aa', 'iA'), installId: 'iA');
    // Session docs carry windows/names/rolls/faceFlags only (see
    // sessions.dart sessionToDoc): assert no face-derived keys exist.
    final rec = ClassRecord(
      id: 's1',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-06',
      timestampIso: '2026-09-06T10:00:00.000Z',
      startIso: '2026-09-06T09:00:00.000Z',
      windows: const [
        {'s@x.in': true}
      ],
      names: const {'s@x.in': 'S'},
      rolls: const {'s@x.in': '1'},
    );
    await fake.pushSession(
        profUid: 'u1', profEmail: 'p@x.in', profName: 'P', record: rec);
    final doc = fake.sessions['s1']!;
    final blob = doc.toString();
    expect(blob.contains('vec'), isFalse);
    expect(blob.contains('embedding'), isFalse);
    expect(blob.contains('faceScore'), isFalse);
    expect(doc['faceFlags'], isA<List>());
  });
}
