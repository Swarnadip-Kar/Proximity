// Shared log-view filter modes (drawer + full-screen terminal).
//
// Modes:
// - [LogViewMode.quiet] (DEFAULT): shows all tags EXCEPT radio chatter
//   ([BleLog.mutedTags] = BLE, MESH). Stored, greppable and copyable —
//   just not rendered until the reader asks.
// - [LogViewMode.all]: shows everything, radio chatter included.
//
// An explicit tag selection always wins over the mode: tapping the BLE
// chip shows exactly BLE in either mode. Copy ([copyLogEntries]) always
// includes the muted tags (tag selection only) so field reports carry
// the radio lines even when the view hides them.
//
// Pure Dart (no widgets) so unit tests pin the contract without pumping.
library;

import 'package:proximity_ble/ble.dart';

/// Log view density.
enum LogViewMode {
  /// Default: all tags except BLE/MESH radio chatter.
  quiet,

  /// Everything, including BLE/MESH.
  all,
}

/// View filter over [entries]: narrows by [only] when non-empty, else
/// applies [mode] (quiet drops [mutedTags], all keeps everything).
List<BleLogEntry> filterLogEntries(
  List<BleLogEntry> entries, {
  required Set<String> only,
  required LogViewMode mode,
  required Set<String> mutedTags,
}) {
  final List<BleLogEntry> base = only.isEmpty
      ? entries
      : entries.where((e) => only.contains(e.tag)).toList();
  if (only.isEmpty && mode == LogViewMode.quiet) {
    return base.where((e) => !mutedTags.contains(e.tag)).toList();
  }
  return base;
}

/// Copy buffer over [entries]: tag selection only — the mode mute never
/// applies, so Copy always carries BLE/MESH (even from the quiet view).
List<BleLogEntry> copyLogEntries(
  List<BleLogEntry> entries, {
  required Set<String> only,
}) =>
    only.isEmpty
        ? List<BleLogEntry>.of(entries)
        : entries.where((e) => only.contains(e.tag)).toList();
