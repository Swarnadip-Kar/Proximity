import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_face/face.dart';

const _email = 'student@example.com';

EnrollmentController makeCtl({
  String email = _email,
  DeviceStore? store,
}) =>
    EnrollmentController(
      auth: FakeAuthService(SignedAccount(email: email, displayName: 'Student One')),
      store: store ?? InMemoryDeviceStore(),
      embedder: MockFaceEmbedder(
        enrolled: const [1, 0, 0, 0],
        probe: const [1, 0, 0, 0],
      ),
    );

/// Completes all five guided-pose slots (2 stills each) for [ctl].
Future<void> enrollSlots(EnrollmentController ctl) async {
  for (var i = 0; i < 5; i++) {
    await ctl.captureSlot(i, const [
      [1],
      [2]
    ]);
  }
}

/// Embedder returning a rotating vector sequence: simulates a second
/// person leaning into frame mid-enrollment.
class _SeqEmbedder implements FaceEmbedder {
  final List<List<double>> seq;
  var _i = 0;
  _SeqEmbedder(this.seq);
  @override
  Future<List<double>> embed(List<int> frameBytes) async =>
      seq[(_i++) % seq.length];
  @override
  Future<bool> checkLiveness(List<int> frameBytes, String prompt) async =>
      true;
}

void main() {
  test('happy path links Gmail identity + saves key on device', () async {
    final store = InMemoryDeviceStore();
    final ctl = makeCtl(store: store);
    await ctl.signIn();
    expect(ctl.state.phase, EnrollPhase.signedIn);
    expect(ctl.state.account?.email, _email);
    await ctl.generateKey();
    expect(ctl.state.phase, EnrollPhase.keyReady);
    expect(ctl.state.pkHex.length, 64);
    await enrollSlots(ctl);
    expect(ctl.state.phase, EnrollPhase.faceDone);
    ctl.setRoll('12342210');
    final id = await ctl.upload();
    expect(ctl.state.phase, EnrollPhase.uploaded);
    expect(id?.gmail, _email);
    expect(id?.name, 'Student One');
    // Offline-local: identity + key live in secure device storage, and
    // nowhere else — no roster, no upload.
    final stored = await store.readEnrollment();
    expect(stored?.email, _email);
    expect(stored?.name, 'Student One');
    expect(stored?.pkHex, ctl.state.pkHex);
    expect(stored?.roll, '12342210');
  });

  test('new key replaces the old one locally (no server round-trip)',
      () async {
    final store = InMemoryDeviceStore();
    final first = makeCtl(store: store);
    await first.signIn();
    first.setRoll('12342210');
    await first.generateKey();
    final pk1 = first.state.pkHex;
    await enrollSlots(first);
    await first.upload();
    expect(first.state.phase, EnrollPhase.uploaded);

    // Same email, fresh keypair: offline-local phase simply replaces.
    final second = makeCtl(store: store);
    await second.signIn();
    await second.generateKey();
    expect(second.state.phase, EnrollPhase.keyReady);
    expect(second.state.pkHex, isNot(pk1));
  });

  test('roll number saved unverified with the profile', () async {
    final store = InMemoryDeviceStore();
    final ctl = makeCtl(store: store);
    await ctl.signIn();
    ctl.setRoll('12342210');
    await ctl.generateKey();
    await enrollSlots(ctl);
    final id = await ctl.upload();
    expect(id?.roll, '12342210');
    expect((await store.readEnrollment())?.roll, '12342210');
  });

  test('pickUpAccount adopts the persisted session without a tap', () async {
    // The enrollment page must not force a second Google tap: students
    // signed in on the landing before reaching here. No preseed (as at
    // real startup for post-launch sign-ins) — the live session is picked
    // up silently in the background.
    final ctl = EnrollmentController(
      auth: FakeAuthService(
          SignedAccount(email: _email, displayName: 'Student One')),
      store: InMemoryDeviceStore(),
      embedder: MockFaceEmbedder(
        enrolled: const [1, 0, 0, 0],
        probe: const [1, 0, 0, 0],
      ),
    );
    expect(ctl.state.account, isNull);
    await ctl.pickUpAccount();
    expect(ctl.state.account?.email, _email);
    expect(ctl.state.phase, EnrollPhase.signedIn);
    // Second call is a no-op (never clobbers).
    await ctl.pickUpAccount();
    expect(ctl.state.account?.email, _email);
  });

  test('pickUpAccount with no session keeps the manual button path', () async {
    final ctl = EnrollmentController(
      auth: FakeAuthService(),
      store: InMemoryDeviceStore(),
      embedder: MockFaceEmbedder(
        enrolled: const [1, 0, 0, 0],
        probe: const [1, 0, 0, 0],
      ),
    );
    await ctl.pickUpAccount();
    expect(ctl.state.account, isNull);
    expect(ctl.state.phase, EnrollPhase.signedOut);
  });

  test('missing ID number blocks upload until entered', () async {    final ctl = makeCtl();
    await ctl.signIn();
    await ctl.generateKey();
    await enrollSlots(ctl);
    expect(await ctl.upload(), isNull);
    expect(ctl.state.phase, EnrollPhase.error);
    expect(ctl.state.message, contains('ID number'));
    ctl.setRoll('12342210');
    ctl.dismissError();
    final id = await ctl.upload();
    expect(ctl.state.phase, EnrollPhase.uploaded);
    expect(id?.roll, '12342210');
  });

  test('same-device sign-in restores key without re-enrolling', () async {
    final store = InMemoryDeviceStore();
    final first = makeCtl(store: store);
    await first.signIn();
    first.setRoll('12342210');
    await first.generateKey();
    final pk = first.state.pkHex;
    await enrollSlots(first);
    await first.upload();
    expect(first.state.phase, EnrollPhase.uploaded);

    // New controller, same device store: key + template restore locally.
    final second = makeCtl(store: store);
    await second.signIn();
    expect(second.state.phase, EnrollPhase.uploaded);
    expect(second.state.restored, isTrue);
    expect(second.state.pkHex, pk);
    expect(second.currentIdentity?.roll, '12342210');
    // Regression: restore must NEVER invent a 1.00 match score — nothing
    // was scanned. Score stays 0 with an honest message until re-scan.
    expect(second.state.faceScore, 0);
    expect(second.state.message, contains('no fresh'));
  });

  test('restored enrollment can re-scan face without losing the key',
      () async {
    final store = InMemoryDeviceStore();
    final first = makeCtl(store: store);
    await first.signIn();
    first.setRoll('12342210');
    await first.generateKey();
    final pk = first.state.pkHex;
    await enrollSlots(first);
    await first.upload();

    final second = makeCtl(store: store);
    await second.signIn();
    expect(second.state.phase, EnrollPhase.uploaded);
    second.restartFace();
    expect(second.state.phase, EnrollPhase.keyReady);
    expect(second.state.pkHex, pk);
    await enrollSlots(second);
    expect(second.state.phase, EnrollPhase.faceDone);
    // Hold-out validation scores a REAL verification (mock vectors are
    // degenerate-identical, so the mock scores 1.0 — the point is the
    // score comes from verify(), not from self-comparison).
    expect(second.state.faceScore, greaterThan(0));
  });

  test('stale pipeline template forces face recapture, keeps key', () async {
    final store = InMemoryDeviceStore();
    // Pre-alignfix enrollment already on this device: key valid, face stale.
    await store.writeEnrollment(StoredEnrollment(
      email: _email,
      name: 'Student One',
      roll: '12342210',
      seedHex: 'ab' * 32,
      pkHex: 'cd' * 32,
      templateCsv: '1.0,0.0,0.0,0.0',
      enrolledAt: DateTime.now().toUtc(),
      modelVer: 'edgeface-xs-g06-tflite-1',
    ));
    final ctl = makeCtl(store: store);
    await ctl.signIn();
    // Key restored but face step reopened — never auto-advanced with a
    // stale score.
    expect(ctl.state.phase, EnrollPhase.keyReady);
    expect(ctl.state.faceScore, 0);
    expect(ctl.state.message, contains('scan your face again'));
    await enrollSlots(ctl);
    expect(ctl.state.phase, EnrollPhase.faceDone);
    final id = await ctl.upload();
    expect(ctl.state.phase, EnrollPhase.uploaded);
    expect(id?.roll, '12342210');
  });

  test('failed face capture never advances: error, score 0, upload blocked',
      () async {
    // Liveness fails the self-check → the non-pass branch. Regression:
    // the template must NOT be stored, or dismissError would land on
    // faceDone with score 0 and upload would accept a bad enrollment.
    final ctl = EnrollmentController(
      auth: FakeAuthService(SignedAccount(email: _email, displayName: 'Student One')),
      store: InMemoryDeviceStore(),
      embedder: MockFaceEmbedder(
        enrolled: const [1, 0, 0, 0],
        probe: const [1, 0, 0, 0],
        liveness: false,
      ),
    );
    await ctl.signIn();
    await ctl.generateKey();
    expect(ctl.state.phase, EnrollPhase.keyReady);
    await enrollSlots(ctl);
    // Hold-out fails (liveness): weakest slot alone drops for a rescan —
    // the template is NOT stored, so retry/upload stay safe with progress.
    expect(ctl.state.phase, EnrollPhase.keyReady);
    expect(ctl.state.faceScore, 0);
    expect(ctl.state.angleSlots, [false, true, true, true, true]);
    expect(ctl.state.message, contains('good light'));
    // Retry lands back on the key step, not faceDone…
    ctl.dismissError();
    expect(ctl.state.phase, EnrollPhase.keyReady);
    // …and upload stays blocked without a passed capture.
    expect(await ctl.upload(), isNull);
  });

  test('mixed-identity slot is dropped alone, progress kept', () async {
    final ctl = EnrollmentController(
      auth: FakeAuthService(SignedAccount(email: _email, displayName: 'Student One')),
      store: InMemoryDeviceStore(),
      embedder: _SeqEmbedder(const [
        [1, 0, 0, 0],
        [0, 1, 0, 0], // intruder leaning into the Front slot
      ]),
    );
    await ctl.signIn();
    await ctl.generateKey();
    await ctl.captureSlot(0, const [
      [1],
      [2]
    ]);
    // Only the mixed slot is dropped — phase stays on the key step with
    // other slots' progress intact, never an error dead-end.
    expect(ctl.state.phase, EnrollPhase.keyReady);
    expect(ctl.state.angleSlots, [false, false, false, false, false]);
    expect(ctl.state.faceScore, 0);
    expect(ctl.state.message, contains('mixed faces'));
    expect(await ctl.upload(), isNull);
  });

  test('slot pair at 0.68 is dropped by the 0.70 bar', () async {
    // Boundary: a 0.68 same-pose pair is a bad frame, never a pass.
    final ctl = EnrollmentController(
      auth: FakeAuthService(SignedAccount(email: _email, displayName: 'Student One')),
      store: InMemoryDeviceStore(),
      embedder: _SeqEmbedder(const [
        [1, 0, 0, 0],
        [0.68, 0.7332, 0, 0], // cosine 0.68 vs the first frame
      ]),
    );
    await ctl.signIn();
    await ctl.generateKey();
    await ctl.captureSlot(0, const [
      [1],
      [2]
    ]);
    expect(ctl.state.phase, EnrollPhase.keyReady);
    expect(ctl.state.angleSlots, [false, false, false, false, false]);
    expect(ctl.state.message, contains('mixed faces'));
  });

  test('slot pair at 0.73 clears the 0.70 bar', () async {
    // Boundary: a 0.73 same-pose pair lands the slot (progress kept;
    // faceDone still needs all five slots + the hold-out).
    final ctl = EnrollmentController(
      auth: FakeAuthService(SignedAccount(email: _email, displayName: 'Student One')),
      store: InMemoryDeviceStore(),
      embedder: _SeqEmbedder(const [
        [1, 0, 0, 0],
        [0.73, 0.6835, 0, 0], // cosine 0.73 vs the first frame
      ]),
    );
    await ctl.signIn();
    await ctl.generateKey();
    await ctl.captureSlot(0, const [
      [1],
      [2]
    ]);
    expect(ctl.state.phase, EnrollPhase.keyReady);
    expect(ctl.state.angleSlots, [true, false, false, false, false]);
    expect(await ctl.upload(), isNull);
  });

  test('odd slot out is dropped, matching slots kept', () async {
    // Slots 0+1+3+4 agree (same person), slot 2 is somebody else: only
    // slot 2 is dropped for a targeted rescan; the rest land normally.
    final ctl = EnrollmentController(
      auth: FakeAuthService(SignedAccount(email: _email, displayName: 'Student One')),
      store: InMemoryDeviceStore(),
      embedder: _SeqEmbedder(const [
        [1, 0, 0, 0],
        [1, 0, 0, 0],
        [1, 0, 0, 0],
        [1, 0, 0, 0],
        [0, 1, 0, 0],
        [0, 1, 0, 0],
        [1, 0, 0, 0],
        [1, 0, 0, 0],
        [1, 0, 0, 0],
        [1, 0, 0, 0],
      ]),
    );
    await ctl.signIn();
    await ctl.generateKey();
    for (var i = 0; i < 5; i++) {
      await ctl.captureSlot(i, const [
        [1],
        [2]
      ]);
    }
    expect(ctl.state.phase, EnrollPhase.keyReady);
    expect(ctl.state.angleSlots, [true, true, false, true, true]);
    expect(ctl.state.message, contains('Right angle'));
    expect(await ctl.upload(), isNull);
  });

  test('pose-spread slots finalize (global bar tolerates turns)', () async {
    // Same person across guided poses: slot means pair at ~0.55
    // (measured 0.50+ on real turned portraits) — must pass the global
    // bar set for intruders (~0.0).
    final ctl = EnrollmentController(
      auth: FakeAuthService(SignedAccount(email: _email, displayName: 'Student One')),
      store: InMemoryDeviceStore(),
      embedder: _SeqEmbedder(const [
        [1, 0, 0, 0],
        [1, 0, 0, 0],
        [0.55, 0.835, 0, 0], // turned pose, same person
        [0.55, 0.835, 0, 0],
        [1, 0, 0, 0],
        [1, 0, 0, 0],
        [1, 0, 0, 0],
        [1, 0, 0, 0],
        [1, 0, 0, 0],
        [1, 0, 0, 0],
      ]),
    );
    await ctl.signIn();
    await ctl.generateKey();
    await enrollSlots(ctl);
    expect(ctl.state.phase, EnrollPhase.faceDone);
    expect(ctl.state.faceScore, greaterThan(0.60));
  });

  test('hold-out at 0.45 refuses enrollment (0.50 minimum)', () async {
    // Cross-pose floor: the held-out centre frame vs the left+right mean
    // must clear 0.50 — a 0.45 same-person read is a bad capture day
    // (poor light/blur), never a pass. Within-slot pairs are perfect
    // (1.0) so only the hold-out decides. The weakest slot alone is
    // dropped for a targeted rescan — the others stay, never a wipe.
    // (0.78, by contrast, PASSES: cross-pose same-person reads 0.50–0.57
    // measured, so 0.78 is a good capture, not a failure.)
    final ctl = EnrollmentController(
      auth: FakeAuthService(SignedAccount(email: _email, displayName: 'Student One')),
      store: InMemoryDeviceStore(),
      embedder: _SeqEmbedder(const [
        [1, 0, 0, 0],
        [1, 0, 0, 0],
        [0.45, 0.8930, 0, 0], // side slots: cosine 0.45 vs centre
        [0.45, 0.8930, 0, 0],
        [0.45, 0.8930, 0, 0],
        [0.45, 0.8930, 0, 0],
        [1, 0, 0, 0],
        [1, 0, 0, 0],
        [1, 0, 0, 0],
        [1, 0, 0, 0],
        [1, 0, 0, 0], // 11th embed: the hold-out centre verify frame
      ]),
    );
    await ctl.signIn();
    await ctl.generateKey();
    await enrollSlots(ctl);
    expect(ctl.state.phase, isNot(EnrollPhase.faceDone));
    expect(ctl.state.phase, EnrollPhase.keyReady);
    // Weakest side slot (Left) dropped alone; the rest kept.
    expect(ctl.state.angleSlots, [true, false, true, true, true]);
    expect(ctl.state.faceScore, 0);
    expect(ctl.state.message, contains('Left angle'));
    expect(ctl.state.message, contains('good light'));
    expect(await ctl.upload(), isNull);
  });

  test('no agreeing pair drops only the worst slot, keeps four', () async {
    // Field bug: scanning the last angle with zero pairwise agreement
    // wiped the whole set. Now only the single weakest slot goes.
    // All pairs here sit at ≤0 (best 0 < 0.35 bar), so only the first
    // minimum (Centre) is dropped — the other four are kept, never a wipe.
    final ctl = EnrollmentController(
      auth: FakeAuthService(SignedAccount(email: _email, displayName: 'Student One')),
      store: InMemoryDeviceStore(),
      embedder: _SeqEmbedder(const [
        [1, 0, 0, 0],
        [1, 0, 0, 0],
        [0, 1, 0, 0],
        [0, 1, 0, 0],
        [0, 0, 1, 0],
        [0, 0, 1, 0],
        [0, 0, 0, 1],
        [0, 0, 0, 1],
        [-1, 0, 0, 0],
        [-1, 0, 0, 0],
      ]),
    );
    await ctl.signIn();
    await ctl.generateKey();
    await enrollSlots(ctl);
    expect(ctl.state.phase, EnrollPhase.keyReady);
    // Exactly one slot dropped, the others kept — never a wipe.
    expect(ctl.state.angleSlots, [false, true, true, true, true]);
    expect(ctl.state.message, contains('Centre angle'));
    expect(await ctl.upload(), isNull);
  });

  test('resume helpers map slots without inventing sections', () {
    expect(firstMissingSlot([false, false, false, false, false]), 0);
    expect(firstMissingSlot([true, true, false, true, true]), 2);
    expect(firstMissingSlot([true, true, true, true, true]), -1);
    // Sparse resume: only the missing slots scan — a dropped middle slot
    // never forces re-capture of already-good later angles.
    expect(missingSlots([false, false, false, false, false]), [0, 1, 2, 3, 4]);
    expect(missingSlots([true, false, true, true, true]), [1]);
    expect(missingSlots([true, false, false, true, true]), [1, 2]);
    expect(missingSlots([true, true, true, true, true]), isEmpty);
    expect(
        slotPairs(const [
          [1],
          [2],
          [3]
        ]),
        [
          [
            [1],
            [2]
          ]
        ]);
    expect(slotPairs(const []), isEmpty);
    expect(scanButtonLabel([false, false, false, false, false]), 'Scan all angles');
    expect(scanButtonLabel([true, true, true, true, false]),
        'Scan remaining angle (1 left)');
    expect(scanButtonLabel([true, false, false, true, true]),
        'Scan remaining angles (2 left)');
  });

  test('restartFace mid-enrollment clears slots but keeps the key', () async {
    // The Start-over escape hatch: a slot stuck in a drop→rescan loop
    // never traps the holder — all angles clear, the key survives, and
    // the next tap re-scans all five from a fresh start.
    final ctl = makeCtl();
    await ctl.signIn();
    await ctl.generateKey();
    final pk = ctl.state.pkHex;
    await ctl.captureSlot(0, const [
      [1],
      [2]
    ]);
    expect(ctl.state.angleSlots, [true, false, false, false, false]);
    ctl.restartFace();
    expect(ctl.state.phase, EnrollPhase.keyReady);
    expect(ctl.state.pkHex, pk);
    expect(ctl.state.angleSlots, [false, false, false, false, false]);
    expect(ctl.state.faceScore, 0);
  });

  test('partial scan cannot save: upload needs all five slots', () async {
    final ctl = makeCtl();
    await ctl.signIn();
    await ctl.generateKey();
    await ctl.captureSlot(0, const [
      [1],
      [2]
    ]);
    expect(ctl.state.angleSlots, [true, false, false, false, false]);
    expect(await ctl.upload(), isNull);
    expect(ctl.state.phase, EnrollPhase.error);
    expect(ctl.state.message, contains('5 face angles'));
    ctl.dismissError();
    // Back on the key step with progress kept — never faceDone on partial.
    expect(ctl.state.phase, EnrollPhase.keyReady);
    expect(ctl.state.angleSlots, [true, false, false, false, false]);
  });

  test('faceTemplateHash stable + 64 hex chars', () {    expect(faceTemplateHash(const [1, 0, 0, 0]),
        faceTemplateHash(const [1, 0, 0, 0]));
    expect(faceTemplateHash(const [1, 0, 0, 0]).length, 64);
    expect(faceTemplateHash(const [0, 1, 0, 0]),
        isNot(faceTemplateHash(const [1, 0, 0, 0])));
  });

  EnrollmentController makeOnlineCtl(FakeCloudSync cloud,
          {String email = _email, DeviceStore? store}) =>
      EnrollmentController(
        auth: FakeAuthService(SignedAccount(
            email: email, displayName: 'Student One', uid: 'uid-1')),
        store: store ?? InMemoryDeviceStore(),
        embedder: MockFaceEmbedder(
          enrolled: const [1, 0, 0, 0],
          probe: const [1, 0, 0, 0],
        ),
        cloud: cloud,
      );

  test('student upload refuses while offline (angles kept)', () async {
    final cloud = FakeCloudSync(online: false);
    final ctl = makeOnlineCtl(cloud);
    await ctl.signIn();
    ctl.setRoll('12342210');
    await ctl.generateKey();
    await enrollSlots(ctl);
    expect(ctl.state.phase, EnrollPhase.faceDone);
    expect(await ctl.upload(), isNull);
    expect(ctl.state.phase, EnrollPhase.error);
    expect(ctl.state.message, contains('internet'));
    // Slots survive the refused save — reconnecting saves without rescanning.
    cloud.online = true;
    ctl.dismissError();
    final id = await ctl.upload();
    expect(ctl.state.phase, EnrollPhase.uploaded);
    expect(id?.gmail, _email);
  });

  test('upload refuses a Gmail bound to another device key', () async {
    final cloud = FakeCloudSync();
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    await cloud.writeStudentDevice(StudentDeviceDoc(
        email: _email,
        uid: 'uid-1',
        pkHex: List.filled(32, 'ff').join(),
        name: 'Student One',
        roll: '12342210',
        modelVer: 'v',
        installId: 'other-install',
        createdAtMillis: nowMs,
        lastMoveAtMillis: nowMs,
        lastSeenAtMillis: nowMs,
        updatedAtMillis: nowMs));
    final ctl = makeOnlineCtl(cloud);
    await ctl.signIn();
    ctl.setRoll('12342210');
    await ctl.generateKey(); // fresh local key ≠ bound key
    await enrollSlots(ctl);
    expect(ctl.state.phase, EnrollPhase.faceDone);
    expect(await ctl.upload(), isNull);
    expect(ctl.state.message, contains('another device'));
  });

  test('upload moves after the weekly cooldown (genuine phone change)',
      () async {
    final cloud = FakeCloudSync();
    const dayMs = 24 * 60 * 60 * 1000;
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final stale = nowMs - 8 * dayMs;
    await cloud.writeStudentDevice(StudentDeviceDoc(
        email: _email,
        uid: 'uid-1',
        pkHex: List.filled(32, 'ff').join(),
        name: 'Student One',
        roll: '12342210',
        modelVer: 'v',
        installId: 'old-install',
        createdAtMillis: stale,
        lastMoveAtMillis: stale,
        lastSeenAtMillis: stale,
        updatedAtMillis: stale));
    final ctl = makeOnlineCtl(cloud);
    await ctl.signIn();
    ctl.setRoll('12342210');
    await ctl.generateKey();
    await enrollSlots(ctl);
    final id = await ctl.upload();
    expect(ctl.state.phase, EnrollPhase.uploaded);
    expect(id?.gmail, _email);
    final binding = await cloud.fetchStudentDevice(_email);
    expect(binding?.moveCount, 1);
  });

  test('upload refuses an install enrolled as another Gmail', () async {
    final cloud = FakeCloudSync();
    // Another Gmail claimed THIS install first (same secure storage).
    final store = InMemoryDeviceStore();
    await store.writeInstallId('shared-install');
    final other = makeOnlineCtl(cloud,
        email: 'other@institute.ac.in', store: store);
    await other.signIn();
    other.setRoll('999');
    await other.generateKey();
    await enrollSlots(other);
    expect(await other.upload(), isNotNull);
    // Same install, different Gmail: hard refuse even though the Gmail
    // itself was never bound.
    final ctl = EnrollmentController(
      auth: FakeAuthService(SignedAccount(
          email: _email, displayName: 'Student One', uid: 'uid-1')),
      store: store,
      embedder: MockFaceEmbedder(
        enrolled: const [1, 0, 0, 0],
        probe: const [1, 0, 0, 0],
      ),
      cloud: cloud,
    );
    await ctl.signIn();
    ctl.setRoll('12342210');
    await ctl.generateKey();
    await enrollSlots(ctl);
    expect(await ctl.upload(), isNull);
    expect(ctl.state.message, contains('already enrolled'));
  });
}
