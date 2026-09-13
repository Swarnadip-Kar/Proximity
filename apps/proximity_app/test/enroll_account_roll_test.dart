// Enrollment identity + single-entry contracts (stale-account + double
// ID-number fixes).
//
// Bug 1 (stale account): the enroll draft (preseed/account + roll + key +
// face) must rebuild from the CURRENT signed-in account on switch/sign-out
// — the card identity, the claim email/org, and the faceId must never ride
// a stale preseed. Bug 2 (double ID entry): the ID number is typed exactly
// once (intro, shared EnrollRollField); the save step shows it readonly
// with fail-closed validation at Save.
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/core/sync/claim.dart';
import 'package:proximity_app/features/setup/enroll_result.dart';
import 'package:proximity_app/features/setup/enroll_widgets.dart';
import 'package:proximity_app/features/setup/intro_sections.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';
import 'package:proximity_protocol/protocol.dart';

const _a =
    SignedAccount(email: 'a@gmail.com', displayName: 'A', uid: 'ua');
const _b =
    SignedAccount(email: 'b@univ.edu', displayName: 'B', uid: 'ub');

EnrollmentController _ctl(FakeAuthService auth, InMemoryDeviceStore store,
        {FaceVerifier? verifier}) =>
    EnrollmentController(
      auth: auth,
      store: store,
      verifier: verifier ?? FakeFaceVerifier(),
      deviceKey: FakeDeviceKey(),
      // enrollFace measures liveness: scripted pass (liveness itself is
      // pinned in enroll_liveness_gate_test.dart).
      livenessGate: FakeLivenessGate(),
    );

Future<EnrollmentController> _signedInWithKey(FakeAuthService auth,
    InMemoryDeviceStore store, String roll) async {
  final ctl = _ctl(auth, store);
  await ctl.signIn();
  ctl.setRoll(roll);
  await ctl.generateKey();
  return ctl;
}

const _stills = ['c.jpg', 'l.jpg', 'r.jpg', 'u.jpg', 'd.jpg'];

