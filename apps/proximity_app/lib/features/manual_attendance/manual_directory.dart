// Search/queue orchestration for the manual-add form. The
// orchestration below lived inline in `widgets/manual_add.dart`
// (`_ManualAddFormState`: debounce timer, online-probe cache,
// `searchStudents` queries, `writePendingAdds` paths, all four submit
// paths). Moved here verbatim: same queries, same queue writes, same
// user-facing copy — so the `ManualAddForm` UI (now
// `manual_add_form.dart`, same module) behaves identically.
//
// What this owns: directory search (400ms debounce, stale-generation
// drop, 15s online-probe cache, 10s failure-log throttle), exact-ID
// resolve, offline pending-add queue writes, and the four submit paths:
// add-at-once / exact-ID resolve + `Matched online` / no-match copy /
// offline queue + queued copy / `ID Number is required.` /
// `Already marked present.` Nothing here renders widgets.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';

import '../../core/cloud_sync.dart';
import '../../core/device_store.dart';
import '../../design/tokens.dart';

export '../../core/sync/queue.dart'
    show PendingManualAdd, SyncQueue, processPendingAdds;

/// User-facing copy for a caught error: [StateError] stringifies as
/// from `widgets/manual_add.dart`.)
String manualAddUserMessage(Object e) => '$e'
    .replaceFirst('StateError: ', '')
    .replaceFirst('Bad state: ', '');

/// Search/queue orchestration for one manual-add form instance. Owned by
/// the form's state (created in `initState`, disposed with it); reads
/// cloud/store lazily through [Ref] exactly where the old inline code
/// did, so provider overrides in tests behave identically.
class ManualDirectoryController extends ChangeNotifier {
  ManualDirectoryController(this._ref);

  final WidgetRef _ref;

  Timer? _debounce;

  /// Last directory-search failure already mirrored to the log ring:
  /// repeat failures for the same query log at most once per 10s (offline
  /// typing would otherwise emit one SYNC line per debounced keystroke).
  DateTime? _failLoggedAt;
  String _failLoggedMsg = '';

  void _logSearchFailure(String msg) {
    final now = DateTime.now().toUtc();
    if (msg == _failLoggedMsg &&
        _failLoggedAt != null &&
        now.difference(_failLoggedAt!) < const Duration(seconds: 10)) {
      return;
    }
    _failLoggedMsg = msg;
    _failLoggedAt = now;
    BleLog.log(ProxLogTags.sync, 'ManualAdd directory search failed: $msg');
  }

  // Generation counter: a slow earlier query must never overwrite newer
  // results (keystrokes overlap in flight).
  int _searchGen = 0;

  DateTime? _onlineCheckedAt;
  bool _onlineCached = false;

  /// Latest field snapshot (stored on every [scheduleSearch] so the
  /// debounced fire reads current input, exactly like the old inline
  /// code reading its text controllers at fire time).
  String _qRoll = '';
  String _qName = '';
  String _qEmail = '';

  /// Directory hits for the current query.
  List<StudentDirectoryEntry> hits = [];

  /// Search UI state (mirrors the old inline flags one-for-one).
  bool searching = false;
  bool searchOffline = false;
  String searchError = '';

  /// True once a search round completed with a non-empty query: gates the
  /// "no match" empty state so a fresh form doesn't lecture.
  bool searched = false;

  /// Submit UI state.
  String error = '';
  String note = '';
  bool busy = false;

  bool _alive = true;

  @override
  void dispose() {
    _alive = false;
    _debounce?.cancel();
    super.dispose();
  }

  void _emit() {
    if (_alive) notifyListeners();
  }

  Future<bool> isOnline() async {
    final now = DateTime.now().toUtc();
    if (_onlineCheckedAt != null &&
        now.difference(_onlineCheckedAt!) < const Duration(seconds: 15)) {
      return _onlineCached;
    }
    var online = false;
    try {
      final cloud = _ref.read(cloudSyncProvider);
      online = cloud.available &&
          await cloud.isOnline().timeout(const Duration(seconds: 6));
    } catch (_) {
      online = false;
    }
    _onlineCheckedAt = now;
    _onlineCached = online;
    return online;
  }

  /// Schedules a debounced directory search over the given field snapshot.
  void scheduleSearch({
    required String roll,
    required String name,
    required String email,
  }) {
    _qRoll = roll;
    _qName = name;
    _qEmail = email;
    _debounce?.cancel();
    _debounce = Timer(ProxDurations.searchDebounce, _runSearch);
  }

  Future<void> _runSearch() async {
    if (_qRoll.trim().isEmpty &&
        _qName.trim().isEmpty &&
        _qEmail.trim().isEmpty) {
      hits = [];
      searching = false;
      searchOffline = false;
      searchError = '';
      searched = false;
      _emit();
      return;
    }
    final gen = ++_searchGen;
    bool stale() => !_alive || gen != _searchGen;
    searching = true;
    searchError = '';
    _emit();
    try {
      if (!await isOnline()) {
        if (stale()) return;
        searching = false;
        searchOffline = true;
        hits = [];
        searched = true;
        _emit();
        return;
      }
      final cloud = _ref.read(cloudSyncProvider);
      // Load shapes: the name field is the least selective (a 1-char
      // prefix returns the first 10 names alphabetically — noise that
      // still bills reads), so it waits for 2 chars. ID and email are
      // selective from the first character and fire immediately.
      final name = _qName.trim();
      String myOrg = '';
      try {
        final role = await _ref.read(deviceStoreProvider).readRole();
        myOrg = roleOrg(role);
      } catch (_) {}
      final found = await cloud.searchStudents(
        rollPrefix: _qRoll,
        namePrefix: name.length >= 2 ? _qName : '',
        emailPrefix: _qEmail,
        org: myOrg,
      );
      if (stale()) return;
      hits = found;
      searching = false;
      searchOffline = false;
      searched = true;
      _emit();
    } catch (e) {
      // Search is advisory for SUBMIT (typing still works, submit resolves
      // or queues) but failures are SHOWN, never swallowed: a denied query
      // (rules not deployed, professor role missing) otherwise looks
      // exactly like "no students enrolled". They are also mirrored once
      // to the SYNC log ring (throttled above) for the terminal + logcat.
      _logSearchFailure(manualAddUserMessage(e));
      if (stale()) return;
      final msg = manualAddUserMessage(e);
      searching = false;
      searchOffline = msg.contains('internet');
      if (searchOffline) hits = [];
      searchError = searchOffline ? '' : msg;
      searched = true;
      _emit();
    }
  }

