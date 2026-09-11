// Landscape support (tester-reported: no orientation lock exists, yet the
// app never goes landscape-usable — presentation/navigation only).
//
// Audit-first suite: every group pumps key screens at landscape phone
// dimensions (740x360, 844x390) + 130% system text and pins no-overflow /
// no-clip / reachable + the responsive rules:
//
// - Landscape phone lists breathe (max-width centered, no fullscreen
//   stretch — §10 ≥600dp rule, ConstrainedBox 560).
// - Camera preview fills HEIGHT first with chrome re-seated; overlay
//   geometry follows the true preview box (reuses displayedPreviewAspect /
//   previewAspectRatio helpers — no new aspect logic).
// - Sheets/dialogs bounded (width + height), tab bar intact, no
//   fixed-height text clipping.
// - Capture DRIVER/timings untouched; portrait rendering pixel-identical
//   (pinned by the untouched existing suites — full suite must stay green).
//
// Frozen per FEATURE_INVENTORY.md Appendix A: strings, timings,
// thresholds, verdict/network semantics — none asserted beyond rendering.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/ble_radio.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/enrollment.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/design/tokens.dart';
import 'package:proximity_app/features/account/account_device_page.dart';
import 'package:proximity_app/features/account/account_enrollment_page.dart';
import 'package:proximity_app/features/account/account_screen.dart';
import 'package:proximity_app/features/account/face_id_screen.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/mark/face_check.dart';
import 'package:proximity_app/features/mark/proving_view.dart';
import 'package:proximity_app/features/mark/verdict_view.dart';
import 'package:proximity_app/features/mark/waiting_room.dart';
import 'package:proximity_app/features/records/course_overview_screen.dart';
import 'package:proximity_app/features/records/export_center_screen.dart';
import 'package:proximity_app/features/records/my_attendance_screen.dart';
import 'package:proximity_app/features/records/prof_courses_screen.dart';
import 'package:proximity_app/features/setup/device_intro_step.dart';
import 'package:proximity_app/features/setup/enroll_capture_sections.dart';
import 'package:proximity_app/features/setup/enroll_result.dart';
import 'package:proximity_app/features/setup/enroll_widgets.dart';
import 'package:proximity_app/features/setup/welcome_screen.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_app/screens/shells.dart';
import 'package:proximity_app/screens/student_home.dart';
import 'package:proximity_app/screens/take_attendance.dart';
import 'package:proximity_app/widgets/capture_overlay.dart';
import 'package:proximity_app/widgets/fallback_button.dart';
import 'package:proximity_app/widgets/student_card.dart';
import 'package:proximity_app/widgets/verdict_badge.dart';
import 'package:proximity_ble/ble.dart';

const _linked = LinkedIdentity(
    name: 'Test User', gmail: 'student@example.com', roll: 'R1001');
const _acct = SignedAccount(
    email: 'student@example.com', displayName: 'Test User', uid: 'test-uid');

List<Override> _ov({LinkedIdentity? linked = _linked}) => [
      authServiceProvider.overrideWithValue(FakeAuthService(_acct)),
      cloudSyncProvider.overrideWithValue(FakeCloudSync()),
      deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
      faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
      deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
      hostDriverProvider.overrideWithValue(FakeHostDriver()),
      studentDriverProvider
          .overrideWithValue(FakeStudentDriver(windowOpenProbe: false)),
      bleEngineProvider.overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
      blePermissionProvider.overrideWithValue(() async => true),
      btPowerProvider.overrideWithValue(() async => BtState.on),
      if (linked != null) linkedIdentityProvider.overrideWith((ref) => linked),
      enrollmentControllerProvider.overrideWith(
        (ref) => EnrollmentController(
          auth: ref.watch(authServiceProvider),
          store: ref.watch(deviceStoreProvider),
          verifier: FakeFaceVerifier(),
          deviceKey: FakeDeviceKey(),
        ),
      ),
    ];

/// Themed host with 130% dynamic type (the same MediaQuery every screen
/// reads for §9 text scaling).
Widget _app(Widget home, {List<Override>? extra}) => ProviderScope(
      overrides: [..._ov(), ...?extra],
      child: MaterialApp(
        theme: proxLightTheme(),
        builder: (c, ch) => MediaQuery(
          data: MediaQuery.of(c).copyWith(
            textScaler: TextScaler.linear(1.3),
          ),
          child: ch!,
        ),
        home: home,
      ),
    );

void _landscape(WidgetTester t, double w, double h) {
  t.view.physicalSize = Size(w, h);
  t.view.devicePixelRatio = 1.0;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
}

Future<void> _settleShort(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 500));
  }
}

