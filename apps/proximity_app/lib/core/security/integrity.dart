// Root/tamper + integrity gate (PROXIMITY_SECURITY.md §5, F5; schedule 2C).
//
// Public API for 2C (handoff: callers depend on this file, never on
// internals):
//   IntegrityGate.performCheck()                 — startup snapshot
//   IntegrityGate.verifyBeforeSensitiveOp(op)    — enroll/host/prove
//   IntegrityGate.lastVerdict                    — cached startup verdict
//   IntegrityGate.enrollBlockReason(verdict)     — '' when enroll may proceed
//   IntegrityGate.markingFlag(verdict)           — '' | 'integrity-flagged'
//   IntegrityAppCheck.ensureActivated()          — App Check wiring stub
//
// Signal contract — IntegrityVerdict{rooted,hooked,tampered,emulator,debug,
// hash} — mirrors §5 exactly:
//   rooted   — privileged OS (RootBeer/su + IOSSecuritySuite jailbreak)
//   hooked   — live-hook runtime (Frida port/maps, Xposed modules)
//   tampered — package/signature tamper (SHA-256 mismatch, re-sign)
//   emulator — emulator/simulator (never enrolls as a real device)
//   debug    — debugger attached / debuggable build (observed, never a
//              hard block on its own — dev builds must still enroll)
//   hash     — verdictHash: first 8 hex of SHA256("v1|r|h|t|e|d"), bound
//              into dSig by the prove path (sec-sync/sec-hwkey owners) so
//              the professor can flag `integrity-flagged` offline.
//
// Enforcement law (§5):
//   enroll hard-blocks privileged/hooked/tampered/emulator (reason string,
//     never silent). Debug alone never blocks enroll.
//   marking NEVER blocks offline: the verdict hash rides inside dSig; the
//     professor flags `integrity-flagged` (never auto-absent offline).
//     Spark-free: no Functions, no TTL, no extra quota.
//
// Native backends (deps landed — pubspec owned outside this file, do NOT
// edit it here):
//     firebase_app_check: ^0.3.2+10 (exact 0.3.x enum API — see
//       [IntegrityAppCheck]; do NOT assume 0.4.x provider classes)
//     flutter_security_suite: ^1.1.1 ([SecureBankKit.runSecurityCheck] →
//       [SecurityStatus]; the per-signal mapping lives on
//       [PlatformIntegrityProbe])
// Signal mapping (flutter_security_suite 1.1.1):
//     rooted   → SecurityStatus.isRooted (RootBeer/su + jailbreak reads)
//     hooked   → SecurityStatus.isRuntimeHooked (Frida/Xposed/
//                instrumentation + attached debugger per the
//                runtime-protection contract)
//     tampered → SecurityStatus.isTampered (+ `!isAppIntegrityValid` on
//                non-debug builds ONLY — the suite folds FLAG_DEBUGGABLE +
//                installer allowlist into that bit, so it reads false on
//                every dev/debug and sideloaded build; gating it raw would
//                hard-block all dev enrollment, see [PlatformIntegrityProbe])
//     emulator → SecurityStatus.isEmulator
//     debug    → kDebugMode (pure Dart observed — the suite exposes no
//                separate debugger bit; debug alone never blocks enroll)
// Contract unchanged: fail-OPEN probe (unknown ⇒ clean, so a missing or
// hung plugin can never brick offline marking) + fail-CLOSED gate
// (tainted verdicts hard-block enroll, flag marking).
library;

import 'dart:async';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kDebugMode, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_security_suite/flutter_security_suite.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_protocol/protocol.dart';

/// Sensitive operation under test. Startup uses [startup]; every other
/// caller passes its own op so logs stay attributable.
enum IntegrityOp { startup, enroll, host, prove }

/// Raw per-signal snapshot from a probe. All false = clean device.
class IntegritySignals {
  final bool rooted;
  final bool hooked;
  final bool tampered;
  final bool emulator;
  final bool debug;
  const IntegritySignals({
    this.rooted = false,
    this.hooked = false,
    this.tampered = false,
    this.emulator = false,
    this.debug = false,
  });
}

