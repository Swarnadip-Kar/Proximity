// Shared BLE/system event log for the toggleable terminal views.
//
// The BLE engine + drivers append here; the student / prof screens render
// the same history in a terminal-style window (toggle on/off). Pure Dart
// (no Flutter) so `proximity_ble` can log without an app dependency.
library;

import 'dart:async';

class BleLogEntry {
  final DateTime at;
  final String tag;
  final String msg;
  BleLogEntry(this.at, this.tag, this.msg);

  String get line {
    final t = at.toUtc();
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    return '[$hh:$mm:$ss.$ms] [$tag] $msg';
  }
}

/// Ring-buffer + broadcast stream. UI subscribes via [stream] and seeds
/// from [history]. Cap keeps the terminal bounded on long windows.
class BleLog {
  static const int cap = 500;
  static final List<BleLogEntry> _history = [];
  static final StreamController<BleLogEntry> _ctl =
      StreamController<BleLogEntry>.broadcast();

  static List<BleLogEntry> get history => List.unmodifiable(_history);
  static Stream<BleLogEntry> get stream => _ctl.stream;

  static void log(String tag, String msg) {
    final e = BleLogEntry(DateTime.now().toUtc(), tag, msg);
    _history.add(e);
    while (_history.length > cap) {
      _history.removeAt(0);
    }
    try {
      _ctl.add(e);
    } catch (_) {}
    // Mirror to console so `adb logcat` (I/flutter) carries the same
    // history the on-screen terminal shows — the in-app ring is
    // autoscrolled and can't be grepped during live radio tests.
    try {
      // ignore: avoid_print
      print('[${e.tag}] ${e.msg}');
    } catch (_) {}
  }

  static void clear() => _history.clear();

  /// Short UUID helper for logs: first 8 chars of the canonical form.
  static String shortUuid(String uuid) {
    final n = uuid.replaceAll('-', '').replaceAll('{', '').replaceAll('}', '');
    return n.length <= 8 ? n : n.substring(0, 8);
  }
}
