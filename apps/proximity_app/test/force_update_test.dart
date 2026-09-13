// 1B: force-update compare / verdict units (pure, no Firebase needed).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:proximity_app/core/app_config/force_update.dart';

ForceUpdateConfig floor({
  String minVersion = '0.2.0',
  bool force = true,
  String message = 'Please update',
  String storeAndroid = 'https://play.example/prox',
  String storeIos = 'https://apps.example/prox',
}) =>
    ForceUpdateConfig(
      minVersion: minVersion,
      latest: '0.3.0',
      force: force,
      message: message,
      storeAndroid: storeAndroid,
      storeIos: storeIos,
    );

void main() {
  group('compareVersions', () {
    test('equal, build metadata, and segment-length forms', () {
      expect(compareVersions('0.1.0', '0.1.0'), 0);
      expect(compareVersions('0.1.0+1', '0.1.0'), 0);
      expect(compareVersions('1.2', '1.2.0'), 0);
      expect(compareVersions(' 1.2.3 ', '1.2.3'), 0);
    });

    test('pre-release sorts below the same core (never satisfies a floor)',
        () {
      expect(compareVersions('1.2.3-beta', '1.2.3'), lessThan(0));
      expect(compareVersions('0.2.0-malicious', '0.2.0'), lessThan(0));
      expect(compareVersions('1.2.3-beta', '1.2.3-alpha'), 0);
      expect(compareVersions('1.2.3', '1.2.3-beta'), greaterThan(0));
      final blocked = ForceUpdate.check(
        currentVersion: '0.2.0-beta',
        config: floor(minVersion: '0.2.0'),
      );
      expect(blocked.updateRequired, isTrue);
    });

    test('numeric (not lexicographic) ordering', () {
      expect(compareVersions('0.1.0', '0.2.0'), lessThan(0));
      expect(compareVersions('1.9.9', '1.10.0'), lessThan(0));
      expect(compareVersions('0.2.0', '0.1.9'), greaterThan(0));
      expect(compareVersions('2.0', '1.99.99'), greaterThan(0));
      expect(compareVersions('0.1.0', '0.1.0'), 0);
    });
  });

  group('ForceUpdate.check', () {
    test('stale + force blocks; fresh and equal pass', () {
      final stale = ForceUpdate.check(
        currentVersion: '0.1.0',
        config: floor(minVersion: '0.2.0'),
      );
      expect(stale.checked, isTrue);
      expect(stale.updateRequired, isTrue);

      final fresh = ForceUpdate.check(
        currentVersion: '0.3.0',
        config: floor(minVersion: '0.2.0'),
      );
      expect(fresh.updateRequired, isFalse);

      final equal = ForceUpdate.check(
        currentVersion: '0.2.0+5',
        config: floor(minVersion: '0.2.0'),
      );
      expect(equal.updateRequired, isFalse);
    });

    test('soft floor (force false) never blocks', () {
      final result = ForceUpdate.check(
        currentVersion: '0.1.0',
        config: floor(minVersion: '9.9.9', force: false),
      );
      expect(result.checked, isTrue);
      expect(result.updateRequired, isFalse);
    });

    test('missing config or empty floor never blocks', () {
      expect(
        ForceUpdate.check(currentVersion: '0.0.1', config: null).updateRequired,
        isFalse,
      );
      expect(
        ForceUpdate.check(
          currentVersion: '0.0.1',
          config: floor(minVersion: ''),
        ).updateRequired,
        isFalse,
      );
    });

    test('unknown current build with force is fail-closed (blocks)', () {
      final result = ForceUpdate.check(
        currentVersion: '',
        config: floor(minVersion: '0.2.0'),
      );
      expect(result.updateRequired, isTrue);
    });
  });

  group('ForceUpdateConfig.fromMap', () {
    test('parses the server doc contract (msg key)', () {
      final config = ForceUpdateConfig.fromMap({
        'minVersion': '0.2.0',
        'latest': '0.3.0',
        'force': true,
        'msg': 'Time to update',
        'storeAndroid': 'https://play.example/prox',
        'storeIos': 'https://apps.example/prox',
      });
      expect(config.minVersion, '0.2.0');
      expect(config.latest, '0.3.0');
      expect(config.force, isTrue);
      expect(config.message, 'Time to update');
      expect(config.storeAndroid, 'https://play.example/prox');
      expect(config.storeIos, 'https://apps.example/prox');
    });

    test('missing keys default to no-block', () {
      final config = ForceUpdateConfig.fromMap({});
      expect(config.minVersion, isEmpty);
      expect(config.force, isFalse);
      final result =
          ForceUpdate.check(currentVersion: '0.0.1', config: config);
      expect(result.updateRequired, isFalse);
    });

    test('force accepts bool, num, and common string forms', () {
      expect(ForceUpdateConfig.fromMap({'force': true}).force, isTrue);
      expect(ForceUpdateConfig.fromMap({'force': 1}).force, isTrue);
      expect(ForceUpdateConfig.fromMap({'force': 0}).force, isFalse);
      expect(ForceUpdateConfig.fromMap({'force': 'true'}).force, isTrue);
      expect(ForceUpdateConfig.fromMap({'force': ' True '}).force, isTrue);
      expect(ForceUpdateConfig.fromMap({'force': '1'}).force, isTrue);
      expect(ForceUpdateConfig.fromMap({'force': 'yes'}).force, isTrue);
      expect(ForceUpdateConfig.fromMap({'force': 'treu'}).force, isFalse);
    });
  });

  group('storeUrlFor', () {
    test('maps platform to the matching store link', () {
      final config = floor();
      expect(
        ForceUpdate.storeUrlFor(config, TargetPlatform.android),
        'https://play.example/prox',
      );
      expect(
        ForceUpdate.storeUrlFor(config, TargetPlatform.iOS),
        'https://apps.example/prox',
      );
      expect(ForceUpdate.storeUrlFor(config, TargetPlatform.windows), isEmpty);
      expect(ForceUpdate.storeUrlFor(config, TargetPlatform.macOS), isEmpty);
    });
  });

  group('ForceUpdate.showBarrier (verified-stale only)', () {
    testWidgets(
        'stale barrier is non-dismissible; offline Recheck keeps it up (fail-closed)',
        (tester) async {
      final stale = ForceUpdate.check(
        currentVersion: '0.1.0',
        config: floor(minVersion: '0.2.0'),
      );
      expect(stale.updateRequired, isTrue);
      // Offline Recheck path: the version lookup throws (no plugin in
      // widget tests — same as an unreadable build on device), so the
      // real checkNow inside Recheck degrades to unchecked. Mocked to
      // throw rather than pend on the unhandled channel.
      const pkgChannel =
          MethodChannel('dev.fluttercommunity.plus/package_info');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              pkgChannel, (call) async => throw PlatformException(code: 'x'));
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pkgChannel, null);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () => ForceUpdate.showBarrier(ctx, stale),
                child: const Text('show'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      expect(find.text('Update required'), findsOneWidget);
      expect(find.textContaining('Required: 0.2.0'), findsOneWidget);
      // Outside-tap cannot dismiss (barrierDismissible: false).
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('Update required'), findsOneWidget);
      // Back/gesture pop cannot dismiss (PopScope canPop: false).
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Update required'), findsOneWidget);
      // Recheck with no network/plugins: the real checkNow degrades to
      // unchecked, which keeps the barrier up (only a verified-fresh
      // recheck lifts it) with an explanatory snackbar.
      await tester.tap(find.text('Recheck'));
      await tester.pumpAndSettle();
      expect(find.text('Update required'), findsOneWidget);
      expect(find.textContaining('Still out of date'), findsOneWidget);
    });
  });

  group('ForceUpdate.checkNow', () {
    test('loader failure is unchecked, never blocking', () async {
      final result = await ForceUpdate.checkNow(
        packageInfoLoader: () => throw StateError('no platform'),
      );
      expect(result.checked, isFalse);
      expect(result.updateRequired, isFalse);
    });

    test('unreadable floor is unchecked, never blocking', () async {
      // No Firestore in unit tests: FirebaseFirestore.instance throws, which
      // checkNow converts to unchecked (offline-safe marking).
      final result = await ForceUpdate.checkNow(
        packageInfoLoader: () async => PackageInfo(
          appName: 'Proximity',
          packageName: 'dev.proximity.app',
          version: '0.1.0',
          buildNumber: '1',
        ),
      );
      expect(result.checked, isFalse);
      expect(result.updateRequired, isFalse);
      expect(result.currentVersion, '0.1.0');
    });
  });
}
