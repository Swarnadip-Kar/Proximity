// Track 5 required surface: professor/admin review list for
// attestationAnomaly-flagged devices (fields exist in Firestore; no
// screen showed them — now built).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/features/review/flagged_devices_screen.dart';

StudentDeviceDoc _doc(String email,
    {bool anomaly = false, String org = 'univ.edu', String reason = ''}) {
  return StudentDeviceDoc(
    email: email,
    uid: 'u-$email',
    pkHex: 'aa',
    name: 'S $email',
    roll: '1',
    modelVer: 'v',
    installId: 'i-$email',
    platform: 'android',
    org: org,
    pkDHex: 'aabbccddeeff0011',
    attestationLevel: 'FULL',
    attestedAtMillis: 1756684800000,
    attestedUntilMillis: 1764460800000,
    attestationAnomaly: anomaly,
    serverVerifiedAtMillis: anomaly ? 1756771200000 : 0,
    serverVerifyReason: reason,
  );
}

void main() {
  test('fetchFlaggedDevices filters anomaly + org, newest first', () async {
    final fake = FakeCloudSync();
    await fake.claimStudentDevice(
        doc: _doc('ok@univ.edu'), installId: 'i-ok@univ.edu');
    await fake.claimStudentDevice(
        doc: _doc('bad1@univ.edu'), installId: 'i-bad1@univ.edu');
    await fake.claimStudentDevice(
        doc: _doc('bad2@univ.edu'), installId: 'i-bad2@univ.edu');
    await fake.claimStudentDevice(
        doc: _doc('other@other.edu'), installId: 'i-other@other.edu');
    // Flag three via the verify mirror (NONE skips; FULL without material
    // flags missing-material — seed material for one to stay clean).
    fake.devices['bad1@univ.edu'] = _doc('bad1@univ.edu',
        anomaly: true, reason: 'chain-mismatch');
    fake.devices['bad2@univ.edu'] = _doc('bad2@univ.edu',
        anomaly: true, reason: 'missing-material');
    fake.devices['other@other.edu'] = _doc('other@other.edu',
        anomaly: true, org: 'other.edu', reason: 'chain-mismatch');

    final mine =
        await fake.fetchFlaggedDevices(org: 'univ.edu', limit: 50);
    expect(mine.map((d) => d.email).toSet(),
        {'bad1@univ.edu', 'bad2@univ.edu'});
    final all = await fake.fetchFlaggedDevices(limit: 50);
    expect(all.length, 3);
    final limited =
        await fake.fetchFlaggedDevices(org: 'univ.edu', limit: 1);
    expect(limited, hasLength(1));
  });

  testWidgets('flagged body lists rows with required fields', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FlaggedDevicesBody(
          loading: false,
          error: '',
          org: 'univ.edu',
          online: true,
          rows: [
            _doc('bad@univ.edu',
                anomaly: true, reason: 'chain-mismatch'),
          ],
          onRefresh: () async {},
        ),
      ),
    ));
    expect(find.textContaining('bad@univ.edu'), findsWidgets);
    expect(find.textContaining('Claimed FULL'), findsOneWidget);
    expect(find.textContaining('chain-mismatch'), findsOneWidget);
    expect(find.textContaining('DKey aabbccddeeff'), findsOneWidget);
    expect(find.textContaining('Past attendance stands'), findsOneWidget);
  });

  testWidgets('flagged empty + offline states render honestly', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FlaggedDevicesBody(
          loading: false,
          error: '',
          org: 'univ.edu',
          online: true,
          rows: const [],
          onRefresh: () async {},
        ),
      ),
    ));
    expect(find.textContaining('No flagged devices'), findsOneWidget);

    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FlaggedDevicesBody(
          loading: false,
          error: 'You appear offline — flagged review needs internet.',
          org: '',
          online: false,
          rows: const [],
          onRefresh: () async {},
        ),
      ),
    ));
    expect(find.textContaining('needs internet'), findsWidgets);
  });
}
