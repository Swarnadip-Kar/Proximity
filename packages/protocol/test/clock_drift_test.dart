import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  DateTime t(int secs) =>
      DateTime.fromMillisecondsSinceEpoch(secs * 1000, isUtc: true);

  test('needs 3 samples; banners when median drift exceeds 5s', () {
    final c = ClockDriftTracker();
    expect(c.drifted, isFalse);
    expect(c.banner, isNull);
    c.addSample(serverTime: t(100), localNow: t(90)); // 10s off
    c.addSample(serverTime: t(200), localNow: t(190));
    expect(c.drifted, isFalse); // only 2 samples: no banner
    c.addSample(serverTime: t(300), localNow: t(290));
    expect(c.medianAbsSecs, 10);
    expect(c.drifted, isTrue);
    expect(c.banner, contains('~10s'));
  });

  test('in-sync clocks never banner', () {
    final c = ClockDriftTracker();
    for (var i = 0; i < 9; i++) {
      c.addSample(serverTime: t(i), localNow: t(i));
    }
    expect(c.drifted, isFalse);
    expect(c.banner, isNull);
  });

  test('median resists one slow POST', () {
    final c = ClockDriftTracker();
    c.addSample(serverTime: t(0), localNow: t(0));
    c.addSample(serverTime: t(5), localNow: t(5));
    c.addSample(serverTime: t(100), localNow: t(10)); // one 90s outlier
    c.addSample(serverTime: t(15), localNow: t(15));
    c.addSample(serverTime: t(20), localNow: t(20));
    expect(c.drifted, isFalse);
  });

  test('window bounds history to the latest samples', () {
    final c = ClockDriftTracker();
    for (var i = 0; i < 8; i++) {
      c.addSample(serverTime: t(100 + i), localNow: t(i)); // 100s drift
    }
    expect(c.drifted, isTrue);
    for (var i = 0; i < 9; i++) {
      c.addSample(serverTime: t(500 + i), localNow: t(500 + i)); // healed
    }
    expect(c.drifted, isFalse);
    expect(c.sampleCount, kClockDriftWindow);
  });
}
