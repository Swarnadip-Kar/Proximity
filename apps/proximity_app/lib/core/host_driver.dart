// Professor host driver: two-phase hosting over WiFi + BLE.
//
//   startHosting(label)  -> HTTPS up (closed window) + LAN announce
//                           (windowOpen=false). Students see the class and
//                           wait. No enrollment required: without a device
//                           key the host signs with an ephemeral lecture key
//                           (never uploaded; identity unpinned until the
//                           institute PKI lands).
//   startWindow(n)       -> fresh secrets, BLE advertise+scan, beacons flip
//                           windowOpen=true, students begin proving.
//   stopWindow()         -> window closes, proofs rejected as window-closed,
//                           announce stays (idle), tally kept.
//   endHosting()         -> everything down, tally/session reset.
//
// [FakeHostDriver] mirrors the states with demo marks (tests / UI polish).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_storage/storage.dart';
import 'package:proximity_transport/transport.dart';

import '../features/entry/entry_flow.dart' show entryHostIntegrity;
import 'device_store.dart';
import 'net_if.dart';
import 'platformx.dart' as platformx;
import 'security/revocation_cache.dart';
import 'sync/roles.dart';

class HostSession {
  final String addressLine; // https://<ip>:<port> · ... (initial IP)
  final String hostIp; // the announced IP (changeable via setAnnounceHost)
  final int port;
  final List<String> allIps; // every local IPv4 candidate
  final String displayCode; // '' while merely advertising
  final bool windowOpen;
  const HostSession({
    required this.addressLine,
    required this.hostIp,
    required this.port,
    required this.allIps,
    required this.displayCode,
    required this.windowOpen,
  });

  /// Rebuilt line after the professor picks a different announced IP.
  String lineFor(String ip) => windowOpen
      ? 'https://$ip:$port · Code $displayCode'
      : 'https://$ip:$port · waiting for window';
}

abstract class HostDriver {
  TallyStore get tally;
  bool get isHosting;
  bool get windowLive;
  int get currentWindowNo;
  int get waitingCount;
  List<WaitingRow> get waitingRows;
  List<ManualRow> get manualRows;
  List<ManualRow> get manualPending;
  Future<HostSession> startHosting({required String classLabel, int port = 8443});
  Future<HostSession> startWindow(int windowNo);
  Future<void> stopWindow();

  /// Manual attendance decisions over LAN.
  Future<void> decideManual(String email, bool approve);
  Future<void> addManualEntry(
      {required String email, required String name, String roll = ''});

  /// Professor eject: drops [email] from the waiting list, manual queue,
  /// live tally and dup flags (session-local; saved history is untouched
  /// until the next upsert/snapshot). Returns true when anything was
  /// removed. The student can rejoin/re-mark afterwards (presence is
  /// re-volunteered per join/proof).
  Future<bool> removeStudent(String email);

  /// Publishes the hosting professor's Gmail photo URL to joining
  /// students (gated /window unicast; '' clears). Best-effort: students
  /// converge on the next room poll; absent photo renders as initials.
  Future<void> setHostPhoto(String photoUrl);

  /// Local same-face dup groups (email → matched peer emails, symmetric).
  /// Session-scoped RAM (survives retakes; cleared on endHosting). The
  /// roster renders these as "Duplicate face detected between [A] and
  /// [B]" with a 1-tap override.
  Map<String, Set<String>> get dupGroups;

  /// 1-tap professor override: clears flags for [email] and its whole
  /// group and exempts every pair in the group for the rest of the
  /// session (the professor sees both faces in the room — the human
  /// resolves what the matcher cannot). Never auto-absent: entries keep
  /// their presence.
  Future<void> resolveDupFlag(String email);

  /// Replaces the live tally with persisted draft data (back/app-kill
  /// resume). Window numbering continues from the restored [windowNo].
  Future<void> restoreTally({
    required List<Map<String, bool>> windows,
    required Map<String, String> names,
    Map<String, String> rolls,
    List<int>? windowNos,
  });

  /// Switches the announced/advertised IP (professor picks the right NIC
  /// when several show up, e.g. VPN vs WiFi). Next beacons use it.
  Future<void> setAnnounceHost(String ip);

  /// Re-resolves NICs and heals a stale announce IP (late WiFi DHCP).
  /// Called on window start and by the idle poll while hosting.
  Future<void> refreshAnnounceIps();

  /// Live announce state for UI sync after a refresh.
  String get announceIp;
  List<String> get announceCandidates;

  /// Non-blocking LAN reachability warning from the last startHosting
  /// self-check (null = reachable). The Take screen renders it under the
  /// address line so a firewall-blocked first start is honest, not silent.
  String? get lanSelfCheckWarning;

  /// Updates the professor display name announced with the class.
  Future<void> setDisplayName(String name);
  Future<void> endHosting();
}

class WaitingRow {
  final String email;
  final String name;
  final String roll;

  /// Student's volunteered Gmail photo URL ('' = absent → initials).
  /// Session RAM only, never persisted to records.
  final String photoUrl;
  const WaitingRow(
      {required this.email,
      required this.name,
      this.roll = '',
      this.photoUrl = ''});
}

class ManualRow {
  final String email;
  final String name;
  final String roll;
  final String status;

  /// Same volunteered photo as [WaitingRow.photoUrl].
  final String photoUrl;
  const ManualRow(
      {required this.email,
      required this.name,
      this.roll = '',
      this.status = 'pending',
      this.photoUrl = ''});
}

class RealHostDriver implements HostDriver {
  final DeviceStore _store;
  final ProxBleEngine _engine;

  ProxServer? _server;
  ClassAnnouncer? _announcer;
  String _lastBeaconTargets = '';
  // Local same-face dup groups (session-scoped RAM — see [dupGroups]).
  final Map<String, Set<String>> _dupGroups = {};
  Timer? _scanHold; // post-stop grace: scan lingers AND proofs still
  // accepted (cancelled by retake/end, which own both immediately).

