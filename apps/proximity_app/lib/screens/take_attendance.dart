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
// and composes the live feature sections behind an explicit sub-nav;
// sub-tab content swaps completely via an IndexedStack — each sub-tab shows ONLY its
// view, no shared scroll, no intersection, inactive views stay mounted so
// their state survives switches (mid-approve inbox selection, roster
// search, direct-add fields). Roster = waiting + dup + marked
// (`LiveRosterBody`, same composer as the dedicated roster screen);
// inbox = manual requests only; add = direct manual entry only
// (the single home — no AppBar sheet extra); setup = name/IP/discovery
// only. Behavior is unchanged from the pre-split screen; only the
// rendering moved.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_storage/storage.dart';
import 'package:proximity_transport/transport.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/auth.dart';
import '../core/ble_radio.dart';
import '../core/cloud_sync.dart';
import '../core/device_store.dart';
import '../core/host_driver.dart';
import '../core/sync_hook.dart';
import '../design/tokens.dart';
import '../features/live/direct_add.dart';
import '../features/live/draft_recovery.dart';
import '../features/live/live_refresh.dart';
import '../features/live/live_roster.dart';
import '../features/live/live_session.dart';
import '../features/live/live_setup.dart';
import '../features/live/manual_inbox.dart';
import '../main.dart';
import '../mode.dart';
import '../widgets/host_preview_card.dart';
import '../widgets/log_drawer.dart';
import '../widgets/partial_list.dart';
import '../widgets/student_card.dart' show courseInitials;

// Recovery policy lives in the draft-recovery section; re-exported here
// so existing imports (and tests) keep resolving it from this screen.
export '../features/live/draft_recovery.dart'
    show recoverPromptThreshold, shouldPromptRecover;

/// Lightweight segmented sub-nav (§7.1) under the slim status strip:
/// segment SWAPS the content below via the host's IndexedStack — each
/// sub-tab shows ONLY its view (no shared scroll, no intersection);
/// inactive views stay mounted so their state survives switches.
///
/// Order: Roster · Waiting · Inbox · Add · Setup. Five equal-width cells
/// that always fit the screen width (never scroll, never flow out):
/// symmetric `xs` padding on every cell, labels ellipsize instead of
/// pushing siblings. Waiting + Inbox carry count badges with reserved
/// width (maintainSize reserves space so 0→N never shifts siblings).
class LiveSubNav extends StatelessWidget {
  final int selected;
  final int waitingCount;
  final int inboxCount;
  final ValueChanged<int> onSelect;

  const LiveSubNav({
    super.key,
    required this.selected,
    this.waitingCount = 0,
    required this.inboxCount,
    required this.onSelect,
  });

  /// Inline live counter: `Waiting (3)` / `Inbox (2)` in the same label
  /// style — no pill container, so all five cells keep even symmetric
  /// padding and always fit. The label half stays an exact `Text(label)`
  /// (tap finders keep working); the count rides a sibling Text.
  Widget _cell(
    BuildContext context,
    ProximityColors c, {
    required int index,
    required String label,
    int badgeCount = 0,
    bool showBadge = false,
  }) {
    final active = selected == index;
    final fg = active ? c.accentBrand : c.contentSecondary;
    final labelStyle = ProxType.label(color: fg).copyWith(
      fontWeight: FontWeight.w600,
    );
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onSelect(index),
        child: AnimatedContainer(
          duration: ProxDurations.micro,
          curve: ProxCurves.standard,
          constraints:
              const BoxConstraints(minHeight: ProxSpacing.minTap),
          padding: const EdgeInsets.symmetric(
            horizontal: ProxSpacing.xs,
            vertical: ProxSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: active
                ? c.accentBrand.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(ProxRadii.pill),
          ),
          alignment: Alignment.center,
          // Scale-down, never truncate: the full word always shows —
          // it shrinks a hair on 360dp instead of clipping to "W...".
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: labelStyle,
                  maxLines: 1,
                  softWrap: false,
                  textAlign: TextAlign.center,
                ),
                if (showBadge && badgeCount > 0)
                  Text(
                    ' ($badgeCount)',
                    style: labelStyle,
                    maxLines: 1,
                    softWrap: false,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Container(
      key: const ValueKey('live-subnav'),
      decoration: BoxDecoration(
        border: Border.all(color: c.divider),
        borderRadius: BorderRadius.circular(ProxRadii.pill),
      ),
      padding: const EdgeInsets.all(ProxSpacing.xs),
      child: Row(
        children: [
          _cell(context, c, index: 0, label: 'Roster'),
          _cell(context, c,
              index: 1,
              label: 'Waiting',
              badgeCount: waitingCount,
              showBadge: true),
          _cell(context, c,
              index: 2,
              label: 'Inbox',
              badgeCount: inboxCount,
              showBadge: true),
          _cell(context, c, index: 3, label: 'Add'),
          _cell(context, c, index: 4, label: 'Setup'),
        ],
      ),
    );
  }
}

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
  // Frozen elapsed at the last stop: resume re-opens the same round from
  // this value (start = now - banked) instead of zero. Null = no banked
  // value, so fresh rounds (_windowNo+1) still start at zero. Set in the
  // _closeWindow path, consumed on resume in _startInner, cleared on
  // fresh starts and discards.
  Duration? _bankedElapsed;
  Timer? _t;
  Timer? _idlePoll;
  String? serverLine;
  String? serverError;

