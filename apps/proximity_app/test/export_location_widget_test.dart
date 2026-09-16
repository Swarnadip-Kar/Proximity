// Export-location setting row: default label, pick → persist, cancel
// no-op, picker failure (incl. the iOS/unregistered-channel
// MissingPluginException that used to surface raw) → friendly note,
// reset back to the system default.
//
// Deadlock contract: the picker AND writability providers are ALWAYS
// overridden here — tests never touch a real platform channel (no host in
// widget tests, so a real FilePicker call would hang awaiting a method
// reply) and never await real `dart:io` futures (they never resolve inside
// `testWidgets`' fake-async zone — pumpAndSettle only waits for scheduled
// frames, not pending futures — so the real probe would hang the body
// forever). The real probe stays covered by the plain unit tests below.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/file_saver.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/account/account_export_location.dart';

Widget _row({
  required DeviceStore store,
  Future<String?> Function()? picker,
  Future<bool> Function(String)? writable,
}) =>
    ProviderScope(
      overrides: [
        deviceStoreProvider.overrideWithValue(store),
        if (picker != null) exportDirPickerProvider.overrideWithValue(picker),
        if (writable != null)
          exportDirWritableProvider.overrideWithValue(writable),
      ],
      child: MaterialApp(
        theme: proxLightTheme(),
        home: const Scaffold(
          body: SingleChildScrollView(child: AccountExportLocationRow()),
        ),
      ),
    );

void main() {
  testWidgets('shows the system default with no stored location', (t) async {
    await t.pumpWidget(_row(store: InMemoryDeviceStore()));
    await t.pumpAndSettle();
    expect(find.text('Downloads (system default)'), findsOneWidget);
    expect(find.byKey(const Key('export-location-reset')), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('pick persists and reset restores the default', (t) async {
    final store = InMemoryDeviceStore();
    const picked = '/exports';
    await t.pumpWidget(_row(
      store: store,
      picker: () async => picked,
      writable: (p) async => p == picked,
    ));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('export-location-row')));
    await t.pumpAndSettle();
    expect(await store.readExportDir(), picked);
    expect(find.text(picked), findsOneWidget);
    expect(find.text('Export location updated.'), findsOneWidget);
    await t.tap(find.byKey(const Key('export-location-reset')));
    await t.pumpAndSettle();
    expect(await store.readExportDir(), isNull);
    expect(find.text('Downloads (system default)'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('unwritable pick shows the error and keeps the default',
      (t) async {
    final store = InMemoryDeviceStore();
    await t.pumpWidget(_row(
      store: store,
      picker: () async => '/nope',
      writable: (_) async => false,
    ));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('export-location-row')));
    await t.pumpAndSettle();
    expect(await store.readExportDir(), isNull);
    expect(find.byKey(const Key('export-location-error')), findsOneWidget);
    expect(find.text('Downloads (system default)'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('cancelled picker is a silent no-op', (t) async {
    final store = InMemoryDeviceStore();
    await t.pumpWidget(_row(store: store, picker: () async => null));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('export-location-row')));
    await t.pumpAndSettle();
    expect(await store.readExportDir(), isNull);
    expect(find.text('Downloads (system default)'), findsOneWidget);
    expect(find.byKey(const Key('export-location-error')), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('missing plugin maps to the friendly note, not a crash',
      (t) async {
    final store = InMemoryDeviceStore();
    await t.pumpWidget(_row(store: store, picker: () async {
      throw MissingPluginException('No implementation found for method dir');
    }));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('export-location-row')));
    await t.pumpAndSettle();
    // Friendly explanation (never the raw plugin dump), default kept.
    expect(find.byKey(const Key('export-location-error')), findsOneWidget);
    expect(find.textContaining('system default'), findsWidgets);
    expect(find.textContaining('MissingPluginException'), findsNothing);
    expect(await store.readExportDir(), isNull);
    expect(t.takeException(), isNull);
  });

  test('real probe accepts a writable dir, rejects blank', () async {
    final tmp = Directory.systemTemp.createTempSync('prox-export-unit');
    try {
      expect(await isExportDirWritable(tmp.path), isTrue);
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
    expect(await isExportDirWritable('   '), isFalse);
  });
}
