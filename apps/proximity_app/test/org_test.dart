// Track 1 org mapping: table tests for orgOf + gate predicates + fakes.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/sync/org.dart';
import 'package:proximity_app/core/sync/sessions.dart';
import 'package:proximity_app/core/sync/fake_sync.dart';
import 'package:proximity_app/core/sync/claim.dart';
import 'package:proximity_app/core/sync/directory.dart' as syncdir;
import 'package:proximity_app/core/sync/roles.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_storage/storage.dart';
import 'package:proximity_transport/transport.dart';

void main() {
  group('orgOf', () {
    final cases = <String, String>{
      'Prof@Univ.edu': 'univ.edu',
      '  STUDENT@MAIL.UNIV.EDU  ': 'mail.univ.edu',
      'a@gmail.com': 'gmail.com',
      'a@Googlemail.com': 'gmail.com',
      'a@GMAIL.COM': 'gmail.com',
      'a@mail.univ.edu': 'mail.univ.edu',
      'no-at-here': '',
      '@nolocal.com': '',
      'nolocal@': '',
      'a@': '',
      '@': '',
      '': '',
      '   ': '',
      'a@b@c.edu': 'c.edu',
      'a@b@c@univ.edu': 'univ.edu',
      'a@bad domain.com': '',
      'a@.leading.com': '',
      'a@trailing.com.': '',
    };
    for (final e in cases.entries) {
      test('${e.key.isEmpty ? '(empty)' : e.key} -> ${e.value.isEmpty ? '(empty)' : e.value}',
          () {
        expect(orgOf(e.key), e.value);
      });
    }

    test('subdomains exact-match (no stripping)', () {
      expect(orgOf('a@mail.univ.edu'), isNot(equals('univ.edu')));
      expect(orgOf('a@mail.univ.edu'), 'mail.univ.edu');
    });

    test('gmail is a normal org (no blocklist)', () {
      expect(orgOf('a@gmail.com'), 'gmail.com');
      expect(orgOf('a@googlemail.com'), 'gmail.com');
    });
  });

  group('orgFromHd + parseHdFromIdToken', () {
    test('prefers hd when present', () {
      expect(orgFromHd('univ.edu', 'a@other.com'), 'univ.edu');
      expect(orgFromHd('GMAIL.COM', 'a@univ.edu'), 'gmail.com');
      expect(orgFromHd('googlemail.com', 'a@gmail.com'), 'gmail.com');
    });

    test('falls back to email when hd absent', () {
      expect(orgFromHd(null, 'a@univ.edu'), 'univ.edu');
      expect(orgFromHd('', 'a@univ.edu'), 'univ.edu');
      expect(orgFromHd('  ', 'a@univ.edu'), 'univ.edu');
    });

    String jwtWith(Map<String, dynamic> payload) {
      String b64(Map<String, dynamic> m) => base64Url
          .encode(utf8.encode(jsonEncode(m)))
          .replaceAll('=', '');
      return '${b64({'alg': 'RS256'})}.${b64(payload)}.sig';
    }

    test('parses hd out of an idToken JWT', () {
      expect(parseHdFromIdToken(jwtWith({'hd': 'univ.edu'})), 'univ.edu');
      expect(parseHdFromIdToken(jwtWith({})), isNull);
      expect(parseHdFromIdToken(null), isNull);
      expect(parseHdFromIdToken('garbage'), isNull);
    });
  });

  group('inMyOrg', () {
    test('strict equality when both stamped', () {
      expect(inMyOrg('univ.edu', 'univ.edu'), isTrue);
      expect(inMyOrg('a.edu', 'b.edu'), isFalse);
      expect(inMyOrg('mail.univ.edu', 'univ.edu'), isFalse);
    });

    test('legacy empty passes locally', () {
      expect(inMyOrg('', 'univ.edu'), isTrue);
      expect(inMyOrg('univ.edu', ''), isTrue);
      expect(inMyOrg('', ''), isTrue);
    });

    test('record convenience mirrors string version', () {
      final r = ClassRecord(
          classLabel: 'c', dateIso: '2026-01-01', org: 'univ.edu');
      expect(recordInMyOrg(r, 'univ.edu'), isTrue);
      expect(recordInMyOrg(r, 'other.edu'), isFalse);
    });
  });

  group('sessionToDoc stamping', () {
    test('unstamped record takes prof org (creation)', () {
      final r = ClassRecord(classLabel: 'c', dateIso: '2026-01-01');
      final d = sessionToDoc(
          profUid: 'u',
          profEmail: 'p@univ.edu',
          profName: 'P',
          record: r);
      expect(d['org'], 'univ.edu');
    });

    test('stamped record keeps org (immutable on update)', () {
      final r = ClassRecord(
          classLabel: 'c', dateIso: '2026-01-01', org: 'univ.edu');
      final d = sessionToDoc(
          profUid: 'u',
          profEmail: 'p@other.edu',
          profName: 'P',
          record: r,
          profOrg: 'other.edu');
      expect(d['org'], 'univ.edu');
    });

    test('explicit profOrg wins for legacy records', () {
      final r = ClassRecord(classLabel: 'c', dateIso: '2026-01-01');
      final d = sessionToDoc(
          profUid: 'u',
          profEmail: 'p@univ.edu',
          profName: 'P',
          record: r,
          profOrg: 'hd.edu');
      expect(d['org'], 'hd.edu');
    });

    test('docToRecord round-trips org (tolerant of missing)', () {
      final r = ClassRecord(
          classLabel: 'c', dateIso: '2026-01-01', org: 'univ.edu');
      final d = sessionToDoc(
          profUid: 'u', profEmail: 'p@univ.edu', profName: 'P', record: r);
      expect(docToRecord('id', d).org, 'univ.edu');
      final legacy = Map<String, dynamic>.from(d)..remove('org');
      expect(docToRecord('id', legacy).org, '');
    });
  });

  group('FakeCloudSync org scoping', () {
    test('setRole stamps org from email when blank', () async {
      final f = FakeCloudSync();
      await f.setRole(RoleDoc(
          uid: 'u', email: 'p@univ.edu', name: 'P', roles: const ['prof']));
      expect(f.roles['u']!.org, 'univ.edu');
    });

    test('pullProfSessions filters by org', () async {
      final f = FakeCloudSync();
      await f.pushSession(
          profUid: 'u',
          profEmail: 'p@univ.edu',
          profName: 'P',
          record: ClassRecord(
              id: 'a', classLabel: 'c', dateIso: '2026-01-01', org: 'univ.edu'));
      await f.pushSession(
          profUid: 'u',
          profEmail: 'p@other.edu',
          profName: 'P',
          record: ClassRecord(
              id: 'b', classLabel: 'c', dateIso: '2026-01-01', org: 'other.edu'));
      final mine = await f.pullProfSessions('u', org: 'univ.edu');
      expect(mine.map((r) => r.id), ['a']);
      final all = await f.pullProfSessions('u');
      expect(all.length, 2);
    });

    test('searchStudents filters by org', () async {
      final f = FakeCloudSync();
      f.dir['a@univ.edu'] = const syncdir.StudentDirectoryEntry(
          email: 'a@univ.edu', name: 'A', roll: '1', org: 'univ.edu');
      f.dir['b@other.edu'] = const syncdir.StudentDirectoryEntry(
          email: 'b@other.edu', name: 'B', roll: '1', org: 'other.edu');
      final hits =
          await f.searchStudents(rollPrefix: '1', org: 'univ.edu');
      expect(hits.map((e) => e.email), ['a@univ.edu']);
    });

    test('claim stamps all three docs with org', () async {
      final f = FakeCloudSync();
      await f.claimStudentDevice(
          doc: const StudentDeviceDoc(
              email: 's@univ.edu',
              uid: 'u',
              pkHex: 'aa',
              name: 'S',
              roll: '1',
              modelVer: 'm',
              installId: 'i',
              platform: 'p'),
          installId: 'i');
      expect(f.devices['s@univ.edu']!.org, 'univ.edu');
      expect(f.dir['s@univ.edu']!.org, 'univ.edu');
    });
  });

  group('student join-gate predicates', () {
    test('studentOrgOf prefers explicit org, else gmail domain', () {
      expect(
          RealStudentDriver.studentOrgOf(const LinkedIdentity(
              name: 'S', gmail: 's@other.com', org: 'univ.edu')),
          'univ.edu');
      expect(
          RealStudentDriver.studentOrgOf(
              const LinkedIdentity(name: 'S', gmail: 'S@Univ.EDU')),
          'univ.edu');
    });

    test('beacon pre-check: mismatch false, legacy true', () {
      expect(
          RealStudentDriver.beaconOrgAllows(
              beaconOrg: 'other.edu', myOrg: 'univ.edu'),
          isFalse);
      expect(
          RealStudentDriver.beaconOrgAllows(
              beaconOrg: '', myOrg: 'univ.edu'),
          isTrue);
      expect(
          RealStudentDriver.beaconOrgAllows(
              beaconOrg: 'univ.edu', myOrg: 'univ.edu'),
          isTrue);
    });
  });

  group('ProxServer org gate (live offline)', () {
    test('/prove + /waiting + /manual-request reject cross-org, allow same',
        () async {
      final prof = ProxCrypto.generateEdKeypair();
      final server = ProxServer(
        classLabel: 't',
        profSk: prof.privateKey,
        profPk: prof.publicKey,
        sightings: (
                {required peerW,
                required expectedAirKey,
                required expectedUuid}) =>
            const RadioSighting(rssiDbm: -55, hop: 0),
        sessionOrg: 'univ.edu',
      );
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
        // /window carries the org.
        final okClient =
            ProxClient(host: '127.0.0.1', port: server.port);
        try {
          final w = await okClient.probeWindow();
          expect(w.org, 'univ.edu');
        } finally {
          okClient.close();
        }
        // Cross-org /waiting rejects (403), same-org passes.
        ProxClient mk() => ProxClient(host: '127.0.0.1', port: server.port);
        final cross = mk();
        try {
          var rejected = false;
          try {
            await cross.postWaiting(
                email: 's@other.edu', name: 'S', roll: '1', org: 'other.edu');
          } catch (_) {
            rejected = true;
          }
          expect(rejected, isTrue);
          expect(server.waitingCount, 0);
        } finally {
          cross.close();
        }
        final same = mk();
        try {
          await same.postWaiting(
              email: 's@univ.edu', name: 'S', roll: '1', org: 'univ.edu');
          expect(server.waitingCount, 1);
        } finally {
          same.close();
        }
        // Legacy (no org) still passes.
        final legacy = mk();
        try {
          await legacy.postWaiting(email: 'l@x.in', name: 'L');
          expect(server.waitingCount, 2);
        } finally {
          legacy.close();
        }
        // Cross-org /manual-request rejects, same-org passes.
        final mCross = mk();
        try {
          var rejected = false;
          try {
            await mCross.postManualRequest(
                email: 's@other.edu', name: 'S', roll: '1', org: 'other.edu');
          } catch (_) {
            rejected = true;
          }
          expect(rejected, isTrue);
        } finally {
          mCross.close();
        }
        // Cross-org /prove returns invalid(org-mismatch) with no tally.
        // Full radio loop: fetch the real descriptor with the heard
        // challenge, then prove with a foreign org (the gate runs before
        // crypto, so the sig helpers never even matter for the reject).
        final stu = ProxCrypto.generateEdKeypair();
        Uint8List pk32(ed.PublicKey k) =>
            Uint8List.fromList(k.bytes.sublist(0, 32));
        final fetchClient = mk();
        late WindowDescriptor desc;
        late Uint8List cj;
        try {
          cj = server.window!.challengeFor(0);
          desc = await fetchClient.fetchWindow(cj);
          expect(desc.org, 'univ.edu');
        } finally {
          fetchClient.close();
        }
        final proveClient = mk();
        try {
          final res = await proveClient.prove(
            desc: desc,
            studentId: 's@other.edu',
            challenge: cj,
            j: 0,
            faceScore: 1.0,
            peerW: ProxCrypto.peerAlias(pk32(stu.publicKey), desc.windowId),
            name: 'S',
            roll: '1',
            pkS: pk32(stu.publicKey),
            org: 'other.edu',
            sigSFor: (c, jj) => ProxCrypto.signStudentProve(
              studentSk: stu.privateKey,
              sessionId: desc.sessionId,
              windowId: desc.windowId,
              j: jj,
              challenge: c,
              studentId: 's@other.edu',
              faceScore: 1.0,
            ),
            sigBindFor: (fp, jj) => ProxCrypto.sign(
                stu.privateKey,
                bindPreimage(
                    sessionId: desc.sessionId,
                    windowId: desc.windowId,
                    j: jj,
                    tlsFingerprint: fp)),
          );
          expect(res.decision, ProveDecision.invalid);
          expect(res.reason, 'org-mismatch');
          // No tally write: the waiting room ensures rows (empty wins) for
          // admitted emails, but the cross-org prover never lands there and
          // nothing confirms.
          expect(server.tally.search('other.edu'), isEmpty);
          expect(server.tally.presentCount, 0);
        } finally {
          proveClient.close();
        }
      } finally {
        await server.stop();
      }
    });
  });
}
