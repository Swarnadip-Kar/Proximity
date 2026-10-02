// Restore-locked contract: a capture opened with a fresh controller
// draft must distinguish "enrollment doc found but key behind the lock"
// (unlock-and-retry copy + in-place Try again) from "genuinely keyless"
// (generate-first copy, no action). The flag lives on the controller
// ([EnrollmentController.restoreLockedForAccount], set by _tryRestore);
// the preview renders the locked branch only when flagged.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/setup/enroll_capture_sections.dart';
import 'package:proximity_app/widgets/prox_buttons.dart';

const _acct = SignedAccount(email: 's@x.in', displayName: 'S', uid: 'u1');

/// Store double failing enrollment reads with a fixed error.
class _FailingReadStore extends InMemoryDeviceStore {
  final Object error;
  _FailingReadStore(this.error);

  @override
  Future<StoredEnrollment?> readEnrollment() async => throw error;
}

EnrollmentController _controller(
        FakeAuthService auth, InMemoryDeviceStore store) =>
    EnrollmentController(
      auth: auth,
      store: store,
      verifier: FakeFaceVerifier(),
      deviceKey: FakeDeviceKey(),
    );

void main() {
  group('restoreLockedForAccount (controller)', () {
    test('dismissed prompt flags locked, keys stay empty', () async {
      final ctl = _controller(
        FakeAuthService(_acct),
        _FailingReadStore(const SecureStoreDismissed()),
      );
      await ctl.refreshFromAuth();
      expect(ctl.state.pkHex, isEmpty);
      expect(ctl.restoreLockedForAccount, isTrue);
    });

    test('transient failure flags locked, keys stay empty', () async {
      final ctl = _controller(
        FakeAuthService(_acct),
        _FailingReadStore(const SecureStoreUnavailable()),
      );
      await ctl.refreshFromAuth();
      expect(ctl.state.pkHex, isEmpty);
      expect(ctl.restoreLockedForAccount, isTrue);
    });

    test('clean miss clears the flag (generate-first copy)', () async {
      final ctl = _controller(
        FakeAuthService(_acct),
        InMemoryDeviceStore(),
      );
      await ctl.refreshFromAuth();
      expect(ctl.state.pkHex, isEmpty);
      expect(ctl.restoreLockedForAccount, isFalse);
    });
  });

  group('locked fail branch (preview)', () {
    Future<void> pumpPreview(
      WidgetTester t, {
      required bool locked,
      required int Function() onRetry,
    }) {
      return t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        home: Scaffold(
          body: EnrollCapturePreview(
            controller: null,
            isOpening: false,
            failMessage: locked
                ? 'Couldn’t unlock this device’s key — approve the phone prompt, then try again.'
                : 'Generate the device key on the previous screen first — the face capture seals to it.',
            doneCount: 0,
            total: 5,
            nextAngle: 0,
            totalAngles: 5,
            statusLine: '',
            sweepAngle: null,
            saveError: false,
            saveMessage: '',
            restoreLocked: locked,
            onRetryRestore: () async {
              onRetry();
            },
          ),
        ),
      ));
    }

    testWidgets('locked shows unlock copy + working Try again',
        (t) async {
      var retries = 0;
      await pumpPreview(t, locked: true, onRetry: () => retries++);
      await t.pump();
      expect(find.textContaining('Couldn’t unlock'), findsOneWidget);
      expect(find.textContaining('Generate the device key'), findsNothing);
      await t.tap(find.widgetWithText(ProxPrimaryButton, 'Try again'));
      await t.pump();
      expect(retries, 1);
      expect(t.takeException(), isNull);
    });

    testWidgets('keyless keeps the static copy with no action', (t) async {
      await pumpPreview(t, locked: false, onRetry: () => 0);
      await t.pump();
      expect(find.textContaining('Generate the device key'), findsOneWidget);
      expect(find.widgetWithText(ProxPrimaryButton, 'Try again'),
          findsNothing);
      expect(t.takeException(), isNull);
    });
  });
}
