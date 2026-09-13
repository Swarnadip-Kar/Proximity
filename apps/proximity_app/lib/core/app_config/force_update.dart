// Force-update gate (PROXIMITY_SECURITY.md §6, F6).
//
// Reads Firestore `app_config/min_version`
// `{minVersion, latest, force, msg, storeAndroid, storeIos}` (collection
// `app_config`, doc id `min_version`; rules owned outside 1B) and compares it
// against the running build via `package_info_plus`.
//
// Integration (owned outside 1B — entry/host/enroll call this, never the
// reverse):
//   final result = await ForceUpdate.checkNow();
//   if (result.updateRequired && context.mounted) {
//     await ForceUpdate.showBarrier(context, result);
//   }
// Bump the remote doc on any ticket/rules/verifier break; stale builds with
// `force: true` get a non-dismissible barrier instead of cryptic
// `bad-sig`/`face-unbound` failures (no silent downgrades, no pinned-APK
// bypass at online gates).
//
// Offline posture: a missing doc or transport failure yields
// `checked: false, updateRequired: false` — marking stays offline-capable.
// Once the barrier is up (verified-stale), only a verified-fresh recheck
// takes it down (fail-closed).
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Remote doc model: `app_config/min_version`.
class ForceUpdateConfig {
  /// Minimum running version; `force: true` + current below this blocks.
  final String minVersion;

  /// Newest release (informational only — never a gate).
  final String latest;

  /// When true, builds below [minVersion] are blocked by the barrier.
  final bool force;

  /// Barrier copy from the server (`msg`; `message` accepted as alias).
  final String message;

  /// Store deep-links shown on the barrier (copyable text; no url_launcher
  /// dep — 1B adds no deps beyond flutter_secure_storage/package_info_plus).
  final String storeAndroid;
  final String storeIos;

  const ForceUpdateConfig({
    required this.minVersion,
    this.latest = '',
    this.force = false,
    this.message = '',
    this.storeAndroid = '',
    this.storeIos = '',
  });

  /// Lenient parse: missing keys default to no-block; `force` accepts bool
  /// (server contract) or non-zero num.
  factory ForceUpdateConfig.fromMap(Map<String, dynamic> map) {
    final forceRaw = map['force'];
    return ForceUpdateConfig(
      minVersion: '${map['minVersion'] ?? ''}'.trim(),
      latest: '${map['latest'] ?? ''}'.trim(),
      force: forceRaw is bool
          ? forceRaw
          : forceRaw is num
              ? forceRaw != 0
              : false,
      message: ('${map['msg'] ?? map['message'] ?? ''}').trim(),
      storeAndroid: '${map['storeAndroid'] ?? ''}'.trim(),
      storeIos: '${map['storeIos'] ?? ''}'.trim(),
    );
  }
}

