import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/core/roster_repo.dart';
import 'package:proximity_face/face.dart';

const _email = 'aarav@institute.ac.in';

EnrollmentController makeCtl({
  String email = _email,
  FakeRosterRepository? repo,
  DeviceStore? store,
}) =>
    EnrollmentController(
      auth: FakeAuthService(SignedAccount(email: email, displayName: 'Aarav S')),
      repo: repo ?? FakeRosterRepository(),
      store: store ?? InMemoryDeviceStore(),
      embedder: MockFaceEmbedder(
        enrolled: const [1, 0, 0, 0],
        probe: const [1, 0, 0, 0],
      ),
    );

void main() {
  test('happy path links Gmail identity + uploads key record', () async {
    final repo = FakeRosterRepository();
    final ctl = makeCtl(repo: repo);
    await ctl.signIn();
    expect(ctl.state.phase, EnrollPhase.signedIn);
    expect(ctl.state.account?.email, _email);
    await ctl.generateKey();
    expect(ctl.state.phase, EnrollPhase.keyReady);
    expect(ctl.state.pkHex.length, 64);
    await ctl.captureFace(const []);
    expect(ctl.state.phase, EnrollPhase.faceDone);
    ctl.setRoll('12342210');
    final id = await ctl.upload();
    expect(ctl.state.phase, EnrollPhase.uploaded);
    expect(id?.gmail, _email);
    expect(id?.name, 'Aarav S');
    final rec = await repo.fetchKey(_email);
    expect(rec?.email, _email);
    expect(rec?.name, 'Aarav S');
    expect(rec?.pkHex, ctl.state.pkHex);
    expect(rec?.sigHex.length, 128);
    expect(rec?.faceHashHex.length, 64);
  });

  test('second device with different key rejected (one-device-per-email)',
      () async {
    final repo = FakeRosterRepository();
    final first = makeCtl(repo: repo);
    await first.signIn();
    first.setRoll('12342210');
    await first.generateKey();
    await first.captureFace(const []);
    await first.upload();
    expect(first.state.phase, EnrollPhase.uploaded);

    final second = makeCtl(repo: repo); // new keypair, same email
    await second.signIn();
    await second.generateKey();
    expect(second.state.phase, EnrollPhase.error);
    expect(second.state.message, contains('another device'));
    second.dismissError();
    expect(second.state.phase, EnrollPhase.signedIn);
  });

  test('roll number saved unverified with the profile', () async {
    final repo = FakeRosterRepository();
    final ctl = makeCtl(repo: repo);
    await ctl.signIn();
    ctl.setRoll('12342210');
    await ctl.generateKey();
    await ctl.captureFace(const []);
    final id = await ctl.upload();
    expect(id?.roll, '12342210');
    expect((await repo.fetchKey(_email))?.roll, '12342210');
  });

  test('missing ID number blocks upload until entered', () async {
    final ctl = makeCtl(repo: FakeRosterRepository());
    await ctl.signIn();
    await ctl.generateKey();
    await ctl.captureFace(const []);
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
    final repo = FakeRosterRepository();
    final store = InMemoryDeviceStore();
    final first = makeCtl(repo: repo, store: store);
    await first.signIn();
    first.setRoll('12342210');
    await first.generateKey();
    final pk = first.state.pkHex;
    await first.captureFace(const []);
    await first.upload();
    expect(first.state.phase, EnrollPhase.uploaded);

    // New controller, same device store; server still holds our key.
    final repo2 = FakeRosterRepository()..keys.addAll(repo.keys);
    final second = makeCtl(repo: repo2, store: store);
    await second.signIn();
    expect(second.state.phase, EnrollPhase.uploaded);
    expect(second.state.restored, isTrue);
    expect(second.state.pkHex, pk);
    expect(second.currentIdentity?.roll, '12342210');
  });

  test('new device within 24h rejected; after 24h allowed', () async {
    RosterKeyRecord serverKey(String pk, DateTime at) => RosterKeyRecord(
          pkHex: pk,
          name: 'Aarav S',
          email: _email,
          roll: '12342210',
          faceHashHex: '00' * 32,
          modelVer: 'm',
          sigHex: '00' * 64,
          updatedAt: at,
        );

    // Fresh server enrollment 1h ago, different key (another device).
    final repo = FakeRosterRepository()
      ..keys[_email] = serverKey(
          'ff' * 32, DateTime.now().toUtc().subtract(const Duration(hours: 1)));
    final ctl = makeCtl(repo: repo, store: InMemoryDeviceStore());
    await ctl.signIn();
    await ctl.generateKey();
    expect(ctl.state.phase, EnrollPhase.error);
    expect(ctl.state.message, contains('once a day'));

    // Same but 25h old → allowed.
    final repo2 = FakeRosterRepository()
      ..keys[_email] =
          serverKey('ff' * 32, DateTime.now().toUtc().subtract(const Duration(hours: 25)));
    final ctl2 = makeCtl(repo: repo2, store: InMemoryDeviceStore());
    await ctl2.signIn();
    await ctl2.generateKey();
    expect(ctl2.state.phase, EnrollPhase.keyReady);
  });

  test('faceTemplateHash stable + 64 hex chars', () {
    expect(faceTemplateHash(const [1, 0, 0, 0]),
        faceTemplateHash(const [1, 0, 0, 0]));
    expect(faceTemplateHash(const [1, 0, 0, 0]).length, 64);
    expect(faceTemplateHash(const [0, 1, 0, 0]),
        isNot(faceTemplateHash(const [1, 0, 0, 0])));
  });
}
