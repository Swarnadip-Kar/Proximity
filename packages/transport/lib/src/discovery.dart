// LAN class discovery: professors announce live classes over local WiFi;
// students listen and render a LIVE list. Pure Dart (dart:io UDP).
//
// Announce payload (JSON, ≤512B, broadcast every 2s while hosting):
//   {v:1, class, host, port, display, prof, profEmail, org, windowOpen, ts}
// Students dedup by host:port and expire entries unheard for 6s.
// BLE RSSI sorting arrives with the radio slice; LAN entries sort by
// first-seen (stable) until then. Manual IP join stays as fallback.
//
// Privacy (explicit product-owner decision, not an oversight): the beacon
// carries the hosting professor's Gmail (professional-contact information,
// lowercased). Any passive LAN listener — including wrong-org devices —
// can learn it. The email rides the LAN broadcast ONLY (never BLE air
// packets, never the cloud record beyond the existing session sync).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';

import 'client.dart';

const kDiscoveryPort = 54545;
const kDiscoveryInterval = Duration(seconds: 2);
const kDiscoveryExpiry = Duration(seconds: 6);
const kDiscoveryMagic = 'PROX1';

/// Known-session persistence (TCP-acked BLE-IP discoveries): once a hinted
/// host answers a unicast HTTPS probe, the class stays listed while the
/// professor app keeps hosting — even after the round (and its BLE rotation)
/// ends. UDP beacons are cheap but AP-suppressed; per-host TCP probes cost
/// one short TLS GET per host per refresh (no sweep), and also return the
/// live window state. Sessions die after [kSessionPersist] without an ack
/// or [kSessionMaxFails] consecutive failed re-probes (professor left).
const kSessionPersist = Duration(seconds: 120);
const kSessionRefresh = Duration(seconds: 15);
const kSessionMaxFails = 3;

/// Lifetime rule for a BLE-hint listing: fresh sightings always live;
/// acked sessions survive radio silence (round over, rotation stopped)
/// until the backstops above fire.
bool hintEntryAlive({
  required DateTime now,
  required DateTime lastSeen,
  DateTime? lastAck,
  int fails = 0,
}) {
  if (now.difference(lastSeen) <= kDiscoveryExpiry) return true;
  if (lastAck == null) return false;
  if (now.difference(lastAck) > kSessionPersist) return false;
  if (fails >= kSessionMaxFails) return false;
  return true;
}

/// Best-effort directed-broadcast guess for an interface address.
/// dart:io exposes no netmask, so RFC1918 hosts assume /24
/// (x.y.z.255); anything else falls back to limited broadcast only.
/// Harmless when wrong (packet goes nowhere); limited broadcast below
/// is always attempted regardless.
/// NOTE: real campus networks are often NOT /24 (this Mac is /18:
/// 10.50.19.107 broadcast 10.50.63.255). See [directedBroadcastGuess16]
/// and [broadcastTargets]: we spray the common masks. Where the AP
/// suppresses broadcasts entirely (verified live: every broadcast
/// variant 0/5), use the BLE IP-hint path or manual IP join instead.
String? directedBroadcastGuess(String addr) {
  // Shared dotted-quad parse (M2 protocol helper); address policy below
  // stays local to discovery.
  final octets = parseIpv4(addr);
  if (octets == null) return null;
  final first = octets[0];
  final private = first == 10 ||
      (first == 172 && octets[1] >= 16 && octets[1] <= 31) ||
      (first == 192 && octets[1] == 168);
  if (!private) return null;
  return '${octets[0]}.${octets[1]}.${octets[2]}.255';
}