  /// Per-course opt-in: publish my Gmail photo to joining students.
  /// Off by default (persisted per course in the device store).
  bool _sharePhoto = false;
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
  String? _recordOrg;
  String _lastSavedSig = '';

  /// Org the host actually announces (role-cache stamp, '' = unstamped).
  /// Same source as the beacon `org` students see on the waiting card —
  /// the Setup preview passes this through so it can never drift.
  String _announcedOrg = '';

  /// Prof org for new sessions (role cache stamped at sign-in; '' when
  /// offline-skipped). Cached per visit so later rounds keep the creation
  /// org immutable.
  Future<String> _profOrgForSession() async {
    String acctOrg = '';
    try {
      acctOrg = ref.read(authServiceProvider).current?.org ?? '';
    } catch (_) {}
    try {
      final role = await ref.read(deviceStoreProvider).readRole();
      return resolveMyOrg(acctOrg, role);
    } catch (_) {
      return '';
    }
  }

  /// Loads the announced org from the SAME source the beacon airs
  /// (`roleOrg` over the role cache — see host_driver `_startHostingInner`).
  /// Read-only: no transport/beacon change, preview display only.
  Future<void> _loadAnnouncedOrg() async {
    try {
      final role = await ref.read(deviceStoreProvider).readRole();
      final org = roleOrg(role);
      if (mounted && org != _announcedOrg) {
        setState(() => _announcedOrg = org);
      }
    } catch (_) {}
  }

  final _nameCtrl = TextEditingController();

  /// Segmented sub-nav (§7.1): the active live sub-tab (0 roster,
  /// 1 waiting, 2 inbox, 3 add, 4 setup). IndexedStack keeps every tab
  /// mounted so mid-lecture state (roster search, waiting list, inbox
  /// selection, add fields) survives switches.
  int _section = 0;
  // Retained (unused by composition): dispose() still disposes it, and the
  // dispose body is orchestration-frozen — so the field stays.
  final _scrollCtrl = ScrollController();

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

  /// Class-strength ceiling for the roster absent count: union of
  /// everyone ever seen in this course's history. Loaded once up front
  /// (absent starts at class strength, not zero); the roster maxes it
  /// with the live tally size so newcomers never shrink it.
  int _historyUnion = 0;

