// Log view filter modes: quiet (default, hides BLE/MESH) vs all.
import 'package:proximity_ble/ble.dart';
import 'package:test/test.dart';

import 'package:proximity_app/widgets/log_filter.dart';

BleLogEntry _e(String tag, String msg) =>
    BleLogEntry(DateTime.utc(2026, 10, 2, 7, 0, 0), tag, msg);

void main() {
  final entries = [
    _e('SEC', 'prove integrity abc'),
    _e('BLE', 'scan start'),
    _e('MESH', 'mesh on'),
    _e('LAN', 'presence sent'),
    _e('STATE', 'verdict error'),
  ];

  test('quiet (default) hides BLE/MESH, keeps the rest', () {
    final out = filterLogEntries(entries,
        only: const {}, mode: LogViewMode.quiet, mutedTags: BleLog.mutedTags);
    expect(out.map((e) => e.tag), ['SEC', 'LAN', 'STATE']);
  });

  test('all keeps everything, even BLE and MESH', () {
    final out = filterLogEntries(entries,
        only: const {}, mode: LogViewMode.all, mutedTags: BleLog.mutedTags);
    expect(out.map((e) => e.tag), ['SEC', 'BLE', 'MESH', 'LAN', 'STATE']);
  });

  test('explicit tag selection wins over the mode', () {
    final bleQuiet = filterLogEntries(entries,
        only: const {'BLE'},
        mode: LogViewMode.quiet,
        mutedTags: BleLog.mutedTags);
    expect(bleQuiet.map((e) => e.tag), ['BLE']);
    final secAll = filterLogEntries(entries,
        only: const {'SEC'},
        mode: LogViewMode.all,
        mutedTags: BleLog.mutedTags);
    expect(secAll.map((e) => e.tag), ['SEC']);
  });

  test('copy includes BLE/MESH even from the quiet view', () {
    final copied = copyLogEntries(entries, only: const {});
    expect(copied.map((e) => e.tag), ['SEC', 'BLE', 'MESH', 'LAN', 'STATE']);
  });

  test('copy still honors an explicit tag selection', () {
    final copied = copyLogEntries(entries, only: const {'SEC', 'LAN'});
    expect(copied.map((e) => e.tag), ['SEC', 'LAN']);
  });
}