/// /16 directed-broadcast guess (x.y.255.255) for the same address.
/// Covers /16..​/18 campuses where the /24 guess is a plain (unassigned)
/// unicast address no host answers. Harmless when wrong.
String? directedBroadcastGuess16(String addr) {
  // Shared dotted-quad parse (M2 protocol helper); address policy below
  // stays local to discovery.
  final octets = parseIpv4(addr);
  if (octets == null) return null;
  final first = octets[0];
  final private = first == 10 ||
      (first == 172 && octets[1] >= 16 && octets[1] <= 31) ||
      (first == 192 && octets[1] == 168);
  if (!private) return null;
  if (addr.startsWith('127.') || addr.startsWith('169.254.')) return null;
  return '${octets[0]}.${octets[1]}.255.255';
}

/// All beacon targets: limited broadcast plus directed guesses per
/// local IPv4 (some APs forward one but drop the other).
Future<List<InternetAddress>> broadcastTargets() async {
  final out = <String>{'255.255.255.255'};
  try {
    final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
    for (final i in ifs) {
      for (final a in i.addresses) {
        if (a.isLoopback) continue;
        final guess = directedBroadcastGuess(a.address);
        if (guess != null && guess != a.address) out.add(guess);
        final guess16 = directedBroadcastGuess16(a.address);
        if (guess16 != null && guess16 != a.address) out.add(guess16);
      }
    }
  } catch (_) {}
  return [for (final s in out) InternetAddress(s)];
}

/// Public alias for callers (e.g. host driver) that need the same
/// cellular-interface judgement used for announce-IP ordering.
bool isCellularIfaceName(String name) => _isCellularIface(name);

/// A local IPv4 candidate with its interface name + VPN guess.
/// VPN/tun interfaces are flagged so callers can deprioritize them:
/// announcing a VPN IP (e.g. utun 10.2.0.2 while WiFi is 10.50.x.x)
/// publishes an unreachable `host` and breaks student joins.
class LanAddress {
  final String iface;
  final String addr;
  final bool likelyVpn;
  const LanAddress(this.iface, this.addr, this.likelyVpn);
}

bool _isLikelyVpnIface(String name) {
  final n = name.toLowerCase();
  return n.startsWith('utun') ||
      n.startsWith('tun') ||
      n.startsWith('ppp') ||
      n.startsWith('ipsec') ||
      n.startsWith('tap') ||
      n == 'pdp_ip0';
}

/// Cellular/mobile-data interfaces (Android rmnet/ccmni, qmap/wwan,
/// clat464, pdp): their 10.x CGNAT addresses are unreachable from WiFi
/// peers, so they must never win the announce `host` while WiFi is up.
/// Live case: hosting started on mobile data (10.148.50.125) before the
/// IITBhilai WiFi DHCP (10.50.37.76) completed, and the stale cellular IP
/// was announced + advertised over BLE until re-hosting.
bool _isCellularIface(String name) {
  final n = name.toLowerCase();
  return n.startsWith('rmnet') ||
      n.startsWith('ccmni') ||
      n.startsWith('qmap') ||
      n.startsWith('wwan') ||
      n.startsWith('clat') ||
      n.startsWith('pdp') ||
      n.startsWith('v4-rmnet') ||
      n.contains('rmnet') ||
      n.contains('mobile') ||
      n.contains('cellular');
}

bool _isPrivateV4(String addr) {
  // Shared dotted-quad parse (M2 protocol helper); policy unchanged.
  final octets = parseIpv4(addr);
  if (octets == null) return false;
  final a = octets[0], b = octets[1];
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
}

/// All usable local IPv4s, WiFi-first: non-VPN private addresses first
/// (wifi interface names boosted), then anything else. Loopback and
/// link-local are dropped.
Future<List<LanAddress>> lanAddressCandidates() async {
  final out = <LanAddress>[];
  try {
    final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
    for (final i in ifs) {
      for (final a in i.addresses) {
        if (a.isLoopback) continue;
        if (a.address.startsWith('169.254.')) continue;
        out.add(LanAddress(i.name, a.address, _isLikelyVpnIface(i.name)));
      }
    }
  } catch (_) {}
  int score(LanAddress c) {
    var s = 0;
    if (!c.likelyVpn) s += 100;
    if (_isCellularIface(c.iface)) s -= 50;
    if (_isPrivateV4(c.addr)) s += 10;
    final n = c.iface.toLowerCase();
    if (n == 'en0' || n == 'wlan0' || n.startsWith('wi-fi') || n == 'wifi0') {
      s += 5;
    }
    return s;
  }
  out.sort((a, b) => score(b).compareTo(score(a)));
  return out;
}

