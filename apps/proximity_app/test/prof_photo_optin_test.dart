// Professor photo opt-in (live setup): per-course, off by default.
//
// Contract: `DeviceStore.readShowProfPhoto` is false when absent;
// `LiveSetupSection` shows the toggle only when a sink is provided, with
// honest on/off copy. Existing call sites omit the sink and render
// exactly as before.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/design/app_theme.dart';
import 'package:proximity_app/features/live/live_setup.dart';

void main() {
  test('student photo cache defaults empty, persists per course', () async {
    final store = InMemoryDeviceStore();
    expect(await store.readCourseProfPhoto('CS201'), isEmpty);
    await store.writeCourseProfPhoto('CS201', 'https://x/photo.jpg');
    expect(await store.readCourseProfPhoto('CS201'), 'https://x/photo.jpg');
    expect(await store.readCourseProfPhoto('CS202'), isEmpty);
    // Blank writes never clobber.
    await store.writeCourseProfPhoto('CS201', '  ');
    expect(await store.readCourseProfPhoto('CS201'), 'https://x/photo.jpg');
    await store.writeCourseProfPhoto('', 'https://x/other.jpg');
    expect(await store.readCourseProfPhoto(''), isEmpty);
  });

  test('photo share defaults off, persists per course', () async {
    final store = InMemoryDeviceStore();
    expect(await store.readShowProfPhoto('CS201'), isFalse);
    await store.writeShowProfPhoto('CS201', true);
    expect(await store.readShowProfPhoto('CS201'), isTrue);
    expect(await store.readShowProfPhoto('CS202'), isFalse);
    await store.writeShowProfPhoto('CS201', false);
    expect(await store.readShowProfPhoto('CS201'), isFalse);
  });

  Future<void> pumpSetup(
    WidgetTester t, {
    bool show = false,
    ValueChanged<bool>? onChanged,
  }) async {
    final nameCtrl = TextEditingController();
    addTearDown(nameCtrl.dispose);
    await t.pumpWidget(MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(
        body: LiveSetupSection(
          hosting: true,
          live: false,
          nameCtrl: nameCtrl,
          onNameChanged: (_) {},
          serverLine: null,
          allIps: const [],
          currentIp: '',
          onPickIp: () {},
          serverError: null,
          showProfPhoto: show,
          onShowProfPhotoChanged: onChanged,
        ),
      ),
    ));
    await t.pumpAndSettle();
  }

  testWidgets('toggle hidden without a sink (legacy call sites)', (t) async {
    final nameCtrl = TextEditingController();
    addTearDown(nameCtrl.dispose);
    await t.pumpWidget(MaterialApp(
      theme: proxLightTheme(),
      home: Scaffold(
        body: LiveSetupSection(
          hosting: true,
          live: false,
          nameCtrl: nameCtrl,
          onNameChanged: (_) {},
          serverLine: null,
          allIps: const [],
          currentIp: '',
          onPickIp: () {},
          serverError: null,
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text('Show my profile photo to students'), findsNothing);
  });

  testWidgets('off state copy + tap flips on', (t) async {
    var value = false;
    await pumpSetup(t, show: value, onChanged: (v) => value = v);
    expect(find.text('Show my profile photo to students'), findsOneWidget);
    expect(find.textContaining('students see your initial'), findsOneWidget);
    await t.tap(find.text('Show my profile photo to students'));
    await t.pumpAndSettle();
    expect(value, isTrue);
  });

  testWidgets('on state copy', (t) async {
    await pumpSetup(t, show: true, onChanged: (_) {});
    expect(find.textContaining('see your Gmail photo'), findsOneWidget);
  });
}