/// Probe contract: one fresh native read per call. Production plugs the
/// `flutter_security_suite` reads here (see file doc); tests inject fakes.
abstract class IntegrityProbe {
  Future<IntegritySignals> check();
}

/// Production probe: one fresh [SecureBankKit.runSecurityCheck] per call,
/// mapped onto the §5 signals (see file doc). Records-only builds
/// (desktop/web — never enroll, never prove) skip the native plugin and
/// report only the honest Dart signal, so a missing plugin can neither
/// taint nor brick them. An absent/hung channel degrades to the same
/// debug-only signals — fail-OPEN probe, fail-CLOSED gate (see
/// [IntegrityGate]): unknown ⇒ clean, so offline marking is never broken
/// by the plugin; tainted ⇒ enroll hard-blocks and marking flags.
/// A PRESENT plugin's root/tamper/integrity errors stay fail-SECURE (the
/// suite's own contract: an unverifiable root/tamper/integrity read taints
/// rather than clears — `?? true` / `?? false`-invalid); runtime/emulator
/// reads fail OPEN per signal (`?? false`). A wholly absent channel fails
/// open (see the ping).
class PlatformIntegrityProbe implements IntegrityProbe {
  const PlatformIntegrityProbe();

  /// Native read budget: a hung channel must never stall startup or a
  /// sensitive op — past this the probe degrades to debug-only (clean).
  static const probeBudget = Duration(seconds: 8);

  /// Suite method channel (pinned to flutter_security_suite 1.1.1 —
  /// `platform/method_channel_security.dart`: `com.securebankkit/security`,
  /// `feature#action` naming). Re-declared here (not imported) because the
  /// package exports only the facade, not the channel.
  static const MethodChannel _suiteChannel =
      MethodChannel('com.securebankkit/security');

  @override
  Future<IntegritySignals> check() async {
    // Records-only builds hold no device trust (fail-closed upstream via
    // requireMobileFace, not here): skip the plugin entirely.
    if (kIsWeb ||
        !(defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      return IntegritySignals(debug: kDebugMode);
    }
    try {
      // Presence ping: the suite's use cases swallow channel errors into
      // fail-SECURE defaults (rooted/tampered read true on error), which
      // is correct for a PRESENT plugin but indistinguishable from an
      // ABSENT one — and an absent channel (stale install that never
      // re-registered the plugin, test harness) must fail OPEN, never
      // taint every verdict. One cheap read proves the native side
      // answers; anything else (missing plugin, hang) degrades clean.
      await _suiteChannel
          .invokeMethod<bool>('emulator#isEmulator')
          .timeout(probeBudget);
      final status = await SecureBankKit.initialize(
        enableRootDetection: true,
        enableAppIntegrity: true,
        enableEmulatorDetection: true,
        enableTamperDetection: true,
        enableRuntimeProtection: true,
      ).runSecurityCheck().timeout(probeBudget);
      return IntegritySignals(
        rooted: status.isRooted,
        hooked: status.isRuntimeHooked,
        // isAppIntegrityValid folds FLAG_DEBUGGABLE + installer allowlist
        // into one bit (suite 1.1.1 AppIntegrityHandler:
        // `!isDebuggable && isInstalledFromTrustedSource`; sideloaded
        // installer null → invalid) — gating it raw taints EVERY
        // `flutter run` debug build and every sideloaded build, hard-
        // blocking all dev enrollment against the "debug alone never
        // blocks" law. Debug builds (never store builds) rely on
        // isTampered (re-sign/strip) only; release/profile builds keep
        // the full bit, so sideloaded release builds still taint.
        tampered: status.isTampered ||
            (!status.isAppIntegrityValid && !kDebugMode),
        emulator: status.isEmulator,
        debug: kDebugMode,
      );
    } catch (_) {
      return IntegritySignals(debug: kDebugMode);
    }
  }
}

/// Immutable integrity verdict: the five signals + the stable hash bound
/// into dSig. `hash` is 8 lowercase hex chars.
class IntegrityVerdict {
  final bool rooted;
  final bool hooked;
  final bool tampered;
  final bool emulator;
  final bool debug;
  final String hash;

