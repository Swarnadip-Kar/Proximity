// Identity surfacing on cards (presentation only; email fetched, never
// broadcast).
//
// Student cards show professor identity: the live tile carries the
// announcement's prof name + org plus the GATED prof Gmail (org-checked
// /window unicast only — never beacons/BLE), the waiting room shows the
// gated prof + Gmail + org, and history tiles carry the synced record's
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
import 'package:proximity_app/features/live/live_roster.dart';
import 'package:proximity_app/features/live/manual_inbox.dart';
import 'package:proximity_app/features/mark/browse_classes.dart';
import 'package:proximity_app/features/mark/waiting_room.dart';
import 'package:proximity_app/widgets/course_attendance.dart';
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
        identityLine: 'S',
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
  testWidgets('browse tile shows prof name, host, code and org', (t) async {
    await t.pumpWidget(_browse([_live()]));
    await t.pumpAndSettle();
    expect(
      find.text('Prof X · 10.0.0.5 · Code KQ7 · univ.edu'),
      findsOneWidget,
    );
  });

  testWidgets('browse tile with legacy announcement shows no org',
      (t) async {
    await t.pumpWidget(_browse([_live(prof: '', display: '', org: '')]));
    await t.pumpAndSettle();
    expect(find.text('10.0.0.5'), findsOneWidget);
    expect(find.textContaining('univ.edu'), findsNothing);
  });

  testWidgets('browse tile shows the gated prof Gmail when present',
      (t) async {
    await t.pumpWidget(_browse([_live()],
        profEmailByHost: const {'10.0.0.5:8443': 'prof.x@univ.edu'}));
    await t.pumpAndSettle();
    expect(
      find.text('Prof X · prof.x@univ.edu · 10.0.0.5 · Code KQ7 · univ.edu'),
      findsOneWidget,
    );
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
    expect(find.text('Hosted by Prof X · univ.edu'), findsOneWidget);
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

  testWidgets('waiting room shows gated prof + Gmail + org', (t) async {
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
    expect(find.text('Hosted by Prof X · prof.x@univ.edu · univ.edu'),
        findsOneWidget);
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
    expect(find.text('Hosted by Prof X · univ.edu'), findsOneWidget);
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

  testWidgets('history tile with legacy record shows no org', (t) async {
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
}