  /// Post-stop grace: the scan lingers for last tokens AND the server
  /// keeps accepting proofs. Tests shrink it.
  Duration scanLinger = const Duration(seconds: 10);

  /// Single-flight guard: concurrent startHosting calls (double-tap,
  /// re-entry) must not interleave server/announcer/engine setup.
  /// Also serializes against fire-and-forget endHosting from dispose:
  /// without this the first startHosting after a quick re-entry binds
  /// port 8443 while the previous HttpServer.close is still in flight
  /// (EADDRINUSE on first tap, success only on the second).
  bool _hostingBusy = false;
  Future<void> _lifecycle = Future.value();

  Future<T> _serial<T>(Future<T> Function() fn) {
    final next = _lifecycle.then((_) => fn());
    // Keep the chain alive across failures; callers still see their error.
    _lifecycle = next.then((_) {}, onError: (_) {});
    return next;
  }
  TallyStore _tally = TallyStore();
  Uint8List? _sessionId;
  ed.KeyPair? _profKeys;
  String _profName = '';
  String _classLabel = '';
  String _announceIp = '';
  List<String> _allIps = const [];

  RealHostDriver({
    required DeviceStore store,
    required ProxBleEngine engine,
  })  : _store = store,
        _engine = engine;

  @override
  TallyStore get tally => _tally;

  /// Test-only reach-in to the live loopback server (port/window for
  /// driving stock-app student marks in integration tests).
  ProxServer? get debugServer => _server;

  @override
  bool get isHosting => _server != null;

  @override
  bool get windowLive => _server?.windowOpen ?? false;

  @override
  int get currentWindowNo => _server?.windowNo ?? 0;

  @override
  int get waitingCount => _server?.waitingCount ?? 0;

  @override
  List<WaitingRow> get waitingRows => [
        for (final w in (_server?.waitingRows ?? const []))
          WaitingRow(
              email: w.email,
              name: w.name,
              roll: w.roll,
              photoUrl: w.photoUrl),
      ];

  @override
  List<ManualRow> get manualRows => [
        for (final m in (_server?.manualRows ?? const []))
          ManualRow(
              email: m.email,
              name: m.name,
              roll: m.roll,
              status: m.status,
              photoUrl: m.photoUrl),
      ];

  @override
  List<ManualRow> get manualPending => [
        for (final m in (_server?.manualPending ?? const []))
          ManualRow(
              email: m.email,
              name: m.name,
              roll: m.roll,
              status: m.status,
              photoUrl: m.photoUrl),
      ];

  @override
  Future<bool> removeStudent(String email) async {
    final key = email.trim().toLowerCase();
    if (key.isEmpty) return false;
    var removed = false;
    try {
      if ((_server?.removeStudent(key) ?? false)) removed = true;
    } catch (_) {}
    // Dup-flag cleanup mirrors resolveDupFlag (presence already dropped
    // with the tally row inside the room).
    final peers = Set<String>.from(_dupGroups[key] ?? const {});
    for (final p in peers) {
      _dupGroups[p]?.remove(key);
      if (_dupGroups[p]?.isEmpty ?? false) _dupGroups.remove(p);
    }
    if (_dupGroups.remove(key) != null) removed = true;
    if (removed) {
      BleLog.log('STATE', 'roster eject $key');
    }
    return removed;
  }

  @override
  Future<void> setHostPhoto(String photoUrl) async {
    try {
      final s = _server;
      if (s != null) s.sessionProfPhoto = photoUrl.trim();
    } catch (_) {}
  }

  /// Matches a recomputed response token against live air sightings.
  /// [expectedAirKey]/[expectedUuid] cover both formats (v2 `type:hex`,
  /// v1 `uuid:`) so mixed fleets interoperate.
  ///
  /// Hop mapping: air packets carry NO TTL byte, so every real sighting
  /// arrives with `ttl == kTtlOriginate` (3) — direct vs relayed is
  /// unknowable on receipt. Map all matches to hop 0 and let the RSSI
  /// gate do the proximity work (a far response never clears -70 dBm at
  /// the professor's antenna; relay tolerance is by design). Mapping
  /// `hop: s.ttl` instead rejects EVERY live prove as `no-ble-sighting`
  /// (3 satisfies neither the `== 0` direct nor the `<= 2` relay branch)
  /// — unit tests hid this by stubbing hop 0.
  static RadioSighting? matchResponse(
      ProxBleEngine engine, String expectedAirKey, String expectedUuid) {
    for (final s in engine.byRssiDesc) {
      if (s.isResponse &&
          (s.key == expectedAirKey || s.key == expectedUuid)) {
        BleLog.log('BLE',
            'response sighting match rssi=${s.rssiDbm} hop=${s.ttl}');
        return RadioSighting(rssiDbm: s.rssiDbm, hop: 0, legacy: s.legacy);
      }
    }
    return null;
  }

  @override
  Future<HostSession> startHosting({required String classLabel, int port = 8443}) {
    return _serial(() async {
      if (_hostingBusy) throw StateError('Already starting hosting.');
      _hostingBusy = true;
      try {
        return await _startHostingInner(classLabel: classLabel, port: port);
      } finally {
        _hostingBusy = false;
      }
    });
  }

  /// Binds the HTTPS server with retries: a quick re-entry after back-nav
  /// (or a lingering OS socket) leaves port 8443 busy for ~hundreds of ms.
  /// Without this the FIRST Take open throws EADDRINUSE and only the second
  /// navigation hosts — the student meanwhile probes a dead hint.
  Future<void> _bindWithRetry(ProxServer server, int port) async {
    Object? lastErr;
    for (var attempt = 1; attempt <= 6; attempt++) {
      try {
        await server.start(port: port);
        return;
      } catch (e) {
        lastErr = e;
        final msg = '$e';
        final busy = msg.contains('Address already in use') ||
            msg.contains('EADDRINUSE') ||
            e is SocketException;
        BleLog.log('NET',
            'HTTPS bind attempt $attempt/6 on $port failed ($e)${busy ? ' — retrying…' : ''}');
        if (!busy || attempt == 6) rethrow;
        // Force any lingering socket closed, then back off briefly.
        try {
          await server.stop();
        } catch (_) {}
        await Future.delayed(Duration(milliseconds: 150 * attempt));
      }
    }
    throw StateError('HTTPS bind failed: $lastErr');
  }

