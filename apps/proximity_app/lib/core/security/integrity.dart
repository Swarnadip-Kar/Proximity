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
// Native backends (NOT imported here — pubspec owned by 1B `sec-store-config`):
//   REQUIRED (request via 1B, do not edit pubspec here):
//     firebase_app_check: ^0.4.7
//     flutter_security_suite: ^latest
//   Once 1B lands them, [PlatformIntegrityProbe] delegates per signal:
//     rooted   → SecuritySuite.isRooted / isJailBroken
//     hooked   → Frida port/maps scan + Xposed/module check + hook detect
//     tampered → tamper SHA-256 check + installer/package verify
//     emulator → emulator check (+ FLAG_SECURE set on Android windows)
//     debug    → debugger / debug-mode check
//   App Check providers: AndroidPlayIntegrityProvider, Apple AppAttest /
//   DeviceCheck provider. Console enforcement is a console toggle (no rules
//   syntax on Spark) — steps live in the commit body + [IntegrityAppCheck].
//   Until then the default probe below is conservative (fail-open signals,
//   fail-closed enforcement at the gate): unknown → false, so offline
//   marking is never broken by a missing plugin.
library;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kDebugMode, kIsWeb, TargetPlatform;
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

/// Conservative default probe (no native deps — green before 1B lands the
/// plugins). Reports only what pure Dart knows honestly:
///   debug = kDebugMode (observed, never an enroll block on its own).
/// Everything else is false (unknown ⇒ clean) so a missing native plugin
/// can never brick offline marking. The native probe overrides [check]
/// with the real RootBeer/Frida/emulator/tamper reads once available.
class PlatformIntegrityProbe implements IntegrityProbe {
  const PlatformIntegrityProbe();

  @override
  Future<IntegritySignals> check() async {
    // TODO(1B sec-store-config): after adding
    //   flutter_security_suite: ^latest
    // delegate each signal to SecuritySuite (root/jailbreak, Frida+Xposed,
    // tamper SHA-256, emulator, debugger) instead of the constants below.
    return IntegritySignals(debug: kDebugMode);
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

/// Firebase App Check wiring (PROXIMITY_SECURITY.md §5).
///
/// REAL activation (lands with 1B's `firebase_app_check: ^0.4.7` — do NOT
/// add the dep here):
/// ```dart
/// import 'package:firebase_app_check/firebase_app_check.dart';
/// await FirebaseAppCheck.instance.activate(
///   androidProvider: AndroidPlayIntegrityProvider(),
///   appleProvider: AppleAppAttestProvider(), // DeviceCheck fallback on <iOS14
/// );
/// ```
/// Must run BEFORE the first Firestore read (see main.dart wiring).
/// Console enforcement is a console toggle (no rules syntax on Spark):
/// Play Integrity DEVICE→STRONG + App Attest, then Enforce Firestore.
/// Full click path ships in the commit body. Until 1B lands the dep this
/// is a documented no-op that logs once — App Check absence never blocks
/// offline marking (defense in depth, never the sole gate: HW dSig still
/// required).
class IntegrityAppCheck {
  IntegrityAppCheck._();

  static bool _logged = false;

  /// Best-effort activation hook called from main.dart before Firestore.
  /// Never throws.
  static Future<void> ensureActivated() async {
    // TODO(1B sec-store-config): replace with the real
    // FirebaseAppCheck.instance.activate(...) snippet above once
    // firebase_app_check ^0.4.7 is in pubspec.yaml.
    if (!_logged) {
      _logged = true;
      BleLog.log('SEC',
          'AppCheck pending 1B dep (firebase_app_check ^0.4.7: PlayIntegrity/AppAttest) — enforcement via console; marking stays offline-capable');
    }
  }
}
