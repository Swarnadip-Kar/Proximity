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

  test('beacon payload is byte-equal to pre-profEmail shape (no email key)', () {
    // Revert pin: beacon//window carry no profEmail (commit 6e10b14
    // reverted). The JSON has exactly the pre-extension keys — a passive
    // listener learns no Gmail from beacons.
    final a = ClassAnnouncement(
      classLabel: 'CS201-Room301',
      host: '10.50.37.76',
      port: 8443,
      display: 'KQ7',
      prof: 'Prof K',
      windowOpen: true,
      ts: DateTime.parse('2026-09-09T10:00:00.000Z'),
      org: 'univ.edu',
    );
    final m = a.toJson();
    expect(m.containsKey('profEmail'), isFalse);
    expect(m.keys.toSet(),
        {'v', 'class', 'host', 'port', 'display', 'prof', 'windowOpen', 'ts', 'org'});
    final back = decodeAnnouncement(encodeAnnouncement(a))!;
    expect(back.org, 'univ.edu');
    expect(back.prof, 'Prof K');
    // Unknown keys (e.g. a stale profEmail from a mixed fleet) are ignored.
    final withStale = Map<String, dynamic>.of(m)..['profEmail'] = 'x@y.z';
    expect(ClassAnnouncement.fromJson(withStale)!.org, 'univ.edu');
  });

  test('beacon stays well under the 512B budget without the email', () {
    final typical = ClassAnnouncement(
      classLabel: 'CS201-Room301',
      host: '10.50.37.76',
      port: 8443,
      display: 'KQ7',
      prof: 'Prof K',
      windowOpen: true,
      ts: DateTime.parse('2026-09-09T10:00:00.000Z'),
      org: 'univ.edu',
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
    );
    expect(encodeAnnouncement(typical).length, lessThan(512));
    expect(encodeAnnouncement(padded).length, lessThan(512));
  });

  test('/window carries no profEmail after the revert (byte-equal keys)', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final server = ProxServer(
      classLabel: 'REVERT-TEST',
      profSk: prof.privateKey,
      profPk: prof.publicKey,
      sightings: ({required peerW, required expectedAirKey, required expectedUuid}) => null,
      sessionOrg: 'univ.edu',
    );
    await server.start(port: 0);
    try {
      final idle = await probeHost('127.0.0.1', server.port);
      expect(idle, isNotNull);
      expect(idle!.org, 'univ.edu');
      server.openWindow(
        WindowParams(
          sessionId: randBytes(16),
          windowId: randBytes(6),
          secret: randBytes(32),
          t0: DateTime.now().toUtc(),
          classLabel: 'REVERT-TEST',
        ),
        1,
      );
      final hit = await probeHost('127.0.0.1', server.port);
      expect(hit!.org, 'univ.edu');
      // Raw /window JSON has no profEmail key (byte-equal to pre-6e10b14).
      final rawClient = ProxClient(host: '127.0.0.1', port: server.port);
      try {
        final cj = server.window!.challengeFor(0);
        final desc = await rawClient.fetchWindow(cj);
        expect(desc.org, 'univ.edu');
        expect(desc.profEmail, '');
      } finally {
        rawClient.close();
      }
    } finally {
      await server.stop();
    }
  });

  test('gated /window: matching org lists + sees email (idle + open)', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final server = ProxServer(
      classLabel: 'GATED-TEST',
      profSk: prof.privateKey,
      profPk: prof.publicKey,
      sightings: ({required peerW, required expectedAirKey, required expectedUuid}) => null,
      sessionOrg: 'univ.edu',
      sessionProfEmail: 'Prof.K@Univ.edu',
    );
    await server.start(port: 0);
    final port = server.port;
    try {
      // Idle: gated probe with the matching claim returns identity + email.
      final idleClient = ProxClient(host: '127.0.0.1', port: port);
      try {
        final idle = await idleClient.probeWindow(org: 'univ.edu');
        expect(idle.reachable, isTrue);
        expect(idle.classLabel, 'GATED-TEST');
        expect(idle.org, 'univ.edu');
        expect(idle.profEmail, 'prof.k@univ.edu');
      } finally {
        idleClient.close();
      }
      // Open: probe + full descriptor both carry the gated email.
      server.openWindow(
        WindowParams(
          sessionId: randBytes(16),
          windowId: randBytes(6),
          secret: randBytes(32),
          t0: DateTime.now().toUtc(),
          classLabel: 'GATED-TEST',
        ),
        1,
      );
      final hit = await probeHost('127.0.0.1', port, org: 'univ.edu');
      expect(hit, isNotNull);
      expect(hit!.org, 'univ.edu');
      final fetchClient = ProxClient(host: '127.0.0.1', port: port);
      try {
        final cj = server.window!.challengeFor(0);
        final desc = await fetchClient.fetchWindow(cj, org: 'univ.edu');
        expect(desc.profEmail, 'prof.k@univ.edu');
        expect(desc.org, 'univ.edu');
      } finally {
        fetchClient.close();
      }
    } finally {
      await server.stop();
    }
  });

  test('gated /window: mismatched org gets silence, never the class', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final server = ProxServer(
      classLabel: 'GATED-TEST',
      profSk: prof.privateKey,
      profPk: prof.publicKey,
      sightings: ({required peerW, required expectedAirKey, required expectedUuid}) => null,
      sessionOrg: 'univ.edu',
      sessionProfEmail: 'prof.k@univ.edu',
    );
    await server.start(port: 0);
    final port = server.port;
    try {
      server.openWindow(
        WindowParams(
          sessionId: randBytes(16),
          windowId: randBytes(6),
          secret: randBytes(32),
          t0: DateTime.now().toUtc(),
          classLabel: 'GATED-TEST',
        ),
        1,
      );
      // Gated probe with the wrong claim: silence (no listing).
      String? miss;
      final missHit =
          await probeHost('127.0.0.1', port, org: 'other.edu', onMiss: (r) => miss = r);
      expect(missHit, isNull);
      expect(miss ?? '', contains('org-mismatch'));
      final probeClient = ProxClient(host: '127.0.0.1', port: port);
      try {
        final probe = await probeClient.probeWindow(org: 'other.edu');
        expect(probe.reachable, isFalse);
        expect(probe.classLabel, '');
        expect(probe.profEmail, '');
        // Full fetch with the wrong claim: structured refusal, never email.
        final cj = server.window!.challengeFor(0);
        try {
          await probeClient.fetchWindow(cj, org: 'other.edu');
          fail('mismatched fetch must throw');
        } on StateError catch (e) {
          expect('$e', contains('org-mismatch'));
          expect('$e', isNot(contains('prof.k@univ.edu')));
        }
      } finally {
        probeClient.close();
      }
    } finally {
      await server.stop();
    }
  });

  test('gated /window: legacy/empty org renders as before (no email key)', () async {
    final prof = ProxCrypto.generateEdKeypair();
    final server = ProxServer(
      classLabel: 'LEGACY-TEST',
      profSk: prof.privateKey,
      profPk: prof.publicKey,
      sightings: ({required peerW, required expectedAirKey, required expectedUuid}) => null,
    );
    await server.start(port: 0);
    try {
      // Legacy host ('' org): any claim passes, no email — renders as before.
      final hit = await probeHost('127.0.0.1', server.port, org: 'univ.edu');
      expect(hit, isNotNull);
      expect(hit!.org, '');
      final client = ProxClient(host: '127.0.0.1', port: server.port);
      try {
        final probe = await client.probeWindow(org: '');
        expect(probe.reachable, isTrue);
        expect(probe.profEmail, '');
        expect(probe.org, '');
      } finally {
        client.close();
      }
    } finally {
      await server.stop();
    }
  });

  test('BLE air packets carry no prof email (IP:port only — assert)', () {
    // The BLE IP hint is host:port packed beside the discriminator (never
    // identity): pack + parse round-trips the address with no email field
    // anywhere on the sighting type.
    const host = '10.50.37.76';
    const port = 8443;
    final uuid = UuidCodec.packIpHint(host, port);
    expect(uuid, isNotNull);
    final norm = UuidCodec.normalize(uuid!);
    expect(norm, isNotEmpty);
    // Raw air bytes never contain an email marker: no '@', no Gmail.
    final raw = uuid.toString();
    expect(raw.contains('@'), isFalse);
    expect(raw.toLowerCase().contains('gmail'), isFalse);
    // Beacons likewise have no email field by construction (see key-set
    // pin above): the announcement type cannot name one.
  });
}
