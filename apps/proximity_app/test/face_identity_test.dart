// Tracks 2+3 L1/L2/L3 tests: mobile-only domain gate matrix, route
// guards, verifier identity/versioning, fail-closed stubs, desktop
// blocked-state widgets.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/platformx.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_blocked.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/routes.dart';

void main() {
  group('L1 domain gate matrix (canUseFace/requireMobileFace)', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('Android + iOS pass, desktop fails', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(canUseFace(), isTrue);
      requireMobileFace();

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(canUseFace(), isTrue);
      requireMobileFace();

      for (final p in [
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = p;
        expect(canUseFace(), isFalse,
            reason: 'records-only on $p: face must fail closed');
        expect(() => requireMobileFace(), throwsStateError);
      }
    });
  });

  group('L2 route guards (mobile-only set)', () {
    test('enroll/* + mark/* are mobile-only; live/records are not', () {
      for (final r in [
        'enroll/intro',
        'enroll/capture',
        'enroll/result',
        'mark/browse',
        'mark/join',
        'mark/waiting',
        'mark/face',
        'mark/proving',
        'mark/verdict',
        'mark/manual',
      ]) {
        expect(ProxRoutes.isMobileOnly(r), isTrue, reason: r);
      }
      for (final r in [
        'live/CS101',
        'live/CS101/roster',
        'prof/courses',
        'records/mine',
        'records/course/CS101',
        'welcome',
        'roles',
        'device',
        'debug/log',
      ]) {
        expect(ProxRoutes.isMobileOnly(r), isFalse, reason: r);
      }
    });

    test('records-only devices redirect mobile-only routes to records/mine',
        () {
      expect(
          ProxRoutes.mobileGuardRedirect('enroll/intro', mobile: false),
          ProxRoutes.myAttendance);
      expect(ProxRoutes.mobileGuardRedirect('mark/face', mobile: false),
          ProxRoutes.myAttendance);
      // Hosting + records stay put (professors host from desktops).
      expect(ProxRoutes.mobileGuardRedirect('live/CS101', mobile: false),
          isNull);
      expect(
          ProxRoutes.mobileGuardRedirect('records/mine', mobile: false),
          isNull);
      expect(
          ProxRoutes.mobileGuardRedirect('prof/courses', mobile: false),
          isNull);
      // Mobile devices never redirect.
      expect(ProxRoutes.mobileGuardRedirect('enroll/intro', mobile: true),
          isNull);
      expect(ProxRoutes.mobileGuardRedirect('mark/face', mobile: true),
          isNull);
    });
  });

  group('face identity (never raw Gmail, versioned)', () {
    test('faceId is sha256 hex, lowercased, install-scoped', () {
      final a = faceIdOf('Student@Example.COM', 'inst-1');
      final b = faceIdOf('student@example.com', 'inst-1');
      expect(a, b);
      expect(a.length, 64);
      expect(a, isNot(contains('student')));
      expect(faceIdOf('student@example.com', 'inst-2'), isNot(a));
      expect(faceIdOf('other@example.com', 'inst-1'), isNot(a));
    });

    test('verifierVer pins plugin version + asset hash', () {
      expect(kFaceVerifierVer, 'face_verification/0.3.9+b45ab893');
      expect(kFaceVerifierVer.startsWith('face_verification/'), isTrue);
    });

    test('enroll slots are centre/left/right/up/down (5 stills)', () {
      expect(faceEnrollSlots, ['centre', 'left', 'right', 'up', 'down']);
    });
  });

  group('fail-closed stubs (desktop/web)', () {
    test('UnavailableFaceVerifier throws on every op', () async {
      const v = UnavailableFaceVerifier();
      expect(v.verifierVer, 'unavailable');
      expect(() => v.init(), throwsStateError);
      expect(() => v.enroll('f', ['a', 'b', 'c', 'd', 'e']), throwsStateError);
      expect(() => v.verify('f', 'a'), throwsStateError);
      expect(() => v.remove('f'), throwsStateError);
    });

    test('PluginFaceVerifier refuses on records-only devices (L1)', () async {
      // Records-only host (this test host defaults to Android, so pin
      // desktop): the adapter gate fires before any plugin channel call
      // (fail-closed, never a mock pass).
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final v = PluginFaceVerifier();
      expect(() => v.init(), throwsStateError);
      expect(() => v.enroll('f', ['a', 'b', 'c', 'd', 'e']), throwsStateError);
      expect(() => v.verify('f', 'a'), throwsStateError);
    });

    test('UnavailableDeviceKey is level none + throws', () async {
      const d = UnavailableDeviceKey();
      expect(d.level.name, 'none');
      expect(() => d.ensure(), throwsStateError);
      expect(() => d.pkD, throwsStateError);
      expect(await d.heartbeat(), isFalse);
    });

    test('SoftwareDeviceKey seal/unseal roundtrip; garbage fails closed',
        () async {
      final d = SoftwareDeviceKey();
      await d.ensure();
      expect(d.pkD.length, 32);
      expect(d.level.name, 'none'); // no tier claimed (fallback-flagged confirm)
      final seed = Uint8List.fromList(List.filled(32, 9));
      final sealed = await d.seal(seed);
      expect(await d.unseal(sealed), seed);
      expect(() => d.unseal(Uint8List.fromList([1, 2, 3])),
          throwsStateError);
    });

    test('FakeDeviceKey clone simulation: dropKey → restore detected',
        () async {
      final d = FakeDeviceKey();
      final sealed = await d.seal(Uint8List.fromList(List.filled(32, 1)));
      expect(await d.unseal(sealed), hasLength(32));
      d.dropKey();
      expect(() => d.unseal(sealed),
          throwsA(isStateError.having((e) => e.message, 'message',
              contains('restore detected — re-enroll'))));
    });
  });

  group('desktop blocked-state widgets', () {
    testWidgets('FaceBlockedCard explains records-only + next steps',
        (tester) async {
      // Pin desktop: the test host defaults to Android (mobile).
      // Reset inline at the end (the binding verifies foundation vars
      // are unset right after the body — addTearDown runs too late).
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: FaceBlockedCard(flow: 'Face enrollment')),
        ),
      );
      debugDefaultTargetPlatformOverride = null;
      expect(find.textContaining('needs the mobile app'), findsOneWidget);
      expect(find.textContaining('records-only'), findsOneWidget);
      expect(find.textContaining('On your phone'), findsOneWidget);
    });

    testWidgets('MobileOnlyGuidanceScreen routes to records affordance',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await tester.pumpWidget(
        MaterialApp(
          home: const MobileOnlyGuidanceScreen(route: 'mark/face'),
          routes: {ProxRoutes.myAttendance: (_) => const Placeholder()},
        ),
      );
      debugDefaultTargetPlatformOverride = null;
      expect(find.text('Mobile only'), findsOneWidget);
      expect(find.textContaining('needs the mobile app'), findsOneWidget);
      expect(find.text('Open my records'), findsOneWidget);
    });
  });
}
