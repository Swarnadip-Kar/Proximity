// Shell chrome: compact bar metrics + dynamic edge-to-edge insets.
//
// Bar compact spec (all platforms, design tokens only): bar content
// height ~60 (pill: lg icon 24 + xs gap + 16 label + vxs*2, + bar vxs*2),
// tab icons lg ([ProxIconSizes.lg]), labels 13sp ([ProxType.labelSize]),
// equal-width pills vxs/hsm fixed both states, bar padding vxs/hsm,
// top radius sheet ([ProxRadii.sheetTopRadius]), account avatar lg.
//
// Dynamic insets (mobile shell bleed): the shell extends behind the
// transparent system bars ([Scaffold.extendBody]) and derives every
// inset from live MediaQuery viewPadding — zero hardcoded inset values.
// This matrix proves the derivation across device profiles by pumping
// the enrolled student shell under each profile's insets and asserting
// the bar floats exactly (inset + design margin) above the bottom edge
// and tab content clears the system inset:
//
//   android-3button  bottom 48  (tall fixed nav keys)
//   android-gesture  bottom 20  (thin gesture line)
//   ios-home         bottom 34  (Home indicator)
//   ios-legacy       bottom 0   (older devices: SafeArea no-op)
//   rotation         844x390, bottom 28 + left 47 (cutout + gesture)
//
// Desktop/Web unchanged: with zero system insets the SafeArea is a
// structural no-op (bar sits on the bottom edge, body full height).
import 'dart:io';

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
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_app/features/face_identity/face_verifier.dart';
import 'package:proximity_app/features/mark/face_check.dart';
import 'package:proximity_app/features/records/my_attendance_screen.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_app/screens/shells.dart';
import 'package:proximity_app/screens/student_home.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';

const _linked = LinkedIdentity(
    name: 'Test User', gmail: 'student@example.com', roll: 'R1');

/// Device inset profile: size + system viewPadding (== padding; no
/// keyboard in these tests) injected via MediaQuery below MaterialApp.
class _InsetProfile {
  final String name;
  final Size size;
  final EdgeInsets insets;
  const _InsetProfile(this.name, this.size, this.insets);
}

const _profiles = [
  _InsetProfile(
      'android-3button', Size(800, 600), EdgeInsets.only(bottom: 48)),
  _InsetProfile(
      'android-gesture', Size(800, 600), EdgeInsets.only(bottom: 20)),
  _InsetProfile('ios-home', Size(800, 600), EdgeInsets.only(bottom: 34)),
  _InsetProfile('ios-legacy', Size(800, 600), EdgeInsets.zero),
  _InsetProfile('rotation',
      Size(844, 390), EdgeInsets.only(bottom: 28, left: 47)),
];

Future<FakeCloudSync> _seededCloud() async {
  final cloud = FakeCloudSync();
  for (var k = 0; k < 3; k++) {
    final course = k < 2 ? 'CS201' : 'CS202';
    await cloud.pushSession(
      profUid: 'p1',
      profEmail: 'prof@example.com',
      profName: 'Prof',
      record: ClassRecord(
        courseId: course,
        classLabel: course,
        dateIso: '2026-09-0${4 + k}',
        timestampIso: '2026-09-0${4 + k}T10:00:00.000Z',
        windows: [
          {'student@example.com': k != 2}
        ],
        names: const {'student@example.com': 'Test User'},
        rolls: const {'student@example.com': 'R1'},
      ),
    );
  }
  return cloud;
}

