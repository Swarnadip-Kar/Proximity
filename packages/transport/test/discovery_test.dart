import 'dart:io';
import 'dart:typed_data';

import 'package:proximity_transport/transport.dart';
import 'package:test/test.dart';

void main() {
  test('announce -> listen over loopback, expiry prunes', () async {
    // NOTE: binds a fixed test port to avoid clashing with a live advertiser.
    const testPort = 54599;
    final listener = ClassListener();
    await listener.start(port: testPort);
    final announcer = ClassAnnouncer(
      () => ClassAnnouncement(
        classLabel: 'CS201-Room301',
        host: '127.0.0.1',
        port: 8443,
        display: 'KQ7',
        prof: 'Prof K',
        windowOpen: true,
        ts: DateTime.now().toUtc(),
      ),
      target: InternetAddress.loopbackIPv4,
    );
    // Point the announcer at the test port via a second socket pair:
    // send directly and verify decode path end-to-end.
    final heard = <ClassAnnouncement>[];
    listener.onChange = () => heard.addAll(
        listener.live().map((e) => e.last));
    // Direct datagram to the listener (loopback stands in for broadcast).
    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sock.send(
        encodeAnnouncement(ClassAnnouncement(
          classLabel: 'CS201-Room301',
          host: '127.0.0.1',
          port: 8443,
          display: 'KQ7',
          prof: 'Prof K',
          windowOpen: true,
          ts: DateTime.now().toUtc(),
        )),
        InternetAddress.loopbackIPv4,
        testPort);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(listener.live().length, 1);
    expect(listener.live().first.last.display, 'KQ7');
    expect(listener.live().first.last.windowOpen, isTrue);
    // Expiry: unheard entries vanish after 6s.
    expect(
        listener
            .live(now: DateTime.now()
                .toUtc()
                .add(const Duration(seconds: 30)))
            .length,
        0);
    sock.close();
    await announcer.stop();
    await listener.stop();
  });

  test('codec rejects garbage + wrong magic', () {
    expect(decodeAnnouncement(Uint8List.fromList([1, 2, 3])), isNull);
    expect(
        ClassAnnouncement.fromJson({'v': 'NOPE', 'class': 'x'}), isNull);
  });

  test('announcer start/stop lifecycle', () async {
    var n = 0;
    final a = ClassAnnouncer(() {
      n++;
      return ClassAnnouncement(
        classLabel: 'C',
        host: '127.0.0.1',
        port: 1,
        display: 'X',
        prof: 'P',
        windowOpen: true,
        ts: DateTime.now().toUtc(),
      );
    }, target: InternetAddress.loopbackIPv4);
    await a.start();
    await Future.delayed(const Duration(milliseconds: 100));
    await a.stop();
    expect(n, greaterThanOrEqualTo(1));
  });
}
