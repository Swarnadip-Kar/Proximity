// Mark slim-down + verdict-back regression (tester fixes, presentation /
// navigation only):
// - Browse carries NO Attendance-records section and NO Enroll-this-device
//   entry (records live in Courses, enrollment in Setup/Account; the Mark
//   gate routes unenrolled users). Kept: live list, fallback-weight IP
//   entry (button → sheet), broadcast-blocked banner, empty state.
// - Back from EVERY verdict (marked/late/manual-decided/wrong-org/
//   needs-review/no-signal) lands DIRECTLY on mark/browse in one step —
//   explicit back action and system-back path alike, never stepping through
//   waiting/face/proving.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/mark/browse_classes.dart';
import 'package:proximity_app/features/mark/verdict_section.dart';
import 'package:proximity_app/features/mark/verdict_view.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_app/screens/student_home.dart';
import 'package:proximity_transport/transport.dart';

import 'widget_test.dart' as helpers;

/// Themed pump helper (rebuilt mark views read `ProximityColors`).
Widget _themed(Widget body) => MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(body: body),
    );

Widget _browse({
  String avatarName = 'Test User',
  String avatarPhotoUrl = '',
  String joinError = '',
  List<LiveClass> live = const [],
  bool broadcastBlocked = false,
}) =>
    _themed(
      BrowseClassesView(
        avatarName: avatarName,
        avatarPhotoUrl: avatarPhotoUrl,
        ipInitial: '',
        onIpChanged: (_) {},
        onJoin: () {},
        joinError: joinError,
        live: live,
        onTapLive: (_) {},
        onRefresh: () async {},
        broadcastBlocked: broadcastBlocked,
      ),
    );

LiveClass _live({
  String label = 'CS201',
  String host = '10.0.0.5',
  int port = 8443,
  bool open = true,
}) {
  final now = DateTime.now().toUtc();
  return LiveClass(
    last: ClassAnnouncement(
      classLabel: label,
      host: host,
      port: port,
      display: 'KQ7',
      prof: 'Prof X',
      windowOpen: open,
      ts: now,
      org: 'univ.edu',
    ),
    firstSeen: now,
    lastSeen: now,
  );
}

/// Host harness (delegates to the canonical widget_test.testScope): Mark
/// host pumped directly — the shell owns unenrolled routing, so the join
/// gate and verdict-back contracts pump StudentHomeScreen itself. Thin
/// wrapper kept so the host call sites keep reading as `_markScope(...)`.
ProviderScope _markScope({
  StudentDriver? studentDriver,
  bool probeOpen = false,
}) =>
    helpers.testScope(
      linked: const LinkedIdentity(
          name: 'Test User', gmail: 'student@example.com', roll: '12342210'),
      studentDriver: studentDriver,
      probeOpen: probeOpen,
      home: MaterialApp(
          theme: proxLightTheme(), home: const StudentHomeScreen()),
    );

/// Late verdict driver: face passes, the proof lands late.
class _LateStudentDriver extends FakeStudentDriver {
  _LateStudentDriver() : super(windowOpenProbe: true);

  @override
  Future<MarkedReceipt> listenAndProve({
    required ClassBeacon target,
    required LinkedIdentity identity,
    required double faceScore,
    required void Function(ListenStatus s) onStatus,
    int faceValidAtMs = 0,
    String verifierVer = '',
  }) async {
    onStatus(ListenStatus.confirming);
    return const MarkedReceipt(
        detail: 'Late · KQ7 · 10:04:12', result: StudentResult.late);
  }
}

