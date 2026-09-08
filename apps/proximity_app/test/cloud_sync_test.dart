import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_storage/storage.dart';

ClassRecord _rec(String id, String ts, Map<String, bool> w1,
        {String startIso = ''}) =>
    ClassRecord(
      id: id,
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-06',
      timestampIso: ts,
      startIso: startIso,
      windows: [w1],
      names: const {'a@x.in': 'A'},
      rolls: const {'a@x.in': '1'},
    );

void main() {
  test('mergeHistoriesUnion: marks additive, newer header wins', () {
    final local = [
      _rec('s1', '2026-09-06T10:00:00.000Z', {'a@x.in': true}),
      _rec('s2', '2026-09-06T11:00:00.000Z', {'a@x.in': true}),
    ];
    final cloud = [
      _rec('s2', '2026-09-06T12:00:00.000Z', {'a@x.in': false}),
      _rec('s3', '2026-09-06T09:00:00.000Z', {'b@x.in': true}),
    ];
    final merged = mergeHistoriesUnion(local, cloud);
    expect(merged.map((r) => r.id), ['s2', 's1', 's3']);
    // s2 keeps the local TRUE mark: union ORs window maps, so a newer
    // cloud `false` can never wipe a mark (the LWW data-loss this
    // replaced). Header fields still come from the newer record.
    expect(merged.first.windows.first['a@x.in'], isTrue);
    expect(merged.first.timestampIso, '2026-09-06T12:00:00.000Z');
  });

  test('profPushIdentity: offline-skipped and students never push', () {
    expect(
        profPushIdentity(
            authEmail: 'p@x.in',
            authUid: 'u1',
            authName: 'Prof',
            role: null,
            hostNameFallback: ''),
        isNull);
    expect(
        profPushIdentity(
            authEmail: 'a@x.in',
            authUid: 'u2',
            authName: 'A',
            role: const {'role': 'student', 'email': 'a@x.in'},
            hostNameFallback: ''),
        isNull);
    // Legacy single-role cache still works.
    final legacy = profPushIdentity(
        authEmail: 'P@x.in',
        authUid: 'u1',
        authName: 'Gmail Name',
        role: const {
          'role': 'prof',
          'email': 'p@x.in',
          'displayName': 'Prof Display'
        },
        hostNameFallback: 'Typed');
    expect(legacy?.uid, 'u1');
    expect(legacy?.email, 'p@x.in');
    expect(legacy?.name, 'Prof Display'); // registered name wins
    // New multi-role cache: a Gmail holding BOTH roles still pushes.
    final dual = profPushIdentity(
        authEmail: 'p@x.in',
        authUid: 'u1',
        authName: 'Gmail Name',
        role: const {
          'roles': 'prof,student',
          'role': 'student',
          'lastMode': 'student',
          'email': 'p@x.in',
          'displayName': 'Prof Display'
        },
        hostNameFallback: 'Typed');
    expect(dual?.uid, 'u1');
    expect(dual?.name, 'Prof Display');
    // Wrong-account cache never pushes.
    expect(
        profPushIdentity(
            authEmail: 'other@x.in',
            authUid: 'u9',
            authName: 'X',
            role: const {'roles': 'prof', 'email': 'p@x.in'},
            hostNameFallback: ''),
        isNull);
  });

  test('role cache helpers: dual roles, legacy fallback, lastMode', () {
    expect(roleSet(null), isEmpty);
    expect(roleSet(const {'role': 'prof', 'email': 'p@x.in'}), {'prof'});
    expect(roleSet(const {'roles': 'prof,student'}), {'prof', 'student'});
    expect(roleHas(const {'roles': 'prof', 'email': 'p@x.in'}, 'prof',
        email: 'P@X.IN'), isTrue);
    expect(roleHas(const {'roles': 'prof', 'email': 'p@x.in'}, 'student'),
        isFalse);
    expect(roleLastMode(const {'roles': 'prof,student', 'lastMode': 'student'}),
        'student');
    expect(roleLastMode(const {'role': 'prof'}), 'prof');
    var m = mergeRoleCache(null,
        email: 'P@X.in', uid: 'u1', addRole: 'student', lastMode: 'student');
    expect(m['roles'], 'student');
    expect(m['role'], 'student'); // legacy mirror
    expect(m['email'], 'p@x.in');
    m = mergeRoleCache(m,
        email: 'p@x.in', uid: 'u1', displayName: 'Prof', addRole: 'prof');
    expect(m['roles'], 'prof,student');
    expect(m['lastMode'], 'student'); // untouched when not passed
    m = mergeRoleCache(m, email: 'p@x.in', uid: 'u1', lastMode: 'prof');
    expect(m['lastMode'], 'prof');
    expect(m['role'], 'prof');
  });

  test('session doc round-trips through Firestore mapping', () {
    final r = _rec('s9', '2026-09-06T10:00:00.000Z', {'a@x.in': true},
        startIso: '2026-09-06T09:00:00.000Z');
    final doc = sessionToDoc(
        profUid: 'u1', profEmail: 'p@x.in', profName: 'Prof', record: r);
    expect((doc['studentEmails'] as List), contains('a@x.in'));
    expect(doc['startIso'], '2026-09-06T09:00:00.000Z');
    final back = docToRecord('s9', doc);
    expect(back.courseId, 'CS201');
    expect(back.isPresent('a@x.in'), isTrue);
    expect(back.startIso, '2026-09-06T09:00:00.000Z');
    // Old docs without startIso fall back to the snapshot time.
    final legacy = docToRecord(
        's9', {...doc}..remove('startIso'));
    expect(legacy.startIso, '2026-09-06T10:00:00.000Z');
  });

  test('FakeCloudSync: setRole unions roles, keeps lastMode', () async {
    final fake = FakeCloudSync();
    await fake.setRole(RoleDoc(
        uid: 'u1', email: 'p@x.in', name: 'P', role: 'prof', lastMode: 'prof'));
    await fake.setRole(RoleDoc(
        uid: 'u1',
        email: 'p@x.in',
        name: 'P',
        roles: const ['student'],
        lastMode: 'student'));
    final back = (await fake.fetchRole('u1'))!;
    expect(back.roles.toSet(), {'prof', 'student'});
    expect(back.lastMode, 'student');
    // Empty lastMode never clobbers.
    await fake.setRole(
        RoleDoc(uid: 'u1', email: 'p@x.in', name: 'P', roles: const ['prof']));
    expect((await fake.fetchRole('u1'))!.lastMode, 'student');
  });

  StudentDeviceDoc dev(String pk, String inst, {int movedAgoDays = -1}) {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    const day = 24 * 60 * 60 * 1000;
    final moved = movedAgoDays < 0 ? 0 : now - movedAgoDays * day;
    return StudentDeviceDoc(
        email: 's@x.in',
        uid: 'u9',
        pkHex: pk,
        name: 'S',
        roll: '1',
        modelVer: 'v',
        installId: inst,
        lastMoveAtMillis: moved,
        lastSeenAtMillis: moved == 0 ? 0 : moved);
  }

  test('evaluateStudentClaim: first/same/move/cooldown/install verdicts', () {
    const email = 's@x.in';
    // First bind.
    expect(
        evaluateStudentClaim(
            localPkHex: 'aa',
            localInstallId: 'i1',
            binding: null,
            installEmail: null,
            email: email)
            .claim,
        StudentClaim.firstBind);
    // Same install enrolled as another Gmail: hard refuse.
    final conflict = evaluateStudentClaim(
        localPkHex: 'aa',
        localInstallId: 'i1',
        binding: null,
        installEmail: 'other@x.in',
        email: email);
    expect(conflict.claim, StudentClaim.installConflict);
    expect(studentClaimMessage(conflict, null), contains('already enrolled'));
    // Same install: same device even with a fresh key (re-key).
    // A bare pk match from a DIFFERENT install is a move, not the same
    // device (a copied public key must not bypass the cooldown).
    expect(
        evaluateStudentClaim(
                localPkHex: 'AA',
                localInstallId: 'iX',
                binding: dev('aa', 'i1', movedAgoDays: 0),
                installEmail: email,
                email: email)
            .claim,
        StudentClaim.cooldownBlocked);
    expect(
        evaluateStudentClaim(
                localPkHex: 'zz',
                localInstallId: 'i1',
                binding: dev('aa', 'i1', movedAgoDays: 0),
                installEmail: email,
                email: email)
            .claim,
        StudentClaim.sameDevice);
    // Different device, moved today: cooldown with a retry date.
    final blocked = evaluateStudentClaim(
        localPkHex: 'zz',
        localInstallId: 'i2',
        binding: dev('aa', 'i1', movedAgoDays: 1),
        installEmail: null,
        email: email);
    expect(blocked.claim, StudentClaim.cooldownBlocked);
    expect(blocked.retryAfter, isNotNull);
    expect(studentClaimMessage(blocked, dev('aa', 'i1', movedAgoDays: 1)),
        contains('professor'));
    // Different device, moved 31 days ago: allowed.
    expect(
        evaluateStudentClaim(
                localPkHex: 'zz',
                localInstallId: 'i2',
                binding: dev('aa', 'i1', movedAgoDays: 31),
                installEmail: null,
                email: email)
            .claim,
        StudentClaim.allowedMove);
    // Legacy doc without timestamps: one migration move.
    expect(
        evaluateStudentClaim(
                localPkHex: 'zz',
                localInstallId: 'i2',
                binding: dev('aa', 'i1'),
                installEmail: null,
                email: email)
            .claim,
        StudentClaim.allowedMove);
  });

  test('FakeCloudSync claim: one Gmail one device, monthly move', () async {
    final fake = FakeCloudSync();
    const email = 's@x.in';
    // Phone A enrolls first.
    final a = await fake.claimStudentDevice(
        doc: dev('aa', 'iA'), installId: 'iA');
    expect(a.isFirst, isTrue);
    // Same phone re-keys freely (same install).
    final a2 = await fake.claimStudentDevice(
        doc: dev('bb', 'iA'), installId: 'iA');
    expect(a2.isMove, isFalse);
    // Phone B races in: refused with retry date + manual path. No reset
    // shortcut exists anywhere (a student could self-register as prof).
    var refused = '';
    try {
      await fake.claimStudentDevice(doc: dev('cc', 'iB'), installId: 'iB');
    } on StateError catch (e) {
      refused = e.message;
    }
    expect(refused, contains('another device'));
    expect(refused, contains('re-enroll'));
    expect(refused, contains('manually'));
    // Same phone, second Gmail: hard refuse (clones included).
    var cloneRefused = '';
    try {
      await fake.claimStudentDevice(
          doc: StudentDeviceDoc(
              email: 'other@x.in',
              uid: 'u2',
              pkHex: 'dd',
              name: 'O',
              roll: '2',
              modelVer: 'v',
              installId: 'iA'),
          installId: 'iA');
    } on StateError catch (e) {
      cloneRefused = e.message;
    }
    expect(cloneRefused, contains('already enrolled'));
    // Heartbeat touches lastSeen while held, ignores strangers.
    expect(
        await fake.touchStudentDevice(
            emailLower: email, pkHex: 'bb', installId: 'iA'),
        isTrue);
    expect(
        await fake.touchStudentDevice(
            emailLower: email, pkHex: 'cc', installId: 'iB'),
        isFalse);
    // Monthly move still works after a stale binding (genuine loss path):
    // seed a second Gmail bound 31 days ago, then move it.
    const day = 24 * 60 * 60 * 1000;
    final stale = DateTime.now().toUtc().millisecondsSinceEpoch - 31 * day;
    await fake.writeStudentDevice(StudentDeviceDoc(
        email: 'old@x.in',
        uid: 'u3',
        pkHex: 'ee',
        name: 'Old',
        roll: '3',
        modelVer: 'v',
        installId: 'iOld',
        createdAtMillis: stale,
        lastMoveAtMillis: stale,
        lastSeenAtMillis: stale,
        updatedAtMillis: stale));
    final moved = await fake.claimStudentDevice(
        doc: StudentDeviceDoc(
            email: 'old@x.in',
            uid: 'u3',
            pkHex: 'ff',
            name: 'Old',
            roll: '3',
            modelVer: 'v'),
        installId: 'iNew');
    expect(moved.isMove, isTrue);
    expect((await fake.fetchStudentDevice('old@x.in'))?.moveCount, 1);
  });

  test('FakeCloudSync directory search: email/roll/name prefixes', () async {
    final fake = FakeCloudSync();
    expect(await fake.searchStudents(), isEmpty); // empty query
    await fake.claimStudentDevice(
        doc: StudentDeviceDoc(
            email: 'student1@example.com',
            uid: 'u1',
            pkHex: 'aa',
            name: 'Student One',
            roll: '12342210',
            modelVer: 'v'),
        installId: 'i1');
    await fake.claimStudentDevice(
        doc: StudentDeviceDoc(
            email: 'student2@example.com',
            uid: 'u2',
            pkHex: 'bb',
            name: 'Student Two',
            roll: '12342211',
            modelVer: 'v'),
        installId: 'i2');
    var hits = await fake.searchStudents(emailPrefix: 'student1@');
    expect(hits.map((e) => e.email), ['student1@example.com']);
    hits = await fake.searchStudents(rollPrefix: '1234221');
    expect(hits, hasLength(2));
    hits = await fake.searchStudents(namePrefix: 'student two');
    expect(hits.map((e) => e.email), ['student2@example.com']);
    hits = await fake.searchStudents(emailPrefix: 'zzz');
    expect(hits, isEmpty);
    fake.online = false;
    var threw = false;
    try {
      await fake.searchStudents(emailPrefix: 'a');
    } catch (_) {
      threw = true;
    }
    expect(threw, isTrue);
  });

  test('FakeCloudSync: push/pull/rename/delete + offline refusal', () async {
    final fake = FakeCloudSync();
    await fake.setRole(RoleDoc(
        uid: 'u1', email: 'p@x.in', name: 'Prof', role: 'prof'));
    expect(await fake.fetchRole('u1'), isNotNull);
    final r = _rec('s1', '2026-09-06T10:00:00.000Z', {'a@x.in': true});
    await fake.pushSession(
        profUid: 'u1', profEmail: 'p@x.in', profName: 'Prof', record: r);
    expect(await fake.pullProfSessions('u1'), hasLength(1));
    expect(await fake.pullStudentSessions('a@x.in'), hasLength(1));
    expect(await fake.pullStudentSessions('nobody@x.in'), isEmpty);
    await fake.renameCourseCloud(
        profUid: 'u1', oldName: 'CS201', newName: 'CS202');
    expect((await fake.pullProfSessions('u1')).first.courseId, 'CS202');
    await fake.deleteSessionsCloud(profUid: 'u1', ids: ['s1']);
    expect(await fake.pullProfSessions('u1'), isEmpty);
    fake.online = false;
    expect(await fake.isOnline(), isFalse);
    var threw = false;
    try {
      await fake.pushSession(
          profUid: 'u1', profEmail: 'p@x.in', profName: 'Prof', record: r);
    } catch (_) {
      threw = true;
    }
    expect(threw, isTrue);
  });

  test('rename bumps timestampIso so merges adopt the new name', () async {
    // The reported gap: a rename that only touches courseId loses to any
    // device holding a newer-timestamped copy under the OLD name. The
    // bump makes the renamed doc newest, so professors AND students (same
    // docs) converge on it; class-start time is untouched by renames.
    final fake = FakeCloudSync();
    final pushed = ClassRecord(
      id: 'sR',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2025-01-06',
      timestampIso: '2025-01-06T10:00:00.000Z',
      startIso: '2025-01-06T09:00:00.000Z',
      windows: const [
        {'a@x.in': true}
      ],
      names: const {'a@x.in': 'A'},
      rolls: const {'a@x.in': '1'},
    );
    await fake.pushSession(
        profUid: 'u1', profEmail: 'p@x.in', profName: 'Prof', record: pushed);
    await fake.renameCourseCloud(
        profUid: 'u1', oldName: 'CS201', newName: 'CS202');
    final renamed = (await fake.pullProfSessions('u1')).single;
    expect(renamed.courseId, 'CS202');
    expect(renamed.timestampIso.compareTo(pushed.timestampIso) > 0, isTrue);
    expect(renamed.startIso, pushed.startIso);
    final merged = mergeHistoriesUnion([pushed], [renamed]);
    expect(merged.single.courseId, 'CS202');
    final student = (await fake.pullStudentSessions('a@x.in')).single;
    expect(student.courseId, 'CS202');
    expect(student.startIso, pushed.startIso);
  });
}
