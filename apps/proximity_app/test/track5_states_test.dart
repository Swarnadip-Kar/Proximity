// Track 5 behavior-state contracts: wrong-org verdict, device trust
// tiers + anomaly, honest-unreachable copy. Presentation-only assertions
// over the shared trust cards (no drivers, no sync).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/mark/verdict_view.dart';
import 'package:proximity_app/features/mark/waiting_room.dart';
import 'package:proximity_app/widgets/trust_cards.dart';

/// Rebuilt mark views read the `ProximityColors` extension, so even these
/// presentation-only contracts pump under the app theme.
Widget _themed(Widget body) => MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(body: body),
    );

void main() {
  testWidgets('wrong-org verdict explains no-proof-sent + way back',
      (t) async {
    await t.pumpWidget(_themed(
      MarkVerdictView(
        kind: MarkVerdict.wrongOrg,
        detail: 'Wrong organization for this class — join your institute class',
        roundMarks: const [],
        onRetryFace: () {},
        onManualInstead: () {},
        onBack: () {},
      ),
    ));
    expect(find.textContaining('Wrong organization'), findsWidgets);
    expect(find.text('Back to classes'), findsOneWidget);
  });

  testWidgets('device trust tiers label distinctly', (t) async {
    for (final entry in {
      'FULL': 'Device trust FULL',
      'STD': 'Device trust STD',
      'STALE': 'Device trust STALE',
      'NONE': 'Device NONE',
    }.entries) {
      // DeviceTrustBadge reads ProximityColors — pump under the app theme.
      await t.pumpWidget(_themed(
        DeviceTrustBadge(level: entry.key, pkDHex: 'abcdef1234567890'),
      ));
      expect(find.textContaining(entry.value), findsOneWidget);
    }
  });

  testWidgets('waiting room states unreachable honestly', (t) async {
    await t.pumpWidget(_themed(
      WaitingRoomView(
        connected: false,
        roomClass: 'CS201',
        roundMarks: const [],
        onRequestManual: () {},
        onCancel: () {},
      ),
    ));
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.textContaining('Honestly unreachable'), findsOneWidget);
  });

  test('trust helpers format honestly', () {
    expect(trustDateLabel(0), '');
    expect(trustDateLabel(1756684800000), '2025-09-01');
    expect(trustPkDFingerprint(''), 'no key');
    expect(trustPkDFingerprint('abcdef1234567890'), contains('…'));
  });
}