  /// Loopback readiness gate: the socket accepting ≠ TLS serving. Poll
  /// 127.0.0.1/window until it answers 200 (self-signed accepted) so the
  /// BLE IP-hint + UDP beacons below never air before the server actually
  /// answers — students must never probe a "still starting" host.
  Future<void> _awaitHttpsReady(int port) async {
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    Object? lastErr;
    while (DateTime.now().isBefore(deadline)) {
      HttpClient? client;
      try {
        client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
        client.badCertificateCallback = (cert, h, p) => true;
        final req = await client
            .getUrl(Uri(scheme: 'https', host: '127.0.0.1', port: port, path: '/window'))
            .timeout(const Duration(seconds: 1));
        final resp = await req.close().timeout(const Duration(seconds: 1));
        final body =
            await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 1));
        if (resp.statusCode == 200) {
          try {
            jsonDecode(body);
          } catch (_) {}
          return;
        }
        lastErr = StateError('HTTP ${resp.statusCode}');
      } catch (e) {
        lastErr = e;
      } finally {
        try {
          client?.close(force: true);
        } catch (_) {}
      }
      await Future.delayed(const Duration(milliseconds: 150));
    }
    throw StateError('HTTPS not ready on $port: $lastErr');
  }

  Future<HostSession> _startHostingInner(
      {required String classLabel, int port = 8443}) async {
    await _endHostingInner();
    // Security §5 pre-host gate: ADVISORY only — hosting stays
    // offline-capable by law; a tainted professor device logs its verdict
    // hash (tainted-student proves still flag via their own dSig-bound
    // hashes). Never throws by contract; belt-and-braces catch anyway.
    try {
      final hv = await entryHostIntegrity();
      if (hv.flagForMarking.isNotEmpty) {
        BleLog.log('SEC',
            'host integrity flagged (${hv.flagForMarking}) → ${hv.hash} — hosting continues, student verdicts carry their own hashes');
      }
    } catch (_) {}
    // One-time online CRL snapshot refresh (security §2 residual):
    // Firestore-independent HTTPS, best-effort, never blocks hosting
    // (failure degrades to the `revocation-stale` review flag — see
    // core/security/revocation_cache.dart). Hosting stays offline-capable.
    unawaited(RevocationCache.refreshBestEffort());
    final stored = await _store.readEnrollment();
    // Advisory revocation review for the host binding's chain (security §2
    // residual): offline serial-vs-CRL flags, log only — hosting stays
    // offline-capable (fail-open; missing/empty chains keep the existing
    // stale-flag behavior).
    if (stored != null && stored.chainDERHex.isNotEmpty) {
      unawaited(logChainRevocationReview(stored.chainDERHex, 'host'));
    }
    // H10 sealed-only migration (security §2 F1): the raw `seedHex'
    // reader is deleted — hosting NEVER derives the lecture identity from
    // a raw seed. The lecture key is always ephemeral (never uploaded;
    // students verify per-window Cert_p + Sig_p fresh each session), and
    // enrollment truth lives in the HW-sealed envelope (`sealedKeyHex` +
    // `pkDHex` + `chainDERHex`, opened only via the HW DeviceKey on the
    // student path — never opened here). On first sealed open, a legacy
    // doc carrying BOTH sealed + raw is wiped to sealed-only best-effort
    // (raw-only legacy docs are left untouched — readable, never
    // re-written — since wiping them would destroy the only copy).
    if (stored != null &&
        stored.sealedKeyHex.trim().isNotEmpty &&
        stored.seedHex.trim().isNotEmpty) {
      try {
        await _store.writeEnrollment(StoredEnrollment(
          email: stored.email,
          name: stored.name,
          roll: stored.roll,
          // seedHex omitted → '' (sealed-only).
          pkHex: stored.pkHex,
          sealedKeyHex: stored.sealedKeyHex,
          chainDERHex: List<String>.of(stored.chainDERHex),
          faceId: stored.faceId,
          enrolledAt: stored.enrolledAt,
          verifierVer: stored.verifierVer,
          org: stored.org,
          pkDHex: stored.pkDHex,
          attestationLevel: stored.attestationLevel,
          attestedAt: stored.attestedAt,
          attestedUntil: stored.attestedUntil,
          lastFaceRescanAtMillis: stored.lastFaceRescanAtMillis,
        ));
      } catch (_) {
        // Best-effort: hosting continues ephemeral regardless.
      }
    }
    String manual = '';
    try {
      manual = await _store.readHostName();
    } catch (_) {}
    // Ephemeral lecture identity, always (H10): no raw-seed branch, no
    // sealed open on the hosting hot path (unsealing would need a
    // biometric HW gate per Take open). Students verify the per-window
    // Cert_p + Sig_p fresh each session, so a rotating professor key is
    // functionally identical here.
    final kp = ProxCrypto.generateEdKeypair();
    _profKeys = kp;
    try {
      _profName = manual.isNotEmpty
          ? manual
          : (stored?.name ?? manual);
    } catch (_) {
      _profName = manual;
    }
    _classLabel = classLabel;
    _sessionId = randBytes(kSessionIdBytes);
    // Session org = prof org at creation (role cache stamped at sign-in;
    // offline-skipped profs host legacy '' local-only).
    var sessionOrg = '';
    // Session prof email = the hosting professor's account Gmail,
    // lowercased (enrollment record first, role-cache email as fallback;
    // '' = unknown, key omitted). Stamped ONLY on the gated /window
    // unicast (matching/legacy org) — NEVER on UDP beacons (which have no
    // such field by construction) and NEVER on BLE air packets (IP:port
    // only). Student cards render it after the gated fetch.
    var sessionProfEmail = (stored?.email ?? '').trim().toLowerCase();
    try {
      final role = await _store.readRole();
      sessionOrg = roleOrg(role);
      if (sessionProfEmail.isEmpty) {
        sessionProfEmail = (role?['email'] ?? '').trim().toLowerCase();
      }
    } catch (_) {}
    // Rosterless: no roster fetch — students verify with presented device
    // keys (TOFU per class). Whoever proves presence over radio lands in
    // the union.
    _server = ProxServer(
      classLabel: classLabel,
      profSk: _profKeys!.privateKey,
      profPk: _profKeys!.publicKey,
      sightings: ({required peerW, required expectedAirKey, required expectedUuid}) =>
          matchResponse(_engine, expectedAirKey, expectedUuid),
      onProve: (email, decision, reason) {
        BleLog.log('NET', 'prove $email -> $decision ($reason)');
        _applyDupFaceToken(email, reason);
        _applyIntegrityFlag(email, reason);
      },
      tally: _tally,
      sessionOrg: sessionOrg,
      sessionProfEmail: sessionProfEmail,
      // Gated LAN /window name (same channel as the email — never BLE).
      sessionProfName: _profName,
    );
    await _bindWithRetry(_server!, port);
    // Readiness BEFORE any hint/beacon: the port must answer TLS locally.
    // On failure tear the half-started server down so the next attempt
    // (or re-entry) binds clean — never advertise a dead host:port.
    try {
      await _awaitHttpsReady(_server!.port);
    } catch (e) {
      BleLog.log('NET', 'HTTPS readiness FAILED: $e');
      try {
        await _server?.stop();
      } catch (_) {}
      _server = null;
      rethrow;
    }
    _allIps = await _lanIps();
    _announceIp = _allIps.first;
    final ip = _announceIp;
    BleLog.log('NET',
        'HTTPS up on ${_server!.boundAddress}:${_server!.port} (ready)');
    BleLog.log('LAN',
        'announcing as $ip (${_allIps.length} NICs: ${_allIps.join(", ")})');
    BleLog.log('LAN',
        'reachability check: open https://$ip:${_server!.port}/ in a phone browser (accept the self-signed cert once) — page loads = unicast reaches this host');
    // First-start honesty: loopback-ready ≠ LAN-reachable (firewall /
    // wrong NIC). Self-probe the aired IP before students do.
    await _lanSelfCheck(ip, _server!.port);
    // Air format per platform: v2 packets (challenge+IP) where the stack
    // delivers manufacturer data intact (Android/Linux); legacy v1
    // single-UUID ticks alternating challenge and IP-hint where it doesn't
    // (Apple/Windows — students parse all formats, relays preserve them).
    try {
      _engine.legacyTx = !(platformx.isAndroid || platformx.isLinux);
      if (_engine.legacyTx) {
        BleLog.log('BLE', 'legacy v1 TX (challenge + IP-hint ticks)');
      }
    } catch (_) {}
    // BLE air packets carry our HTTPS host:port — students hear the class
    // IP over radio and background-probe it (no LAN broadcasts needed).
    // Loopback is never advertised: students probing 127.0.0.1 would test
    // THEMSELVES and fail — stay undiscoverable-by-radio until a real LAN
    // IP exists (the professor picks one via the all-IP picker).
    if (ip == 'this-device') {
      _engine.clearServerIp();
      BleLog.log('LAN',
          'no LAN IP — connect WiFi and pick the announce address; BLE hint off');
    } else {
      _engine.setServerIp(ip, _server!.port);
    }
    await _announcer?.stop();
    _announcer = ClassAnnouncer(() {
      // Reads fields live so setAnnounceHost / window flips apply to the
      // very next beacon without restarting the announcer.
      final ip = _announceIp;
      return ClassAnnouncement(
        classLabel: _classLabel,
        // Never 127.0.0.1 here: a loopback beacon makes students probe
        // themselves. 'this-device' fails honestly until a LAN IP exists.
        host: ip,
        port: _server?.port ?? 8443,
        display: _server?.window?.displayCode ?? '',
        prof: _profName,
        windowOpen: _server?.windowOpen ?? false,
        ts: DateTime.now().toUtc(),
        org: _server?.sessionOrg ?? '',
      );
    });
    final announcer = _announcer!;
    announcer.onBeacon = (a, targets) {
      // Beacons fire every 2s: log on targets-change (a phone joining the
      // WiFi is immediately visible) else every 10th live / 5th idle, so
      // a long window doesn't drown the terminal. The ring caps history.
      final live = _server?.windowOpen ?? false;
      final key = targets.map((t) => t.address).join(',');
      final nth = announcer.beaconCount % (live ? 10 : 5) == 1;
      if (key != _lastBeaconTargets || nth) {
        _lastBeaconTargets = key;
        BleLog.log('LAN',
            'beacon sent ${a.classLabel}@${a.host}:${a.port} ${a.windowOpen ? "OPEN" : "idle"} → ${targets.length} targets');
      }
    };
    await announcer.start();
    final targets = await broadcastTargets();
    BleLog.log('LAN',
        'broadcast targets: ${targets.map((t) => t.address).join(", ")}');
    // Waiting-room discoverability: UDP beacons are AP-suppressed on
    // isolating networks, so repeat the BLE server-address hint (same
    // packet the round path alternates — challenge-free, nothing provable)
    // until the window starts its challenge rotation.
    try {
      await _engine.startIdleHintRotation();
      BleLog.log('BLE', 'idle IP-hint rotation on (waiting discoverable)');
    } catch (e) {
      BleLog.log('BLE', 'idle hint start FAILED: $e');
    }
    return HostSession(
      addressLine: 'https://$ip:${_server!.port} · waiting for window',
      hostIp: ip,
      port: _server!.port,
      allIps: _allIps,
      displayCode: '',
      windowOpen: false,
    );
  }

  @override
  Future<HostSession> startWindow(int windowNo) async {
    final server = _server;
    final session = _sessionId;
    if (server == null || session == null) {
      throw StateError('Start hosting first.');
    }
    // Heal a stale announce IP (e.g. hosting started on mobile data before
    // WiFi DHCP completed): beacons + BLE air packets below must carry the
    // reachable WiFi address, and the returned session feeds the IP picker.
    await refreshAnnounceIps();
    final window = WindowParams(
      sessionId: session,
      windowId: randBytes(kWindowIdBytes),
      secret: randBytes(kWindowSecretBytes),
      t0: DateTime.now().toUtc(),
      classLabel: _classLabel,
    );
    server.openWindow(window, windowNo);
    BleLog.log('BLE', 'window #$windowNo open code=${window.displayCode}');
    _scanHold?.cancel(); // retake owns the scan from here
    _engine.relayEnabled = false; // professors originate, never relay
    BleLog.log('MESH', 'mesh off (prof originates, never relays)');
    try {
      await _engine.startScanning(deferIfNotReady: true);
    } catch (e) {
      BleLog.log('BLE', 'prof scan start FAILED: $e');
    }
    try {
      await _engine.startProfRotation(window);
      BleLog.log('BLE', 'prof advertising challenges (5s rotation)');
    } catch (e) {
      BleLog.log('BLE', 'prof ADV start FAILED: $e');
      // Half-open cleanup: the window + scan above succeeded, so unwind
      // them before surfacing — never leave a live window with no beacons.
      try {
        server.closeWindow();
      } catch (_) {}
      try {
        await _engine.stopScanOnly();
      } catch (_) {}
      rethrow;
    }
    final ip = _announceIp;
    return HostSession(
      addressLine:
          'https://$ip:${server.port} · Code ${window.displayCode}',
      hostIp: ip,
      port: server.port,
      allIps: _allIps,
      displayCode: window.displayCode,
      windowOpen: true,
    );
  }

  /// Applies an announce-IP switch to the radio hint (loopback blanks it —
  /// see startHosting: students must never probe 127.0.0.1).
  void _applyAnnounceIp(String ip) {
    if (ip == 'this-device') {
      _engine.clearServerIp();
      BleLog.log('LAN', 'BLE hint off (no LAN IP)');
    } else {
      _engine.setServerIp(ip, _server?.port ?? 8443);
    }
  }

  @override
  String get announceIp => _announceIp;

  @override
  List<String> get announceCandidates => List.of(_allIps);

  /// Last LAN self-check failure (null = reachable). Surfaced in the Take
  /// UI as a non-blocking warning: loopback-ready but own-LAN-IP Timeout
  /// means macOS Firewall is dropping inbound (allow the app) or AP client
  /// isolation — students will time out exactly like the student log shows.
  String? lanSelfCheckError;

  @override
  String? get lanSelfCheckWarning => lanSelfCheckError;

  /// Best-effort LAN self-check: GET our own announce IP (not loopback) to
  /// catch OS firewall / wrong-NIC picks on FIRST start. Never throws: a
  /// failure logs AND arms [lanSelfCheckError] for the UI — students would
  /// see the same TimeoutException, so the prof screen must say so instead
  /// of a clean "HTTPS up".
  Future<void> _lanSelfCheck(String ip, int port) async {
    lanSelfCheckError = null;
    if (ip == 'this-device' || ip.startsWith('127.')) return;
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      client.badCertificateCallback = (cert, h, p) => true;
      final req = await client
          .getUrl(Uri(scheme: 'https', host: ip, port: port, path: '/window'))
          .timeout(const Duration(seconds: 2));
      final resp = await req.close().timeout(const Duration(seconds: 2));
      await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 2));
      if (resp.statusCode != 200) {
        lanSelfCheckError =
            'Students on WiFi can\'t reach https://$ip:$port from this Mac (HTTP ${resp.statusCode}) — check Firewall / announce-IP pick, and VPN off (VPNs capture LAN traffic even to your own IP).';
        BleLog.log('NET', 'LAN self-check $ip:$port HTTP ${resp.statusCode} — $lanSelfCheckError');
      }
    } catch (e) {
      final short = e is TimeoutException
          ? 'timed out (SYN dropped: macOS Firewall blocking inbound, or AP client isolation)'
          : '$e';
      lanSelfCheckError =
          'Students on WiFi can\'t reach https://$ip:$port from this Mac itself ($short) — allow incoming connections for this app (System Settings → Network → Firewall), pick another announce IP, or turn VPN off (a VPN tunnel blocks LAN traffic even to your own IP).';
      BleLog.log('NET', 'LAN self-check $ip:$port FAILED ($e) — $lanSelfCheckError');
    } finally {
      try {
        client?.close(force: true);
      } catch (_) {}
    }
  }

  /// Re-resolves local IPs and switches the announce host when the current
  /// one vanished or a better (non-VPN, non-cellular) candidate appeared.
  /// Never overrides an explicit professor pick of a still-present IP —
  /// only heals stale (gone) or mobile-data addresses.
  @override
  Future<void> refreshAnnounceIps() async {
    List<LanAddress> cands;
    try {
      cands = await lanAddressCandidates();
    } catch (_) {
      return;
    }
    if (cands.isEmpty) return;
    final seen = <String>{};
    final ordered = <String>[];
    for (final c in cands) {
      if (seen.add(c.addr)) ordered.add(c.addr);
    }
    _allIps = ordered;
    final best = ordered.first;
    String? switchTo;
    if (!ordered.contains(_announceIp)) {
      switchTo = best;
    } else if (_announceIp != best) {
      final cur = cands.firstWhere((c) => c.addr == _announceIp,
          orElse: () => cands.first);
      final top = cands.first;
      final curBad = cur.likelyVpn || isCellularIfaceName(cur.iface);
      final bestGood =
          !top.likelyVpn && !isCellularIfaceName(top.iface);
      if (curBad && bestGood) switchTo = best;
    }
    if (switchTo != null) {
      final old = _announceIp;
      _announceIp = switchTo;
      BleLog.log('LAN', 'announce IP refreshed $old → $switchTo');
      _applyAnnounceIp(switchTo);
    }
  }

  @override
  Future<void> setAnnounceHost(String ip) async {
    if (_allIps.contains(ip)) {
      _announceIp = ip;
      BleLog.log('LAN', 'announce IP switched to $ip');
      _applyAnnounceIp(ip);
    }
  }

  @override
  Future<void> stopWindow() async {
    BleLog.log('BLE', 'window stopping (rotation off, proofs accepted '
        '${scanLinger.inSeconds}s more)');
    _scanHold?.cancel();
    // Record the round NOW (not after the linger): snapshots taken on the
    // Stop tap must already count this round, or an empty/late-only round
    // vanishes and the intersection still reads 1/1 after 2 rounds.
    // Idempotent (Set) — the grace close re-notes harmlessly. The live
    // window is never noted at OPEN, so the intersection cannot collapse
    // mid-round before anyone marks.
    try {
      final no = _server?.windowNo ?? 0;
      if (no > 0) {
        _tally.noteWindow(no);
        BleLog.log(
            'SESSION', 'round #$no recorded (open rounds: ${_tally.windowNos})');
      }
    } catch (_) {}
    try {
      // Keep scanning: late student responses still arrive for ~seconds
      // after close and must be heard (their POSTs were already sent).
      await _engine.stop(keepScanning: true);
    } catch (_) {}
    // Hosting continues: resume idle hints so the waiting class stays
    // discoverable for the retake (rotation only runs inside windows).
    try {
      await _engine.startIdleHintRotation();
    } catch (_) {}
    try {
      await _engine.startScanning(deferIfNotReady: true);
    } catch (_) {}
    // Grace: the server window stays OPEN for the linger, so proofs
    // already on the wire (or a last rotation token) still mark. Only
    // then does the window hard-close. A retake/end meanwhile cancels
    // this timer and owns the window immediately — so a firing timer
    // always means grace elapsed with no new window: close unconditionally.
    _scanHold = Timer(scanLinger, () async {
      _server?.closeWindow();
      try {
        await _engine.stopScanOnly();
        BleLog.log('BLE', 'post-window grace done (window closed, scan off)');
      } catch (_) {}
    });
    BleLog.log('BLE', 'window stopped (grace running)');
  }

  @override
  Future<void> decideManual(String email, bool approve) async {
    _server?.decideManual(email, approve);
  }

  @override
  Future<void> addManualEntry(
      {required String email, required String name, String roll = ''}) async {
    final key = email.trim().toLowerCase();
    if (key.isEmpty || !key.contains('@')) return;
    // Manual marks land immediately in the current (or first — windows
    // always number from 1) round: the entry is visible at once, drafts
    // capture it, and later rounds intersect honestly.
    final no = _server?.windowNo ?? 0;
    _tally.mark(key, name, no == 0 ? 1 : no, roll: roll);
    _server?.registerWaiting(key, name, roll);
  }

  /// Security §4/§2 host allowlists (mirror the protocol/transport gates —
  /// the per-prove enforcement lives in `ProxServer`/`verifyProve`; these
  /// pin the contract here so allowlist drift fails review/tests, never
  /// marking). `verifierAllowlist` gates `face.verifierVer`,
  /// `livenessAllowlist` + [livenessThreshold] gate `liveness.{score,ver}`
  /// (`>=Tl`, fail-closed `liveness-unbound`/`unknown-liveness-verifier`/
  /// `liveness-below-threshold` in the server). `faceValidAt` freshness
  /// (5-min window) + fresh `dSig` per 5s rotation are likewise server-gated;
  /// NONE proofs confirm only via the logged `device-none-fallback` (never
  /// hard-invalid live marking until HW ships) and tainted proofs ride
  /// `integrity-flagged` into [_applyIntegrityFlag] below (never auto-absent).
  static const List<String> hostVerifierAllowlist = [kVerifierVerPrefix];
  static const List<String> hostLivenessAllowlist = [kLivenessVerPrefix];
  static const double hostLivenessThreshold = kLivenessThreshold;

  /// True when the server's piped `reason` carries the §5 taint flag.
  /// Pure (tests pin it): the flag is machine-readable, never shown; the
  /// roster renders FLAGGED from the tally flag (see [_applyIntegrityFlag]).
  static bool isIntegrityFlaggedReason(String reason) {
    for (final seg in reason.split('|')) {
      if (seg.trim() == 'integrity-flagged') return true;
    }
    return false;
  }

  /// Maps a tainted prove into the roster-visible FLAGGED state WITHOUT
  /// touching presence (never auto-absent offline — the server already
  /// marked confirmed/late; we only add the flag). Invalid proofs plant
  /// nothing ([TallyStore.setFaceFlag] no-ops without a row, same as the
  /// dup path). `device-none-fallback` is deliberately NOT mapped here:
  /// every genuine software-key proof carries it until HW ships, so
  /// flagging it would mark the whole room — it stays a log-line signal
  /// (plus the post-hoc double-pkD audit in `claim.dart`), not a roster flag.
  ///
  /// TOFU note (§2): professor-side pinning is per-class first-seen (no
  /// roster lookup — `studentDevices` denies list + cross-Gmail get, so an
  /// online pre-fetch of other Gmails' pkD+chain is impossible under the
  /// current rules). The chain-vs-pinned-Google-roots + challenge-match
  /// gate runs per prove inside the server; clone pairs surface post-hoc
  /// via `findDoublePkD` on synced bindings (TOFU→pin-check on mismatch
  /// is manual review until a roster source exists). CRL review rides
  /// alongside as advisory flags (`revocation-stale` when the snapshot is
  /// stale/missing, `revocation-revoked` when a chain serial matches a
  /// FRESH snapshot — see `core/security/revocation_cache.dart`
  /// `reviewFlagsForChainHex` + `revocationReviewFlagsForDevice` in
  /// `core/sync/claim.dart`; refreshed at host setup, never blocking) —
  /// same review screen, never auto-absent offline.
  void _applyIntegrityFlag(String email, String reason) {
    if (!isIntegrityFlaggedReason(reason)) return;
    final me = email.trim().toLowerCase();
    if (me.isEmpty) return;
    _tally.setFaceFlag(me);
    BleLog.log('SEC', 'integrity flagged (tainted device, kept present): $me');
  }

  /// Test seam: applies the same flag parsing as the live `onProve`
  /// callback (dup + integrity) without needing a full HTTPS prove round.
  /// The tally must already hold the email (server marks before flagging);
  /// unknown emails no-op, exactly like the live path.
  void applyProveFlagsForTest(String email, String reason) {
    _applyDupFaceToken(email, reason);
    _applyIntegrityFlag(email, reason);
  }

  /// Parses the server's `dupface:a,b` reason token into roster flags +
  /// groups. The token is machine-readable (never shown); the UI renders
  /// neutral copy from [dupGroups]. Unknown/unmarked peers no-op (their
  /// own prove plants the flag symmetrically when it lands).
  void _applyDupFaceToken(String email, String reason) {
    var peers = const <String>[];
    for (final seg in reason.split('|')) {
      if (seg.startsWith('dupface:')) {
        peers = seg
            .substring('dupface:'.length)
            .split(',')
            .map((e) => e.trim().toLowerCase())
            .where((e) => e.isNotEmpty && e != email.toLowerCase())
            .toList();
      }
    }
    if (peers.isEmpty) return;
    final me = email.toLowerCase();
    _tally.setFaceFlag(me);
    final mine = _dupGroups.putIfAbsent(me, () => <String>{});
    for (final p in peers) {
      _tally.setFaceFlag(p);
      mine.add(p);
      _dupGroups.putIfAbsent(p, () => <String>{}).add(me);
    }
    BleLog.log(
        'SEC', 'duplicate face flagged: $me ~ ${peers.join(', ')}');
  }

  @override
  Map<String, Set<String>> get dupGroups => {
        for (final e in _dupGroups.entries) e.key: Set<String>.from(e.value),
      };

  @override
  Future<void> resolveDupFlag(String email) async {
    final me = email.trim().toLowerCase();
    final peers = Set<String>.from(_dupGroups[me] ?? const {});
    for (final p in peers) {
      _server?.exemptFacePair(me, p);
      _tally.clearFaceFlag(p);
      _dupGroups[p]?.remove(me);
      if (_dupGroups[p]?.isEmpty ?? false) _dupGroups.remove(p);
    }
    _tally.clearFaceFlag(me);
    _dupGroups.remove(me);
    BleLog.log('SEC', 'duplicate face resolved by professor: $me');
  }

  @override
  Future<void> restoreTally({
    required List<Map<String, bool>> windows,
    required Map<String, String> names,
    Map<String, String> rolls = const {},
    List<int>? windowNos,
  }) async {
    _tally.restore(
        windows: windows, names: names, rolls: rolls, windowNos: windowNos);
    BleLog.log('SESSION',
        'tally restored: windows ${_tally.windowNos} (${_tally.size} records)');
  }

  @override
  Future<void> setDisplayName(String name) async {
    _profName = name.trim();
    // Live-update the gated /window name mid-hosting (beacons already read
    // _profName live via the announcer closure).
    try {
      final s = _server;
      if (s != null) s.sessionProfName = _profName;
    } catch (_) {}
    try {
      await _store.writeHostName(_profName);
    } catch (_) {}
  }

  @override
  Future<void> endHosting() => _serial(_endHostingInner);

  /// Inner teardown: snapshot + null the live refs SYNCHRONOUSLY before
  /// any await, so a concurrent dispose/start pair can't double-close or
  /// rebind while the old socket is still closing. Only logs 'serve down'
  /// when something was actually hosting (kills the misleading
  /// radio-stop/serve-down lines on every fresh Take open).
  Future<void> _endHostingInner() async {
    _scanHold?.cancel();
    _scanHold = null;
    final announcer = _announcer;
    _announcer = null;
    final server = _server;
    _server = null;
    // Hosting-end vector wipe, EXPLICIT (vectors would die with the server
    // object anyway — this is the audited second teardown path alongside
    // the window-close wipe in ProxServer.closeWindow).
    try {
      server?.clearFaceVectors();
    } catch (_) {}
    _dupGroups.clear();
    final wasHosting = announcer != null || server != null;
    if (announcer != null) {
      try {
        await announcer.stop();
      } catch (_) {}
    }
    try {
      await _engine.stop();
    } catch (_) {}
    try {
      _engine.clearServerIp();
    } catch (_) {}
    if (server != null) {
      try {
        await server.stop();
      } catch (_) {}
    }
    if (wasHosting) {
      BleLog.log('TRANSPORT', 'serve down (hosting ended)');
    }
    _tally = TallyStore();
    _sessionId = null;
    _profKeys = null;
    _profName = '';
    _classLabel = '';
  }

  static Future<List<String>> _lanIps() async {
    // WiFi-first ordering via lanAddressCandidates: VPN/tun interfaces
    // (utun*) are deprioritized so the announced `host` is the reachable
    // LAN IP, not a tunnel address. The professor can still override via
    // the all-IP picker when several NICs show up.
    try {
      final cands = await lanAddressCandidates();
      final out = <String>[];
      for (final c in cands) {
        if (!out.contains(c.addr)) out.add(c.addr);
      }
      if (out.isNotEmpty) return out;
    } catch (_) {}
    try {
      final addrs = await localIPv4Addrs();
      if (addrs.isNotEmpty) return addrs;
    } catch (_) {}
    return const ['this-device'];
  }
}