/// Best local address for the announce `host` field: first non-VPN
/// non-cellular private IPv4, else first non-cellular candidate, else
/// first candidate, else loopback.
Future<String> bestLanAddress() async {
  final cands = await lanAddressCandidates();
  for (final c in cands) {
    if (!c.likelyVpn &&
        !_isCellularIface(c.iface) &&
        _isPrivateV4(c.addr)) {
      return c.addr;
    }
  }
  for (final c in cands) {
    if (!_isCellularIface(c.iface)) return c.addr;
  }
  if (cands.isNotEmpty) return cands.first.addr;
  return '127.0.0.1';
}

class ClassAnnouncement {
  final String classLabel;
  final String host;
  final int port;
  final String display;
  final String prof;
  final bool windowOpen;
  final DateTime ts;
  final String org; // prof org domain, '' = legacy beacon
  /// Hosting professor's Gmail, lowercased, '' = legacy beacon without it.
  /// LAN-broadcast by explicit owner decision (see file header) so student
  /// live cards can show professional-contact info.
  final String profEmail;
  const ClassAnnouncement({
    required this.classLabel,
    required this.host,
    required this.port,
    required this.display,
    required this.prof,
    required this.windowOpen,
    required this.ts,
    this.org = '',
    this.profEmail = '',
  });

  String get key => '$host:$port';

  Map<String, dynamic> toJson() => {
        'v': kDiscoveryMagic,
        'class': classLabel,
        'host': host,
        'port': port,
        'display': display,
        'prof': prof,
        'windowOpen': windowOpen,
        'ts': ts.toUtc().toIso8601String(),
        'org': org,
        'profEmail': profEmail,
      };

  static ClassAnnouncement? fromJson(Map<String, dynamic> j) {
    try {
      if (j['v'] != kDiscoveryMagic) return null;
      return ClassAnnouncement(
        classLabel: j['class'] as String,
        host: j['host'] as String,
        port: (j['port'] as num).toInt(),
        display: j['display'] as String? ?? '',
        prof: j['prof'] as String? ?? '',
        windowOpen: j['windowOpen'] as bool? ?? false,
        ts: DateTime.parse(j['ts'] as String),
        org: j['org'] as String? ?? '',
        // Lowercased end to end: the host stamps it lowercased, and beacons
        // from mixed-case senders normalize here so cards compare cleanly.
        profEmail: (j['profEmail'] as String? ?? '').trim().toLowerCase(),
      );
    } catch (_) {
      return null;
    }
  }
}

Uint8List encodeAnnouncement(ClassAnnouncement a) =>
    Uint8List.fromList(utf8.encode(jsonEncode(a.toJson())));

ClassAnnouncement? decodeAnnouncement(Uint8List raw) {
  try {
    return ClassAnnouncement.fromJson(
        jsonDecode(utf8.decode(raw)) as Map<String, dynamic>);
  } catch (_) {
    return null;
  }
}

/// Discovery assumption table (Track 4 §2). NEVER silent: the app logs
/// [discoveryAssumptionLines] on hosting start + browse entry (LAN tag)
/// and renders [formatLadderLine] as a one-line UI status, so a dead
/// enterprise AP reads as an explained state, not an empty list.
///
/// | path | standing | note |
/// | UDP broadcast | advisory-only | cheap 2s beacons; expected DEAD on
/// enterprise APs (measured 0/5 incl. the true /18 broadcast) — never
/// required, never retried harder. |
/// | HTTPS unicast prof↔student | HARD REQUIREMENT | the only path that
/// marks. Blocked => honest `Professor unreachable` + manual-IP + abort. |
/// | BLE hint + unicast probe + typed IP | relied-upon | one probe per
/// hinted host, no sweep (254 rapid probes kicked phones off enterprise
/// WiFi); the hint is unverified, join gates (radio + Sig_p + face)
/// unchanged. |
/// | internet in live flow | never probed | live marking is LAN-only;
/// cloud sync runs before/after class (SyncEngine). |
/// | BLE off | tappable Turn-on | else honest noSignal — never silent. |
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

