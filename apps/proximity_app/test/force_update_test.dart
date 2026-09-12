// 1B: force-update compare / verdict units (pure, no Firebase needed).
import 'package:flutter/foundation.dart' show TargetPlatform;
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
      expect(compareVersions('1.2.3-beta', '1.2.3'), 0);
      expect(compareVersions(' 1.2.3 ', '1.2.3'), 0);
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
