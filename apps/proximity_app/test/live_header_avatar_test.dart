// Live header avatar (prof live header, avatar & iconography): gated Gmail
// photo iff the per-course opt-in supplied a non-empty URL, else the
// initials disc. Settle-safe only: empty-URL initials paths (no Image) +
// model-level photo gating. NO network-image widget tests here.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/live/live_session.dart';
import 'package:proximity_app/widgets/student_card.dart'
    show CourseLogo, courseInitials;

Widget _themed(Widget body) => MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(body: body),
    );

Widget _header({String photoUrl = '', String avatarName = ''}) =>
    LiveSessionHeader(
      live: false,
      elapsed: Duration.zero,
      present: 0,
      waiting: 0,
      windowsTaken: 0,
      windowNo: 0,
      hosting: true,
      hostLine: null,
      photoUrl: photoUrl,
      avatarName: avatarName,
      onStart: () {},
      onRetake: () {},
      onTakeAnother: () {},
      onStop: () {},
      onEnd: () {},
    );

void main() {
  group('liveHeaderPhotoUrl gating (model-level photo passing)', () {
    test('off shares nothing even with a URL', () {
      expect(
        liveHeaderPhotoUrl(
            sharePhoto: false, accountPhotoUrl: 'https://x/p.jpg'),
        isEmpty,
      );
    });

    test('on passes the trimmed account URL', () {
      expect(
        liveHeaderPhotoUrl(
            sharePhoto: true, accountPhotoUrl: '  https://x/p.jpg  '),
        'https://x/p.jpg',
      );
    });

    test('on with empty/null stays on initials', () {
      expect(
          liveHeaderPhotoUrl(sharePhoto: true, accountPhotoUrl: ''), isEmpty);
      expect(
          liveHeaderPhotoUrl(sharePhoto: true, accountPhotoUrl: '   '),
          isEmpty);
      expect(liveHeaderPhotoUrl(sharePhoto: true, accountPhotoUrl: null),
          isEmpty);
    });
  });

  group('liveHeaderInitial (HostPreviewCard single-letter contract)', () {
    test('first alphanum, upper', () {
      expect(liveHeaderInitial('Prof X'), 'P');
      expect(liveHeaderInitial('  alice'), 'A');
      expect(liveHeaderInitial('123'), '1');
    });

    test('skips leading symbols, ? when blank', () {
      expect(liveHeaderInitial('·test'), 'T');
      expect(liveHeaderInitial(''), '?');
      expect(liveHeaderInitial('   '), '?');
      expect(liveHeaderInitial('···'), '?');
    });
  });

  group('LiveSessionHeader empty-URL initials (no Image)', () {
    testWidgets('named prof shows its initial, no photo', (t) async {
      await t.pumpWidget(_themed(_header(avatarName: 'Prof X')));
      await t.pumpAndSettle();
      expect(find.text('P'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('unnamed prof shows ?, no photo', (t) async {
      await t.pumpWidget(_themed(_header(avatarName: '')));
      await t.pumpAndSettle();
      expect(find.text('?'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('opted-out URL-equivalent (empty) keeps date/meta intact',
        (t) async {
      await t.pumpWidget(_themed(_header(
        photoUrl: '',
        avatarName: 'Ada',
      )));
      await t.pumpAndSettle();
      expect(find.text('A'), findsOneWidget);
      expect(find.byIcon(Icons.calendar_today_outlined), findsOneWidget);
      expect(find.text('IDLE'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('course picker/tab two-letter initials (shared helper)', () {
    test('Quantum uses QU, not Q', () {
      expect(courseInitials('Quantum'), 'QU');
      expect(courseInitials('Quantum Computing'), 'QU');
      expect(courseInitials('CS201'), 'CS');
    });

    testWidgets('CourseLogo for Quantum shows QU', (t) async {
      await t.pumpWidget(_themed(const CourseLogo(course: 'Quantum')));
      await t.pumpAndSettle();
      expect(find.text('QU'), findsOneWidget);
      expect(find.text('Q'), findsNothing);
      expect(t.takeException(), isNull);
    });
  });
}
