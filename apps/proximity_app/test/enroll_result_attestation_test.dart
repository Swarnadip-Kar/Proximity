// Save-enrollment attestation refusal rendering: the exact state shape
// EnrollmentController.upload() produces on a self-check FAIL (field
// 2026-09-15: expired-cert chain=5 root=6d9db4ce) must render the notice
// + the Debug card + the attestation next-step on the real screen —
// not just in unit-tested copy/classifier helpers.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/attestation_self_check.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/setup/enroll_result.dart';
import 'package:proximity_app/widgets/log_drawer.dart';

/// The production state shape from upload()'s self-check FAIL branch:
/// message + debug built by the real helpers (no hand-typed copies).
EnrollmentState _attestationFailure(EnrollmentController ctl) {
  const check = AttestationSelfCheck(
    ok: false,
    reason: 'expired-cert',
    flags: ['attest-expired', 'attest-cert-0'],
    rootPrefix: '6d9db4ce',
    chainLen: 5,
    debugDetail:
        'now=2026-09-15T13:42Z cert0:1970-01-01→2048-01-01 EXPIRED '
        'cert1:2026-09-07→2026-09-19 ok cert2:2026-08-31→2026-11-09 ok '
        'cert3:2026-02-09→2029-02-08 ok cert4:2025-07-17→2035-07-15 ok',
  );
  return EnrollmentState(
    phase: EnrollPhase.error,
    pkHex: 'aa' * 32,
    faceScore: 0.9,
    message: attestationSelfCheckCopy(check),
    attestationDebug: check.debugLine,
  );
}

Widget _app(EnrollmentController ctl) {
  return ProviderScope(
    overrides: [enrollmentControllerProvider.overrideWith((ref) => ctl)],
    child: MaterialApp(
      theme: proxLightTheme(),
      home: const EnrollResultScreen(),
    ),
  );
}

EnrollmentController _controller() {
  return EnrollmentController(
    auth: FakeAuthService(const SignedAccount(
        email: 's@x.in', displayName: 'S', uid: 'u')),
    store: InMemoryDeviceStore(),
    verifier: FakeFaceVerifier(),
    deviceKey: FakeDeviceKey(),
    cloud: FakeCloudSync(),
  );
}

void main() {
  testWidgets('save screen shows notice + Debug card + attestation next step',
      (t) async {
    final ctl = _controller();
    ctl.state = _attestationFailure(ctl);
    await t.pumpWidget(_app(ctl));
    await t.pumpAndSettle();
    expect(find.text('Save enrollment'), findsWidgets);
    expect(find.textContaining('hardware certificate is expired'),
        findsOneWidget);
    expect(find.textContaining('Debug: chain=5 root=6d9db4ce'),
        findsOneWidget);
    expect(find.textContaining('attest-cert-0'), findsOneWidget);
    expect(find.text('Back to account step'), findsOneWidget);
  });

  testWidgets('generic refusal never shows the Debug card', (t) async {
    final ctl = _controller();
    ctl.state = const EnrollmentState(
      phase: EnrollPhase.error,
      message: 'Something unexpected happened — try again.',
      // Stale detail must stay hidden under a non-attestation refusal.
      attestationDebug: 'chain=5 root=6d9db4ce flags=[] now=2026-09-15Z',
    );
    await t.pumpWidget(_app(ctl));
    await t.pumpAndSettle();
    expect(find.textContaining('Debug:'), findsNothing);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('save screen has a System log action opening the drawer',
      (t) async {
    final ctl = _controller();
    ctl.state = const EnrollmentState(
        phase: EnrollPhase.faceDone, faceScore: 0.9);
    await t.pumpWidget(_app(ctl));
    await t.pumpAndSettle();
    expect(find.byTooltip('System log'), findsOneWidget);
    await t.tap(find.byTooltip('System log'));
    await t.pumpAndSettle();
    expect(find.byType(LogDrawerContent), findsOneWidget);
  });
}
