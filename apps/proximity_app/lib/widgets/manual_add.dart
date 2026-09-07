// Shared manual-add form (modular UI): ONE field set for both professor
// manual entries — the live take-attendance direct entry and the saved
// session editor. The three fields (ID, name, email) ARE the directory
// search: typing live-searches the online student directory (400 ms
// debounced, parallel single-field prefix queries, stale generations
// dropped; name waits for 2 chars, ID/email fire at 1) and tapping a
// card fills all three. Typing without tapping works the same — the ID
// Number is the only compulsory field.
//
// Submit path:
//   1. name + email present (typed or card-filled) → added at once.
//   2. ID only + online + directory holds that exact ID → name/email are
//      fetched and the add completes with a "Matched online" note.
//   3. ID only + online + no match → error asking for full details.
//   4. ID only + offline → the task is stored in the pending queue and
//      applied on the next sync (see processPendingAdds in
//      core/sync/queue.dart), with a queued
//      note. Nothing is lost; attendance lands late, never missing.
//
// Field keys are "$fieldPrefix-name|-roll|-email" so the two mounted
// instances (take-attendance uses 'direct', session edit uses 'edit')
// keep stable, testable keys without colliding.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';

import '../core/cloud_sync.dart';
import '../core/device_store.dart';
import '../design/tokens.dart';
import 'prox_buttons.dart';
import 'prox_cards.dart';
import 'prox_states.dart';

/// Queue replay ([processPendingAdds], [PendingManualAdd], [SyncQueue])
/// lives in core/sync/queue.dart — re-exported here so existing callers
/// (records page, tests) keep importing this file.
export '../core/sync/queue.dart';

/// User-facing copy for a caught error: [StateError] stringifies as
/// 'Bad state: [message]', so both prefixes come off.
String _userMessage(Object e) => '$e'
    .replaceFirst('StateError: ', '')
    .replaceFirst('Bad state: ', '');

class ManualAddForm extends ConsumerStatefulWidget {
  final String fieldPrefix;
  final String course;
  final String sessionId;
  final Future<void> Function(
      {required String name,
      required String roll,
      required String email}) onAdd;
  /// Present-check for the hosting list (live tally intersection on the
  /// take screen, session intersection on the edit page). When it returns
  /// true the form shows "Already marked present." instead of re-adding —
  /// partials (not in every round) still go through.
  final bool Function(String email)? isPresent;
  const ManualAddForm(
      {super.key,
      required this.fieldPrefix,
      required this.course,
      required this.sessionId,
      required this.onAdd,
      this.isPresent});

  @override
  ConsumerState<ManualAddForm> createState() => _ManualAddFormState();
}

class _ManualAddFormState extends ConsumerState<ManualAddForm> {
  final _nameCtrl = TextEditingController();
  final _rollCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  String _error = '';
  String _note = '';
  bool _busy = false;
  // Live directory search over these same fields (debounced, parallel).
  Timer? _debounce;
  List<StudentDirectoryEntry> _hits = [];
  bool _searching = false;
  bool _searchOffline = false;
  // Generation counter: a slow earlier query must never overwrite newer
  // results (keystrokes overlap in flight).
  int _searchGen = 0;
  // Last directory-search failure already mirrored to the log ring:
  // repeat failures for the same query log at most once per 10s (offline
  // typing would otherwise emit one SYNC line per debounced keystroke —
  // same dedupe idea as the BLE beacon/relay loud-keys).
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

  // Last search failure, shown verbatim (permission-denied names the rules
  // redeploy; nothing here is ever silently swallowed).
  String _searchError = '';
  // True once a search round completed with a non-empty query: gates the
  // "no match" empty state so a fresh form doesn't lecture.
  bool _searched = false;
  DateTime? _onlineCheckedAt;
  bool _onlineCached = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _nameCtrl.dispose();
    _rollCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  bool get _hasQuery =>
      _rollCtrl.text.trim().isNotEmpty ||
      _nameCtrl.text.trim().isNotEmpty ||
      _emailCtrl.text.trim().isNotEmpty;

  void _scheduleSearch() {
    _debounce?.cancel();
    _debounce = Timer(ProxDurations.searchDebounce, _runSearch);
  }

  Future<bool> _isOnline() async {
    final now = DateTime.now().toUtc();
    if (_onlineCheckedAt != null &&
        now.difference(_onlineCheckedAt!) < const Duration(seconds: 15)) {
      return _onlineCached;
    }
    var online = false;
    try {
      final cloud = ref.read(cloudSyncProvider);
      online = cloud.available &&
          await cloud.isOnline().timeout(const Duration(seconds: 6));
    } catch (_) {
      online = false;
    }
    _onlineCheckedAt = now;
    _onlineCached = online;
    return online;
  }

