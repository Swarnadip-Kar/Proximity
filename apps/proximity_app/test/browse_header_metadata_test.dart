// Browse header metadata (PROF-NAME slice: browse header only).
//
// Contract: the browse top keeps the top-left avatar EXACTLY as-is
// (photo → initials, glowing ring, nothing when unknown) AND restores the
// previous metadata text BESIDE it — identity lines (linked name · roll /
// gmail, or the not-enrolled guidance) plus the existing ClockHeader
// date/time, reusing the exact previous strings/components. No new copy.
// The text sits right of the avatar, ellipsized.
//
// Avatar ring geometry untouched; waiting-card fallback/dedupe/shrink
// contracts untouched (pinned in waiting_prof_name_mobile_test +
// identity_surface_test).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/mark/browse_classes.dart';
import 'package:proximity_app/widgets/clock.dart';

Widget _themed(Widget body) => MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(body: body),
    );

Widget _browse({
  String avatarName = '',
  String avatarPhotoUrl = '',
  String identityLine = '',
}) =>
    _themed(
      BrowseClassesView(
        avatarName: avatarName,
        avatarPhotoUrl: avatarPhotoUrl,
        identityLine: identityLine,
        ipInitial: '',
        onIpChanged: (_) {},
        onJoin: () {},
        joinError: '',
        live: const [],
        onTapLive: (_) {},
        onRefresh: () async {},
      ),
    );

void main() {
  testWidgets('browse header shows avatar + identity + clock together',
      (t) async {
    const identity = 'Test User · 12342210\nstudent@example.com';
    await t.pumpWidget(_browse(
      avatarName: 'Test User',
      identityLine: identity,
    ));
    await t.pumpAndSettle();
    // Avatar unchanged: initials + glowing ring.
    expect(find.text('TU'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('browse-avatar-ring')), findsOneWidget);
    // Restored metadata beside it: exact previous identity string.
    expect(find.text(identity), findsOneWidget);
    // Existing clock component still renders.
    expect(find.byType(ClockHeader), findsOneWidget);
    // Avatar and identity share one Row (text sits right of the avatar).
    final row = find.ancestor(
      of: find.text(identity),
      matching: find.byType(Row),
    );
    expect(row, findsWidgets);
    var sharesRow = false;
    for (final r in row.evaluate()) {
      final subtree = find.descendant(
        of: find.byWidget(r.widget),
        matching: find.byKey(const ValueKey('browse-avatar-ring')),
      );
      if (subtree.evaluate().isNotEmpty) {
        sharesRow = true;
        break;
      }
    }
    expect(sharesRow, isTrue);
    expect(t.takeException(), isNull);
  });

  testWidgets('browse header unenrolled keeps guidance + clock, no avatar',
      (t) async {
    const identity = 'Not enrolled — enroll this device to link identity.';
    await t.pumpWidget(_browse(identityLine: identity));
    await t.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('browse-avatar-ring')), findsNothing);
    expect(find.text(identity), findsOneWidget);
    expect(find.byType(ClockHeader), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('browse header empty identity still shows avatar + clock',
      (t) async {
    await t.pumpWidget(_browse(avatarName: 'Ada Lovelace'));
    await t.pumpAndSettle();
    expect(find.text('AL'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('browse-avatar-ring')), findsOneWidget);
    expect(find.byType(ClockHeader), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
