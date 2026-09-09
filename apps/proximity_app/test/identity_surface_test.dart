// Identity surfacing on cards (presentation only, nothing fetched).
//
// Student cards show already-available professor identity: the live tile
// carries the announcement's prof name + org, the waiting room shows the
// tapped announcement's prof + org, and history tiles carry the synced
// record's org. Professor rows already carried the student email via
// rosterSubtitle — locked here so a copy tweak can never drop it silently.
//
// Privacy: the professor EMAIL is in no student-side payload (beacon,
// /window, ClassRecord all carry name/org only), so no card here renders
// one — asserting its absence is part of the contract.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/features/live/live_roster.dart';
import 'package:proximity_app/features/live/manual_inbox.dart';
import 'package:proximity_app/features/mark/browse_classes.dart';
import 'package:proximity_app/features/mark/waiting_room.dart';
import 'package:proximity_app/widgets/course_attendance.dart';
import 'package:proximity_app/widgets/partial_list.dart';
import 'package:proximity_storage/storage.dart';
import 'package:proximity_transport/transport.dart';

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

Widget _browse(List<LiveClass> live) => MaterialApp(
      home: Scaffold(
        body: BrowseClassesView(
          linked: null,
          identityLine: 'S',
          ipFieldKey: UniqueKey(),
          ipInitial: '',
          onIpChanged: (_) {},
          onJoin: () {},
          joinError: '',
          live: live,
          onTapLive: (_) {},
          onEnroll: () {},
          onViewRecords: () {},
          onRefresh: () async {},
        ),
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

  testWidgets('waiting room shows tapped announcement prof + org',
      (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WaitingRoomView(
          connected: true,
          roomClass: 'CS201',
          roomProf: 'Prof X',
          roomOrg: 'univ.edu',
          roundMarks: const [],
          onRequestManual: () {},
          onCancel: () {},
        ),
      ),
    ));
    expect(find.text('Hosted by Prof X · univ.edu'), findsOneWidget);
  });

  testWidgets('waiting room typed-IP join shows no host line', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WaitingRoomView(
          connected: true,
          roomClass: 'CS201',
          roundMarks: const [],
          onRequestManual: () {},
          onCancel: () {},
        ),
      ),
    ));
    expect(find.textContaining('Hosted by'), findsNothing);
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
    await t.pumpWidget(MaterialApp(
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
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: WaitingListSection(waitingRows: [
          WaitingRow(email: 's@univ.edu', name: 'S', roll: '1'),
        ]),
      ),
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
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: MarkedRosterSection(tally: tally)),
    ));
    await t.pumpAndSettle();
    expect(find.textContaining('a@univ.edu'), findsOneWidget);
    expect(find.textContaining('b@univ.edu'), findsOneWidget);
  });

  testWidgets('professor manual inbox shows student email', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ManualInboxSection(
          pending: const [
            ManualRow(email: 's@univ.edu', name: 'S', roll: '1'),
          ],
          onApproveOne: (_) async {},
          onRejectOne: (_) async {},
          onDecide: (_, __) async {},
        ),
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