/// Pure dotted-version compare: negative / zero / positive.
///
/// Strips build metadata (`+…`) and pre-release (`-…`); non-numeric segments
/// count as 0; missing segments count as 0 (`'1.2' == '1.2.0'`, and numeric
/// — never lexicographic — so `'1.10.0' > '1.9.9'`).
int compareVersions(String a, String b) {
  List<int> parse(String v) {
    var s = v.trim();
    final plus = s.indexOf('+');
    if (plus >= 0) s = s.substring(0, plus);
    final dash = s.indexOf('-');
    if (dash >= 0) s = s.substring(0, dash);
    if (s.isEmpty) return <int>[0];
    return s.split('.').map((p) => int.tryParse(p.trim()) ?? 0).toList();
  }

  final pa = parse(a);
  final pb = parse(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

/// Outcome of [ForceUpdate.check]/[ForceUpdate.checkNow].
class ForceUpdateResult {
  /// False when the remote floor could not be verified (offline, missing
  /// doc, version lookup failed). Never blocks — callers re-check at the
  /// next online gate.
  final bool checked;

  /// True only for verified-stale with `force: true`. Show the barrier.
  final bool updateRequired;

  /// Running `PackageInfo.version` (`''` when unreadable).
  final String currentVersion;

  /// Remote floor that produced this verdict (null when unverified).
  final ForceUpdateConfig? config;

  const ForceUpdateResult({
    required this.checked,
    required this.updateRequired,
    required this.currentVersion,
    this.config,
  });
}

/// Public API for 1B force-update (handoff: callers depend on
/// [ForceUpdate.check]/[ForceUpdate.checkNow]/[ForceUpdate.showBarrier]).
class ForceUpdate {
  ForceUpdate._();

  /// Firestore collection / doc id of the version floor.
  static const configCollection = 'app_config';
  static const configDoc = 'min_version';

  /// H6 last-known floor cache (Spark-free, in-memory): the last verified
  /// floor + fetch time. Updated on every verified [checkNow]; enforced
  /// offline by [checkNow]/[checkCached] so a pinned old build cannot dodge
  /// the floor by staying offline after seeing it once. Structure only
  /// (version strings + timestamps) — no sealed bytes involved.
  static ForceUpdateConfig? _lastFloor;
  static DateTime? _lastFetchedAt;

  /// Last verified floor (null until the first verified read).
  static ForceUpdateConfig? get lastKnownFloor => _lastFloor;

  /// Fetch time of [lastKnownFloor] (null until the first verified read).
  static DateTime? get lastFetchedAt => _lastFloor == null
      ? null
      : (_lastFetchedAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));

  /// Test seam: seed/clear the last-known floor cache.
  static void debugSeedFloorForTest(ForceUpdateConfig? config,
      {DateTime? fetchedAt}) {
    _lastFloor = config;
    _lastFetchedAt = config == null
        ? null
        : (fetchedAt ?? DateTime.now()).toUtc();
  }

  /// Offline verdict against the cached floor: verified-stale + force
  /// blocks even without a fresh read (fail-closed); anything else passes
  /// unchecked (never blocks without a floor). Pure — the offline path of
  /// [checkNow] delegates here on transport failure.
  static ForceUpdateResult checkCached({required String currentVersion}) {
    final floor = _lastFloor;
    final current = currentVersion.trim();
    if (floor == null || floor.minVersion.isEmpty || !floor.force) {
      return ForceUpdateResult(
        checked: false,
        updateRequired: false,
        currentVersion: current,
        config: floor,
      );
    }
    final stale =
        current.isEmpty || compareVersions(current, floor.minVersion) < 0;
    // Cached-floor verdicts are checked:true when they block (a known floor
    // was enforced) and checked:false when they pass (no fresh verification
    // — callers re-check at the next online gate).
    return ForceUpdateResult(
      checked: stale,
      updateRequired: stale,
      currentVersion: current,
      config: floor,
    );
  }

  /// Pure verdict — unit-testable, platform-independent.
  ///
  /// Fail-closed: an empty [currentVersion] with `force: true` counts as
  /// stale (never trust an unknown build against a mandated floor). A null
  /// config or empty floor never blocks.
  static ForceUpdateResult check({
    required String currentVersion,
    required ForceUpdateConfig? config,
  }) {
    final current = currentVersion.trim();
    if (config == null || config.minVersion.isEmpty || !config.force) {
      return ForceUpdateResult(
        checked: true,
        updateRequired: false,
        currentVersion: current,
        config: config,
      );
    }
    final stale =
        current.isEmpty || compareVersions(current, config.minVersion) < 0;
    return ForceUpdateResult(
      checked: true,
      updateRequired: stale,
      currentVersion: current,
      config: config,
    );
  }

  /// Live verdict: Firestore floor vs running build.
  ///
  /// Injectable for tests (`firestore`, `packageInfoLoader`); production
  /// uses `FirebaseFirestore.instance` + `PackageInfo.fromPlatform()`.
  /// Transport/parse failures yield `checked: false` (never throws for
  /// those — marking stays offline-capable).
  static Future<ForceUpdateResult> checkNow({
    FirebaseFirestore? firestore,
    Future<PackageInfo> Function()? packageInfoLoader,
  }) async {
    late final String current;
    try {
      final info = packageInfoLoader != null
          ? await packageInfoLoader()
          : await PackageInfo.fromPlatform();
      current = info.version;
    } catch (_) {
      return const ForceUpdateResult(
        checked: false,
        updateRequired: false,
        currentVersion: '',
      );
    }
    try {
      final store = firestore ?? FirebaseFirestore.instance;
      final snap =
          await store.collection(configCollection).doc(configDoc).get();
      final data = snap.data();
      if (data == null) {
        // Missing doc: fall back to the cached floor (H6 offline
        // enforcement) instead of blind pass — a pinned build that saw the
        // floor once cannot clear it by deleting the doc offline.
        final cached = checkCached(currentVersion: current);
        if (cached.updateRequired) return cached;
        return ForceUpdateResult(
          checked: false,
          updateRequired: false,
          currentVersion: current,
        );
      }
      final result = check(
        currentVersion: current,
        config: ForceUpdateConfig.fromMap(data),
      );
      // Cache every verified read (floor or no-floor) with its fetch time.
      _lastFloor = result.config;
      _lastFetchedAt = DateTime.now().toUtc();
      return result;
    } catch (_) {
      // Transport failure: enforce the cached floor when it blocks (H6),
      // else unchecked (marking stays offline-capable on first-ever run).
      final cached = checkCached(currentVersion: current);
      if (cached.updateRequired) return cached;
      return ForceUpdateResult(
        checked: false,
        updateRequired: false,
        currentVersion: current,
      );
    }
  }

  /// Store link for the barrier on [platform] (`''` where no store exists —
  /// desktop/web still block, with copy + recheck only).
  static String storeUrlFor(ForceUpdateConfig config, TargetPlatform platform) {
    switch (platform) {
      case TargetPlatform.android:
        return config.storeAndroid;
      case TargetPlatform.iOS:
        return config.storeIos;
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return '';
    }
  }

  /// Non-dismissible barrier: `barrierDismissible: false` + `PopScope(canPop:
  /// false)`, so back/gesture/outside-tap can never clear it. Completes only
  /// via Recheck after a verified-fresh read; a verified-stale or unverified
  /// recheck keeps the barrier up (fail-closed).
  static Future<void> showBarrier(
    BuildContext context,
    ForceUpdateResult result,
  ) async {
    final config = result.config;
    final message = (config != null && config.message.isNotEmpty)
        ? config.message
        : 'This version of Proximity is too old to mark attendance safely. '
            'Update to continue.';
    final url = config == null
        ? ''
        : storeUrlFor(config, defaultTargetPlatform);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Update required'),
          content: SingleChildScrollView(
            child: ListBody(
              children: [
                Text(message),
                const SizedBox(height: 8),
                Text(
                  'Installed: ${result.currentVersion.isEmpty ? 'unknown' : result.currentVersion}'
                  '${config == null ? '' : ' • Required: ${config.minVersion}'}',
                ),
                if (url.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SelectableText(url),
                ],
              ],
            ),
          ),
          actions: [
            if (url.isNotEmpty)
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: url));
                  if (ctx.mounted) {
                    ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
                      const SnackBar(
                        content: Text('Store link copied'),
                      ),
                    );
                  }
                },
                child: const Text('Copy store link'),
              ),
            FilledButton(
              onPressed: () async {
                // Bounded like every other floor read (entry gates + main
                // barrier): a hung version lookup must degrade to the
                // "still out of date" snackbar, never a dead Recheck.
                ForceUpdateResult fresh;
                try {
                  fresh = await checkNow()
                      .timeout(const Duration(seconds: 10));
                } catch (_) {
                  fresh = const ForceUpdateResult(
                    checked: false,
                    updateRequired: false,
                    currentVersion: '',
                  );
                }
                if (fresh.checked && !fresh.updateRequired && ctx.mounted) {
                  Navigator.of(ctx).pop();
                } else if (ctx.mounted) {
                  ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Still out of date — connect to the internet and update to continue.',
                      ),
                    ),
                  );
                }
              },
              child: const Text('Recheck'),
            ),
          ],
        ),
      ),
    );
  }
}
