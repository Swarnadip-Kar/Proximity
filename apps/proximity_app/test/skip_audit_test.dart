// SKIP-PATH AUDIT: no path may let a student reach marking without a
// completed enrollment. Each attempt below constructs a bypass and asserts
// the gate that closes it (route guard → L1 domain gate → driver pre-sign
// check → server-side ticket verification).
//
// Layers (defense in depth):
//   RVil  route guards (ProxRoutes.isMobileOnly/mobileGuardRedirect —
//         enroll-only set; desktop/web land on guidance, never a camera;
//         mark/* is dead — no named routes, no guard branches, unknown
//         placeholder only)
//   L1    domain gate (requireMobileFace/canUseFace — plugin + sign paths)
//   D     driver pre-sign gates (enrollment present + email match + fresh
//         pipeline + FaceGate freshness before any signature)
//   S     server ticket checks (Sig_s bind, score>=T, fresh faceValidAt,
//         allowlisted verifierVer, sighting; NONE confirms only via the
//         logged device-none-fallback with every check still run)
//
// Pure unit file (no widget binding): audit 12 proves against a real local
// ProxServer, which needs real HTTP — any testWidgets in this file would
// force the fake-400 HTTP binding and break it. Routing-level widget proof
// (MaterialApp.routes exact-table guards render MobileOnlyGuidanceScreen,
// mark/* renders unknown, guidance CTA replaces) lives in
// setup_bundle_rebuild_test.dart + enroll_guided_test.dart.
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/face_identity/liveness_gate.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_app/routes.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_transport/transport.dart';

import 'student_driver_test.dart' as helpers;

const _email = 's@x.in';
const _beacon = ClassBeacon(
    classLabel: 't', host: '127.0.0.1', port: 9, rssiDbm: 0, displayCode: 'X');
const _identity = LinkedIdentity(name: 'S', gmail: _email, roll: '1');

RealStudentDriver _driver(
        {required InMemoryDeviceStore store,
        FaceVerifier? verifier,
        FakeDeviceKey? deviceKey,
        LivenessGate? livenessGate}) =>
    RealStudentDriver(
      store: store,
      verifier: verifier ?? FakeFaceVerifier(),
      deviceKey: deviceKey ?? FakeDeviceKey(),
      engine: ProxBleEngine(radio: FakeBleRadio()),
      livenessGate: livenessGate ?? FakeLivenessGate(),
    );

