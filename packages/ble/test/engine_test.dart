import 'dart:async';
import 'dart:typed_data';

import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

BleSighting challengeSighting(List<int> token,
        {int rssi = -60,
        int ttl = 3,
        String ip = '10.50.19.107',
        bool legacy = false}) =>
    BleSighting(
      type: kAirTypeChallenge,
      token8: Uint8List.fromList(token),
      ipHost: ip,
      ipPort: 8443,
      legacy: legacy,
      legacyUuid: legacy
          ? UuidCodec.normalize(UuidCodec.packChallenge(
              Uint8List.fromList(token)))
          : null,
      rssiDbm: rssi,
      at: DateTime.now().toUtc(),
      ttl: ttl,
    );

/// Peripheral stack that never completes an advertise (the wedged-radio
/// case from live testing).
class _HungRadio extends FakeBleRadio {
  @override
  Future<void> startAirPacket(String airServiceUuid, Uint8List airMfg,
          {List<int>? scanResponse}) =>
      Completer<void>().future;

  @override
  Future<void> startLegacyUuid(String uuid128) => Completer<void>().future;
}

void main() {
  test('prof rotation advertises v2 air packet per sub-epoch', () async {
    final radio = FakeBleRadio();
    final engine = ProxBleEngine(radio: radio);
    engine.setServerIp('10.50.19.107', 8443);
    final window = WindowParams(
      sessionId: randBytes(16),
      windowId: randBytes(6),
      secret: randBytes(32),
      t0: DateTime.now().toUtc(),
      classLabel: 'C',
    );
    await engine.startProfRotation(window);
    expect(radio.advertisingSvc, kAirSvc);
    final pdu = unpackAir(radio.advertisingMfg!)!;
    expect(pdu.type, kAirTypeChallenge);
    expect(pdu.token8, window.challengeFor(0));
    expect(pdu.host, '10.50.19.107');
    expect(pdu.port, 8443);
    await engine.stop();
    expect(radio.advertisingSvc, isNull);
  });

  test('prof rotation repeats the server IP on every tick', () async {
    // The BLE IP broadcast is continuous, never one-shot: every rotation
    // tick of a live window re-publishes host:port (v2: inside the air
    // packet; legacy: alternating IP-hint ticks).
    final radio = FakeBleRadio();
    final engine = ProxBleEngine(radio: radio);
    engine.setServerIp('10.50.19.107', 8443);
    final window = WindowParams(
      sessionId: randBytes(16),
      windowId: randBytes(6),
      secret: randBytes(32),
      t0: DateTime.now().toUtc(),
      classLabel: 'C',
    );
    await engine.startProfRotation(window);
    final first = unpackAir(radio.advertisingMfg!)!;
    await Future.delayed(const Duration(seconds: 6));
    final second = unpackAir(radio.advertisingMfg!)!;
    expect(first.host, '10.50.19.107');
    expect(first.port, 8443);
    expect(second.host, '10.50.19.107');
    expect(second.port, 8443);
    expect(bytesEqual(second.token8, first.token8), isFalse);
    await engine.stop();
  });

  test('idle rotation advertises the server IP-hint (waiting discoverable)',
      () async {
    // Waiting-room path: the same hint packet the round path alternates,
    // repeated with no challenge — students discover + join the wait, and
    // nothing is provable from it.
    final radio = FakeBleRadio();
    final engine = ProxBleEngine(radio: radio);
    engine.setServerIp('10.50.19.107', 8443);
    await engine.startIdleHintRotation();
    final uuid = radio.advertisingLegacyUuid!;
    expect(UuidCodec.isIpHintUuid(uuid), isTrue);
    final ip = UuidCodec.unpackIpHint(uuid)!;
    expect(ip.host, '10.50.19.107');
    expect(ip.port, 8443);
    // Challenge rotation preempts idle hints…
    final window = WindowParams(
      sessionId: randBytes(16),
      windowId: randBytes(6),
      secret: randBytes(32),
      t0: DateTime.now().toUtc(),
      classLabel: 'C',
    );
    await engine.startProfRotation(window);
    expect(radio.advertisingLegacyUuid, isNull);
    expect(unpackAir(radio.advertisingMfg!)!.isChallenge, isTrue);
    await engine.stop();
    expect(radio.advertisingMfg, isNull);
    expect(radio.advertisingLegacyUuid, isNull);
  });

  test('idle hint rotation survives a failed first tick (first-run heal)',
      () async {
    // The reported bug: a first-run idle ADV failure (BT settling,
    // permission timing, transient stack error) threw BEFORE the retry
    // timer existed — zero hints until Start's challenge rotation. Now
    // the timer arms first and the next tick heals.
    final radio = _FirstTickFailRadio();
    final engine = ProxBleEngine(radio: radio);
    engine.setServerIp('10.50.19.107', 8443);
    await engine.startIdleHintRotation(); // must NOT throw
    expect(radio.advertisingLegacyUuid, isNull); // first tick died
    expect(radio.advertiseCalls, 1);
    await Future.delayed(const Duration(seconds: 6)); // one retry tick
    // The retry tick REALLY re-advertises (not the old nested-guard fake
    // success, which skipped the radio call and only logged): a second
    // radio call lands the hint bytes on air.
    expect(radio.advertiseCalls, 2);
    final uuid = radio.advertisingLegacyUuid!;
    expect(UuidCodec.isIpHintUuid(uuid), isTrue);
    expect(UuidCodec.unpackIpHint(uuid)!.host, '10.50.19.107');
    expect(UuidCodec.unpackIpHint(uuid)!.port, 8443);
    await engine.stop();
    expect(radio.advertisingLegacyUuid, isNull);
  });

  test('hung radio surfaces TimeoutException instead of wedging rotation',
      () async {
    // Regression: one "legacy TX" log line then silence — a hung peripheral
    // stack wedged `await` forever and no per-tick ADV line ever repeated.
    final radio = _HungRadio();
    final engine = ProxBleEngine(radio: radio)
      ..advTimeout = const Duration(milliseconds: 100);
    engine.setServerIp('10.50.19.107', 8443);
    final window = WindowParams(
      sessionId: randBytes(16),
      windowId: randBytes(6),
      secret: randBytes(32),
      t0: DateTime.now().toUtc(),
      classLabel: 'C',
    );
    await expectLater(
        engine.startProfRotation(window), throwsA(isA<TimeoutException>()));
    await engine.stop();
  });

  test('prof rotation legacy TX advertises v1 UUID (Apple-safe)', () async {
    final radio = FakeBleRadio();
    final engine = ProxBleEngine(radio: radio)..legacyTx = true;
    engine.setServerIp('10.50.19.107', 8443);
    final window = WindowParams(
      sessionId: randBytes(16),
      windowId: randBytes(6),
      secret: randBytes(32),
      t0: DateTime.now().toUtc(),
      classLabel: 'C',
    );
    await engine.startProfRotation(window);
    expect(radio.advertisingLegacyUuid,
        UuidCodec.packChallenge(window.challengeFor(0)));
    expect(radio.advertisingMfg, isNull);
    await engine.stop();
  });

  test('rotation has no expiry coupling (the 29s radio-silence bug)', () async {
    // The reported killer: rotation auto-stopped at j == subEpochs, so a
    // professor going silent at 30s stranded every slow prover while the
    // server window still showed OPEN. Rotation now starts at j=0 and
    // ticks until stopped, however long the window has been open.
    final radio = FakeBleRadio();
    final engine = ProxBleEngine(radio: radio);
    engine.setServerIp('10.50.19.107', 8443);
    final window = WindowParams(
      sessionId: randBytes(16),
      windowId: randBytes(6),
      secret: randBytes(32),
      t0: DateTime.now().toUtc().subtract(const Duration(minutes: 10)),
      classLabel: 'C',
    );
    await engine.startProfRotation(window);
    expect(engine.currentJ, 0);
    expect(radio.advertisingMfg, isNotNull);
    expect(unpackAir(radio.advertisingMfg!)!.token8,
        window.challengeFor(0));
    await engine.stop();
  });

  test('restartScan revives the scan without tearing the role down', () async {
    // Observed live: the platform scan dies silently while reporting
    // active (zero sightings for minutes with an open window on air) and
    // only a fresh start revives it. restartScan re-arms in place —
    // relay arming and halted state survive (unlike stop()).
    final radio = FakeBleRadio();
    final engine = ProxBleEngine(radio: radio);
    await engine.startScanning();
    engine.relayEnabled = true;
    expect(await engine.restartScan(), isTrue);
    expect(radio.scanning, isTrue);
    expect(engine.relayEnabled, isTrue);
    // A broken radio reports false instead of throwing.
    final dead = ProxBleEngine(radio: _FailRadio());
    expect(await dead.restartScan(), isFalse);
    await engine.stop();
  });

  test('student response waits for the radio (never skip+lie)', () async {
    // Observed live: the relay held the ADV guard, the response ADV was
    // busy-skipped, yet `response on air` logged success — a guaranteed
    // no-ble-sighting. The response now waits for the guard and only
    // logs on actual TX.
    final radio = _GateRadio()..gate = Completer<void>();
    final engine = ProxBleEngine(radio: radio);
    await engine.startScanning();
    engine.relayEnabled = true;
    // Occupy the guard with a relay op (held at the gate past jitter).
    engine.handleSighting(
        challengeSighting([3, 3, 3, 3, 3, 3, 3, 3], legacy: true));
    await Future.delayed(const Duration(milliseconds: 400));
    // The response must NOT have completed (old code returned instantly
    // having skipped) — it waits for the guard instead.
    var done = false;
    final cj = Uint8List.fromList([3, 3, 3, 3, 3, 3, 3, 3]);
    final pending = engine
        .advertiseStudentResponse(
            's@x.in', cj, 0, Uint8List.fromList(List.filled(8, 9)))
        .then((_) => done = true);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(done, isFalse);
    // Release: relay finishes, response transmits for real.
    radio.gate!.complete();
    await pending.timeout(const Duration(seconds: 5));
    expect(done, isTrue);
    final rid = ProxCrypto.responseToken(cj, 's@x.in');
    expect(radio.advertisingLegacyUuid,
        UuidCodec.normalize(UuidCodec.packResponse(rid)));
    await engine.stop();
  });

  test('restartScanIfSilent re-arms only a silent scan (throttled)', () async {
    // Browse watchdog: a dead CHALLENGE channel heals via restart; a live
    // one is left alone, restarts run at most once per window, and a
    // freshly started scan never restarts instantly (no storm on entry).
    final radio = FakeBleRadio();
    final engine = ProxBleEngine(radio: radio);
    await engine.startScanning();
    // Fresh scan: not silent yet.
    expect(
        await engine.restartScanIfSilent(const Duration(seconds: 30)),
        isFalse);
    // Age past a short window: the challenge channel is silent → re-arms.
    // Response-only noise moves the any-sighting clock but must NOT mask
    // the dead challenge channel.
    engine.handleSighting(BleSighting(
      type: kAirTypeResponse,
      token8: Uint8List.fromList([9, 9, 9, 9, 9, 9, 9, 9]),
      ipHost: '',
      ipPort: 0,
      rssiDbm: -60,
      at: DateTime.now().toUtc(),
      ttl: 3,
    ));
    await Future.delayed(const Duration(milliseconds: 120));
    expect(
        await engine.restartScanIfSilent(
            const Duration(milliseconds: 50)),
        isTrue);
    // …then throttles (restarted moments ago).
    expect(
        await engine.restartScanIfSilent(
            const Duration(milliseconds: 50)),
        isFalse);
    // A live challenge channel is never touched.
    engine.handleSighting(challengeSighting([5, 5, 5, 5, 5, 5, 5, 5]));
    expect(
        await engine.restartScanIfSilent(
            const Duration(milliseconds: 50)),
        isFalse);
    expect(radio.scanning, isTrue);
    await engine.stop();
  });

  test('repeated packets log once (routine repeats stay silent)', () async {    // The reported log spam: the same challenge/ip-hint arrives every
    // second (professor ticks + our own relay echo) and every repeat
    // logged an RX line plus a relay-skip line. Only a NEW packet key
    // logs; repeats still dispatch and relay-guard silently.
    BleLog.clear();
    final radio = FakeBleRadio();
    final engine = ProxBleEngine(radio: radio);
    engine.relayEnabled = true;
    final c1 = challengeSighting([1, 1, 1, 1, 1, 1, 1, 1]);
    engine.handleSighting(c1);
    engine.handleSighting(c1);
    engine.handleSighting(c1);
    await Future.delayed(const Duration(milliseconds: 300));
    final rxLines = BleLog.history
        .where((e) => e.msg.startsWith('RX challenge'))
        .toList();
    expect(rxLines, hasLength(1));
    // A new token logs again.
    engine.handleSighting(challengeSighting([2, 2, 2, 2, 2, 2, 2, 2]));
    expect(BleLog.history.where((e) => e.msg.startsWith('RX challenge')),
        hasLength(2));
    await engine.stop();
  });

  test('legacy TX alternates challenge / IP-hint ticks', () async {    final radio = FakeBleRadio();
    final engine = ProxBleEngine(radio: radio)..legacyTx = true;
    engine.setServerIp('10.50.19.107', 8443);
    final window = WindowParams(
      sessionId: randBytes(16),
      windowId: randBytes(6),
      secret: randBytes(32),
      t0: DateTime.now().toUtc(),
      classLabel: 'C',
    );
    // j=0 advertises the challenge; the next 5s tick (j=1, odd) carries
    // the IP-hint UUID with the server address.
    await engine.startProfRotation(window);
    expect(UuidCodec.isChallengeUuid(radio.advertisingLegacyUuid!), isTrue);
    await Future.delayed(const Duration(milliseconds: 5500));
    final ipUuid = radio.advertisingLegacyUuid!;
    expect(UuidCodec.isIpHintUuid(ipUuid), isTrue);
    final ip = UuidCodec.unpackIpHint(ipUuid)!;
    expect(ip.host, '10.50.19.107');
    expect(ip.port, 8443);
    await engine.stop();
  });

  test('prof rotation skips without server IP', () async {    final radio = FakeBleRadio();
    final engine = ProxBleEngine(radio: radio);
    final window = WindowParams(
      sessionId: randBytes(16),
      windowId: randBytes(6),
      secret: randBytes(32),
      t0: DateTime.now().toUtc(),
      classLabel: 'C',
    );
    await engine.startProfRotation(window);
    expect(radio.advertisingMfg, isNull);
    expect(radio.advertisingLegacyUuid, isNull);
    await engine.stop();
  });

  test('student response echoes heard format (v2 and v1)', () async {
    final radio = FakeBleRadio();
    final engine = ProxBleEngine(radio: radio);
    // No heard server yet → skipped.
    await engine.advertiseStudentResponse(
        's@x.in',
        Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
        0,
        Uint8List.fromList(List.filled(8, 9)));
    expect(radio.advertisingMfg, isNull);
    // v2 heard → v2 response echoing its server.
    engine.handleSighting(challengeSighting([1, 2, 3, 4, 5, 6, 7, 8]));
    await engine.advertiseStudentResponse(
        's@x.in',
        Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
        0,
        Uint8List.fromList(List.filled(8, 9)));
    final pdu = unpackAir(radio.advertisingMfg!)!;
    expect(pdu.type, kAirTypeResponse);
    expect(
        pdu.token8,
        ProxCrypto.responseToken(
            Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]), 's@x.in'));
    expect(pdu.host, '10.50.19.107');
    // v1 heard → v1 UUID_S response.
    engine.handleSighting(
        challengeSighting([2, 2, 2, 2, 2, 2, 2, 2], legacy: true));
    await engine.advertiseStudentResponse(
        's@x.in',
        Uint8List.fromList([2, 2, 2, 2, 2, 2, 2, 2]),
        0,
        Uint8List.fromList(List.filled(8, 9)));
    expect(
        radio.advertisingLegacyUuid,
        UuidCodec.packResponse(ProxCrypto.responseToken(
            Uint8List.fromList([2, 2, 2, 2, 2, 2, 2, 2]), 's@x.in')));
    await engine.stop();
  });

  test('nextChallenge: fresh past sighting resolves, stale waits', () async {
    final engine = ProxBleEngine(radio: FakeBleRadio());
    engine.handleSighting(challengeSighting([5, 5, 5, 5, 5, 5, 5, 5]));
    expect(
        await engine.nextChallenge(timeout: const Duration(seconds: 1)),
        [5, 5, 5, 5, 5, 5, 5, 5]);

    final engine2 = ProxBleEngine(radio: FakeBleRadio());
    final t0 = DateTime.now().toUtc().millisecondsSinceEpoch;
    final res = await engine2.nextChallenge(
        timeout: const Duration(milliseconds: 300));
    expect(res, isNull);
    expect(DateTime.now().toUtc().millisecondsSinceEpoch - t0,
        greaterThanOrEqualTo(250));
  });

  test('front-row relay preserves format (v2 and v1)', () async {
    final radio = FakeBleRadio();
    final engine = ProxBleEngine(radio: radio)..relayEnabled = true;
    engine.handleSighting(challengeSighting([3, 3, 3, 3, 3, 3, 3, 3]));
    await Future.delayed(const Duration(milliseconds: 600));
    final pdu = unpackAir(radio.advertisingMfg!)!;
    expect(pdu.type, kAirTypeChallenge);
    expect(pdu.token8, [3, 3, 3, 3, 3, 3, 3, 3]);
    expect(pdu.host, '10.50.19.107');
    // Duplicate storm suppressed.
    engine.handleSighting(challengeSighting([3, 3, 3, 3, 3, 3, 3, 3]));
    await Future.delayed(const Duration(milliseconds: 400));
    expect(unpackAir(radio.advertisingMfg!)!.token8,
        [3, 3, 3, 3, 3, 3, 3, 3]);
    await engine.stop();

    // v1 heard → v1 UUID re-advertised.
    final radio2 = FakeBleRadio();
    final engine2 = ProxBleEngine(radio: radio2)..relayEnabled = true;
    engine2.handleSighting(
        challengeSighting([4, 4, 4, 4, 4, 4, 4, 4], legacy: true));
    await Future.delayed(const Duration(milliseconds: 600));
    expect(
        radio2.advertisingLegacyUuid,
        UuidCodec.packChallenge(Uint8List.fromList([4, 4, 4, 4, 4, 4, 4, 4])));
    await engine2.stop();
  });

  test('relay suppressed when disabled, weak, TTL spent, or own packet',
      () async {
    final radio = FakeBleRadio();
    final engine = ProxBleEngine(radio: radio);
    // disabled (default)
    engine.handleSighting(challengeSighting([6, 6, 6, 6, 6, 6, 6, 6]));
    await Future.delayed(const Duration(milliseconds: 400));
    expect(radio.advertisingMfg, isNull);
    // enabled but weak RSSI
    engine.relayEnabled = true;
    engine.handleSighting(
        challengeSighting([6, 6, 6, 6, 6, 6, 6, 6], rssi: -85));
    await Future.delayed(const Duration(milliseconds: 400));
    expect(radio.advertisingMfg, isNull);
    // enabled but TTL spent
    engine.handleSighting(
        challengeSighting([6, 6, 6, 6, 6, 6, 6, 6], ttl: 0));
    await Future.delayed(const Duration(milliseconds: 400));
    expect(radio.advertisingMfg, isNull);
    await engine.stop();
  });

  test('heard challenge fires IP-hint callback + records server', () async {
    final heard = <String>[];
    final engine = ProxBleEngine(radio: FakeBleRadio())
      ..onIpHintHeard = (h, p) => heard.add('$h:$p');
    engine.handleSighting(challengeSighting([4, 4, 4, 4, 4, 4, 4, 4]));
    expect(heard, ['10.50.19.107:8443']);
  });

  test('v1 IP-hint sighting fires hint + relays legacy UUID', () async {
    final heard = <String>[];
    final radio = FakeBleRadio();
    final engine = ProxBleEngine(radio: radio);
    engine.onIpHintHeard = (h, p) => heard.add('$h:$p');
    engine.relayEnabled = true;
    final uuid = UuidCodec.packIpHint('10.50.19.107', 8443)!;
    engine.handleSighting(BleSighting(
      type: kAirTypeIpHint,
      token8: Uint8List(8),
      ipHost: '10.50.19.107',
      ipPort: 8443,
      legacy: true,
      legacyUuid: UuidCodec.normalize(uuid),
      rssiDbm: -60,
      at: DateTime.now().toUtc(),
    ));
    expect(heard, ['10.50.19.107:8443']);
    await Future.delayed(const Duration(milliseconds: 600));
    expect(radio.advertisingLegacyUuid, UuidCodec.normalize(uuid));
    await engine.stop();
  });

  test('sightings sort strongest-first', () {
    final engine = ProxBleEngine(radio: FakeBleRadio());
    engine.handleSighting(
        challengeSighting([1, 1, 1, 1, 1, 1, 1, 1], rssi: -80));
    engine.handleSighting(
        challengeSighting([2, 2, 2, 2, 2, 2, 2, 2], rssi: -55));
    expect(engine.byRssiDesc.first.rssiDbm, -55);
  });

  test('stop() never kills a scan started after it (prof→student race)',
      () async {
    final radio = _SlowStopRadio();
    final engine = ProxBleEngine(radio: radio);
    await engine.startScanning();
    final stopping = engine.stop(); // trailing stopScanning is slow
    await engine.startScanning(); // next screen re-scans immediately
    await stopping;
    // The fresh scan survived: sightings still dispatch.
    engine.handleSighting(challengeSighting([9, 9, 9, 9, 9, 9, 9, 9]));
    expect(
        await engine.nextChallenge(timeout: const Duration(seconds: 1)),
        [9, 9, 9, 9, 9, 9, 9, 9]);
    await engine.stop();
  });

  test('scan deferred while BT off restarts when BT powers on', () async {
    // The reported bug: prompt-era Turn-on came too late — the initState
    // scan had already failed "bluetooth not enabled" and nothing ever
    // re-armed it. Opt-in callers now defer instead of dying.
    final radio = _BtToggleRadio();
    final engine = ProxBleEngine(radio: radio);
    var btOn = false;
    engine.radioReady = () async => btOn;
    await engine.startScanning(deferIfNotReady: true); // must NOT throw
    expect(engine.scanPending, isTrue);
    expect(radio.scanning, isFalse);
    btOn = true; // user taps Turn on (or enables via Settings)
    radio.powered = true;
    expect(await engine.retryPendingScan(), isTrue);
    expect(engine.scanPending, isFalse);
    expect(radio.scanning, isTrue);
    await engine.stop();
  });

  test('deferred scan self-polls back without any UI call', () async {
    final radio = _BtToggleRadio();
    final engine = ProxBleEngine(radio: radio);
    engine.scanRetryInterval = const Duration(milliseconds: 10);
    var btOn = false;
    engine.radioReady = () async => btOn;
    await engine.startScanning(deferIfNotReady: true);
    expect(engine.scanPending, isTrue);
    btOn = true; // enabled via Settings: no prompt result fires
    radio.powered = true;
    for (var i = 0; i < 100 && !radio.scanning; i++) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    expect(radio.scanning, isTrue);
    expect(engine.scanPending, isFalse);
    await engine.stop();
  });

  test('scan failure without defer opt-in still throws', () async {
    final radio = _BtToggleRadio();
    final engine = ProxBleEngine(radio: radio);
    engine.radioReady = () async => false;
    expect(() => engine.startScanning(), throwsStateError);
    expect(engine.scanPending, isFalse);
    await engine.stop();
  });

  test('real radio errors never defer (gate says on)', () async {
    final radio = _FailRadio();
    final engine = ProxBleEngine(radio: radio);
    engine.radioReady = () async => true;
    expect(() => engine.startScanning(deferIfNotReady: true),
        throwsStateError);
    expect(engine.scanPending, isFalse);
    await engine.stop();
  });

  test('failed scan start stays watchdog-visible (dead scan heals)',
      () async {
    // Same one-shot-death class, student side: a non-defer scan failure
    // used to leave no timestamp, so the silence watchdog treated the
    // dead scan as "never requested" and nothing ever re-armed it. The
    // request itself now stamps the clock; once the stack settles the
    // watchdog revives the scan with no UI call.
    final radio = _FlakyScanRadio();
    final engine = ProxBleEngine(radio: radio);
    engine.radioReady = () async => true;
    expect(() => engine.startScanning(deferIfNotReady: true),
        throwsStateError);
    expect(engine.scanPending, isFalse);
    radio.fail = false; // BT stack settles after the first-run transient
    expect(await engine.restartScanIfSilent(Duration.zero), isTrue);
    expect(radio.scanning, isTrue);
    await engine.stop();
  });

  test('explicit stop drops a pending scan (no resurrection)', () async {
    final radio = _BtToggleRadio();
    final engine = ProxBleEngine(radio: radio);
    var btOn = false;
    engine.radioReady = () async => btOn;
    await engine.startScanning(deferIfNotReady: true);
    expect(engine.scanPending, isTrue);
    await engine.stop(); // user left / round over: deferral consumed
    btOn = true;
    expect(await engine.retryPendingScan(), isFalse);
    expect(radio.scanning, isFalse);
  });
}

