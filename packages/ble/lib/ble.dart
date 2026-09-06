// BLE engine: identical air bytes on every OS (§5.2, §6.1, §6.2).
//
// Over-the-air format (v2, see protocol/air.dart): fixed 16-bit service
// UUID [kAirSvc] + manufacturer payload (company [kAirCompanyId]):
// magic 'PX', ver, type (challenge/response), token(8B), ipv4(4B),
// port BE16. 29B total in the PRIMARY advertisement packet on every
// platform — no scan-response dependence, no per-OS packet layout.
//
// Platform mapping (outside this pure-Dart core):
//  - scan/connect: `universal_ble` (Android/iOS/macOS/Windows/Linux),
//    filtered on [kAirSvc]
//  - advertise: `universal_ble` peripheral (Android/iOS/macOS/Windows)
//  - Linux advertise: BlueZ LEAdvertisingManager1 D-Bus shim (same bytes)
//  - GATT: PROX_SVC/PROX_CHR read/write/notify + CCCD, MTU 517,
//    autoConnect=false, ≥5s between scan restarts.
//
// This file holds the OS-independent core: rotation schedule, sighting store,
// relay admission (delegates to protocol FloodController), RSSI thresholds.
// A [BlePlatformDelegate] injects the actual radio; fakes drive P0 tests.
library proximity_ble;

export 'src/bluez.dart' if (dart.library.html) 'src/bluez_stub.dart';
export 'src/ble_log.dart';

import 'dart:async';
import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';

import 'src/ble_log.dart';

/// Observed air packet: v2 (FCD2 service + manufacturer payload) or
/// legacy v1 (single rotating 128-bit UUID, challenge in low bytes).
class BleSighting {
  final int type; // kAirTypeChallenge | kAirTypeResponse
  final Uint8List token8;
  final String ipHost; // HTTPS server ('' when unknown, e.g. v1 sightings)
  final int ipPort; // 0 when unknown
  final bool legacy; // true = v1 128-bit-UUID packet (Apple-TX compatible)
  final String? legacyUuid; // normalized UUID when [legacy]
  final Uint8List? peerW; // 8B alias when present (response path)
  final int rssiDbm;
  final DateTime at;
  /// Relay budget left. Air packets carry no TTL byte, so direct
  /// sightings default to [kTtlOriginate]; an explicit 0 means TTL spent
  /// (never relay). The [_relayed] set still bounds each packet to one
  /// re-advertise per device (storm guard).
  final int ttl;
  final String? ingressLink;
  BleSighting({
    required this.type,
    required this.token8,
    this.ipHost = '',
    this.ipPort = 0,
    this.legacy = false,
    this.legacyUuid,
    required this.rssiDbm,
    required this.at,
    this.peerW,
    this.ttl = kTtlOriginate,
    this.ingressLink,
  }) : assert(token8.length == 8);

  bool get isChallenge => type == kAirTypeChallenge;
  bool get isResponse => type == kAirTypeResponse;
  bool get isIpHint => type == kAirTypeIpHint;
  bool get hasServer => ipHost.isNotEmpty && ipPort > 0;

  /// Dedup / split-horizon key, format-aware.
  String get key => legacy
      ? 'uuid:${legacyUuid ?? ''}'
      : '$type:${token8.map((e) => e.toRadixString(16).padLeft(2, '0')).join()}';

  /// Short token for logs.
  String get shortToken =>
      token8.sublist(0, 4).map((e) => e.toRadixString(16).padLeft(2, '0')).join();

  /// Human log label: server address for IP hints (whose token bytes are
  /// unused), short token otherwise.
  String get label => isIpHint && hasServer ? '$ipHost:$ipPort' : '${shortToken}…';
}

/// Platform radio contract. Implementations per OS share this interface.
/// v2 air packets go through [startAirPacket] (fixed 16-bit [kAirSvc] +
/// 18B manufacturer payload, 29B primary packet everywhere). Legacy v1
/// single-UUID packets (challenge in UUID low bytes, Apple-TX compatible)
/// go through [startLegacyUuid]. Students parse both; relays preserve the
/// heard format so mixed fleets interoperate.
abstract class BlePlatformDelegate {
  Future<void> startAirPacket(String airServiceUuid, Uint8List airMfg,
      {List<int>? scanResponse});
  Future<void> startLegacyUuid(String uuid128);
  Future<void> stopAdvertising();
  Future<void> startScanning(void Function(BleSighting s) onSight);
  Future<void> stopScanning();
  Future<Uint8List?> gattRead(
      String deviceId, String serviceUuid, String charUuid);
  Future<void> gattWrite(String deviceId, String serviceUuid,
      String charUuid, Uint8List value);
  String get platformName;
}

