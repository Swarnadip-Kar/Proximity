// Account Device-verification card: cache-first standing (no native
// probe from a facts page), explicit Check-now probing, honest copy.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/security/integrity.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/account/device_verification.dart';

class _FakeProbe implements IntegrityProbe {
  final IntegritySignals signals;
  int calls = 0;
  _FakeProbe(this.signals);
  @override
  Future<IntegritySignals> check() async {
    calls++;
    return signals;
  }
}

Widget _card() => ProviderScope(
      child: MaterialApp(
        theme: proxLightTheme(),
        home: const Scaffold(body: DeviceVerificationCard()),
      ),
    );

void main() {
  tearDown(() {
    IntegrityGate.probe = const PlatformIntegrityProbe();
    IntegrityGate.debugResetForTest();
  });

  testWidgets('fresh cached clean verdict renders Verified, probes nothing',
      (t) async {
    final probe = _FakeProbe(const IntegritySignals());
    IntegrityGate.probe = probe;
    await IntegrityGate.performCheck();
    final callsAfterPrime = probe.calls;
    await t.pumpWidget(_card());
    await t.pumpAndSettle();
    expect(find.text('Device verification'), findsOneWidget);
    expect(find.text('Verified'), findsOneWidget);
    expect(find.text('Unverified'), findsNothing);
    expect(find.textContaining('Checked when the app started.'),
        findsOneWidget);
    expect(probe.calls, callsAfterPrime);
    expect(t.takeException(), isNull);
  });

  testWidgets('fresh cached tainted verdict renders Unverified', (t) async {
    IntegrityGate.probe =
        _FakeProbe(const IntegritySignals(rooted: true));
    await IntegrityGate.performCheck();
    await t.pumpWidget(_card());
    await t.pumpAndSettle();
    expect(find.text('Unverified'), findsOneWidget);
    expect(find.text('Verified'), findsNothing);
    expect(find.textContaining('rooted'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('stale cache asks, Check-now probes once', (t) async {
    IntegrityGate.debugResetForTest();
    final probe = _FakeProbe(const IntegritySignals(emulator: true));
    IntegrityGate.probe = probe;
    await t.pumpWidget(_card());
    await t.pumpAndSettle();
    expect(find.textContaining('Not checked yet'), findsOneWidget);
    expect(probe.calls, 0);
    await t.tap(find.text('Check now'));
    await t.pumpAndSettle();
    expect(probe.calls, 1);
    expect(find.text('Unverified'), findsOneWidget);
    expect(find.textContaining('Checked just now.'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