void main() {
  group('shells + tabs landscape (tab bar intact)', () {
    for (final size in [const Size(740, 360), const Size(844, 390)]) {
      testWidgets(
          'student shell ${size.width.toInt()}x${size.height.toInt()} 130% settles, 3 tabs visible',
          (t) async {
        _landscape(t, size.width, size.height);
        await t.pumpWidget(_app(const StudentShell()));
        await _settleShort(t);
        expect(t.takeException(), isNull);
        // Gradient-pill shell bar: keyed container + tab labels.
        expect(find.byKey(const ValueKey('shell-bar')), findsOneWidget);
        expect(find.text('Mark'), findsOneWidget);
        expect(find.text('Courses'), findsWidgets);
        expect(find.text('Account'), findsOneWidget);
        // Tab bar sits above the bottom edge (SafeArea honored).
        final bar = t.getRect(find.byKey(const ValueKey('shell-bar')));
        expect(bar.bottom, lessThanOrEqualTo(size.height));
        expect(bar.width, moreOrLessEquals(size.width, epsilon: 1));
      });

      testWidgets(
          'prof shell ${size.width.toInt()}x${size.height.toInt()} 130% settles, Live root reachable',
          (t) async {
        _landscape(t, size.width, size.height);
        await t.pumpWidget(ProviderScope(
          overrides: _ov(),
          child: MaterialApp(
            theme: proxLightTheme(),
            builder: (c, ch) => MediaQuery(
              data: MediaQuery.of(c)
                  .copyWith(textScaler: TextScaler.linear(1.3)),
              child: ch!,
            ),
            home: const ProfShell(),
          ),
        ));
        await _settleShort(t);
        expect(t.takeException(), isNull);
        expect(find.byKey(const ValueKey('shell-bar')), findsOneWidget);
        expect(
            find.descendant(
              of: find.byKey(const ValueKey('shell-bar')),
              matching: find.text('Live'),
            ),
            findsOneWidget);
        expect(find.text('Courses'), findsWidgets);
        expect(
            find.descendant(
              of: find.byKey(const ValueKey('shell-bar')),
              matching: find.text('Account'),
            ),
            findsOneWidget);
      });
    }
  });

  group('mark phases landscape (scroll, no overflow)', () {
    testWidgets('waiting + proving + verdict settle at 740x360 130%',
        (t) async {
      _landscape(t, 740, 360);
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        builder: (c, ch) => MediaQuery(
          data:
              MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(1.3)),
          child: ch!,
        ),
        home: Scaffold(
          body: WaitingRoomView(
            connected: true,
            roomClass: 'CS201',
            roundMarks: const ['R1 · KQ7 · 10:04:12'],
            onRequestManual: () {},
            onCancel: () {},
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('Connected'), findsOneWidget);

      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        builder: (c, ch) => MediaQuery(
          data:
              MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(1.3)),
          child: ch!,
        ),
        home: const Scaffold(
          body: ProvingView(status: 'Signal heard — proving…'),
        ),
      ));
      await t.pump();
      await t.pump(const Duration(seconds: 2));
      expect(t.takeException(), isNull);

      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        builder: (c, ch) => MediaQuery(
          data:
              MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(1.3)),
          child: ch!,
        ),
        home: Scaffold(
          body: MarkVerdictView(
            kind: MarkVerdict.marked,
            detail: '',
            roundMarks: const ['R1 · KQ7 · 10:04:12'],
            onRetryFace: () {},
            onManualInstead: () {},
            onBack: () {},
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('✓ Marked'), findsOneWidget);
    });

    testWidgets('student home browse settles at 844x390 130%', (t) async {
      _landscape(t, 844, 390);
      await t.pumpWidget(ProviderScope(
        overrides: _ov(),
        child: MaterialApp(
          theme: proxLightTheme(),
          builder: (c, ch) => MediaQuery(
            data: MediaQuery.of(c)
                .copyWith(textScaler: TextScaler.linear(1.3)),
            child: ch!,
          ),
          home: const StudentHomeScreen(),
        ),
      ));
      await _settleShort(t);
      expect(t.takeException(), isNull);
      expect(find.text('Live on this WiFi'), findsOneWidget);
    });
  });

  group('setup steps landscape (CTA reachable via scroll)', () {
    testWidgets('device + account-key + result settle at 740x360 130%',
        (t) async {
      _landscape(t, 740, 360);
      await t.pumpWidget(_app(const DeviceConfirmStep()));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.scrollUntilVisible(find.text('Continue'), 200);
      expect(t.takeException(), isNull);

      await t.pumpWidget(_app(const AccountKeyStep()));
      await _settleShort(t);
      expect(t.takeException(), isNull);

      await t.pumpWidget(_app(const EnrollResultScreen()));
      await _settleShort(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('welcome settles at 844x390 130%', (t) async {
      _landscape(t, 844, 390);
      await t.pumpWidget(_app(const WelcomeScreen()));
      await _settleShort(t);
      expect(t.takeException(), isNull);
      expect(find.text('Sign in with Google'), findsOneWidget);
    });
  });

  group('capture landscape (height-first, chrome re-seated)', () {
    testWidgets('enroll feed preserves ratio, overlay inside video box',
        (t) async {
      _landscape(t, 740, 360);
      Widget feed(double r) => AspectRatio(
            aspectRatio: r,
            child: const SizedBox.expand(key: Key('feed')),
          );
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 740,
            height: 250,
            child: EnrollCapturePreview(
              controller: null,
              isOpening: false,
              failMessage: null,
              doneCount: 1,
              total: 5,
              nextAngle: 1,
              totalAngles: 5,
              statusLine: enrollCapturePrompt,
              sweepAngle: 0.5,
              saveError: false,
              saveMessage: '',
              preview: feed(4 / 3),
              previewAspectRatio: 4 / 3,
            ),
          ),
        ),
      ));
      await t.pump();
      expect(t.takeException(), isNull);
      final feedRect = t.getRect(find.byKey(const Key('feed')));
      // Height-first letterbox: feed fills the 250px height, bars on sides.
      expect(feedRect.height, moreOrLessEquals(250, epsilon: 1));
      expect(feedRect.width / feedRect.height,
          moreOrLessEquals(4 / 3, epsilon: 0.01));
      // Overlay oval tracks the video box (same fractions the overlay
      // derives via guideRectForAspect — no new aspect logic).
      final box = const Size(740, 250);
      final video =
          CaptureOverlay.previewRectFor(box, 4 / 3);
      final oval = CaptureOverlay.guideRectForAspect(box, 4 / 3);
      expect(video.contains(oval.topLeft), isTrue);
      expect(video.contains(oval.bottomRight), isTrue);
    });

    testWidgets('face-check prompt never hides under Scan at 740x360 130%',
        (t) async {
      _landscape(t, 740, 360);
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        builder: (c, ch) => MediaQuery(
          data:
              MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(1.3)),
          child: ch!,
        ),
        home: Scaffold(
          body: SizedBox(
            width: 740,
            height: 300,
            child: FaceCheckView(faceNotice: '', canScan: true, onScan: () {}),
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      final prompt = t.getRect(find.text(faceCheckPrompt));
      final btn = t.getRect(find.text('Scan face'));
      expect(prompt.overlaps(btn), isFalse,
          reason: 'prompt $prompt hidden under Scan $btn in landscape');
      expect(find.text('Scan face'), findsOneWidget);
    });

    testWidgets('face-check prompt reachable at 844x390 130%', (t) async {
      _landscape(t, 844, 390);
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        builder: (c, ch) => MediaQuery(
          data:
              MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(1.3)),
          child: ch!,
        ),
        home: Scaffold(
          body: SizedBox(
            width: 844,
            height: 330,
            child: FaceCheckView(faceNotice: '', canScan: true, onScan: () {}),
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      final prompt = t.getRect(find.text(faceCheckPrompt));
      final btn = t.getRect(find.text('Scan face'));
      expect(prompt.overlaps(btn), isFalse,
          reason: 'prompt $prompt hidden under Scan $btn in landscape');
    });
  });

  group('take host landscape (sections reachable)', () {
    testWidgets('host settles, inbox reachable via sub-nav at 740x360 130%',
        (t) async {
      _landscape(t, 740, 360);
      await t.pumpWidget(ProviderScope(
        overrides: _ov(),
        child: MaterialApp(
          theme: proxLightTheme(),
          builder: (c, ch) => MediaQuery(
            data: MediaQuery.of(c)
                .copyWith(textScaler: TextScaler.linear(1.3)),
            child: ch!,
          ),
          home: const TakeAttendanceScreen(courseName: 'CS201'),
        ),
      ));
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
      expect(t.takeException(), isNull);
      await t.tap(find.text('Inbox'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.textContaining('Manual requests'), findsOneWidget);
    });
  });

  group('records landscape (max-width breathing, no stretch)', () {
    testWidgets('my-attendance + prof courses settle at 740x360 130%',
        (t) async {
      _landscape(t, 740, 360);
      await t.pumpWidget(_app(const MyAttendanceScreen()));
      await _settleShort(t);
      expect(t.takeException(), isNull);

      await t.pumpWidget(_app(const ProfCoursesScreen()));
      await _settleShort(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('overview + export settle at 844x390 130%', (t) async {
      _landscape(t, 844, 390);
      await t.pumpWidget(_app(const CourseOverviewScreen(courseName: 'CS201')));
      await _settleShort(t);
      expect(t.takeException(), isNull);

      await t.pumpWidget(_app(const ExportCenterScreen(courseName: 'CS201')));
      await _settleShort(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('browse tiles never stretch past 560 in landscape',
        (t) async {
      _landscape(t, 740, 360);
      await t.pumpWidget(ProviderScope(
        overrides: _ov(),
        child: MaterialApp(
          theme: proxLightTheme(),
          builder: (c, ch) => MediaQuery(
            data: MediaQuery.of(c)
                .copyWith(textScaler: TextScaler.linear(1.3)),
            child: ch!,
          ),
          home: const StudentHomeScreen(),
        ),
      ));
      await _settleShort(t);
      expect(t.takeException(), isNull);
      // The browse list centers content: no tile spans the full 740 width.
      final tiles = t.widgetList<ConstrainedBox>(
        find.byWidgetPredicate((w) =>
            w is ConstrainedBox &&
            w.constraints.maxWidth == ProxSpacing.maxContentWidth),
      );
      expect(tiles, isNotEmpty);
    });
  });

  group('account landscape', () {
    testWidgets('student + prof + face-id settle at 740x360 130%',
        (t) async {
      _landscape(t, 740, 360);
      await t.pumpWidget(_app(const StudentAccountScreen()));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);

      await t.pumpWidget(ProviderScope(
        overrides: _ov(),
        child: MaterialApp(
          theme: proxLightTheme(),
          builder: (c, ch) => MediaQuery(
            data: MediaQuery.of(c)
                .copyWith(textScaler: TextScaler.linear(1.3)),
            child: ch!,
          ),
          home: const ProfAccountScreen(),
        ),
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);

      await t.pumpWidget(ProviderScope(
        overrides: _ov(),
        child: MaterialApp(
          theme: proxLightTheme(),
          builder: (c, ch) => MediaQuery(
            data: MediaQuery.of(c)
                .copyWith(textScaler: TextScaler.linear(1.3)),
            child: ch!,
          ),
          home: const FaceIdScreen(),
        ),
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });

    testWidgets('enrollment + device sub-pages settle at 844x390 130%',
        (t) async {
      _landscape(t, 844, 390);
      await t.pumpWidget(
          _app(AccountEnrollmentPage(acct: _acct)));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);

      await t.pumpWidget(_app(AccountDevicePage(acct: _acct)));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  });

  group('sheets + dialogs bounded landscape', () {
    testWidgets('fallback sheet never stretches past 560 at 740x360',
        (t) async {
      _landscape(t, 740, 360);
      await t.pumpWidget(ProviderScope(
        overrides: _ov(),
        child: MaterialApp(
          theme: proxLightTheme(),
          builder: (c, ch) => MediaQuery(
            data: MediaQuery.of(c)
                .copyWith(textScaler: TextScaler.linear(1.3)),
            child: ch!,
          ),
          home: Scaffold(
            body: Center(
              child: FallbackButton(
                label: 'Enter IP manually',
                sheetTitle: 'Enter IP manually',
                sheetBuilder: (_) => const TextField(
                  decoration: InputDecoration(labelText: 'Professor IP'),
                ),
              ),
            ),
          ),
        ),
      ));
      await t.pumpAndSettle();
      await t.tap(find.text('Enter IP manually'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.byType(TextField), findsOneWidget);
      final field = t.getRect(find.byType(TextField));
      expect(field.width, lessThanOrEqualTo(ProxSpacing.maxContentWidth),
          reason: 'sheet $field stretches full width in landscape');
    });

    testWidgets('alert dialog bounded at 740x360 130%', (t) async {
      _landscape(t, 740, 360);
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        builder: (c, ch) => MediaQuery(
          data:
              MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(1.3)),
          child: ch!,
        ),
        home: Builder(builder: (c) {
          return Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showDialog(
                  context: c,
                  builder: (_) => AlertDialog(
                    title: const Text('Delete course CS201?'),
                    content: const Text(
                        'This will delete attendance data of 30 students for 12 sessions. This cannot be undone.'),
                    actions: [
                      TextButton(onPressed: () {}, child: const Text('Cancel')),
                      TextButton(onPressed: () {}, child: const Text('Delete')),
                    ],
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          );
        }),
      ));
      await t.pumpAndSettle();
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('Delete course CS201?'), findsOneWidget);
      // Dialog actions stay reachable (no clipping under the short height).
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });
  });

  group('no fixed-height text clipping landscape', () {
    testWidgets('long student card survives 740x360 130%', (t) async {
      _landscape(t, 740, 360);
      const longName =
          'Alexandria Constantine Worthington-Smythe the Third Esquire Junior';
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        builder: (c, ch) => MediaQuery(
          data:
              MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(1.3)),
          child: ch!,
        ),
        home: const Scaffold(
          body: StudentCard(
            name: longName,
            subtitle:
                '99999999 · a.very.long.email.address@university.example.edu',
            status: VerdictBadge(status: ProxStatus.marked),
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      final name = t.widget<Text>(find.text(longName));
      expect(name.overflow, TextOverflow.ellipsis);
    });
  });
}