  const IntegrityVerdict({
    required this.rooted,
    required this.hooked,
    required this.tampered,
    required this.emulator,
    required this.debug,
    required this.hash,
  });

  /// Privileged OS = rooted or jailbroken (single §5 gate word).
  bool get privileged => rooted;

  /// Enroll hard-block (§5): privileged / hooked / tampered / emulator.
  /// Debug alone never blocks.
  bool get blocksEnroll => rooted || hooked || tampered || emulator;

  /// Marking flag for the professor path: '' when clean, else
  /// `integrity-flagged`. Host maps non-empty → FLAGGED, never ABSENT
  /// offline (owned by sec-sync).
  String get flagForMarking => blocksEnroll ? IntegrityGate.flaggedValue : '';

  @override
  String toString() =>
      'IntegrityVerdict(r:$rooted h:$hooked t:$tampered e:$emulator d:$debug hash:$hash)';
}

/// Public API for 2C integrity (handoff: callers depend on this class,
// callers never touch probes directly).
class IntegrityGate {
  IntegrityGate._();

  /// Host-side flag value for a tainted prove (schema §7 `integrityFlag`).
  static const flaggedValue = 'integrity-flagged';

  /// Injectable probe (tests + future native backend). Fresh checks read
  /// it live; the cache resets only via a fresh [performCheck].
  static IntegrityProbe probe = const PlatformIntegrityProbe();
  static IntegrityVerdict? _last;

  /// Cached startup verdict (null before the first [performCheck]).
  static IntegrityVerdict? get lastVerdict => _last;