  Future<void> _runSearch() async {
    if (!_hasQuery) {
      if (mounted) {
        setState(() {
          _hits = [];
          _searching = false;
          _searchOffline = false;
          _searchError = '';
          _searched = false;
        });
      }
      return;
    }
    final gen = ++_searchGen;
    bool stale() => !mounted || gen != _searchGen;
    if (mounted) {
      setState(() {
        _searching = true;
        _searchError = '';
      });
    }
    try {
      if (!await _isOnline()) {
        if (stale()) return;
        setState(() {
          _searching = false;
          _searchOffline = true;
          _hits = [];
          _searched = true;
        });
        return;
      }
      final cloud = ref.read(cloudSyncProvider);
      // Load shapes: the name field is the least selective (a 1-char
      // prefix returns the first 10 names alphabetically — noise that
      // still bills reads), so it waits for 2 chars. ID and email are
      // selective from the first character and fire immediately.
      final name = _nameCtrl.text.trim();
      String myOrg = '';
      try {
        final role = await ref.read(deviceStoreProvider).readRole();
        myOrg = (role?['org'] ?? '').trim().toLowerCase();
      } catch (_) {}
      final hits = await cloud.searchStudents(
        rollPrefix: _rollCtrl.text,
        namePrefix: name.length >= 2 ? _nameCtrl.text : '',
        emailPrefix: _emailCtrl.text,
        org: myOrg,
      );
      if (stale()) return;
      setState(() {
        _hits = hits;
        _searching = false;
        _searchOffline = false;
        _searched = true;
      });
    } catch (e) {
      // Search is advisory for SUBMIT (typing still works, submit resolves
      // or queues) but failures are SHOWN, never swallowed: a denied query
      // (rules not deployed, professor role missing) otherwise looks
      // exactly like "no students enrolled". They are also mirrored once
      // to the SYNC log ring (throttled above) for the terminal + logcat.
      _logSearchFailure(_userMessage(e));
      if (stale()) return;
      final msg = _userMessage(e);
      setState(() {
        _searching = false;
        _searchOffline = msg.contains('internet');
        if (_searchOffline) _hits = [];
        _searchError = _searchOffline ? '' : msg;
        _searched = true;
      });
    }
  }

  /// Already on the hosting list → note instead of re-adding (used by the
  /// card tap and both submit paths; partials still go through).
  bool _alreadyPresent(String email) {
    if (email.isEmpty) return false;
    return widget.isPresent?.call(email.toLowerCase()) ?? false;
  }

  void _notePresent() {
    setState(() {
      _busy = false;
      _error = '';
      _searchError = '';
      _note = 'Already marked present.';
      _hits = [];
    });
  }

  void _fill(String name, String roll, String email) {
    _nameCtrl.text = name;
    _rollCtrl.text = roll;
    _emailCtrl.text = email;
  }

