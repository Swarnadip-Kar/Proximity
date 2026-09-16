// Landing edge-to-edge insets: actionable buttons clear the system nav bar.
//
// The LANDING page (Welcome when signed out, RoleHub when signed in) lives
// outside the shell, so it cannot rely on _ShellEdgeBody — it seats its own
// bottom-only SafeArea (mirroring the shell approach, viewPadding-driven,
// zero hardcoded insets). This matrix pumps both screens under distinct
// device inset profiles and asserts the primary actions sit fully above the
// system nav bar:
//
//   android-3button  bottom 48  (tall fixed nav keys)
//   android-gesture  bottom 20  (thin gesture line)
//   ios-home         bottom 34  (Home indicator)
//   ios-legacy       bottom 0   (older devices: SafeArea no-op)
//   rotation         844x390, bottom 28 (landscape gesture)
//
// Desktop/Web unchanged: zero insets → SafeArea is a structural no-op.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/cloud_sync.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/setup/role_hub_screen.dart';
import 'package:proximity_app/features/setup/welcome_screen.dart';
import 'package:proximity_app/widgets/prox_buttons.dart';

const _acct = SignedAccount(
    email: 'landing@example.com', displayName: 'Landing User', uid: 'landing');

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
  _InsetProfile(
      'rotation', Size(844, 390), EdgeInsets.only(bottom: 28)),
];

List<Override> _welcomeOverrides() => [
      authServiceProvider.overrideWithValue(FakeAuthService()),
      cloudSyncProvider.overrideWithValue(FakeCloudSync()),
      deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
    ];

List<Override> _roleOverrides() => [
      authServiceProvider.overrideWithValue(FakeAuthService(_acct)),
      cloudSyncProvider.overrideWithValue(FakeCloudSync()),
      deviceStoreProvider.overrideWithValue(InMemoryDeviceStore()),
    ];

Future<void> _pumpWithInsets(
  WidgetTester t,
  _InsetProfile p,
  Widget home,
  List<Override> overrides,
) async {
  t.view.physicalSize = p.size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
  await t.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: proxLightTheme(),
        home: MediaQuery(
          data: MediaQueryData(
            size: p.size,
            viewPadding: p.insets,
            padding: p.insets,
          ),
          child: home,
        ),
      ),
    ),
  );
  await t.pump();
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  group('landing insets: welcome actions clear the system nav bar', () {
    for (final p in _profiles) {
      testWidgets('${p.name}: sign-in clears bottom inset', (t) async {
        await _pumpWithInsets(
            t, p, const WelcomeScreen(), _welcomeOverrides());
        expect(t.takeException(), isNull);
        final btnFinder = find.widgetWithText(
            ProxPrimaryButton, 'Sign in with Google');
        expect(btnFinder, findsOneWidget);
        // Bottom action may start below the fold on short viewports —
        // scroll it into view, then assert it sits fully above the nav bar.
        // ensureVisible (not scrollUntilVisible): role-hub's TextField owns
        // an inner Scrollable, so the default scrollable lookup matches two.
        await t.ensureVisible(btnFinder);
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        final btn = t.getRect(btnFinder);
        expect(btn.bottom,
            lessThanOrEqualTo(p.size.height - p.insets.bottom + 1.5),
            reason:
                '${p.name}: sign-in bottom ${btn.bottom} must clear inset ${p.insets.bottom}');
      });
    }
  });

  group('landing insets: role-hub actions clear the system nav bar', () {
    for (final p in _profiles) {
      testWidgets('${p.name}: register clears bottom inset', (t) async {
        await _pumpWithInsets(
            t, p, RoleHubScreen(account: _acct), _roleOverrides());
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        // Fresh account holds no role → register section with student CTA.
        // Button finder (not raw Text) stays single even if the label text
        // appears in helper/decoration strings elsewhere.
        final btnFinder = find.widgetWithText(
            ProxSecondaryButton, 'Register as Student');
        expect(btnFinder, findsOneWidget);
        await t.ensureVisible(btnFinder);
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        final btn = t.getRect(btnFinder);
        expect(btn.bottom,
            lessThanOrEqualTo(p.size.height - p.insets.bottom + 1.5),
            reason:
                '${p.name}: register bottom ${btn.bottom} must clear inset ${p.insets.bottom}');
      });
    }
  });

  group('landing insets wiring (source pins)', () {
    String codeOf(String src) => src
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');

    test('welcome + role-hub seat bottom SafeArea, zero hardcoded insets',
        () {
      final welcome =
          codeOf(File('lib/features/setup/welcome_screen.dart')
              .readAsStringSync());
      final hub = codeOf(
          File('lib/features/setup/role_hub_screen.dart').readAsStringSync());
      for (final src in [welcome, hub]) {
        expect(src.contains('SafeArea('), isTrue);
        expect(src.contains('bottom: true'), isTrue);
        expect(src.contains('top: false'), isTrue);
      }
      // No device-literal bottom padding in the landing bodies — every
      // inset flows through MediaQuery/viewPadding at layout time.
      for (final src in [welcome, hub]) {
        expect(src.contains('48'), isFalse,
            reason: 'hardcoded 3-button inset in landing');
        expect(src.contains('EdgeInsets.only(bottom:'), isFalse);
      }
    });

    test('app chrome bleeds edge-to-edge, never opts out', () {
      final main =
          codeOf(File('lib/main.dart').readAsStringSync());
      expect(main.contains('SystemUiMode.edgeToEdge'), isTrue);
      expect(main.contains('systemNavigationBarColor'), isTrue);
      expect(main.contains('extendBody: isMobile'), isTrue);
      final shells =
          codeOf(File('lib/screens/shells.dart').readAsStringSync());
      expect(shells.contains('extendBody: isMobile'), isTrue);
      expect(shells.contains('_ShellEdgeBody('), isTrue);
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
