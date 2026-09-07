// Server attestation re-verification — schema + rules + trigger gate tests.
//
// Covers: StudentDeviceDoc server-verdict defaults, attestationVerifyDue
// gating matrix, the FakeCloudSync verdict lifecycle (claim resets,
// touch preserves), and a rules-text regression pinning the client-write
// deny for kAttestationServerFields (see firestore.rules).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/cloud_sync.dart';

StudentDeviceDoc dev(String email) => StudentDeviceDoc(
      email: email,
      uid: 'u1',
      pkHex: 'aa',
      name: 'S',
      roll: '1',
      modelVer: 'v',
      platform: 'android',
      attestationLevel: 'FULL',
      attestedAtMillis:
          DateTime.utc(2026, 9, 1).millisecondsSinceEpoch,
      attestedUntilMillis:
          DateTime.utc(2026, 12, 1).millisecondsSinceEpoch,
    );

void main() {
  test('server-verdict fields default to unknown/clear', () {
    final d = dev('s@x.in');
    expect(d.attestationAnomaly, isFalse);
    expect(d.serverVerifiedAtMillis, 0);
    expect(d.serverVerifyReason, isEmpty);
    expect(d.attestMaterialJson, isEmpty);
    expect(kAttestationServerFields,
        {'attestationAnomaly', 'serverVerifiedAtMillis', 'serverVerifyReason'});
  });

  test('attestationVerifyDue: unknown or near/past window only', () {
    final now = DateTime.utc(2026, 10, 1);
    int ms(DateTime d) => d.millisecondsSinceEpoch;
    // Never verified -> due even with a fresh window.
    expect(
        attestationVerifyDue(
            attestedUntilMillis: ms(DateTime.utc(2026, 12, 1)),
            serverVerifiedAtMillis: 0,
            now: now),
        isTrue);
    // Stamped + far from expiry -> skip (cheap: not every flush).
    expect(
        attestationVerifyDue(
            attestedUntilMillis: ms(DateTime.utc(2026, 12, 15)),
            serverVerifiedAtMillis: ms(DateTime.utc(2026, 10, 1)),
            now: now),
        isFalse);
    // Stamped + within the 30d lead -> due.
    expect(
        attestationVerifyDue(
            attestedUntilMillis: ms(DateTime.utc(2026, 10, 20)),
            serverVerifiedAtMillis: ms(DateTime.utc(2026, 9, 1)),
            now: now),
        isTrue);
    // Stamped + window past -> due.
    expect(
        attestationVerifyDue(
            attestedUntilMillis: ms(DateTime.utc(2026, 9, 20)),
            serverVerifiedAtMillis: ms(DateTime.utc(2026, 9, 1)),
            now: now),
        isTrue);
    // No window known -> due once (then the stamp stops the repeat).
    expect(
        attestationVerifyDue(
            attestedUntilMillis: 0,
            serverVerifiedAtMillis: ms(DateTime.utc(2026, 9, 1)),
            now: now),
        isTrue);
  });

  test('fake claim resets verdicts; touch preserves them', () async {
    final fake = FakeCloudSync();
    await fake.claimStudentDevice(doc: dev('s@x.in'), installId: 'iA');
    var binding = (await fake.fetchStudentDevice('s@x.in'))!;
    expect(binding.attestationAnomaly, isFalse);
    expect(binding.serverVerifiedAtMillis, 0);
    expect(binding.attestMaterialJson, isEmpty);
    // A server verdict lands (as the endpoint's admin write would)...
    fake.devices['s@x.in'] = StudentDeviceDoc(
      email: binding.email,
      uid: binding.uid,
      pkHex: binding.pkHex,
      name: binding.name,
      roll: binding.roll,
      modelVer: binding.modelVer,
      installId: binding.installId,
      platform: binding.platform,
      org: binding.org,
      createdAtMillis: binding.createdAtMillis,
      lastMoveAtMillis: binding.lastMoveAtMillis,
      lastSeenAtMillis: binding.lastSeenAtMillis,
      updatedAtMillis: binding.updatedAtMillis,
      moveCount: binding.moveCount,
      pkDHex: binding.pkDHex,
      attestationLevel: binding.attestationLevel,
      attestedAtMillis: binding.attestedAtMillis,
      attestedUntilMillis: binding.attestedUntilMillis,
      attestationAnomaly: true,
      serverVerifiedAtMillis: 123,
      serverVerifyReason: 'challenge-mismatch',
      attestMaterialJson: binding.attestMaterialJson,
    );
    // ...heartbeat touch keeps it (recency only, never verdicts).
    expect(
        await fake.touchStudentDevice(
            emailLower: 's@x.in', pkHex: 'aa', installId: 'iA'),
        isTrue);
    binding = (await fake.fetchStudentDevice('s@x.in'))!;
    expect(binding.attestationAnomaly, isTrue);
    expect(binding.serverVerifiedAtMillis, 123);
    expect(binding.serverVerifyReason, 'challenge-mismatch');
  });

  test('firestore.rules denies client writes to the server-verdict fields',
      () {
    final rules = File('firestore.rules').readAsStringSync();
    // Guard helpers exist and cover every field in kAttestationServerFields.
    for (final f in kAttestationServerFields) {
      expect(rules, contains(f),
          reason: 'rules must guard server field $f');
    }
    expect(rules, contains('attestServerFieldsDefault'));
    expect(rules, contains('attestServerFieldsUnchanged'));
    // The studentDevices create/update actually enforce them (not dead
    // helpers): both guards are referenced after their definitions.
    final defUse = rules.indexOf('attestServerFieldsDefault()');
    final createUse = rules.indexOf('allow create', rules.indexOf('studentDevices'));
    expect(defUse > createUse, isTrue);
    final unchUse = rules.indexOf('attestServerFieldsUnchanged()');
    final updateUse = rules.indexOf('allow update', rules.indexOf('studentDevices'));
    expect(unchUse > updateUse, isTrue);
  });

  group('FakeCloudSync.verifyAttestationChain (coherence mirror)', () {
    test('NONE skips with a stamp, FULL without material flags', () async {
      final fake = FakeCloudSync();
      await fake.claimStudentDevice(doc: dev('s@x.in'), installId: 'iA');
      // FULL + empty pkD/material (dev() stamps no pkDHex): missing-material.
      var out = await fake.verifyAttestationChain(
          emailLower: 's@x.in', org: 'x.in');
      expect(out.ok, isTrue);
      expect(out.anomaly, isTrue);
      expect(out.reason, 'missing-material');
      expect(out.serverVerifiedAtMillis, greaterThan(0));
      var binding = (await fake.fetchStudentDevice('s@x.in'))!;
      expect(binding.attestationAnomaly, isTrue);
      expect(binding.serverVerifyReason, 'missing-material');
      // NONE short-circuits to a clear stamp.
      fake.devices['s@x.in'] = StudentDeviceDoc(
        email: binding.email,
        uid: binding.uid,
        pkHex: binding.pkHex,
        name: binding.name,
        roll: binding.roll,
        modelVer: binding.modelVer,
        installId: binding.installId,
        platform: binding.platform,
        org: binding.org,
        createdAtMillis: binding.createdAtMillis,
        lastMoveAtMillis: binding.lastMoveAtMillis,
        lastSeenAtMillis: binding.lastSeenAtMillis,
        updatedAtMillis: binding.updatedAtMillis,
        moveCount: binding.moveCount,
        attestationLevel: 'NONE',
      );
      out = await fake.verifyAttestationChain(
          emailLower: 's@x.in', org: 'x.in');
      expect(out.ok, isTrue);
      expect(out.anomaly, isFalse);
      expect(out.reason, 'skipped-none');
      binding = (await fake.fetchStudentDevice('s@x.in'))!;
      expect(binding.attestationAnomaly, isFalse);
    });

    test('FULL with material passes; offline/unknown defers', () async {
      final fake = FakeCloudSync();
      await fake.claimStudentDevice(
          doc: StudentDeviceDoc(
            email: 's@x.in',
            uid: 'u1',
            pkHex: 'aa',
            name: 'S',
            roll: '1',
            modelVer: 'v',
            platform: 'android',
            attestationLevel: 'FULL',
            pkDHex: 'ab' * 32,
            attestMaterialJson: '{"chain":[]}',
          ),
          installId: 'iA');
      final out = await fake.verifyAttestationChain(
          emailLower: 'S@X.IN', org: 'x.in');
      expect(out.ok, isTrue);
      expect(out.anomaly, isFalse);
      // Unknown binding + offline both defer without flagging.
      expect(
          (await fake.verifyAttestationChain(
                  emailLower: 'nobody@x.in', org: 'x.in'))
              .ok,
          isFalse);
      fake.online = false;
      final before =
          (await fake.fetchStudentDevice('s@x.in'))!.serverVerifiedAtMillis;
      final deferred = await fake.verifyAttestationChain(
          emailLower: 's@x.in', org: 'x.in');
      expect(deferred.ok, isFalse);
      expect(deferred.reason, 'unreachable');
      expect((await fake.fetchStudentDevice('s@x.in'))!.serverVerifiedAtMillis,
          before);
    });
  });

  group('FirestoreCloudSync.verifyAttestationChain (injected HTTP)', () {
    test('posts no-arg callable with bearer token, parses verdict',
        () async {
      Uri? gotUrl;
      Map<String, String>? gotHeaders;
      String? gotBody;
      final cloud = FirestoreCloudSync(
        idTokenOf: () async => 'tok123',
        postJson: (url, headers, body) async {
          gotUrl = url;
          gotHeaders = headers;
          gotBody = body;
          return (
            status: 200,
            json: {
              'result': {
                'verified': true,
                'anomaly': true,
                'reason': 'challenge-mismatch',
                'serverVerifiedAtMillis': 777,
              }
            }
          );
        },
      );
      final out = await cloud.verifyAttestationChain(
          emailLower: 's@x.in', org: 'x.in');
      expect(out.ok, isTrue);
      expect(out.anomaly, isTrue);
      expect(out.reason, 'challenge-mismatch');
      expect(out.serverVerifiedAtMillis, 777);
      expect(gotUrl.toString(), kVerifyAttestationUrl);
      expect(gotHeaders!['Authorization'], 'Bearer tok123');
      expect(gotHeaders!['Content-Type'], 'application/json');
      // No client args: the endpoint verifies from Auth identity.
      expect(gotBody, '{"data":{}}');
    });

    test('error bodies, non-200s, throws and missing token all defer',
        () async {
      var posts = 0;
      Future<({int status, Map<String, dynamic> json})> err(
              Uri u, Map<String, String> h, String b) async {
        posts++;
        return (
          status: 200,
          json: {
            'error': {'status': 'NOT_FOUND', 'message': 'nope'}
          }
        );
      }

      var out = await FirestoreCloudSync(
              idTokenOf: () async => 't', postJson: err)
          .verifyAttestationChain(emailLower: 's@x.in', org: 'x.in');
      expect(out.ok, isFalse);
      expect(out.reason, 'server-not_found');

      out = await FirestoreCloudSync(
          idTokenOf: () async => 't',
          postJson: (_, __, ___) async =>
              (status: 503, json: <String, dynamic>{})).verifyAttestationChain(
          emailLower: 's@x.in', org: 'x.in');
      expect(out.ok, isFalse);

      out = await FirestoreCloudSync(
          idTokenOf: () async => 't',
          postJson: (_, __, ___) async =>
              throw StateError('socket')).verifyAttestationChain(
          emailLower: 's@x.in', org: 'x.in');
      expect(out.ok, isFalse);
      expect(out.reason, 'unreachable');

      // No token provider (or empty token): no POST at all.
      posts = 0;
      out = await FirestoreCloudSync(postJson: err).verifyAttestationChain(
          emailLower: 's@x.in', org: 'x.in');
      expect(out.ok, isFalse);
      expect(posts, 0);
      out = await FirestoreCloudSync(
              idTokenOf: () async => '', postJson: err)
          .verifyAttestationChain(emailLower: 's@x.in', org: 'x.in');
      expect(out.ok, isFalse);
      expect(posts, 0);
    });
  });
}
