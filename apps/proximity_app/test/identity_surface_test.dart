// Identity surfacing on cards (presentation only; email fetched, never
// broadcast).
//
// Student cards show professor identity: the live tile carries the
// announcement's prof name + org plus the GATED prof Gmail (org-checked
// /window unicast only — never beacons/BLE), the waiting room shows the
// display name + org only (raw Gmail never rendered — presentation
// privacy), and history tiles carry the synced record's
// org. Professor rows already carried the student email via
// rosterSubtitle — locked here so a copy tweak can never drop it silently.
//
// Privacy (gated model): beacons/BLE carry NO Gmail by construction
// (ClassAnnouncement has no such field); live cards render the Gmail only
// when the gated unicast supplied it. Legacy/unknown renders exactly as
// before — asserting both shapes is part of the contract.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/design/tokens.dart' show ProxStatus;
import 'package:proximity_app/features/live/live_roster.dart';
import 'package:proximity_app/features/live/manual_inbox.dart';
import 'package:proximity_app/features/mark/browse_classes.dart';
import 'package:proximity_app/features/mark/browse_list.dart';
import 'package:proximity_app/features/mark/waiting_room.dart';
import 'package:proximity_app/widgets/course_attendance.dart';
import 'package:proximity_app/widgets/host_preview_card.dart';
import 'package:proximity_app/widgets/student_card.dart'
    show StudentCard, courseInitials;
import 'package:proximity_app/widgets/verdict_badge.dart' show VerdictBadge;
import 'package:proximity_app/widgets/partial_list.dart';
import 'package:proximity_storage/storage.dart';
import 'package:proximity_transport/transport.dart';

// Rebuilt mark views read the `ProximityColors` extension.
Widget _themed(Widget body) => MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(body: body),
    );

LiveClass _live({
  String label = 'CS201',
  String host = '10.0.0.5',
  int port = 8443,
  String display = 'KQ7',
  String prof = 'Prof X',
  bool open = false,
  String org = 'univ.edu',
}) {
  final now = DateTime.now().toUtc();
  return LiveClass(
    last: ClassAnnouncement(
      classLabel: label,
      host: host,
      port: port,
      display: display,
      prof: prof,
      windowOpen: open,
      ts: now,
      org: org,
    ),
    firstSeen: now,
    lastSeen: now,
  );
}

Widget _browse(List<LiveClass> live,
        {Map<String, String> profEmailByHost = const {}}) =>
    _themed(
      BrowseClassesView(
        avatarName: 'S',
        ipInitial: '',
        onIpChanged: (_) {},
        onJoin: () {},
        joinError: '',
        live: live,
        profEmailByHost: profEmailByHost,
        onTapLive: (_) {},
        onRefresh: () async {},
      ),
    );