/// Radio whose legacy advertise blocks until released: pins the ADV
/// guard while a relay op is in flight.
class _GateRadio extends FakeBleRadio {
  Completer<void>? gate;
  @override
  Future<void> startLegacyUuid(String uuid128) async {
    final g = gate;
    if (g != null) await g.future;
    return super.startLegacyUuid(uuid128);
  }
}

/// Radio whose stopScanning is slow, to interleave stop() with a
/// re-scan the way prof-teardown races student-init on navigation.
class _SlowStopRadio extends FakeBleRadio {
  @override
  Future<void> stopScanning() async {
    await Future.delayed(const Duration(milliseconds: 200));
    return super.stopScanning();
  }
}

/// Radio whose scan stack is down until BT powers on — the reported
/// "scan failed: bluetooth not enabled" case. Tests flip [powered]
/// together with the [ProxBleEngine.radioReady] gate.
class _BtToggleRadio extends FakeBleRadio {
  bool powered = false;
  @override
  Future<void> startScanning(void Function(BleSighting s) onSight) {
    if (!powered) throw StateError('bluetooth not enabled');
    return super.startScanning(onSight);
  }
}

/// Radio whose scan stack is broken regardless of BT state.
class _FailRadio extends FakeBleRadio {
  @override
  Future<void> startScanning(void Function(BleSighting s) onSight) =>
      throw StateError('stack wedged');
}

/// Radio whose scan stack fails until the test flips [fail] (first-run
/// BT transient that settles): the silence watchdog must heal it.
class _FlakyScanRadio extends FakeBleRadio {
  bool fail = true;
  @override
  Future<void> startScanning(void Function(BleSighting s) onSight) {
    if (fail) throw StateError('first-run scan transient');
    return super.startScanning(onSight);
  }
}

/// Radio whose FIRST legacy advertise throws (first-run ADV transient),
/// then behaves: the idle-hint rotation must survive it.
class _FirstTickFailRadio extends FakeBleRadio {
  var _failed = false;

  /// Legacy-ADV attempts (failed first tick + real retry ticks).
  int advertiseCalls = 0;
  @override
  Future<void> startLegacyUuid(String uuid128) {
    advertiseCalls++;
    if (!_failed) {
      _failed = true;
      throw StateError('first-run ADV transient');
    }
    return super.startLegacyUuid(uuid128);
  }
}
