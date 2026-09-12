// SYNC/TRANSITION-OWNED regression: class-marking → next-state latency cut
// + marked-complete auto-exit. Transport, drivers, and poll guards only —
// no visuals, copy, export, or date logic touched here.
//
// 1. prove auto-leaves the server waiting room: the /prove verdict IS the
//    leave (zero extra requests — the test never calls leaveWaiting and the
//    count still drops to 0). Rewaits re-register via presence.
// 2. waiting-room entry reuses the presence POST's piggybacked window sample
//    instead of an immediate GET /window: an open-window entry spends
//    1 POST + 0 GETs (was 1 POST + 1 GET) — one fewer TLS handshake on the
//    join→face path and one fewer hit in the 5-hits/10s/IP budget.
// 3. a flaked presence POST still falls back to the immediate probe.
// 4. a closed-window entry parks on presence (zero entry GETs, Connected
//    from the POST proof-of-life) and the next 2s poll — not an entry GET —
//    drives the window-open flip (poll-phase alignment preserved).
//
// Fake-time/fake-driver widget suite, settle-safe (bounded pumps only,
// never an unbounded settle over the periodic room/presence timers).
//
// The real-server prove test lives in prove_auto_leave_test.dart: files
// that pump widgets run under TestWidgetsFlutterBinding, whose mock
// HttpClient answers 400 to every real request, so loopback HTTPS tests
// must stay in a widget-free file (same split as student_driver_test).
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_transport/transport.dart';

import 'widget_test.dart' as helpers;

/// Counting fake: separates presence POSTs from window probes so the tests
/// pin the exact request mix per room entry (the latency/load contract).
class _CountingLatencyDriver extends FakeStudentDriver {
  _CountingLatencyDriver({super.windowOpenProbe, this.presenceWorks = true});

  /// False mirrors a flaked presence POST the way the real driver reports
  /// it (sent:false, never a throw — presence stays best-effort).
  bool presenceWorks;
  var presencePosts = 0;
  var probeWindows = 0;
  var listens = 0;

  @override
  Future<PresenceSample> sendPresence(
      {required ClassBeacon target,
      required LinkedIdentity identity,
      String photoUrl = ''}) async {
    presencePosts++;
    if (!presenceWorks) return const PresenceSample(sent: false);
    return super.sendPresence(
        target: target, identity: identity, photoUrl: photoUrl);
  }

  @override
  Future<WindowProbe> probeWindow(ClassBeacon target,
      {String myOrg = ''}) async {
    probeWindows++;
    return super.probeWindow(target, myOrg: myOrg);
  }

  @override
  Future<MarkedReceipt> listenAndProve({
    required ClassBeacon target,
    required LinkedIdentity identity,
    required double faceScore,
    required void Function(ListenStatus s) onStatus,
    int faceValidAtMs = 0,
    String verifierVer = '',
  }) async {
    listens++;
    onStatus(ListenStatus.waiting);
    return const MarkedReceipt(
        detail: 'KQ7 · 10:04:12',
        result: StudentResult.marked,
        display: 'KQ7');
  }
}

void main() {
  testWidgets(
      'open-window entry marks with zero entry GETs (presence sample drives it)',
      (t) async {
    final driver = _CountingLatencyDriver(windowOpenProbe: true);
    await t.pumpWidget(helpers.testScope(
        studentDriver: driver,
        linked: const LinkedIdentity(
            name: 'Test User',
            gmail: 'student@example.com',
            roll: '12342210')));
    await t.pumpAndSettle();
    await helpers.enterIp(t, '192.168.43.1');
    await t.tap(find.text('Join'));
    var marked = false;
    for (var i = 0; i < 20 && !marked; i++) {
      await t.pump(const Duration(seconds: 1));
      marked = find.text('Marked').evaluate().isNotEmpty;
    }
    expect(marked, isTrue);
    expect(driver.listens, 1);
    // BEFORE: entry spent 1 POST /waiting + 1 GET /window (immediate
    // probe). AFTER: the piggybacked presence sample drives the fast path
    // (the assertion lands before the 3s rewait chain can poll, so any
    // probe here would be an entry GET).
    expect(driver.presencePosts, 1);
    expect(driver.probeWindows, 0);
    expect(t.takeException(), isNull);
  });

  testWidgets('flaked presence still falls back to the immediate probe',
      (t) async {
    final driver = _CountingLatencyDriver(
        windowOpenProbe: true, presenceWorks: false);
    await t.pumpWidget(helpers.testScope(
        studentDriver: driver,
        linked: const LinkedIdentity(
            name: 'Test User',
            gmail: 'student@example.com',
            roll: '12342210')));
    await t.pumpAndSettle();
    await helpers.enterIp(t, '192.168.43.1');
    await t.tap(find.text('Join'));
    var marked = false;
    for (var i = 0; i < 20 && !marked; i++) {
      await t.pump(const Duration(seconds: 1));
      marked = find.text('Marked').evaluate().isNotEmpty;
    }
    expect(marked, isTrue);
    expect(driver.listens, 1);
    // The POST flaked, so exactly one fallback immediate GET ran (the old
    // path, preserved) — then the advance cancelled the periodic poll.
    expect(driver.presencePosts, 1);
    expect(driver.probeWindows, 1);
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'closed-window entry parks on presence and the next poll flips it',
      (t) async {
    final driver = _CountingLatencyDriver(windowOpenProbe: false);
    await t.pumpWidget(helpers.testScope(
        studentDriver: driver,
        linked: const LinkedIdentity(
            name: 'Test User',
            gmail: 'student@example.com',
            roll: '12342210')));
    await t.pumpAndSettle();
    await helpers.enterIp(t, '192.168.43.1');
    await t.tap(find.text('Join'));
    // Short pumps only (well under the first 2s poll tick): entry must
    // park with zero GETs of any kind.
    var waiting = false;
    for (var i = 0; i < 6 && !waiting; i++) {
      await t.pump(const Duration(milliseconds: 300));
      waiting =
          find.textContaining('has not yet started').evaluate().isNotEmpty;
    }
    expect(waiting, isTrue);
    // Connected comes from the POST proof-of-life (no probe ran yet).
    expect(find.text('Connected'), findsOneWidget);
    expect(driver.presencePosts, 1);
    expect(driver.probeWindows, 0);
    // Professor opens the window: the next 2s poll (not an entry GET)
    // flips the room to face → listen → marked, zero taps.
    driver.windowOpenProbe = true;
    var marked = false;
    for (var i = 0; i < 20 && !marked; i++) {
      await t.pump(const Duration(seconds: 1));
      marked = find.text('Marked').evaluate().isNotEmpty;
    }
    expect(marked, isTrue);
    expect(driver.listens, 1);
    expect(driver.probeWindows, greaterThanOrEqualTo(1));
    expect(t.takeException(), isNull);
  });
}