Future<void> _pumpShell(
  WidgetTester t,
  _InsetProfile p, {
  FakeCloudSync? cloud,
}) async {
  // Real view resize (MediaQuery size alone does not move the render
  // surface — rotation/orientation profiles need the physical view).
  t.view.physicalSize = p.size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(FakeAuthService(
            const SignedAccount(
                email: 'student@example.com',
                displayName: 'Test User',
                uid: 'test-uid'))),
        cloudSyncProvider.overrideWithValue(cloud ?? FakeCloudSync()),
        deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
        faceVerifierProvider.overrideWithValue(FakeFaceVerifier()),
        deviceKeyProvider.overrideWithValue(FakeDeviceKey()),
        hostDriverProvider.overrideWithValue(FakeHostDriver()),
        studentDriverProvider
            .overrideWithValue(FakeStudentDriver(windowOpenProbe: false)),
        bleEngineProvider.overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
        blePermissionProvider.overrideWithValue(() async => true),
        btPowerProvider.overrideWithValue(() async => BtState.on),
        linkedIdentityProvider.overrideWith((ref) => _linked),
        enrollmentControllerProvider.overrideWith(
          (ref) => EnrollmentController(
            auth: ref.watch(authServiceProvider),
            store: ref.watch(deviceStoreProvider),
            verifier: FakeFaceVerifier(),
            deviceKey: FakeDeviceKey(),
          ),
        ),
      ],
      child: MaterialApp(
        theme: proxLightTheme(),
        home: MediaQuery(
          data: MediaQueryData(
            size: p.size,
            viewPadding: p.insets,
            padding: p.insets,
          ),
          child: const StudentShell(),
        ),
      ),
    ),
  );
  await t.pump();
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 500));
  }
}

/// Design bottom margin below the tab pills inside the bar (mirrors the
/// `_shellBar` outer vertical padding, v4). The device inset itself is
/// never mirrored here — it flows through MediaQuery per profile.
const _kBarBottomMargin = 4.0;

Finder _coursesTab() => find.descendant(
      of: find.byKey(const ValueKey('shell-bar')),
      matching: find.text('Courses'),
    );

/// Test stand-in for a live frame: self-maintains its native aspect
/// internally (like `CameraPreview`), proving the loose Stack never
/// distorts it even with system insets present.
class _NativeFeed extends StatelessWidget {
  final double ratio;
  const _NativeFeed({required this.ratio});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: ratio,
      child: const SizedBox.expand(key: Key('feed')),
    );
  }
}

