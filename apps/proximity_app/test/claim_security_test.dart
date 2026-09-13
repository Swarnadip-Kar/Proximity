import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/cloud_sync.dart';
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
          livenessVer: 'liveness/minifasnet-v2-27-80x80+4ff758f4',
          integrityFlag: ''),
      installId: 'iA',
    );
    final back = (await fake.fetchStudentDevice('s@x.in'))!;
    expect(back.pkDHex, 'bb' * 32);
    expect(back.attestationLevel, 'FULL');
    expect(back.attestedUntilMillis, greaterThan(0));
    expect(back.attestationChain, ['ab12', 'cd34']);
    expect(back.livenessVer, 'liveness/minifasnet-v2-27-80x80+4ff758f4');
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
          livenessVer: 'liveness/minifasnet-v2-27-80x80+4ff758f4',
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
    expect(back.livenessVer, 'liveness/minifasnet-v2-27-80x80+4ff758f4');
    expect(back.integrityFlag, 'integrity-flagged');
    expect(
        await fake.touchStudentDevice(
            emailLower: 's@x.in', pkHex: 'cc', installId: 'iB'),
        isFalse);
  });

  test('MoveIntent instant move + 30d cooldown untouched by security fields',
      () async {
    final fake = FakeCloudSync();
    await fake.claimStudentDevice(
        doc: dev('s@x.in', 'aa', 'iA'), installId: 'iA');
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
    // Same move with a valid old-DKey MoveIntent succeeds instantly.
    final moved = await fake.claimStudentDevice(
        doc: dev('s@x.in', 'cc', 'iB',
            pkDHex: 'cc' * 32, level: 'FULL', chain: ['ff']),
        installId: 'iB',
        moveIntentValid: true);
    expect(moved.isMove, isTrue);
    expect((await fake.fetchStudentDevice('s@x.in'))?.pkDHex, 'cc' * 32);
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
