// Current-IA route-guard unit tests (pure, no Firebase, no widgets).
// Covers normalizeProxRoute, isValidCourseSegment, ProxRouteGuard
// (auth/role/enrollment) and strict parameterized shapes in
// proxOnGenerateRoute. Adapted to the canonical IA on
// routing-overhaul-and-audit (prof/courses, live/<course>, enroll/*,
// records/mine, account/face-id) — not the old placeholder names.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/routes.dart';

void main() {
  group('normalizeProxRoute', () {
    test('trims, strips leading slash and trailing slashes', () {
      expect(normalizeProxRoute('/welcome'), ProxRoutes.welcome);
      expect(normalizeProxRoute('welcome'), ProxRoutes.welcome);
      expect(normalizeProxRoute('  /roles/ '), ProxRoutes.roles);
      expect(normalizeProxRoute('prof/courses/'), ProxRoutes.profCourses);
    });

    test('keeps nested routes intact', () {
      expect(normalizeProxRoute('/enroll/capture'), ProxRoutes.enrollCapture);
      expect(normalizeProxRoute('account/face-id'), ProxRoutes.faceId);
      expect(normalizeProxRoute('/live/CS101'), 'live/CS101');
    });
  });

  group('isValidCourseSegment', () {
    test('accepts normal course names', () {
      expect(isValidCourseSegment('CS201'), isTrue);
      expect(isValidCourseSegment('CS-101 A'), isTrue);
    });

    test('rejects empty, whitespace, slash, overlong', () {
      expect(isValidCourseSegment(''), isFalse);
      expect(isValidCourseSegment('   '), isFalse);
      expect(isValidCourseSegment('a/b'), isFalse);
      expect(isValidCourseSegment('x' * 81), isFalse);
    });
  });

  group('ProxRouteGuard.authGuard', () {
    test('signed-out: only welcome passes', () {
      expect(ProxRouteGuard.authGuard('welcome', signedIn: false), isNull);
      for (final r in [
        ProxRoutes.roles,
        ProxRoutes.profCourses,
        ProxRoutes.enrollCapture,
        ProxRoutes.myAttendance,
        ProxRoutes.faceId,
      ]) {
        expect(ProxRouteGuard.authGuard(r, signedIn: false),
            ProxRoutes.welcome,
            reason: r);
      }
    });

    test('signed-in: welcome -> roles, rest pass', () {
      expect(ProxRouteGuard.authGuard('welcome', signedIn: true),
          ProxRoutes.roles);
      for (final r in [
        ProxRoutes.roles,
        ProxRoutes.profCourses,
        ProxRoutes.enrollCapture,
        ProxRoutes.myAttendance,
      ]) {
        expect(ProxRouteGuard.authGuard(r, signedIn: true), isNull, reason: r);
      }
    });
  });

  group('ProxRouteGuard.roleGuard', () {
    test('prof/live require prof role', () {
      expect(
          ProxRouteGuard.roleGuard('live/CS101',
              roles: {}, signedIn: true),
          ProxRoutes.roles);
      expect(
          ProxRouteGuard.roleGuard(ProxRoutes.profCourses,
              roles: {'student'}, signedIn: true),
          ProxRoutes.roles);
      expect(
          ProxRouteGuard.roleGuard('live/CS101',
              roles: {'prof'}, signedIn: true),
          isNull);
      expect(
          ProxRouteGuard.roleGuard(ProxRoutes.profCourses,
              roles: {'prof', 'student'}, signedIn: true),
          isNull);
    });

    test('signed-out prof/live -> welcome, enroll/* need sign-in', () {
      expect(
          ProxRouteGuard.roleGuard('live/CS101',
              roles: {}, signedIn: false),
          ProxRoutes.welcome);
      expect(
          ProxRouteGuard.roleGuard(ProxRoutes.enrollCapture,
              roles: {}, signedIn: false),
          ProxRoutes.welcome);
      expect(
          ProxRouteGuard.roleGuard(ProxRoutes.myAttendance,
              roles: {}, signedIn: true),
          isNull);
    });
  });

  group('ProxRouteGuard.enrollmentGuard', () {
    test('capture done -> result, result incomplete -> capture', () {
      expect(
          ProxRouteGuard.enrollmentGuard(ProxRoutes.enrollCapture,
              enrolled: true, faceComplete: false),
          ProxRoutes.enrollResult);
      expect(
          ProxRouteGuard.enrollmentGuard(ProxRoutes.enrollCapture,
              enrolled: false, faceComplete: true),
          ProxRoutes.enrollResult);
      expect(
          ProxRouteGuard.enrollmentGuard(ProxRoutes.enrollResult,
              enrolled: false, faceComplete: false),
          ProxRoutes.enrollCapture);
      expect(
          ProxRouteGuard.enrollmentGuard(ProxRoutes.enrollResult,
              enrolled: true, faceComplete: false),
          isNull);
    });

    test('face-id requires enrolled flag', () {
      expect(
          ProxRouteGuard.enrollmentGuard(ProxRoutes.faceId,
              enrolled: false, faceComplete: true),
          ProxRoutes.enrollCapture);
      expect(
          ProxRouteGuard.enrollmentGuard(ProxRoutes.faceId,
              enrolled: true, faceComplete: false),
          isNull);
    });
  });

  group('proxOnGenerateRoute strict shapes', () {
    test('live/ empty and extra suffix are unknown', () {
      expect(
          proxOnGenerateRoute(const RouteSettings(name: 'live/')), isNull);
      expect(proxOnGenerateRoute(const RouteSettings(name: 'live/CS101/x')),
          isNull);
      expect(proxOnGenerateRoute(const RouteSettings(name: 'live/  ')),
          isNull);
    });

    test('live/<course> resolves', () {
      final r =
          proxOnGenerateRoute(const RouteSettings(name: 'live/CS101'));
      expect(r, isNotNull);
      expect(r!.settings.name, 'live/CS101');
    });

    test('prof/courses extra sections are unknown, trailing slash ok', () {
      expect(
          proxOnGenerateRoute(
              const RouteSettings(name: 'prof/courses/')), isNull);
      expect(
          proxOnGenerateRoute(
              const RouteSettings(name: 'prof/courses/CS101/a/b')),
          isNull);
      expect(
          proxOnGenerateRoute(
              const RouteSettings(name: 'prof/courses/CS101/mid')),
          isNull);
      expect(
          proxOnGenerateRoute(
              const RouteSettings(name: 'prof/courses/CS101/')),
          isNotNull);
      expect(
          proxOnGenerateRoute(
              const RouteSettings(name: 'prof/courses/CS101/export/')),
          isNotNull);
    });
  });
}
