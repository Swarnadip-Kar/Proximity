// LAN class discovery: professors announce live classes over local WiFi;
// students listen and render a LIVE list. Pure Dart (dart:io UDP).
//
// Announce payload (JSON, ≤512B, broadcast every 2s while hosting):
//   {v:1, class, host, port, display, prof, windowOpen, ts}
// Students dedup by host:port and expire entries unheard for 6s.
// BLE RSSI sorting arrives with the radio slice; LAN entries sort by
// first-seen (stable) until then. Manual IP join stays as fallback.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const kDiscoveryPort = 54545;
const kDiscoveryInterval = Duration(seconds: 2);
const kDiscoveryExpiry = Duration(seconds: 6);
const kDiscoveryMagic = 'PROX1';

class ClassAnnouncement {
  final String classLabel;
  final String host;
  final int port;
  final String display;
  final String prof;
  final bool windowOpen;
  final DateTime ts;
  const ClassAnnouncement({
    required this.classLabel,
    required this.host,
    required this.port,
    required this.display,
    required this.prof,
    required this.windowOpen,
    required this.ts,
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

/// Broadcasts this host's class while it is live. [target] defaults to
/// 255.255.255.255 (inject loopback in tests).
class ClassAnnouncer {
  final ClassAnnouncement Function() _current;
  final InternetAddress _target;
  RawDatagramSocket? _sock;
  Timer? _timer;

  ClassAnnouncer(ClassAnnouncement Function() current,
      {InternetAddress? target})
      : _current = current,
        _target = target ?? InternetAddress('255.255.255.255');

  Future<void> start() async {
    _sock ??= await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _sock!.broadcastEnabled = true;
    _beacon();
    _timer ??=
        Timer.periodic(kDiscoveryInterval, (_) => _beacon());
  }

  void _beacon() {
    try {
      _sock?.send(
          encodeAnnouncement(_current()), _target, kDiscoveryPort);
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

  Future<void> start({int port = kDiscoveryPort}) async {
    _sock ??= await RawDatagramSocket.bind(
        InternetAddress.anyIPv4, port,
        reuseAddress: true, reusePort: true);
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
