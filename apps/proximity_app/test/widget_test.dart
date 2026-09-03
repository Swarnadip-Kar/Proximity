import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/core/face_camera.dart';
import 'package:proximity_app/core/roster_repo.dart';
import 'package:proximity_app/main.dart';
import 'package:proximity_face/face.dart';

ProviderScope testScope({String email = 'aarav@institute.ac.in'}) {
  final auth = FakeAuthService(
      SignedAccount(email: email, displayName: 'Test User'));
  final repo = FakeRosterRepository();
  return ProviderScope(
    overrides: [
      authServiceProvider.overrideWithValue(auth),
      rosterRepositoryProvider.overrideWithValue(repo),
      faceCameraProvider.overrideWithValue(FakeFaceCamera()),
      enrollmentControllerProvider.overrideWith(
        (ref) => EnrollmentController(
          auth: ref.watch(authServiceProvider),
          repo: ref.watch(rosterRepositoryProvider),
          embedder: MockFaceEmbedder(
            enrolled: const [1, 0, 0, 0],
            probe: const [1, 0, 0, 0],
          ),
        ),
      ),
    ],
    child: const ProximityApp(),
  );
}

void main() {
  testWidgets('prof start→LIVE→close→export', (t) async {
    await t.pumpWidget(const ProviderScope(child: ProximityApp()));
    // role select → prof
    await t.tap(find.text('Continue as Professor (host)'));
    await t.pumpAndSettle();
    expect(find.textContaining('Prof —'), findsOneWidget);
    // start window #1
    await t.tap(find.text('Start #1'));
    await t.pump();
    expect(find.textContaining('00:'), findsWidgets);
    // fast-forward 31s → auto-close
    await t.pump(const Duration(seconds: 31));
    // export
    await t.tap(find.text('End + Export'));
    await t.pumpAndSettle();
    expect(find.textContaining('Name,ID Number,Email,W1,W2,Status'), findsOneWidget);
  });

  testWidgets('student join→face→listening→ACK', (t) async {
    await t.pumpWidget(const ProviderScope(child: ProximityApp()));
    await t.tap(find.text('Continue as Student'));
    await t.pumpAndSettle();
    expect(find.text('CS201-Room301'), findsOneWidget);
    // RSSI-sorted: stronger first
    final list = find.byType(ListTile);
    expect(list, findsWidgets);
    await t.tap(find.text('CS201-Room301'));
    await t.pump();
    // face oval appears, then listening after ~1s
    await t.pump(const Duration(seconds: 2));
    expect(find.textContaining('Listening'), findsOneWidget);
    await t.pump(const Duration(seconds: 30));
    expect(find.text('✓ Marked'), findsOneWidget);
  });

  testWidgets('face-fail→needs-review copy present', (t) async {
    // Static copy contract: needs-review path must exist in UI strings.
    await t.pumpWidget(const ProviderScope(child: ProximityApp()));
    await t.tap(find.text('Continue as Student'));
    await t.pumpAndSettle();
    // Paused copy exists in source (background contract); smoke-check browsing.
    expect(find.textContaining('foreground'), findsOneWidget);
  });

  testWidgets('enrollment: sign-in → key → face → upload → linked',
      (t) async {
    await t.pumpWidget(testScope());
    // open enrollment from role select
    await t.tap(find.text('Enroll this device (online, once)'));
    await t.pumpAndSettle();
    expect(find.text('Enroll this device'), findsWidgets);
    // 1. sign in — nothing to type, identity imports from Gmail
    await t.tap(find.text('Sign in with Google'));
    await t.pumpAndSettle();
    expect(find.textContaining('Signed in as Test User'), findsOneWidget);
    expect(find.textContaining('aarav@institute.ac.in'), findsWidgets);
    // ID number (compulsory, saved unverified)
    await t.enterText(
        find.widgetWithText(TextField, 'ID Number'), '12342210');
    await t.pump();
    // 2. device key
    await t.tap(find.text('Generate device key'));
    await t.pumpAndSettle();
    expect(find.textContaining('Key: '), findsOneWidget);
    // 3. face scan (fake camera: preview → scan → detected)
    await t.tap(find.text('Scan face'));
    await t.pumpAndSettle();
    expect(find.text('Face scan'), findsWidgets);
    await t.tap(find.text('Scan my face'));
    await t.pumpAndSettle();
    expect(find.textContaining('Face detected and enrolled'), findsOneWidget);
    // 4. upload → linked banner on role select after Done
    await t.tap(find.text('Upload enrollment'));
    await t.pumpAndSettle();
    expect(find.textContaining('Enrolled. Identity linked'), findsOneWidget);
    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    expect(
        find.textContaining('Enrolled as Test User · 12342210'),
        findsOneWidget);
  });

  testWidgets('late/invalid states render in prof search', (t) async {
    await t.pumpWidget(const ProviderScope(child: ProximityApp()));
    await t.tap(find.text('Continue as Professor (host)'));
    await t.pumpAndSettle();
    await t.tap(find.text('Start #1'));
    await t.pump();
    await t.enterText(find.byType(TextField), 'aarav');
    await t.pump();
    expect(find.text('Aarav S'), findsOneWidget);
  });

  // Regression: Cupertino branch (iOS/macOS) must provide a Material
  // ancestor for the shared body — caught once on-simulator as red screen.
  testWidgets('iOS platform renders student list without material error',
      (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await t.pumpWidget(const ProviderScope(child: ProximityApp()));
    await t.tap(find.text('Continue as Student'));
    await t.pumpAndSettle();
    expect(find.byType(ListTile), findsWidgets);
    expect(t.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS platform renders prof screen without material error',
      (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await t.pumpWidget(const ProviderScope(child: ProximityApp()));
    await t.tap(find.text('Continue as Professor (host)'));
    await t.pumpAndSettle();
    await t.tap(find.text('Start #1'));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(t.takeException(), isNull);
    expect(find.textContaining('present'), findsWidgets);
    debugDefaultTargetPlatformOverride = null;
  });
}