void main() {
  group('stale account invalidation', () {
    test('switch-account rebuilds the draft from the current account',
        () async {
      final auth = FakeAuthService(_a);
      final store = InMemoryDeviceStore();
      final ctl = await _signedInWithKey(auth, store, 'A-ROLL');
      expect(ctl.state.account?.email, 'a@gmail.com');
      expect(ctl.state.roll, 'A-ROLL');
      expect(ctl.state.pkHex.isNotEmpty, isTrue);

      // Account switch outside the controller (landing switch-account path).
      auth.seedAccount(_b);
      await ctl.refreshFromAuth();

      expect(ctl.state.account?.email, 'b@univ.edu');
      expect(ctl.state.roll, isEmpty);
      expect(ctl.state.pkHex, isEmpty);
      expect(ctl.state.phase, EnrollPhase.signedIn);
    });

    test('switch-account-then-enroll files the claim under the new account',
        () async {
      final auth = FakeAuthService(_a);
      final store = InMemoryDeviceStore();
      final ctl = await _signedInWithKey(auth, store, 'A-ROLL');

      auth.seedAccount(_b);
      await ctl.refreshFromAuth();
      ctl.setRoll('B-ROLL');
      await ctl.generateKey();
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      final id = await ctl.upload();
      expect(id, isNotNull);
      expect(id!.gmail, 'b@univ.edu');
      expect(id.roll, 'B-ROLL');
      expect(id.org, 'univ.edu');

      final stored = await store.readEnrollment();
      expect(stored, isNotNull);
      expect(stored!.email, 'b@univ.edu');
      expect(stored.roll, 'B-ROLL');
      expect(stored.org, 'univ.edu');
      // Face gallery key bound to the NEW account, never the stale one.
      final installId = await getOrCreateInstallId(store);
      expect(stored.faceId, faceIdOf('b@univ.edu', installId));
    });

    test('upload without refresh refuses instead of filing stale', () async {
      final auth = FakeAuthService(_a);
      final store = InMemoryDeviceStore();
      final ctl = await _signedInWithKey(auth, store, 'A-ROLL');
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);

      auth.seedAccount(_b); // raced switch, no refresh
      final id = await ctl.upload();
      expect(id, isNull);
      // Atomic resync (behavior B): refusal adopts the live account AND
      // wipes roll/key in the same op (same as refreshFromAuth), so the
      // draft never sits half-migrated (new account + old roll/key).
      expect(ctl.state.account?.email, 'b@univ.edu');
      expect(ctl.state.roll, isEmpty);
      expect(ctl.state.pkHex, isEmpty);
      expect(ctl.state.message, contains('changed'));
      expect(await store.readEnrollment(), isNull);
    });

    test('sign-out clears the whole draft', () async {
      final auth = FakeAuthService(_a);
      final store = InMemoryDeviceStore();
      final ctl = await _signedInWithKey(auth, store, 'A-ROLL');

      auth.seedAccount(null);
      await ctl.refreshFromAuth();
      expect(ctl.state.account, isNull);
      expect(ctl.state.phase, EnrollPhase.signedOut);
      expect(ctl.state.roll, isEmpty);
      expect(ctl.state.pkHex, isEmpty);
    });

    test('controller sign-in as another Gmail wipes the previous draft',
        () async {
      final auth = FakeAuthService(_a);
      final store = InMemoryDeviceStore();
      final ctl = await _signedInWithKey(auth, store, 'A-ROLL');

      auth.seedAccount(_b);
      await ctl.signIn(); // in-flow sign-in button path
      expect(ctl.state.account?.email, 'b@univ.edu');
      expect(ctl.state.roll, isEmpty);
      expect(ctl.state.pkHex, isEmpty);
    });
  });

  group('single ID-number entry', () {
    testWidgets('account step holds the one editable field, prefilled', (t) async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final ctl = await _signedInWithKey(auth, store, 'B-ROLL');
      await t.pumpWidget(ProviderScope(
        overrides: [enrollmentControllerProvider.overrideWith((ref) => ctl)],
        child: const MaterialApp(
            home: Scaffold(body: IntroAccountSection())),
      ));
      await t.pumpAndSettle();
      expect(find.byType(EnrollRollField), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      final field = t.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'B-ROLL');
    });

    testWidgets('result shows the entry readonly, never a second prompt',
        (t) async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final ctl = await _signedInWithKey(auth, store, 'B-ROLL');
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      await t.pumpWidget(ProviderScope(
        overrides: [enrollmentControllerProvider.overrideWith((ref) => ctl)],
        child: const MaterialApp(home: EnrollResultScreen()),
      ));
      await t.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(EnrollRollField), findsNothing);
      expect(find.text('ID: B-ROLL'), findsOneWidget);
    });

    test('save with no ID fails closed, storing and claiming nothing',
        () async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final ctl = _ctl(auth, store);
      await ctl.signIn();
      await ctl.generateKey();
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      final id = await ctl.upload();
      expect(id, isNull);
      expect(ctl.state.phase, EnrollPhase.error);
      expect(ctl.state.message, contains('ID number'));
      expect(await store.readEnrollment(), isNull);
    });
  });

  group('recapture key-gate (faceDone reuses the completed key)', () {
    test('recapture from faceDone succeeds without the key prompt',
        () async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final ctl = await _signedInWithKey(auth, store, 'B-ROLL');
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      final keyBefore = ctl.state.pkHex;
      expect(keyBefore.isNotEmpty, isTrue);
      // Recapture: fresh 5 stills, no repeated key ceremony.
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      expect(ctl.state.pkHex, keyBefore);
      expect(ctl.state.message, isNot(contains('device key')));
    });

    test('recapture from uploaded succeeds without the key prompt',
        () async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final ctl = await _signedInWithKey(auth, store, 'B-ROLL');
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      final id = await ctl.upload();
      expect(id, isNotNull);
      expect(ctl.state.phase, EnrollPhase.uploaded);
      final keyBefore = ctl.state.pkHex;
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      expect(ctl.state.pkHex, keyBefore);
      expect(ctl.state.message, isNot(contains('device key')));
    });

    test('truly keyless enrollFace stays blocked with the key prompt',
        () async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final ctl = _ctl(auth, store);
      await ctl.signIn();
      // No generateKey: the key is genuinely absent.
      expect(ctl.state.pkHex, isEmpty);
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.error);
      expect(ctl.state.message, contains('Generate the device key first'));
    });

    test(
        'rescan after restart restores the stored key (no key-gate error)',
        () async {
      // Reproduces the rescan bug: key generated earlier (stored on
      // device), then a fresh controller (restart) with an empty draft.
      // The capture screen's mount reconcile (`refreshFromAuth`) must
      // reload the key before Save — the gate must not fire.
      // Sealed-only fixture (security §2).
      final store = InMemoryDeviceStore();
      await store.writeEnrollment(StoredEnrollment(
        email: 'b@univ.edu',
        name: 'B',
        roll: 'B-ROLL',
        seedHex: '',
        pkHex: 'cd' * 32,
        sealedKeyHex: hexEncode(await FakeDeviceKey()
            .seal(Uint8List.fromList(hexDecode('ab' * 32)))),
        faceId: 'face-1',
        enrolledAt: DateTime.utc(2026, 9, 1),
        verifierVer: kFaceVerifierVer,
        org: 'example.com',
        pkDHex: 'ef' * 32,
        attestationLevel: 'NONE',
        attestedAt: DateTime.utc(2026, 9, 1),
        attestedUntil: DateTime.utc(2026, 11, 30),
      ));
      final auth = FakeAuthService(_b);
      final ctl = _ctl(auth, store);
      expect(ctl.state.pkHex, isEmpty);

      await ctl.refreshFromAuth();

      expect(ctl.state.pkHex.isNotEmpty, isTrue);
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      expect(ctl.state.message, isNot(contains('device key')));
    });

    test('stored-but-locked key gets the honest message, not the prompt',
        () async {
      // The locked hole: account adopted, but no usable key loaded while
      // a stored enrollment exists for this account (as a failed sealed
      // restore leaves them). The gate must name the recovery instead of
      // implying the key was never generated.
      final store = InMemoryDeviceStore();
      final auth = FakeAuthService(_b);
      final ctl = _ctl(auth, store);
      await ctl.signIn();
      expect(ctl.state.account?.email, 'b@univ.edu');
      // Enrollment lands AFTER the adopt, so no restore ever ran for it.
      await store.writeEnrollment(StoredEnrollment(
        email: 'b@univ.edu',
        name: 'B',
        roll: 'B-ROLL',
        seedHex: 'ab' * 32,
        pkHex: 'cd' * 32,
        faceId: 'face-1',
        enrolledAt: DateTime.utc(2026, 9, 1),
        verifierVer: kFaceVerifierVer,
        org: 'example.com',
        pkDHex: 'ef' * 32,
        attestationLevel: 'NONE',
        attestedAt: DateTime.utc(2026, 9, 1),
        attestedUntil: DateTime.utc(2026, 11, 30),
      ));
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.error);
      expect(ctl.state.message, contains('unlock'));
      expect(ctl.state.message, contains('Generate device key'));
      expect(ctl.state.message, isNot(contains('first, then scan')));
    });

    test('same-account refresh retries a missing key', () async {
      // The refresh hole: account adopted but `_keys` null (a locked
      // restore that only recovered pkHex). A later refresh must retry
      // the restore instead of early-returning on the account match.
      final store = InMemoryDeviceStore();
      final auth = FakeAuthService(_b);
      final ctl = _ctl(auth, store);
      await ctl.signIn();
      expect(ctl.state.account?.email, 'b@univ.edu');
      expect(ctl.state.pkHex, isEmpty);
      // Enrollment lands after the adopt (e.g. slow store read winning
      // late): refresh must pick the key up now. Sealed-only (security §2).
      await store.writeEnrollment(StoredEnrollment(
        email: 'b@univ.edu',
        name: 'B',
        roll: 'B-ROLL',
        seedHex: '',
        pkHex: 'cd' * 32,
        sealedKeyHex: hexEncode(await FakeDeviceKey()
            .seal(Uint8List.fromList(hexDecode('ab' * 32)))),
        faceId: 'face-1',
        enrolledAt: DateTime.utc(2026, 9, 1),
        verifierVer: kFaceVerifierVer,
        org: 'example.com',
        pkDHex: 'ef' * 32,
        attestationLevel: 'NONE',
        attestedAt: DateTime.utc(2026, 9, 1),
        attestedUntil: DateTime.utc(2026, 11, 30),
      ));
      await ctl.refreshFromAuth();
      expect(ctl.state.pkHex.isNotEmpty, isTrue);
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);
    });

    test('signed-out enrollFace stays put, enrolling nothing', () async {
      final auth = FakeAuthService();
      final store = InMemoryDeviceStore();
      final ctl = _ctl(auth, store);
      expect(ctl.state.account, isNull);
      await ctl.enrollFace(_stills);
      // Fail-closed: no account → no face, never faceDone.
      expect(ctl.state.phase, isNot(EnrollPhase.faceDone));
      expect(ctl.state.faceScore, 0);
    });
  });

  group('honest score UI (no constant parades as a measurement)', () {
    testWidgets('success shows match copy, never a numeric score', (t) async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final ctl = await _signedInWithKey(auth, store, 'B-ROLL');
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      expect(await ctl.upload(), isNotNull);
      expect(ctl.state.phase, EnrollPhase.uploaded);
      await t.pumpWidget(ProviderScope(
        overrides: [enrollmentControllerProvider.overrideWith((ref) => ctl)],
        child: const MaterialApp(home: EnrollResultScreen()),
      ));
      await t.pumpAndSettle();
      // Honest copy: match (the real plugin signal) in words, no number.
      expect(find.textContaining('Face matched on this phone'), findsOneWidget);
      // The fake-score strings must never render.
      expect(find.textContaining('Match score'), findsNothing);
      expect(find.textContaining('score 0.'), findsNothing);
      expect(find.textContaining('0.70'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('pending shows progress, never a numeric score', (t) async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final ctl = await _signedInWithKey(auth, store, 'B-ROLL');
      await ctl.enrollFace(_stills);
      expect(ctl.state.phase, EnrollPhase.faceDone);
      await t.pumpWidget(ProviderScope(
        overrides: [enrollmentControllerProvider.overrideWith((ref) => ctl)],
        child: const MaterialApp(home: EnrollResultScreen()),
      ));
      await t.pumpAndSettle();
      // Progress state stays user-visible…
      expect(find.textContaining('5 of 5 stills captured'), findsOneWidget);
      // …but no numeric internal ever renders.
      expect(find.textContaining('score'), findsNothing);
      expect(find.textContaining('0.70'), findsNothing);
      expect(t.takeException(), isNull);
    });
  });
}
