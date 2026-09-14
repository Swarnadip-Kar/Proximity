// Student flow: manual join (IP shown by professor; BLE discovery lands
// with the radio slice) → face check → 45s-bounded radio wait ([silenceCap]
// probe decides) → signed ACK. Foreground-required; backgrounding pauses.
// Identical Android/iOS.
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_transport/transport.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/auth.dart';
import '../core/ble_radio.dart';
import '../core/cloud_sync.dart';
import '../core/device_store.dart';
import '../core/platformx.dart';
import '../core/student_driver.dart';
import '../core/sync_hook.dart';
import '../design/tokens.dart';
import '../features/account/account_common.dart';
import '../features/entry/entry_flow.dart';
import '../features/mark/browse_classes.dart';
import '../features/mark/face_check.dart';
import '../features/mark/manual_status.dart';
import '../features/mark/mark_flow.dart';
import '../features/mark/mark_phase.dart';
import '../features/mark/paused_view.dart';
import '../features/mark/proving_view.dart';
import '../features/mark/verdict_section.dart';
import '../features/mark/waiting_room.dart';
import '../main.dart';
import '../mode.dart';
import '../widgets/log_drawer.dart';
import 'face_capture.dart';

// Mark phases live in the mark-flow section; re-exported here so existing
// imports keep resolving StudentPhase from this screen.
export '../features/mark/mark_phase.dart' show StudentPhase;

/// UDP discovery port (injectable so tests avoid clashing with a running app).
final discoveryPortProvider = Provider<int>((_) => kDiscoveryPort);

/// True while the Mark tab sits on an inner flow phase (waiting / face /
/// proving / verdict — anything past browsing). The tab root holds only a
/// LocalHistoryEntry then (view-state, KeepAlive-preserved), never a real
/// pushed route. The shell reads this to keep pager swipes enabled
/// in-flow (swipes into/out of Mark must land — the entry alone must not
/// page-lock) while swipes off real pushed sub-pages stay locked.
/// Reset on dispose; single Mark tab per shell, so one global is enough.
final markInFlow = ValueNotifier<bool>(false);

/// Hands-free retry decision for one inconclusive face verdict (pure):
/// returns the delay before the next automatic scan, or null when the
/// window is spent (caller falls back to the manual Scan button). The
/// try-count cap is a backstop for clock jumps; the deadline is the real
/// budget. Mismatch never reaches here (it burns an attempt by design).
Duration? nextAutoFaceRetryDelay({
  required int tries,
  required int tryCap,
  required Duration gap,
  required DateTime now,
  required DateTime deadline,
}) {
  if (tries > tryCap) return null;
  if (deadline.difference(now) <= Duration.zero) return null;
  return gap;
}

