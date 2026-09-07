// Student flow: manual join (IP shown by professor; BLE discovery lands
// with the radio slice) → real face scan → 30s listening radar → signed
// ACK. Foreground-required; backgrounding pauses. Identical Android/iOS.
//
// Layout contract: this screen owns discovery/waiting/proving orchestration
// and composes the mark feature sections (browse, join-by-IP, waiting
// room, face check, proving, verdict, manual status) — one section per
// file under lib/features/mark/. Waiting → scan → verdict is wrapped in
// [MarkFlowShell] so it reads as ONE continuation (AnimatedSwitcher with
// the screen-level emphasized curve, no hard cuts, no BLE/radar/verdict
// info dumps). Behavior is unchanged from the pre-split screen; only the
// rendering moved.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_transport/transport.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/ble_radio.dart';
import '../core/device_store.dart';
import '../core/student_driver.dart';
import '../design/tokens.dart';
import '../features/debug/debug_log_screen.dart';
import '../features/enrollment/enroll_flow.dart';
import '../features/mark/browse_classes.dart';
import '../features/mark/face_check.dart';
import '../features/mark/manual_status.dart';
import '../features/mark/mark_flow.dart';
import '../features/mark/mark_phase.dart';
import '../features/mark/proving_view.dart';
import '../features/mark/verdict_view.dart';
import '../features/mark/waiting_room.dart';
import '../features/records/my_attendance_screen.dart';
import '../main.dart';
import '../mode.dart';
import 'face_capture.dart';

// Mark phases live in the mark-flow section; re-exported here so existing
// imports keep resolving StudentPhase from this screen.
export '../features/mark/mark_phase.dart' show StudentPhase;

/// UDP discovery port (injectable so tests avoid clashing with a running app).
final discoveryPortProvider = Provider<int>((_) => kDiscoveryPort);

class StudentHomeScreen extends ConsumerStatefulWidget {
  const StudentHomeScreen({super.key});

  @override
  ConsumerState<StudentHomeScreen> createState() => _StudentHomeScreenState();
}

