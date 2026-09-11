// Waiting-room connection-state regression (CONNECTION-STATE LOGIC ONLY):
// the badge must hold steady Connected on a stable link even when the
// professor's 5-hits/10s/IP sliding-window cap 429s a poll, and genuine
// loss must still surface promptly (no latching either way). Follows the
// fake-driver/testScope patterns in widget_test.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_transport/transport.dart';

import 'widget_test.dart' as helpers;

/// Fake room that trips the real professor server's rate cap the way the
/// 2s poll actually does: every 6th poll answers 429 (host alive, payload
/// withheld) on an otherwise perfectly reachable link. Genuine loss is
/// toggled via [reachableProbe] — a dead server answers nothing, not even
/// a 429, so unreachable probes are never marked rate-limited.
class _CappedRoomDriver extends FakeStudentDriver {
  _CappedRoomDriver() : super(windowOpenProbe: false);
  var probes = 0;
  var limited = 0;
  var reachableProbe = true;

  @override
  Future<WindowProbe> probeWindow(ClassBeacon target,
      {String myOrg = ''}) async {
    probes++;
    if (!reachableProbe) {
      return WindowProbe(
          reachable: false,
          windowOpen: false,
          classLabel: target.classLabel);
    }
    // Steady-state 429 cadence: the entry probe + 5 ticks fill the 5/10s
    // budget, so the 6th GET is limited — the real-server rhythm that used
    // to flap the badge for exactly one tick every ~10s.
    if (probes % 6 == 0) {
      limited++;
      return WindowProbe(
          reachable: false,
          windowOpen: false,
          classLabel: target.classLabel,
          rateLimited: true);
    }
    return WindowProbe(
        reachable: true, windowOpen: false, classLabel: target.classLabel);
  }
}

Future<void> _joinWaiting(WidgetTester t, _CappedRoomDriver driver) async {
  await t.pumpWidget(helpers.testScope(
      studentDriver: driver,
      linked: const LinkedIdentity(
          name: 'Test User',
          gmail: 'student@example.com',
          roll: '12342210')));
  await t.pumpAndSettle();
  await helpers.enterIp(t, '192.168.43.1');
  await t.tap(find.text('Join'));
  await t.pumpAndSettle();
  expect(find.text('Connected'), findsOneWidget);
}

void main() {
  testWidgets('stable room holds Connected across rate-limited ticks',
      (t) async {
    final driver = _CappedRoomDriver();
    await _joinWaiting(t, driver);
    // Twelve 2s poll cycles: two full 429 ticks land in here on a healthy
    // link. The badge must never flap to Not connected.
    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(seconds: 2));
      await t.pump();
      expect(find.text('Connected'), findsOneWidget,
          reason: 'badge flapped on cycle $i');
      expect(find.text('Not connected'), findsNothing,
          reason: 'badge flapped on cycle $i');
    }
    expect(driver.limited, greaterThanOrEqualTo(1),
        reason: 'test never tripped the emulated 429 cap');
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  testWidgets('genuine loss surfaces promptly and recovers without latch',
      (t) async {
    final driver = _CappedRoomDriver();
    await _joinWaiting(t, driver);
    // Real outage: the very next unreachable tick shows Not connected
    // (single-miss responsiveness is unchanged by the 429 hold).
    driver.reachableProbe = false;
    await t.pump(const Duration(seconds: 2));
    await t.pump();
    expect(find.text('Not connected'), findsOneWidget);
    // Recovery: back to Connected on the next good tick, no latch.
    driver.reachableProbe = true;
    await t.pump(const Duration(seconds: 2));
    await t.pump();
    expect(find.text('Connected'), findsOneWidget);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
}
