// Web records-build stub for discovery.dart: identical public API, every
// call throws. The web app never announces, listens, or probes (records
// only); this exists so the shared drivers/screens compile for web.
// Native builds use discovery.dart (dart:io UDP). Mirror new shared-code
// members here or the web build fails loudly (by design).
library;

Never _web() =>
    throw UnsupportedError('records-only web build: no LAN discovery');

const kDiscoveryPort = 54545;
const kDiscoveryInterval = Duration(seconds: 2);
const kDiscoveryExpiry = Duration(seconds: 6);
const kDiscoveryMagic = 'PROX1';

const kSessionPersist = Duration(seconds: 120);
const kSessionRefresh = Duration(seconds: 15);
const kSessionMaxFails = 3;

bool hintEntryAlive({
  required DateTime now,
  required DateTime lastSeen,
  DateTime? lastAck,
  int fails = 0,
}) =>
    _web();

class LanAddress {
  final String iface;
  final String addr;
  final bool likelyVpn;
  const LanAddress(this.iface, this.addr, this.likelyVpn);
}

bool isCellularIfaceName(String name) => _web();

/// Minimal beacon target (address only): the shared host driver logs
/// `t.address` per target, so the stub element type carries it.
class BroadcastTarget {
  final String address;
  const BroadcastTarget(this.address);
}

Future<List<BroadcastTarget>> broadcastTargets() => _web();

Future<List<LanAddress>> lanAddressCandidates() => _web();

Future<String> bestLanAddress() => _web();

class ClassAnnouncement {
  final String classLabel;
  final String host;
  final int port;
  final String display;
  final String prof;
  final bool windowOpen;
  final DateTime ts;
  final String org;
  const ClassAnnouncement({
    required this.classLabel,
    required this.host,
    required this.port,
    required this.display,
    required this.prof,
    required this.windowOpen,
    required this.ts,
    this.org = '',
  });

  String get key => '$host:$port';
}

class ClassAnnouncer {
  ClassAnnouncer(ClassAnnouncement Function() current,
      {String? target, List<String>? targets, int port = kDiscoveryPort});

  /// Beacon targets (addresses only — the closure body never runs on web).
  void Function(ClassAnnouncement a, List<dynamic> targets)? onBeacon;
  int beaconCount = 0;

  Future<void> start() => _web();
  Future<void> stop() async {}
}

class LiveClass {
  final ClassAnnouncement last;
  final DateTime firstSeen;
  final DateTime lastSeen;
  const LiveClass(
      {required this.last, required this.firstSeen, required this.lastSeen});
}

class ClassListener {
  void Function()? onChange;
  void Function(ClassAnnouncement a, bool isNew)? onBeacon;

  Future<void> start({int port = kDiscoveryPort}) => _web();

  List<LiveClass> live({DateTime? now}) => const [];

  Future<void> stop() async {}
}

Future<ClassAnnouncement?> probeHost(
  String host,
  int port, {
  Duration timeout = const Duration(milliseconds: 900),
  void Function(String reason)? onMiss,
  bool verboseMisses = false,
}) =>
    _web();
