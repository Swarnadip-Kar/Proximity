// Live attendance for one course instance: host (advertise on WiFi so
// students see the class and join the waiting room) → Start (BLE+HTTPS
// window stays open until Stop — no countdown) → Take another round
// (+window, present = intersection of all windows) → End attendance
// (history saved, hosting down). Back ends hosting (ports closed, no
// orphaned window) but the tally autosaves per course and resumes on
// re-entry — even across a full app kill.
//
// Every round close (and every manual action) upserts the SAME class
// record in on-device history, so data survives even when the professor
// forgets to end: later rounds rewrite the same record. Export is a
// separate feature on the course page (per-session + date-range matrix).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/auth.dart';
import '../core/ble_radio.dart';
import '../core/cloud_sync.dart';
import '../core/device_store.dart';
import '../core/host_driver.dart';
import '../design/tokens.dart';
import '../main.dart';
import '../mode.dart';
import '../widgets/animated.dart';
import '../widgets/ble_log_view.dart';
import '../widgets/clock.dart';
import '../widgets/manual_add.dart';
import '../widgets/prox_cards.dart';
import '../widgets/prox_motion.dart';
import '../widgets/prox_states.dart';

class TakeAttendanceScreen extends ConsumerStatefulWidget {
  final String courseName;
  final bool autoStart;
  const TakeAttendanceScreen(
      {super.key, required this.courseName, this.autoStart = false});

  @override
  ConsumerState<TakeAttendanceScreen> createState() =>
      _TakeAttendanceScreenState();
}

/// Session-recovery policy: the "Recover old session?" prompt appears ONLY
/// when the autosaved draft is older than 2.5h (a genuinely old visit —
/// yesterday's class, a forgotten session). A recent draft (quick back-nav,
/// crash, app kill mid-lecture) is auto-archived to history as marked
/// attendance and the professor starts fresh — no prompt, no lost data.
const recoverPromptThreshold = Duration(minutes: 150);

/// Pure policy for tests: true = prompt, false = auto-archive + fresh.
@visibleForTesting
bool shouldPromptRecover(DateTime? savedAt, DateTime now) {
  if (savedAt == null) return false;
  return now.toUtc().difference(savedAt.toUtc()) > recoverPromptThreshold;
}

class _TakeAttendanceScreenState extends ConsumerState<TakeAttendanceScreen> {
  final TallyStore _fallbackTally = TallyStore();
  bool hosting = false;
  bool live = false;
  int _windowNo = 0;
  // Elapsed open time: the window stays open until Stop (no countdown —
  // slow provers are never stranded by a clock).
  Duration elapsed = Duration.zero;
  Timer? _t;
  Timer? _idlePoll;
  String search = '';
  String? serverLine;
  String? serverError;
  HostSession? _session;
  String _ip = '';
  bool _resumed = false;
  String? _draftDateIso;
  // Stable history id + class-start time for this visit: every round
  // rewrites the SAME class record (upsert), so un-closed sessions still
  // leave data behind and later rounds update it in place. The start time
  // is captured with the first snapshot and kept stable (students see
  // WHEN the class was, not when the last round pushed).
  String? _recordId;
  String? _recordStartIso;
  String _lastSavedSig = '';
  final _nameCtrl = TextEditingController();
  final Set<String> _manualSelected = {};
  // Toggleable terminal log (BLE RX → sighting match → tally → ACK).
  bool _showLog = false;

  TallyStore get tally {
    try {
      return ref.read(hostDriverProvider).tally;
    } catch (_) {
      return _fallbackTally;
    }
  }