/// Fake radio for tests / P0 Android↔Android loop without hardware.
class FakeBleRadio implements BlePlatformDelegate {
  @override
  String get platformName => 'fake';
  String? advertisingSvc;
  Uint8List? advertisingMfg;
  String? advertisingLegacyUuid;
  void Function(BleSighting s)? _onSight;

  /// Test aid: whether a scan callback is currently armed.
  bool get scanning => _onSight != null;
  final List<(String, String, Uint8List)> gattWrites = [];

  /// Loop injected sightings to peer radios via test harness.
  void inject(BleSighting s) => _onSight?.call(s);

  @override
  Future<void> startAirPacket(String airServiceUuid, Uint8List airMfg,
      {List<int>? scanResponse}) async {
    advertisingSvc = airServiceUuid;
    advertisingMfg = airMfg;
    advertisingLegacyUuid = null;
  }

  @override
  Future<void> startLegacyUuid(String uuid128) async {
    advertisingLegacyUuid = uuid128;
    advertisingSvc = null;
    advertisingMfg = null;
  }

  @override
  Future<void> stopAdvertising() async {
    advertisingSvc = null;
    advertisingMfg = null;
    advertisingLegacyUuid = null;
  }

  @override
  Future<void> startScanning(void Function(BleSighting s) onSight) async {
    _onSight = onSight;
  }

  @override
  Future<void> stopScanning() async => _onSight = null;

  @override
  Future<Uint8List?> gattRead(
          String deviceId, String serviceUuid, String charUuid) async =>
      null;

  @override
  Future<void> gattWrite(String deviceId, String serviceUuid,
          String charUuid, Uint8List value) async =>
      gattWrites.add((serviceUuid, charUuid, value));
}

/// Rotation + relay core. Drives [BlePlatformDelegate] on 5s ticks.
class ProxBleEngine {
  final BlePlatformDelegate radio;
  final FloodController flood;
  final void Function(BleSighting s)? onChallengeHeard;
  final void Function(BleSighting s)? onResponseHeard;

  /// Fired for every heard professor challenge: students background-probe
  /// the hinted host:port (TCP) and list it when a Proximity server
  /// answers — class discovery with zero LAN broadcasts and zero taps.
  /// The hint itself is unverified; joining still enforces radio +
  /// signature + face gates.
  void Function(String host, int port)? onIpHintHeard;

  final List<BleSighting> sightings = [];
  Timer? _rotTimer;
  int currentJ = 0;
  bool dense = false;
  /// Scan generation: guards the prof→student handoff race. endHosting
  /// awaits engine.stop() while the next screen already re-started the
  /// scan; without this, stop's trailing stopScanning kills the fresh
  /// scan and the student silently hears nothing.
  int _generation = 0;  /// Front-row relay switch. The student driver enables it while listening;
  /// professors never relay (they originate), and it is off otherwise so
  /// re-advertising strictly extends coverage during open windows.
  bool relayEnabled = false;
  final Set<String> _relayed = {}; // packet keys already re-advertised
  String? _ownAdvertising; // split-horizon: never relay what we advertise
  bool _halted = false;

  /// Guards every radio advertise call: a hung peripheral stack must never
  /// wedge the rotation (one log line, then silence — the reported "legacy
  /// TX logged once, per-tick ADV lines never repeat" symptom), and two
  /// overlapping stop/start sequences must not interleave on air.
  bool _advBusy = false;

  /// Max time one advertise call may take before it is abandoned (rotation
  /// ticks continue regardless). Tests shrink this to milliseconds.
  Duration advTimeout = const Duration(seconds: 8);

  /// Runs one advertise op with overlap-skip + hang timeout. Timeouts and
  /// skips are logged (never silent); other errors keep their caller's
  /// semantics (logged + rethrown by [_advertiseProf]).
  /// [rethrowOnTimeout]: true for one-shot calls whose caller reports
  /// failure (rotation start, student response); false for rotation ticks,
  /// which must keep ticking if the radio recovers.
  /// Returns false when the op was SKIPPED (radio busy) — callers that
  /// consume dedup keys (relay) must release them so the next hearing
  /// retries instead of starving.
  Future<bool> _advGuard(Future<void> Function() fn, String what,
      {bool rethrowOnTimeout = true}) async {
    if (_advBusy) {
      BleLog.log('BLE', 'ADV busy, $what skipped');
      return false;
    }
    _advBusy = true;
    try {
      await fn().timeout(advTimeout);
      return true;
    } on TimeoutException {
      BleLog.log('BLE', 'ADV TIMEOUT $what (radio hung?)');
      if (rethrowOnTimeout) rethrow;
      return true;
    } finally {
      _advBusy = false;
    }
  }