  /// Pure verdict hash: first 8 hex of
  /// SHA256("v1|r|h|t|e|d") with 1/0 per signal. Stable across runs and
  /// platforms — the value the prove path binds into dSig and the
  /// professor compares offline.
  static String verdictHashOf({
    required bool rooted,
    required bool hooked,
    required bool tampered,
    required bool emulator,
    required bool debug,
  }) {
    String bit(bool b) => b ? '1' : '0';
    final csv =
        'v1|${bit(rooted)}|${bit(hooked)}|${bit(tampered)}|${bit(emulator)}|${bit(debug)}';
    final digest = ProxCrypto.sha256Sync(csv.codeUnits);
    final sb = StringBuffer();
    for (final byte in digest.sublist(0, 4)) {
      sb.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static IntegrityVerdict _build(IntegritySignals s) => IntegrityVerdict(
        rooted: s.rooted,
        hooked: s.hooked,
        tampered: s.tampered,
        emulator: s.emulator,
        debug: s.debug,
        hash: verdictHashOf(
          rooted: s.rooted,
          hooked: s.hooked,
          tampered: s.tampered,
          emulator: s.emulator,
          debug: s.debug,
        ),
      );

  /// Startup snapshot: probes once, caches into [lastVerdict], logs via
  /// SEC. Never throws — a probe failure yields a clean verdict (unknown ⇒
  /// clean) so startup can never brick offline marking; sensitive ops
  /// re-probe fresh via [verifyBeforeSensitiveOp].
  static Future<IntegrityVerdict> performCheck() async {
    IntegritySignals signals;
    try {
      signals = await probe.check();
    } catch (e) {
      BleLog.log('SEC', 'integrity startup probe failed ($e) — assuming clean');
      signals = const IntegritySignals();
    }
    final verdict = _build(signals);
    _last = verdict;
    BleLog.log('SEC',
        'integrity startup → $verdict${kIsWeb ? ' (web records-only)' : ''}');
    return verdict;
  }

  /// Fresh probe before a sensitive op (enroll/host/prove). Never serves
  /// the cached startup verdict for decisions — callers pass the returned
  /// verdict to [enrollBlockReason] / [markingFlag]. Never throws (same
  /// fail-open-probe contract as [performCheck]).
  static Future<IntegrityVerdict> verifyBeforeSensitiveOp(
      IntegrityOp op) async {
    IntegritySignals signals;
    try {
      signals = await probe.check();
    } catch (e) {
      BleLog.log(
          'SEC', 'integrity pre-${op.name} probe failed ($e) — assuming clean');
      signals = const IntegritySignals();
    }
    final verdict = _build(signals);
    BleLog.log('SEC', 'integrity pre-${op.name} → $verdict');
    return verdict;
  }

  /// Enroll gate (§5): '' when enroll may proceed, else an actionable
  /// refusal naming the first taint in signal order
  /// (privileged → hooked → tampered → emulator). Debug alone returns ''.
  static String enrollBlockReason(IntegrityVerdict verdict) {
    if (verdict.rooted) {
      return 'This device looks rooted or jailbroken — enrollment is blocked '
          'on privileged OS builds. Restore the stock OS and try again.';
    }
    if (verdict.hooked) {
      return 'A hooking framework (Frida/Xposed) was detected — enrollment '
          'is blocked while code injection is present. Remove it and try again.';
    }
    if (verdict.tampered) {
      return 'This install looks tampered or re-signed — enrollment is '
          'blocked. Reinstall Proximity from the official store build.';
    }
    if (verdict.emulator) {
      return 'Emulators cannot enroll as student devices — use a physical '
          'Android/iOS phone for enrollment.';
    }
    return '';
  }

  /// Marking flag for the prove path: '' when clean, else
  /// `integrity-flagged`. The professor flags (never auto-absent offline).
  /// Thin alias of [IntegrityVerdict.flagForMarking] for call sites that
  /// hold no verdict object yet.
  static String markingFlag(IntegrityVerdict verdict) => verdict.flagForMarking;

  /// Desktop/web records builds hold no device trust: they never enroll
  /// and never prove, so integrity is not applicable (fail-closed upstream
  /// via requireMobileFace, not here).
  static bool get isRecordsOnly =>
      kIsWeb ||
      !(defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
}

/// Firebase App Check wiring (PROXIMITY_SECURITY.md §5) — REAL activation
/// on the exact 0.3.x API (firebase_app_check ^0.3.2+10 — enum providers,
/// NOT 0.4.x provider classes):
/// ```dart
/// await FirebaseAppCheck.instance.activate(
///   androidProvider: AndroidProvider.playIntegrity,
///   appleProvider: AppleProvider.deviceCheck,
/// );
/// ```
/// Must run BEFORE the first Firestore read (main.dart calls this before
/// ForceUpdate.checkNow and every provider read). Apple uses DeviceCheck
/// (App Attest needs iOS 14+ plus entitlements per flavor — escalate per
/// release once the floor is 14+; DeviceCheck is the safe default).
/// Console enforcement is a console toggle (no rules syntax on Spark):
/// register Play Integrity + DeviceCheck apps, set Play DEVICE→STRONG,
/// THEN Enforce on Firestore — only after the 0.2.0 floor has rolled out
/// (enforcing earlier bricks legit installs that cannot attest yet; see
/// commit body for the timing). App Check absence never blocks offline
/// marking (defense in depth, never the sole gate: HW dSig still
/// required).
class IntegrityAppCheck {
  IntegrityAppCheck._();

  static bool _activated = false;

  /// Activation budget: a hung native activate must never stall startup —
  /// past this the call degrades to a log line (same fail-soft posture as
  /// the integrity probe's [PlatformIntegrityProbe.probeBudget]).
  static const activateBudget = Duration(seconds: 8);

  /// Best-effort activation hook called from main.dart before Firestore.
  /// Never throws (uninitialized Firebase, unsupported platform, missing
  /// provider all degrade to a log line — marking stays offline-capable)
  /// and never hangs past [activateBudget] (a blackholed native channel
  /// degrades the same way, so cold start always proceeds).
  static Future<void> ensureActivated() async {
    if (_activated) return;
    try {
      await FirebaseAppCheck.instance
          .activate(
            androidProvider: AndroidProvider.playIntegrity,
            appleProvider: AppleProvider.deviceCheck,
          )
          .timeout(activateBudget);
      _activated = true;
      BleLog.log('SEC', 'AppCheck activated (PlayIntegrity/DeviceCheck)');
    } catch (e) {
      BleLog.log('SEC',
          'AppCheck activation skipped ($e) — marking stays offline-capable');
    }
  }
}
