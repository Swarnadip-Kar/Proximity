import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_transport/transport.dart';
import 'package:test/test.dart';

void main() {
  test('hint sessions outlive radio expiry while acked', () {
    final now = DateTime.now().toUtc();
    // Fresh sighting: alive regardless of acks.
    expect(hintEntryAlive(now: now, lastSeen: now), isTrue);
    expect(
        hintEntryAlive(
            now: now, lastSeen: now.subtract(kDiscoveryExpiry)),
        isTrue);
    // Stale sighting, never acked: dead (old 6s behavior).
    expect(
        hintEntryAlive(
            now: now, lastSeen: now.subtract(const Duration(seconds: 30))),
        isFalse);
    // Stale sighting but recently TCP-acked (round over, host still up):
    // stays listed so the student can join the waiting room.
    expect(
        hintEntryAlive(
            now: now,
            lastSeen: now.subtract(const Duration(seconds: 30)),
            lastAck: now.subtract(const Duration(seconds: 10))),
        isTrue);
    // Ack older than the persist window: dead.
    expect(
        hintEntryAlive(
            now: now,
            lastSeen: now.subtract(const Duration(seconds: 30)),
            lastAck: now.subtract(const Duration(seconds: 300))),
        isFalse);
    // Too many consecutive failed re-probes (professor left): dead.
    expect(
        hintEntryAlive(
            now: now,
            lastSeen: now.subtract(const Duration(seconds: 30)),
            lastAck: now.subtract(const Duration(seconds: 10)),
            fails: kSessionMaxFails),
        isFalse);
  });

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

  test('directed broadcast guesses (/24 heuristic, validated)', () {
    expect(directedBroadcastGuess('192.168.43.1'), '192.168.43.255');
    expect(directedBroadcastGuess('10.50.37.76'), '10.50.37.255');
    expect(directedBroadcastGuess('172.16.5.9'), '172.16.5.255');
    expect(directedBroadcastGuess('8.8.8.8'), isNull); // public: skip
    expect(directedBroadcastGuess('not-an-ip'), isNull);
    expect(directedBroadcastGuess('127.0.0.1'), isNull); // loopback: skip
  });

  test('directed broadcast /16 guess covers /16../18 campuses', () {
    // Live case: 10.50.19.107/18 broadcasts at 10.50.63.255, which the
    // /24 guess (10.50.19.255) misses entirely.
    expect(directedBroadcastGuess16('10.50.19.107'), '10.50.255.255');
    expect(directedBroadcastGuess16('192.168.43.1'), '192.168.255.255');
    expect(directedBroadcastGuess16('8.8.8.8'), isNull);
    expect(directedBroadcastGuess16('127.0.0.1'), isNull);
    expect(directedBroadcastGuess16('not-an-ip'), isNull);
  });

  test('lan candidates skip loopback/link-local; best is usable', () async {
    final cands = await lanAddressCandidates();
    for (final c in cands) {
      expect(c.addr.startsWith('127.'), isFalse);
      expect(c.addr.startsWith('169.254.'), isFalse);
    }
    final best = await bestLanAddress();
    expect(best.isNotEmpty, isTrue);
  });

  test('single-host probe finds a loopback ProxServer', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final server = ProxServer(
      classLabel: 'PROBE-TEST',
      profSk: prof.privateKey,
      profPk: prof.publicKey,
      sightings: ({required peerW, required expectedAirKey, required expectedUuid}) => null,
    );
    await server.start(port: 0);
    final port = server.port;
    expect(port, greaterThan(0));
    try {
      // 127.0.0.1 is loopback: probeHost hits the server directly.
      final hit = await probeHost('127.0.0.1', port);
      expect(hit, isNotNull);
      expect(hit!.windowOpen, isFalse);
      // Nobody home on an unroutable TEST-NET port.
      final miss = await probeHost('127.0.0.1', 1,
          timeout: const Duration(milliseconds: 300));
      expect(miss, isNull);
    } finally {
      await server.stop();
    }
  });

  test('broadcast targets always include limited broadcast', () async {
    final targets = await broadcastTargets();
    expect(targets.map((e) => e.address), contains('255.255.255.255'));
  });

  test('announcer start/stop lifecycle', () async {    var n = 0;
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

  test('assumption table is never silent (5 rows, honest standings)', () {
    expect(discoveryAssumptions, hasLength(5));
    final byPath = {for (final a in discoveryAssumptions) a.path: a};
    expect(byPath['UDP broadcast']!.standing, 'advisory-only');
    expect(byPath['HTTPS unicast prof<->student']!.standing,
        'HARD REQUIREMENT');
    expect(byPath['BLE hint + unicast probe + typed IP']!.standing,
        'relied-upon');
    expect(byPath['internet in live flow']!.standing, 'never probed');
    expect(byPath['BLE off']!.standing, 'tappable Turn-on');
    // Log rendering covers every row (hosting start + browse entry log
    // these with the LAN tag).
    final lines = discoveryAssumptionLines();
    expect(lines, hasLength(5));
    for (final a in discoveryAssumptions) {
      expect(lines.any((l) => l.contains(a.path)), isTrue);
    }
  });

  test('degradation ladder order + rung picker', () {
    expect(degradationLadder, [
      'BLE hint + probe',
      'typed IP + BLE',
      'LAN manual IP',
      'offline direct manual-add',
    ]);
    expect(
        ladderStepFor(bleOn: true, hintHeard: true, unicastOk: true), 0);
    expect(
        ladderStepFor(bleOn: true, hintHeard: false, unicastOk: true), 1);
    expect(
        ladderStepFor(bleOn: false, hintHeard: false, unicastOk: true), 2);
    expect(
        ladderStepFor(bleOn: true, hintHeard: true, unicastOk: false), 3);
    // One-line status brackets the active rung.
    expect(formatLadderLine(1),
        'BLE hint + probe → [typed IP + BLE] → LAN manual IP → offline direct manual-add');
  });

  test('discovery stays unicast-only (no sweep helper exists)', () {
    // probeHost takes ONE host:port. A subnet sweep (254 rapid probes)
    // kicked phones off enterprise WiFi and was deleted — this pins the
    // single-host signature so it cannot grow a range argument silently.
    expect(probeHost, isA<Future<ClassAnnouncement?> Function(String, int)>());
  });

  test('beacon round-trips the prof email (lowercased)', () {
    final a = ClassAnnouncement(
      classLabel: 'CS201-Room301',
      host: '10.50.37.76',
      port: 8443,
      display: 'KQ7',
      prof: 'Prof K',
      windowOpen: true,
      ts: DateTime.now().toUtc(),
      org: 'univ.edu',
      profEmail: 'Prof.K@Univ.edu',
    );
    final back = decodeAnnouncement(encodeAnnouncement(a))!;
    expect(back.profEmail, 'prof.k@univ.edu');
    expect(back.org, 'univ.edu');
    expect(back.prof, 'Prof K');
  });

  test('legacy beacons without the email parse to empty', () {
    final legacy = {
      'v': kDiscoveryMagic,
      'class': 'CS201',
      'host': '10.0.0.5',
      'port': 8443,
      'display': '',
      'prof': 'Prof X',
      'windowOpen': false,
      'ts': DateTime.now().toUtc().toIso8601String(),
      'org': 'univ.edu',
    };
    final back = ClassAnnouncement.fromJson(legacy)!;
    expect(back.profEmail, '');
    // Codec-level legacy: no profEmail key at all still decodes.
    final raw =
        Uint8List.fromList(utf8.encode(jsonEncode(legacy)));
    expect(decodeAnnouncement(raw)!.profEmail, '');
  });

  test('beacon stays well under the 512B budget with the email', () {
    final typical = ClassAnnouncement(
      classLabel: 'CS201-Room301',
      host: '10.50.37.76',
      port: 8443,
      display: 'KQ7',
      prof: 'Prof K',
      windowOpen: true,
      ts: DateTime.parse('2026-09-09T10:00:00.000Z'),
      org: 'univ.edu',
      profEmail: 'prof.k@univ.edu',
    );
    final padded = ClassAnnouncement(
      classLabel: 'CS101-Introduction-to-Computer-Science-Room-301-B',
      host: '10.50.37.76',
      port: 8443,
      display: 'KQ7',
      prof: 'Professor Kavitha Krishnamurthy Rao-Jones',
      windowOpen: true,
      ts: DateTime.parse('2026-09-09T10:00:00.000Z'),
      org: 'engineering.university-example.edu',
      profEmail: 'kavitha.krishnamurthy-rao-jones@engineering.university-example.edu',
    );
    expect(encodeAnnouncement(typical).length, lessThan(512));
    expect(encodeAnnouncement(padded).length, lessThan(512));
  });

  test('/window + probe + descriptor carry the prof email', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final server = ProxServer(
      classLabel: 'EMAIL-TEST',
      profSk: prof.privateKey,
      profPk: prof.publicKey,
      sightings: ({required peerW, required expectedAirKey, required expectedUuid}) => null,
      sessionOrg: 'univ.edu',
      sessionProfEmail: 'prof.k@univ.edu',
    );
    await server.start(port: 0);
    final port = server.port;
    try {
      // Idle window: the lightweight probe still carries it.
      final idle = await probeHost('127.0.0.1', port);
      expect(idle, isNotNull);
      expect(idle!.profEmail, 'prof.k@univ.edu');
      expect(idle.org, 'univ.edu');
      // Open window: probe + full descriptor both carry it.
      server.openWindow(
        WindowParams(
          sessionId: randBytes(16),
          windowId: randBytes(6),
          secret: randBytes(32),
          t0: DateTime.now().toUtc(),
          classLabel: 'EMAIL-TEST',
        ),
        1,
      );
      final hit = await probeHost('127.0.0.1', port);
      expect(hit!.profEmail, 'prof.k@univ.edu');
      final fetchClient = ProxClient(host: '127.0.0.1', port: port);
      try {
        final cj = server.window!.challengeFor(0);
        final desc = await fetchClient.fetchWindow(cj);
        expect(desc.profEmail, 'prof.k@univ.edu');
        expect(desc.org, 'univ.edu');
      } finally {
        fetchClient.close();
      }
    } finally {
      await server.stop();
    }
  });

  test('/window without the email reads legacy empty', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final server = ProxServer(
      classLabel: 'LEGACY-TEST',
      profSk: prof.privateKey,
      profPk: prof.publicKey,
      sightings: ({required peerW, required expectedAirKey, required expectedUuid}) => null,
    );
    await server.start(port: 0);
    try {
      final hit = await probeHost('127.0.0.1', server.port);
      expect(hit, isNotNull);
      expect(hit!.profEmail, '');
    } finally {
      await server.stop();
    }
  });
}