/// Log-ready rendering of the table (one line per row; the app logs these
/// with the LAN tag on hosting start + browse entry).
List<String> discoveryAssumptionLines() => [
      for (final a in discoveryAssumptions)
        'assume ${a.path}: ${a.standing} — ${a.note}',
    ];

/// Degradation ladder, best first. Shown as a one-line UI status
/// ([formatLadderLine]) and mirrored in the BleLog so the terminal and the
/// screen always agree on which rung the session is on.
const degradationLadder = <String>[
  'BLE hint + probe',
  'typed IP + BLE',
  'LAN manual IP',
  'offline direct manual-add',
];

/// Picks the ladder rung: unicast failure strands marking at offline
/// manual-add; BLE-off drops to LAN manual (Turn-on prompt offered);
/// no hint heard means typed-IP+BLE; hint + probe is the top rung.
int ladderStepFor(
    {required bool bleOn,
    required bool hintHeard,
    required bool unicastOk}) {
  if (!unicastOk) return 3;
  if (!bleOn) return 2;
  if (!hintHeard) return 1;
  return 0;
}

/// One-line ladder status with the active rung bracketed, e.g.
/// `BLE hint + probe → [typed IP + BLE] → LAN manual IP → …`.
String formatLadderLine(int active) => [
      for (var i = 0; i < degradationLadder.length; i++)
        i == active ? '[${degradationLadder[i]}]' : degradationLadder[i],
    ].join(' → ');

/// Broadcasts this host's class while it is live.
/// Targets default to [broadcastTargets] (limited + directed guesses);
/// inject loopback in tests.
///
/// NOTE on isolating APs: enterprise WiFi often drops inter-client
/// broadcasts entirely (verified live 2026-09: all broadcast variants
/// 0/5 incl. the true /18 broadcast). Beacons then never arrive no matter
/// the targets — students use the BLE IP-hint listing or manual IP join
/// (both report through [onBeacon] for the system log).
class ClassAnnouncer {
  final ClassAnnouncement Function() _current;
  final List<InternetAddress>? _targets;
  final int port;

  /// Fired after every beacon send (every [kDiscoveryInterval]).
  void Function(ClassAnnouncement a, List<InternetAddress> targets)? onBeacon;
  int beaconCount = 0;

  RawDatagramSocket? _sock;
  Timer? _timer;

  ClassAnnouncer(ClassAnnouncement Function() current,
      {InternetAddress? target,
      List<InternetAddress>? targets,
      this.port = kDiscoveryPort})
      : _current = current,
        _targets = targets ?? (target == null ? null : [target]);

  Future<void> start() async {
    _sock ??= await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _sock!.broadcastEnabled = true;
    _resolvedTargets ??= _targets ?? await broadcastTargets();
    _beacon();
    _timer ??= Timer.periodic(kDiscoveryInterval, (_) => _beacon());
  }

  List<InternetAddress>? _resolvedTargets;

  void _beacon() {
    final sock = _sock;
    final targets = _resolvedTargets;
    if (sock == null || targets == null) return;
    final cur = _current();
    final raw = encodeAnnouncement(cur);
    for (final t in targets) {
      try {
        sock.send(raw, t, port);
      } catch (_) {}
    }
    beaconCount++;
    try {
      onBeacon?.call(cur, targets);
    } catch (_) {}
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _sock?.close();
    _sock = null;
  }
}

class LiveClass {
  final ClassAnnouncement last;
  final DateTime firstSeen;
  final DateTime lastSeen;
  const LiveClass(
      {required this.last, required this.firstSeen, required this.lastSeen});
}