  HostDriver? get _driver {
    try {
      return ref.read(hostDriverProvider);
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _host();
    _loadName();
    // Bluetooth off is otherwise a log-only failure: prompt once, up
    // front, with a tappable Turn-on (rounds need the radio).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) promptEnableBluetoothIfOff(context, ref);
    });
  }

  /// Prefills the professor display name (linked identity, else last saved).
  Future<void> _loadName() async {
    var name = ref.read(linkedIdentityProvider)?.name ?? '';
    try {
      final saved =
          await ref.read(deviceStoreProvider).readHostName();
      if (saved.isNotEmpty) name = saved;
    } catch (_) {}
    if (mounted && _nameCtrl.text.isEmpty && name.isNotEmpty) {
      setState(() => _nameCtrl.text = name);
    }
  }

  Future<void> _host() async {
    // Prompt FIRST: starting the idle BLE hint without BLUETOOTH_CONNECT
    // throws SecurityException spam (GattService.registerServer — the
    // peripheral plugin always advertises connectable, and no GATT service
    // of ours removes that). HTTPS hosting never waits on this; a denial
    // just shows guidance and Start re-asks.
    var permOk = true;
    try {
      permOk = await ref.read(blePermissionProvider)();
    } catch (_) {
      permOk = false;
    }
    if (!permOk && mounted) {
      setState(() => serverError =
          'Bluetooth permission is required to announce this class over radio. Enable it in Settings — students can still join by IP until then.');
    }
    HostSession session;
    try {
      session = await ref
          .read(hostDriverProvider)
          .startHosting(classLabel: widget.courseName);
    } catch (e) {
      if (!mounted) return;
      setState(() => serverError = '$e');
      return;
    }
    if (!mounted) return;
    final permWarn = permOk
        ? null
        : 'Bluetooth permission is required to announce this class over radio. Enable it in Settings — students can still join by IP until then.';
    setState(() {
      hosting = true;
      serverError = permWarn;
      _session = session;
      _ip = session.hostIp;
      serverLine = session.addressLine;
    });
    await _restoreDraft();
    if (!mounted) return;
    _idlePoll?.cancel();
    _idlePoll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted || !hosting || live) return;
      _maybeAutosave();
      // Rebuild only when the waiting set actually changed — an
      // unconditional setState here rebuilt the whole list every 2s
      // (scroll jank on big classes).
      if (_logWaitingDelta()) setState(() {});
    });
    if (widget.autoStart) _startNext();
  }

  Set<String> _prevWaiting = {};

  /// Logs waiting-room joins/leaves (student entered or backed out) so the
  /// count changes are visible in the system log, not just the list.
  /// Returns true when the set changed (caller rebuilds only then).
  bool _logWaitingDelta() {
    Set<String> cur = {};
    try {
      cur = {
        for (final w in ref.read(hostDriverProvider).waitingRows) w.email
      };
    } catch (_) {
      return false;
    }
    final joined = cur.difference(_prevWaiting);
    final left = _prevWaiting.difference(cur);
    _prevWaiting = cur;
    for (final e in joined) {
      BleLog.log('LAN', 'waiting +$e (${cur.length} waiting)');
    }
    for (final e in left) {
      BleLog.log('LAN', 'waiting -$e left (${cur.length} waiting)');
    }
    return joined.isNotEmpty || left.isNotEmpty;
  }

  /// Autosaved-draft resume (back navigation or full app kill). Policy:
  /// - draft older than 2.5h → ask: Recover (continue it) or Save & fresh
  ///   (archive it to history, start a new visit). Data is never dropped.
  /// - recent draft → archive a snapshot to history FIRST (the old visit
  ///   is safe as marked attendance under its own record id — crash,
  ///   kill, or never-return all keep the data), then resume live with
  ///   zero taps. No prompt: a crash mid-lecture must not interrogate
  ///   the professor, and accidental back-navigation continues the SAME
  ///   record (End upserts the same id — no duplicates).
  Future<void> _restoreDraft() async {
    Map<String, dynamic>? draft;
    try {
      draft = await ref.read(deviceStoreProvider).readSession(widget.courseName);
    } catch (_) {
      return;
    }
    final d = draft;
    if (d == null || !mounted) return;
    final windowNo = (d['windowNo'] as num?)?.toInt() ?? 0;
    final windows = _boolMaps(d['windows']);
    final names = _stringMap(d['names']);
    if (windowNo <= 0 && windows.isEmpty && names.isEmpty) return;
    final savedAt = DateTime.tryParse(d['savedAt'] as String? ?? '');
    if (shouldPromptRecover(savedAt, DateTime.now())) {
      final recover = await _askRecover(savedAt);
      if (!mounted) return;
      if (recover == true) {
        await _applyDraft(d);
      } else {
        // Save & start fresh (or dismissed): archive first, then clear.
        await _archiveDraftAsHistory(d);
        try {
          await ref
              .read(deviceStoreProvider)
              .clearSession(widget.courseName);
        } catch (_) {}
      }
      return;
    }
    // Recent: snapshot to history, then resume the same visit live.
    await _archiveDraftAsHistory(d);
    await _applyDraft(d);
  }

  /// Archives an autosaved draft to class history under its own record
  /// id/date (this is the "auto-save that session as attendance marked"
  /// path). No-op when nothing was ever marked.
  Future<void> _archiveDraftAsHistory(Map<String, dynamic> d) async {
    try {
      final windows = _boolMaps(d['windows']);
      final names = _stringMap(d['names']);
      final tally = TallyStore()
        ..restore(
          windows: windows,
          names: names,
          rolls: _stringMap(d['rolls']),
          windowNos: _intList(d['windowNos'], windows.length),
        );
      if (tally.size == 0) return;
      final now = DateTime.now();
      await ref.read(deviceStoreProvider).upsertHistory(
            tally.toClassRecord(
              courseId: widget.courseName,
              classLabel: widget.courseName,
              dateIso: d['dateIso'] as String? ?? dateIsoOf(now),
              timestampIso: now.toUtc().toIso8601String(),
              id: d['recordId'] as String?,
            ),
          );
    } catch (_) {}
  }

  /// Old-session prompt. Returns true = Recover, false = save & fresh.
  Future<bool?> _askRecover(DateTime? savedAt) {
    final age = savedAt == null
        ? 'a while ago'
        : _ageLine(DateTime.now().toUtc().difference(savedAt.toUtc()));
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Recover old session?'),
        content: Text(
            'An autosaved session from $age is still here. Recover it to continue, or save it to history and start fresh.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Save & start fresh'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Recover'),
          ),
        ],
      ),
    );
  }

  String _ageLine(Duration age) {
    if (age.inHours >= 24) return '${age.inDays}d ago';
    if (age.inHours >= 1) return '${age.inHours}h ago';
    return '${age.inMinutes}m ago';
  }

  /// Continues an autosaved draft in the fresh host: the tally and window
  /// numbering are restored; the window itself stays closed so the
  /// professor taps Take another round to continue.
  Future<void> _applyDraft(Map<String, dynamic> d) async {
    final windowNo = (d['windowNo'] as num?)?.toInt() ?? 0;
    final windows = _boolMaps(d['windows']);
    final names = _stringMap(d['names']);
    try {
      await ref.read(hostDriverProvider).restoreTally(
            windows: windows,
            names: names,
            rolls: _stringMap(d['rolls']),
            windowNos: _intList(d['windowNos'], windows.length),
          );
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _windowNo = windowNo;
      _draftDateIso = d['dateIso'] as String?;
      _recordId = d['recordId'] as String?;
      _recordStartIso = d['recordStartIso'] as String?;
      _resumed = true;
      _lastSavedSig = '';
    });
    _maybeAutosave();
  }

  Map<String, String> _stringMap(Object? v) {
    if (v is! Map) return {};
    return {
      for (final e in v.entries)
        if (e.key is String && e.value is String) e.key as String: e.value as String
    };
  }

  List<Map<String, bool>> _boolMaps(Object? v) {
    if (v is! List) return [];
    final out = <Map<String, bool>>[];
    for (final e in v) {
      if (e is Map) {
        out.add({
          for (final kv in e.entries)
            if (kv.key is String && kv.value is bool)
              kv.key as String: kv.value as bool
        });
      }
    }
    return out;
  }

  List<int> _intList(Object? v, int n) {
    if (v is List && v.length == n) {
      final out = [
        for (final e in v) (e as num?)?.toInt() ?? 0,
      ];
      if (out.every((e) => e > 0)) return out;
    }
    return [for (var i = 0; i < n; i++) i + 1];
  }

  String _draftSig() =>
      '$_windowNo|${tally.windowsAsMaps}|${tally.size}|${tally.confirmedCount}';

  Map<String, dynamic> _draftJson() => {
        'windowNo': _windowNo,
        'dateIso': _draftDateIso ?? dateIsoOf(DateTime.now()),
        'recordId': _recordId,
        'recordStartIso': _recordStartIso,
        'savedAt': DateTime.now().toUtc().toIso8601String(),
        'names': tally.nameMap(),
        'rolls': tally.rollMap(),
        'windows': tally.windowsAsMaps,
        'windowNos': tally.windowNos,
      };

  /// Writes the draft when marks are absent entirely it clears any stale
  /// draft instead, so untouched courses never show a resume banner.
  Future<void> _saveDraft() async {
    if (!hosting) return;
    try {
      final store = ref.read(deviceStoreProvider);
      if (tally.size == 0 && _windowNo == 0) {
        await store.clearSession(widget.courseName);
      } else {
        await store.writeSession(widget.courseName, _draftJson());
      }
      _lastSavedSig = _draftSig();
    } catch (_) {}
  }

  bool _saving = false;
  void _maybeAutosave() {
    if (!hosting || !mounted || _saving) return;
    if (_draftSig() != _lastSavedSig) {
      // Single-flight: the 1s elapsed timer and the 2s idle poll both
      // call here — overlapping writes raced _lastSavedSig (check-then-act
      // across an await). Best-effort either way; history snapshots are
      // the durable path.
      _saving = true;
      _saveDraft().whenComplete(() => _saving = false);
    }
  }

  Future<void> _discardDraft() async {
    try {
      await ref.read(deviceStoreProvider).clearSession(widget.courseName);
    } catch (_) {}
    try {
      ref.read(hostDriverProvider).tally.clear();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _windowNo = 0;
      _resumed = false;
      _draftDateIso = null;
      _lastSavedSig = '';
      _manualSelected.clear();
    });
  }

  /// Lets the professor pick which local IP to announce when several NICs
  /// show up (VPN vs WiFi) — the top cause of "students can't find me".
  Future<void> _pickIp() async {
    final session = _session;
    if (session == null || session.allIps.length < 2) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Announce on'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final ip in session.allIps)
                ListTile(
                  title: Text(ip),
                  trailing:
                      ip == _ip ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.of(ctx).pop(ip),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (picked == null || picked == _ip) return;
    try {
      await ref.read(hostDriverProvider).setAnnounceHost(picked);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _ip = picked;
      serverLine = session.lineFor(picked);
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    _idlePoll?.cancel();
    _nameCtrl.dispose();
    _setWake(false);
    // Best-effort only: dispose cannot await, so the durable save is the
    // autosave + _leave path above. _saveDraft/endHosting here are
    // fire-and-forget teardowns (ports close, last draft attempted).
    // Persist first so back navigation never loses marks; then full teardown
    // closes HTTPS + UDP sockets so no port stays open (req 7).
    _saveDraft();
    try {
      ref.read(hostDriverProvider).endHosting();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _leave() async {
    await _saveDraft();
    try {
      await ref.read(hostDriverProvider).endHosting();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  void _startNext() => _start(_windowNo + 1);

  bool _starting = false;
  Future<void> _start(int windowNo) async {
    // Single-flight: double-tap Start/Retake must not open overlapping
    // windows (was unguarded — two startWindow calls interleaved).
    if (_starting) return;
    _starting = true;
    try {
      await _startInner(windowNo);
    } finally {
      _starting = false;
    }
  }

  Future<void> _startInner(int windowNo) async {
    if (!await ref.read(blePermissionProvider)()) {
      if (!mounted) return;
      setState(() => serverError =
          'Bluetooth permission is required to host. Enable it in Settings.');
      return;
    }
    if (!await _ensureBt()) return;
    HostSession session;
    try {
      session = await ref.read(hostDriverProvider).startWindow(windowNo);
    } catch (e) {
      if (!mounted) return;
      setState(() => serverError = '$e');
      return;
    }
    if (!mounted) return;
    // Keep the screen awake for the live window on all OS.
    _setWake(true);
    setState(() {
      live = true;
      _windowNo = windowNo;
      elapsed = Duration.zero;
      serverError = null;
      _session = session;
      _ip = session.hostIp;
      serverLine = session.addressLine;
    });
    _saveDraft();
    _t?.cancel();
    _t = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      _maybeAutosave();
      _logWaitingDelta();
      // Elapsed-up only: nothing auto-closes. Stop ends acceptance
      // (after a short grace for proofs already on the wire).
      setState(() => elapsed += const Duration(seconds: 1));
    });
  }

  /// Stops the window on professor tap (never on a clock). Tally is kept
  /// and the class record is upserted now — every round persists, so even
  /// an un-closed session leaves data behind.
  Future<void> _closeWindow() async {
    _t?.cancel();
    if (!mounted) return;
    setState(() => live = false);
    _setWake(false);
    try {
      await ref.read(hostDriverProvider).stopWindow();
    } catch (_) {}
    await _saveDraft();
    await _saveSnapshot();
    if (mounted) setState(() {});
  }

  Future<void> _stopEarly() => _closeWindow();

  /// Open-window elapsed clock (mm:ss, unbounded — Stop ends it).
  String _elapsedLabel() {
    final s = elapsed.inSeconds;
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  /// Best-effort wakelock: fire-and-forget so a hung platform channel can
  /// never stall the attendance flow (caught once in widget tests).
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

  /// Bluetooth power gate. Only a confirmed powered-off radio blocks:
  /// the OS enable prompt is offered on Android; `unknown`/`unsupported`
  /// (e.g. permission backends that misreport, desktop stacks) proceed and
  /// real radio errors surface inline from the operation itself (Bug 1).
  Future<bool> _ensureBt() async {
    final state = await ref.read(btPowerProvider)();
    if (state == BtState.on) return true;
    if (state == BtState.off) {
      final enabled = await requestEnableBluetooth();
      if (enabled && await ref.read(btPowerProvider)() == BtState.on) {
        return true;
      }
      if (!mounted) return false;
      setState(() => serverError =
          'Bluetooth is off — turn it on to start the window.');
      return false;
    }
    return true;
  }

  /// Ends attendance (no export — that lives on the course page): final
  /// snapshot, draft cleared, hosting down, back to the course.
  Future<void> _endAttendance() async {
    try {
      await _saveSnapshot();
      try {
        await ref.read(deviceStoreProvider).clearSession(widget.courseName);
      } catch (_) {}
      _lastSavedSig = '';
      _recordId = null;
      _recordStartIso = null;
      await ref.read(hostDriverProvider).endHosting();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => serverError = '$e');
    }
  }

  /// Upserts the finished-so-far tally into on-device class history under
  /// this visit's stable record id: every round rewrites the SAME record,
  /// so un-closed sessions still leave data and later rounds update it.
  /// Skipped while nothing is marked (no empty records in history).
  /// When a signed-in professor is online, the same record pushes to the
  /// cloud (fire-and-forget — local data never waits on it).
  Future<void> _saveSnapshot([String? dateIso]) async {
    if (tally.size == 0) return;
    ClassRecord? record;
    try {
      final now = DateTime.now();
      _recordId ??=
          'live-${widget.courseName}-${now.toUtc().microsecondsSinceEpoch}';
      // First snapshot of the visit fixes the class-start time; later
      // rounds (and resumed drafts) keep it — timestampIso still moves
      // with every push for merge ordering.
      _recordStartIso ??= now.toUtc().toIso8601String();
      record = tally.toClassRecord(
        courseId: widget.courseName,
        classLabel: widget.courseName,
        dateIso: dateIso ?? _draftDateIso ?? dateIsoOf(now),
        timestampIso: now.toUtc().toIso8601String(),
        startIso: _recordStartIso,
        id: _recordId,
      );
      await ref.read(deviceStoreProvider).upsertHistory(record);
    } catch (_) {
      // History is best-effort; live tally + draft autosave are unaffected.
      return;
    }
    final rec = record;
    unawaited(_pushSnapshot(rec));
  }

  /// Best-effort cloud push for one snapshot (professors only, online only).
  Future<void> _pushSnapshot(ClassRecord record) async {
    try {
      final cloud = ref.read(cloudSyncProvider);
      if (!cloud.available) return;
      final acct = ref.read(authServiceProvider).current;
      Map<String, String>? role;
      try {
        role = await ref.read(deviceStoreProvider).readRole();
      } catch (_) {}
      String hostName = '';
      try {
        hostName = await ref.read(deviceStoreProvider).readHostName();
      } catch (_) {}
      final id = profPushIdentity(
          authEmail: acct?.email,
          authUid: acct?.uid,
          authName: acct?.displayName,
          role: role,
          hostNameFallback: hostName);
      if (id == null) return; // offline-skipped prof or student: local only
      await cloud
          .pushSession(
              profUid: id.uid,
              profEmail: id.email,
              profName: id.name,
              record: record)
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  Future<void> _approveOne(String email) async {
    try {
      await _driver?.decideManual(email, true);
    } catch (e) {
      if (mounted) setState(() => serverError = '$e');
    }
    await _saveDraft();
    await _saveSnapshot();
    if (mounted) {
      setState(() => _manualSelected.remove(email.toLowerCase()));
    }
  }

  Future<void> _rejectOne(String email) async {
    try {
      await _driver?.decideManual(email, false);
    } catch (e) {
      if (mounted) setState(() => serverError = '$e');
    }
    await _saveDraft();
    await _saveSnapshot();
    if (mounted) {
      setState(() => _manualSelected.remove(email.toLowerCase()));
    }
  }

  Future<void> _decideSelected(bool approve) async {
    final emails = _manualSelected.toList();
    for (final e in emails) {
      try {
        await _driver?.decideManual(e, approve);
      } catch (_) {}
    }
    await _saveDraft();
    await _saveSnapshot();
    if (mounted) setState(() => _manualSelected.clear());
  }

  /// Shared manual-add submit (see ManualAddForm): the form guarantees an
  /// ID plus a resolved or typed name/email — or queues offline itself.
  Future<void> _addDirectEntry(
      {required String name,
      required String roll,
      required String email}) async {
    try {
      await _driver?.addManualEntry(email: email, name: name, roll: roll);
    } catch (e) {
      throw StateError('$e'.replaceFirst('StateError: ', ''));
    }
    await _saveDraft();
    await _saveSnapshot();
  }

  @override
  Widget build(BuildContext context) {
    final linked = ref.watch(linkedIdentityProvider);
    final present = tally.confirmedCount;
    final waiting = _driver?.waitingCount ?? 0;
    final denom = waiting > 0 ? waiting : (present > 0 ? present : 0);
    final windowsTaken = tally.windowCount;
    final windowNos = tally.windowNos;
    // Intersection + partials: a student who marked R1 but missed R2 must
    // stay visible with per-round ticks (R1 ✓ · R2 ✗) instead of vanishing
    // from the list while the header still reads an intersection count.
    final confirmedRows =
        search.isEmpty ? tally.confirmed : tally.search(search).where((r) {
          if (windowNos.isEmpty) return r.wins.isNotEmpty;
          for (final w in windowNos) {
            if (!r.wins.contains(w)) return false;
          }
          return true;
        }).toList();
    final partialRows = search.isEmpty
        ? tally.presentAny
            .where((r) {
              if (windowNos.isEmpty) return false;
              var all = true;
              for (final w in windowNos) {
                if (!r.wins.contains(w)) {
                  all = false;
                  break;
                }
              }
              return !all;
            })
            .toList()
        : const [];
    String ticksFor(Set<int> wins) {
      if (windowNos.isEmpty) return wins.isEmpty ? 'no rounds yet' : 'R1 ✓';
      return [
        for (final w in windowNos) 'R$w ${wins.contains(w) ? '✓' : '✗'}',
      ].join(' · ');
    }
    final waitingRows = _driver?.waitingRows ?? const [];
    final manualPending = _driver?.manualPending ?? const [];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: AdaptiveScaffold(
        title: widget.courseName,
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const ClockHeader(),
            if (!hosting && serverError == null) ...[
              const SizedBox(height: 8),
              const Text('Starting host…'),
            ],
            if (hosting && !live) ...[
              const SizedBox(height: 8),
              const Text(
                  'Advertising on WiFi + Bluetooth — students can see this class now and join the waiting area. Tap Start when the class has joined. If students on institute WiFi can\u2019t see it, switch this phone to hotspot and rejoin it from their side.'),
              const SizedBox(height: 8),
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Your name (optional, shown to students)',
                ),
                onChanged: (v) {
                  try {
                    ref.read(hostDriverProvider).setDisplayName(v);
                  } catch (_) {}
                },
              ),
            ],
            if (serverLine != null) ...[
              const SizedBox(height: 4),
              Text(serverLine!, style: Theme.of(context).textTheme.bodyMedium),
            ],
            if (_session != null && _session!.allIps.length > 1) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: live ? null : _pickIp,
                  child: Text('Announcing on $_ip · change'),
                ),
              ),
            ],
            if (serverError != null) ...[
              const SizedBox(height: 4),
              Text(serverError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            if (_resumed) ...[
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.history),
                  title: const Text('Resumed autosaved session'),
                  subtitle: Text(
                      '$present present · $windowsTaken window${windowsTaken == 1 ? '' : 's'} so far — retake the round, take again, or end attendance.'),
                  trailing: TextButton(
                    onPressed: _discardDraft,
                    child: const Text('Discard'),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            // Live header: elapsed clock + pulsing on-air dot + counters.
            // The dot is the only repeating motion here — everything else
            // updates in place so the 1s elapsed tick never replays
            // entrances (rows are keyed; see waiting/present lists below).
            AnimatedContainer(
              duration: ProxDurations.small,
              curve: ProxCurves.standard,
              padding: const EdgeInsets.all(ProxSpacing.md),
              decoration: BoxDecoration(
                color: live
                    ? Theme.of(context)
                        .colorScheme
                        .primaryContainer
                        .withValues(alpha: 0.45)
                    : Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: 0.35),
                borderRadius: ProxRadii.cardRadius,
                border: Border.all(
                  color: live
                      ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)
                      : Theme.of(context)
                          .colorScheme
                          .outlineVariant
                          .withValues(alpha: 0.5),
                ),
              ),
              child: Row(
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _elapsedLabel(),
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 2),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ProxDot(
                            color: live
                                ? ProxStateColors.of(
                                    context, ProxState.active)
                                : ProxStateColors.of(
                                    context, ProxState.neutral),
                            pulse: live,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            live ? 'LIVE' : 'IDLE',
                            style: const TextStyle(letterSpacing: 3),
                          ),
                        ],
                      ),
                    ],
                  ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      PresentTicker(present: present, total: denom),
                      ProxSwitcher(
                        child: Text(
                          windowsTaken <= 1
                              ? 'Window 1 · $present present / $denom waiting'
                              : 'Windows 1–$_windowNo ($windowsTaken taken) · intersection $present / $denom waiting',
                          key: ValueKey<String>(
                              '$windowsTaken-$_windowNo-$present-$denom'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      if (linked != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                              'Host: ${linked.name}${linked.roll.isNotEmpty ? ' · ${linked.roll}' : ''}',
                              style: Theme.of(context).textTheme.bodySmall),
                        ),
                      const SizedBox(height: 8),
                      // Start ⇄ Stop control cluster cross-fades (continuation,
                      // not a hard swap) — the single most "alive" moment in
                      // the app. Actions fire immediately; only the visuals
                      // transition.
                      ProxSwitcher(
                        child: Wrap(
                          key: ValueKey<bool>(live),
                          spacing: 8,
                          runSpacing: 8,
                        children: [
                          if (live) ...[
                            FilledButton(
                              onPressed: _stopEarly,
                              child: const Text('Stop'),
                            ),
                          ] else ...[
                            if (_windowNo == 0)
                              FilledButton(
                                onPressed:
                                    (!hosting) ? null : () => _startNext(),
                                child: const Text('Start'),
                              )
                            else ...[
                              // Retake resumes the stopped round: same round
                              // number, fresh secrets, marks merge into it
                              // (no new intersection hurdle). Take another
                              // round opens a new round instead.
                              FilledButton(
                                onPressed: (!hosting)
                                    ? null
                                    : () => _start(_windowNo),
                                child:
                                    Text('Retake round $_windowNo'),
                              ),
                              FilledButton(
                                onPressed:
                                    (!hosting) ? null : () => _startNext(),
                                child: const Text('Take another round'),
                              ),
                              OutlinedButton(
                                onPressed:
                                    (!hosting) ? null : _endAttendance,
                                child: const Text('End attendance'),
                              ),
                            ],
                            if (_windowNo == 0)
                              OutlinedButton(
                                onPressed:
                                    (!hosting) ? null : _endAttendance,
                                child: const Text('End attendance'),
                              ),
                          ],
                        ],
                      ),
                      ),
                    ],
                  ),
                ),
              ],
              ),
            ),
            const SizedBox(height: 12),
            // Toggleable terminal: BLE RX → sighting match → tally → ACK.
            // Same log stream as the student side; helps debug radio live.
            BleLogView(
              visible: _showLog,
              onToggle: () => setState(() => _showLog = !_showLog),
            ),
            const SizedBox(height: 16),
            ProxSectionHeader(title: 'Waiting area ($waiting)'),
            if (waitingRows.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text('No students in the waiting area yet.'),
              )
            else
              // Keyed entrances: a join fades/slides its row in; the 1s
              // elapsed tick rebuilds with stable keys so nothing replays.
              for (final w in waitingRows)
                ProxFadeSlideIn(
                  key: ValueKey<String>('waiting-${w.email}'),
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.hourglass_top, size: 20),
                    title: Text(w.name.isNotEmpty ? w.name : w.email),
                    subtitle: Text(
                        [if (w.roll.isNotEmpty) w.roll, w.email].join(' · ')),
                  ),
                ),
            const SizedBox(height: 8),
            ProxSectionHeader(
              title: 'Manual requests (${manualPending.length})',
              padding: EdgeInsets.zero,
              trailing: manualPending.isEmpty
                  ? null
                  : TextButton(
                      onPressed: () => setState(() {
                        if (_manualSelected.length == manualPending.length) {
                          _manualSelected.clear();
                        } else {
                          _manualSelected
                            ..clear()
                            ..addAll(manualPending
                                .map((m) => m.email.toLowerCase()));
                        }
                      }),
                      child: Text(_manualSelected.length ==
                              manualPending.length
                          ? 'Clear all'
                          : 'Select all'),
                    ),
            ),
            if (manualPending.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text('No manual requests.'),
              )
            else ...[
              for (final m in manualPending)
                ProxFadeSlideIn(
                  key: ValueKey<String>('manual-${m.email}'),
                  child: CheckboxListTile(
                    dense: true,
                    value: _manualSelected.contains(m.email.toLowerCase()),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _manualSelected.add(m.email.toLowerCase());
                    } else {
                      _manualSelected.remove(m.email.toLowerCase());
                    }
                  }),
                  title: Text(m.name.isNotEmpty ? m.name : m.email),
                  subtitle: Text(
                      [if (m.roll.isNotEmpty) m.roll, m.email].join(' · ')),
                  secondary: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.check, color: Colors.green),
                        tooltip: 'Approve',
                        onPressed: () => _approveOne(m.email),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.red),
                        tooltip: 'Reject',
                        onPressed: () => _rejectOne(m.email),
                      ),
                    ],
                  ),
                  ),
                ),
              Row(
                children: [
                  FilledButton(
                    onPressed: _manualSelected.isEmpty
                        ? null
                        : () => _decideSelected(true),
                    child: const Text('Approve selected'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _manualSelected.isEmpty
                        ? null
                        : () => _decideSelected(false),
                    child: const Text('Reject'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            ProxSectionHeader(
              title: 'Direct manual entry',
              padding: EdgeInsets.zero,
            ),
            ManualAddForm(
              fieldPrefix: 'direct',
              course: widget.courseName,
              sessionId: _recordId ?? '',
              onAdd: _addDirectEntry,
              // Present = every round taken (intersection): re-adding one
              // shows "Already marked present."; partials still go through.
              isPresent: (email) => tally.confirmed
                  .any((r) => r.email == email.toLowerCase()),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('prof-search'),
              decoration: const InputDecoration(
                  labelText: 'Search by name, ID, or email',
                  prefixIcon: Icon(Icons.search)),
              onChanged: (v) => setState(() => search = v),
            ),
            const SizedBox(height: 8),
            ProxSectionHeader(
              title:
                  'Present — all rounds ($present) · ${windowsTaken <= 1 ? '1 round' : '$windowsTaken rounds'}',
              padding: EdgeInsets.zero,
            ),
            if (confirmedRows.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text(
                    'Nobody present in every round yet — partials stay listed below.'),
              )
            else
              for (var i = 0; i < confirmedRows.length; i++)
                ProxListTile(
                  title: confirmedRows[i].name,
                  subtitle: [
                    ticksFor(confirmedRows[i].wins),
                    if (confirmedRows[i].roll.isNotEmpty)
                      confirmedRows[i].roll,
                    confirmedRows[i].email,
                    if (confirmedRows[i].late) 'late',
                  ].join(' · '),
                  staggerIndex: i,
                  leading: Icon(
                    Icons.check_circle,
                    color: ProxStateColors.of(context, ProxState.marked),
                  ),
                ),
            if (partialRows.isNotEmpty) ...[
              const SizedBox(height: 8),
              ProxSectionHeader(
                title: 'Partial — some rounds (${partialRows.length})',
                padding: EdgeInsets.zero,
              ),
              for (final r in partialRows)
                ListTile(
                  key: ValueKey<String>('partial-${r.email}'),
                  dense: true,
                  leading: Icon(
                    Icons.timelapse,
                    color: ProxStateColors.of(context, ProxState.late),
                  ),
                  title: Text(r.name),
                  subtitle: Text([
                    ticksFor(r.wins),
                    if (r.roll.isNotEmpty) r.roll,
                    r.email,
                    if (r.late) 'late',
                  ].join(' · ')),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
