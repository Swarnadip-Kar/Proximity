// Enrollment identity + single-entry contracts (stale-account + double
// ID-number fixes).
//
// Bug 1 (stale account): the enroll draft (preseed/account + roll + key +
// face) must rebuild from the CURRENT signed-in account on switch/sign-out
// — the card identity, the claim email/org, and the faceId must never ride
// a stale preseed. Bug 2 (double ID entry): the ID number is typed exactly
// once (intro, shared EnrollRollField); the save step shows it readonly
// with fail-closed validation at Save.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/core/sync/claim.dart';
import 'package:proximity_app/features/enrollment/enroll_intro.dart';
import 'package:proximity_app/features/enrollment/enroll_result.dart';
import 'package:proximity_app/features/enrollment/enroll_widgets.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';

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
      expect(ctl.state.account?.email, 'b@univ.edu');
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
    testWidgets('intro holds the one editable field, prefilled', (t) async {
      final auth = FakeAuthService(_b);
      final store = InMemoryDeviceStore();
      final ctl = await _signedInWithKey(auth, store, 'B-ROLL');
      await t.pumpWidget(ProviderScope(
        overrides: [enrollmentControllerProvider.overrideWith((ref) => ctl)],
        child: const MaterialApp(home: EnrollIntroScreen()),
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
}