class FakeHostDriver implements HostDriver {
  TallyStore _tally = TallyStore();
  bool _hosting = false;
  bool _live = false;
  int _windowNo = 0;
  final List<WaitingRow> _waiting = [];
  final List<ManualRow> _manual = [];
  final Map<String, Set<String>> _dupGroups = {};

  @override
  TallyStore get tally => _tally;

  @override
  bool get isHosting => _hosting;

  @override
  bool get windowLive => _live;

  @override
  int get currentWindowNo => _windowNo;

  @override
  int get waitingCount => _waiting.length;

  @override
  List<WaitingRow> get waitingRows => List.of(_waiting);

  @override
  List<ManualRow> get manualRows => List.of(_manual);

  @override
  List<ManualRow> get manualPending =>
      _manual.where((m) => m.status == 'pending').toList();

  @override
  Future<HostSession> startHosting({required String classLabel, int port = 8443}) async {
    _hosting = true;
    _live = false;
    _windowNo = 0;
    return const HostSession(
        addressLine: 'demo · waiting for window',
        hostIp: 'demo',
        port: 8443,
        allIps: ['demo'],
        displayCode: '',
        windowOpen: false);
  }

  @override
  Future<HostSession> startWindow(int windowNo) async {
    _live = true;
    _windowNo = windowNo;
    _tally.mark('student@example.com', 'Student One', windowNo,
        roll: '12342210');
    _tally.mark('student2@example.com', 'Student Two', windowNo, roll: '12342211');
    return const HostSession(
        addressLine: 'demo · Code KQ7',
        hostIp: 'demo',
        port: 8443,
        allIps: ['demo'],
        displayCode: 'KQ7',
        windowOpen: true);
  }

