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

// Mirrored pure data (Track 4 §2 assumption table + ladder): identical
// values to discovery.dart, no dart:io — the records UI renders the same
// one-line status on web.
class DiscoveryAssumption {
  final String path;
  final String standing;
  final String note;
  const DiscoveryAssumption(this.path, this.standing, this.note);
}

const discoveryAssumptions = <DiscoveryAssumption>[
  DiscoveryAssumption('UDP broadcast', 'advisory-only',
      'Cheap 2s beacons; expected DEAD on enterprise APs — never required.'),
  DiscoveryAssumption('HTTPS unicast prof<->student', 'HARD REQUIREMENT',
      'The only path that marks; blocked = honest Professor unreachable + manual-IP + abort.'),
  DiscoveryAssumption('BLE hint + unicast probe + typed IP', 'relied-upon',
      'One probe per hinted host, no sweep; hint unverified, join gates unchanged.'),
  DiscoveryAssumption(
      'internet in live flow', 'never probed', 'Live marking is LAN-only.'),
  DiscoveryAssumption('BLE off', 'tappable Turn-on',
      'Else honest noSignal — never a silent empty list.'),
];

List<String> discoveryAssumptionLines() => [
      for (final a in discoveryAssumptions)
        'assume ${a.path}: ${a.standing} — ${a.note}',
    ];

const degradationLadder = <String>[
  'BLE hint + probe',
  'typed IP + BLE',
  'LAN manual IP',
  'offline direct manual-add',
];

int ladderStepFor(
    {required bool bleOn,
    required bool hintHeard,
    required bool unicastOk}) {
  if (!unicastOk) return 3;
  if (!bleOn) return 2;
  if (!hintHeard) return 1;
  return 0;
}

String formatLadderLine(int active) => [
      for (var i = 0; i < degradationLadder.length; i++)
        i == active ? '[${degradationLadder[i]}]' : degradationLadder[i],
    ].join(' → ');

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
