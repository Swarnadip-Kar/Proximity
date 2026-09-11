// Join-page visuals (UI/UX slice): present-idiom status on the waiting
// room + joining-as avatar top-left on the browse list.
//
// The waiting room carries no student identity block (removed) — the
// avatar lives on the browse list top-left instead (photo → initials,
// glowing Accounts-page ring, static and settle-safe).
//
// Settle-safe by construction: empty-URL initials paths only (no
// network-image widget tests), no timers/implicit-animation loops — every
// case pumps with `pumpAndSettle`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/design/tokens.dart';
import 'package:proximity_app/features/mark/browse_classes.dart';
import 'package:proximity_app/features/mark/waiting_room.dart';
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
  testWidgets('connected badge uses the present (marked/green) idiom',
      (t) async {
    await t.pumpWidget(_room(connected: true));
    await t.pumpAndSettle();
    // Copy unchanged — the verbatim join words still render.
    expect(find.text('Connected'), findsOneWidget);
    final badge = t.widget<VerdictBadge>(find.byType(VerdictBadge).first);
    expect(badge.label, 'Connected');
    // Visual prop only: the global present status language (green).
    expect(badge.status, ProxStatus.marked);
    // No student identity block on the waiting room anymore.
    expect(find.byKey(const ValueKey('browse-avatar-ring')), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('not-connected badge keeps the waiting treatment', (t) async {
    await t.pumpWidget(_room(connected: false));
    await t.pumpAndSettle();
    expect(find.text('Not connected'), findsOneWidget);
    final badge = t.widget<VerdictBadge>(find.byType(VerdictBadge).first);
    expect(badge.label, 'Not connected');
    expect(badge.status, ProxStatus.waiting);
    expect(t.takeException(), isNull);
  });

  testWidgets('browse top-left shows initials + glowing ring on empty photo',
      (t) async {
    await t.pumpWidget(_browse(avatarName: 'Ada Lovelace'));
    await t.pumpAndSettle();
    // Initials fallback (shared helper): never blank, never a spinner,
    // never a network image on the empty URL — and no identity text.
    expect(find.text('AL'), findsOneWidget);
    expect(find.text('Ada Lovelace'), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // Glowing gradient ring: token gradient + glow shadow, static.
    final ringFinder = find.byKey(const ValueKey('browse-avatar-ring'));
    expect(ringFinder, findsOneWidget);
    final ring = t.widget<Container>(ringFinder);
    final dec = ring.decoration! as BoxDecoration;
    expect(dec.gradient, isNotNull);
    expect(dec.boxShadow, isNotNull);
    expect(dec.boxShadow, isNotEmpty);
    expect(dec.shape, BoxShape.circle);
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