  /// Already on the hosting list → note instead of re-adding (used by the
  /// card tap and both submit paths; partials still go through).
  bool alreadyPresent(String email, bool Function(String email)? isPresent) {
    if (email.isEmpty) return false;
    return isPresent?.call(email.toLowerCase()) ?? false;
  }

  void notePresent() {
    busy = false;
    error = '';
    searchError = '';
    note = 'Already marked present.';
    hits = [];
    _emit();
  }

  /// Tap-a-card fill: notes instead of filling when already present.
  void pickHit(
    StudentDirectoryEntry h,
    bool Function(String email)? isPresent,
    void Function(String name, String roll, String email) fillFields,
  ) {
    if (alreadyPresent(h.email, isPresent)) {
      notePresent();
      return;
    }
    error = '';
    note = '';
    hits = [];
    _emit();
    fillFields(h.name, h.roll, h.email);
  }

  ///  1. name + valid email present (typed or card-filled) → added at once.
  ///  2. ID only + online + directory holds that exact ID → `Matched
  ///     online` + added.
  ///  3. ID only + online + no match → error asking for full details.
  ///  4. ID only + offline → queued for the next sync + queued note.
  /// Empty roll → `ID Number is required.` [clearFields] mirrors the old
  /// inline controller clears.
  Future<void> submit({
    required String rollRaw,
    required String nameRaw,
    required String emailRaw,
    required String course,
    required String sessionId,
    required Future<void> Function(
            {required String name,
            required String roll,
            required String email})
        onAdd,
    bool Function(String email)? isPresent,
    required void Function() clearFields,
  }) async {
    final roll = rollRaw.trim();
    final name = nameRaw.trim();
    final email = emailRaw.trim().toLowerCase();
    if (roll.isEmpty) {
      error = 'ID Number is required.';
      note = '';
      _emit();
      return;
    }
    if (name.isNotEmpty && email.isNotEmpty && email.contains('@')) {
      await add(
          name: name,
          roll: roll,
          email: email,
          onAdd: onAdd,
          isPresent: isPresent,
          clearFields: clearFields);
      return;
    }
    // ID only: resolve online, queue offline.
    busy = true;
    error = '';
    note = '';
    _emit();
    try {
      final cloud = _ref.read(cloudSyncProvider);
      final online = await isOnline();
      String myOrg = '';
      try {
        final role = await _ref.read(deviceStoreProvider).readRole();
        myOrg = roleOrg(role);
      } catch (_) {}
      if (online) {
        StudentDirectoryEntry? match;
        try {
          final found =
              await cloud.searchStudents(rollPrefix: roll, org: myOrg);
          match = matchRollExact(found, roll);
        } catch (_) {
          match = null;
        }
        if (match != null && _alive) {
          final m = match;
          if (alreadyPresent(m.email, isPresent)) {
            notePresent();
            return;
          }
          note = 'Matched online: ${m.name}';
          _emit();
          await add(
              name: m.name.isNotEmpty ? m.name : name,
              roll: roll,
              email: m.email,
              onAdd: onAdd,
              isPresent: isPresent,
              clearFields: clearFields);
          return;
        }
        if (_alive) {
          busy = false;
          error = name.isNotEmpty && email.isNotEmpty
              ? 'Enter a valid email.'
              : 'No enrolled student with this ID — type the name + email as well, or retry online.';
          _emit();
        }
        return;
      }
      // Offline: queue for the next sync (ID is enough to resolve later).
      final store = _ref.read(deviceStoreProvider);
      final prev = await store.readPendingAdds();
      await store.writePendingAdds([
        ...prev,
        PendingManualAdd(
          course: course,
          sessionId: sessionId,
          roll: roll,
          name: name,
          email: (email.contains('@')) ? email : '',
          createdAtIso: DateTime.now().toUtc().toIso8601String(),
          org: myOrg,
        ).toJson(),
      ]);
      if (_alive) {
        busy = false;
        note =
            'No internet — queued. It applies automatically on the next sync.';
        _emit();
        clearFields();
      }
    } finally {
      if (_alive && busy) {
        busy = false;
        _emit();
      }
    }
  }

  /// guarantees an ID plus a resolved or typed name/email — or queues
  /// offline itself.
  Future<void> add({
    required String name,
    required String roll,
    required String email,
    required Future<void> Function(
            {required String name,
            required String roll,
            required String email})
        onAdd,
    bool Function(String email)? isPresent,
    required void Function() clearFields,
  }) async {
    if (alreadyPresent(email, isPresent)) {
      notePresent();
      return;
    }
    busy = true;
    error = '';
    _emit();
    try {
      await onAdd(name: name, roll: roll, email: email);
    } catch (e) {
      // Back to idle: the professor fixes the entry and retries.
      if (_alive) {
        busy = false;
        error = manualAddUserMessage(e);
        _emit();
      }
      return;
    }
    if (_alive) {
      busy = false;
      note = '';
      _emit();
      clearFields();
    }
  }
}
