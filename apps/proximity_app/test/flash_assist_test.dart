// Flash assist seam contracts: fail-soft channel, fake round-trip, and
// the sync widget lifecycle (max on activate, restore on deactivate and
// on dispose; unknown previous skips restore instead of writing garbage).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/features/setup/flash_assist.dart';

void main() {
  group('ChannelScreenBrightnessControl fail-soft', () {
    test('no channel mock degrades to null / no-op, never throws', () async {
      // No TestDefaultBinaryMessenger mock: the unit-test engine has no
      // native side, so every hop raises MissingPluginException — the
      // control must degrade instead of throwing past the caller.
      const control = ChannelScreenBrightnessControl();
      expect(await control.current(), isNull);
      await control.set(1.0); // must not throw
    });

    test('provider resolves the channel impl by default', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(enrollScreenBrightnessProvider),
          isA<ChannelScreenBrightnessControl>());
    });
  });

  group('FakeScreenBrightnessControl', () {
    test('scripted current round-trips, sets recorded', () async {
      final fake = FakeScreenBrightnessControl(scriptedCurrent: 0.4);
      expect(await fake.current(), 0.4);
      await fake.set(1.0);
      await fake.set(0.4);
      expect(fake.sets, [1.0, 0.4]);
    });
  });

  group('FlashAssistSync lifecycle', () {
    Future<void> pumpSync(WidgetTester t,
        {required bool active,
        required FakeScreenBrightnessControl fake}) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: FlashAssistSync(active: active, control: fake))));
      await t.pump();
    }

    testWidgets('inactive never touches brightness', (t) async {
      final fake = FakeScreenBrightnessControl(scriptedCurrent: 0.4);
      await pumpSync(t, active: false, fake: fake);
      expect(fake.sets, isEmpty);
      expect(t.takeException(), isNull);
    });

    testWidgets('activate reads previous then sets max', (t) async {
      final fake = FakeScreenBrightnessControl(scriptedCurrent: 0.4);
      await pumpSync(t, active: false, fake: fake);
      await pumpSync(t, active: true, fake: fake);
      await t.pump();
      expect(fake.sets, [1.0]);
      expect(t.takeException(), isNull);
    });

    testWidgets('deactivate restores the previous value', (t) async {
      final fake = FakeScreenBrightnessControl(scriptedCurrent: 0.4);
      await pumpSync(t, active: true, fake: fake);
      await t.pump();
      expect(fake.sets, [1.0]);
      await pumpSync(t, active: false, fake: fake);
      await t.pump();
      expect(fake.sets, [1.0, 0.4]);
      expect(t.takeException(), isNull);
    });

    testWidgets('dispose while active restores', (t) async {
      final fake = FakeScreenBrightnessControl(scriptedCurrent: 0.4);
      await pumpSync(t, active: true, fake: fake);
      await t.pump();
      expect(fake.sets, [1.0]);
      await t.pumpWidget(const MaterialApp(home: Scaffold()));
      await t.pump();
      expect(fake.sets, [1.0, 0.4]);
      expect(t.takeException(), isNull);
    });

    testWidgets('unknown previous skips restore, never writes garbage',
        (t) async {
      final fake = FakeScreenBrightnessControl(scriptedCurrent: null);
      await pumpSync(t, active: true, fake: fake);
      await t.pump();
      expect(fake.sets, [1.0]);
      await t.pumpWidget(const MaterialApp(home: Scaffold()));
      await t.pump();
      expect(fake.sets, [1.0]);
      expect(t.takeException(), isNull);
    });
  });
}