  @override
  Future<void> stopWindow() async {
    // Completed round persists even when empty (mirrors the real server).
    if (_windowNo > 0) _tally.noteWindow(_windowNo);
    _live = false;
  }

  @override
  Future<void> decideManual(String email, bool approve) async {
    final key = email.trim().toLowerCase();
    final idx = _manual.indexWhere((m) => m.email == key);
    if (idx < 0) return;
    final m = _manual[idx];
    _manual[idx] = ManualRow(
        email: m.email,
        name: m.name,
        roll: m.roll,
        status: approve ? 'approved' : 'rejected',
        photoUrl: m.photoUrl);
    if (approve) {
      _tally.mark(key, m.name, _windowNo == 0 ? 1 : _windowNo,
          roll: m.roll, photoUrl: m.photoUrl);
    }
  }

  @override
  Future<void> addManualEntry(
      {required String email,
      required String name,
      String roll = '',
      String photoUrl = ''}) async {
    final key = email.trim().toLowerCase();
    if (key.isEmpty) return;
    // Immediate mark into the current (or first — windows always number
    // from 1) round: visible at once, captured by drafts, intersected
    // honestly by later rounds.
    _tally.mark(key, name, _windowNo == 0 ? 1 : _windowNo,
        roll: roll, photoUrl: photoUrl);
    if (_waiting.every((w) => w.email != key)) {
      _waiting.add(
          WaitingRow(email: key, name: name, roll: roll, photoUrl: photoUrl));
    }
  }

