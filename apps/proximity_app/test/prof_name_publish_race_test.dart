// Prof-name publish ordering (PROF-NAME data path).
//
// Root cause: TakeAttendanceScreen.initState fires `_host()` and
// `_loadName()` concurrently (take_attendance.dart initState). `_host`
// publishes `_nameCtrl.text` via `setDisplayName` but skips when the field
// is still empty; the prefill (`_loadName`: linked → saved → Gmail display
// name, async) lands later. Without the late publish the announcement
// `prof` stays empty on real devices → waiting-room card shows the email
// as title + org line, browse tile shows course + email + IP.
//
// Contract pinned here: when hosting starts BEFORE the prefill lands
// (deferred saved-name read), the prefill still publishes the effective
// name once it arrives (idempotent — same-value rewrites harmless). No new
// transport fields, no new components; genuinely-unnamed hosts keep the
// existing honest fallbacks (pinned in waiting_prof_name_mobile_test +
// identity_surface_test).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/auth.dart';
import 'package:proximity_app/core/ble_radio.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/host_driver.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/screens/take_attendance.dart';
import 'package:proximity_ble/ble.dart';

/// Records every `setDisplayName` publish (FakeHostDriver itself no-ops it).
class _RecordingHostDriver extends FakeHostDriver {
  final List<String> published = [];
  @override
  Future<void> setDisplayName(String name) async {
    published.add(name);
  }
}

/// Defers ONLY the saved-name read (the prefill gate); everything else is
/// the immediate in-memory store. Hosting (FakeHostDriver) therefore starts
/// while the prefill is still in flight.
class _DeferredHostNameStore extends InMemoryDeviceStore {
  final Future<String> Function() readHostNameFn;
  _DeferredHostNameStore(this.readHostNameFn);
  @override
  Future<String> readHostName() => readHostNameFn();
}

Future<void> _pumpTake(
  WidgetTester t, {
  required InMemoryDeviceStore store,
  required FakeHostDriver host,
  required AuthService auth,
}) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        deviceStoreProvider.overrideWithValue(store),
        hostDriverProvider.overrideWithValue(host),
        authServiceProvider.overrideWithValue(auth),
        studentDriverProvider.overrideWithValue(FakeStudentDriver()),
        bleEngineProvider
            .overrideWithValue(ProxBleEngine(radio: FakeBleRadio())),
        blePermissionProvider.overrideWithValue(() async => true),
        btPowerProvider.overrideWithValue(() async => BtState.on),
      ],
      child: MaterialApp(
        theme: proxLightTheme(),
        home: const TakeAttendanceScreen(courseName: 'CS201'),
      ),
    ),
  );
}

void main() {
  testWidgets(
      'deferred prefill publishes after hosting already started', (t) async {
    // Gmail empty on purpose: the late publish must come from the deferred
    // saved name, not from the sync Gmail fallback in `_host`.
    final auth = FakeAuthService(const SignedAccount(
      email: 'prof@example.com',
      displayName: '',
      uid: 'u-prof',
    ));
    final gate = Completer<String>();
    final store = _DeferredHostNameStore(() => gate.future);
    final host = _RecordingHostDriver();

    await _pumpTake(t, store: store, host: host, auth: auth);
    // Hosting starts while the prefill is still gated: the announce field
    // is empty and the sync Gmail fallback is empty, so nothing publishes
    // yet (the skip path — never a blank publish).
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(host.isHosting, isTrue);
    expect(host.published, isEmpty);

    // Prefill lands late (saved name resolves after hosting is up).
    gate.complete('Deferred Prof');
    await t.pumpAndSettle();

    // Late publish converged: the effective name aired even though hosting
    // started first. Idempotent — every publish carries the same value.
    expect(host.published, isNotEmpty);
    expect(host.published.last, 'Deferred Prof');
    expect(host.published.toSet(), {'Deferred Prof'});
    expect(t.takeException(), isNull);
  });

  testWidgets('immediate saved name publishes on host (no race)', (t) async {
    final auth = FakeAuthService(const SignedAccount(
      email: 'prof@example.com',
      displayName: '',
      uid: 'u-prof',
    ));
    final store = InMemoryDeviceStore()..hostName = 'Saved Prof';
    final host = _RecordingHostDriver();

    await _pumpTake(t, store: store, host: host, auth: auth);
    await t.pumpAndSettle();

    expect(host.isHosting, isTrue);
    expect(host.published, isNotEmpty);
    expect(host.published.toSet(), {'Saved Prof'});
    expect(t.takeException(), isNull);
  });
}