  Future<void> _submit() async {
    final roll = _rollCtrl.text.trim();
    final name = _nameCtrl.text.trim();
    final email = _emailCtrl.text.trim().toLowerCase();
    if (roll.isEmpty) {
      setState(() {
        _error = 'ID Number is required.';
        _note = '';
      });
      return;
    }
    if (name.isNotEmpty && email.isNotEmpty && email.contains('@')) {
      await _add(name, roll, email);
      return;
    }
    // ID only: resolve online, queue offline.
    setState(() {
      _busy = true;
      _error = '';
      _note = '';
    });
    try {
      final cloud = ref.read(cloudSyncProvider);
      final online = await _isOnline();
      String myOrg = '';
      try {
        final role = await ref.read(deviceStoreProvider).readRole();
        myOrg = (role?['org'] ?? '').trim().toLowerCase();
      } catch (_) {}
      if (online) {
        StudentDirectoryEntry? match;
        try {
          final hits =
              await cloud.searchStudents(rollPrefix: roll, org: myOrg);
          match = matchRollExact(hits, roll);
        } catch (_) {
          match = null;
        }
        if (match != null && mounted) {
          final m = match;
          if (_alreadyPresent(m.email)) {
            _notePresent();
            return;
          }
          setState(() => _note = 'Matched online: ${m.name}');
          await _add(
              m.name.isNotEmpty ? m.name : name, roll, m.email);
          return;
        }
        if (mounted) {
          setState(() {
            _busy = false;
            _error = name.isNotEmpty && email.isNotEmpty
                ? 'Enter a valid email.'
                : 'No enrolled student with this ID — type the name + email as well, or retry online.';
          });
        }
        return;
      }
      // Offline: queue for the next sync (ID is enough to resolve later).
      final store = ref.read(deviceStoreProvider);
      final prev = await store.readPendingAdds();
      await store.writePendingAdds([
        ...prev,
        PendingManualAdd(
          course: widget.course,
          sessionId: widget.sessionId,
          roll: roll,
          name: name,
          email: (email.contains('@')) ? email : '',
          createdAtIso: DateTime.now().toUtc().toIso8601String(),
          org: myOrg,
        ).toJson(),
      ]);
      if (mounted) {
        setState(() {
          _busy = false;
          _note =
              'No internet — queued. It applies automatically on the next sync.';
        });
        _nameCtrl.clear();
        _rollCtrl.clear();
        _emailCtrl.clear();
      }
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  Future<void> _add(String name, String roll, String email) async {
    if (_alreadyPresent(email)) {
      if (mounted) _notePresent();
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await widget.onAdd(name: name, roll: roll, email: email);
    } catch (e) {
      // Back to idle: the professor fixes the entry and retries.
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _userMessage(e);
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _note = '';
      });
      _nameCtrl.clear();
      _rollCtrl.clear();
      _emailCtrl.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.fieldPrefix;
    // A 1-char name never queries (withheld load-side), so it must not
    // read as "no match".
    final effectiveQuery = _rollCtrl.text.trim().isNotEmpty ||
        _emailCtrl.text.trim().isNotEmpty ||
        _nameCtrl.text.trim().length >= 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Type to search the online directory — tap a card to fill:',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 4),
        TextField(
          key: ValueKey('$p-roll'),
          controller: _rollCtrl,
          onChanged: (_) => _scheduleSearch(),
          decoration: const InputDecoration(
            labelText: 'ID Number (required)',
            prefixIcon: Icon(Icons.badge_outlined),
            suffixIcon: Icon(Icons.cloud_outlined),
            helperText: 'Searches the online student directory',
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          key: ValueKey('$p-name'),
          controller: _nameCtrl,
          onChanged: (_) => _scheduleSearch(),
          decoration: const InputDecoration(
            labelText: 'Student name (fills from ID when online)',
            prefixIcon: Icon(Icons.person_outline),
            suffixIcon: Icon(Icons.cloud_outlined),
            helperText: 'Searches the online student directory',
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          key: ValueKey('$p-email'),
          controller: _emailCtrl,
          onChanged: (_) => _scheduleSearch(),
          decoration: const InputDecoration(
            labelText: 'Student email (fills from ID when online)',
            prefixIcon: Icon(Icons.email_outlined),
            suffixIcon: Icon(Icons.cloud_outlined),
            helperText: 'Searches the online student directory',
          ),
          keyboardType: TextInputType.emailAddress,
        ),
        if (_searching) ...[
          const SizedBox(height: 8),
          const ProxLoadingRow(label: 'Searching online…'),
        ],
        if (_searchOffline && _hasQuery) ...[
          const SizedBox(height: 8),
          Text(
            'Directory unreachable — your entry still saves (queued when needed).',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
        if (_searchError.isNotEmpty && _hasQuery) ...[
          const SizedBox(height: 8),
          Text(
            'Directory search failed: $_searchError',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (_searchError.isEmpty &&
            !_searching &&
            !_searchOffline &&
            _searched &&
            _hasQuery &&
            effectiveQuery &&
            _hits.isEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'No enrolled students match — they enroll once online in the native app.',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
        for (final h in _hits)
          ProxListTile(
            dense: true,
            leading: const Icon(Icons.account_circle_outlined),
            title: h.name.isEmpty ? h.email : h.name,
            subtitle:
                [if (h.roll.isNotEmpty) h.roll, h.email].join(' · '),
            trailing: const Icon(Icons.add),
            onTap: () {
              if (_alreadyPresent(h.email)) {
                _notePresent();
                return;
              }
              setState(() {
                _error = '';
                _note = '';
                _hits = [];
              });
              _fill(h.name, h.roll, h.email);
            },
          ),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_error,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        if (_note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _note,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: ProxSecondaryButton(
            icon: _busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.person_add),
            label: const Text('Add & mark present'),
            onPressed: _busy ? null : _submit,
          ),
        ),
      ],
    );
  }
}