  @override
  Map<String, Set<String>> get dupGroups => {
        for (final e in _dupGroups.entries) e.key: Set<String>.from(e.value),
      };

  @override
  Future<void> resolveDupFlag(String email) async {
    final me = email.trim().toLowerCase();
    final peers = Set<String>.from(_dupGroups[me] ?? const {});
    for (final p in peers) {
      _tally.clearFaceFlag(p);
      _dupGroups[p]?.remove(me);
      if (_dupGroups[p]?.isEmpty ?? false) _dupGroups.remove(p);
    }
    _tally.clearFaceFlag(me);
    _dupGroups.remove(me);
  }

  @override
  Future<bool> removeStudent(String email) async {
    final key = email.trim().toLowerCase();
    if (key.isEmpty) return false;
    var removed = false;
    final w0 = _waiting.length;
    _waiting.removeWhere((w) => w.email == key);
    if (_waiting.length != w0) removed = true;
    final m0 = _manual.length;
    _manual.removeWhere((m) => m.email == key);
    if (_manual.length != m0) removed = true;
    if (_tally.remove(key)) removed = true;
    final peers = Set<String>.from(_dupGroups[key] ?? const {});
    for (final p in peers) {
      _dupGroups[p]?.remove(key);
      if (_dupGroups[p]?.isEmpty ?? false) _dupGroups.remove(p);
    }
    if (_dupGroups.remove(key) != null) removed = true;
    return removed;
  }

