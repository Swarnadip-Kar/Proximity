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
/// from [history]. The cap covers a full lecture + debug session;
/// views render a window, never the whole ring.
///
/// Release console echo (field debugging without restructuring):
///   flutter run --release --dart-define=PROX_LOG_CONSOLE=true
///   flutter build apk --release --dart-define=PROX_LOG_CONSOLE=true
/// `true` forces the `print` mirror on even on user builds; `false`
/// forces it off; unset keeps the safe default (on in debug/test, off
/// in release). Release echo carries PII/scores into logcat — pilot and
/// personal debug builds only, never store builds.
class BleLog {
  static const int cap = 50000;

  /// Tags muted BY DEFAULT in the views (radio chatter — stored,
  /// greppable and copyable, just not shown until the reader taps the
  /// chip). Muting is view-only: nothing is dropped from the ring.
  static const Set<String> mutedTags = {'BLE', 'MESH'};

  static final List<BleLogEntry> _history = [];
  static final StreamController<BleLogEntry> _ctl =
      StreamController<BleLogEntry>.broadcast();

  static List<BleLogEntry> get history => List.unmodifiable(_history);
  static Stream<BleLogEntry> get stream => _ctl.stream;

  /// Console mirror switch (audit LOW: PII/scores in logcat): `true` in
  /// debug/test so `adb logcat` carries the same history the on-screen
  /// terminal shows (the in-app ring is autoscrolled and can't be grepped
  /// during live radio tests); `false` in release (`dart.vm.product`), so
  /// emails/scores/verdicts stay in the in-memory ring + on-screen
  /// terminal and never reach logcat on user builds. Tests flip this to
  /// pin both branches (zone-intercepted `print`).
  ///
  /// Compile-time override `--dart-define=PROX_LOG_CONSOLE=true|false`
  /// (see [consoleEchoFor]): forces the mirror on/off regardless of the
  /// build mode, so release builds can stream logs to the terminal while
  /// debugging without restructuring. Unset = the safe default above.
  static bool echoToConsole = consoleEchoFor(
    flag: const String.fromEnvironment('PROX_LOG_CONSOLE', defaultValue: ''),
    productBuild: bool.fromEnvironment('dart.vm.product'),
  );

  static void log(String tag, String msg) {
    final e = BleLogEntry(DateTime.now().toUtc(), tag, msg);
    _history.add(e);
    // O(1) amortized eviction: drop in batches instead of memmoving one
    // entry per log (old `removeAt(0)` shifted 500 entries per packet —
    // dominant cost during BLE bursts on low-end phones).
    if (_history.length > cap) {
      final overflow = _history.length - cap;
      _history.removeRange(0, overflow);
    }
    try {
      _ctl.add(e);
    } catch (_) {}
    if (!echoToConsole) return;
    try {
      // ignore: avoid_print
      print('[${e.tag}] ${e.msg}');
    } catch (_) {}
  }

  static void clear() => _history.clear();

  /// Resolves the console mirror for a build: an explicit
  /// `--dart-define=PROX_LOG_CONSOLE=true|false` (also `1/0`, `yes/no`,
  /// `on/off`) always wins; otherwise debug/test echoes and release
  /// (`dart.vm.product`) stays silent. Pure so tests pin the table.
  static bool consoleEchoFor({required String flag, required bool productBuild}) {
    switch (flag.trim().toLowerCase()) {
      case '1':
      case 'true':
      case 'yes':
      case 'on':
        return true;
      case '0':
      case 'false':
      case 'no':
      case 'off':
        return false;
      default:
        return !productBuild;
    }
  }

  /// Short UUID helper for logs: first 8 chars of the canonical form.
  static String shortUuid(String uuid) {
    final n = uuid.replaceAll('-', '').replaceAll('{', '').replaceAll('}', '');
    return n.length <= 8 ? n : n.substring(0, 8);
  }
}