  /// Runs one advertise op EXCLUSIVELY: waits (bounded) for an in-flight
  /// op to finish instead of skipping like [_advGuard]. For the student
  /// response, which must precede its POST — a skipped response
  /// guarantees `no-ble-sighting`, and the old skip-then-log-success lied
  /// about it (observed live). Throws on timeout: the caller logs FAILED
  /// honestly and the POST still goes out (the server's sighting grace
  /// may yet save it; otherwise the next rotation proves).
  Future<void> _advExclusive(Future<void> Function() fn, String what,
      {Duration wait = const Duration(seconds: 3)}) async {
    final until = DateTime.now().add(wait);
    while (_advBusy) {
      if (DateTime.now().isAfter(until)) {
        BleLog.log('BLE', 'ADV busy too long, $what ABORTED');
        throw StateError('ADV busy ($what)');
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
    await _advGuard(fn, what);
  }

  /// Our HTTPS server address, advertised in every packet we originate.
  /// Set by the host from its announce IP:port; relays forward the heard
  /// address unchanged so back rows learn the server IP too.
  String _serverHost = '';
  int _serverPort = 8443;

  /// Server address heard in the latest challenge (drives the student
  /// response packet + IP-hint discovery).
  String _heardHost = '';
  int _heardPort = 0;

  /// Format of the latest heard challenge (response echoes it).
  bool _heardLegacy = false;

  /// Sets our server address (clears on unusable input → originate stops).
  void setServerIp(String host, int port) {
    if (packAir(
            type: kAirTypeChallenge,
            token8: Uint8List(8),
            host: host,
            port: port) ==
        null) {
      _serverHost = '';
      BleLog.log('BLE', 'ADV server IP cleared (unusable $host:$port)');
      return;
    }
    _serverHost = host;
    _serverPort = port;
    BleLog.log('BLE', 'ADV server IP set → $host:$port');
  }

  void clearServerIp() => _serverHost = '';

  ProxBleEngine({
    required this.radio,
    FloodController? flood,
    this.onChallengeHeard,
    this.onResponseHeard,
  }) : flood = flood ?? FloodController();

  /// Injected radio-readiness gate (app layer wires BT power state).
  /// Null = unknown: scan failures keep their old throw semantics, so
  /// tests and gateless callers see zero behavior change.
  Future<bool> Function()? radioReady;

  /// Retry cadence while a deferred scan waits for the radio. Tests shrink.
  Duration scanRetryInterval = const Duration(seconds: 2);

  /// A scan start deferred because the radio was off: restarted by
  /// [retryPendingScan] (polled automatically) once the radio is back.
  /// Set only by opt-in callers ([startScanning] with deferIfNotReady).
  bool _scanPending = false;
  bool get scanPending => _scanPending;
  Timer? _pendingTimer;
  bool _retryBusy = false;

  Future<void> startScanning({bool deferIfNotReady = false}) async {
    _generation++;
    _halted = false;
    // A requested scan is watchdog-visible from the call, not from first
    // success: a non-defer failure (real stack error, gate says on) used
    // to leave _scanStartAt null, so restartScanIfSilent treated the dead
    // scan as "never requested" and nothing ever re-armed it.
    _scanStartAt = DateTime.now().toUtc();
    BleLog.log('BLE', 'scan start (filter $kAirSvc)');
    try {
      await radio.startScanning(handleSighting);
      BleLog.log('BLE', 'scan started via ${radio.platformName}');
      _scanStartAt = DateTime.now().toUtc();
      _dropPendingScan();
    } catch (e) {
      BleLog.log('BLE', 'scan start FAILED: $e');
      if (deferIfNotReady && await _radioDown()) {
        _deferScan();
        return;
      }
      rethrow;
    }
  }

  /// True when the gate reports the radio off. Unknown gate, gate errors,
  /// or non-off states (on/unavailable) count as ready — deferral is only
  /// for the certain off case, never for sims/desktops or real failures.
  Future<bool> _radioDown() async {
    final g = radioReady;
    if (g == null) return false;
    try {
      return !(await g());
    } catch (_) {
      return false;
    }
  }

  void _deferScan() {
    _scanPending = true;
    BleLog.log('BLE', 'scan deferred (radio off — restarts when enabled)');
    _pendingTimer?.cancel();
    _pendingTimer =
        Timer.periodic(scanRetryInterval, (_) => _pollPendingScan());
  }

  void _dropPendingScan() {
    _scanPending = false;
    _pendingTimer?.cancel();
    _pendingTimer = null;
  }

  Future<void> _pollPendingScan() async {
    if (!_scanPending || _retryBusy) return;
    _retryBusy = true;
    try {
      await retryPendingScan();
    } finally {
      _retryBusy = false;
    }
  }

  /// Restarts a deferred scan once the radio is back. No-op (false) when
  /// nothing is pending or the radio is still off — the poll keeps
  /// watching. True when a scan is active afterwards. An explicit [stop]
  /// consumes the deferral, so a dead screen can never resurrect a scan.
  Future<bool> retryPendingScan() async {
    if (!_scanPending) return false;
    if (await _radioDown()) return false;
    _dropPendingScan();
    try {
      await startScanning();
      BleLog.log('BLE', 'scan restarted (radio back on)');
      return true;
    } catch (_) {
      if (await _radioDown()) _deferScan(); // died mid-retry: re-arm
      return false;
    }
  }

  /// Restarts an already-expected scan without touching anything else
  /// (relay arming, halted state, deferrals all preserved — unlike
  /// [stop], which tears the role down). The driver calls this after a
  /// quiet spell while listening: platform stacks die silently while
  /// reporting active (observed live: zero sightings for minutes with an
  /// open window on air), and only a fresh start revives them. Never
  /// throws; false means the radio itself is broken (logged).
  Future<bool> restartScan({bool quiet = false}) async {
    _generation++;
    try {
      try {
        await radio.stopScanning().timeout(advTimeout);
      } catch (_) {}
      await radio.startScanning(handleSighting);
      _scanStartAt = DateTime.now().toUtc();
      _dropPendingScan();
      if (!quiet) BleLog.log('BLE', 'scan restarted via ${radio.platformName}');
      return true;
    } catch (e) {
      BleLog.log('BLE', 'scan restart FAILED: $e');
      return false;
    }
  }

  /// Last time any sighting dispatched (any type). Browse uses it to tell
  /// a dead platform scan from a quiet room (see [restartScanIfSilent]).
  DateTime? _lastSightAt;
  DateTime? get lastSightAt => _lastSightAt;
  DateTime? _lastWatchdogRestart;
  // Challenge-channel clock: challenges + IP-hints move it, responses and
  // junk do not. The watchdog keys on THIS — own response echoes or radio
  // noise must never mask a dead challenge channel (the exact "zero
  // challenges for minutes with an open window" failure).
  DateTime? _lastChallengeAt;
  DateTime? _scanStartAt;

  /// Re-arms the scan when no challenge-channel packet has been heard for
  /// [silence] — at most one restart per [silence] window, quietly. A
  /// truly quiet room costs one cheap restart per window; a dead scan
  /// heals on its own without any screen needing its own timer. Returns
  /// true when a restart ran.
  Future<bool> restartScanIfSilent(Duration silence) async {
    // An explicit stop() wins over the watchdog: never resurrect a scan
    // the role tore down (halted screens own their radio state).
    if (_halted) return false;
    final now = DateTime.now().toUtc();
    final ref = _lastChallengeAt ?? _scanStartAt;
    // No scan ever started (or clock unknown): nothing to re-arm, and no
    // instant restart storm on first browse either.
    if (ref == null) return false;
    if (now.difference(ref) < silence) return false;
    if (_lastWatchdogRestart != null &&
        now.difference(_lastWatchdogRestart!) < silence) {
      return false;
    }
    _lastWatchdogRestart = now;
    return restartScan(quiet: true);
  }

  Future<void> stop({bool keepScanning = false}) async {
    final gen = _generation;
    _halted = true;
    _dropPendingScan(); // explicit stop wins over a deferral
    _relayed.clear();
    relayEnabled = false; // role reset: students re-arm on next scan start,
    // so a stale arm can never leak into professor (originate-only) mode.
    _settleChallengeWaiters(null); // wake listeners as noSignal, no danglers
    _rotTimer?.cancel();
    stopIdleHintRotation();
    _advBusy = false; // a wedged advertise must not jam the next round
    BleLog.log(
        'BLE', keepScanning ? 'radio stop (adv off, scan held)' : 'radio stop (adv+scan off)');
    try {
      await radio.stopAdvertising().timeout(advTimeout);
    } catch (_) {}
    // A newer startScanning (next screen) wins over this trailing stop:
    // never kill a scan that began after stop() did.
    if (!keepScanning && gen == _generation) {
      try {
        await radio.stopScanning().timeout(advTimeout);
      } catch (_) {}
    } else if (!keepScanning) {
      BleLog.log('BLE', 'stop skipped scan-off (rescanned, gen $gen→$_generation)');
    }
  }

  /// Stops scanning only (advertising untouched): ends a post-window
  /// scan linger without silencing idle hints. Never throws.
  Future<void> stopScanOnly() async {
    _generation++;
    _dropPendingScan();
    try {
      await radio.stopScanning().timeout(advTimeout);
    } catch (_) {}
  }

  /// Professor: rotate challenge token C_j every 5s for as long as the
  /// window is open (j=0,1,2… unbounded — the window closes only when the
  /// professor stops it, never on a clock). Rotation stops with [stop];
  /// the host keeps accepting proofs briefly afterwards (grace), so a
  /// token heard on the last tick still marks.
  Future<void> startProfRotation(WindowParams window) async {
    stopIdleHintRotation(); // challenge rotation replaces idle hints
    currentJ = 0;
    await _advGuard(() => _advertiseProf(window, 0), 'prof j=0');
    _rotTimer?.cancel();
    _rotTimer = Timer.periodic(
        const Duration(seconds: kSubEpochSeconds), (t) async {
      final j = t.tick;
      currentJ = j;
      await _advGuard(() => _advertiseProf(window, j), 'prof j=$j',
          rethrowOnTimeout: false);
    });
  }

  /// Waiting-room (idle hosting) rotation: repeats the SAME server-address
  /// hint packet the round path alternates — same bytes, same student
  /// parse/probe/list/relay handling, on every platform (Apple-safe lone
  /// UUID, no wire change). Carries NO challenge, so nothing is provable
  /// from it: students discover the class and join the waiting room, and
  /// proving still needs a live window's rotating C_j + Sig_p + face.
  /// Reads [_serverHost]/[_serverPort] live each tick, so IP-picker
  /// changes apply within one tick.
  ///
  /// Self-healing by construction: the retry timer is armed BEFORE the
  /// first tick, and a failed first tick only logs. (Before: one `await`
  /// on the first tick meant ANY first-run failure — BT just turned on,
  /// transient stack error, permission settling — threw before the timer
  /// existed and silenced idle hints for the whole hosting session. The
  /// class then appeared only when Start's challenge rotation advertised
  /// the IP — the reported "first run shows nothing, Start lists
  /// instantly" bug.)
  Timer? _hintTimer;

  Future<void> startIdleHintRotation() async {
    _rotTimer?.cancel(); // idle hints never overlap challenge rotation
    _hintTimer?.cancel();
    // NOTE: the tick calls [_advertiseIdleHint] DIRECTLY (never wrapped in
    // another _advGuard): it already guards itself, and a nested guard
    // re-enters busy — the inner call skips and reports success, so the
    // retry tick advertises nothing (the old shape of this timer).
    _hintTimer = Timer.periodic(
        const Duration(seconds: kSubEpochSeconds), (_) async {
      try {
        await _advertiseIdleHint();
      } catch (e) {
        BleLog.log('BLE', 'idle hint tick FAILED (retrying on tick): $e');
      }
    });
    try {
      await _advertiseIdleHint();
    } catch (e) {
      BleLog.log('BLE', 'idle hint first tick FAILED (retrying on tick): $e');
    }
  }

  void stopIdleHintRotation() {
    _hintTimer?.cancel();
    _hintTimer = null;
  }

  Future<void> _advertiseIdleHint() async {
    final uuid = UuidCodec.packIpHint(_serverHost, _serverPort);
    if (uuid == null) {
      BleLog.log('BLE', 'ADV idle-hint SKIPPED (no server IP set)');
      return;
    }
    _ownAdvertising = 'uuid:${UuidCodec.normalize(uuid)}';
    try {
      await _advGuard(() async {
        await radio.stopAdvertising();
        await radio.startLegacyUuid(uuid);
      }, 'idle hint');
      BleLog.log('BLE',
          'ADV idle-hint ${_serverHost}:${_serverPort} via ${radio.platformName}');
    } catch (e) {
      BleLog.log('BLE', 'ADV idle-hint FAILED: $e');
      rethrow;
    }
  }

  /// Transmit format for originated packets. v2 air packets carry the
  /// server IP (fast auto-discovery); legacy v1 single-UUID ticks alternate
  /// challenge and server-address hint (Apple-TX compatible —
  /// CoreBluetooth displaces attached manufacturer data where Android
  /// can't read it, but a lone UUID always arrives). Students parse all
  /// formats; relays preserve the heard format. Set by the host per
  /// platform (Android/Linux: v2; Apple/Windows: legacy).
  bool legacyTx = false;

  Future<void> _advertiseProf(WindowParams window, int j) async {
    final cj = window.challengeFor(j);
    if (legacyTx) {
      // Odd ticks carry the server address so Apple-originated classes
      // are joinable with zero taps (challenge ticks stay full-strength
      // crypto — C_j is never truncated).
      if (j.isOdd) {
        final uuid = UuidCodec.packIpHint(_serverHost, _serverPort);
        if (uuid == null) {
          BleLog.log('BLE', 'ADV ip-hint v1 j=$j SKIPPED (no server IP set)');
          return;
        }
        _ownAdvertising = 'uuid:${UuidCodec.normalize(uuid)}';
        try {
          await radio.stopAdvertising();
          await radio.startLegacyUuid(uuid);
          BleLog.log('BLE',
              'ADV ip-hint v1 j=$j ${_serverHost}:${_serverPort} via ${radio.platformName}');
        } catch (e) {
          BleLog.log('BLE', 'ADV ip-hint j=$j FAILED: $e');
          rethrow;
        }
        return;
      }
      final uuid = UuidCodec.packChallenge(cj);
      _ownAdvertising = 'uuid:${UuidCodec.normalize(uuid)}';
      try {
        await radio.stopAdvertising();
        await radio.startLegacyUuid(uuid);
        BleLog.log('BLE',
            'ADV challenge v1 j=$j uuid=${BleLog.shortUuid(uuid)}… via ${radio.platformName}');
      } catch (e) {
        BleLog.log('BLE', 'ADV challenge j=$j FAILED: $e');
        rethrow;
      }
      return;
    }
    if (_serverHost.isEmpty) {
      BleLog.log('BLE', 'ADV challenge j=$j SKIPPED (no server IP set)');
      return;
    }
    final mfg = packAir(
        type: kAirTypeChallenge,
        token8: cj,
        host: _serverHost,
        port: _serverPort)!;
    _ownAdvertising = _airKey(kAirTypeChallenge, cj);
    try {
      await radio.stopAdvertising();
      await radio.startAirPacket(kAirSvc, mfg);
      BleLog.log('BLE',
          'ADV challenge j=$j tok=${_hex4(cj)}… via ${radio.platformName}');
    } catch (e) {
      BleLog.log('BLE', 'ADV challenge j=$j FAILED: $e');
      rethrow;
    }
  }

  /// Student: advertise response token R_IDj once C_j known, in the format
  /// of the heard challenge (v1 heard → v1 UUID_S response). The v2 packet
  /// echoes the heard server address (professors ignore it; relays of
  /// challenges preserve the original).
  Future<void> advertiseStudentResponse(
      String studentId, Uint8List challenge, int j, Uint8List peerW) async {
    final rid = ProxCrypto.responseToken(challenge, studentId);
    if (_heardLegacy) {
      final uuid = UuidCodec.packResponse(rid);
      _ownAdvertising = 'uuid:${UuidCodec.normalize(uuid)}';
      try {
        await _advExclusive(() async {
          await radio.stopAdvertising();
          await radio.startLegacyUuid(uuid);
        }, 'response v1 j=$j');
        BleLog.log('BLE',
            'ADV response v1 j=$j uuid=${BleLog.shortUuid(uuid)}… via ${radio.platformName}');
      } catch (e) {
        BleLog.log('BLE', 'ADV response FAILED: $e');
        rethrow;
      }
      return;
    }
    if (_heardHost.isEmpty) {
      BleLog.log('BLE', 'ADV response SKIPPED (no server heard yet)');
      return;
    }
    final mfg = packAir(
        type: kAirTypeResponse,
        token8: rid,
        host: _heardHost,
        port: _heardPort)!;
    _ownAdvertising = _airKey(kAirTypeResponse, rid);
    try {
      await _advExclusive(() async {
        await radio.stopAdvertising();
        await radio.startAirPacket(kAirSvc, mfg, scanResponse: peerW);
      }, 'response j=$j');
      BleLog.log('BLE',
          'ADV response j=$j tok=${_hex4(rid)}… via ${radio.platformName}');
    } catch (e) {
      BleLog.log('BLE', 'ADV response FAILED: $e');
      rethrow;
    }
  }

  /// Incoming sighting: log RSSI, fire callbacks, relay challenges w/ flood controls.
  ///
  /// Routine repeats are silent: the same packet arrives every second
  /// (professor ticks, our own relay echo), so only a NEW packet key logs.
  /// Repetitions still dispatch to callbacks and the relay storm guard —
  /// only the log line is gated.
  String _lastLoudChallenge = '';
  String _lastLoudHint = '';
  String _lastLoudResponse = '';
  bool _loud(String key, int slot) {
    final last = switch (slot) {
      0 => _lastLoudChallenge,
      1 => _lastLoudHint,
      _ => _lastLoudResponse,
    };
    if (key == last) return false;
    switch (slot) {
      case 0:
        _lastLoudChallenge = key;
      case 1:
        _lastLoudHint = key;
      default:
        _lastLoudResponse = key;
    }
    return true;
  }

  void handleSighting(BleSighting s) {
    sightings.add(s);
    _lastSightAt = DateTime.now().toUtc();
    if (s.isChallenge) {
      _lastChallengeAt = _lastSightAt;
      _heardHost = s.ipHost;
      _heardPort = s.ipPort;
      _heardLegacy = s.legacy;
      final loud = _loud(s.key, 0);
      if (loud) {
        BleLog.log('BLE',
            'RX challenge ${s.legacy ? 'v1' : 'v2'} tok=${s.shortToken}… rssi=${s.rssiDbm} ttl=${s.ttl}');
      }
      if (s.hasServer) {
        if (loud) BleLog.log('BLE', 'IP hint → ${s.ipHost}:${s.ipPort}');
        try {
          onIpHintHeard?.call(s.ipHost, s.ipPort);
        } catch (_) {}
      }
      // Observer callbacks must never break the radio: an exception here
      // would propagate into the platform scan callback and kill the
      // stream (the silent radio death the watchdog heals).
      try {
        onChallengeHeard?.call(s);
      } catch (_) {}
      _settleChallengeWaiters(Uint8List.fromList(s.token8));
      unawaited(_maybeRelay(s, log: loud));
    } else if (s.isIpHint) {
      // Server-address companion to a v1 challenge (Apple-originated
      // hosts): not radio proof itself, just a routable hint — treated
      // exactly like a v2 IP hint (unverified, join gates unchanged) and
      // relayed so back rows learn the server IP too.
      _lastChallengeAt = _lastSightAt;
      _heardHost = s.ipHost;
      _heardPort = s.ipPort;
      final loud = _loud(s.key, 1);
      if (loud) {
        BleLog.log('BLE',
            'RX ip-hint v1 ${s.ipHost}:${s.ipPort} rssi=${s.rssiDbm} ttl=${s.ttl}');
      }
      if (s.hasServer) {
        try {
          onIpHintHeard?.call(s.ipHost, s.ipPort);
        } catch (_) {}
      }
      unawaited(_maybeRelay(s, log: loud));
    } else if (s.isResponse) {
      final loud = _loud(s.key, 2);
      if (loud) {
        BleLog.log('BLE',
            'RX response tok=${s.shortToken}… rssi=${s.rssiDbm}');
      }
      try {
        onResponseHeard?.call(s);
      } catch (_) {}
    } else {
      BleLog.log('BLE',
          'RX other type=${s.type} rssi=${s.rssiDbm} (ignored)');
    }
  }

  /// Front-row re-advertise of professor packets (controlled flood,
  /// §6.2): unseen packet + TTL left + strong signal + jitter, never what
  /// we already advertise (split horizon), never responses (no flooding).
  /// Both challenge and IP-hint packets relay (back rows need the server
  /// address too); responses travel direct (or directed GATT write) only.
  /// Air packets carry no TTL byte, so direct receptions arrive with
  /// ttl=[kTtlOriginate]; explicit 0 still drops.
  /// [log]: false silences the routine per-repeat lines (same packet heard
  /// every second) — the relay decision itself is unchanged.
  Future<void> _maybeRelay(BleSighting s, {bool log = true}) async {
    // Relay disarmed (professor mode, or radio off) is a steady state, not
    // an event — return silently so the terminal isn't spammed with skips.
    if (!relayEnabled) return;
    final key = s.key;
    void skip(String why) {
      if (log) BleLog.log('MESH', 'relay skip ($why) ${s.label}');
    }

    if (s.ttl <= 0) {
      skip('TTL spent');
      return;
    }
    if (s.rssiDbm <= kRssiRelayMinDbm) {
      skip('weak rssi=${s.rssiDbm}');
      return;
    }
    if (key == _ownAdvertising) {
      skip('split-horizon/own');
      return;
    }
    if (!_relayed.add(key)) {
      skip('dup');
      return; // unseen only (storm guard)
    }
    if (_relayed.length > 64) _relayed.remove(_relayed.first);
    if (log) {
      BleLog.log('MESH', 'forwarding to mesh ${s.label} jitter→re-ADV');
    }
    await Future.delayed(
        FloodController.relayJitter(dense: dense));
    if (_halted) {
      if (log) BleLog.log('MESH', 'relay aborted (halted) ${s.label}');
      return;
    }
    try {
      final bool aired;
      if (s.legacy && s.legacyUuid != null) {
        aired = await _advGuard(
            () => radio.startLegacyUuid(s.legacyUuid!), 'relay ${s.label}');
      } else {
        final mfg = packAir(
            type: s.type, token8: s.token8, host: s.ipHost, port: s.ipPort)!;
        aired = await _advGuard(
            () => radio.startAirPacket(kAirSvc, mfg), 'relay ${s.label}');
      }
      if (!aired) {
        // Busy-skip must not burn the token either (see catch below).
        _relayed.remove(key);
        return;
      }
      _ownAdvertising = key;
      if (log) BleLog.log('MESH', 'relayed ${s.label} on air');
    } catch (e) {
      // A skipped/failed air attempt must not burn the token: the next
      // hearing of the same rotation retries (back rows starve otherwise).
      _relayed.remove(key);
      BleLog.log('MESH', 'relay ADV FAILED: $e');
    }
  }

  final List<Completer<Uint8List?>> _challengeWaiters = [];
  final Map<Completer<Uint8List?>, Timer> _challengeTimers = {};
  String _lastLiveHex = '';

  /// Completes every outstanding challenge waiter with [v] and cancels
  /// their timeout timers, so no dangling callbacks survive a radio stop
  /// (or a completed wait).
  void _settleChallengeWaiters(Uint8List? v) {
    for (final w in _challengeWaiters.toList()) {
      if (!w.isCompleted) w.complete(v);
      _challengeTimers.remove(w)?.cancel();
    }
    _challengeWaiters.clear();
  }

  /// Resolves with the next challenge's C_j heard over radio, or null on
  /// [timeout] (dead air — no rotation heard for the whole wait).
  /// Already-heard fresh challenges (≤7s old) resolve immediately so slow
  /// pollers never miss a rotation.
  Future<Uint8List?> nextChallenge(
      {Duration timeout = const Duration(seconds: 31)}) {
    final now = DateTime.now().toUtc();
    for (var i = sightings.length - 1; i >= 0; i--) {
      final s = sightings[i];
      // One-sided freshness (matches WindowParams.isFresh): a sighting
      // timestamped in the future never resolves.
      final age = now.difference(s.at.toUtc());
      if (s.isChallenge &&
          age >= Duration.zero &&
          age < kFreshness) {
        BleLog.log('BLE',
            'heard challenge (cached) tok=${s.shortToken}… rssi=${s.rssiDbm}');
        return Future.value(Uint8List.fromList(s.token8));
      }
    }
    BleLog.log('BLE', 'waiting for challenge over radio…');
    final c = Completer<Uint8List?>();
    _challengeWaiters.add(c);
    _challengeTimers[c] = Timer(timeout, () {
      // Expire ONLY this waiter: completing every waiter here let the
      // shortest timeout kill concurrent longer waits with a spurious
      // noSignal (browse prewarm + listen overlap). Mass-settle stays in
      // _settleChallengeWaiters (radio stop path) only.
      _challengeWaiters.remove(c);
      _challengeTimers.remove(c);
      if (!c.isCompleted) {
        BleLog.log('BLE', 'challenge wait timeout (${timeout.inSeconds}s, noSignal)');
        c.complete(null);
      }
    });
    c.future.then((v) {
      // Same-token echoes (own relay, professor repeat) resolve waiters
      // silently — only a NEW token logs.
      if (v != null) {
        final hex =
            v.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
        if (hex != _lastLiveHex) {
          _lastLiveHex = hex;
          BleLog.log('BLE', 'heard challenge (live) ${v.length}B');
        }
      }
    });
    return c.future;
  }

  /// Strongest-first ordering for nearby-class list UI.
  List<BleSighting> get byRssiDesc {
    final l = List<BleSighting>.of(sightings);
    l.sort((a, b) => b.rssiDbm.compareTo(a.rssiDbm));
    return l;
  }

  void clearSightings() {
    sightings.clear();
    // Round restart: the next token logs fresh even if its key matches.
    _lastLoudChallenge = '';
    _lastLoudHint = '';
    _lastLoudResponse = '';
    _lastLiveHex = '';
  }

  static String _airKey(int type, Uint8List token) =>
      '$type:${token.map((e) => e.toRadixString(16).padLeft(2, '0')).join()}';

  static String _hex4(Uint8List token) => token
      .sublist(0, 4)
      .map((e) => e.toRadixString(16).padLeft(2, '0'))
      .join();
}