void main() {
  group('SKIP-AUDIT route guards (mobile-only set)', () {
    // MaterialApp resolution order (main.dart): exact table
    // (buildProxRoutes) wins over onGenerateRoute, onUnknownRoute last.
    // The in-tab router (shells _tabRoute) resolves the SAME way: exact
    // table lookup first, then proxOnGenerateRoute, then unknown
    // placeholder — so these pure tests resolve through that same
    // table + router shape (no pumping; widget rendering proof lives in
    // setup_bundle_rebuild_test + enroll_guided_test).
    RouteSettings settingsFor(String name, {Object? arguments}) =>
        RouteSettings(name: name, arguments: arguments);

    test('1: enroll/* deep-links redirect off-mobile (exact table guarded)',
        () {
      final table = buildProxRoutes();
      for (final r in ['enroll/capture', 'enroll/result']) {
        expect(ProxRoutes.isMobileOnly(r), isTrue, reason: r);
        expect(ProxRoutes.isNativeOnly(r), isTrue, reason: r);
        expect(
            ProxRoutes.mobileGuardRedirect(r, mobile: false),
            ProxRoutes.myAttendance,
            reason: '$r must land on records guidance off-mobile');
        expect(ProxRoutes.mobileGuardRedirect(r, mobile: true), isNull,
            reason: '$r stays put on mobile');
        // Exact-table hit exists — without the _guardedRoute wrapper this
        // would bypass onGenerateRoute guards (MaterialApp.routes wins).
        // The wrapper runs web/mobile guards BEFORE the inner builder.
        expect(table.containsKey(r), isTrue,
            reason: '$r exact-table entry must exist (guard-wrapped)');
      }
    });

    test('1b: mark/* guards are gone (dead flow — unknown, never guidance)',
        () {
      final table = buildProxRoutes();
      for (final r in [
        'mark/browse',
        'mark/join',
        'mark/waiting',
        'mark/face',
        'mark/proving',
        'mark/verdict',
        'mark/manual',
      ]) {
        expect(ProxRoutes.isMobileOnly(r), isFalse, reason: r);
        expect(ProxRoutes.isNativeOnly(r), isFalse, reason: r);
        expect(ProxRoutes.mobileGuardRedirect(r, mobile: false), isNull,
            reason: '$r must not redirect (guards gone)');
        expect(ProxRoutes.mobileGuardRedirect(r, mobile: true), isNull,
            reason: r);
        // No exact-table entry (no named mark routes — in-tab only).
        expect(table.containsKey(r), isFalse, reason: r);
        // In-tab / MaterialApp onGenerate has no mark branch → null,
        // so both routers fall to onUnknownRoute (placeholder, never
        // MobileOnlyGuidanceScreen).
        expect(
            proxOnGenerateRoute(settingsFor(r)), isNull,
            reason: '$r must miss onGenerate (unknown fallback)');
        final unknown = proxOnUnknownRoute(settingsFor(r));
        expect(unknown, isNotNull, reason: r);
      }
    });

    test('2: router serves guidance for enroll/* on records-only devices',
        () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        // onGenerate guard path (parameterized + exact names both hit
        // guards first in proxOnGenerateRoute).
        final route = proxOnGenerateRoute(
            const RouteSettings(name: 'enroll/capture'));
        expect(route, isNotNull,
            reason: 'enroll/capture must resolve to guidance on desktop');
        final resultRoute = proxOnGenerateRoute(
            const RouteSettings(name: 'enroll/result'));
        expect(resultRoute, isNotNull,
            reason: 'enroll/result must resolve to guidance on desktop');
        // In-tab router shape: exact table hit exists for enroll/*, and
        // the guard fires — so the in-tab exact builder (wrapped) and the
        // onGenerate path agree (guidance, never the capture screen).
        final table = buildProxRoutes();
        expect(table.containsKey('enroll/capture'), isTrue);
        expect(
            ProxRoutes.mobileGuardRedirect('enroll/capture'), isNotNull);
        // Hosting + records stay available on desktop (professors host).
        expect(ProxRoutes.mobileGuardRedirect('live/CS101', mobile: false),
            isNull);
        expect(
            ProxRoutes.mobileGuardRedirect('records/mine', mobile: false),
            isNull);
        // Same via live platform read (no explicit mobile pin).
        expect(proxOnGenerateRoute(settingsFor('live/CS101')), isNotNull,
            reason: 'live host stays available on desktop');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('2b: live/ + prof/courses/ edge shapes resolve explicitly', () {
      // live/ empty never falls back to args — unknown fallback.
      expect(
          proxOnGenerateRoute(const RouteSettings(name: 'live/')), isNull);
      expect(
          proxOnGenerateRoute(RouteSettings(
              name: 'live/',
              arguments: const ProxRouteArgs(course: 'CS101'))),
          isNull,
          reason: 'live/ empty must not resolve via args');
      // live/<course> prefers the path segment on args conflict.
      final conflict = proxOnGenerateRoute(RouteSettings(
          name: 'live/CS101',
          arguments: const ProxRouteArgs(course: 'CS999')));
      expect(conflict, isNotNull);
      expect(conflict!.settings.name, 'live/CS101');
      // prof/courses/ trailing slash is explicit: bare prefix → unknown,
      // `CS101/` == `CS101`, `CS101/export/` == `CS101/export`.
      expect(
          proxOnGenerateRoute(
              const RouteSettings(name: 'prof/courses/')),
          isNull);
      expect(
          proxOnGenerateRoute(
              const RouteSettings(name: 'prof/courses/CS101/')),
          isNotNull);
      expect(
          proxOnGenerateRoute(
              const RouteSettings(name: 'prof/courses/CS101/export/')),
          isNotNull);
      // prof/courses prefers the path segment too.
      final courseConflict = proxOnGenerateRoute(RouteSettings(
          name: 'prof/courses/CS101',
          arguments: const ProxRouteArgs(course: 'CS999')));
      expect(courseConflict, isNotNull);
      expect(courseConflict!.settings.name, 'prof/courses/CS101');
    });

    // Widget-level proof (MobileOnlyGuidanceScreen actually renders via
    // MaterialApp.routes exact-table + in-tab router, mark/* renders
    // unknown, guidance CTA replaces so back never loops) lives in
    // setup_bundle_rebuild_test.dart + enroll_guided_test.dart.
    // Direct-screen blocked cards (L1) stay in enroll_guided_test.dart
    // 'records-only device sees the blocked card'.
  });

  group('SKIP-AUDIT L1 domain gates (records-only devices)', () {
    test('4: desktop checkFace is blocked, never a pass', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final d = _driver(store: await helpers.enrolledStore());
        expect((await d.checkFace('still.jpg')).match, FaceMatch.blocked);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('5: desktop listenAndProve signs nothing', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final d = _driver(store: await helpers.enrolledStore());
        final res = await d.listenAndProve(
            target: _beacon,
            identity: _identity,
            faceScore: 0.95,
            onStatus: (_) {});
        expect(res.result, StudentResult.error);
        expect(res.detail, contains('mobile app'));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('6: desktop enrollment cannot validate a face', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final ctl = EnrollmentController(
          auth: FakeAuthService(const SignedAccount(
              email: _email, displayName: 'S', uid: 'u1')),
          store: InMemoryDeviceStore(),
          verifier: const UnavailableFaceVerifier(),
          deviceKey: const UnavailableDeviceKey(),
        );
        await ctl.signIn();
        await ctl.generateKey();
        await ctl.enrollFace(['a.jpg', 'b.jpg', 'c.jpg']);
        expect(ctl.state.phase, EnrollPhase.error);
        expect(await ctl.upload(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('SKIP-AUDIT driver pre-sign gates (no completed enrollment)', () {
    test('7: fresh install (no record) cannot listen-and-prove', () async {
      final d = _driver(store: InMemoryDeviceStore());
      final res = await d.listenAndProve(
          target: _beacon,
          identity: _identity,
          faceScore: 0.95,
          onStatus: (_) {});
      expect(res.result, StudentResult.error);
      expect(res.detail, contains('Not enrolled'));
    });

    test('8: record for another gmail cannot prove as me', () async {
      final store = InMemoryDeviceStore();
      await store.writeEnrollment(StoredEnrollment(
        email: 'someone.else@x.in',
        name: 'X',
        roll: '9',
        seedHex: 'ab' * 32,
        pkHex: 'cd' * 32,
        faceId: 'face-test-id',
        enrolledAt: DateTime.now().toUtc(),
        verifierVer: kFaceVerifierVer,
      ));
      final d = _driver(store: store);
      final res = await d.listenAndProve(
          target: _beacon,
          identity: _identity,
          faceScore: 0.95,
          onStatus: (_) {});
      expect(res.result, StudentResult.error);
      expect(res.detail, contains('Not enrolled'));
    });

    test('9: wiped faceId cannot prove (re-face, key kept)', () async {
      final store = InMemoryDeviceStore();
      await store.writeEnrollment(StoredEnrollment(
        email: _email,
        name: 'S',
        roll: '1',
        seedHex: 'ab' * 32,
        pkHex: 'cd' * 32,
        enrolledAt: DateTime.now().toUtc(),
        verifierVer: kFaceVerifierVer,
      ));
      final d = _driver(store: store);
      final res = await d.listenAndProve(
          target: _beacon,
          identity: _identity,
          faceScore: 0.95,
          onStatus: (_) {});
      expect(res.result, StudentResult.faceFailed);
      expect(res.detail, contains('re-enroll'));
    });

    test('10: stale pipeline cannot prove against incomparable faces',
        () async {
      final d = _driver(
          store: await helpers.enrolledStore(
              verifierVer: 'edgeface-xs-g06-tflite-1'));
      final res = await d.listenAndProve(
          target: _beacon,
          identity: _identity,
          faceScore: 0.95,
          onStatus: (_) {});
      expect(res.result, StudentResult.faceFailed);
      expect(res.detail, contains('re-enroll'));
    });

    test('11: corrupt key material errors, never throws, never signs',
        () async {
      final store = InMemoryDeviceStore();
      await store.writeEnrollment(StoredEnrollment(
        email: _email,
        name: 'S',
        roll: '1',
        seedHex: 'zzzz-not-hex',
        pkHex: 'cd' * 32,
        faceId: 'face-test-id',
        enrolledAt: DateTime.now().toUtc(),
        verifierVer: kFaceVerifierVer,
      ));
      final engine = ProxBleEngine(radio: FakeBleRadio());
      final d = RealStudentDriver(
        store: store,
        verifier: FakeFaceVerifier(),
        deviceKey: FakeDeviceKey(),
        engine: engine,
      );
      Future.delayed(const Duration(milliseconds: 300), () {
        engine.handleSighting(BleSighting(
          type: kAirTypeChallenge,
          token8: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
          rssiDbm: -60,
          at: DateTime.now().toUtc(),
        ));
      });
      final res = await d.listenAndProve(
          target: _beacon,
          identity: _identity,
          faceScore: 0.95,
          onStatus: (_) {});
      expect(res.result, StudentResult.error);
    });

    test('12: stale holder check cannot sign (FaceGate pre-sign)',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      final prof = ProxCrypto.generateEdKeypair();
      final seed = randBytes(32);
      final store = InMemoryDeviceStore();
      await store.writeEnrollment(StoredEnrollment(
        email: _email,
        name: 'S',
        roll: '1',
        seedHex: hexEncode(seed),
        pkHex: 'cd' * 32,
        faceId: 'face-test-id',
        enrolledAt: DateTime.now().toUtc(),
        verifierVer: kFaceVerifierVer,
      ));
      final server = ProxServer(
        classLabel: 't',
        profSk: prof.privateKey,
        profPk: prof.publicKey,
        sightings: (
                {required peerW,
                required expectedAirKey,
                required expectedUuid}) =>
            const RadioSighting(rssiDbm: -55, hop: 0),
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
        final engine = ProxBleEngine(radio: FakeBleRadio());
        final d = RealStudentDriver(
          store: store,
          verifier: FakeFaceVerifier(),
          deviceKey: FakeDeviceKey(),
          engine: engine,
        )..silenceCap = const Duration(seconds: 2);
        Future.delayed(const Duration(milliseconds: 300), () {
          final w = server.window!;
          engine.handleSighting(BleSighting(
            type: kAirTypeChallenge,
            token8: w.challengeFor(w.jForTime(DateTime.now().toUtc())),
            ipHost: '127.0.0.1',
            ipPort: server.port,
            rssiDbm: -60,
            at: DateTime.now().toUtc(),
          ));
        });
        final res = await d.listenAndProve(
          target: ClassBeacon(
              classLabel: 't',
              host: '127.0.0.1',
              port: server.port,
              rssiDbm: 0,
              displayCode: 'X'),
          identity: _identity,
          faceScore: 0.0,
          onStatus: (_) {},
        );
        expect(res.result, StudentResult.faceFailed);
        expect(server.tally.presentCount, 0);
      } finally {
        await server.stop();
      }
    });
  });

  group('SKIP-AUDIT controller gates (cannot save without validation)', () {
    Future<EnrollmentController> keyReady() async {
      final ctl = EnrollmentController(
        auth: FakeAuthService(const SignedAccount(
            email: _email, displayName: 'S', uid: 'u1')),
        store: InMemoryDeviceStore(),
        verifier: FakeFaceVerifier(),
        deviceKey: FakeDeviceKey(),
      );
      await ctl.signIn();
      await ctl.generateKey();
      return ctl;
    }

    test('13: upload without a validated capture is refused', () async {
      final ctl = await keyReady();
      expect(await ctl.upload(), isNull);
      expect(ctl.state.phase, EnrollPhase.error);
    });

    test('14: enrollFace enforces key-first ordering', () async {
      final ctl = EnrollmentController(
        auth: FakeAuthService(const SignedAccount(
            email: _email, displayName: 'S', uid: 'u1')),
        store: InMemoryDeviceStore(),
        verifier: FakeFaceVerifier(),
        deviceKey: FakeDeviceKey(),
      );
      await ctl.signIn();
      await ctl.enrollFace(['a.jpg', 'b.jpg', 'c.jpg']);
      expect(ctl.state.phase, EnrollPhase.error);
      expect(await ctl.upload(), isNull);
    });
  });
}