/// Listens for announcements; prunes entries older than [kDiscoveryExpiry].
class ClassListener {
  final Map<String, LiveClass> _live = {};
  RawDatagramSocket? _sock;
  StreamSubscription<RawSocketEvent>? _sub;
  void Function()? onChange;

  /// Fired for every decodable beacon (for the system log). [isNew] is
  /// true for a previously unseen host:port.
  void Function(ClassAnnouncement a, bool isNew)? onBeacon;

  Future<void> start({int port = kDiscoveryPort}) async {
    // reusePort is unsupported on Android (native E/Dart log
    // "reusePort not supported" even when caught): skip the attempt there
    // instead of try/catch-spamming logcat. Other platforms keep the
    // reusePort attempt with fallback so beacon discovery never dies.
    if (_sock == null) {
      final wantReusePort = !Platform.isAndroid;
      if (wantReusePort) {
        try {
          _sock = await RawDatagramSocket.bind(
              InternetAddress.anyIPv4, port,
              reuseAddress: true, reusePort: true);
        } catch (_) {
          _sock = null;
        }
      }
      _sock ??= await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, port,
          reuseAddress: true);
    }
    _sub ??= _sock!.listen((e) {
      if (e == RawSocketEvent.read) {
        final dg = _sock!.receive();
        if (dg == null) return;
        final a = decodeAnnouncement(dg.data);
        if (a == null) return;
        final now = DateTime.now().toUtc();
        final prev = _live[a.key];
        _live[a.key] = LiveClass(
          last: a,
          firstSeen: prev?.firstSeen ?? now,
          lastSeen: now,
        );
        try {
          onBeacon?.call(a, prev == null);
        } catch (_) {}
        onChange?.call();
      }
    });
  }

  /// Currently live classes, oldest first-seen first (stable order).
  /// Only classes with an open window are joinable; idle advertisers
  /// (windowOpen=false) are still listed but greyed by the UI.
  List<LiveClass> live({DateTime? now}) {
    final n = (now ?? DateTime.now()).toUtc();
    _live.removeWhere((_, v) => n.difference(v.lastSeen) > kDiscoveryExpiry);
    final out = _live.values.toList()
      ..sort((a, b) => a.firstSeen.compareTo(b.firstSeen));
    return out;
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _sock?.close();
    _sock = null;
  }
}

/// Probes one host's HTTPS /window (self-signed host cert accepted).
/// Returns an announcement when a Proximity host answers, else null.
/// Single-host unicast only: used for BLE IP-hint probes (one cheap GET
/// per hinted host:port). There is deliberately no subnet sweep — 254
/// rapid probes have kicked phones off enterprise WiFi; discovery is
/// passive (UDP beacons + BLE hints) plus typed IP.
/// [onMiss] receives the failure reason (surfaced to the system log;
/// connection-refused on empty hosts is normal and stays quiet unless
/// [verboseMisses] is set).
Future<ClassAnnouncement?> probeHost(
  String host,
  int port, {
  Duration timeout = const Duration(milliseconds: 900),
  void Function(String reason)? onMiss,
  bool verboseMisses = false,
}) async {
  final client = ProxClient(host: host, port: port);
  String? err;
  try {
    final r = await client
        .probeWindow(timeout: timeout, onError: (e) => err = '$e')
        .timeout(timeout + const Duration(seconds: 2));
    if (!r.reachable) {
      onMiss?.call(err == null ? '$host unreachable' : '$host: $err');
      return null;
    }
    return ClassAnnouncement(
      classLabel: r.classLabel.isEmpty ? 'Class at $host' : r.classLabel,
      host: host,
      port: port,
      display: '',
      prof: '',
      windowOpen: r.windowOpen,
      ts: DateTime.now().toUtc(),
      org: r.org,
      profEmail: r.profEmail,
    );
  } catch (e) {
    onMiss?.call('$host: $e');
    return null;
  } finally {
    client.close();
  }
}
