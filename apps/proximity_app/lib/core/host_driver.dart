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

import 'dart:io';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_storage/storage.dart';
import 'package:proximity_transport/transport.dart';

import 'device_store.dart';
import 'roster_repo.dart';

class HostSession {
  final String addressLine; // https://<ip>:<port> · Code XXX (live only)
  final String displayCode; // '' while merely advertising
  final bool windowOpen;
  const HostSession({
    required this.addressLine,
    required this.displayCode,
    required this.windowOpen,
  });
}

abstract class HostDriver {
  TallyStore get tally;
  bool get isHosting;
  bool get windowLive;
  Future<HostSession> startHosting({required String classLabel});
  Future<HostSession> startWindow(int windowNo);
  Future<void> stopWindow();

  /// Updates the professor display name announced with the class.
  Future<void> setDisplayName(String name);
  Future<String> signExport(String csv);
  Future<void> endHosting();
}

class RealHostDriver implements HostDriver {
  final DeviceStore _store;
  final RosterRepository _repo;
  final ProxBleEngine _engine;

  ProxServer? _server;
  ClassAnnouncer? _announcer;
  TallyStore _tally = TallyStore();
  Uint8List? _sessionId;
  ed.KeyPair? _profKeys;
  String _profName = '';
  String _classLabel = '';

  RealHostDriver({
    required DeviceStore store,
    required RosterRepository repo,
    required ProxBleEngine engine,
  })  : _store = store,
        _repo = repo,
        _engine = engine;

  @override
  TallyStore get tally => _tally;

  @override
  bool get isHosting => _server != null;

  @override
  bool get windowLive => _server?.windowOpen ?? false;

  @override
  Future<HostSession> startHosting({required String classLabel}) async {
    await endHosting();
    final stored = await _store.readEnrollment();
    String manual = '';
    try {
      manual = await _store.readHostName();
    } catch (_) {}
    if (stored == null) {
      // No device key: ephemeral lecture identity (never uploaded).
      final kp = ProxCrypto.generateEdKeypair();
      _profKeys = kp;
      _profName = manual;
    } else {
      final seed = hexDecode(stored.seedHex);
      final sk = ed.newKeyFromSeed(seed);
      _profKeys = ed.KeyPair(sk, ed.public(sk));
      _profName = manual.isNotEmpty ? manual : stored.name;
    }
    _classLabel = classLabel;
    _sessionId = randBytes(kSessionIdBytes);
    final keys = await _repo.fetchKeysCached();
    final studentKeys = <String, ed.PublicKey>{};
    for (final e in keys.entries) {
      try {
        studentKeys[e.key] = ed.PublicKey(hexDecode(e.value.pkHex));
      } catch (_) {
        // Skip malformed key records; CRL/admin cleanup handles them.
      }
    }
    final crl = await _repo.fetchCrlCached();
    _server = ProxServer(
      classLabel: classLabel,
      profSk: _profKeys!.privateKey,
      profPk: _profKeys!.publicKey,
      studentKeys: studentKeys,
      revokedPkHex: crl,
      sightings: ({required peerW, required expectedResponseUuid}) {
        // Match the recomputed response UUID against live radio sightings.
        for (final s in _engine.byRssiDesc) {
          if (s.isResponse &&
              UuidCodec.normalize(s.uuid) ==
                  UuidCodec.normalize(expectedResponseUuid)) {
            return RadioSighting(rssiDbm: s.rssiDbm, hop: s.ttl);
          }
        }
        return null;
      },
      tally: _tally,
    );
    await _server!.start();
    final ip = await _lanIp();
    await _announcer?.stop();
    _announcer = ClassAnnouncer(() => ClassAnnouncement(
          classLabel: _classLabel,
          host: ip == 'this-device' ? '127.0.0.1' : ip,
          port: _server?.port ?? 8443,
          display: _server?.window?.displayCode ?? '',
          prof: _profName,
          windowOpen: _server?.windowOpen ?? false,
          ts: DateTime.now().toUtc(),
        ));
    await _announcer!.start();
    return HostSession(
      addressLine: 'https://$ip:${_server!.port} · waiting for window',
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
    final window = WindowParams(
      sessionId: session,
      windowId: randBytes(kWindowIdBytes),
      secret: randBytes(kWindowSecretBytes),
      t0: DateTime.now().toUtc(),
      classLabel: _classLabel,
    );
    server.openWindow(window, windowNo);
    _engine.relayEnabled = false; // professors originate, never relay
    await _engine.startScanning();
    await _engine.startProfRotation(window);
    final ip = await _lanIp();
    return HostSession(
      addressLine:
          'https://$ip:${server.port} · Code ${window.displayCode}',
      displayCode: window.displayCode,
      windowOpen: true,
    );
  }

  @override
  Future<void> stopWindow() async {
    try {
      await _engine.stop();
    } catch (_) {}
    _server?.closeWindow();
  }

  @override
  Future<void> setDisplayName(String name) async {
    _profName = name.trim();
    try {
      await _store.writeHostName(_profName);
    } catch (_) {}
  }

  @override
  Future<String> signExport(String csv) async {
    final kp = _profKeys;
    if (kp == null) throw StateError('Not hosting.');
    return hexEncode(
        ProxCrypto.sign(kp.privateKey, ProxCrypto.sha256Sync(csv.codeUnits)));
  }

  @override
  Future<void> endHosting() async {
    await _announcer?.stop();
    _announcer = null;
    try {
      await _engine.stop();
    } catch (_) {}
    await _server?.stop();
    _server = null;
    _tally = TallyStore();
    _sessionId = null;
    _profKeys = null;
    _profName = '';
    _classLabel = '';
  }

  static Future<String> _lanIp() async {
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final i in ifs) {
        for (final a in i.addresses) {
          if (!a.isLoopback) return a.address;
        }
      }
    } catch (_) {}
    return 'this-device';
  }
}

class FakeHostDriver implements HostDriver {
  TallyStore _tally = TallyStore();
  bool _hosting = false;
  bool _live = false;

  @override
  TallyStore get tally => _tally;

  @override
  bool get isHosting => _hosting;

  @override
  bool get windowLive => _live;

  @override
  Future<HostSession> startHosting({required String classLabel}) async {
    _hosting = true;
    _live = false;
    return const HostSession(
        addressLine: 'demo · waiting for window',
        displayCode: '',
        windowOpen: false);
  }

  @override
  Future<HostSession> startWindow(int windowNo) async {
    _live = true;
    _tally.mark('aarav@institute.ac.in', 'Aarav S', windowNo,
        roll: '12342210');
    _tally.mark('diya@institute.ac.in', 'Diya R', windowNo, roll: '12342211');
    return const HostSession(
        addressLine: 'demo · Code KQ7',
        displayCode: 'KQ7',
        windowOpen: true);
  }

  @override
  Future<void> stopWindow() async => _live = false;

  @override
  Future<void> setDisplayName(String name) async {}

  @override
  Future<String> signExport(String csv) async => '00' * 64;

  @override
  Future<void> endHosting() async {
    _hosting = false;
    _live = false;
    _tally = TallyStore();
  }
}

final hostDriverProvider = Provider<HostDriver>((ref) {
  throw UnimplementedError('Override in main / tests');
});
