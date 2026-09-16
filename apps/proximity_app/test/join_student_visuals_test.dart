// Join-page visuals (UI/UX slice): connection pill on the waiting room +
// joining-as avatar top-left on the browse list.
//
// The waiting room carries no student identity block (removed) — the
// avatar lives on the browse list top-left instead (photo → initials,
// gradient ring WITHOUT glow, static and settle-safe).
//
// Settle-safe by construction: empty-URL initials paths only (no
// network-image widget tests), no timers/implicit-animation loops — every
// case pumps with `pumpAndSettle`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/mark/browse_classes.dart';
import 'package:proximity_app/features/mark/waiting_room.dart';
import 'package:proximity_app/widgets/student_card.dart';
import 'package:proximity_app/widgets/verdict_badge.dart';

Widget _themed(Widget body) => MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(body: body),
    );

Widget _room({bool connected = true}) => _themed(
      WaitingRoomView(
        connected: connected,
        roomClass: 'CS201',
        roundMarks: const [],
        onRequestManual: () {},
        onCancel: () {},
      ),
    );

Widget _browse({String avatarName = '', String avatarPhotoUrl = ''}) =>
    _themed(
      BrowseClassesView(
        avatarName: avatarName,
        avatarPhotoUrl: avatarPhotoUrl,
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
  testWidgets('connected pill uses brand, not the Marked verdict idiom',
      (t) async {
    await t.pumpWidget(_room(connected: true));
    await t.pumpAndSettle();
    // Copy unchanged — the verbatim join words still render.
    expect(find.text('Connected'), findsOneWidget);
    // Transport state, not attendance: no verdict badge anywhere here.
    expect(find.byType(VerdictBadge), findsNothing);
    // No student identity block on the waiting room anymore.
    expect(find.byKey(const ValueKey('browse-avatar-ring')), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('not-connected pill keeps the neutral treatment', (t) async {
    await t.pumpWidget(_room(connected: false));
    await t.pumpAndSettle();
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.byType(VerdictBadge), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('browse top-left shows initials + gradient ring, no glow',
      (t) async {
    await t.pumpWidget(_browse(avatarName: 'Ada Lovelace'));
    await t.pumpAndSettle();
    // Initials fallback (shared helper): never blank, never a spinner,
    // never a network image on the empty URL — and no identity text.
    expect(find.text('AL'), findsOneWidget);
    expect(find.text('Ada Lovelace'), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // Shared ProxAvatar behind the alias: gradient ring, never glow.
    expect(
        find.byKey(const ValueKey('browse-avatar-ring')), findsOneWidget);
    expect(find.byType(ProxAvatar), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('browse unknown identity renders no avatar at all',
      (t) async {
    await t.pumpWidget(_browse());
    await t.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('browse-avatar-ring')), findsNothing);
    // No blank disc, no spinner, no image.
    expect(find.byType(Image), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('browse avatar empty-photo contract holds standalone',
      (t) async {
    await t.pumpWidget(_browse(
      avatarName: 'Alan Turing',
      avatarPhotoUrl: '   ',
    ));
    await t.pumpAndSettle();
    // Whitespace-only URL trims to empty → initials disc.
    expect(find.text('AT'), findsOneWidget);
    expect(find.text('Alan Turing'), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
        find.byKey(const ValueKey('browse-avatar-ring')), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