void main() {
  group('browse slim-down: no records / enroll sections', () {
    testWidgets('empty browse keeps list chrome, drops records+enroll',
        (t) async {
      await t.pumpWidget(_browse());
      await t.pumpAndSettle();
      // Kept: empty state, section header, fallback-weight IP entry,
      // foreground note, top-left avatar (initials, no text block).
      expect(find.text('Looking for a class…'), findsOneWidget);
      expect(find.text('Live on this WiFi'), findsOneWidget);
      expect(find.text('Enter IP manually'), findsOneWidget);
      expect(find.textContaining('foreground'), findsOneWidget);
      expect(find.text('TU'), findsOneWidget);
      expect(
          find.byKey(const ValueKey('browse-avatar-ring')), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      // Removed: records entry, enroll entry (both linked states gone —
      // the gate routes unenrolled users, Courses owns records).
      expect(find.text('My attendance records (synced)'), findsNothing);
      expect(find.text('Enroll this device (face + ID)'), findsNothing);
      expect(find.textContaining('Records view only here'), findsNothing);
    });

    testWidgets('populated browse lists tiles + keeps banners, no extras',
        (t) async {
      var tapped = false;
      await t.pumpWidget(_themed(
        BrowseClassesView(
          avatarName: 'S',
          ipInitial: '',
          onIpChanged: (_) {},
          onJoin: () {},
          joinError: 'Enter the professor IP shown in class.',
          live: [_live()],
          onTapLive: (_) => tapped = true,
          onRefresh: () async {},
          broadcastBlocked: true,
        ),
      ));
      await t.pumpAndSettle();
      // Kept: live tile, join-error banner, broadcast-blocked banner.
      expect(find.textContaining('Prof X'), findsOneWidget);
      expect(find.text('Enter the professor IP shown in class.'),
          findsOneWidget);
      expect(
          find.textContaining('blocks discovery broadcasts'), findsOneWidget);
      await t.tap(find.textContaining('Prof X'));
      expect(tapped, isTrue);
      // Removed, even with content on screen.
      expect(find.text('My attendance records (synced)'), findsNothing);
      expect(find.text('Enroll this device (face + ID)'), findsNothing);
    });
  });

  group('verdict back action exists on every verdict', () {
    Future<void> pumpVerdict(
        WidgetTester t, MarkVerdict kind, int attemptsLeft) async {
      await t.pumpWidget(_themed(
        MarkVerdictView(
          kind: kind,
          detail: 'KQ7 · 10:04:12',
          roundMarks: const ['R1 · KQ7 · 10:04:12'],
          attemptsLeft: attemptsLeft,
          onRetryFace: () {},
          onManualInstead: () {},
          onBack: () {},
        ),
      ));
      await t.pumpAndSettle();
    }

    testWidgets('marked exposes Back to classes', (t) async {
      var backed = false;
      await t.pumpWidget(_themed(
        MarkVerdictView(
          kind: MarkVerdict.marked,
          detail: 'KQ7 · 10:04:12',
          roundMarks: const ['R1 · KQ7 · 10:04:12'],
          onRetryFace: () {},
          onManualInstead: () {},
          onBack: () => backed = true,
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('✓ Marked'), findsOneWidget);
      await t.tap(find.text('Back to classes'));
      await t.pumpAndSettle();
      expect(backed, isTrue);
    });

    testWidgets('late exposes Back to classes', (t) async {
      var backed = false;
      await t.pumpWidget(_themed(
        MarkVerdictView(
          kind: MarkVerdict.late,
          detail: 'Late · KQ7 · 10:04:12',
          roundMarks: const ['R1 · KQ7 · 10:04:12'],
          onRetryFace: () {},
          onManualInstead: () {},
          onBack: () => backed = true,
        ),
      ));
      await t.pumpAndSettle();
      await t.tap(find.text('Back to classes'));
      await t.pumpAndSettle();
      expect(backed, isTrue);
    });

    testWidgets('wrong-org / needs-review / no-signal keep their backs',
        (t) async {
      await pumpVerdict(t, MarkVerdict.wrongOrg, 4);
      expect(find.text('Back to classes'), findsOneWidget);
      await pumpVerdict(t, MarkVerdict.needsReview, 3);
      expect(find.text('Back'), findsOneWidget);
      expect(find.textContaining('Retry face scan (3 left)'), findsOneWidget);
      await pumpVerdict(t, MarkVerdict.needsReview, 0);
      expect(find.text('Back'), findsOneWidget);
      await pumpVerdict(t, MarkVerdict.noSignal, 0);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  group('verdict back lands on browsing (host)', () {
    testWidgets('marked back lands on browse and stays (no re-face)',
        (t) async {
      await t.pumpWidget(_markScope(probeOpen: true));
      await t.pumpAndSettle();
      await helpers.enterIp(t, '192.168.43.1');
      await t.tap(find.text('Join'));
      var marked = false;
      for (var i = 0; i < 20 && !marked; i++) {
        await t.pump(const Duration(seconds: 1));
        marked = find.text('✓ Marked').evaluate().isNotEmpty;
      }
      expect(marked, isTrue);
      await t.pumpAndSettle();
      await t.tap(find.text('Back to classes'));
      await t.pumpAndSettle();
      expect(find.text('✓ Marked'), findsNothing);
      expect(find.text('Enter IP manually'), findsOneWidget);
      // The rewait chain is dead (run-guarded teardown): no silent hop
      // back into waiting/face/proving behind the browse list.
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(seconds: 1));
      }
      expect(find.textContaining('has not yet started'), findsNothing);
      expect(find.text('Enter IP manually'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('late back lands on browse and stays', (t) async {
      await t.pumpWidget(_markScope(studentDriver: _LateStudentDriver()));
      await t.pumpAndSettle();
      await helpers.enterIp(t, '192.168.43.1');
      await t.tap(find.text('Join'));
      var late = false;
      for (var i = 0; i < 20 && !late; i++) {
        await t.pump(const Duration(seconds: 1));
        late = find.text('Late').evaluate().isNotEmpty;
      }
      expect(late, isTrue);
      await t.pumpAndSettle();
      await t.tap(find.text('Back to classes'));
      await t.pumpAndSettle();
      expect(find.text('Enter IP manually'), findsOneWidget);
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(seconds: 1));
      }
      expect(find.textContaining('has not yet started'), findsNothing);
      expect(find.text('Enter IP manually'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('manual-rejected back lands on browse', (t) async {
      await t.pumpWidget(_markScope(
          studentDriver: FakeStudentDriver(manualStatus: 'rejected')));
      await t.pumpAndSettle();
      await helpers.enterIp(t, '192.168.43.1');
      await t.tap(find.text('Join'));
      await t.pumpAndSettle();
      expect(find.textContaining('has not yet started'), findsOneWidget);
      await t.tap(find.text('Request manual attendance'));
      await t.pumpAndSettle();
      var decided = false;
      for (var i = 0; i < 10 && !decided; i++) {
        await t.pump(const Duration(seconds: 1));
        decided = find.textContaining('declined').evaluate().isNotEmpty;
      }
      expect(decided, isTrue);
      await t.tap(find.text('Back'));
      await t.pumpAndSettle();
      expect(find.text('Enter IP manually'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('system back from marked lands on browse in one step',
        (t) async {
      await t.pumpWidget(_markScope(probeOpen: true));
      await t.pumpAndSettle();
      await helpers.enterIp(t, '192.168.43.1');
      await t.tap(find.text('Join'));
      var marked = false;
      for (var i = 0; i < 20 && !marked; i++) {
        await t.pump(const Duration(seconds: 1));
        marked = find.text('✓ Marked').evaluate().isNotEmpty;
      }
      expect(marked, isTrue);
      await t.pumpAndSettle();
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      // One step to browse — never waiting/face/proving on the way.
      expect(find.text('✓ Marked'), findsNothing);
      expect(find.textContaining('has not yet started'), findsNothing);
      expect(find.text('Enter IP manually'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('verdict_section composition', () {
    test('builds each terminal verdict kind', () {
      Widget build(StudentPhase phase) => _themed(markVerdictSection(
            phase: phase,
            ackDetail: 'KQ7 · 10:04:12',
            infoDetail: '',
            wrongClassOrg: 'a.edu',
            wrongMyOrg: 'b.edu',
            roundMarks: const ['R1 · KQ7 · 10:04:12'],
            attemptsLeft: 3,
            onBackToBrowsing: () {},
            onRequestManual: () {},
            onRetryFace: () {},
          ));
      expect(build(StudentPhase.marked), isA<MaterialApp>());
      expect(
          (build(StudentPhase.marked) as MaterialApp).home, isA<Scaffold>());
    });

    test('rejects non-verdict phases', () {
      expect(
        () => markVerdictSection(
          phase: StudentPhase.browsing,
          ackDetail: '',
          infoDetail: '',
          wrongClassOrg: '',
          wrongMyOrg: '',
          roundMarks: const [],
          attemptsLeft: 0,
          onBackToBrowsing: () {},
          onRequestManual: () {},
          onRetryFace: () {},
        ),
        throwsArgumentError,
      );
    });
  });
}
