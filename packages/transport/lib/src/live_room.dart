// Live waiting room + manual attendance registry (extracted from ProxServer).
//
// Standalone owner of the waiting/manual maps with identical semantics to
// the former ProxServer inline implementation: ProxServer delegates to this
// class (same public method names/signatures) and keeps HTTP routing,
// /prove orchestration, window open/close, bearer, TLS, rate limits and
// sighting grace. No endpoint, timing, or threshold changes here.
//
// Tally wiring: [registerWaiting]/[requestManual] ensure the tally row;
// approving via [decideManual] marks the current window (or window 1 when
// idle, i.e. `_windowNo == 0 ? 1 : _windowNo` on the server).
library;

import 'package:proximity_storage/storage.dart';

class WaitingEntry {
  final String email;
  final String name;
  final String roll;
  final DateTime ts;
  const WaitingEntry(
      {required this.email,
      required this.name,
      required this.roll,
      required this.ts});
  Map<String, dynamic> toJson() =>
      {'email': email, 'name': name, 'roll': roll, 'ts': ts.toIso8601String()};
}

class ManualEntry {
  final String email;
  final String name;
  final String roll;
  final DateTime ts;
  String status; // pending|approved|rejected
  ManualEntry(
      {required this.email,
      required this.name,
      required this.roll,
      required this.ts,
      this.status = 'pending'});
  Map<String, dynamic> toJson() => {
        'email': email,
        'name': name,
        'roll': roll,
        'ts': ts.toIso8601String(),
        'status': status,
      };
}

/// Waiting registry + manual request/decide/status + presence/leave
/// bookkeeping. Bodies are verbatim copies of the former ProxServer inline
/// methods; only `_windowNo`/`tally` resolve through the injected
/// [windowNoOf]/[tally] so approval still marks the current window (1 idle).
class LiveRoom {
  final TallyStore tally;
  final int Function() windowNoOf;

  LiveRoom({required this.tally, required this.windowNoOf});

  final Map<String, WaitingEntry> _waiting = {};
  final Map<String, ManualEntry> _manual = {};

  // ---- Waiting room (students join before the window opens) ----
  void registerWaiting(String email, String name, [String roll = '']) {
    final key = email.trim().toLowerCase();
    if (key.isEmpty || !key.contains('@')) return;
    _waiting[key] = WaitingEntry(
        email: key, name: name, roll: roll, ts: DateTime.now().toUtc());
    tally.ensure(key, name, roll);
  }

  /// Explicit leave: the student backed out of the waiting room (Cancel /
  /// back navigation / dispose). Returns true when an entry was removed.
  /// Presence heartbeats stop with the room timers, so without this the
  /// professor's waiting count would stay stale.
  bool removeWaiting(String email) {
    final key = email.trim().toLowerCase();
    if (key.isEmpty) return false;
    return _waiting.remove(key) != null;
  }

  List<WaitingEntry> get waitingRows {
    final out = _waiting.values.toList()
      ..sort((a, b) => a.ts.compareTo(b.ts));
    return out;
  }

  int get waitingCount => _waiting.length;

  // ---- Manual attendance over LAN ----
  void requestManual(String email, String name, [String roll = '']) {
    final key = email.trim().toLowerCase();
    if (key.isEmpty || !key.contains('@')) return;
    final prev = _manual[key];
    _manual[key] = ManualEntry(
        email: key,
        name: name,
        roll: roll,
        ts: DateTime.now().toUtc(),
        status: prev?.status == 'approved' ? 'approved' : 'pending');
    tally.ensure(key, name, roll);
  }

  List<ManualEntry> get manualRows {
    final out = _manual.values.toList()
      ..sort((a, b) => a.ts.compareTo(b.ts));
    return out;
  }

  List<ManualEntry> get manualPending =>
      manualRows.where((e) => e.status == 'pending').toList();

  String manualStatus(String email) =>
      _manual[email.trim().toLowerCase()]?.status ?? 'none';

  /// Prof decision. Approving marks the student present in the current
  /// window (or window 1 when idle) so manual marks count in the session.
  bool decideManual(String email, bool approve) {
    final key = email.trim().toLowerCase();
    final e = _manual[key];
    if (e == null) return false;
    e.status = approve ? 'approved' : 'rejected';
    if (approve) {
      final windowNo = windowNoOf();
      tally.mark(key, e.name, windowNo == 0 ? 1 : windowNo, roll: e.roll);
    }
    return true;
  }
}