String _codeOf(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  group('shell bar scale-up (all platforms)', () {
    testWidgets('bar content height ~60, icons lg, labels 13sp vertical',
        (t) async {
      await _pumpShell(t, _profiles[3], cloud: await _seededCloud());
      expect(t.takeException(), isNull);
      // Bar content (pill: lg 24 + xs gap + 16 label + vxs*2 = 52) +
      // bar vxs*2 = 60, zero insets so the bar sits flush on the
      // bottom edge.
      final bar = t.getRect(find.byKey(const ValueKey('shell-bar')));
      expect(bar.height, moreOrLessEquals(60, epsilon: 1.5));
      expect(bar.bottom, moreOrLessEquals(600, epsilon: 1));
      // Tab icons are lg; labels stay 13sp ([ProxType.labelSize]).
      // (Courses starts inactive → outlined icon; rendered icon size
      // resolves through the bar IconTheme.)
      expect(
        t.getSize(find.byIcon(Icons.layers_outlined)),
        const Size(24, 24),
      );
      final label = t.widget<Text>(find.descendant(
        of: find.byKey(const ValueKey('shell-bar')),
        matching: find.text('Courses'),
      ));
      expect(label.style?.fontSize, ProxType.labelSize);
      expect(t.takeException(), isNull);
    });
  });

  group('dynamic inset matrix (shell bleed)', () {
    for (final p in _profiles) {
      testWidgets('${p.name}: bar clears inset, content clears inset',
          (t) async {
        await _pumpShell(t, p, cloud: await _seededCloud());
        expect(t.takeException(), isNull);
        expect(find.byType(StudentHomeScreen), findsOneWidget);

        // Pills float exactly (system inset + bar design margin) above
        // the bottom edge: dynamic per profile, never a device literal.
        // (The bar box itself includes the SafeArea pad, so measure the
        // live pill rects — matched by the pill-radius decoration, not
        // raw type, since CircleAvatar also builds an AnimatedContainer.)
        final pills = find.descendant(
          of: find.byKey(const ValueKey('shell-bar')),
          matching: find.byWidgetPredicate((w) =>
              w is AnimatedContainer &&
              (w.decoration as BoxDecoration?)?.borderRadius ==
                  BorderRadius.circular(ProxRadii.pill)),
        );
        expect(pills, findsNWidgets(3));
        for (var i = 0; i < 3; i++) {
          final pill = t.getRect(pills.at(i));
          expect(p.size.height - pill.bottom,
              moreOrLessEquals(p.insets.bottom + _kBarBottomMargin, epsilon: 1.5),
              reason: '${p.name}: pill clearance must equal inset + margin');
        }

        // Open Courses through the animation; every frame clean.
        await t.tap(_coursesTab());
        for (var i = 0; i < 8; i++) {
          await t.pump(const Duration(milliseconds: 60));
          expect(t.takeException(), isNull);
        }
        await t.pump(const Duration(milliseconds: 500));
        expect(t.takeException(), isNull);
        expect(find.byType(MyAttendanceScreen), findsOneWidget);

        // Tab content bottom clears the whole bar box (extendBody body
        // padding is the live max(system inset, bar slot) — fully
        // derived, asserted against the live bar rect, no literals).
        final barTop =
            t.getRect(find.byKey(const ValueKey('shell-bar'))).top;
        final list = t.getRect(find.descendant(
          of: find.byType(MyAttendanceScreen),
          matching: find.byType(ListView),
        ));
        expect(list.bottom, moreOrLessEquals(barTop, epsilon: 1.5),
            reason: '${p.name}: content must clear the bar box');
      });
    }
  });

  group('camera preview aspect intact with insets (small viewport)', () {
    testWidgets('feed keeps native ratio under home-indicator insets',
        (t) async {
      const ratio = 3 / 4;
      await t.pumpWidget(MaterialApp(
        theme: proxLightTheme(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 700),
            viewPadding: EdgeInsets.only(bottom: 34, top: 47),
            padding: EdgeInsets.only(bottom: 34, top: 47),
          ),
          child: Scaffold(
            body: FaceCheckView(
              faceNotice: '',
              canScan: true,
              onScan: () {},
              previewAspectRatio: ratio,
              preview: const _NativeFeed(ratio: ratio),
            ),
          ),
        ),
      ));
      await t.pump();
      final feed = t.getRect(find.byKey(const Key('feed')));
      expect(feed.width / feed.height, moreOrLessEquals(ratio, epsilon: 0.02));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  });

  group('edge-to-edge wiring (source pins)', () {
    test('shell bleeds on mobile with dynamic insets, keyed pages', () {
      final shells =
          _codeOf(File('lib/screens/shells.dart').readAsStringSync());
      expect(shells.contains('extendBody: isMobile'), isTrue);
      expect(shells.contains('_ShellEdgeBody('), isTrue);
      expect(shells.contains("key: ValueKey('student-tab-"), isTrue);
      expect(shells.contains("key: ValueKey('prof-tab-"), isTrue);
      expect(shells.contains("key: ValueKey('course-"), isFalse);
    });

    test('courses list keys each card by course', () {
      final mine = _codeOf(File('lib/features/records/my_attendance_screen.dart')
          .readAsStringSync());
      expect(mine.contains("key: ValueKey('course-"), isTrue);
    });

    test('main opts Android into edge-to-edge, transparent nav bar', () {
      final main = _codeOf(File('lib/main.dart').readAsStringSync());
      expect(main.contains('SystemUiMode.edgeToEdge'), isTrue);
      expect(main.contains('systemNavigationBarColor'), isTrue);
      expect(main.contains('isAndroid'), isTrue);
    });

    test('android themes are transparent, never opt out', () {
      for (final f in [
        'android/app/src/main/res/values/styles.xml',
        'android/app/src/main/res/values-night/styles.xml',
      ]) {
        final xml = File(f).readAsStringSync();
        expect(xml.contains('navigationBarColor'), isTrue);
        expect(xml.contains('@android:color/transparent'), isTrue);
        expect(
            xml.contains(
                '<item name="android:windowOptOutEdgeToEdgeEnforcement"'),
            isFalse);
      }
    });
  });
}
