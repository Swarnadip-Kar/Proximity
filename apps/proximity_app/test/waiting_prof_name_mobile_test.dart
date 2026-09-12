// Waiting-room professor-name visibility on phones (PROF-NAME data path +
// card visibility).
//
// Root-cause repro: joining an OPEN class from the browse tile goes straight
// to face check (`_joinBeacon`), which never stored the tapped announcement's
// prof/org — so after the round the rewait waiting room showed no host card
// at all even though the name was known. Mobile-only: only face-capable
// devices (`canUseFace() == isMobile`) can mark and therefore rewait;
// records-only desktop/web never reach that room. The view-level cases pin
// the mobile-viewport rendering contract (known names always visible;
// genuinely-unknown hosts keep email-fallback + dedupe + shrink).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/mark/waiting_room.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_app/screens/student_home.dart';
import 'package:proximity_app/widgets/host_preview_card.dart';
import 'package:proximity_transport/transport.dart';

import 'widget_test.dart' as helpers;

Widget _themed(Widget body) => MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(body: body),
    );

/// Narrow-phone viewport for every case in this file.
void _phone(WidgetTester t) {
  t.view.physicalSize = const Size(360, 640);
  t.view.devicePixelRatio = 1.0;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
}

Widget _waiting({
  String prof = 'Prof Mobile',
  String email = '',
  String org = 'example.com',
}) =>
    _themed(
      WaitingRoomView(
        connected: true,
        roomClass: 'CSMOB',
        roomProf: prof,
        roomProfEmail: email,
        roomOrg: org,
        roundMarks: const [],
        onRequestManual: () {},
        onCancel: () {},
      ),
    );

void main() {
  testWidgets(
      'mobile rewait waiting room keeps the announced prof name (open tap)',
      (t) async {
    // Failing-first repro for the join-class waiting-page bug: the prof
    // name is known (tapped announcement carries it) but the phone's
    // post-round waiting room must still render it.
    _phone(t);
    final driver = FakeStudentDriver(windowOpenProbe: true);
    await t.pumpWidget(helpers.testScope(
      linked: const LinkedIdentity(
          name: 'Test User',
          gmail: 'student@example.com',
          roll: '12342210'),
      studentDriver: driver,
      discoveryPort: 54917,
      home: MaterialApp(
          theme: proxLightTheme(), home: const StudentHomeScreen()),
    ));
    await t.pumpAndSettle();
    ClassAnnouncer announce() => ClassAnnouncer(
          () => ClassAnnouncement(
            classLabel: 'CSMOB',
            host: '127.0.0.1',
            port: 8443,
            display: 'M1X',
            prof: 'Prof Mobile',
            windowOpen: true,
            ts: DateTime.now().toUtc(),
            org: 'example.com',
          ),
          target: InternetAddress.loopbackIPv4,
          port: 54917,
        );
    final ann = announce();
    await ann.start();
    addTearDown(ann.stop);
    // Real-async window: the first beacon sends synchronously on start;
    // loopback delivery needs the real event loop (runAsync), then a pump
    // to rebuild with the tile.
    await t.runAsync(() => Future.delayed(const Duration(seconds: 1)));
    await t.pump();
    expect(find.text('CSMOB'), findsOneWidget);
    // Open window → straight to face check (zero taps after this one);
    // the auto-scan passes and the fake marks round 1. Beacons are no
    // longer needed past the tap — stop the announcer now (its timer is
    // not widget-owned, so it must not outlive the test body).
    await t.tap(find.text('CSMOB'));
    await ann.stop();
    var marked = false;
    for (var i = 0; i < 20 && !marked; i++) {
      await t.pump(const Duration(seconds: 1));
      marked = find.text('Marked').evaluate().isNotEmpty;
    }
    expect(marked, isTrue);
    // Round ends behind the badge → rewait waiting room for the next round.
    driver.windowOpenProbe = false;
    var waiting = false;
    for (var i = 0; i < 20 && !waiting; i++) {
      await t.pump(const Duration(seconds: 1));
      waiting =
          find.textContaining('has not yet started').evaluate().isNotEmpty;
    }
    expect(waiting, isTrue);
    await t.pump(const Duration(milliseconds: 500));
    // The known prof name + org from the tapped announcement render on the
    // phone (shared host card, no prefix, address never twice).
    expect(find.text('Prof Mobile'), findsOneWidget);
    expect(find.text('example.com'), findsOneWidget);
    expect(find.textContaining('Hosted by'), findsNothing);
    expect(find.byType(HostPreviewCard), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  group('known-name states render the name on the mobile viewport', () {
    testWidgets('name + org', (t) async {
      _phone(t);
      await t.pumpWidget(_waiting());
      await t.pumpAndSettle();
      expect(find.text('Prof Mobile'), findsOneWidget);
      expect(find.text('example.com'), findsOneWidget);
      expect(find.textContaining('Hosted by'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('name + email + org dedupes the address', (t) async {
      _phone(t);
      await t.pumpWidget(_waiting(email: 'prof.m@example.com'));
      await t.pumpAndSettle();
      expect(find.text('Prof Mobile'), findsOneWidget);
      // Email and org render on separate lines (no '·' join).
      expect(find.text('prof.m@example.com'), findsOneWidget);
      expect(find.text('example.com'), findsOneWidget);
      expect(find.textContaining('prof.m@example.com'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('name-only shows the title', (t) async {
      _phone(t);
      await t.pumpWidget(_waiting(org: ''));
      await t.pumpAndSettle();
      expect(find.text('Prof Mobile'), findsOneWidget);
      expect(find.byType(HostPreviewCard), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('padded name trims to the name', (t) async {
      _phone(t);
      await t.pumpWidget(_waiting(prof: '  Prof Mobile  '));
      await t.pumpAndSettle();
      expect(find.text('Prof Mobile'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('genuinely-unknown hosts keep the fallback contract', () {
    testWidgets('typed-IP join renders no host card at all', (t) async {
      _phone(t);
      await t.pumpWidget(_waiting(prof: '', email: '', org: ''));
      await t.pumpAndSettle();
      expect(find.byType(HostPreviewCard), findsNothing);
      expect(find.textContaining('@'), findsNothing);
      expect(find.textContaining('·'), findsNothing);
      expect(find.textContaining('Hosted by'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('email-only host falls back to the email title',
        (t) async {
      _phone(t);
      await t.pumpWidget(
          _waiting(prof: '', email: 'prof.m@example.com', org: ''));
      await t.pumpAndSettle();
      expect(find.text('prof.m@example.com'), findsOneWidget);
      expect(find.textContaining('·'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('unnamed host falls back to email, org deduped',
        (t) async {
      _phone(t);
      await t.pumpWidget(
          _waiting(prof: '', email: 'prof.m@example.com'));
      await t.pumpAndSettle();
      expect(find.text('prof.m@example.com'), findsOneWidget);
      expect(find.text('example.com'), findsOneWidget);
      expect(find.textContaining('prof.m@example.com'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  testWidgets('whitespace-only prof renders no host card', (t) async {
    // Guard matches the shared card's trim semantics: blank-but-non-empty
    // strings must not force a stray empty card (no title, no lines).
    _phone(t);
    await t.pumpWidget(_waiting(prof: '   ', email: '', org: ''));
    await t.pumpAndSettle();
    expect(find.byType(HostPreviewCard), findsNothing);
    expect(find.textContaining('·'), findsNothing);
    expect(t.takeException(), isNull);
  });
}