class _StudentHomeScreenState extends ConsumerState<StudentHomeScreen>
    with WidgetsBindingObserver {
  StudentPhase phase = StudentPhase.browsing;
  String listenStatus = '';
  String ackDetail = '';
  // Marks collected this join, oldest first ('R1 · KQ7 · 10:04:12'):
  // the waiting room shows the per-round trail, and the rewait uses the
  // count for the next round label. Cleared on every fresh join.
  final List<String> _roundMarks = [];
  String infoDetail = '';
  String joinError = '';
  String _typedHostPort = '';
  String _fieldInitial = '';
  int _fieldNonce = 0;
  final _listener = ClassListener();
  List<LiveClass> _live = [];
  ClassBeacon? _waitingTarget;
  int _runId = 0;
  // Waiting-room state (req 1): connection status + prof-triggered advance.
  bool _connected = false;
  bool _roomWindowOpen = false;
  String _roomClass = '';
  // Consecutive unreachable room polls: hosting ended under a waiter
  // (End attendance stops the professor server) vs a network blip.
  int _roomMisses = 0;
  Timer? _roomPoll;
  Timer? _presenceBeat;
  Timer? _manualPoll;
  String _manualStatus = '';
  // Instant face retries used this join (4 mismatch sessions, then review).
  int _faceAttempts = 0;
  // Automatic re-scans after unreadable verdicts (bounded; Cancel exits).
  int _autoFaceTries = 0;
  // Samsung-style auto-start guard: the scan fires once per faceCheck
  // entry (post-frame); the manual button stays as fallback/retry.
  bool _autoFaceFired = false;
  // Transient verdict note on the face-check screen (inconclusive scans).
  String faceNotice = '';

  // BLE-hint listings (professor host:port heard over radio, probed once,
  // listed on answer). Merged with broadcast beacons in [_allLive].
  final Map<String, LiveClass> _hints = {};
  // BLE IP-hint throttle: one background probe per hinted host:port per 10s.
  final Map<String, DateTime> _bleHintThrottle = {};
  // Known sessions: hinted hosts that ANSWERED a TCP probe stay listed
  // while the professor app hosts (round over ≠ session over — rotation
  // stops but HTTPS still acks). [key] → last ack time / consec failures.
  final Map<String, DateTime> _sessionAck = {};
  final Map<String, int> _sessionFails = {};
  // Pending hints: heard over BLE but the first probe missed (professor
  // HTTPS still starting). Retried by the heartbeat until they answer or
  // age out — never silently dropped after one miss.
  final Map<String, DateTime> _pendingHints = {};
  // Live-refresh: recompute the merged list every 2s so classes that
  // stopped advertising disappear on their 6s expiry without any tap.
  Timer? _refreshTimer;
  // Session heartbeat: re-probe acked sessions every 15s so a listed class
  // tracks the live window state (and dead hosts age out) with zero taps.
  Timer? _sessionTimer;
  // One-shot hint retries (3s fast retry when the prof HTTPS is still
  // starting). Tracked so dispose cancels them — no post-dispose probes.
  final List<Timer> _hintRetryTimers = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listener.onBeacon = (a, isNew) {
      BleLog.log(ProxLogTags.lan,
          'beacon ${isNew ? "new" : "heard"} ${a.classLabel}@${a.host}:${a.port} ${a.windowOpen ? "OPEN" : "idle"}');
    };
    _listener.onChange = () {
      if (!mounted) return;
      final live = _allLive();
      // Auto-advance: the professor opened the window we are waiting for.
      // The waiting room flips to face check with no new taps (camera opens
      // on the next step); radio was pre-warmed at join for speed (req 1).
      final waiting = _waitingTarget;
      if (phase == StudentPhase.waiting && waiting != null) {
        // Backup advance only on DIRECTLY confirmed servers: _allLive can
        // briefly carry a stale OPEN flag (flipped closed on the next
        // failed heartbeat), and advancing on it face-scans an ended class.
        final flipped = _connected &&
            live.any((c) =>
                '${c.last.host}:${c.last.port}' ==
                    '${waiting.host}:${waiting.port}' &&
                c.last.windowOpen);
        if (flipped) {
          BleLog.log(ProxLogTags.lan,
              'window OPEN seen for ${waiting.host}:${waiting.port} → face check');
          _advanceToFace(waiting);
          return;
        }
        if (mounted) setState(() => _live = live);
        return;
      }
      if (phase == StudentPhase.browsing) {
        setState(() => _live = live);
      }
    };
    _listener.start(port: ref.read(discoveryPortProvider));
    _loadLastHost();
    // BLE IP-hint discovery: scan continuously while browsing; any
    // professor HTTPS hint heard over radio is background-probed and
    // listed when it answers. No verification of the hint itself — the
    // join still enforces radio + signature + face gates.
    // Every student also relays: like bitchat, each node re-advertises
    // heard challenges (flood-controlled), so back rows hear the class
    // through front rows with zero taps.
    // Permission FIRST: scanning without BLUETOOTH_SCAN/CONNECT throws on
    // Android 12+. The prompt surfaces on entry (not mid-join); a denial
    // skips the scan quietly and join re-asks via the join gates.
    try {
      final engine = ref.read(bleEngineProvider);
      engine.onIpHintHeard = _onBleIpHint;
      engine.relayEnabled = true;
      BleLog.log(ProxLogTags.mesh, 'mesh on (student relay armed)');
      Future(() async {
        var ok = true;
        try {
          ok = await ref.read(blePermissionProvider)();
        } catch (_) {
          ok = false;
        }
        if (!mounted) return;
        if (!ok) {
          BleLog.log(ProxLogTags.ble,
              'scan held for Bluetooth permission (join re-asks)');
          return;
        }
        try {
          await engine.startScanning(deferIfNotReady: true);
        } catch (_) {}
      });
    } catch (_) {}
    // Live refresh heartbeat: expiry pruning + waiting-flip checks run on
    // every tick, so entries vanish ~6s after their last sighting and
    // newly opened windows advance without taps. Local recompute only —
    // no network scan of any kind (enterprise APs have kicked phones off
    // WiFi under probe load; discovery is passive: UDP beacons + BLE
    // hints + typed IP).
    _refreshTimer?.cancel();
    // Serialized: Timer.periodic does not await the body, so a slow tick
    // (watchdog restart) overlapping the next tick ran _allLive + setState
    // concurrently. One tick at a time; overruns skip, never pile up.
    var refreshBusy = false;
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted || refreshBusy) return;
      refreshBusy = true;
      try {
        if (phase == StudentPhase.browsing) {
          final live = _allLive();
          if (_liveKeys(live) != _liveKeys(_live)) {
            setState(() => _live = live);
          }
          // Browse scan watchdog: a platform scan can die silently while
          // reporting active (observed live: hints stop for minutes, class
          // never lists). 30s with zero sightings → one quiet re-arm; a
          // truly quiet room costs nothing more.
          try {
            await ref
                .read(bleEngineProvider)
                .restartScanIfSilent(const Duration(seconds: 30));
          } catch (_) {}
        } else if (phase == StudentPhase.waiting && _waitingTarget != null) {
          final waiting = _waitingTarget!;
          // Same stale-OPEN guard as the beacon advance above: the direct
          // 2s room poll owns waiting→face, this is only its backup.
          final flipped = _connected &&
              _allLive().any((c) =>
                  '${c.last.host}:${c.last.port}' ==
                      '${waiting.host}:${waiting.port}' &&
                  c.last.windowOpen);
          if (flipped) {
            BleLog.log(ProxLogTags.lan,
                'window OPEN seen for ${waiting.host}:${waiting.port} → face check');
            _advanceToFace(waiting);
          }
        }
      } finally {
        refreshBusy = false;
      }
    });
    // Session heartbeat (TCP, unicast, cheap): re-ack known sessions so
    // the list survives the round end. One short GET per host per 15s —
    // never a sweep. Other phases run their own probes; browse only here.
    _sessionTimer?.cancel();
    _sessionTimer =
        Timer.periodic(kSessionRefresh, (_) => _refreshSessions());
    // Bluetooth off is otherwise a log-only failure: prompt once, up
    // front, with a tappable Turn-on.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) promptEnableBluetoothIfOff(context, ref);
    });
  }

  static String _liveKeys(List<LiveClass> live) =>
      live.map((c) => '${c.last.key}:${c.last.windowOpen}').join(',');

  Future<void> _loadLastHost() async {
    // Last joined IP pre-fills the field (nothing to re-tap): it opens
    // exactly where the last class left off. Also background-probe it
    // once: on first open (fresh install, radios quiet) this lists the
    // class even before any beacon or BLE hint arrives.
    try {
      final last = await ref.read(deviceStoreProvider).readLastHost();
      if (mounted && last != null && last.isNotEmpty) {
        setState(() {
          _fieldInitial = last;
          _typedHostPort = last;
        });
        final slash = last.lastIndexOf(':');
        if (slash > 0) {
          final port = int.tryParse(last.substring(slash + 1).trim()) ?? 0;
          if (port > 0) {
            _onBleIpHint(last.substring(0, slash).trim(), port);
          }
        }
      }
    } catch (_) {}
  }

  /// Tells the professor we left the waiting room (fire-and-forget) so
  /// the waiting count/view drops immediately instead of going stale.
  void _leaveWaitingRoom() {
    final target = _waitingTarget;
    final linked = ref.read(linkedIdentityProvider);
    if (target == null || linked == null) return;
    unawaited(ref
        .read(studentDriverProvider)
        .leaveWaiting(target: target, email: linked.gmail));
  }

  /// BLE IP hint heard (professor HTTPS host:port in scan-response mfg).
  /// Background-probes the hint (throttled) and lists it on answer —
  /// class discovery with zero LAN broadcasts and zero taps.
  ///
  /// Early-join race: the hint can arrive while the professor's HTTPS is
  /// still coming up (first start), so one probe is never the verdict. A
  /// miss is kept as PENDING (not dropped): one quick retry follows in 3 s
  /// for the starting-server case, and the session heartbeat keeps
  /// re-probing pending hints until they answer or age out.
  Future<void> _onBleIpHint(String host, int port) async {
    final key = '$host:$port';
    final now = DateTime.now().toUtc();
    final last = _bleHintThrottle[key];
    if (last != null && now.difference(last) < const Duration(seconds: 10)) {
      return;
    }
    _bleHintThrottle[key] = now;
    BleLog.log(ProxLogTags.ble, 'IP hint $key — background probe…');
    final hit = await probeHost(host, port);
    if (!mounted) return;
    if (hit == null) {
      BleLog.log(ProxLogTags.ble,
          'IP hint $key unreachable — server may still be starting, retrying…');
      // Pending: heartbeat retries (see _refreshSessions). One fast retry
      // covers the professor-tapped-Start-seconds-ago case without waiting
      // a full 10 s throttle window.
      _pendingHints[key] = now;
      final retry = Timer(const Duration(seconds: 3), () async {
        _hintRetryTimers.removeWhere((t) => !t.isActive);
        if (!mounted || phase != StudentPhase.browsing) return;
        if (_sessionAck.containsKey(key)) return; // answered meanwhile
        _bleHintThrottle.remove(key); // let the retry probe at once
        await _onBleIpHint(host, port);
      });
      _hintRetryTimers.add(retry);
      return;
    }
    BleLog.log(ProxLogTags.ble,
        'IP hint $key answers (${hit.classLabel}, ${hit.windowOpen ? "OPEN" : "idle"}) → listed');
    _pendingHints.remove(key);
    _sessionAck[key] = now;
    _sessionFails[key] = 0;
    setState(() {
      final known = {for (final c in _listener.live()) c.last.key: c};
      final prev = _hints[key] ?? known[key];
      _hints[key] = LiveClass(
        last: hit,
        firstSeen: prev?.firstSeen ?? now,
        lastSeen: now,
      );
      _live = _allLive();
    });
  }

  /// Forgets everything browse knows about one host:port (hosting ended):
  /// ack, fail count, hint listing, pending hint and probe throttle — the
  /// live list clears at once instead of lingering up to 45s on a stale
  /// ack whose last-answered flag still reads OPEN.
  void _dropHostEntries(String key) {
    _sessionAck.remove(key);
    _sessionFails.remove(key);
    _hints.remove(key);
    _pendingHints.remove(key);
    _bleHintThrottle.remove(key);
  }

  /// Leaves waiting/marked for the browse list (hosting ended): room
  /// timers off, target cleared, list recomputed — never a dead waiting
  /// room, never a face re-scan on an ended class.
  void _toBrowsing(String notice) {
    if (!mounted) return;
    _stopRoomTimers();
    _waitingTarget = null;
    _roomWindowOpen = false;
    _connected = false;
    _roomMisses = 0;
    setState(() {
      phase = StudentPhase.browsing;
      joinError = notice;
      _live = _allLive();
    });
  }

  /// Session heartbeat: re-probe hosts that once answered, so a class
  /// discovered over BLE stays listed (with live open/idle state) after
  /// its round — and its challenges — go silent. Answered hosts refresh;
  /// dead ones age out via [hintEntryAlive]. Pending hints (first probe
  /// missed while the server started) retry here too. Browse phase only.
  Future<void> _refreshSessions() async {
    if (!mounted || phase != StudentPhase.browsing) return;
    // Drop stale pending hints (heard >2 min ago, never answered).
    final now0 = DateTime.now().toUtc();
    _pendingHints.removeWhere(
        (k, v) => now0.difference(v) > const Duration(minutes: 2));
    if (_sessionAck.isEmpty && _pendingHints.isEmpty) {
      return;
    }
    final now = DateTime.now().toUtc();
    var changed = false;
    final keys = <String>{..._sessionAck.keys, ..._pendingHints.keys};
    for (final key in keys) {
      final lastProbe = _bleHintThrottle[key];
      if (lastProbe != null &&
          now.difference(lastProbe) < kSessionRefresh) {
        continue;
      }
      _bleHintThrottle[key] = now;
      final slash = key.lastIndexOf(':');
      if (slash < 0) continue;
      final hit = await probeHost(
          key.substring(0, slash), int.tryParse(key.substring(slash + 1)) ?? 0);
      if (!mounted) return;
      if (hit == null) {
        _sessionFails[key] = (_sessionFails[key] ?? 0) + 1;
        // The listing otherwise keeps its LAST ANSWERED open flag while
        // the ack lingers — flip it closed on the first failed re-probe
        // so an ended class never shows (or auto-advances) as OPEN. The
        // entry stays listed greyed until the fail backstop drops it.
        final prev = _hints[key];
        if (prev != null && prev.last.windowOpen) {
          _hints[key] = LiveClass(
            last: ClassAnnouncement(
              classLabel: prev.last.classLabel,
              host: prev.last.host,
              port: prev.last.port,
              display: '',
              prof: prev.last.prof,
              windowOpen: false,
              ts: now,
              org: prev.last.org,
            ),
            firstSeen: prev.firstSeen,
            lastSeen: prev.lastSeen,
          );
          changed = true;
        }
        if ((_sessionFails[key] ?? 0) >= kSessionMaxFails) {
          BleLog.log(ProxLogTags.lan, 'session $key gone (no ack) → dropped');
          _sessionAck.remove(key);
          _sessionFails.remove(key);
          changed = true;
        }
        continue;
      }
      _sessionAck[key] = now;
      _sessionFails[key] = 0;
      if (_pendingHints.remove(key) != null) {
        BleLog.log(
            ProxLogTags.ble, 'IP hint $key answered on retry → listed');
      }
      final prev = _hints[key];
      _hints[key] = LiveClass(
        last: hit,
        firstSeen: prev?.firstSeen ?? now,
        lastSeen: now,
      );
      changed = true;
    }
    if (changed && mounted && phase == StudentPhase.browsing) {
      setState(() => _live = _allLive());
    }
  }

  /// Broadcast beacons + BLE-hint listings, deduped by host:port.
  /// Hint entries outlive the 6s radio expiry while their session acks
  /// ([hintEntryAlive]): the class stays visible after the round ends;
  /// tapping re-validates through the waiting room / join gates.
  List<LiveClass> _allLive() {
    final now = DateTime.now().toUtc();
    _hints.removeWhere((k, v) => !hintEntryAlive(
        now: now,
        lastSeen: v.lastSeen,
        lastAck: _sessionAck[k],
        fails: _sessionFails[k] ?? 0));
    final byKey = <String, LiveClass>{};
    for (final c in _listener.live()) {
      byKey[c.last.key] = c;
    }
    for (final c in _hints.values) {
      byKey.putIfAbsent(c.last.key, () => c);
    }
    final out = byKey.values.toList()
      ..sort((a, b) => a.firstSeen.compareTo(b.firstSeen));
    return out;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _runId++;
    _refreshTimer?.cancel();
    _sessionTimer?.cancel();
    for (final t in _hintRetryTimers) {
      t.cancel();
    }
    _hintRetryTimers.clear();
    _rewaitTimer?.cancel();
    _rewaitTimer = null;
    try {
      ref.read(bleEngineProvider).onIpHintHeard = null;
    } catch (_) {}
    _setWake(false);
    _stopRoomTimers();
    if (phase == StudentPhase.waiting) {
      try {
        _leaveWaitingRoom();
      } catch (_) {}
    }
    _relayOff();
    // Closes the UDP discovery socket so no port stays open (req 7).
    _listener.stop();
    super.dispose();
  }

  void _stopRoomTimers() {
    _roomPoll?.cancel();
    _roomPoll = null;
    _presenceBeat?.cancel();
    _presenceBeat = null;
    _manualPoll?.cancel();
    _manualPoll = null;
  }

  /// Backstop so navigation away never leaves the mesh relaying behind.
  /// (The 20s linger timer in student_driver already bounds it; this cuts
  /// it immediately. Deliberately NOT called on the waiting→face advance,
  /// where the listen about to start needs the relay.)
  void _relayOff() {
    try {
      ref.read(bleEngineProvider).relayEnabled = false;
    } catch (_) {}
  }

  /// Best-effort wakelock, never awaited (see take_attendance.dart).
  void _setWake(bool on) {
    Future.microtask(() async {
      try {
        if (on) {
          await WakelockPlus.enable();
        } else {
          await WakelockPlus.disable();
        }
      } catch (_) {}
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Foreground-required UX on all OS: only a REAL backgrounding pauses
    // proving. `inactive` is transient (notification shade, incoming-call
    // UI, PiP, split-screen) and must never reset state.
    final backgrounded = state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    if (backgrounded &&
        (phase == StudentPhase.listening || phase == StudentPhase.faceCheck)) {
      _runId++;
      BleLog.log(ProxLogTags.state, 'backgrounded during $phase → paused');
      if (mounted) setState(() => phase = StudentPhase.paused);
    }
  }

  ClassBeacon? _parseTarget() {
    final raw = _typedHostPort.trim();
    if (raw.isEmpty) return null;
    var host = raw;
    var port = 8443;
    if (raw.contains(':')) {
      final parts = raw.split(':');
      host = parts.first.trim();
      port = int.tryParse(parts.last.trim()) ?? 8443;
    }
    if (host.isEmpty) return null;
    return ClassBeacon(
        classLabel: 'Class at $host',
        host: host,
        port: port,
        rssiDbm: 0,
        displayCode: '···');
  }

  Future<void> _join() async {
    final target = _parseTarget();
    if (target == null) {
      setState(() => joinError = 'Enter the professor IP shown in class.');
      return;
    }
    BleLog.log(ProxLogTags.nav, 'join by IP ${target.host}:${target.port} → waiting');
    try {
      await ref
          .read(deviceStoreProvider)
          .writeLastHost('${target.host}:${target.port}');
    } catch (_) {}
    _roundMarks.clear();
    await _enterWaitingRoom(target);
  }

  Future<bool> _checkJoinGates() async {
    final linked = ref.read(linkedIdentityProvider);
    if (linked == null) {
      setState(
          () => joinError = 'Enroll this device first — identity is required.');
      return false;
    }
    if (!await ref.read(blePermissionProvider)()) {
      setState(() => joinError =
          'Bluetooth permission is required for proximity proofs. Enable it in Settings and rejoin.');
      return false;
    }
    if (await ref.read(btPowerProvider)() == BtState.off) {
      final enabled = await requestEnableBluetooth();
      if (!enabled || await ref.read(btPowerProvider)() != BtState.on) {
        setState(() =>
            joinError = 'Bluetooth is off — turn it on to join the class.');
        return false;
      }
    }
    return true;
  }

  Future<void> _joinBeacon(ClassBeacon target) async {
    if (!await _checkJoinGates()) return;
    if (!mounted) return;
    // NOTE: unknown/unavailable stacks proceed; real radio errors surface
    // from the scan/prove operations themselves (Bug 1).
    // Pre-warm scanning only (no challenge wait yet — it is armed after
    // the face passes, so tests ending at faceCheck stay timer-clean and a
    // pre-face token can never leak into the proof).
    try {
      await ref.read(studentDriverProvider).prewarmRadio();
    } catch (_) {}
    if (!mounted) return;
    BleLog.log(ProxLogTags.nav,
        'live window for ${target.host}:${target.port} → face check');
    setState(() {
      joinError = '';
      phase = StudentPhase.faceCheck;
      _faceAttempts = 0;
      _autoFaceTries = 0;
      faceNotice = '';
    });
    final linked = ref.read(linkedIdentityProvider);
    if (linked != null) _scheduleAutoScan(target, linked);
  }

  /// Waiting-room entry (req 1): Join never starts face scan. It registers
  /// presence, pre-warms BLE, and shows Connected / Not connected + waiting
  /// for the professor. When the window opens the room auto-advances.
  /// [immediateProbe] false skips the fast-path check (UDP idle beacons
  /// already say closed); timers still start for presence + polling.
  Future<void> _enterWaitingRoom(ClassBeacon target,
      {bool immediateProbe = true}) async {
    if (!await _checkJoinGates()) return;
    if (!mounted) return;
    final linked = ref.read(linkedIdentityProvider)!;
    try {
      await ref.read(studentDriverProvider).prewarmRadio();
    } catch (_) {}
    if (!mounted) return;
    _stopRoomTimers();
    BleLog.log(ProxLogTags.nav, 'waiting room ${target.host}:${target.port}');
    setState(() {
      joinError = '';
      _waitingTarget = target;
      _connected = false;
      _roomMisses = 0;
      _roomWindowOpen = false;
      _roomClass = target.classLabel;
      phase = StudentPhase.waiting;
      _faceAttempts = 0;
      _autoFaceTries = 0;
      faceNotice = '';
    });
    // Presence heartbeat (prof sees n waiting) + immediate probe.
    try {
      await ref
          .read(studentDriverProvider)
          .sendPresence(target: target, identity: linked);
    } catch (_) {}
    if (immediateProbe) {
      await _pollRoomOnce();
      // Fast path: window already open (e.g. rejoin mid-window) → face check.
      if (!mounted) return;
      if (_roomWindowOpen) {
        _advanceToFace(target);
        return;
      }
    }
    final run = _runId;
    _presenceBeat = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!mounted || run != _runId || phase != StudentPhase.waiting) return;
      try {
        await ref
            .read(studentDriverProvider)
            .sendPresence(target: target, identity: linked);
      } catch (_) {}
    });
    _roomPoll = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted || run != _runId || phase != StudentPhase.waiting) return;
      await _pollRoomOnce();
      if (!mounted || run != _runId) return;
      if (_roomWindowOpen && phase == StudentPhase.waiting) {
        _advanceToFace(target);
      }
    });
  }

  Future<void> _pollRoomOnce() async {
    final target = _waitingTarget;
    if (target == null) return;
    try {
      final probe = await ref.read(studentDriverProvider).probeWindow(target);
      if (!mounted) return;
      if (!probe.reachable) {
        // Hosting may have ended under a waiter (End attendance stops
        // the server): 5 consecutive misses (~10s) leaves for the live
        // list instead of parking on "Not connected" forever. Single
        // misses just show the state (transient holes must not bounce
        // a waiter out).
        if (++_roomMisses >= 5) {
          final key = '${target.host}:${target.port}';
          BleLog.log(ProxLogTags.lan, 'hosting ended while waiting → live list');
          _dropHostEntries(key);
          _toBrowsing('Class ended — back to the live list.');
          return;
        }
      } else {
        _roomMisses = 0;
      }
      setState(() {
        _connected = probe.reachable;
        _roomWindowOpen = probe.windowOpen;
        if (probe.classLabel.isNotEmpty) _roomClass = probe.classLabel;
      });
    } catch (_) {
      if (++_roomMisses >= 5) {
        final t = _waitingTarget;
        if (t != null) {
          BleLog.log(ProxLogTags.lan, 'hosting ended while waiting → live list');
          _dropHostEntries('${t.host}:${t.port}');
          _toBrowsing('Class ended — back to the live list.');
          return;
        }
      }
      if (mounted) setState(() => _connected = false);
    }
  }

  void _advanceToFace(ClassBeacon target) {
    if (!mounted || phase != StudentPhase.waiting) return;
    _stopRoomTimers();
    _joinBeacon(target);
  }

  /// Samsung-style seamless unlock: the scan starts by itself the moment
  /// the face step appears — zero taps. Fires once per entry (post-frame,
  /// guarded): backgrounding to paused, leaving the step, or a manual tap
  /// first all suppress the auto-fire. The Scan button stays as fallback.
  void _scheduleAutoScan(ClassBeacon target, LinkedIdentity linked) {
    _autoFaceFired = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || phase != StudentPhase.faceCheck || _autoFaceFired) {
        return;
      }
      _autoFaceFired = true;
      _scanFace(target, linked);
    });
  }

  Future<void> _scanFace(ClassBeacon target, LinkedIdentity linked) async {
    // Manual tap before the post-frame callback must not double-push.
    _autoFaceFired = true;
    // Parallel face + mesh (req 1): the scan pre-warmed at join keeps
    // running (and relaying) under the camera UI; we only wait on the face
    // verdict here. The challenge wait is armed AFTER the face passes, so a
    // token heard during the camera UI can never be reused as proof for a
    // rotated/restarted round (air carries no window ID — a pre-face token
    // verifies against nothing and fails as "prof signature mismatch").
    // Live auto-scan returns accepted stills (or null on cancel/timeout).
    // Marking scan runs a fast cadence (350ms gaps) inside a 12s VERIFY
    // SESSION: the camera page checks every accepted still live, with
    // score feedback and a countdown — any one pass pops at once, and a
    // dead session pops its failures together so it burns exactly one of
    // the 4 attempts. A single bad frame never exits the camera nor burns
    // a retry on its own (instant single-frame failure is gone).
    // Enrollment uses the slower default cadence without a verifier.
    // Zero-progress timeouts auto-retry twice in-screen (Cancel always
    // available); attempts are never consumed here either way.
    final frames = await Navigator.of(context).push<List<Uint8List>>(
      MaterialPageRoute(
          builder: (_) => FaceCaptureScreen(
                frameGap: const Duration(milliseconds: 350),
                autoRetries: 2,
                verifyWindow: const Duration(seconds: 12),
                verifier: (bytes) =>
                    ref.read(studentDriverProvider).checkFace(bytes),
              )),
    );
    if (frames == null || frames.isEmpty || !mounted) return;
    final res =
        await ref.read(studentDriverProvider).checkFace(frames.first);
    if (!mounted) return;
    switch (res.match) {
      case FaceMatch.pass:
        BleLog.log(ProxLogTags.face, 'face pass — continuing to proving');
        setState(() => faceNotice = '');
        _listen(target, linked, res.score);
      case FaceMatch.mismatch:
        // Readable session, somebody else: the ONLY outcome that consumes
        // one of the 4 attempts (a whole 12s session, not one frame).
        BleLog.log(ProxLogTags.face, 'face mismatch — attempt consumed, needs review');
        _faceAttempts++;
        setState(() => phase = StudentPhase.needsReview);
      case FaceMatch.inconclusive:
        // No readable verdict (attempt kept): relaunch automatically a
        // couple of times with a helpful prompt, then fall back to the
        // manual Scan button. Cancel exits this loop by returning null.
        BleLog.log(ProxLogTags.face, 'face inconclusive — auto-retry ($_autoFaceTries of 2)');
        if (_autoFaceTries < 2) {
          _autoFaceTries++;
          setState(() => faceNotice =
              'Scan unclear — retrying automatically… ($_autoFaceTries of 2)');
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || phase != StudentPhase.faceCheck) return;
            _scanFace(target, linked);
          });
        } else {
          setState(() => faceNotice =
              'Could not read that scan — adjust light and try again.');
        }
      case FaceMatch.staleTemplate:
        // Template predates the face pipeline: matching against it would
        // be meaningless. Park on the check screen with a re-enroll
        // notice — no attempt consumed, nothing signed.
        BleLog.log(ProxLogTags.face, 'stale template — re-enroll, nothing signed');
        setState(() => faceNotice =
            'Face recognition was updated — re-enroll this device from the home screen, then join again.');
    }
  }

  Future<void> _requestManual() async {
    final target = _waitingTarget ?? _parseTarget();
    final linked = ref.read(linkedIdentityProvider);
    if (target == null || linked == null) return;
    BleLog.log(ProxLogTags.state, 'manual request → ${target.host} (polling prof)');
    setState(() {
      _manualStatus = 'pending';
      phase = StudentPhase.manualPending;
    });
    try {
      await ref
          .read(studentDriverProvider)
          .requestManual(target: target, identity: linked);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        joinError = 'Manual request failed: $e';
        phase = StudentPhase.waiting;
      });
      return;
    }
    final run = _runId;
    _manualPoll?.cancel();
    _manualPoll = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted || run != _runId || phase != StudentPhase.manualPending) {
        return;
      }
      try {
        final st = await ref
            .read(studentDriverProvider)
            .pollManualStatus(target: target, email: linked.gmail);
        if (!mounted || run != _runId) return;
        setState(() => _manualStatus = st);
        if (st == 'approved') {
          _manualPoll?.cancel();
          BleLog.log(ProxLogTags.state, 'manual approved — marked present');
          setState(() {
            ackDetail = 'Marked present (manual approval)';
            phase = StudentPhase.marked;
          });
        } else if (st == 'rejected') {
          _manualPoll?.cancel();
          BleLog.log(ProxLogTags.state, 'manual rejected — parked, see professor');
          // Stays in manualPending showing the verdict (present-or-absent ACK).
        }
      } catch (_) {}
    });
  }

  Future<void> _listen(
      ClassBeacon target, LinkedIdentity linked, double faceScore) async {
    final run = ++_runId;
    _rewaitTimer?.cancel();
    _rewaitTimer = null;
    _rewaitMisses = 0;
    _setWake(true);
    setState(() {
      phase = StudentPhase.listening;
      listenStatus = 'Waiting for the class signal…';
    });
    // No round clock: the driver loops on fresh challenges until a verdict
    // (marked/late/dead-air/error) — nothing here retries or counts down.
    final receipt = await ref.read(studentDriverProvider).listenAndProve(
          target: target,
          identity: linked,
          faceScore: faceScore,
          onStatus: (s) {
            if (!mounted || run != _runId) return;
            setState(() => listenStatus = switch (s) {
                  ListenStatus.waiting => 'Waiting for the class signal…',
                  ListenStatus.proving => 'Signal heard — proving…',
                  ListenStatus.confirming => 'Proof sent — confirming…',
                });
          },
        );
    if (!mounted || run != _runId) return;
    _setWake(false);
    if (receipt.result == StudentResult.marked ||
        receipt.result == StudentResult.late) {
      // Per-round trail for the waiting-room card (R1, R2, … this join).
      _roundMarks.add(
          'R${_roundMarks.length + 1} · ${receipt.detail}');
    }
    BleLog.log(ProxLogTags.state, 'verdict ${receipt.result.name} (${receipt.detail})');
    setState(() {
      ackDetail = receipt.detail;
      phase = switch (receipt.result) {
        StudentResult.marked => StudentPhase.marked,
        StudentResult.late => StudentPhase.late,
        StudentResult.faceFailed => StudentPhase.needsReview,
        StudentResult.noSignal => StudentPhase.noSignal,
        StudentResult.error => StudentPhase.noSignal,
      };
      if (receipt.result == StudentResult.error) {
        infoDetail = receipt.detail;
      }
    });
    if (receipt.result == StudentResult.marked ||
        receipt.result == StudentResult.late) {
      // Stay for the next round: once THIS round ends, rejoin the waiting
      // room (fast-paths straight back to face if the next window is
      // already open). No taps, face re-checks every round.
      _rewaitAfterRound(target, run, receipt.display);
    }
  }

  /// Parks on the verdict badge until the just-marked round ends, then
  /// rejoins the waiting room for the next round. Same-window re-face is
  /// impossible: we only leave when the probe says closed/unreachable, or
  /// when the window code changes (fast professor retake). Single-shot
  /// chained timer (never a bare delayed future) so dispose/test teardown
  /// stays timer-clean.
  ///
  /// Hosting-ended vs round-over: End attendance STOPS the professor
  /// server, so the probe goes unreachable — that is not "next round",
  /// it is "class over": after 2 consecutive misses (~6s, blip-tolerant)
  /// the badge leaves for the live list (entries purged) instead of a
  /// dead waiting room that would face-scan again on the stale OPEN flag.
  /// Reachable-but-closed still means round over → waiting room.
  Timer? _rewaitTimer;
  int _rewaitMisses = 0;
  void _rewaitAfterRound(ClassBeacon target, int run, String markedDisplay) {
    _rewaitTimer?.cancel();
    _rewaitTimer = Timer(const Duration(seconds: 3),
        () => _rewaitPoll(target, run, markedDisplay));
  }

  Future<void> _rewaitPoll(
      ClassBeacon target, int run, String markedDisplay) async {
    _rewaitTimer = null;
    if (!mounted ||
        run != _runId ||
        !(phase == StudentPhase.marked ||
            phase == StudentPhase.late)) {
      return;
    }
    var rewait = false;
    var ended = false;
    var nextDisplay = '';
    try {
      final probe =
          await ref.read(studentDriverProvider).probeWindow(target);
      if (!probe.reachable) {
        if (++_rewaitMisses >= 2) ended = true;
      } else {
        _rewaitMisses = 0;
        if (!probe.windowOpen) {
          rewait = true; // round over (hosting continues)
        } else {
          nextDisplay = probe.display;
          rewait = nextDisplay.isNotEmpty &&
              markedDisplay.isNotEmpty &&
              nextDisplay != markedDisplay;
        }
      }
    } catch (_) {
      // Probe flaked: the badge keeps polling until the misses add up.
      if (++_rewaitMisses >= 2) ended = true;
    }
    if (!mounted ||
        run != _runId ||
        !(phase == StudentPhase.marked ||
            phase == StudentPhase.late)) {
      return;
    }
    if (ended) {
      BleLog.log(ProxLogTags.lan,
          'hosting ended (was $markedDisplay) → live list, no re-face');
      _dropHostEntries('${target.host}:${target.port}');
      _toBrowsing('Class ended — back to the live list.');
      return;
    }
    if (rewait) {
      BleLog.log(ProxLogTags.lan,
          'round over (was $markedDisplay, now ${nextDisplay.isEmpty ? 'closed' : nextDisplay}) → waiting for next');
      await _enterWaitingRoom(target);
      return;
    }
    _rewaitAfterRound(target, run, markedDisplay);
  }

  /// Leaves any inner phase for the browse list: timers off, explicit
  /// /leave so the professor count drops, relay cut. Used by Cancel/Back
  /// actions and the system-back handler (same teardown everywhere).
  void _cancelToBrowsing() {
    _runId++;
    _stopRoomTimers();
    _leaveWaitingRoom();
    setState(() {
      _waitingTarget = null;
      phase = StudentPhase.browsing;
    });
  }

  Widget _browsing(
      BuildContext context, LinkedIdentity? linked, String identityLine) {
    return BrowseClassesView(
      linked: linked,
      identityLine: identityLine,
      ipFieldKey: ValueKey('ip-$_fieldNonce'),
      ipInitial: _fieldInitial,
      onIpChanged: (v) {
        _typedHostPort = v ?? '';
        final hp = v;
        if (hp != null && hp.isNotEmpty) {
          try {
            ref.read(deviceStoreProvider).writeLastHost(hp);
          } catch (_) {}
        }
      },
      onJoin: _join,
      joinError: joinError,
      live: _live,
      onTapLive: (c) {
        BleLog.log(ProxLogTags.nav, 'live tile ${c.last.classLabel} tapped');
        final target = ClassBeacon(
          classLabel: c.last.classLabel,
          host: c.last.host,
          port: c.last.port,
          rssiDbm: 0,
          displayCode: c.last.display,
          org: c.last.org,
        );
        final hp = '${c.last.host}:${c.last.port}';
        setState(() {
          _fieldInitial = hp;
          _fieldNonce++;
          _typedHostPort = hp;
        });
        _roundMarks.clear();
        if (c.last.windowOpen) {
          _joinBeacon(target);
        } else {
          _enterWaitingRoom(target, immediateProbe: false);
        }
      },
      onEnroll: () {
        BleLog.log(ProxLogTags.nav, 'browse → enroll bundle');
        EnrollFlow.openBundle(context).then((_) {
          if (mounted) setState(() {});
        });
      },
      onViewRecords: () {
        BleLog.log(ProxLogTags.nav, 'browse → records');
        Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const MyAttendanceScreen()));
      },
      onRefresh: () async {
        if (mounted) setState(() => _live = _allLive());
      },
    );
  }

  void _openLog() {
    BleLog.log(ProxLogTags.nav, 'mark → system log');
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const DebugLogScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final linked = ref.watch(linkedIdentityProvider);
    final identityLine = linked == null
        ? 'Not enrolled — enroll this device to link identity.'
        : '${linked.name}${linked.roll.isNotEmpty ? ' · ${linked.roll}' : ''}\n${linked.gmail}';
    final target = _parseTarget();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Back never exits mid-flow: inner phases return to browsing,
        // browsing returns to the mode hub.
        if (phase == StudentPhase.browsing) {
          setMode(ref, AppMode.unset);
        } else {
          _runId++;
          _stopRoomTimers();
          _leaveWaitingRoom();
          _relayOff();
          setState(() {
            _waitingTarget = null;
            phase = StudentPhase.browsing;
          });
        }
      },
      child: AdaptiveScaffold(
        title: 'Student — Join class',
        actions: [
          IconButton(
            icon: const Icon(Icons.terminal_outlined),
            tooltip: 'System log',
            onPressed: _openLog,
          ),
          IconButton(
            icon: const Icon(Icons.switch_account),
            tooltip: 'Switch mode',
            onPressed: () => setMode(ref, AppMode.unset),
          ),
        ],
        // Waiting → scan → verdict wrapped as ONE continuation: every hop
        // cross-fades (emphasized) instead of hard-cutting.
        body: MarkFlowShell(
          phase: phase,
          child: switch (phase) {
            StudentPhase.browsing => _browsing(context, linked, identityLine),
            StudentPhase.waiting => WaitingRoomView(
                connected: _connected,
                roomClass: _roomClass.isNotEmpty
                    ? _roomClass
                    : (_waitingTarget?.classLabel ?? 'this class'),
                roundMarks: _roundMarks,
                onRequestManual: _requestManual,
                onCancel: _cancelToBrowsing,
              ),
            StudentPhase.manualPending => ManualRequestView(
                status: _manualStatus,
                onBack: _cancelToBrowsing,
              ),
            StudentPhase.faceCheck => FaceCheckView(
                faceNotice: faceNotice,
                canScan: (_waitingTarget ?? target) != null && linked != null,
                onScan: () {
                  final t = _waitingTarget ?? target;
                  final l = linked;
                  if (t != null && l != null) _scanFace(t, l);
                },
              ),
            StudentPhase.listening => ProvingView(
                status: listenStatus,
              ),
            StudentPhase.marked => MarkVerdictView(
                kind: MarkVerdict.marked,
                detail: ackDetail,
                roundMarks: _roundMarks,
                onRetryFace: () {},
                onManualInstead: () {},
                onBack: () {},
              ),
            StudentPhase.late => MarkVerdictView(
                kind: MarkVerdict.late,
                detail: ackDetail,
                roundMarks: _roundMarks,
                onRetryFace: () {},
                onManualInstead: () {},
                onBack: () {},
              ),
            StudentPhase.needsReview => MarkVerdictView(
                kind: MarkVerdict.needsReview,
                detail: '',
                roundMarks: const [],
                attemptsLeft: 4 - _faceAttempts,
                onRetryFace: () {
                  final t = _waitingTarget ?? target;
                  final l = linked;
                  setState(() => phase = StudentPhase.faceCheck);
                  if (t != null && l != null) {
                    _scheduleAutoScan(t, l);
                  }
                },
                onManualInstead: _requestManual,
                onBack: () => setState(() => phase = StudentPhase.browsing),
              ),
            StudentPhase.noSignal => MarkVerdictView(
                kind: MarkVerdict.noSignal,
                detail: ackDetail,
                infoDetail: infoDetail,
                roundMarks: const [],
                onRetryFace: () {},
                onManualInstead: () {},
                onBack: () => setState(() => phase = StudentPhase.browsing),
              ),
            StudentPhase.paused => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Paused — reopen'),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: () =>
                          setState(() => phase = StudentPhase.browsing),
                      child: const Text('Back to join'),
                    ),
                  ],
                ),
              ),
          },
        ),
      ),
    );
  }
}