  @override
  Future<void> setHostPhoto(String photoUrl) async {}

  /// Test helper: seed a dup group (mirrors the onProve token path).
  void seedDupGroup(String email, List<String> peers) {
    final me = email.trim().toLowerCase();
    _tally.setFaceFlag(me);
    final mine = _dupGroups.putIfAbsent(me, () => <String>{});
    for (final p in peers.map((e) => e.trim().toLowerCase())) {
      _tally.setFaceFlag(p);
      mine.add(p);
      _dupGroups.putIfAbsent(p, () => <String>{}).add(me);
    }
  }

  @override
  Future<void> restoreTally({
    required List<Map<String, bool>> windows,
    required Map<String, String> names,
    Map<String, String> rolls = const {},
    List<int>? windowNos,
  }) async {
    _tally.restore(
        windows: windows, names: names, rolls: rolls, windowNos: windowNos);
  }

  /// Test helper: seed manual queue.
  void seedManual(List<ManualRow> rows) {
    _manual
      ..clear()
      ..addAll(rows);
  }

  @override
  Future<void> setAnnounceHost(String ip) async {}

  @override
  Future<void> refreshAnnounceIps() async {}

  @override
  String get announceIp => 'demo';

  @override
  List<String> get announceCandidates => const ['demo'];

  @override
  String? get lanSelfCheckWarning => null;

  @override
  Future<void> setDisplayName(String name) async {}

  @override
  Future<void> endHosting() async {
    _hosting = false;
    _live = false;
    _windowNo = 0;
    _waiting.clear();
    _manual.clear();
    _dupGroups.clear();
    _tally = TallyStore();
  }
}

final hostDriverProvider = Provider<HostDriver>((ref) {
  throw UnimplementedError('Override in main / tests');
});
