// Professor "Export location" setting (Account → Exports section).
//
// Stock components only (ProxListTile + ProxErrorNote + SnackBar — the
// same feedback idiom as the CSV save path): shows the stored default or
// 'Downloads (system default)', tap opens a directory picker, persists
// per device via the DeviceStore. Validation rejects empty/unwritable
// picks with the inline error note; picker cancellation is a no-op.
// Web records builds have no filesystem picker (the browser owns the
// download location) — the row explains that and saves keep working.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/device_store.dart';
import '../../core/export_location.dart';
import '../../core/file_saver.dart';
import '../../design/tokens.dart';
import '../../widgets/prox_cards.dart';
import '../../widgets/prox_states.dart';

/// Thrown when the platform cannot present a folder picker at all (never
/// a user cancel — cancels resolve to null). The row maps this to the
/// friendly "system default" note instead of a raw plugin dump.
class ExportPickerUnavailable implements Exception {
  const ExportPickerUnavailable(this.message);
  final String message;
  @override
  String toString() => 'ExportPickerUnavailable: $message';
}

/// Unified cross-platform folder pick (single call site for every target):
/// - Web: no filesystem picker exists (browser owns downloads) → null.
/// - Android: SAF folder tree needs no manifest permission — the dialog
///   just opens.
/// - macOS/Windows/Linux: native dialog via file_picker (macOS needs the
///   user-selected read-write entitlement — see Runner entitlements).
/// - iOS: no folder picker exists (native side deliberately unimplemented)
///   → [ExportPickerUnavailable], never a raw [MissingPluginException].
/// A missing/unregistered plugin channel on any target maps to the same
/// typed unavailable error, so the UI can always explain instead of hang.
Future<String?> pickExportDirectory() async {
  if (kIsWeb) return null;
  try {
    return await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose export folder',
    );
  } on MissingPluginException {
    throw const ExportPickerUnavailable(
        'Folder picking isn\u2019t available on this device.');
  } on UnimplementedError {
    throw const ExportPickerUnavailable(
        'Folder picking isn\u2019t available on this device.');
  }
}

/// Injectable directory picker (default: [pickExportDirectory] above).
/// Overridden in widget tests with a fake path / cancel / throw — tests
/// never touch a real platform channel (which would hang with no host).
final exportDirPickerProvider = Provider<Future<String?> Function()>(
    (ref) => pickExportDirectory);

/// Injectable writability probe (default: the real filesystem check).
/// Overridden in widget tests: real `dart:io` futures never resolve
/// inside `testWidgets`' fake-async zone, so awaiting the real probe
/// there hangs the test body forever with pumpAndSettle unable to help
/// (it waits for scheduled frames, not pending futures). The real
/// implementation stays covered by plain (non-widget) unit tests.
final exportDirWritableProvider = Provider<Future<bool> Function(String)>(
    (ref) => isExportDirWritable);

/// Export-location setting row for the professor Account section.
class AccountExportLocationRow extends ConsumerStatefulWidget {
  const AccountExportLocationRow({super.key});

  @override
  ConsumerState<AccountExportLocationRow> createState() =>
      _AccountExportLocationRowState();
}

class _AccountExportLocationRowState
    extends ConsumerState<AccountExportLocationRow> {
  String? _dir;
  var _loaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final dir = await ref.read(deviceStoreProvider).readExportDir();
      if (!mounted) return;
      setState(() {
        _dir = normalizeExportDir(dir);
        _loaded = true;
      });
    } catch (_) {
      // Unreadable store: stay on the system default, never block Account.
      if (!mounted) return;
      setState(() => _loaded = true);
    }
  }

  void _note(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pick() async {
    if (kIsWeb) {
      // Browser records build: no filesystem picker exists — the browser
      // owns the download location and saves keep working as today.
      setState(() => _error =
          'Your browser manages download locations — exports download as usual.');
      return;
    }
    String? picked;
    try {
      picked = await ref.read(exportDirPickerProvider)();
    } on ExportPickerUnavailable catch (e) {
      // No picker on this target (iOS, unregistered channel): exports
      // keep using the system default — explain, don't dump the plugin.
      if (!mounted) return;
      setState(() => _error = '${e.message} Exports use the system default.');
      return;
    } on MissingPluginException {
      // Same unavailability surfacing through an injected picker impl.
      if (!mounted) return;
      setState(() => _error =
          'Folder picking isn\u2019t available on this device. Exports use the system default.');
      return;
    } on UnimplementedError {
      if (!mounted) return;
      setState(() => _error =
          'Folder picking isn\u2019t available on this device. Exports use the system default.');
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not open the folder picker: $e');
      return;
    }
    if (picked == null) return; // Cancelled — not an error.
    final clean = normalizeExportDir(picked);
    if (clean == null) {
      if (!mounted) return;
      setState(
          () => _error = 'That folder name was empty — pick a folder.');
      return;
    }
    var writable = false;
    try {
      writable = await ref.read(exportDirWritableProvider)(clean);
    } catch (_) {
      writable = false;
    }
    if (!writable) {
      if (!mounted) return;
      setState(() =>
          _error = 'That folder isn\u2019t writable — pick another folder.');
      return;
    }
    try {
      await ref.read(deviceStoreProvider).writeExportDir(clean);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not save the export location: $e');
      return;
    }
    if (!mounted) return;
    setState(() {
      _dir = clean;
      _error = null;
    });
    _note('Export location updated.');
  }

  Future<void> _reset() async {
    try {
      await ref.read(deviceStoreProvider).clearExportDir();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not reset the export location: $e');
      return;
    }
    if (!mounted) return;
    setState(() {
      _dir = null;
      _error = null;
    });
    _note('Export location reset to the system default.');
  }

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Export location',
          style: ProxType.label(color: c.contentSecondary),
        ),
        const SizedBox(height: ProxSpacing.sm),
        ProxListTile(
          key: const Key('export-location-row'),
          title: 'Export location',
          subtitle:
              _loaded ? exportDirDisplayName(_dir) : 'Loading…',
          leading: const Icon(Icons.folder_outlined),
          trailing: const Icon(Icons.chevron_right),
          onTap: _pick,
        ),
        if (_error != null) ...[
          const SizedBox(height: ProxSpacing.sm),
          ProxErrorNote(
            _error!,
            key: const Key('export-location-error'),
          ),
        ],
        if (_dir != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const Key('export-location-reset'),
              onPressed: _reset,
              child: const Text('Reset to system default'),
            ),
          ),
      ],
    );
  }
}
