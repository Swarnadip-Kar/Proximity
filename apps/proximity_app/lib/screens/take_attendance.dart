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
//
// Layout contract: this screen owns hosting/window/draft orchestration
// and composes the live feature sections (setup, session header, roster,
// manual inbox, direct add, draft recovery) — one section per file under
// lib/features/live/. Behavior is unchanged from the pre-split screen;
// only the rendering moved.
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
import '../features/debug/debug_log_screen.dart';
import '../features/live/direct_add.dart';
import '../features/live/draft_recovery.dart';
import '../features/live/live_roster.dart';
import '../features/live/live_session.dart';
import '../features/live/live_setup.dart';
import '../features/live/manual_inbox.dart';
import '../main.dart';
import '../mode.dart';
import '../widgets/clock.dart';

// Recovery policy lives in the draft-recovery section; re-exported here
// so existing imports (and tests) keep resolving it from this screen.
export '../features/live/draft_recovery.dart'
    show recoverPromptThreshold, shouldPromptRecover;

class TakeAttendanceScreen extends ConsumerStatefulWidget {
  final String courseName;
  final bool autoStart;
  const TakeAttendanceScreen(
      {super.key, required this.courseName, this.autoStart = false});

  @override
  ConsumerState<TakeAttendanceScreen> createState() =>
      _TakeAttendanceScreenState();
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
      BleLog.log(ProxLogTags.lan, 'waiting +$e (${cur.length} waiting)');
    }
    for (final e in left) {
      BleLog.log(ProxLogTags.lan, 'waiting -$e left (${cur.length} waiting)');
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
      final recover = await showRecoverOldDialog(context, savedAt);
      if (!mounted) return;
      if (recover == true) {
        BleLog.log(ProxLogTags.nav, 'old draft recovered (continue same visit)');
        await _applyDraft(d);
      } else {
        // Save & start fresh (or dismissed): archive first, then clear.
        BleLog.log(ProxLogTags.nav, 'old draft archived, starting fresh visit');
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
    BleLog.log(ProxLogTags.nav, 'recent draft auto-archived + resumed live, no prompt');
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
      BleLog.log(ProxLogTags.sync, 'draft archived to history (${tally.size} marked)');
    } catch (_) {}
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
    BleLog.log(ProxLogTags.state, 'draft discarded by professor (tally cleared)');
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
    });
  }

  /// Lets the professor pick which local IP to announce when several NICs
  /// show up (VPN vs WiFi) — the top cause of "students can't find me".
  Future<void> _pickIp() async {
    final session = _session;
    if (session == null || session.allIps.length < 2) return;
    final picked = await showAnnounceIpDialog(
      context,
      allIps: session.allIps,
      currentIp: _ip,
    );
    if (picked == null || picked == _ip) return;
    try {
      await ref.read(hostDriverProvider).setAnnounceHost(picked);
    } catch (_) {}
    if (!mounted) return;
    BleLog.log(ProxLogTags.state, 'announce IP switched to $picked');
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
    // autosave + _leave path above.
    // Non-clobbering teardown: _leave/_endAttendance save first and then
    // endHosting clears the live tally, so an unconditional write here
    // would persist an EMPTY visit over the good draft (back-nav would
    // then "resume" zero marks). Only top-up when live marks exist that
    // the autosave may not have flushed yet (abnormal teardown without
    // back-nav); the awaited _leave save + per-round snapshots own the
    // normal path. (Ports still close unconditionally below — req 7.)
    if (tally.size > 0) _saveDraft();
    try {
      ref.read(hostDriverProvider).endHosting();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _leave() async {
    // Freeze autosave FIRST: endHosting clears the live tally below, and a
    // 1s/2s timer tick landing between the clear and unmount would persist
    // an EMPTY visit over the good draft (back-nav would "resume" zero
    // marks). Timers die here (and again in dispose), never after the pop.
    _t?.cancel();
    _idlePoll?.cancel();
    BleLog.log(ProxLogTags.nav, 'leaving take screen (draft saved, hosting down)');
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
    BleLog.log(ProxLogTags.state, 'window #$windowNo live (code ${session.displayCode})');
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
    BleLog.log(ProxLogTags.state, 'window #$_windowNo stopped (grace running)');
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
    BleLog.log(ProxLogTags.nav, 'end attendance (final snapshot, hosting down)');
    // Freeze autosave first (same teardown race as _leave: the draft is
    // cleared and the tally dropped below, so a timer tick landing before
    // unmount would resurrect a stale empty draft behind the course page).
    _t?.cancel();
    _idlePoll?.cancel();
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
      BleLog.log(ProxLogTags.sync,
          'snapshot upserted ${record.id} (${tally.confirmedCount} present)');
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
      BleLog.log(ProxLogTags.state, 'manual approved $email');
    } catch (e) {
      if (mounted) setState(() => serverError = '$e');
    }
    await _saveDraft();
    await _saveSnapshot();
    if (mounted) setState(() {});
  }

  Future<void> _rejectOne(String email) async {
    try {
      await _driver?.decideManual(email, false);
      BleLog.log(ProxLogTags.state, 'manual rejected $email');
    } catch (e) {
      if (mounted) setState(() => serverError = '$e');
    }
    await _saveDraft();
    await _saveSnapshot();
    if (mounted) setState(() {});
  }

  Future<void> _decideSelected(List<String> emails, bool approve) async {
    for (final e in emails) {
      try {
        await _driver?.decideManual(e, approve);
      } catch (_) {}
    }
    BleLog.log(ProxLogTags.state,
        'manual bulk ${approve ? 'approved' : 'rejected'} (${emails.length})');
    await _saveDraft();
    await _saveSnapshot();
    if (mounted) setState(() {});
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

  void _openLog() {
    BleLog.log(ProxLogTags.nav, 'take → system log');
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const DebugLogScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final linked = ref.watch(linkedIdentityProvider);
    final present = tally.confirmedCount;
    final waiting = _driver?.waitingCount ?? 0;
    final windowsTaken = tally.windowCount;
    final waitingRows = _driver?.waitingRows ?? const [];
    final manualPending = _driver?.manualPending ?? const [];
    final hostLine = linked == null
        ? null
        : 'Host: ${linked.name}${linked.roll.isNotEmpty ? ' · ${linked.roll}' : ''}';
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: AdaptiveScaffold(
        title: widget.courseName,
        actions: [
          IconButton(
            icon: const Icon(Icons.terminal_outlined),
            tooltip: 'System log',
            onPressed: _openLog,
          ),
        ],
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const ClockHeader(),
            LiveSetupSection(
              hosting: hosting,
              live: live,
              nameCtrl: _nameCtrl,
              onNameChanged: (v) {
                try {
                  ref.read(hostDriverProvider).setDisplayName(v);
                } catch (_) {}
              },
              serverLine: serverLine,
              allIps: _session?.allIps ?? const [],
              currentIp: _ip,
              onPickIp: _pickIp,
              serverError: serverError,
            ),
            if (_resumed) ...[
              const SizedBox(height: 8),
              DraftResumedBanner(
                present: present,
                windowsTaken: windowsTaken,
                onDiscard: _discardDraft,
              ),
            ],
            const SizedBox(height: 8),
            // Live header: elapsed clock + pulsing on-air dot + counters.
            // The dot is the only repeating motion here — everything else
            // updates in place so the 1s elapsed tick never replays
            // entrances (waiting rows are keyed; present rows mount
            // static, see the roster section).
            LiveSessionHeader(
              live: live,
              elapsed: elapsed,
              present: present,
              waiting: waiting,
              windowsTaken: windowsTaken,
              windowNo: _windowNo,
              hosting: hosting,
              hostLine: hostLine,
              onStart: _startNext,
              onRetake: () => _start(_windowNo),
              onTakeAnother: _startNext,
              onStop: _stopEarly,
              onEnd: _endAttendance,
            ),
            const SizedBox(height: 12),
            WaitingListSection(
              waitingRows: waitingRows,
            ),
            const SizedBox(height: 8),
            ManualInboxSection(
              pending: manualPending,
              onApproveOne: _approveOne,
              onRejectOne: _rejectOne,
              onDecide: _decideSelected,
            ),
            const SizedBox(height: 8),
            DirectAddSection(
              course: widget.courseName,
              sessionId: _recordId ?? '',
              onAdd: _addDirectEntry,
              // Present = every round taken (intersection): re-adding one
              // shows "Already marked present."; partials still go through.
              isPresent: (email) => tally.confirmed
                  .any((r) => r.email == email.toLowerCase()),
            ),
            const SizedBox(height: 16),
            MarkedRosterSection(
              tally: tally,
            ),
          ],
        ),
      ),
    );
  }
}