void main() {
  testWidgets('browse tile shows prof name and code (no IP, no org)',
      (t) async {
    await t.pumpWidget(_browse([_live()]));
    await t.pumpAndSettle();
    expect(
      find.text('Prof X · Code KQ7'),
      findsOneWidget,
    );
    expect(find.textContaining('10.0.0.5'), findsNothing);
    expect(find.textContaining('univ.edu'), findsNothing);
  });

  testWidgets('browse tile with unstamped announcement shows no org',
      (t) async {
    await t.pumpWidget(_browse([_live(prof: '', display: '', org: '')]));
    await t.pumpAndSettle();
    expect(find.textContaining('10.0.0.5'), findsNothing);
    expect(find.textContaining('univ.edu'), findsNothing);
  });

  testWidgets('browse tile shows the gated prof Gmail when present',
      (t) async {
    await t.pumpWidget(_browse([_live()],
        profEmailByHost: const {'10.0.0.5:8443': 'prof.x@univ.edu'}));
    await t.pumpAndSettle();
    expect(
      find.text('Prof X · Code KQ7'),
      findsOneWidget,
    );
    expect(find.text('prof.x@univ.edu'), findsOneWidget);
  });

  testWidgets('waiting room shows tapped announcement prof + org',
      (t) async {
    await t.pumpWidget(_themed(
      WaitingRoomView(
          connected: true,
          roomClass: 'CS201',
          roomProf: 'Prof X',
          roomOrg: 'univ.edu',
          roundMarks: const [],
          onRequestManual: () {},
          onCancel: () {},
        ),
      ));
    // Shared host card: bare name title + org line (no prefix).
    expect(find.text('Prof X'), findsOneWidget);
    expect(find.textContaining('Hosted by'), findsNothing);
    expect(find.text('univ.edu'), findsOneWidget);
  });

  testWidgets('waiting room typed-IP join shows no host line', (t) async {
    await t.pumpWidget(_themed(
      WaitingRoomView(
          connected: true,
          roomClass: 'CS201',
          roundMarks: const [],
          onRequestManual: () {},
          onCancel: () {},
        ),
      ));
    expect(find.textContaining('Hosted by'), findsNothing);
  });

  testWidgets('waiting room shows display name + email + org, deduped',
      (t) async {
    await t.pumpWidget(_themed(
      WaitingRoomView(
          connected: true,
          roomClass: 'CS201',
          roomProf: 'Prof X',
          roomProfEmail: 'prof.x@univ.edu',
          roomOrg: 'univ.edu',
          roundMarks: const [],
          onRequestManual: () {},
          onCancel: () {},
        ),
      ));
    expect(find.text('Prof X'), findsOneWidget);
    expect(find.textContaining('Hosted by'), findsNothing);
    // Name + email + org on separate lines, address rendered exactly once.
    expect(find.text('prof.x@univ.edu'), findsOneWidget);
    expect(find.text('univ.edu'), findsOneWidget);
    expect(find.textContaining('prof.x@univ.edu'), findsOneWidget);
  });

  testWidgets('waiting room unnamed host falls back to the email',
      (t) async {
    await t.pumpWidget(_themed(
      WaitingRoomView(
          connected: true,
          roomClass: 'CS201',
          roomProfEmail: 'prof.x@univ.edu',
          roomOrg: 'univ.edu',
          roundMarks: const [],
          onRequestManual: () {},
          onCancel: () {},
        ),
      ));
    // No display name: the title honestly falls back to the email (never
    // a bare org domain), the org-only second line leaves no dangling
    // separator, and the address renders exactly once.
    expect(find.text('Your professor'), findsNothing);
    expect(find.text('prof.x@univ.edu'), findsOneWidget);
    expect(find.text('univ.edu'), findsOneWidget);
    expect(find.textContaining('prof.x@univ.edu'), findsOneWidget);
  });

  testWidgets('waiting room email-only host shows the email title',
      (t) async {
    // Typed-IP join where only the gated fetch landed (no name/org):
    // the title falls back to the email, no second line at all.
    await t.pumpWidget(_themed(
      WaitingRoomView(
          connected: true,
          roomClass: 'CS201',
          roomProfEmail: 'prof.x@univ.edu',
          roundMarks: const [],
          onRequestManual: () {},
          onCancel: () {},
        ),
      ));
    expect(find.text('Your professor'), findsNothing);
    expect(find.text('prof.x@univ.edu'), findsOneWidget);
    expect(find.textContaining('·'), findsNothing);
  });

  testWidgets('waiting room named host without org shows the email line',
      (t) async {
    await t.pumpWidget(_themed(
      WaitingRoomView(
          connected: true,
          roomClass: 'CS201',
          roomProf: 'Prof X',
          roomProfEmail: 'prof.x@univ.edu',
          roundMarks: const [],
          onRequestManual: () {},
          onCancel: () {},
        ),
      ));
    // Named host without org: title + email line, address rendered once.
    expect(find.text('Prof X'), findsOneWidget);
    expect(find.text('prof.x@univ.edu'), findsOneWidget);
    expect(find.textContaining('·'), findsNothing);
  });

  testWidgets('waiting room typed-IP join renders no host card at all',
      (t) async {
    await t.pumpWidget(_themed(
      WaitingRoomView(
          connected: true,
          roomClass: 'CS201',
          roundMarks: const [],
          onRequestManual: () {},
          onCancel: () {},
        ),
      ));
    expect(find.byType(HostPreviewCard), findsNothing);
    expect(find.text('Your professor'), findsNothing);
    expect(find.textContaining('Hosted by'), findsNothing);
    expect(find.textContaining('@'), findsNothing);
  });

  testWidgets('waiting room without the Gmail renders no dangling separator',
      (t) async {
    await t.pumpWidget(_themed(
      WaitingRoomView(
          connected: true,
          roomClass: 'CS201',
          roomProf: 'Prof X',
          roomOrg: 'univ.edu',
          roundMarks: const [],
          onRequestManual: () {},
          onCancel: () {},
        ),
      ));
    expect(find.text('Prof X'), findsOneWidget);
    expect(find.textContaining('Hosted by'), findsNothing);
    expect(find.text('univ.edu'), findsOneWidget);
    expect(find.textContaining('@'), findsNothing);
  });

  testWidgets('history tile shows stamped record org', (t) async {
    final session = ClassRecord(
      id: 's1',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-06',
      timestampIso: '2026-09-06T10:00:00.000Z',
      windows: const [
        {'s@univ.edu': true}
      ],
      names: const {'s@univ.edu': 'S'},
      rolls: const {'s@univ.edu': '1'},
      org: 'univ.edu',
    );
    // Themed harness (date-visibility rebuild): the tile now reads
    // `ProximityColors` like every other rebuilt widget (LIVE-D3 pattern).
    await t.pumpWidget(MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(
        body: StudentSessionTile(
            session: session, email: 's@univ.edu', course: 'CS201'),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.textContaining('univ.edu'), findsOneWidget);
  });

  testWidgets('history tile with unstamped record shows no org', (t) async {
    final session = ClassRecord(
      classLabel: 'CS201',
      dateIso: '2026-09-06',
      windows: const [
        {'s@univ.edu': true}
      ],
    );
    await t.pumpWidget(MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(
        body: StudentSessionTile(
            session: session, email: 's@univ.edu', course: 'CS201'),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.textContaining('univ.edu'), findsNothing);
    expect(find.textContaining('Present'), findsOneWidget);
  });

  testWidgets('professor waiting row shows student email', (t) async {
    await t.pumpWidget(_themed(
      const WaitingListSection(waitingRows: [
        WaitingRow(email: 's@univ.edu', name: 'S', roll: '1'),
      ]),
    ));
    await t.pumpAndSettle();
    expect(find.text('1 · s@univ.edu'), findsOneWidget);
  });

  testWidgets('professor present + partial rows show student email',
      (t) async {
    final tally = TallyStore();
    tally.noteWindow(1);
    tally.noteWindow(2);
    tally.mark('a@univ.edu', 'A', 1, roll: '1');
    tally.mark('a@univ.edu', 'A', 2, roll: '1');
    tally.mark('b@univ.edu', 'B', 1, roll: '2');
    await t.pumpWidget(_themed(
      MarkedRosterSection(tally: tally),
    ));
    await t.pumpAndSettle();
    expect(find.textContaining('a@univ.edu'), findsOneWidget);
    expect(find.textContaining('b@univ.edu'), findsOneWidget);
  });

  testWidgets('professor manual inbox shows student email', (t) async {
    await t.pumpWidget(_themed(
      ManualInboxSection(
        pending: const [
          ManualRow(email: 's@univ.edu', name: 'S', roll: '1'),
        ],
        onApproveOne: (_) async {},
        onRejectOne: (_) async {},
        onDecide: (_, __) async {},
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text('1 · s@univ.edu'), findsOneWidget);
  });

  test('rosterSubtitle always carries the email', () {
    expect(rosterSubtitle('1', 's@univ.edu'), '1 · s@univ.edu');
    expect(rosterSubtitle('', 's@univ.edu'), 's@univ.edu');
  });

  testWidgets('host card shows the name with no Hosted-by prefix',
      (t) async {
    await t.pumpWidget(_themed(const HostPreviewCard(
      displayName: 'Prof X',
      email: 'prof@univ.edu',
      org: 'univ.edu',
    )));
    await t.pumpAndSettle();
    expect(find.text('Prof X'), findsOneWidget);
    expect(find.textContaining('Hosted by'), findsNothing);
    // Name + email + org on separate lines; the address renders exactly once.
    expect(find.text('prof@univ.edu'), findsOneWidget);
    expect(find.text('univ.edu'), findsOneWidget);
    expect(find.textContaining('prof@univ.edu'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('host card falls back to the email, deduped',
      (t) async {
    await t.pumpWidget(_themed(const HostPreviewCard(
      displayName: '',
      email: 'prof@univ.edu',
      org: 'univ.edu',
    )));
    await t.pumpAndSettle();
    // No display name: the title honestly falls back to the email (never
    // a bare org domain); the second line carries the org only, so the
    // address renders exactly once. Initial follows the title.
    expect(find.text('Your professor'), findsNothing);
    expect(find.text('prof@univ.edu'), findsOneWidget);
    expect(find.text('univ.edu'), findsOneWidget);
    expect(find.text('P'), findsOneWidget);
    expect(find.textContaining('prof@univ.edu'), findsOneWidget);
    expect(find.textContaining('Hosted by'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('host card with no name and no org shows the email title',
      (t) async {
    await t.pumpWidget(_themed(const HostPreviewCard(
      displayName: '',
      email: 'prof@univ.edu',
      org: '',
    )));
    await t.pumpAndSettle();
    // No name/org: the title falls back to the email, no second line.
    expect(find.text('Your professor'), findsNothing);
    expect(find.text('prof@univ.edu'), findsOneWidget);
    expect(find.textContaining('·'), findsNothing);
    expect(find.textContaining('Hosted by'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('host card with no identity at all renders nothing',
      (t) async {
    await t.pumpWidget(_themed(const HostPreviewCard(
      displayName: '',
      email: '',
      org: '',
    )));
    await t.pumpAndSettle();
    // Nothing known → SizedBox.shrink: no blank card, no separators.
    expect(find.text('Your professor'), findsNothing);
    expect(find.textContaining('@'), findsNothing);
    expect(find.textContaining('·'), findsNothing);
    expect(find.textContaining('Hosted by'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('host card falls back to a letter initial without a photo',
      (t) async {
    await t.pumpWidget(_themed(const HostPreviewCard(
      displayName: 'Prof X',
      email: 'prof@univ.edu',
    )));
    await t.pumpAndSettle();
    // No photo and no network image: the avatar disc shows the letter.
    expect(find.text('P'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(t.takeException(), isNull);
  });

  group('browse + course avatar consistency (photo iff gated, else letters)',
      () {
    test('signalBarsFor: open→3, recent→2, stale hint→1', () {
      final now = DateTime.now().toUtc();
      expect(
          signalBarsFor(
              windowOpen: true,
              lastSeen: now.subtract(const Duration(minutes: 5)),
              now: now),
          3);
      expect(
          signalBarsFor(windowOpen: false, lastSeen: now, now: now), 2);
      expect(
          signalBarsFor(
              windowOpen: false,
              lastSeen: now.subtract(const Duration(seconds: 30)),
              now: now),
          1);
    });

    test('browseRingFor: ring mirrors the idle indicator (open only)', () {
      expect(browseRingFor(windowOpen: true), isTrue);
      // Recently heard but idle (2 bars): flat — recency is not openness.
      expect(browseRingFor(windowOpen: false), isFalse);
    });

    test('gatedPhotoFor trims, blanks on unknown/opted-out', () {
      expect(gatedPhotoFor({'h:1': '  https://x/p.jpg '}, 'h:1'),
          'https://x/p.jpg');
      expect(gatedPhotoFor(const {}, 'h:1'), isEmpty);
      expect(gatedPhotoFor({'h:1': '   '}, 'h:1'), isEmpty);
    });

    test('course letter fallback for the My Courses discs', () {
      // `courseInitials` is the shared helper behind `CourseLogo` (the
      // My Courses ring-center fallback): first 2 alphanumerics, upper.
      // One helper everywhere — csl201 reads CS on every surface.
      expect(courseInitials('CS201'), 'CS');
      expect(courseInitials('csl201'), 'CS');
      expect(courseInitials('Quantum Computing'), 'QU');
      expect(courseInitials(''), '?');
      expect(courseInitials('  '), '?');
      // Course-titled browse cards read the course disc, not person
      // initials: `DSL506 - Intro…` → `DS` (was `D-` via the person path).
      expect(courseInitials('DSL506 - introduction to machine learning'),
          'DS');
    });

    test('browseVerifyTag: highlight pill per pin verdict, none when neutral',
        () {
      VerdictBadge tag(String label) =>
          browseVerifyTag(label) as VerdictBadge;
      expect(tag('verified').label, 'Verified');
      expect(tag('verified').status, ProxStatus.marked);
      expect(tag('verified-live').label, 'Verified');
      expect(tag('unverified').label, 'Unverified');
      expect(tag('unverified').status, ProxStatus.review);
      expect(tag('first-seen').label, 'Unverified');
      expect(tag('mismatch').label, 'Blocked');
      expect(tag('mismatch').status, ProxStatus.wrongOrg);
      // 'known' (cached pins, unmatched yet) stays caption-only: a cached
      // pin is not a match. Unknown hosts render exactly as before.
      expect(browseVerifyTag('known'), isNull);
      expect(browseVerifyTag(''), isNull);
    });

    testWidgets('course-titled tile renders DS disc + Unverified tag',
        (t) async {
      await t.pumpWidget(_themed(BrowseTile(
        live: _live(label: 'DSL506 - introduction to machine learning'),
        profEmail: 'prof@univ.edu',
        verifyLabel: 'first-seen',
        onTap: () {},
      )));
      await t.pumpAndSettle();
      expect(find.text('DS'), findsOneWidget);
      expect(find.text('D-'), findsNothing);
      expect(find.text('Unverified'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('live round ordinal tucks under the disc', (t) async {
      await t.pumpWidget(_themed(BrowseTile(
        live: _live(label: 'CS201', open: true),
        profEmail: 'prof@univ.edu',
        classNo: 2,
        onTap: () {},
      )));
      await t.pumpAndSettle();
      expect(find.text('2nd Class'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('unknown round hides the ordinal', (t) async {
      await t.pumpWidget(_themed(BrowseTile(
        live: _live(label: 'CS201'),
        profEmail: '',
        onTap: () {},
      )));
      await t.pumpAndSettle();
      expect(find.textContaining('Class'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('list passes labels + round through to footer pills',
        (t) async {
      await t.pumpWidget(_themed(
        BrowseClassesView(
          avatarName: 'S',
          ipInitial: '',
          onIpChanged: (_) {},
          onJoin: () {},
          joinError: '',
          live: [_live(label: 'CS201', open: true)],
          profEmailByHost: const {'10.0.0.5:8443': 'prof.x@univ.edu'},
          profVerifyByHost: const {'10.0.0.5:8443': 'verified'},
          windowNoByHost: const {'10.0.0.5:8443': 3},
          onTapLive: (_) {},
          onRefresh: () async {},
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('Verified'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('3rd Class'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('idle tile renders class letters, no ring, no photo',
        (t) async {
      final now = DateTime.now().toUtc();
      final stale = LiveClass(
        last: ClassAnnouncement(
          classLabel: 'CS201',
          host: '10.0.0.5',
          port: 8443,
          display: 'KQ7',
          prof: 'Prof X',
          windowOpen: false,
          ts: now.subtract(const Duration(seconds: 30)),
          org: 'univ.edu',
        ),
        firstSeen: now.subtract(const Duration(seconds: 30)),
        lastSeen: now.subtract(const Duration(seconds: 30)),
      );
      await t.pumpWidget(_browse([stale]));
      await t.pumpAndSettle();
      // Idle: flat row, class-letter disc, no network image.
      expect(find.text('idle'), findsOneWidget);
      expect(find.byKey(const ValueKey('browse-ring')), findsNothing);
      expect(find.text('CS'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      final card =
          t.widget<StudentCard>(find.byType(StudentCard).first);
      expect(card.photoUrl ?? '', isEmpty);
      expect(t.takeException(), isNull);
    });

    testWidgets('recently heard but idle tile stays flat (no ring)',
        (t) async {
      final now = DateTime.now().toUtc();
      final heard = LiveClass(
        last: ClassAnnouncement(
          classLabel: 'CS201',
          host: '10.0.0.5',
          port: 8443,
          display: 'KQ7',
          prof: 'Prof X',
          windowOpen: false,
          ts: now,
          org: 'univ.edu',
        ),
        firstSeen: now,
        lastSeen: now,
      );
      await t.pumpWidget(_browse([heard]));
      await t.pumpAndSettle();
      // Idle indicator says `idle` (2 bars, window closed): the highlight
      // must mirror it — flat row, no ring.
      expect(find.text('idle'), findsOneWidget);
      expect(find.text('Open'), findsNothing);
      expect(find.byKey(const ValueKey('browse-ring')), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('open tile rings + keeps the letters fallback on empty URL',
        (t) async {
      await t.pumpWidget(_browse([_live(open: true)],
          profEmailByHost: const {'10.0.0.5:8443': 'prof.x@univ.edu'}));
      await t.pumpAndSettle();
      // Non-idle: gradient ring on, Open badge on, avatar still the
      // class-letter disc while no gated photo was published.
      expect(find.text('Open'), findsOneWidget);
      expect(find.byKey(const ValueKey('browse-ring')), findsOneWidget);
      expect(find.text('CS'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      final card =
          t.widget<StudentCard>(find.byType(StudentCard).first);
      expect(card.photoUrl ?? '', isEmpty);
      expect(t.takeException(), isNull);
    });

    testWidgets('waiting room without a photo renders initials, no Image',
        (t) async {
      await t.pumpWidget(_themed(
        WaitingRoomView(
          connected: true,
          roomClass: 'CS201',
          roomProf: 'Prof X',
          roomProfEmail: 'prof.x@univ.edu',
          roomProfPhoto: '',
          roomOrg: 'univ.edu',
          roundMarks: const [],
          onRequestManual: () {},
          onCancel: () {},
        ),
      ));
      await t.pumpAndSettle();
      // roomProfPhoto → HostPreviewCard photoUrl path with the empty URL:
      // the letter disc, never a blank avatar, never a network image.
      expect(find.text('P'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(t.takeException(), isNull);
    });
  });

  test('tally photo converges latest-non-empty, empty never clobbers', () {
    final tally = TallyStore();
    tally.noteWindow(1);
    tally.mark('a@univ.edu', 'A', 1, roll: '1');
    expect(tally.confirmed.first.photoUrl, isEmpty);
    // Presence volunteers a photo: the roster row model carries it.
    tally.mark('a@univ.edu', 'A', 1,
        roll: '1', photoUrl: 'https://pics/x.jpg');
    expect(tally.confirmed.first.photoUrl, 'https://pics/x.jpg');
    // A later photo-less mark must not wipe the known photo.
    tally.mark('a@univ.edu', 'A', 1, roll: '1');
    expect(tally.confirmed.first.photoUrl, 'https://pics/x.jpg');
    // Latest non-empty photo wins.
    tally.mark('a@univ.edu', 'A', 1,
        roll: '1', photoUrl: 'https://pics/y.jpg');
    expect(tally.confirmed.first.photoUrl, 'https://pics/y.jpg');
  });
}