/// Same-round re-face policy (pure): auto-advance may face-check a window
/// only when it is NOT the round already marked on this host. Unknown
/// display with a recorded mark holds (the room poll refines it); first
/// joins (no recorded mark) always pass. Manual joins bypass this —
/// explicit user action, server dedupes.
bool mayAutoFaceFor({String? markedDisplay, required String display}) {
  final marked = (markedDisplay ?? '').trim();
  if (marked.isEmpty) return true;
  final d = display.trim();
  if (d.isEmpty || d == marked) return false;
  return true;
}

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
  // Wrong-org orgs from the latest receipt (feed the verdict card).
  String wrongClassOrg = '';
  String wrongMyOrg = '';
  String joinError = '';
  String _typedHostPort = '';
  String _fieldInitial = '';
  final _listener = ClassListener();
  List<LiveClass> _live = [];
  ClassBeacon? _waitingTarget;
  int _runId = 0;
  // Waiting-room state (req 1): connection status + prof-triggered advance.
  bool _connected = false;
  bool _roomWindowOpen = false;
  String _roomClass = '';
  // Waiting-room identity (presentation only): prof name + org from the
  // tapped announcement + Gmail from the GATED /window unicast (never
  // beacons/BLE). Typed-IP joins heard no announcement, so name/org stay
  // empty and email fills after the gated fetch — nothing is fetched from
  // broadcasts.
  String _roomProf = '';
  String _roomProfEmail = '';

  /// Hosting professor's Gmail photo from the gated /window poll ('' =
  /// unknown). Converges when the host publishes; initials fallback.
  String _roomProfPhoto = '';

  /// Last (course → photo) pair written to the device cache: guards the
  /// 2s room poll from rewriting prefs on every tick.
  String _cachedPhotoKey = '';
  // Provisional waiting-room pin verdict (issue-7 banner): the gated email
  // is known but no proof has run yet (prove-time checkProfPin is what
  // HONESTLY verifies — Sig_p against the pin — so a `verified` claim here
  // would be early). When the pin cache holds NOTHING for this email, the
  // professor is first-seen by definition: show the `unverified` banner
  // now (queued for auto-verify online) instead of silence. When pins ARE
  // cached, show nothing until prove verdicts (a cached pin is not a
  // match). The prove-time driver verdict always wins when present.
  ProfVerificationResult? _waitingCacheVerdict;
  // Email the provisional verdict above was computed for (one pin-cache
  // read per email per room — never per 2s tick).
  String _waitingCacheEmail = '';

  /// Own Gmail profile photo for volunteered presence ('' = absent).
  /// Best-effort read; never blocks join/prove.
  String _ownPhoto() {
    try {
      return ref.read(accountProvider).valueOrNull?.photoUrl?.trim() ?? '';
    } catch (_) {
      return '';
    }
  }
  String _roomOrg = '';
  // Gated prof emails by `host:port` (org-checked /window unicast only).
  // Browse tiles render these (KEEP of the pre-revert surfacing, new
  // gated source); mismatched org never populates (silence).
  final Map<String, String> _gatedEmailByHost = {};
  // Gated prof photos by `host:port` (same unicast as the emails above).
  // Browse tiles render these; ''/absent = opted-out/unknown → the
  // class-letter disc. Never beacons/BLE.
  final Map<String, String> _gatedPhotoByHost = {};
  // Verification labels by `host:port` for the browse tiles (see
  // BrowseTile.verifyLabel): 'known' / 'first-seen' from the pin-cache
  // presence at backfill time, upgraded to 'verified-live' / 'verified' /
  // 'mismatch' / 'unverified' by the prove-time pin verdict. Absent/'' =
  // unknown host — renders exactly as before.
  final Map<String, String> _profVerifyByHost = {};
  // Email each browse label above was computed for, by `host:port`. A
  // label is only valid for its email: when the gated fetch reports a
  // DIFFERENT professor on the same host (sign-out → different account
  // re-hosting the same IP, or a stale cache after the host went
  // anonymous), the old label is dropped and recomputed — a 'verified'
  // earned by the previous professor must never badge the next one.
  final Map<String, String> _profVerifyEmailByHost = {};
  // Live round numbers by `host:port` (same gated /window unicast —
  // browse tiles render the under-disc ordinal from these; 0/absent
  // hides it). Refreshed on every backfill while reachable.
  final Map<String, int> _windowNoByHost = {};
  // Email backfill throttle: one gated /window fetch per host per 15s
  // (same budget as the session heartbeat — solicitation stays cheap).
  final Map<String, DateTime> _emailFetchThrottle = {};
  // Consecutive unreachable room polls: hosting ended under a waiter
  // (End attendance stops the professor server) vs a network blip.
  int _roomMisses = 0;
  // Latest observed window display code for the waiting room (round
  // identity — drives the same-round re-face guard below).
  String _roomDisplay = '';
  // Rounds already marked, by `host:port` → display code. Auto-advance
  // (room poll, entry fast paths) must never face-check these again: a
  // transient closed sample mid-round used to bounce marked → waiting →
  // face for the SAME round. Manual joins bypass (explicit user action;
  // the server dedupes already-marked re-proves idempotently). Entries
  // drop with their host (see _dropHostEntries); a new mark overwrites.
  final Map<String, String> _markedDisplayByHost = {};

  /// Auto-advance gate for [target] showing [display]: false when this is
  /// the round already marked on this host (same display, both known).
  /// Unknown display with a recorded mark holds too — the 2s room poll
  /// refines it before any face check. First joins (no mark) always pass.
  bool _mayAutoFace(ClassBeacon target, String display) {
    final marked = _markedDisplayByHost['${target.host}:${target.port}'];
    if (!mayAutoFaceFor(markedDisplay: marked, display: display)) {
      BleLog.log(ProxLogTags.face,
          'already marked $marked here — holding (no same-round re-face)');
      return false;
    }
    return true;
  }
  Timer? _roomPoll;
  Timer? _presenceBeat;
  // Overlap guard for the 2s room poll: Timer.periodic does not await the
  // body, and a probe may outlive the cadence (timeout budget is 4s), so a
  // slow tick would otherwise overlap the next one — two in-flight probes
  // race on _roomMisses/_connected (out-of-order completion flips the
  // badge) and double the GET /window rate into the server's 5-hits/10s/IP
  // cap. Owned by the current _runId generation (see _pollRoomOnce).
  bool _roomPollBusy = false;
  Timer? _manualPoll;
  String _manualStatus = '';
  // Instant face retries used this join (4 mismatch sessions, then review).
  int _faceAttempts = 0;
  // True when the latest mismatch failed VITALITY (liveness gate) rather
  // than identity (face matcher) — the needs-review verdict names
  // photo/screen then, not the wrong face (see
  // FaceCheckResult.livenessFailed). Reset on every face-check entry.
  bool _faceMismatchLiveness = false;
  // Automatic re-scans after unreadable/low-score verdicts: time-boxed
  // (7s window, ~1s between bursts of 10 stills — the holder just keeps
  // holding still, never taps retry), with a try-count backstop;
  // Cancel/back exits via the teardown guards. The retries run INSIDE the
  // open camera sheet (same preview, same controller — see the [accept]
  // handoff in _scanFace), so the camera never tears down between bursts;
  // the delayed re-push below is the legacy path for capturers without
  // [accept] support. Readable wrong-face (identity mismatch) never
  // auto-retries — it burns an attempt and parks for review. Low vitality
  // (possible photo/screen) retries IN PLACE till the 7s window spends
  // (never an instant exit that wastes a retry), then burns — so transient
  // dips don't cost attempts while consistent-low spoofs still do after
  // the window, without handing free oracle queries beyond the window.
  int _autoFaceTries = 0;
  DateTime? _autoFaceDeadline;
  static const _autoFaceWindow = Duration(seconds: 7);
  // Marking retry stills land ~0.6s apart (was 1s): shorter total check,
  // same 7s budget + try cap. In-burst stills stay ~350ms apart.
  static const _autoFaceGap = Duration(milliseconds: 600);
  static const _autoFaceTryCap = 8;
  // Samsung-style auto-start guard: the scan fires once per faceCheck
  // entry (post-frame); the manual button stays as fallback/retry.
  bool _autoFaceFired = false;
  // Single-flight for still-capture auto-fire + manual taps: concurrent
  // _scanFace calls never overlap captures (double-push would stack two
  // camera sheets). Second caller no-ops; Scan stays as fallback after
  // the in-flight scan settles.
  bool _scanBusy = false;
  // In-modal verify handoff (see _scanFace): the open camera sheet runs
  // checkFaceAny per burst via its [accept] callback and caches the latest
  // verdict here, so the preview never tears down between auto-retries.
  // Null when the capturer ignored [accept] (legacy fakes) — the caller
  // then verifies once itself, exactly as before.
  FaceCheckResult? _modalResult;
  // True when the modal's in-preview retries already spent the auto-retry
  // window: a popped inconclusive resolves straight to the manual Scan
  // notice instead of scheduling another sheet.
  bool _modalExhausted = false;
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
  // Broadcast-blocked banner: UDP beacons deliver nothing on isolating
  // APs while BLE-hinted classes still list (hint+probe rung). True means
  // the list below is hint-only — never a silent empty state.
  bool _broadcastBlocked = false;
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
    // Discovery assumptions, never silent: logged on every browse entry
    // (LAN tag) so a dead enterprise AP reads as explained, not empty.
    for (final line in discoveryAssumptionLines()) {
      BleLog.log(ProxLogTags.lan, line);
    }
    BleLog.log(ProxLogTags.lan, 'ladder ${formatLadderLine(-1)}');
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
    _sessionTimer = Timer.periodic(kSessionRefresh, (_) => _refreshSessions());
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
    // once through the loud hint path so the system log always shows the
    // attempt + honest miss reason — a silent miss hides dead-AP vs
    // starting-server. Live BLE hints cover discovery after this.
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

  /// This student's org claim for gated discovery (explicit identity org,
  /// else the Gmail domain; '' = unstamped/unknown, passes as before).
  String _myOrg() {
    try {
      final linked = ref.read(linkedIdentityProvider);
      if (linked == null) return '';
      if (linked.org.trim().isNotEmpty) return linked.org.trim().toLowerCase();
      return orgOf(linked.gmail);
    } catch (_) {
      return '';
    }
  }

  /// BLE IP hint heard (professor HTTPS host:port in scan-response mfg).
  /// Gated-probes the hint with our org claim (throttled) and lists it
  /// ONLY on match — mismatched org gets silence (never listed). Class
  /// discovery with zero LAN broadcasts and zero taps.
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
    BleLog.log(ProxLogTags.ble, 'IP hint $key — gated probe…');
    String missReason = 'unreachable';
    final hit = await probeHost(host, port,
        verboseMisses: true, onMiss: (r) => missReason = r, org: _myOrg());
    if (!mounted) return;
    if (hit == null) {
      // Honest reason always logged: refused = starting-server, timeout =
      // AP isolation/firewall, org-mismatch = gated silence (foreign org:
      // the class never appears here). Pending + heartbeat retry
      // regardless — never one-and-done, never silent.
      BleLog.log(ProxLogTags.ble,
          'IP hint $key unreachable ($missReason) — retrying…');
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
    // Gated email backfill (one cheap unicast; throttled): the hint probe
    // above is presence-only — the Gmail rides the gated /window unicast.
    unawaited(_backfillGatedEmail(host, port));
  }

  /// Gated email backfill for one host:port (matching/legacy org only).
  /// One short GET per host per 15s — solicitation stays cheap. Mismatched
  /// org gets silence (nothing cached, nothing rendered).
  Future<void> _backfillGatedEmail(String host, int port) async {
    final key = '$host:$port';
    final now = DateTime.now().toUtc();
    final last = _emailFetchThrottle[key];
    if (last != null && now.difference(last) < kSessionRefresh) return;
    _emailFetchThrottle[key] = now;
    try {
      final probe = await ref.read(studentDriverProvider).probeWindow(
          ClassBeacon(
              classLabel: '',
              host: host,
              port: port,
              rssiDbm: 0,
              displayCode: ''),
          myOrg: _myOrg());
      if (!mounted || !probe.reachable) return;
      final email = probe.profEmail.trim().toLowerCase();
      final photo = probe.profPhoto.trim();
      var changed = false;
      if (email.isEmpty) {
        // Reachable host serving NO identity (signed-out/anonymous host —
        // sign-out ends hosting, but a lingering server may answer one
        // more poll first): drop any cached identity so tiles stop
        // showing the previous professor's email/photo/verified tag.
        // Legacy hosts never populate these maps — no-op for them.
        if (_gatedEmailByHost.remove(key) != null) {
          changed = true;
          BleLog.log(ProxLogTags.lan,
              'host $key went anonymous — dropped cached prof identity');
        }
        if (_gatedPhotoByHost.remove(key) != null) changed = true;
        if (_profVerifyByHost.remove(key) != null) changed = true;
        _profVerifyEmailByHost.remove(key);
        if (_windowNoByHost.remove(key) != null) changed = true;
      } else {
        if (_windowNoByHost[key] != probe.windowNo) {
          _windowNoByHost[key] = probe.windowNo;
          changed = true;
        }
        if (_gatedEmailByHost[key] != email) {
          _gatedEmailByHost[key] = email;
          changed = true;
        }
        // Different professor on the same host:port (sign-out → another
        // account re-hosting the same IP): the old label was earned by
        // someone else — drop it so the recompute below starts honest.
        // A 'verified' from the previous professor must never badge the
        // next one.
        if (_profVerifyEmailByHost[key] != null &&
            _profVerifyEmailByHost[key] != email &&
            _profVerifyByHost.remove(key) != null) {
          changed = true;
          BleLog.log(ProxLogTags.sec,
              'host $key changed professor — dropped stale verify label');
        }
        // Same gated photo cached per host for the browse tiles (photo
        // shows iff the host published one — i.e. the per-course opt-in
        // is on). Empty photo with a cached one = opt-out mid-session.
        if (photo.isNotEmpty) {
          if (_gatedPhotoByHost[key] != photo) {
            _gatedPhotoByHost[key] = photo;
            changed = true;
          }
        } else if (_gatedPhotoByHost.remove(key) != null) {
          changed = true;
        }
        // Pin-cache presence for the tile caption (honest pre-join state:
        // a cached pin means the key WILL be checked on join; no pin means
        // first-seen TOFU. Never claims verified without a key match —
        // the prove-time verdict upgrades this to verified/mismatch).
        if (!_profVerifyByHost.containsKey(key)) {
          try {
            final pins =
                await ref.read(deviceStoreProvider).readProfPin(email);
            final label = pins.isNotEmpty ? 'known' : 'first-seen';
            _profVerifyByHost[key] = label;
            _profVerifyEmailByHost[key] = email;
            changed = true;
          } catch (_) {}
        }
      }
      if (changed && phase == StudentPhase.browsing && mounted) {
        setState(() => _live = _allLive());
      }
    } catch (_) {}
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
    _gatedEmailByHost.remove(key);
    _gatedPhotoByHost.remove(key);
    _profVerifyByHost.remove(key);
    _profVerifyEmailByHost.remove(key);
    _markedDisplayByHost.remove(key);
    _windowNoByHost.remove(key);
    _emailFetchThrottle.remove(key);
  }

  /// Leaves waiting/marked for the browse list (hosting ended): room
  /// timers off, target cleared, list recomputed — never a dead waiting
  /// room, never a face re-scan on an ended class.
  void _toBrowsing(String notice) {
    if (!mounted) return;
    _dropInnerBackEntry();
    _stopRoomTimers();
    _waitingTarget = null;
    _roomWindowOpen = false;
    _connected = false;
    _roomMisses = 0;
    _roomProf = '';
    _roomProfEmail = '';
    _roomProfPhoto = '';
    _waitingCacheVerdict = null;
    _waitingCacheEmail = '';
    _cachedPhotoKey = '';
    _roomOrg = '';
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
  /// All re-probes carry our org claim (gated): a host that now answers
  /// org-mismatch goes silent here (dropped like a dead host — the class
  /// never appears on a foreign-org phone).
  /// Waiting-room badge state: the driver's last pin verdict, but ONLY
  /// when it belongs to this room's gated email (a stale verdict from a
  /// previous class must never badge the next room). Before the first
  /// prove, the provisional cache verdict applies (first-seen unverified
  /// banner when the pin cache is empty for this email; nothing otherwise).
  /// Null renders nothing.
  ProfVerificationResult? _waitingVerification() {
    ProfVerificationResult? provisional;
    try {
      provisional = _waitingCacheVerdict;
      final driver = ref.read(studentDriverProvider);
      if (driver is! RealStudentDriver) return provisional;
      final v = driver.lastProfVerification;
      if (v == null || v.profEmail.isEmpty) return provisional;
      // The verdict belongs to this room only when its email matches the
      // room's gated identity (falling back to the provisional email while
      // the gated fetch is still landing). Otherwise it is stale history
      // from a previous class — or a signed-out host — and must not badge
      // this room (unknown hosts render nothing).
      final roomEmail = _roomProfEmail.trim().toLowerCase();
      final wantEmail = roomEmail.isNotEmpty
          ? roomEmail
          : _waitingCacheEmail.trim().toLowerCase();
      if (wantEmail.isEmpty) return provisional;
      if (v.profEmail != wantEmail) return provisional;
      return v;
    } catch (_) {
      return provisional;
    }
  }

  /// One pin-cache read per waiting-room email (see [_waitingCacheVerdict]):
  /// empty cache ⇒ first-seen ⇒ provisional `unverified` banner. Called
  /// when the gated email first lands; never on the 2s tick. Never throws.
  Future<void> _refreshWaitingCacheVerdict(
      String email, int run, ClassBeacon target) async {
    try {
      final driver = ref.read(studentDriverProvider);
      if (driver is RealStudentDriver &&
          driver.lastProfVerification != null) {
        return; // prove already verdicts — provisional is obsolete.
      }
      final rows =
          await ref.read(deviceStoreProvider).readProfPin(email);
      if (!mounted || run != _runId || _waitingTarget != target) return;
      if (_roomProfEmail.trim().toLowerCase() != email) return;
      if (!mounted) return;
      setState(() {
        if (rows.isEmpty) {
          _waitingCacheVerdict = ProfVerificationResult(
            state: ProfEmailVerification.unverified,
            liveFetch: false,
            profEmail: email,
          );
        } else {
          _waitingCacheVerdict = null;
        }
      });
    } catch (_) {}
  }

  /// Offline-first auto-verify drain: first-seen prof emails queued while
  /// offline get a live direct fetch (online only) and their tile captions
  /// flip to verified without a rejoin. Never throws; no-ops offline.
  Future<void> _drainProfVerifyQueue() async {
    try {
      final driver = ref.read(studentDriverProvider);
      if (driver is! RealStudentDriver) return;
      final cloud = ref.read(cloudSyncProvider);
      if (!await cloud.isOnline()) return;
      final verdicts = await driver.verifyQueuedProfEmails();
      if (verdicts.isEmpty || !mounted) return;
      var changed = false;
      for (final entry in verdicts.entries) {
        for (final host in _gatedEmailByHost.entries) {
          if (host.value == entry.key && entry.value.name == 'known') {
            if (_profVerifyByHost[host.key] != 'verified-live') {
              _profVerifyByHost[host.key] = 'verified-live';
              _profVerifyEmailByHost[host.key] = entry.key;
              changed = true;
            }
          }
        }
      }
      if (changed && phase == StudentPhase.browsing && mounted) {
        setState(() => _live = _allLive());
      }
    } catch (_) {}
  }

  Future<void> _refreshSessions() async {
    if (!mounted || phase != StudentPhase.browsing) return;
    // 15s backstop also drains the prof auto-verify queue (online only).
    unawaited(_drainProfVerifyQueue());
    // Drop stale pending hints (heard >2 min ago, never answered).
    final now0 = DateTime.now().toUtc();
    _pendingHints
        .removeWhere((k, v) => now0.difference(v) > const Duration(minutes: 2));
    if (_sessionAck.isEmpty && _pendingHints.isEmpty) {
      return;
    }
    final now = DateTime.now().toUtc();
    var changed = false;
    final myOrg = _myOrg();
    final keys = <String>{..._sessionAck.keys, ..._pendingHints.keys};
    for (final key in keys) {
      final lastProbe = _bleHintThrottle[key];
      if (lastProbe != null && now.difference(lastProbe) < kSessionRefresh) {
        continue;
      }
      _bleHintThrottle[key] = now;
      final slash = key.lastIndexOf(':');
      if (slash < 0) continue;
      String missReason = 'unreachable';
      final hit = await probeHost(
          key.substring(0, slash), int.tryParse(key.substring(slash + 1)) ?? 0,
          verboseMisses: true, onMiss: (r) => missReason = r, org: myOrg);
      if (!mounted) return;
      if (hit == null) {
        _sessionFails[key] = (_sessionFails[key] ?? 0) + 1;
        // Pending hints log honestly (starting vs isolated); acked-session
        // misses stay quiet until the drop backstop fires below.
        if (_pendingHints.containsKey(key)) {
          BleLog.log(ProxLogTags.ble,
              'IP hint $key retry miss ($missReason, ${(_sessionFails[key] ?? 0)}/$kSessionMaxFails)');
        }
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
        BleLog.log(ProxLogTags.ble, 'IP hint $key answered on retry → listed');
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
  ///
  /// ORG-GATED: beacons whose org is stamped and mismatched against ours
  /// are EXCLUDED here (foreign org gets silence — the class never
  /// appears). Hints are already gated (their probeHost carried our claim
  /// and returned null on mismatch, so no entry exists). Legacy '' on
  /// either side passes (migration) and renders as before.
  List<LiveClass> _allLive() {
    final now = DateTime.now().toUtc();
    _hints.removeWhere((k, v) => !hintEntryAlive(
        now: now,
        lastSeen: v.lastSeen,
        lastAck: _sessionAck[k],
        fails: _sessionFails[k] ?? 0));
    final beacons = _listener.live();
    // classes listing = the AP eats broadcasts. Edge-logged once (never
    // silent, never spammy on the 2s refresh).
    final blocked = beacons.isEmpty && _hints.isNotEmpty;
    if (blocked && !_broadcastBlocked) {
      BleLog.log(ProxLogTags.lan,
          'broadcast-blocked? 0 UDP beacons but ${_hints.length} BLE-hinted — hint+probe rung');
    }
    _broadcastBlocked = blocked;
    String myOrg = '';
    try {
      myOrg = _myOrg();
    } catch (_) {}
    bool orgAllows(String beaconOrg) {
      if (beaconOrg.isEmpty || myOrg.isEmpty) return true;
      return beaconOrg == myOrg;
    }

    final byKey = <String, LiveClass>{};
    for (final c in beacons) {
      if (!orgAllows(c.last.org)) continue; // gated silence: never listed
      byKey[c.last.key] = c;
    }
    for (final c in _hints.values) {
      byKey.putIfAbsent(c.last.key, () => c);
    }
    final out = byKey.values.toList()
      ..sort((a, b) => a.firstSeen.compareTo(b.firstSeen));
    // Gated email backfill for newly listed matching hosts (cheap,
    // throttled — see _backfillGatedEmail): browse tiles render the Gmail
    // once the unicast lands, without any tap.
    for (final c in out) {
      final key = c.last.key;
      if ((_gatedEmailByHost[key] ?? '').isEmpty && orgAllows(c.last.org)) {
        unawaited(_backfillGatedEmail(c.last.host, c.last.port));
      }
    }
    return out;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Disposal armor first: the route detaches the back entry on the way
    // out and removal always fires onRemove — it must no-op (ref and
    // setState are dead past this point; teardown below owns cleanup).
    _disposed = true;
    _dropInnerBackEntry();
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
    // Sync-on-reconnect trigger: a resume may be a reconnect (the app-wide
    // observer in main.dart also fires — double flushes single-flight, so
    // this student-side call is belt over suspenders for mark flows).
    if (state == AppLifecycleState.resumed && mounted) {
      unawaited(flushNow(ref));
      // Auto-verify queue: first-seen prof emails queued while offline get
      // a live direct fetch now — tiles flip to verified without a rejoin.
      unawaited(_drainProfVerifyQueue());
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
    BleLog.log(
        ProxLogTags.nav, 'join by IP ${target.host}:${target.port} → waiting');
    try {
      await ref
          .read(deviceStoreProvider)
          .writeLastHost('${target.host}:${target.port}');
    } catch (_) {}
    _roundMarks.clear();
    await _enterWaitingRoom(target);
  }

  /// True when [linked] is bound to the CURRENT signed-in account (same
  /// Gmail, case-insensitive). A stale linked identity from a previous
  /// account never passes — join/prove must resolve the current account,
  /// never any cached enrollment.
  bool _identityMatchesCurrent(SignedAccount? acct, LinkedIdentity? linked) {
    final want = acct?.email.trim().toLowerCase() ?? '';
    if (want.isEmpty || linked == null) return false;
    return linked.gmail.trim().toLowerCase() == want;
  }

  LinkedIdentity? _readLinked() {
    try {
      return ref.read(linkedIdentityProvider);
    } catch (_) {
      return null;
    }
  }

  SignedAccount? _readAccount() {
    try {
      final streamed = ref.read(accountProvider).valueOrNull;
      if (streamed != null) return streamed;
    } catch (_) {}
    // Stream loading gap (cold start / switch mid-flight): the synchronous
    // session is already current while the stream still replays. Fall back
    // so joins never refuse an enrolled returner as "unenrolled".
    try {
      return ref.read(authServiceProvider).current;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _checkJoinGates() async {
    var acct = _readAccount();
    var linked = _readLinked();
    if (!_identityMatchesCurrent(acct, linked)) {
      // Account-switch race: the stored enrollment already belongs to the
      // new account but linked has not relinked yet. One fail-soft relink
      // attempt before refusing (never throws, never touches providers on
      // a dead screen).
      if (acct != null) {
        try {
          await relinkLinkedIdentity(ref, acct);
        } catch (_) {}
        if (!mounted) return false;
        acct = _readAccount();
        linked = _readLinked();
      }
      if (!_identityMatchesCurrent(acct, linked)) {
        if (!mounted) return false;
        setState(
            () => joinError = 'Enroll this device first — identity is required.');
        return false;
      }
    }
    bool bleOk = false;
    try {
      bleOk = await ref.read(blePermissionProvider)();
    } catch (_) {
      bleOk = false;
    }
    if (!bleOk) {
      if (!mounted) return false;
      setState(() => joinError =
          'Bluetooth permission is required for proximity proofs. Enable it in Settings and rejoin.');
      return false;
    }
    // Async gap above may have outlived an account switch/sign-out:
    // re-resolve the CURRENT identity before proceeding.
    if (!mounted) return false;
    acct = _readAccount();
    linked = _readLinked();
    if (!_identityMatchesCurrent(acct, linked)) {
      if (!mounted) return false;
      setState(
          () => joinError = 'Enroll this device first — identity is required.');
      return false;
    }
    BtState power = BtState.on;
    try {
      power = await ref.read(btPowerProvider)();
    } catch (_) {
      power = BtState.on;
    }
    if (power == BtState.off) {
      final enabled = await requestEnableBluetooth();
      if (!mounted) return false;
      acct = _readAccount();
      linked = _readLinked();
      if (!_identityMatchesCurrent(acct, linked)) {
        if (!mounted) return false;
        setState(
            () => joinError = 'Enroll this device first — identity is required.');
        return false;
      }
      BtState now = BtState.on;
      try {
        now = await ref.read(btPowerProvider)();
      } catch (_) {}
      if (!enabled || now != BtState.on) {
        if (!mounted) return false;
        setState(() =>
            joinError = 'Bluetooth is off — turn it on to join the class.');
        return false;
      }
    }
    if (!mounted) return false;
    acct = _readAccount();
    linked = _readLinked();
    if (!_identityMatchesCurrent(acct, linked)) {
      if (!mounted) return false;
      setState(
          () => joinError = 'Enroll this device first — identity is required.');
      return false;
    }
    return true;
  }

  /// Open-window join (face check first, no waiting room yet): [profName]
  /// and [org] are the tapped announcement's already-available identity
  /// (null = same-room advance from waiting via [_advanceToFace], which
  /// preserves the waiting room's values; non-null — even '' for a
  /// hint-only/typed entry with no announcement heard — replaces them so a
  /// stale previous room's name can never leak into this join's rewait
  /// waiting room). Stored trimmed; the waiting card trims again.
  Future<void> _joinBeacon(ClassBeacon target,
      {String? profName, String? org}) async {
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
    // The prewarm gap may have outlived an account switch/sign-out: resolve
    // the CURRENT identity again and refuse rather than entering face check
    // with a stale/missing identity.
    final freshAcct = _readAccount();
    final freshLinked = _readLinked();
    if (!_identityMatchesCurrent(freshAcct, freshLinked)) {
      if (!mounted) return;
      setState(() =>
          joinError = 'Enroll this device first — identity is required.');
      return;
    }
    BleLog.log(ProxLogTags.nav,
        'live window for ${target.host}:${target.port} → face check');
    setState(() {
      joinError = '';
      phase = StudentPhase.faceCheck;
      _faceAttempts = 0;
      _faceMismatchLiveness = false;
      _autoFaceTries = 0;
      _autoFaceDeadline = null;
      faceNotice = '';
      if (profName != null) _roomProf = profName.trim();
      if (org != null) _roomOrg = org.trim();
    });
    // First back press from here returns to the class list (entry held
    // once per join; re-entry from waiting is a null-guarded no-op).
    _pushInnerBackEntry();
    final linked = _readLinked();
    final acct = _readAccount();
    if (linked != null && _identityMatchesCurrent(acct, linked)) {
      _scheduleAutoScan(target, linked);
    }
  }

  /// Waiting-room entry (req 1): Join never starts face scan. It registers
  /// presence, pre-warms BLE, and shows Connected / Not connected + waiting
  /// for the professor. When the window opens the room auto-advances.
  /// [immediateProbe] true falls back to an immediate GET /window when the
  /// presence POST itself flaked (no piggybacked sample); false parks and
  /// lets the 2s poll own the first sample (UDP idle beacons already say
  /// closed). A sent presence already carries the live window flag, so the
  /// entry fast-path below spends zero extra GETs either way.
  /// [profName]/[profEmail]/[org] are the tapped announcement's
  /// already-available identity (email from the gated cache when known),
  /// shown on the waiting card (absent = typed-IP join with no announcement
  /// heard: the card shows the class only; round rewaits pass the current
  /// values back to preserve them — the gated poll below refreshes email).
  /// [profPhoto] is the cached gated photo for this host ('' = unseen):
  /// paints instantly and survives round rewaits; the room poll below
  /// converges when the host publishes late.
  Future<void> _enterWaitingRoom(ClassBeacon target,
      {bool immediateProbe = true,
      String? profName,
      String? profEmail,
      String? profPhoto,
      String? org}) async {
    if (!await _checkJoinGates()) return;
    if (!mounted) return;
    // Null-safe re-read (never force-unwrap): the join-gate gaps above may
    // have outlived an account switch/sign-out. Refuse rather than crashing
    // on a stale `!`.
    var linked = _readLinked();
    var acct = _readAccount();
    if (linked == null || !_identityMatchesCurrent(acct, linked)) {
      if (!mounted) return;
      setState(
          () => joinError = 'Enroll this device first — identity is required.');
      return;
    }
    try {
      await ref.read(studentDriverProvider).prewarmRadio();
    } catch (_) {}
    if (!mounted) return;
    // Prewarm gap may have outlived a switch: re-resolve before opening the
    // room so presence never files as a stale identity.
    linked = _readLinked();
    acct = _readAccount();
    if (linked == null || !_identityMatchesCurrent(acct, linked)) {
      if (!mounted) return;
      setState(
          () => joinError = 'Enroll this device first — identity is required.');
      return;
    }
    _stopRoomTimers();
    // New room generation: any probe still in flight from a previous room
    // (rewaits re-enter here without leaving the flow) carries the old run
    // and its result is dropped in _pollRoomOnce — stale results must not
    // clobber the fresh room's Connected state. Also releases the previous
    // generation's poll guard (its finally is run-checked and won't clear
    // the new room's flag).
    final run = ++_runId;
    _roomPollBusy = false;
    BleLog.log(ProxLogTags.nav, 'waiting room ${target.host}:${target.port}');
    final cachedEmail =
        _gatedEmailByHost['${target.host}:${target.port}'] ?? '';
    setState(() {
      joinError = '';
      _waitingTarget = target;
      _connected = false;
      _roomMisses = 0;
      _roomProfPhoto = '';
      _roomWindowOpen = false;
      _roomClass = target.classLabel;
      // Empty-vs-null: rewait passes the current (possibly stale '')
      // values back — a blank must fall through to the live fallbacks
      // (gated email cache / beacon target org) instead of pinning blank
      // over them. Fresh typed-IP joins pass null and clear as before.
      _roomProf = profName?.trim() ?? '';
      _roomProfEmail = (profEmail == null || profEmail.trim().isEmpty)
          ? cachedEmail
          : profEmail;
      _roomOrg =
          (org == null || org.trim().isEmpty) ? target.org : org;
      phase = StudentPhase.waiting;
      _faceAttempts = 0;
      _faceMismatchLiveness = false;
      _autoFaceTries = 0;
      _autoFaceDeadline = null;
      _waitingCacheVerdict = null;
      _waitingCacheEmail = '';
      faceNotice = '';
    });
    // First back press from here returns to the class list (entry held
    // once per join; round rewaits re-enter safely via the null guard).
    _pushInnerBackEntry();
    // Instant provisional banner when the gated email is already cached
    // for this host (the 2s poll re-lands it anyway — this just skips the
    // first-tick delay).
    final entryEmail = _roomProfEmail.trim().toLowerCase();
    if (entryEmail.isNotEmpty) {
      _waitingCacheEmail = entryEmail;
      unawaited(_refreshWaitingCacheVerdict(entryEmail, run, target));
    }
    // Join identity for stale-switch guards below: timers/probes must never
    // file presence or flip state as a previous account after a rapid
    // switch/sign-out. [linked] is the CURRENT account's identity here
    // (validated above); every continuation re-reads and compares.
    final joinEmail = linked.gmail.trim().toLowerCase();
    final joinIdentity = linked;
    // Presence heartbeat (prof sees n waiting + volunteered photo). The
    // reply piggybacks the live window flag (SYNC fast-path): a sent
    // presence already proves the host reachable over TLS, so entry reuses
    // that sample instead of spending a second (rate-capped) GET /window —
    // one fewer handshake on join→face and one fewer hit in the server's
    // 5-hits/10s/IP budget. The 2s poll below stays the authoritative flip
    // (generation-guarded, serialized, 429-held); [immediateProbe] now only
    // governs the fallback immediate GET when the POST itself flaked.
    PresenceSample? sample;
    try {
      sample = await ref.read(studentDriverProvider).sendPresence(
          target: target, identity: joinIdentity, photoUrl: _ownPhoto());
    } catch (_) {
      sample = null;
    }
    if (!mounted || run != _runId) return;
    // Account switched/signed out during the presence POST: abandon the
    // fresh room rather than flipping it with a stale sample.
    final postAcct = _readAccount();
    final postLinked = _readLinked();
    if (postLinked == null ||
        postLinked.gmail.trim().toLowerCase() != joinEmail ||
        !_identityMatchesCurrent(postAcct, postLinked)) {
      return;
    }
    final entry = sample;
    if (entry != null && entry.sent) {
      // Proof of life stronger than a GET: mark Connected at once (the
      // poll below still owns window flips + misses, run-guarded as ever).
      setState(() {
        _connected = true;
        _roomMisses = 0;
        _roomWindowOpen = entry.windowOpen;
        if (entry.display.trim().isNotEmpty) {
          _roomDisplay = entry.display.trim();
        }
      });
      // Fast path: window already open (e.g. rejoin mid-window, or a
      // stale-closed beacon on the tile path) → face check, zero extra GET.
      // Never for the round already marked here (transient-closed bounce).
      if (entry.windowOpen && _mayAutoFace(target, entry.display)) {
        _advanceToFace(target);
        return;
      }
    } else if (immediateProbe) {
      await _pollRoomOnce(run);
      // Fast path: window already open (e.g. rejoin mid-window) → face check.
      if (!mounted) return;
      if (_roomWindowOpen && _mayAutoFace(target, _roomDisplay)) {
        _advanceToFace(target);
        return;
      }
    }
    _presenceBeat = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!mounted || run != _runId || phase != StudentPhase.waiting) return;
      // Stale-identity guard: never heartbeat as a previous account after a
      // rapid switch. Bail quietly — the account listener/gate owns routing;
      // this room's generation is already obsolete.
      final beatLinked = _readLinked();
      final beatAcct = _readAccount();
      if (beatLinked == null ||
          beatLinked.gmail.trim().toLowerCase() != joinEmail ||
          !_identityMatchesCurrent(beatAcct, beatLinked)) {
        return;
      }
      try {
        await ref.read(studentDriverProvider).sendPresence(
            target: target, identity: beatLinked, photoUrl: _ownPhoto());
      } catch (_) {}
    });
    _roomPoll = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted || run != _runId || phase != StudentPhase.waiting) return;
      final pollLinked = _readLinked();
      final pollAcct = _readAccount();
      if (pollLinked == null ||
          pollLinked.gmail.trim().toLowerCase() != joinEmail ||
          !_identityMatchesCurrent(pollAcct, pollLinked)) {
        return;
      }
      // Serialized: a probe may outlive the 2s cadence (timeout budget is
      // 4s). Overruns skip, never pile up — concurrent probes would race
      // on _roomMisses/_connected and double the GET /window rate into the
      // server's 5-hits/10s/IP cap (self-inflicted 429s).
      if (_roomPollBusy) return;
      _roomPollBusy = true;
      try {
        await _pollRoomOnce(run);
      } finally {
        // Only the current generation owns the guard: a stale poll
        // draining after a rewait must not clear the new room's flag.
        if (run == _runId) _roomPollBusy = false;
      }
      if (!mounted || run != _runId) return;
      if (_roomWindowOpen &&
          phase == StudentPhase.waiting &&
          _mayAutoFace(target, _roomDisplay)) {
        _advanceToFace(target);
      }
    });
  }

  Future<void> _pollRoomOnce(int run) async {
    final target = _waitingTarget;
    if (target == null || !mounted) return;
    String myOrg = '';
    try {
      myOrg = _myOrg();
    } catch (_) {}
    try {
      final probe = await ref
          .read(studentDriverProvider)
          .probeWindow(target, myOrg: myOrg);
      if (!mounted) return;
      // Stale-generation guard: a rewait/Cancel/rejoin started a new room
      // while this probe was in flight — its result must not clobber the
      // new room's state (the classic flicker: old Not-connected landing
      // on a fresh Connected room, or vice versa).
      if (run != _runId || _waitingTarget != target) return;
      // Account switched/signed out mid-probe: drop the stale sample rather
      // than flipping the fresh room's badge with it.
      final freshLinked = _readLinked();
      final freshAcct = _readAccount();
      if (freshLinked == null ||
          !_identityMatchesCurrent(freshAcct, freshLinked)) {
        return;
      }
      if (probe.rateLimited) {
        // HTTP 429 is proof of life (the host answered over TLS) — hold
        // the badge steady: no miss, no _connected flip, no window change.
        // ROOT CAUSE of the Connected↔Not-connected oscillation: the 2s
        // poll sits exactly at the professor server's 5-hits/10s/IP cap
        // (server.dart _windowLimits; 6th GET → 429), and the transport
        // reports non-200 as unreachable — so a perfectly healthy link
        // 429'd one tick every ~10s (entry probe + 5 ticks, plus any
        // overlapping/backfill GET), flipping the badge for exactly one
        // tick and, under crowded NAT, false-exiting to "Class ended".
        // Genuine loss still flips on the very next unreachable tick
        // below — responsiveness is unchanged. Next tick repolls normally.
        BleLog.log(ProxLogTags.lan, 'room poll rate-limited — holding state');
        return;
      }
      if (!probe.reachable) {
        // Gated silence (org-mismatch) reads like hosting-ended here: the
        // class never appears for a foreign org. Single misses just show
        // the state; 5 consecutive misses leave for the live list.
        if (++_roomMisses >= 5) {
          final key = '${target.host}:${target.port}';
          BleLog.log(
              ProxLogTags.lan, 'hosting ended while waiting → live list');
          _dropHostEntries(key);
          _toBrowsing('Class ended — back to the live list.');
          return;
        }
      } else {
        _roomMisses = 0;
      }
      // Gated email lands here (matching/legacy org): cache + waiting card.
      final email = probe.profEmail.trim().toLowerCase();
      if (email.isEmpty && _roomProfEmail.trim().isNotEmpty) {
        // Host went anonymous mid-wait (professor signed out — sign-out
        // ends hosting, but a lingering server may answer one more poll
        // first): drop the room identity + provisional verdict so the
        // card stops showing the previous professor's email/photo and
        // the badge stops claiming verified for them. Browse maps for
        // this host go too (backfill re-adds if identity returns).
        final key = '${target.host}:${target.port}';
        _roomProfEmail = '';
        _roomProfPhoto = '';
        _waitingCacheVerdict = null;
        _waitingCacheEmail = '';
        _gatedEmailByHost.remove(key);
        _gatedPhotoByHost.remove(key);
        _profVerifyByHost.remove(key);
        _profVerifyEmailByHost.remove(key);
        _windowNoByHost.remove(key);
        BleLog.log(ProxLogTags.lan,
            'host $key went anonymous — room identity cleared');
      }
      if (email.isNotEmpty) {
        _gatedEmailByHost['${target.host}:${target.port}'] = email;
        // First landing of this room's email: one pin-cache read for the
        // provisional unverified banner (see _refreshWaitingCacheVerdict).
        if (email != _waitingCacheEmail) {
          _waitingCacheEmail = email;
          unawaited(_refreshWaitingCacheVerdict(email, run, target));
        }
      }
      // Same gated photo cached per host for the browse tiles (photo shows
      // iff the host published one — i.e. the per-course opt-in is on).
      final roomPhoto = probe.profPhoto.trim();
      if (roomPhoto.isNotEmpty) {
        _gatedPhotoByHost['${target.host}:${target.port}'] = roomPhoto;
      }
      setState(() {
        _connected = probe.reachable;
        _roomWindowOpen = probe.windowOpen;
        if (probe.display.trim().isNotEmpty) {
          _roomDisplay = probe.display.trim();
        }
        if (probe.classLabel.isNotEmpty) _roomClass = probe.classLabel;
        if (email.isNotEmpty) _roomProfEmail = email;
        if (probe.profPhoto.trim().isNotEmpty) {
          _roomProfPhoto = probe.profPhoto.trim();
        }
        // Gated LAN name converges like email/photo (latest-non-empty, never
        // clobbered by ''): hint-only rooms (no UDP beacons) learn the prof
        // display name here on the next 2s poll.
        final gatedName = probe.profName.trim();
        if (gatedName.isNotEmpty && _roomProf != gatedName) {
          _roomProf = gatedName;
          BleLog.log(ProxLogTags.lan, 'gated prof name: $gatedName');
        }
      });
      // Cache the photo per course for the course LIST (which has no live
      // connection): once per distinct pair, best-effort, never blocking.
      final cacheKey = '${_roomClass.trim()}|$_roomProfPhoto'.trim();
      if (_roomClass.trim().isNotEmpty &&
          _roomProfPhoto.isNotEmpty &&
          cacheKey != _cachedPhotoKey) {
        _cachedPhotoKey = cacheKey;
        unawaited(ref
            .read(deviceStoreProvider)
            .writeCourseProfPhoto(_roomClass.trim(), _roomProfPhoto)
            .catchError((_) {}));
      }
    } catch (_) {
      // Same stale-generation guard as above: a previous room's failed
      // probe must not flip the new room to Not connected.
      if (!mounted || run != _runId || _waitingTarget != target) return;
      if (++_roomMisses >= 5) {
        final t = _waitingTarget;
        if (t != null) {
          BleLog.log(
              ProxLogTags.lan, 'hosting ended while waiting → live list');
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
    final scanEmail = linked.gmail.trim().toLowerCase();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || phase != StudentPhase.faceCheck || _autoFaceFired) {
        return;
      }
      // Account switched while the face step sat idle: never scan as the
      // previous identity.
      final fresh = _readLinked();
      final freshAcct = _readAccount();
      if (fresh == null ||
          fresh.gmail.trim().toLowerCase() != scanEmail ||
          !_identityMatchesCurrent(freshAcct, fresh)) {
        return;
      }
      _autoFaceFired = true;
      _scanFace(target, fresh);
    });
  }

  Future<void> _scanFace(ClassBeacon target, LinkedIdentity linked) async {
    // Single-flight: concurrent auto-fire + manual taps never overlap
    // captures (double-push would stack two camera sheets).
    if (_scanBusy) return;
    _scanBusy = true;
    try {
      // Manual tap before the post-frame callback must not double-push.
      _autoFaceFired = true;
      final scanEmail = linked.gmail.trim().toLowerCase();
    // L1: records-only devices never scan — guidance, nothing consumed,
    // nothing signed.
    if (!canUseFace()) {
      BleLog.log(ProxLogTags.face, 'face blocked: records-only device');
      if (!mounted) return;
      setState(() => faceNotice =
          'Marking needs the mobile app (Android/iOS) — this device is records-only.');
      return;
    }
    // Parallel face + mesh (req 1): the scan pre-warmed at join keeps
    // running (and relaying) under the camera UI; we only wait on the face
    // verdict here. The challenge wait is armed AFTER the face passes, so a
    // token heard during the camera UI can never be reused as proof for a
    // rotated/restarted round (air carries no window ID — a pre-face token
    // verifies against nothing and fails as "prof signature mismatch").
    // Marking captures a short burst ([kMarkingLivenessCaptures] stills,
    // ~350ms apart) and the driver decides vitality on the MAX: one still
    // can dip on transient noise while spoofs score consistently low.
    // Match→stamp+prove; readable mismatch→burn one of the 4 attempts
    // (whole session); inconclusive (incl. the near-miss vitality
    // band)→rescan in the session burning nothing.
    //
    // The verify runs INSIDE the open sheet ([accept]): inconclusive
    // bursts re-capture on the SAME preview (~1s apart, 7s window — the
    // holder just keeps holding still, never taps retry, never sees the
    // camera flash). The sheet pops only on a terminal verdict (pass /
    // mismatch / stale / blocked) or a spent window. Capturers without
    // [accept] support (tests) pop at once and the caller verifies below.
    _modalResult = null;
    _modalExhausted = false;
    final paths = await ref.read(stillCapturerProvider).capture(
      context,
      captures: kMarkingLivenessCaptures,
      autoFire: true,
      accept: (burst) async {
        if (!mounted || phase != StudentPhase.faceCheck) return true;
        var inModal = _readLinked();
        var inModalAcct = _readAccount();
        if (inModal == null ||
            inModal.gmail.trim().toLowerCase() != scanEmail ||
            !_identityMatchesCurrent(inModalAcct, inModal)) {
          return true;
        }
        FaceCheckResult res;
        try {
          res = await ref.read(studentDriverProvider).checkFaceAny(burst);
        } on StateError {
          _modalResult = const FaceCheckResult(FaceMatch.blocked);
          return true;
        }
        if (!mounted || phase != StudentPhase.faceCheck) return true;
        inModal = _readLinked();
        inModalAcct = _readAccount();
        if (inModal == null ||
            inModal.gmail.trim().toLowerCase() != scanEmail ||
            !_identityMatchesCurrent(inModalAcct, inModal)) {
          return true;
        }
        _modalResult = res;
        // Low-vitality stays in preview: a very-low-score burst (possible
        // photo/screen OR transient shadow/blur) must NOT exit the camera
        // and waste a retry — it retries in place till the 7s window
        // spends, exactly like inconclusive. Only a spent window converts
        // it to a terminal mismatch (burns one attempt). Identity
        // mismatches (readable wrong face, livenessFailed=false) still pop
        // at once — they are decisions, not lighting.
        final retryableLowVitality = res.match == FaceMatch.mismatch &&
            res.livenessFailed;
        if (res.match != FaceMatch.inconclusive && !retryableLowVitality) {
          return true;
        }
        // No readable verdict (attempt kept) OR retryable low vitality:
        // retry in place while the window holds; the sheet owns the gap,
        // this owns the budget.
        _autoFaceTries++;
        final now = DateTime.now();
        _autoFaceDeadline ??= now.add(_autoFaceWindow);
        final gap = nextAutoFaceRetryDelay(
          tries: _autoFaceTries,
          tryCap: _autoFaceTryCap,
          gap: _autoFaceGap,
          now: now,
          deadline: _autoFaceDeadline!,
        );
        BleLog.log(ProxLogTags.face,
            '${res.match == FaceMatch.inconclusive ? 'face inconclusive' : 'face low-vitality'} — auto-retry in place ($_autoFaceTries)');
        if (gap == null) {
          _modalExhausted = true;
          // Window spent on a low-vitality burst: keep the mismatch
          // verdict (burns one attempt below); spent inconclusive keeps
          // the inconclusive verdict (manual Scan below).
          if (retryableLowVitality) _modalResult = res;
        } else if (retryableLowVitality) {
          // Still retrying: hold the preview with an inconclusive-grade
          // notice (no attempt burned yet).
          _modalResult = const FaceCheckResult(FaceMatch.inconclusive);
        }
        return gap == null;
      },
      acceptWindow: _autoFaceWindow,
      acceptGap: _autoFaceGap,
    );
    // Mounted-before-ref + back/teardown guard: Cancel/Back/system-back
    // leaves faceCheck during the camera UI — never verify or prove after it.
    if (paths == null ||
        paths.isEmpty ||
        !mounted ||
        phase != StudentPhase.faceCheck) {
      return;
    }
    // Capture gap may have outlived a switch/sign-out: never verify or prove
    // as a stale identity.
    var fresh = _readLinked();
    var freshAcct = _readAccount();
    if (fresh == null ||
        fresh.gmail.trim().toLowerCase() != scanEmail ||
        !_identityMatchesCurrent(freshAcct, fresh)) {
      return;
    }
    late final FaceCheckResult res;
    try {
      // In-modal verdict wins (verified while the preview stayed up);
      // legacy capturers pop at once, so verify here exactly as before.
      res = _modalResult ??
          await ref.read(studentDriverProvider).checkFaceAny(paths);
      _modalResult = null;
    } on StateError {
      if (!mounted) return;
      setState(() => faceNotice =
          'Marking needs the mobile app (Android/iOS) — this device is records-only.');
      return;
    }
    // CheckFace gap may have outlived Cancel/Back — same teardown guard.
    if (!mounted || phase != StudentPhase.faceCheck) return;
    fresh = _readLinked();
    freshAcct = _readAccount();
    if (fresh == null ||
        fresh.gmail.trim().toLowerCase() != scanEmail ||
        !_identityMatchesCurrent(freshAcct, fresh)) {
      return;
    }
    switch (res.match) {
      case FaceMatch.pass:
        BleLog.log(ProxLogTags.face, 'face pass — continuing to proving');
        if (!mounted) return;
        setState(() => faceNotice = '');
        // C5: holder evidence travels as the check object, never raw
        // doubles — the SK-use gate was stamped ONLY by the [checkFace]
        // above, and the listen binds this object's scores.
        await _listenWithCheck(target, fresh, res);
      case FaceMatch.mismatch:
        // Low-vitality legacy path (no in-modal stay): don't burn on the
        // first low burst — retry hands-free in the 7s window like
        // inconclusive. Spent windows (in-modal _modalExhausted, or the
        // outer budget below) still burn. Identity mismatches
        // (livenessFailed=false) always burn at once.
        if (res.livenessFailed && !_modalExhausted) {
          _autoFaceTries++;
          final lowNow = DateTime.now();
          _autoFaceDeadline ??= lowNow.add(_autoFaceWindow);
          final lowGap = nextAutoFaceRetryDelay(
            tries: _autoFaceTries,
            tryCap: _autoFaceTryCap,
            gap: _autoFaceGap,
            now: lowNow,
            deadline: _autoFaceDeadline!,
          );
          if (lowGap != null) {
            BleLog.log(ProxLogTags.face,
                'face low-vitality — auto-retry ($_autoFaceTries)');
            if (!mounted) return;
            setState(() => faceNotice =
                'Scan unclear — hold still, retrying automatically…');
            Future.delayed(lowGap, () {
              if (!mounted || phase != StudentPhase.faceCheck) return;
              final retryLinked = _readLinked();
              final retryAcct = _readAccount();
              if (retryLinked == null ||
                  retryLinked.gmail.trim().toLowerCase() != scanEmail ||
                  !_identityMatchesCurrent(retryAcct, retryLinked)) {
                return;
              }
              _scanFace(target, retryLinked);
            });
            break;
          }
          _autoFaceDeadline = null;
          // Window spent: fall through to burn below.
        }
        _modalExhausted = false;
        _autoFaceDeadline = null;
        // Readable session, somebody else (or a consistent-low spoof after
        // the 7s window): the ONLY outcome that consumes one of the 4
        // attempts (a whole session, not one frame).
        BleLog.log(
            ProxLogTags.face, 'face mismatch — attempt consumed, needs review');
        if (!mounted) return;
        _faceAttempts++;
        _faceMismatchLiveness = res.livenessFailed;
        setState(() => phase = StudentPhase.needsReview);
      case FaceMatch.inconclusive:
        // No readable verdict (attempt kept). The open sheet already
        // retried in place until its window spent ([_modalExhausted]) —
        // park on the manual Scan button then. Legacy capturers (no
        // in-modal verify) keep the old re-push chain below.
        if (_modalExhausted) {
          _modalExhausted = false;
          _autoFaceDeadline = null;
          BleLog.log(ProxLogTags.face,
              'face inconclusive — window spent in place, manual Scan');
          if (!mounted) return;
          setState(() => faceNotice =
              'Could not read that scan — adjust light and tap Scan to try again.');
          return;
        }
        // No readable verdict (attempt kept): keep re-scanning hands-free
        // inside a 7s window (~1s apart) with a steady prompt, then fall
        // back to the manual Scan button. Cancel/back exits via the
        // teardown guards below; an account switch mid-gap never scans as
        // the stale identity.
        _autoFaceTries++;
        final now = DateTime.now();
        _autoFaceDeadline ??= now.add(_autoFaceWindow);
        final gap = nextAutoFaceRetryDelay(
          tries: _autoFaceTries,
          tryCap: _autoFaceTryCap,
          gap: _autoFaceGap,
          now: now,
          deadline: _autoFaceDeadline!,
        );
        BleLog.log(ProxLogTags.face,
            'face inconclusive — auto-retry ($_autoFaceTries)');
        if (gap != null) {
          if (!mounted) return;
          setState(() => faceNotice =
              'Scan unclear — hold still, retrying automatically…');
          Future.delayed(gap, () {
            if (!mounted || phase != StudentPhase.faceCheck) return;
            final retryLinked = _readLinked();
            final retryAcct = _readAccount();
            if (retryLinked == null ||
                retryLinked.gmail.trim().toLowerCase() != scanEmail ||
                !_identityMatchesCurrent(retryAcct, retryLinked)) {
              return;
            }
            _scanFace(target, retryLinked);
          });
        } else {
          _autoFaceDeadline = null;
          if (!mounted) return;
          setState(() => faceNotice =
              'Could not read that scan — adjust light and tap Scan to try again.');
        }
      case FaceMatch.staleTemplate:
        // FaceId predates the plugin pipeline: matching against it would
        // be meaningless. Park on the check screen with a re-enroll
        // notice — no attempt consumed, nothing signed.
        BleLog.log(ProxLogTags.face, 'stale face — re-enroll, nothing signed');
        if (!mounted) return;
        setState(() => faceNotice =
            'Face recognition was updated — re-enroll this device from the home screen, then join again.');
      case FaceMatch.blocked:
        // Records-only device (desktop/web L1 gate): guidance, nothing
        // consumed, nothing signed.
        BleLog.log(ProxLogTags.face, 'face blocked — records-only device');
        if (!mounted) return;
        setState(() => faceNotice =
            'Marking needs the mobile app (Android/iOS) — this device is records-only.');
      }
    } finally {
      _scanBusy = false;
    }
  }

  Future<void> _requestManual() async {
    final target = _waitingTarget ?? _parseTarget();
    final linked = _readLinked();
    final acct = _readAccount();
    if (target == null || linked == null || !_identityMatchesCurrent(acct, linked)) {
      if (!mounted) return;
      setState(
          () => joinError = 'Enroll this device first — identity is required.');
      return;
    }
    final manualEmail = linked.gmail;
    final manualIdentity = linked;
    BleLog.log(
        ProxLogTags.state, 'manual request → ${target.host} (polling prof)');
    if (!mounted) return;
    setState(() {
      _manualStatus = 'pending';
      phase = StudentPhase.manualPending;
    });
    try {
      await ref.read(studentDriverProvider).requestManual(
          target: target, identity: manualIdentity, photoUrl: _ownPhoto());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        joinError = 'Manual request failed: $e';
        phase = StudentPhase.waiting;
      });
      return;
    }
    if (!mounted) return;
    // Switch/sign-out during the request POST: never poll as a stale Gmail.
    final postLinked = _readLinked();
    final postAcct = _readAccount();
    if (postLinked == null ||
        postLinked.gmail.trim().toLowerCase() !=
            manualEmail.trim().toLowerCase() ||
        !_identityMatchesCurrent(postAcct, postLinked)) {
      if (!mounted) return;
      setState(() {
        phase = StudentPhase.browsing;
        joinError = 'Enroll this device first — identity is required.';
      });
      return;
    }
    final run = _runId;
    _manualPoll?.cancel();
    _manualPoll = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted || run != _runId || phase != StudentPhase.manualPending) {
        return;
      }
      final pollLinked = _readLinked();
      final pollAcct = _readAccount();
      if (pollLinked == null ||
          pollLinked.gmail.trim().toLowerCase() !=
              manualEmail.trim().toLowerCase() ||
          !_identityMatchesCurrent(pollAcct, pollLinked)) {
        return;
      }
      try {
        final st = await ref
            .read(studentDriverProvider)
            .pollManualStatus(target: target, email: manualEmail);
        if (!mounted || run != _runId) return;
        final afterLinked = _readLinked();
        final afterAcct = _readAccount();
        if (afterLinked == null ||
            afterLinked.gmail.trim().toLowerCase() !=
                manualEmail.trim().toLowerCase() ||
            !_identityMatchesCurrent(afterAcct, afterLinked)) {
          return;
        }
        if (!mounted) return;
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
          BleLog.log(
              ProxLogTags.state, 'manual rejected — parked, see professor');
          // Stays in manualPending showing the verdict (present-or-absent ACK).
        }
      } catch (_) {}
    });
  }

  /// C5 object path: the holder evidence travels as the [FaceCheckResult]
  /// from [StudentDriver.checkFace], never raw doubles. Real driver binds
  /// the object's scores; other drivers (fake/tests) keep the raw shape.
  Future<void> _listenWithCheck(ClassBeacon target, LinkedIdentity linked,
      FaceCheckResult faceCheck) async {
    final driver = ref.read(studentDriverProvider);
    if (driver is RealStudentDriver) {
      await _listenVia(
        target,
        linked,
        (startLinked, onStatus) => driver.listenAndProveWithCheck(
          target: target,
          identity: startLinked,
          faceCheck: faceCheck,
          onStatus: onStatus,
        ),
      );
      return;
    }
    await _listen(target, linked, faceCheck.score,
        faceValidAtMs: faceCheck.faceValidAtMs,
        verifierVer: faceCheck.verifierVer,
        livenessScore: faceCheck.livenessScore,
        livenessVer: faceCheck.livenessVer);
  }

  Future<void> _listen(ClassBeacon target, LinkedIdentity linked,
      double faceScore,
      {int faceValidAtMs = 0,
      String verifierVer = '',
      double? livenessScore,
      String? livenessVer}) async {
    final driver = ref.read(studentDriverProvider);
    await _listenVia(
      target,
      linked,
      (startLinked, onStatus) => driver.listenAndProve(
        target: target,
        identity: startLinked,
        faceScore: faceScore,
        faceValidAtMs: faceValidAtMs,
        verifierVer: verifierVer,
        livenessScore: livenessScore,
        livenessVer: livenessVer,
        onStatus: onStatus,
      ),
    );
  }

  /// Shared listen body: run/entry guards, listening UI, receipt routing.
  /// [prover] runs the driver (raw-score or check-object path); everything
  /// else here is identical so the two paths cannot drift.
  Future<void> _listenVia(
      ClassBeacon target,
      LinkedIdentity linked,
      Future<MarkedReceipt> Function(LinkedIdentity startLinked,
              void Function(ListenStatus s) onStatus)
          prover) async {
    final run = ++_runId;
    _rewaitTimer?.cancel();
    _rewaitTimer = null;
    _rewaitMisses = 0;
    final listenEmail = linked.gmail.trim().toLowerCase();
    // Never start proving as a stale identity (switch landed between face
    // pass and listen start).
    final startLinked = _readLinked();
    final startAcct = _readAccount();
    if (startLinked == null ||
        startLinked.gmail.trim().toLowerCase() != listenEmail ||
        !_identityMatchesCurrent(startAcct, startLinked)) {
      return;
    }
    _setWake(true);
    if (!mounted) {
      _setWake(false);
      return;
    }
    setState(() {
      phase = StudentPhase.listening;
      listenStatus = 'Waiting for the class signal…';
    });
    // No round clock: the driver loops on fresh challenges until a verdict
    // (marked/late/dead-air/error) — nothing here retries or counts down.
    final receipt = await prover(startLinked, (s) {
      if (!mounted || run != _runId) return;
      final sLinked = _readLinked();
      final sAcct = _readAccount();
      if (sLinked == null ||
          sLinked.gmail.trim().toLowerCase() != listenEmail ||
          !_identityMatchesCurrent(sAcct, sLinked)) {
        return;
      }
      setState(() => listenStatus = switch (s) {
            ListenStatus.waiting => 'Waiting for the class signal…',
            ListenStatus.proving => 'Signal heard — proving…',
            ListenStatus.confirming => 'Proof sent — confirming…',
          });
    });
    if (!mounted || run != _runId) return;
    // Switch/sign-out during the long prove: drop the stale receipt rather
    // than landing a verdict for the wrong account.
    final endLinked = _readLinked();
    final endAcct = _readAccount();
    if (endLinked == null ||
        endLinked.gmail.trim().toLowerCase() != listenEmail ||
        !_identityMatchesCurrent(endAcct, endLinked)) {
      _setWake(false);
      return;
    }
    _setWake(false);
    if (receipt.result == StudentResult.marked ||
        receipt.result == StudentResult.late) {
      // Per-round trail for the waiting-room card (R1, R2, … this join).
      _roundMarks.add('R${_roundMarks.length + 1} · ${receipt.detail}');
    }
    BleLog.log(ProxLogTags.state,
        'verdict ${receipt.result.name} (${receipt.detail})');
    // Prove-time pin verdict → browse tile caption + waiting badge state.
    // First-seen/verified/mismatch labels replace the cache-presence hint
    // for this host (offline unverified stays queued for auto-verify).
    try {
      final driver = ref.read(studentDriverProvider);
      final v = driver is RealStudentDriver
          ? driver.lastProfVerification
          : null;
      if (v != null && v.profEmail.isNotEmpty) {
        final hostKey = '${target.host}:${target.port}';
        final label = switch (v.state) {
          ProfEmailVerification.verified =>
            v.liveFetch ? 'verified-live' : 'verified',
          ProfEmailVerification.unverified => 'unverified',
          ProfEmailVerification.mismatch => 'mismatch',
          ProfEmailVerification.absent => '',
        };
        if (label.isNotEmpty && _profVerifyByHost[hostKey] != label) {
          _profVerifyByHost[hostKey] = label;
          _profVerifyEmailByHost[hostKey] = v.profEmail;
        }
      }
    } catch (_) {}
    // Wrong-org refusals surface as structured error receipts (no proof
    // sent, no PII left) with their own verdict screen — a decision, not
    // a network hole. Branches on the receipt flag, never detail text.
    final isWrongOrg =
        receipt.result == StudentResult.error && receipt.isWrongOrg;
    setState(() {
      ackDetail = receipt.detail;
      wrongClassOrg = receipt.classOrg;
      wrongMyOrg = receipt.myOrg;
      phase = switch (receipt.result) {
        StudentResult.marked => StudentPhase.marked,
        StudentResult.late => StudentPhase.late,
        StudentResult.faceFailed => StudentPhase.needsReview,
        StudentResult.noSignal => StudentPhase.noSignal,
        StudentResult.error =>
          isWrongOrg ? StudentPhase.wrongOrg : StudentPhase.noSignal,
      };
      if (receipt.result == StudentResult.error) {
        infoDetail = receipt.detail;
      }
    });
    if (receipt.result == StudentResult.marked ||
        receipt.result == StudentResult.late) {
      // Record the marked round so auto-advance never re-faces it (see
      // _mayAutoFace): a transient closed sample mid-round used to bounce
      // marked → waiting → face for the SAME round.
      if (receipt.display.trim().isNotEmpty) {
        _markedDisplayByHost['${target.host}:${target.port}'] =
            receipt.display.trim();
      }
      // Stay for the next round: once THIS round ends, rejoin the waiting
      // room (fast-paths straight back to face if the next window is
      // already open). No taps, face re-checks every round.
      _rewaitAfterRound(target, run, receipt.display);
    }
  }

  /// Parks on the verdict badge until the just-marked round ends, then
  /// rejoins the waiting room for the next round. Same-window re-face is
  /// impossible: we only leave when the probe says closed/unreachable, or
  /// when the window code changes (fast professor retake) — and every
  /// auto-advance re-checks the marked round via [_mayAutoFace], so even
  /// a transient closed sample mid-round can only park in waiting, never
  /// re-face. Single-shot chained timer (never a bare delayed future) so
  /// dispose/test teardown stays timer-clean.
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
        !(phase == StudentPhase.marked || phase == StudentPhase.late)) {
      return;
    }
    // Stale-identity guard: never rewait the next round as a previous
    // account. Bail quietly — the gate owns routing after a switch.
    final rewaitLinked = _readLinked();
    final rewaitAcct = _readAccount();
    if (rewaitLinked == null ||
        !_identityMatchesCurrent(rewaitAcct, rewaitLinked)) {
      return;
    }
    var rewait = false;
    var ended = false;
    var nextDisplay = '';
    String myOrg = '';
    try {
      myOrg = _myOrg();
    } catch (_) {}
    try {
      final probe = await ref
          .read(studentDriverProvider)
          .probeWindow(target, myOrg: myOrg);
      if (!mounted) return;
      final afterLinked = _readLinked();
      final afterAcct = _readAccount();
      if (afterLinked == null ||
          !_identityMatchesCurrent(afterAcct, afterLinked)) {
        return;
      }
      if (probe.rateLimited) {
        // 429 proves the host is alive — neither "round over" (window
        // state unknown) nor "hosting ended". Repoll with no miss counted
        // (same 429-misread-as-unreachable defect as the waiting room).
      } else if (!probe.reachable) {
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
        !(phase == StudentPhase.marked || phase == StudentPhase.late)) {
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
      await _enterWaitingRoom(target,
          profName: _roomProf,
          profEmail: _roomProfEmail,
          profPhoto: _roomProfPhoto,
          org: _roomOrg);
      return;
    }
    _rewaitAfterRound(target, run, markedDisplay);
  }

  /// In-flow back entry (system + app-bar back without a pushed route):
  /// the Mark flow is a view-state machine on ONE tab-root route, so the
  /// shell would otherwise treat back from any inner phase as tab-root
  /// back (hint, then app exit — the tab Navigator holds no pushed route
  /// to pop). While any non-browsing phase is showing, one
  /// [LocalHistoryEntry] sits on this route: the first back press removes
  /// it (no pop, no tab change, no shell hint) and its [onRemove] runs the
  /// same [_cancelToBrowsing] teardown as Cancel/Back — landing on the
  /// class list with the browse root untouched. Added once per join
  /// (null-guarded, never stacked); dropped silently whenever we land back
  /// on browsing through an explicit or programmatic path.
  ///
  /// Removal ALWAYS fires [onRemove] (framework contract — there is no
  /// silent detach), so programmatic drops set [_suppressEntryTeardown]
  /// around the remove, and [onRemove] itself bails when disposing or
  /// unmounted (route teardown at test/pump boundaries must never run
  /// flow teardown: ref/setState are dead there).
  LocalHistoryEntry? _innerBackEntry;
  bool _suppressEntryTeardown = false;
  bool _disposed = false;

  /// Ensures the in-flow back entry exists (no-op when one is already
  /// held). Call right after the setState that leaves browsing (join
  /// gates already passed); inner→inner hops re-enter safely via the
  /// null guard and never stack entries.
  void _pushInnerBackEntry() {
    if (!mounted || _disposed || _innerBackEntry != null) return;
    final route = ModalRoute.of(context);
    if (route == null) return;
    _innerBackEntry = LocalHistoryEntry(onRemove: () {
      _innerBackEntry = null;
      markInFlow.value = false;
      if (_suppressEntryTeardown || _disposed || !mounted) return;
      _cancelToBrowsing();
    });
    route.addLocalHistoryEntry(_innerBackEntry!);
    markInFlow.value = true;
  }

  /// Drops the in-flow back entry without running teardown (the landing
  /// is already browsing through an explicit, programmatic, or dispose
  /// path): nulls the ref first, then removes under suppression so the
  /// mandatory [onRemove] becomes a no-op instead of recursing.
  void _dropInnerBackEntry() {
    final entry = _innerBackEntry;
    _innerBackEntry = null;
    markInFlow.value = false;
    if (entry == null) return;
    _suppressEntryTeardown = true;
    try {
      entry.remove();
    } finally {
      _suppressEntryTeardown = false;
    }
  }

  /// Leaves any inner phase for the browse list: back entry dropped,
  /// run-guarded async work invalidated, room timers off, rewait chain
  /// parked, wakelock released, and explicit /leave so the professor count
  /// drops. Used by Cancel/Back actions and the back-entry handler (same
  /// teardown everywhere).
  void _cancelToBrowsing() {
    _dropInnerBackEntry();
    _runId++;
    _stopRoomTimers();
    _rewaitTimer?.cancel();
    _rewaitTimer = null;
    _setWake(false);
    _leaveWaitingRoom();
    if (!mounted) return;
    setState(() {
      _waitingTarget = null;
      phase = StudentPhase.browsing;
    });
  }

  /// Clock-drift banner copy from the live student driver (null when
  String? _driftBanner() {
    try {
      return ref.read(studentDriverProvider).clockDrift.banner;
    } catch (_) {
      return null;
    }
  }

  Widget _browsing(BuildContext context) {
    // Mark slim-down: no enrollment entry and no records entry on this
    // screen (Setup/Account own enrollment, Courses owns records; the Mark
    // gate already routes unenrolled users). Header is avatar + the exact
    // previous identity lines beside it (same strings as the pre-avatar
    // header) — only wiring lives here, callbacks stay host-owned
    // (nav/gate untouched).
    final linked = ref.watch(linkedIdentityProvider);
    final identityLine = linked == null
        ? 'Not enrolled — enroll this device to link identity.'
        : '${linked.name}${linked.roll.isNotEmpty ? ' · ${linked.roll}' : ''}\n${linked.gmail}';
    return BrowseClassesView(
      avatarName: linked?.name ?? '',
      avatarPhotoUrl: _ownPhoto(),
      identityLine: identityLine,
      // Split lines render as time → name → ID → email in the header.
      identityName: linked?.name ?? '',
      identityId: linked?.roll ?? '',
      identityEmail: linked?.gmail ?? '',
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
      broadcastBlocked: _broadcastBlocked,
      profEmailByHost: Map.of(_gatedEmailByHost),
      profPhotoByHost: Map.of(_gatedPhotoByHost),
      profVerifyByHost: Map.of(_profVerifyByHost),
      windowNoByHost: Map.of(_windowNoByHost),
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
          _typedHostPort = hp;
        });
        _roundMarks.clear();
        if (c.last.windowOpen) {
          // Carry the tapped announcement's identity: ClassBeacon drops
          // `prof`, and the post-round rewait waiting room can only show
          // what _joinBeacon stored here (the gated poll never carries a
          // display name).
          _joinBeacon(target, profName: c.last.prof, org: c.last.org);
        } else {
          _enterWaitingRoom(target,
              immediateProbe: false,
              profName: c.last.prof,
              profEmail: _gatedEmailByHost[hp],
              profPhoto: _gatedPhotoByHost[hp],
              org: c.last.org);
        }
      },
      onRefresh: () async {
        if (mounted) setState(() => _live = _allLive());
      },
    );
  }

  void _openLog() {
    BleLog.log(ProxLogTags.nav, 'mark → system log');
    // Overlay drawer (§4.5): proving/face keep listening while it is open —
    // no navigation/lifecycle interruption (never a route push of its own).
    // The drawer's Expand carries the tag filter into debug/log.
    showLogDrawer(context);
  }

  @override
  Widget build(BuildContext context) {
    final linked = ref.watch(linkedIdentityProvider);
    // Back contract (§3.5, navigation-shell rebuild): the shell owns
    // tab-root back — in-tab back pops that tab's stack only, tab-root
    // back hints (double-press leaves the app, OS-level). The Mark flow
    // is a view-state machine, not pushed routes, so the tab Navigator
    // holds nothing to pop here: the [_innerBackEntry] local-history
    // entry (added on every join, dropped on every browsing landing)
    // gives the first back press something in-tab to consume — the shell
    // pops the entry instead of hinting, and its onRemove runs the same
    // [_cancelToBrowsing] teardown as Cancel/Back. One step to the class
    // list from ANY inner phase (waiting / face / proving / manual /
    // paused / verdicts), never stepping through phases, never exiting
    // the Mark module on the first press; browsing itself holds no entry
    // so the shell's tab-root hint/double-exit still applies there.
    // No PopScope here (a veto would fight the entry: pop() consumes
    // local history before consulting vetoes, and the shell short-
    // circuits on canPop before any veto runs). The entry also drives the
    // platform-automatic app-bar back affordance on inner phases.
    final target = _parseTarget();
    return AdaptiveScaffold(
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
          onPressed: () {
            // Stale-stack reset first: the root setup-flow is dismissed
            // BEFORE the switch per the product decision, then the Mark
            // tab pops to root — the previous identity's screens can never
            // survive underneath. `setMode` is idempotent (a home switch,
            // never a push), so rapid taps cannot double-navigate.
            prepareAccountTransition(context);
            if (!mounted) return;
            unawaited(setMode(ref, AppMode.unset));
          },
        ),
      ],
      // Waiting → scan → verdict wrapped as ONE continuation: every hop
      // cross-fades (emphasized) instead of hard-cutting.
      body: MarkFlowShell(
        phase: phase,
        child: switch (phase) {
          StudentPhase.browsing => _browsing(context),
          StudentPhase.waiting => WaitingRoomView(
              connected: _connected,
              roomClass: _roomClass.isNotEmpty
                  ? _roomClass
                  : (_waitingTarget?.classLabel ?? 'this class'),
              roomProf: _roomProf,
              roomProfEmail: _roomProfEmail,
              roomProfPhoto: _roomProfPhoto,
              roomOrg: _roomOrg,
              roundMarks: _roundMarks,
              onRequestManual: _requestManual,
              onCancel: _cancelToBrowsing,
              // Live pin verdict for the gated email (verified live/cache,
              // first-seen unverified with online auto-verify, mismatch).
              // Unknown before the first prove renders nothing.
              profVerification: _waitingVerification(),
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
              // Failed check never dead-ends: manual request is one tap
              // away (button appears only with a failure notice).
              onRequestManual: _requestManual,
            ),
          StudentPhase.listening => ProvingView(
              status: listenStatus,
              driftBanner: _driftBanner(),
              onLeave: _cancelToBrowsing,
            ),
          // Terminal verdicts (composition lives in `verdict_section.dart`):
          // every verdict back runs the SAME `_cancelToBrowsing` teardown
          // so back lands directly on browsing in one step. Retry/manual
          // callbacks stay host-owned (flow logic untouched).
          StudentPhase.marked ||
          StudentPhase.late ||
          StudentPhase.wrongOrg ||
          StudentPhase.needsReview ||
          StudentPhase.noSignal =>
            markVerdictSection(
              phase: phase,
              ackDetail: ackDetail,
              infoDetail: infoDetail,
              wrongClassOrg: wrongClassOrg,
              wrongMyOrg: wrongMyOrg,
              roundMarks: _roundMarks,
              attemptsLeft: 4 - _faceAttempts,
              needsReviewDetail: _faceMismatchLiveness
                  ? 'The scan did not look live (possible photo or screen) — hold still in good light and try again.'
                  : '',
              onBackToBrowsing: _cancelToBrowsing,
              onRequestManual: _requestManual,
              onRetryFace: () {
                final t = _waitingTarget ?? target;
                final l = linked;
                setState(() => phase = StudentPhase.faceCheck);
                if (t != null && l != null) {
                  _scheduleAutoScan(t, l);
                }
              },
            ),
          // Paused keeps the same browsing destination via the shared
          // teardown (also drops the back entry — a plain setState would
          // leave a stale entry behind on the class list).
          StudentPhase.paused => PausedView(
              onBack: _cancelToBrowsing,
            ),
        },
      ),
    );
  }
}