  @override
  void initState() {
    super.initState();
    _host();
    _loadName();
    _loadAnnouncedOrg();
    _loadUnion();
    // Bluetooth off is otherwise a log-only failure: prompt once, up
    // front, with a tappable Turn-on (rounds need the radio).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) promptEnableBluetoothIfOff(context, ref);
    });
  }

  /// Loads the history union for the roster absent ceiling (same
  /// course filter as the overview roster count).
  Future<void> _loadUnion() async {
    try {
      final history = await ref.read(deviceStoreProvider).readHistory();
      final mine = history
          .where((r) =>
              r.courseId == widget.courseName ||
              (r.courseId.isEmpty && r.classLabel == widget.courseName))
          .toList();
      if (!mounted) return;
      setState(() => _historyUnion = courseRoster(mine).length);
    } catch (_) {}
  }

  /// Prefills the professor display name: linked identity wins, last
  /// saved name otherwise, Gmail display name as the final default — so
  /// students see a name (never a bare email) even when the professor
  /// never typed one. Publishes the filled value via `setDisplayName` so
  /// the announcement carries it even when `_host` already ran (late
  /// Gmail): the announcer reads the driver name live, and the student
  /// cannot invent it — host-side publish only, no transport change.
  Future<void> _loadName() async {
    var name = ref.read(linkedIdentityProvider)?.name ?? '';
    try {
      final saved = await ref.read(deviceStoreProvider).readHostName();
      if (saved.isNotEmpty) name = saved;
    } catch (_) {}
    if (name.isEmpty) {
      try {
        name = ref.read(authServiceProvider).current?.displayName.trim() ?? '';
      } catch (_) {}
    }
    if (name.isEmpty) {
      name = ref.read(accountProvider).valueOrNull?.displayName.trim() ?? '';
    }
    if (name.isEmpty) {
      // Late Gmail: the account stream may not have emitted when initState
      // ran. Await the first value (bounded) so an empty field still
      // converges to the known Gmail name instead of airing blank.
      try {
        final acct = await ref
            .read(accountProvider.future)
            .timeout(const Duration(seconds: 5));
        name = acct?.displayName.trim() ?? '';
      } catch (_) {}
    }
    if (mounted && _nameCtrl.text.isEmpty && name.isNotEmpty) {
      setState(() => _nameCtrl.text = name);
      try {
        unawaited(ref.read(hostDriverProvider).setDisplayName(name));
      } catch (_) {}
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
    // Anti-fake-professor pin publish: the lecture key is appended to
    // `profDevices/{email}` (owner-only write) so students verify the
    // email→key binding offline. Wired here (auth + role + cloud live
    // together) — the driver calls it fire-and-forget, never blocking.
    try {
      final driver = ref.read(hostDriverProvider);
      driver.profKeyPublisher = ({required emailLower, required pkPHex}) async {
        try {
          final acct = ref.read(authServiceProvider).current;
          if (acct == null) return;
          final role = await ref.read(deviceStoreProvider).readRole();
          final org = roleOrg(role);
          await ref.read(cloudSyncProvider).uploadProfKey(
                emailLower: emailLower,
                uid: acct.uid.isNotEmpty ? acct.uid : acct.email.toLowerCase(),
                org: org,
                pkPHex: pkPHex,
              );
        } catch (_) {}
      };
    } catch (_) {}
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
    // Anti-fake-student pin prefetch: persist the same-org directory
    // email→pkS map locally whenever online, then hydrate the live server
    // so offline `unknown-pkS` enforcement survives restarts. Best-effort.
    unawaited(_prefetchStudentPins());
    if (!mounted) return;
    String? warn;
    try {
      warn = ref.read(hostDriverProvider).lanSelfCheckWarning;
    } catch (_) {}
    final permWarn = permOk
        ? null
        : 'Bluetooth permission is required to announce this class over radio. Enable it in Settings — students can still join by IP until then.';
    setState(() {
      hosting = true;
      // Firewall-blocked first start stays honest in the UI (non-blocking):
      // hosting is up on loopback, but students will time out on the LAN IP.
      serverError = permWarn ?? warn;
      _session = session;
      _ip = session.hostIp;
      serverLine = session.addressLine;
    });
    // Announce the setup name field as-is (the announcer reads it live,
    // so a Gmail-defaulted field the professor never typed still airs a
    // name — students see it instead of a bare email). Idempotent: the
    // same value rewrites the same pref.
    try {
      final field = _nameCtrl.text.trim();
      if (field.isEmpty) {
        var gmail = '';
        try {
          gmail =
              ref.read(authServiceProvider).current?.displayName.trim() ?? '';
        } catch (_) {}
        gmail = gmail.isNotEmpty
            ? gmail
            : (ref.read(accountProvider).valueOrNull?.displayName.trim() ??
                '');
        if (gmail.isNotEmpty && mounted) {
          setState(() => _nameCtrl.text = gmail);
        }
      }
      final announced = _nameCtrl.text.trim();
      if (announced.isNotEmpty) {
        unawaited(
            ref.read(hostDriverProvider).setDisplayName(announced));
      }
    } catch (_) {}
    // Publish the host Gmail photo to joining students ONLY when the
    // professor opted in for this course (off by default). Students
    // converge on the next room poll; initials fallback when absent or
    // off. Best-effort, never blocks hosting.
    try {
      final share = await ref
          .read(deviceStoreProvider)
          .readShowProfPhoto(widget.courseName);
      if (!mounted) return;
      setState(() => _sharePhoto = share);
      final photo = share
          ? (ref.read(accountProvider).valueOrNull?.photoUrl?.trim() ?? '')
          : '';
      unawaited(ref.read(hostDriverProvider).setHostPhoto(photo));
    } catch (_) {}
    // Discovery assumptions, never silent: logged on every hosting start
    // (LAN tag) so a dead enterprise AP reads as explained, not empty.
    for (final line in discoveryAssumptionLines()) {
      BleLog.log(ProxLogTags.lan, line);
    }
    BleLog.log(ProxLogTags.lan, 'ladder ${formatLadderLine(-1)}');
    await _restoreDraft();
    if (!mounted) return;
    _idlePoll?.cancel();
    _idlePoll = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted || !hosting || live) return;
      _maybeAutosave();
      // Heal late WiFi DHCP while idling: hosting opened on mobile data or
      // before DHCP completed airs a stale/unreachable IP on FIRST start.
      // refreshAnnounceIps never overrides an explicit professor pick.
      try {
        final driver = ref.read(hostDriverProvider);
        await driver.refreshAnnounceIps();
        final cur = driver.announceIp;
        if (mounted && cur.isNotEmpty && cur != _ip) {
          final session = _session;
          setState(() {
            _ip = cur;
            if (session != null) serverLine = session.lineFor(cur);
          });
        }
      } catch (_) {}
      // Rebuild only when something actually changed — an
      // unconditional setState here rebuilt the whole list every 2s
      // (scroll jank on big classes). The manual delta refreshes the
      // `Inbox (N)` badge + inbox prop while idle (inbox rows
      // self-refresh in the section — see
      // `features/live/manual_inbox.dart`).
      final waitingChanged = _logWaitingDelta();
      final manualChanged = _logManualDelta();
      if (waitingChanged || manualChanged) setState(() {});
    });
    if (widget.autoStart) _startNext();
  }

  Set<String> _prevWaiting = {};
  Set<String> _prevManual = {};

  /// Logs waiting-room joins/leaves (student entered or backed out) so the
  /// count changes are visible in the system log, not just the list.
  /// Returns true when the set changed (caller rebuilds only then).
  bool _logWaitingDelta() {
    Set<String> cur = {};
    try {
      cur = {for (final w in ref.read(hostDriverProvider).waitingRows) w.email};
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

  /// Manual-arrival delta (inbox live-update fix, rebuild trigger only):
  /// the idle poll previously watched the waiting set alone, so manual
  /// arrivals while idle never refreshed the `Inbox (N)` badge or the
  /// inbox prop until the next decision/navigation. Compares the LOCAL
  /// pending email set (no network, no proof load) and stays silent —
  /// arrivals render, decided rows still clear via the existing decide
  /// paths. Orchestration untouched.
  bool _logManualDelta() {
    Set<String> cur = {};
    try {
      cur = {
        for (final m in ref.read(hostDriverProvider).manualPending) m.email
      };
    } catch (_) {
      return false;
    }
    final changed =
        cur.length != _prevManual.length || !cur.containsAll(_prevManual);
    _prevManual = cur;
    return changed;
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
      draft =
          await ref.read(deviceStoreProvider).readSession(widget.courseName);
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
        BleLog.log(
            ProxLogTags.nav, 'old draft recovered (continue same visit)');
        await _applyDraft(d);
      } else {
        // Save & start fresh (or dismissed): archive first, then clear.
        BleLog.log(ProxLogTags.nav, 'old draft archived, starting fresh visit');
        await _archiveDraftAsHistory(d);
        try {
          await ref.read(deviceStoreProvider).clearSession(widget.courseName);
        } catch (_) {}
      }
      return;
    }
    // Recent: snapshot to history, then resume the same visit live.
    BleLog.log(ProxLogTags.nav,
        'recent draft auto-archived + resumed live, no prompt');
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
      BleLog.log(
          ProxLogTags.sync, 'draft archived to history (${tally.size} marked)');
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
      _recordOrg = d['recordOrg'] as String?;
      _resumed = true;
      _lastSavedSig = '';
      // Restored drafts resume idle: no frozen stop to continue from.
      _bankedElapsed = null;
      elapsed = Duration.zero;
    });
    _maybeAutosave();
  }

  Map<String, String> _stringMap(Object? v) {
    if (v is! Map) return {};
    return {
      for (final e in v.entries)
        if (e.key is String && e.value is String)
          e.key as String: e.value as String
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
        for (final e in v)
          e is num ? e.toInt() : int.tryParse('$e') ?? 0,
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
        'recordOrg': _recordOrg,
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
    BleLog.log(
        ProxLogTags.state, 'draft discarded by professor (tally cleared)');
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
      _bankedElapsed = null;
      elapsed = Duration.zero;
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
    _scrollCtrl.dispose();
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

  /// Back-interrupt guards (§3.5 back-intercept): [_leaving] single-flights
  /// the awaited teardown (a second back-press mid-await is ignored);
  /// [_bypass] marks our own programmatic pops so the PopScope handler can
  /// never re-enter teardown for them. Both are load-bearing: without them
  /// a double-back would run teardown twice (double save + double
  /// endHosting).
  bool _leaving = false;
  bool _bypass = false;

  /// Shared back-path teardown: freeze autosave timers FIRST (endHosting
  /// clears the live tally below, and a 1s/2s timer tick landing between
  /// the clear and unmount would persist an EMPTY visit over the good
  /// draft — back-nav would then "resume" zero marks). Timers die here
  /// (and again in dispose), never after the pop.
  ///
  /// Throws stay caught exactly as today (ports close best-effort). The
  /// End-attendance path passes `save: false`: it already snapshotted +
  /// cleared the draft above, so saving again here would resurrect it.
  Future<void> _teardown({bool save = true}) async {
    _t?.cancel();
    _idlePoll?.cancel();
    if (save) {
      BleLog.log(
          ProxLogTags.nav, 'leaving take screen (draft saved, hosting down)');
      await _saveDraft();
    }
    try {
      await ref.read(hostDriverProvider).endHosting();
    } catch (_) {}
  }

  /// Anti-fake-student pin prefetch (shared by hosting start + every
  /// window start): persists the same-org directory email→pkS map locally
  /// whenever online, then hydrates the live server. Re-running per window
  /// converges mid-class enrollments and student re-keys (a pin cached at
  /// hosting start would otherwise refuse a freshly re-enrolled key as
  /// `unknown-pkS` for the whole session). Best-effort, never throws.
  Future<void> _prefetchStudentPins() async {
    try {
      final cloud = ref.read(cloudSyncProvider);
      if (!await cloud.isOnline()) return;
      final store = ref.read(deviceStoreProvider);
      final role = await store.readRole();
      final org = roleOrg(role);
      if (org.isEmpty) return;
      final pins = await cloud.fetchStudentKeyPins(org: org, limit: 200);
      if (pins.isEmpty) return;
      final prev = await store.readStudentKeyPins();
      await store.writeStudentKeyPins({...prev, ...pins});
      try {
        await ref.read(hostDriverProvider).hydrateStudentPins(pins);
      } catch (_) {}
      BleLog.log('SEC', 'student key pins prefetched (${pins.length})');
    } catch (_) {}
  }

  /// Single-flight leave: the bar BackButton, the PopScope intercept, and
  /// (its tail) End-attendance all funnel through here. Teardown throws
  /// stay caught so the pop still proceeds (same as `_leave` today).
  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    try {
      await _teardown();
    } catch (_) {}
    if (mounted) {
      _bypass = true;
      Navigator.of(context).pop();
    }
  }

  /// PopScope intercept: system/shell back arriving via maybePop (the path
  /// that consults the veto) runs the SAME awaited teardown as the bar
  /// BackButton, then pops. Programmatic pops complete directly (notified
  /// with didPop:true), so [_bypass] only ever short-circuits re-entry.
  Future<void> _interceptBack() => _leave();

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
    BleLog.log(ProxLogTags.state,
        'window #$windowNo live (code ${session.displayCode})');
    // Fresh pins per window (see _prefetchStudentPins): a student who
    // enrolled or re-keyed mid-class must not prove against a stale pin
    // for the rest of the session.
    unawaited(_prefetchStudentPins());
    // Resume continues from the frozen elapsed at stop (start = now -
    // banked); fresh rounds (windowNo+1, no banked value) start at zero.
    // The comparison runs before _windowNo advances, so same-number
    // re-opens resume while next-number opens start fresh.
    final isResume = windowNo == _windowNo && _bankedElapsed != null;
    final startElapsed = isResume ? _bankedElapsed! : Duration.zero;
    _bankedElapsed = null;
    setState(() {
      live = true;
      _windowNo = windowNo;
      elapsed = startElapsed;
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
    // Freeze the elapsed for a later resume (start = now - banked).
    _bankedElapsed = elapsed;
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

  /// Discards the stopped round [n] = [_windowNo] after an explicit
  /// warning popup (marks for that round are lost; people stay — names,
  /// waiting and manual entries are visit data, not round data). Resume
  /// re-opens the same round instead (marks merge). After the drop,
  /// [_windowNo] rewinds to the newest surviving round, so a discarded
  /// final round returns the dock to Start.
  Future<void> _discardRound() async {
    final n = _windowNo;
    if (n <= 0 || live || _leaving || !mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Discard round $n?'),
        content: Text(
            'This drops every mark taken in round $n. People stay on the roster — only the round goes away. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    tally.discardWindow(n);
    BleLog.log(ProxLogTags.state, 'discarded round $n');
    if (tally.windowCount == 0) {
      // Full reset: the visit never started — no history record, no
      // draft, dock back to Start. The stopped round already upserted a
      // record at Stop time, so delete this visit's record outright
      // (tombstoned like any local delete, so peers converge too).
      final store = ref.read(deviceStoreProvider);
      try {
        await store.clearSession(widget.courseName);
      } catch (_) {}
      try {
        tally.clear();
      } catch (_) {}
      final rid = _recordId;
      if (rid != null && rid.isNotEmpty) {
        try {
          await syncEngine.deleteSessionsLocal(store, [rid],
              courseOf: (_) => widget.courseName);
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _windowNo = 0;
        _resumed = false;
        _recordId = null;
        _recordStartIso = null;
        _recordOrg = null;
        _draftDateIso = null;
        _lastSavedSig = '';
        _bankedElapsed = null;
        elapsed = Duration.zero;
      });
      bumpLiveHistoryTick();
      return;
    }
    _windowNo = tally.windowCount;
    // No round to resume from anymore: drop the frozen elapsed so the
    // next fresh Start begins at zero.
    _bankedElapsed = null;
    elapsed = Duration.zero;
    await _saveDraft();
    await _saveSnapshot();
    if (mounted) setState(() {});
    bumpLiveHistoryTick();
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
      setState(() =>
          serverError = 'Bluetooth is off — turn it on to start the window.');
      return false;
    }
    return true;
  }

  /// Ends attendance (no export — that lives on the course page): final
  /// snapshot, draft cleared, hosting down, back to the course.
  Future<void> _endAttendance() async {
    if (_leaving) return;
    _leaving = true;
    BleLog.log(
        ProxLogTags.nav, 'end attendance (final snapshot, hosting down)');
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
      _recordOrg = null;
      _bankedElapsed = null;
      // Shared tail: awaited endHosting via _teardown (save:false — the
      // draft was cleared above and must not be rewritten). A teardown
      // throw stays caught and the pop still proceeds (uniform with
      // _leave; previously an endHosting throw surfaced serverError and
      // kept the screen mounted).
      await _teardown(save: false);
      if (mounted) {
        _bypass = true;
        Navigator.of(context).pop();
      }
    } catch (e) {
      // Stay retryable: release the single-flight so End/back still work
      // (today a failed End leaves the screen usable).
      _leaving = false;
      if (!mounted) return;
      setState(() => serverError = '$e');
    }
  }

  /// Upserts the finished-so-far tally into on-device class history under
  /// this visit's stable record id: every round rewrites the SAME record,
  /// so un-closed sessions still leave data and later rounds update it.
  /// Skipped while nothing is marked (no empty records in history).
  /// The SyncEngine post-live-save hook durably queues + best-effort
  /// pushes (professors, online) — local data never waits on it.
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
      // Session org = prof org at creation, immutable afterwards: reuse
      // the first snapshot's org for later rounds of this visit.
      _recordOrg ??= await _profOrgForSession();
      record = tally.toClassRecord(
        courseId: widget.courseName,
        classLabel: widget.courseName,
        dateIso: dateIso ?? _draftDateIso ?? dateIsoOf(now),
        timestampIso: now.toUtc().toIso8601String(),
        startIso: _recordStartIso,
        id: _recordId,
        org: _recordOrg ?? '',
      );
    } catch (_) {
      // History is best-effort; live tally + draft autosave are unaffected.
      return;
    }
    final rec = record;
    final prof = await readSyncProf(ref);
    if (!mounted) return;
    try {
      final store = ref.read(deviceStoreProvider);
      final cloud = ref.read(cloudSyncProvider);
      BleLog.log(ProxLogTags.sync,
          'snapshot upserted ${rec.id} (${tally.confirmedCount} present)');
      await syncEngine.noteLocalSave(
          store: store, cloud: cloud, prof: prof, record: rec);
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

  // in the Add section (`DirectAddSection` below, `direct-` keys). The
  // former AppBar `Add student` sheet (`sheet-` keys, same module form)
  // duplicated it, so it is removed — no second entry point, no second
  // form instance. [_addDirectEntry] below stays (it is the Add section's
  // submit path: driver + draft + snapshot).

  /// Segmented sub-nav tap: swap to the tapped sub-tab. State-preserving
  /// by construction (IndexedStack keeps inactive views mounted — this is
  /// the fix for the reverted grouping probe, where unmounting broke the
  /// mid-approve inbox flow).
  void _selectSection(int i) {
    setState(() => _section = i);
  }

  /// 1-tap duplicate-face override: the driver clears the whole group and
  /// exempts the pair for the session; presence is untouched.
  Future<void> _resolveDup(String email) async {
    try {
      await _driver?.resolveDupFlag(email);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  /// Per-course photo opt-in toggle: persists immediately, then
  /// publishes (or clears) the host Gmail photo for joining students.
  Future<void> _setSharePhoto(bool share) async {
    try {
      await ref
          .read(deviceStoreProvider)
          .writeShowProfPhoto(widget.courseName, share);
    } catch (_) {}
    if (!mounted) return;
    setState(() => _sharePhoto = share);
    try {
      final photo = share
          ? (ref.read(accountProvider).valueOrNull?.photoUrl?.trim() ?? '')
          : '';
      unawaited(ref.read(hostDriverProvider).setHostPhoto(photo));
    } catch (_) {}
  }

  /// Professor eject from the roster (swipe → confirm): drops the student
  /// from waiting + manual queue + tally + dup flags, then refreshes. The
  /// next history upsert/snapshot no longer contains them; rejoin/re-mark
  /// re-adds. Returns true when anything was removed (drives the
  /// Dismissible animation).
  Future<bool> _removeStudent(String email) async {
    var removed = false;
    try {
      removed = await _driver?.removeStudent(email) ?? false;
    } catch (_) {
      removed = false;
    }
    if (!mounted) return removed;
    setState(() {});
    bumpLiveHistoryTick();
    if (removed) {
      // Tapping anywhere on the bar (OK action) dismisses it at once —
      // a passive bar that ignores taps reads as a stuck popup.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Removed — they can rejoin anytime.'),
          duration: const Duration(seconds: 3),
          action: SnackBarAction(
            label: 'OK',
            onPressed: () =>
                ScaffoldMessenger.of(context).hideCurrentSnackBar(),
          ),
        ),
      );
    }
    return removed;
  }

  @override
  Widget build(BuildContext context) {
    final present = tally.confirmedCount;
    final waiting = _driver?.waitingCount ?? 0;
    final windowsTaken = tally.windowCount;
    final waitingRows = _driver?.waitingRows ?? const [];
    final manualPending = _driver?.manualPending ?? const [];
    // AppBar avatar (gated Gmail photo iff the per-course opt-in is on,
    // else the CS-style course disc — the same [courseInitials] helper as
    // the Live list + Courses pickers, so CSL1010 reads CS everywhere).
    final appBarPhotoUrl = liveHeaderPhotoUrl(
      sharePhoto: _sharePhoto,
      accountPhotoUrl: ref.watch(accountProvider).valueOrNull?.photoUrl,
    );
    // Back-intercept (§3.5, navigation-shell rebuild): the shell still owns
    // tab back — in-tab back pops this tab's stack only, and this screen
    // never leaves the shell or touches mode. The route carries its own
    // PopScope (canPop:false) so back arriving via maybePop runs the SAME
    // awaited teardown as the bar BackButton ([_leave]: timers → save →
    // endHosting) before popping, instead of racing it through dispose.
    // Single-flight ([_leaving]) + programmatic-pop ([_bypass]) guards are
    // load-bearing against double-back mid-await. dispose() below stays
    // the backstop (timers + non-clobbering top-up + unconditional port
    // close), unchanged.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _bypass) return;
        _interceptBack();
      },
      child: AdaptiveScaffold(
        title: widget.courseName,
        // Avatar just left of the course name (28dp, same photo/initials
        // contract as before — placement only, no new plumbing).
        titleWidget: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _TakeBarAvatar(
              photoUrl: appBarPhotoUrl,
              courseName: widget.courseName,
            ),
            const SizedBox(width: ProxSpacing.sm),
            Flexible(
              child: Text(
                widget.courseName,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        ),
        leading: BackButton(onPressed: () {
          // Composition wrapper (body untouched): leaving the Live tab
          // bumps the history-refresh tick so the Courses tab re-reads on
          // re-show (its IndexedStack-kept state never re-reads alone).
          _leave().whenComplete(bumpLiveHistoryTick);
        }),
        // Zero-intersection: no AppBar add entry — manual entry lives
        // ONLY in the Add section below (single home). System log stays.
        actions: [
          IconButton(
            icon: const Icon(Icons.terminal_outlined),
            tooltip: 'System log',
            // Overlay drawer (§4.5): the radio UI keeps listening beneath
            // it. `Expand` inside pushes the full-screen debug/log.
            onPressed: () => showLogDrawer(context),
          ),
        ],
        body: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Slim top status only: dot + LIVE/IDLE + timer + counts.
                // Everything else from the old card (avatar, meta lines,
                // buttons) is gone — avatar lives in the AppBar above,
                // actions dock below.
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      ProxSpacing.screenMargin, 12, ProxSpacing.screenMargin, 0),
                  child: LiveStatusStrip(
                    live: live,
                    elapsed: elapsed,
                    present: present,
                    waiting: waiting,
                  ),
                ),
                if (_resumed)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        ProxSpacing.screenMargin, 8, ProxSpacing.screenMargin, 0),
                    child: DraftResumedBanner(
                      present: present,
                      windowsTaken: windowsTaken,
                      onDiscard: _discardDraft,
                    ),
                  ),
                // Wider bar: md (12) side insets instead of the screen
                // margin (20) — the width is there, so the five cells
                // breathe instead of squeezing.
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      ProxSpacing.md, 8, ProxSpacing.md, 0),
                  child: LiveSubNav(
                    selected: _section,
                    waitingCount: waitingRows.length,
                    inboxCount: manualPending.length,
                    onSelect: _selectSection,
                  ),
                ),
                Expanded(
                  // this IndexedStack — each sub-tab shows ONLY its view, no
                  // shared scroll, no intersection. Inactive views stay mounted
                  // (state-preserving switch): roster search, waiting list,
                  // mid-approve inbox selection, and direct-add fields survive
                  // tab switches — the reverted grouping probe failed exactly
                  // because unmounting broke the inbox approve flow. Order is
                  // Roster · Waiting · Inbox · Add · Setup. Each tab scrolls
                  // independently. Bottom padding reserves room for the
                  // floating controls docked below (content never slides
                  // under the buttons).
                  child: IndexedStack(
                    index: _section,
                    children: [
                      // 0 — Roster only: dup flags + marked (search + present
                      // + partial). Same `LiveRosterBody` composer with
                      // waiting excluded (it lives on its own tab). Top
                      // inset is xs — the search sits tight under the bar.
                      SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(
                            ProxSpacing.screenMargin,
                            ProxSpacing.xs,
                            ProxSpacing.screenMargin,
                            220),
                        child: LiveRosterBody(
                          waitingRows: const [],
                          groups: _driver?.dupGroups ?? const {},
                          names: tally.nameMap(),
                          onResolve: _resolveDup,
                          tally: tally,
                          onRemoveStudent: _removeStudent,
                          includeWaiting: false,
                          rosterTotal: _historyUnion,
                        ),
                      ),
                      // 1 — Waiting only: parked joiners for the next window.
                      SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(
                            ProxSpacing.screenMargin,
                            ProxSpacing.sm,
                            ProxSpacing.screenMargin,
                            220),
                        child: WaitingListSection(
                          waitingRows: waitingRows,
                          onRemove: _removeStudent,
                        ),
                      ),
                      // 2 — Inbox only: pending manual requests. Wrappers bump
                      // the history-refresh tick (decisions upsert history).
                      SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(
                            ProxSpacing.screenMargin,
                            ProxSpacing.sm,
                            ProxSpacing.screenMargin,
                            220),
                        child: ManualInboxSection(
                          pending: manualPending,
                          onApproveOne: (email) => _approveOne(email)
                              .whenComplete(bumpLiveHistoryTick),
                          onRejectOne: (email) => _rejectOne(email)
                              .whenComplete(bumpLiveHistoryTick),
                          onDecide: (emails, approve) =>
                              _decideSelected(emails, approve)
                                  .whenComplete(bumpLiveHistoryTick),
                        ),
                      ),
                      // 3 — Add only: direct manual entry (the single home —
                      // no AppBar sheet extra). The wrapper preserves the
                      // submit's error propagation (`whenComplete` rethrows)
                      // and bumps the tick (adds upsert history).
                      SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(
                            ProxSpacing.screenMargin,
                            ProxSpacing.sm,
                            ProxSpacing.screenMargin,
                            220),
                        child: DirectAddSection(
                          course: widget.courseName,
                          sessionId: _recordId ?? '',
                          onAdd: ({
                            required String name,
                            required String roll,
                            required String email,
                          }) =>
                              _addDirectEntry(
                                      name: name, roll: roll, email: email)
                                  .whenComplete(bumpLiveHistoryTick),
                          // Present = every round taken (intersection):
                          // re-adding one shows "Already marked present.";
                          // partials still go through.
                          isPresent: (email) => tally.confirmed
                              .any((r) => r.email == email.toLowerCase()),
                        ),
                      ),
                      // 4 — Setup only: name/IP/discovery before Start, plus
                      // a live student-view preview (same shared card).
                      SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(
                            ProxSpacing.screenMargin,
                            ProxSpacing.sm,
                            ProxSpacing.screenMargin,
                            220),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            LiveSetupSection(
                              hosting: hosting,
                              live: live,
                              nameCtrl: _nameCtrl,
                              onNameChanged: (v) {
                                try {
                                  ref
                                      .read(hostDriverProvider)
                                      .setDisplayName(v);
                                } catch (_) {}
                                // Live preview follows typing.
                                if (mounted) setState(() {});
                              },
                              serverLine: serverLine,
                              allIps: _session?.allIps ?? const [],
                              currentIp: _ip,
                              onPickIp: _pickIp,
                              serverError: serverError,
                              showProfPhoto: _sharePhoto,
                              onShowProfPhotoChanged: _setSharePhoto,
                            ),
                            // Student-view preview from the first setup paint
                            // (pre-hosting included): the toggle + name field
                            // above drive it live, so the professor sees the
                            // student view before going live.
                            if (!live) ...[
                              const SizedBox(height: ProxSpacing.md),
                              _StudentViewPreview(
                                displayName: _nameCtrl.text,
                                showPhoto: _sharePhoto,
                                org: _announcedOrg,
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
            // Floating controls docked just above the shell nav bar:
            // fresh → full-width Start; live → full-width Stop;
            // post-round → 2x2 grid (Discard + End / Resume +
            // Take another). Same enablement as the old cluster.
            Positioned(
              left: ProxSpacing.lg,
              right: ProxSpacing.lg,
              bottom: ProxSpacing.sm,
              child: SafeArea(
                top: false,
                child: LiveFloatingControls(
                  live: live,
                  hosting: hosting,
                  windowNo: _windowNo,
                  elapsed: elapsed,
                  present: present,
                  waiting: waiting,
                  onStart: _startNext,
                  onResume: () => _start(_windowNo),
                  onDiscard: _discardRound,
                  onTakeAnother: _startNext,
                  // Composition wrappers (bodies untouched): stopping a round
                  // and ending attendance both upsert class history — bump the
                  // history-refresh tick so the Courses tab re-reads on
                  // re-show instead of serving its stale snapshot.
                  onStop: () =>
                      _stopEarly().whenComplete(bumpLiveHistoryTick),
                  onEnd: () =>
                      _endAttendance().whenComplete(bumpLiveHistoryTick),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// AppBar avatar just left of the course name (28dp): gated Gmail photo
/// iff the per-course opt-in supplied a URL, else the course disc via
/// [courseInitials] — the same helper as the Live list + Courses pickers,
/// so CSL1010 reads CS in all three places. Static (no timers/animation)
/// so the 1s elapsed tick stays the only motion on this screen.
class _TakeBarAvatar extends StatelessWidget {
  final String photoUrl;
  final String courseName;

  const _TakeBarAvatar({required this.photoUrl, required this.courseName});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    Widget initials() => Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.accentBrand.withValues(alpha: 0.12),
          ),
          alignment: Alignment.center,
          child: Text(
            courseInitials(courseName),
            style: ProxType.label(color: c.accentBrand).copyWith(
              fontWeight: FontWeight.w700,
            ),
            overflow: TextOverflow.clip,
            maxLines: 1,
          ),
        );
    final photo = photoUrl.trim();
    if (photo.isEmpty) return initials();
    return ClipOval(
      child: Image.network(
        photo,
        width: 28,
        height: 28,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => initials(),
        frameBuilder: (context, child, frame, _) {
          if (frame == null) return initials();
          return child;
        },
      ),
    );
  }
}

/// "This is what students will see": the SAME shared [HostPreviewCard]
// the waiting room renders — display name as typed (Gmail name by
// default), Gmail email + announced org, Gmail photo iff the photo toggle
// is on (letter initial otherwise). Updates live with name/toggle/org.
// [org] is the announced org the beacon airs (role-cache stamp) — passed
// in so the preview mapping is provably identical to the waiting card
// (same widget + same inputs: displayName/email/org/photo).
class _StudentViewPreview extends ConsumerWidget {
  final String displayName;
  final bool showPhoto;
  final String org;

  const _StudentViewPreview({
    required this.displayName,
    required this.showPhoto,
    this.org = '',
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ProximityColors.of(context);
    final acct = ref.watch(accountProvider).valueOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'This is what students will see',
          style: ProxType.label(color: c.contentSecondary),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        const SizedBox(height: ProxSpacing.xs),
        HostPreviewCard(
          displayName: displayName,
          email: acct?.email ?? '',
          org: org,
          photoUrl: showPhoto ? (acct?.photoUrl ?? '') : '',
        ),
      ],
    );
  }
}
