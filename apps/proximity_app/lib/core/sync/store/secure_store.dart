// SecureDeviceStore (prod): flutter_secure_storage (enrollment secrets) +
// shared_preferences (history JSON). Split out of core/device_store.dart
// course-membership predicates, which now call the shared pure helper
// [recordInCourse] (see record_helpers.dart).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:proximity_storage/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../features/records/records_isolate.dart'
    show decodeJsonListIsolate, encodeJsonIsolate;
import '../../security/revocation_cache.dart' show RevocationHashStore;
import '../../security/secure_store_options.dart';
import 'record_helpers.dart';
import 'store_base.dart';
import '../../export_location.dart' show exportDirPrefsKey;

class SecureDeviceStore implements DeviceStore {
  static const _kEnroll = 'prox.enrollment.v1';
  static const _kHistory = 'prox.history.v1';
  static const _kCatalog = 'prox.catalog.v1';
  static const _kCourses = 'prox.courses.v1';
  static const _kMode = 'prox.mode.v1';
  static const _kHostName = 'prox.hostname.v1';
  static const _kShowProfPhoto = 'prox.showprofphoto.v1.';
  static const _kCourseProfPhoto = 'prox.courseprofphoto.v1.';
  static const _kLastHost = 'prox.lasthost.v1';
  final FlutterSecureStorage _secure;
  // Hardened at-rest posture (PROXIMITY_SECURITY.md §3, F3): biometric-bound
  // AES-GCM on Android (`enforceBiometrics:true`, `strongBiometricOnly`),
  // this-device-only unsynced Keychain on iOS (`synchronizable:false`,
  // `first_unlock_this_device`, `biometryCurrentSet`). Never revert to
  // `const FlutterSecureStorage()` defaults — the default AndroidOptions
  // allow device-credential fallback and the default IOSOptions are
  // syncable/migratable. This is the ENROLLMENT doc store (prompt-gated);
  // the HW seal DEK lives in the prompt-free `FlutterSealStore` (same FSS
  // plugin, ungated options — gated instead by the 4h HW grant + face).
  // The two instances MUST keep distinct Android `storageNamespace`s
  // ('prox_enroll' here via SecureStoreOptions.aOpts vs 'prox_seal' there):
  // different key ciphers sharing one namespace flip algorithm markers and
  // trigger migrate/reset wipes of each other's data.
  // The credential-fallback instance below is a THIRD namespace
  // ('prox_enroll_cred' via SecureStoreOptions.aOptsFallback), never the
  // same as the strong slot: FSS v11 derives the KeyStore alias
  // (`.<namespace>`), the IV pref and the wrapped app-key blob from the
  // namespace, so two configs with different `biometricType` (different
  // `UserAuthenticationParameters`) sharing one namespace clobber each
  // other's IV/blob — the loser's post-auth `cipher.doFinal` then throws
  // `javax.crypto.IllegalBlockSizeException` inside
  // `BiometricPrompt.onAuthenticationSucceeded` (field report: "Save
  // failed: PlatformException(...IllegalBlockSizeException...)"). Separate
  // namespaces = separate keys/blobs = no clobber; the tier hint below
  // picks the live slot so steady state costs one prompt, not two.
  // Backup exclusion lives in AndroidManifest (`allowBackup=false`,
  // `fullBackupContent=false`) + res/xml/data_extraction_rules.xml.
  SecureDeviceStore({
    FlutterSecureStorage? secure,
    FlutterSecureStorage? fallbackSecure,
  })  : _secure = secure ??
            const FlutterSecureStorage(
              aOptions: SecureStoreOptions.aOpts,
              iOptions: SecureStoreOptions.iOpts,
            ),
        _fallbackSecure = fallbackSecure ??
            const FlutterSecureStorage(
              aOptions: SecureStoreOptions.aOptsFallback,
              iOptions: SecureStoreOptions.iOptsFallback,
            );

  final FlutterSecureStorage _fallbackSecure;

  /// True for every secure-store failure that must try the OTHER slot
  /// instead of surfacing raw platform text:
  /// - pre-auth unavailability (no strong biometric enrolled, no hardware);
  /// - user-skipped prompts (`cancel…`/`auth_canceled`/`user_cancel` —
  ///   kept here for the WRITE path only, where a dismissal stops the
  ///   slot loop with the sanitized persist error instead of falling
  ///   through; READS check [_isPromptDismissal] first and stop there,
  ///   never fall through);
  /// - POST-AUTH key/blob mismatch: the prompt succeeded but the stored
  ///   Keystore-wrapped app-key blob cannot be unwrapped with the unlocked
  ///   key (`IllegalBlockSizeException` / `BadPaddingException` /
  ///   `KeyPermanentlyInvalidatedException` after a fingerprint/PIN-set
  ///   change — `setInvalidatedByBiometricEnrollment(true)` orphans the old
  ///   blob by OS design);
  /// - iOS keychain lockout/invalidation (`biometryCurrentSet` items die
  ///   with the enrolled set: err -34018/-25300).
  ///
  /// `biometric` stays matched here for genuine unavailability ("no
  /// biometrics enrolled", "biometric hardware unavailable" → cred-slot
  /// fallback). Cancel wordings never reach this matcher on reads:
  /// [_isPromptDismissal] runs first and parks them as dismissal.
  ///
  /// Non-matching errors (I/O, Firestore, programming bugs) rethrow
  /// untouched — they are never a signal to switch slots.
  bool _isSecureStoreAuthOrKeyFailure(Object e) {
    final s = '$e'.toLowerCase();
    return s.contains('biometric') ||
        s.contains('none_enrolled') ||
        s.contains('no_hardware') ||
        s.contains('cryptofailed') ||
        s.contains('keystore') ||
        s.contains('illegalblocksize') ||
        s.contains('badpadding') ||
        s.contains('bad padding') ||
        s.contains('aeadbadtagexception') ||
        s.contains('invalidat') ||
        // Fresh namespace after an app update: the Keystore key exists but
        // the biometric-bound cipher cannot init until the namespace
        // re-binds (`IllegalStateException: Cipher not initialized`). Data
        // may exist behind the lock — never report empty (that pushes a
        // phantom enrollment); park dismissed with retry instead.
        s.contains('cipher') ||
        // First-frame channel race: the platform side is not attached yet.
        // Transient — retry, never empty.
        s.contains('missingplugin') ||
        s.contains('usernotauthenticated') ||
        s.contains('user_not_authenticated') ||
        s.contains('cryptoobject') ||
        s.contains('auth_canceled') ||
        s.contains('authcanceled') ||
        s.contains('user_cancel') ||
        s.contains('keychain') ||
        s.contains('-34018') ||
        s.contains('-25300') ||
        s.contains('authfailed') ||
        s.contains('authentication failed');
  }

  /// User-dismissal signals: the user actively killed THIS prompt
  /// (back/cancel/negative button). A dismissal STOPS the slot scan
  /// immediately (see both read loops) — falling through to the other
  /// slot would pop a SECOND prompt milliseconds after the skip (the
  /// skip-then-prompt-again defect: pass-or-fail, it only re-parks).
  /// One read call costs at most one prompt, ever. Checked BEFORE
  /// [_isSecureStoreAuthOrKeyFailure], which keeps matching these
  /// strings for the write path (writes stop on dismissal too — see
  /// below — and fall through only on genuine key/blob mismatch).
  /// Key/blob-mismatch signals (crypto, invalidated, keychain codes)
  /// are NOT dismissals — the slot genuinely cannot serve, so the scan
  /// still continues to the other slot (cred-slot recovery preserved).
  ///
  /// Deliberately BROAD on `cancel`: field logcat pins the real
  /// flutter_secure_storage strings as
  /// `Biometric authentication error [10]: Authentication cancelled`
  /// and `... Fingerprint operation cancelled by user.` — neither
  /// carries a `user_cancel`/`auth_canceled`/`dismiss` marker, and the
  /// first ALSO contains `biometric`, so anything narrower routes a
  /// plain skip into the other slot's prompt (the cancel-first-pass-
  /// second-then-inconclusive loop). No legitimate crypto/keystore/io
  /// error contains `cancel`, and an overlap/system cancel sharing the
  /// wording degrades to a dismissal park (explicit retry recovers) —
  /// fail-safe, never a second prompt, never a hammer loop.
  bool _isPromptDismissal(Object e) {
    final s = '$e'.toLowerCase();
    return s.contains('cancel') ||
        s.contains('dismiss') ||
        s.contains('negative_button') ||
        s.contains('negativebutton');
  }

  /// Honest, prompt-free copy for an unrecoverable secure-store write (both
  /// slots refused with an auth/key failure). Never leaks the raw
  /// `PlatformException(...javax.crypto...)` + Java stack to the UI banner.
  StateError _secureStorePersistError() => StateError(
        'Secure storage rejected the save (phone lock / fingerprint set '
        'changed). Unlock and try again — nothing already saved was lost. '
        'If it repeats, re-enroll your fingerprint or PIN in Settings.',
      );

  /// Tier hint: which FSS namespace holds the live data ('strong' =
  /// `prox_enroll`, 'cred' = `prox_enroll_cred`). Unencrypted SharedPrefs,
  /// best-effort: a hint, never a secret. Starts at strong; flips to the
  /// slot that answers after the other fails with an auth/key error, so a
  /// corrupted strong slot costs one prompt per process (not two forever).
  static const _kTierPref = 'prox.secure.tier.v1';
  static const _kTierCred = 'cred';
  bool _preferCredSlot = false;
  // Proven-emptiness hints (unencrypted SharedPrefs, same best-effort
  // standing as the tier hint): whether a gated value is KNOWN present or
  // KNOWN absent. Null = unknown (pre-hint installs, never yet proven).
  // A `false` lets auto reads report empty WITHOUT a biometric prompt —
  // fresh-install sign-in must not pop fingerprint for data that cannot
  // exist (the field phantom-prompt → dismiss → locked-accounts loop).
  // Set on every proven result (hit → true, clean miss → false) and every
  // write; explicit retries always scan regardless (tier-wipe recovery:
  // prefs and secure storage can diverge, and a false hint must never
  // hide data an explicit retry could serve).
  static const _kHasEnroll = 'prox.secure.hasEnroll.v1';
  static const _kHasInstall = 'prox.secure.hasInstall.v1';
  bool? _hasEnrollHint;
  bool? _hasInstallHint;
  // Single-flight tier load: concurrent gated reads on a fresh process
  // must share one prefs read. The old bool flag let the second reader
  // skip the load and use the default (strong) while the first was still
  // awaiting prefs — a persisted cred hint then served strong-first,
  // costing a miss-prompt + hit-prompt (the unpredictable second prompt
  // on cold open). Sharing the future keeps steady state at one prompt.
  Future<void>? _tierLoad;

  Future<void> _ensureTierLoaded() {
    return _tierLoad ??= () async {
      try {
        final prefs = await _prefs();
        _preferCredSlot = prefs.getString(_kTierPref) == _kTierCred;
        _hasEnrollHint = prefs.getBool(_kHasEnroll);
        _hasInstallHint = prefs.getBool(_kHasInstall);
      } catch (_) {
        _preferCredSlot = false;
      }
    }();
  }

  Future<void> _persistTier() async {
    try {
      final prefs = await _prefs();
      await prefs.setString(
          _kTierPref, _preferCredSlot ? _kTierCred : 'strong');
    } catch (_) {}
  }

  /// Records a proven emptiness result (see [_kHasEnroll]/[_kHasInstall]).
  /// Memory first, then the prefs sidecar (best-effort like the tier).
  Future<void> _noteHasEnroll(bool present) async {
    _hasEnrollHint = present;
    try {
      final prefs = await _prefs();
      await prefs.setBool(_kHasEnroll, present);
    } catch (_) {}
  }

  /// Records a proven install-id result (see [_noteHasEnroll]).
  Future<void> _noteHasInstall(bool present) async {
    _hasInstallHint = present;
    try {
      final prefs = await _prefs();
      await prefs.setBool(_kHasInstall, present);
    } catch (_) {}
  }

  /// Adopts [credPreferred], persisting the hint only when it flips (steady
  /// state costs no extra prefs write).
  Future<void> _adoptTier(bool credPreferred) async {
    if (_preferCredSlot == credPreferred) return;
    _preferCredSlot = credPreferred;
    await _persistTier();
  }

  /// Strong slot first by default, cred slot first once it proved live.
  List<FlutterSecureStorage> _orderedSlots() =>
      _preferCredSlot ? [_fallbackSecure, _secure] : [_secure, _fallbackSecure];

  /// Test-only view of the wired storage (lets tests assert the hardened
  /// options are actually passed, not just that the constants exist).
  @visibleForTesting
  FlutterSecureStorage get debugSecureStorageForTest => _secure;

  /// Single SharedPreferences acquisition point (was 34 inline copies).
  Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  // Process-local cache for the two biometric-gated reads (enrollment doc
  // + installId share the gated FSS instance). Root cause of the
  // fingerprint-on-every-prove: checkFaceAny reads enrollment, listen
  // reads it again, and every _prove rotation reads installId + signs —
  // each secure read re-prompts (Android enforceBiometrics, iOS
  // biometryCurrentSet). The HW 4h grant + face check already gate use,
  // so one prompt per process per value is enough; writes invalidate.
  StoredEnrollment? _enrollmentCache;
  bool _enrollmentLoaded = false;
  String? _installIdCache;
  bool _installIdLoaded = false;
  // Last secure-read failure (biometric cancel/lockout/dead keychain):
  // reads inside the cooldown return the cached value without touching
  // the store, so a cancel + 600ms auto-retry cannot hammer the prompt.
  DateTime? _lastSecureFailAt;
  static const _secureFailCooldown = Duration(seconds: 5);

  bool _inSecureCooldown(DateTime now) =>
      _lastSecureFailAt != null &&
      now.difference(_lastSecureFailAt!) < _secureFailCooldown;

  // Biometric-prompt single-flight: concurrent gated reads overlap
  // BiometricPrompts, which cancel each other — the scanned prompt then
  // belongs to a read whose result nobody uses, while the unlock read
  // dies dismissed behind a banner (cold-open "scan does nothing").
  // Queued behind this chain, readers run one at a time; each re-checks
  // the warm cache and the dismissal cooldown on entry, so an overlap
  // costs exactly one prompt total (first success warms, first failure
  // cools) instead of a prompt fight. The chain itself never carries
  // errors — a failed reader must not wedge later readers — while the
  // error still propagates to its own caller.
  Future<void> _promptGate = Future<void>.value();

  Future<T> _behindPromptGate<T>(Future<T> Function() work) {
    final run = _promptGate.then((_) => work(), onError: (_) => work());
    _promptGate = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  @override
  Future<StoredEnrollment?> readEnrollment() async {
    if (_enrollmentLoaded) return _enrollmentCache;
    final now = DateTime.now().toUtc();
    // Recent failure with nothing proven (the cache is necessarily null
    // here — every write pairs it with loaded): stay dismissed WITHOUT
    // re-prompting (anti-hammer) and WITHOUT misreporting empty — the
    // caller (unlock resolve) parks locked with retry instead of pushing
    // the enrollment flow for data that may still exist behind the lock.
    if (_inSecureCooldown(now)) {
      _lastSecureFailAt = now;
      throw const SecureStoreDismissed();
    }
    await _ensureTierLoaded();
    // Proven-empty installs skip the gated read entirely: no phantom
    // biometric prompt for data known absent (fresh-install sign-in).
    // Unknown (null — pre-hint installs) still probes; explicit retries
    // always scan (tier-wipe recovery, see _noteHasEnroll).
    if (_hasEnrollHint == false) return null;
    // Auto path: preferred slot only on clean miss (one prompt max for
    // the empty case). The full both-slot scan lives behind explicit
    // retry (see readEnrollmentRetry) for the tier-wiped reinstall shape.
    return _behindPromptGate(() => _readEnrollmentCold(scanAll: false));
  }

  /// Gated enrollment scan (one prompt-chain turn): re-checks the warm
  /// cache and the dismissal cooldown on entry — a reader queued behind
  /// a success serves the cache with no second prompt; a reader queued
  /// behind a failure stays dismissed with no second prompt (a
  /// just-dismissed user is never re-prompted by someone else's stale
  /// overlap).
  ///
  /// [scanAll]: explicit-retry full scan (both slots, clean miss keeps
  /// scanning) for the tier-wiped reinstall shape (unencrypted prefs hint
  /// gone, live doc in the other slot). Auto reads pass false: a clean
  /// miss on the preferred slot reports empty WITHOUT prompting the
  /// second slot — every fresh/empty cold open used to pay two prompts
  /// (miss + miss) for one answer. Auth/key failures ALWAYS fall through
  /// (crypto recovery preserved on both paths); dismissals always stop;
  /// a clean miss with no failure anywhere leaves the tier untouched.
  Future<StoredEnrollment?> _readEnrollmentCold({required bool scanAll}) async {
    if (_enrollmentLoaded) return _enrollmentCache;
    final now = DateTime.now().toUtc();
    if (_inSecureCooldown(now)) {
      _lastSecureFailAt = now;
      throw const SecureStoreDismissed();
    }
    await _ensureTierLoaded();
    // Fail-open: unsigned simulator builds have no keychain (err -34018);
    // a missing enrollment just means "enroll".
    // First hit wins; dismissed needs an auth/key failure with no hit
    // anywhere; empty needs clean miss(es) with no failure anywhere
    // (one miss on auto, two on explicit retry).
    String? raw;
    var sawAuthFailure = false;
    FlutterSecureStorage? hitSlot;
    FlutterSecureStorage? missSlot;
    for (final slot in _orderedSlots()) {
      String? v;
      try {
        v = await slot.read(key: _kEnroll);
      } catch (e) {
        // User skipped THIS prompt: stop the scan now (coolstamp fresh —
        // the loop may already have spanned a prompt) and report
        // dismissed — data may sit behind the lock, never empty. Never
        // fall through: the other slot would prompt again immediately.
        if (_isPromptDismissal(e)) {
          _lastSecureFailAt = DateTime.now().toUtc();
          throw const SecureStoreDismissed();
        }
        if (!_isSecureStoreAuthOrKeyFailure(e)) {
          // Non-auth failure (I/O, detached channel, programming bug):
          // never a slot signal and never an empty report — a transient
          // here must not read as "unenrolled" (phantom setup push) the
          // way a clean miss does. Throw transient; callers park/retry.
          // (No coolstamp: nothing was prompted, nothing to hammer.)
          throw const SecureStoreUnavailable();
        }
        sawAuthFailure = true;
        continue;
      }
      // The hitting slot becomes the preferred slot, so steady state
      // costs one prompt. On the auto path a clean miss on the preferred
      // slot reports empty immediately (no second prompt); the explicit
      // retry keeps scanning for the reinstall shape and adopts the
      // answering miss slot below for the same one-prompt steady state.
      if (v != null) {
        raw = v;
        hitSlot = slot;
        break;
      }
      if (!scanAll) {
        _enrollmentCache = null;
        _enrollmentLoaded = true;
        // Proven empty on the preferred slot: future auto reads skip the
        // prompt (see readEnrollment); explicit retries still scan.
        await _noteHasEnroll(false);
        return null;
      }
      missSlot ??= slot;
    }
    if (raw != null) {
      await _adoptTier(identical(hitSlot, _fallbackSecure));
      // Proven present (parse may still reject a corrupt doc below — the
      // data exists, so future auto reads keep probing).
      await _noteHasEnroll(true);
      // fall through to parse below
    } else {
      if (sawAuthFailure) {
        if (missSlot != null) {
          await _adoptTier(identical(missSlot, _fallbackSecure));
        }
        // Every slot refused behind the prompt gate and no proven value
        // can be served: throw dismissed (data may exist behind the lock
        // — never report empty here, or the shell pushes enrollment for
        // an enrolled user who just pressed back). Coolstamp first
        // (anti-hammer).
        _lastSecureFailAt = now;
        throw const SecureStoreDismissed();
      }
      _enrollmentCache = null;
      _enrollmentLoaded = true;
      // Full-scan proven empty: future auto reads skip the prompt.
      await _noteHasEnroll(false);
      return null;
    }
    late final Map<String, dynamic> doc;
    late final StoredEnrollment parsed;
    try {
      doc = jsonDecode(raw) as Map<String, dynamic>;
      parsed = StoredEnrollment.fromJson(doc);
    } catch (_) {
      return null;
    }
    // Fresh-only (security §2 F1): no raw-seed migration — the doc is
    // sealed-only by construction. Unknown keys are ignored by fromJson.
    _enrollmentCache = parsed;
    _enrollmentLoaded = true;
    return parsed;
  }

  @override
  Future<StoredEnrollment?> readEnrollmentRetry() async {
    // Explicit user retry: clear the dismissal anti-hammer cooldown so
    // the prompt shows again instead of replaying the dismissal, and run
    // the FULL both-slot scan (clean miss keeps scanning) for the
    // tier-wiped reinstall shape. Auto reads (mount, listeners) use
    // [readEnrollment] (preferred slot only on clean miss: one prompt
    // for empty, never two uninvited). Cached PROVEN values still
    // shortcut with no prompt; a cached auto-empty re-scans full (the
    // auto miss was single-slot, so it cannot stand for the other slot).
    _lastSecureFailAt = null;
    if (_enrollmentLoaded && _enrollmentCache == null) {
      _enrollmentLoaded = false;
    }
    if (_enrollmentLoaded) return _enrollmentCache;
    return _behindPromptGate(() => _readEnrollmentCold(scanAll: true));
  }

  @override
  Future<void> writeEnrollment(StoredEnrollment e) async {
    final payload = jsonEncode(e.toJson());
    await _ensureTierLoaded();
    for (final slot in _orderedSlots()) {
      try {
        await slot.write(key: _kEnroll, value: payload);
      } catch (err) {
        // Skipped save prompt: stop here with the sanitized copy — the
        // other slot would prompt again immediately (same defect as the
        // read scan), and the raw PlatformException + Java stack must
        // never reach the UI.
        if (_isPromptDismissal(err)) throw _secureStorePersistError();
        if (!_isSecureStoreAuthOrKeyFailure(err)) rethrow;
        // Best-effort: drop the unreadable entry so a later init cannot
        // trip on stale data (the Keystore blob itself is namespaced away
        // from the other slot, which is tried next). Native delete needs
        // no cipher, so it works even when init is what failed.
        try {
          await slot.delete(key: _kEnroll);
        } catch (_) {}
        continue;
      }
      final usedCred = identical(slot, _fallbackSecure);
      await _adoptTier(usedCred);
      _enrollmentCache = e;
      _enrollmentLoaded = true;
      await _noteHasEnroll(true);
      return;
    }
    // Both slots refused with auth/key failures (e.g. the field
    // IllegalBlockSizeException after a lock-set change): honest copy, no
    // raw PlatformException + Java stack. Nothing is cached — a later Save
    // retries storage instead of believing an unpersisted doc.
    throw _secureStorePersistError();
  }

  @override
  Future<void> clearEnrollment() async {
    try {
      await _secure.delete(key: _kEnroll);
    } catch (_) {}
    try {
      await _fallbackSecure.delete(key: _kEnroll);
    } catch (_) {}
    await _adoptTier(false);
    _enrollmentCache = null;
    _enrollmentLoaded = true;
    await _noteHasEnroll(false);
  }

  @override
  Future<List<ClassRecord>> readHistory() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_kHistory);
    if (raw == null) return [];
    // Bulk JSON decode off the main thread (this blob grows unboundedly);
    // typed mapping stays here with the same corrupt-row skipping.
    List<Map<String, Object?>> list;
    try {
      list = await decodeJsonListIsolate(raw);
    } catch (_) {
      return [];
    }
    final out = <ClassRecord>[];
    for (final e in list) {
      try {
        out.add(ClassRecord.fromJson(Map<String, dynamic>.from(e)));
      } catch (_) {}
    }
    return out;
  }

  @override
  Future<void> appendHistory(ClassRecord record) async {
    final prefs = await _prefs();
    final cur = await readHistory();
    cur.add(record);
    await prefs.setString(
        _kHistory, await encodeJsonIsolate(cur.map((e) => e.toJson()).toList()));
  }

  @override
  Future<List<String>> readCatalog() async {
    final prefs = await _prefs();
    return prefs.getStringList(_kCatalog) ?? const [];
  }

  @override
  Future<void> addClass(String label) async {
    final clean = label.trim();
    if (clean.isEmpty) return;
    final prefs = await _prefs();
    final cur = await readCatalog();
    if (!cur.contains(clean)) {
      await prefs.setStringList(_kCatalog, [...cur, clean]);
    }
  }

  @override
  Future<List<Course>> readCourses() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_kCourses);
    if (raw == null) {
      // Migrate legacy name catalog.
      return [
        for (final n in await readCatalog())
          Course(name: n, createdAt: '')
      ];
    }
    try {
      final list = jsonDecode(raw) as List;
      final out = <Course>[];
      for (final e in list) {
        try {
          if (e is Map) {
            final c =
                Course.fromJson(Map<String, dynamic>.from(e));
            if (c.name.isNotEmpty) out.add(c);
          }
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> addCourse(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    final prefs = await _prefs();
    final cur = await readCourses();
    if (cur.any((c) => c.name == clean)) return;
    cur.add(Course(name: clean, createdAt: todayIso()));
    await prefs.setString(
        _kCourses, jsonEncode(cur.map((e) => e.toJson()).toList()));
    await addClass(clean);
  }

  @override
  Future<bool> renameCourse(String oldName, String newName) async {
    final clean = newName.trim();
    if (clean.isEmpty || clean == oldName) return false;
    final prefs = await _prefs();
    final courses = await readCourses();
    if (courses.any((c) => c.name == clean)) return false;
    final idx = courses.indexWhere((c) => c.name == oldName);
    if (idx < 0) return false;
    courses[idx] = Course(name: clean, createdAt: courses[idx].createdAt);
    await prefs.setString(
        _kCourses, jsonEncode(courses.map((e) => e.toJson()).toList()));
    final history = await readHistory();
    var touched = false;
    final migrated = [
      for (final r in history)
        if (recordInCourse(r, oldName))
          () {
            touched = true;
            return ClassRecord(
              id: r.id,
              courseId: clean,
              classLabel: r.classLabel == oldName ? clean : r.classLabel,
              dateIso: r.dateIso,
              timestampIso: r.timestampIso,
              startIso: r.startIso,
              windows: r.windows,
              names: r.names,
              rolls: r.rolls,
              org: r.org,
            );
          }()
        else
          r
    ];
    if (touched) {
      await prefs.setString(_kHistory,
          await encodeJsonIsolate(migrated.map((e) => e.toJson()).toList()));
    }
    final catalog = await readCatalog();
    final ci = catalog.indexOf(oldName);
    if (ci >= 0) {
      final next = List.of(catalog);
      next[ci] = clean;
      await prefs.setStringList(_kCatalog, next);
    }
    return true;
  }

  @override
  Future<String?> readMode() async {
    final prefs = await _prefs();
    return prefs.getString(_kMode);
  }

  @override
  Future<void> writeMode(String? mode) async {
    final prefs = await _prefs();
    if (mode == null) {
      await prefs.remove(_kMode);
    } else {
      await prefs.setString(_kMode, mode);
    }
  }

  @override
  Future<String> readHostName() async {
    final prefs = await _prefs();
    return prefs.getString(_kHostName) ?? '';
  }

  @override
  Future<void> writeHostName(String name) async {
    final prefs = await _prefs();
    await prefs.setString(_kHostName, name.trim());
  }

  @override
  Future<bool> readShowProfPhoto(String course) async {
    final prefs = await _prefs();
    return prefs.getBool('$_kShowProfPhoto${course.trim()}') ?? false;
  }

  @override
  Future<void> writeShowProfPhoto(String course, bool show) async {
    final key = course.trim();
    if (key.isEmpty) return;
    final prefs = await _prefs();
    await prefs.setBool('$_kShowProfPhoto$key', show);
  }

  @override
  Future<String> readCourseProfPhoto(String course) async {
    final prefs = await _prefs();
    return prefs.getString('$_kCourseProfPhoto${course.trim()}') ?? '';
  }

  @override
  Future<void> writeCourseProfPhoto(String course, String photoUrl) async {
    final key = course.trim();
    final url = photoUrl.trim();
    if (key.isEmpty || url.isEmpty) return;
    final prefs = await _prefs();
    await prefs.setString('$_kCourseProfPhoto$key', url);
  }

  @override
  Future<String?> readLastHost() async {
    final prefs = await _prefs();
    return prefs.getString(_kLastHost);
  }

  @override
  Future<void> writeLastHost(String hostPort) async {
    final prefs = await _prefs();
    await prefs.setString(_kLastHost, hostPort.trim());
  }

  @override
  Future<String?> readExportDir() async {
    final prefs = await _prefs();
    final v = (prefs.getString(exportDirPrefsKey) ?? '').trim();
    return v.isEmpty ? null : v;
  }

  @override
  Future<void> writeExportDir(String path) async {
    final clean = path.trim();
    if (clean.isEmpty) return;
    final prefs = await _prefs();
    await prefs.setString(exportDirPrefsKey, clean);
  }

  @override
  Future<void> clearExportDir() async {
    final prefs = await _prefs();
    await prefs.remove(exportDirPrefsKey);
  }

  @override
  Future<int> deleteSessions(List<String> ids) async {
    final set = ids.toSet();
    final cur = await readHistory();
    final keep = cur.where((r) => !set.contains(r.id)).toList();
    final removed = cur.length - keep.length;
    if (removed > 0) await writeHistory(keep);
    return removed;
  }

  @override
  Future<(int, int)> deleteCourse(String name) async {
    final courses = await readCourses();
    final ci = courses.indexWhere((c) => c.name == name);
    var coursesRemoved = 0;
    if (ci >= 0) {
      courses.removeAt(ci);
      final prefs = await _prefs();
      await prefs.setString(
          _kCourses, jsonEncode(courses.map((e) => e.toJson()).toList()));
      coursesRemoved = 1;
    }
    final history = await readHistory();
    final keep = history.where((r) => !recordInCourse(r, name)).toList();
    final sessionsRemoved = history.length - keep.length;
    if (sessionsRemoved > 0) await writeHistory(keep);
    final prefs = await _prefs();
    final catalog = await readCatalog();
    if (catalog.contains(name)) {
      await prefs.setStringList(
          _kCatalog, catalog.where((c) => c != name).toList());
    }
    return (coursesRemoved, sessionsRemoved);
  }

  @override
  Future<void> writeHistory(List<ClassRecord> records) async {
    final prefs = await _prefs();
    await prefs.setString(_kHistory,
        await encodeJsonIsolate(records.map((e) => e.toJson()).toList()));
  }

  @override
  Future<void> upsertHistory(ClassRecord record) async {
    final cur = await readHistory();
    final idx = cur.indexWhere((r) => r.id == record.id);
    if (idx < 0) {
      cur.add(record);
    } else {
      cur[idx] = record;
    }
    await writeHistory(cur);
  }

  static const _kSessions = 'prox.sessions.v1';

  Future<Map<String, dynamic>> _readSessions() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_kSessions);
    if (raw == null) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  @override
  Future<Map<String, dynamic>?> readSession(String course) async {
    final all = await _readSessions();
    final v = all[course];
    if (v == null) return null;
    try {
      if (v is! Map) return null;
      return Map<String, dynamic>.from(v);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeSession(String course, Map<String, dynamic> draft) async {
    final prefs = await _prefs();
    final all = await _readSessions();
    all[course] = draft;
    await prefs.setString(_kSessions, jsonEncode(all));
  }

  @override
  Future<void> clearSession(String course) async {
    final prefs = await _prefs();
    final all = await _readSessions();
    if (all.remove(course) != null) {
      await prefs.setString(_kSessions, jsonEncode(all));
    }
  }

  static const _kRole = 'prox.role.v1';
  static const _kHidden = 'prox.hidden.v1';
  static const _kInstall = 'prox.install.v1';
  static const _kStudentSessions = 'prox.studentSessions.v1';

  @override
  Future<Map<String, String>?> readRole() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_kRole);
    if (raw == null) return null;
    try {
      return Map<String, String>.from(
          (jsonDecode(raw) as Map).map((k, v) => MapEntry('$k', '$v')));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeRole(Map<String, String> role) async {
    final prefs = await _prefs();
    await prefs.setString(_kRole, jsonEncode(role));
  }

  @override
  Future<void> clearRole() async {
    final prefs = await _prefs();
    await prefs.remove(_kRole);
  }

  @override
  Future<String?> readInstallId() async {
    if (_installIdLoaded) return _installIdCache;
    final now = DateTime.now().toUtc();
    // Same dismissal law as readEnrollment: the cache is necessarily null
    // here (every write pairs it with loaded), so a cooldown hit means a
    // recent failure with nothing proven — stay dismissed without
    // re-prompting, and crucially must NOT resolve to null here, or
    // getOrCreateInstallId mints a FRESH install over existing data
    // (identity fork: orphaned faceId, phantom device move).
    if (_inSecureCooldown(now)) {
      _lastSecureFailAt = now;
      throw const SecureStoreDismissed();
    }
    await _ensureTierLoaded();
    // Proven-empty install: skip the gated read (same phantom-prompt law
    // as readEnrollment — a missing id mints fresh downstream, so this
    // answers null fast; explicit callers still retry through the store).
    if (_hasInstallHint == false) return null;
    return _behindPromptGate(() => _readInstallIdCold());
  }

  /// Gated install-id scan (one prompt-chain turn — same cache + cooldown
  /// re-check contract as [_readEnrollmentCold], so overlaps cost one
  /// prompt total and never re-prompt a just-dismissed user).
  ///
  /// Unlike enrollment, BOTH slots are always scanned on clean miss: a
  /// null here makes getOrCreateInstallId mint a FRESH install over
  /// existing data (identity fork: orphaned faceId, phantom device move),
  /// which is worse than a second prompt. This path never runs on shell
  /// mount (the resolve reads enrollment only) — it runs in explicit /
  /// setup contexts (claim, enroll restore) where the extra prompt has
  /// user context, so the cost is predictable, never a cold-open ambush.
  Future<String?> _readInstallIdCold() async {
    if (_installIdLoaded) return _installIdCache;
    final now = DateTime.now().toUtc();
    if (_inSecureCooldown(now)) {
      _lastSecureFailAt = now;
      throw const SecureStoreDismissed();
    }
    await _ensureTierLoaded();
    // Both slots always scanned (unlike enrollment auto reads): a clean
    // miss on the preferred slot never stops the scan, or a wiped tier
    // hint resolves to null here and getOrCreateInstallId mints a FRESH
    // install over existing data (identity fork — see above).
    String? v;
    var sawAuthFailure = false;
    FlutterSecureStorage? hitSlot;
    FlutterSecureStorage? missSlot;
    for (final slot in _orderedSlots()) {
      String? got;
      try {
        got = await slot.read(key: _kInstall);
      } catch (e) {
        // Same one-prompt law as the enrollment scan above: a skipped
        // prompt stops here instead of prompting again on the other slot.
        if (_isPromptDismissal(e)) {
          _lastSecureFailAt = DateTime.now().toUtc();
          throw const SecureStoreDismissed();
        }
        if (!_isSecureStoreAuthOrKeyFailure(e)) {
          // Non-auth failure: never a slot signal and never an empty
          // report — resolving null here would make getOrCreateInstallId
          // mint a FRESH install over existing data (identity fork).
          // Throw transient; callers park/retry.
          throw const SecureStoreUnavailable();
        }
        sawAuthFailure = true;
        continue;
      }
      if (got != null) {
        v = got;
        hitSlot = slot;
        break;
      }
      missSlot ??= slot;
    }
    if (v == null && sawAuthFailure) {
      if (missSlot != null) {
        await _adoptTier(identical(missSlot, _fallbackSecure));
      }
      _lastSecureFailAt = now;
      throw const SecureStoreDismissed();
    }
    if (v != null) {
      await _adoptTier(identical(hitSlot, _fallbackSecure));
    }
    // Proven result either way (hit or clean miss): future auto reads
    // skip the prompt when absent. Auth-failure dismissals above leave
    // the hint untouched (unknown, never empty).
    await _noteHasInstall(v != null);
    _installIdCache = v;
    _installIdLoaded = true;
    return v;
  }

  @override
  Future<void> writeInstallId(String id) async {
    await _ensureTierLoaded();
    for (final slot in _orderedSlots()) {
      try {
        await slot.write(key: _kInstall, value: id);
      } catch (e) {
        // Same dismissal law as the enrollment write above: a skipped
        // save prompt stops here instead of prompting again on the
        // other slot.
        if (_isPromptDismissal(e)) throw _secureStorePersistError();
        if (!_isSecureStoreAuthOrKeyFailure(e)) rethrow;
        try {
          await slot.delete(key: _kInstall);
        } catch (_) {}
        continue;
      }
      final usedCred = identical(slot, _fallbackSecure);
      await _adoptTier(usedCred);
      _installIdCache = id;
      _installIdLoaded = true;
      await _noteHasInstall(true);
      return;
    }
    throw _secureStorePersistError();
  }

  @override
  Future<Set<String>> readHiddenSessions() async {
    final prefs = await _prefs();
    return prefs.getStringList(_kHidden)?.toSet() ?? {};
  }

  @override
  Future<void> hideSession(String id) async {
    final prefs = await _prefs();
    final cur = prefs.getStringList(_kHidden)?.toSet() ?? <String>{};
    cur.add(id);
    await prefs.setStringList(_kHidden, cur.toList());
  }

  @override
  Future<void> unhideSession(String id) async {
    final prefs = await _prefs();
    final cur = prefs.getStringList(_kHidden)?.toSet() ?? <String>{};
    cur.remove(id);
    await prefs.setStringList(_kHidden, cur.toList());
  }

  static const _kPendingAdds = 'prox.pendingAdds.v1';
  static const _kPendingSessions = 'prox.pendingSessions.v1';
  static const _kTombstones = 'prox.tombstones.v1';

  @override
  Future<List<Map<String, dynamic>>> readPendingAdds() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_kPendingAdds);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      final out = <Map<String, dynamic>>[];
      for (final e in list) {
        try {
          if (e is Map) out.add(Map<String, dynamic>.from(e));
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> writePendingAdds(List<Map<String, dynamic>> items) async {
    final prefs = await _prefs();
    await prefs.setString(_kPendingAdds, jsonEncode(items));
  }

  Future<List<Map<String, dynamic>>> _readJsonList(String key) async {
    final prefs = await _prefs();
    final raw = prefs.getString(key);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      final out = <Map<String, dynamic>>[];
      for (final e in list) {
        try {
          if (e is Map) out.add(Map<String, dynamic>.from(e));
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  @override
  Future<List<Map<String, dynamic>>> readPendingSessions() =>
      _readJsonList(_kPendingSessions);

  @override
  Future<void> writePendingSessions(
      List<Map<String, dynamic>> items) async {
    final prefs = await _prefs();
    await prefs.setString(_kPendingSessions, jsonEncode(items));
  }

  @override
  Future<List<Map<String, dynamic>>> readTombstones() =>
      _readJsonList(_kTombstones);

  @override
  Future<void> writeTombstones(List<Map<String, dynamic>> items) async {
    final prefs = await _prefs();
    await prefs.setString(_kTombstones, jsonEncode(items));
  }

  @override
  Future<List<ClassRecord>> readStudentSessions() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_kStudentSessions);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      final out = <ClassRecord>[];
      for (final e in list) {
        try {
          if (e is Map) {
            out.add(ClassRecord.fromJson(Map<String, dynamic>.from(e)));
          }
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> writeStudentSessions(List<ClassRecord> records) async {
    final prefs = await _prefs();
    await prefs.setString(_kStudentSessions,
        jsonEncode(records.map((e) => e.toJson()).toList()));
  }

  /// H8 hash backend: intentionally the prefs sidecar (null), never the
  /// biometric-bound secure store. A secure hash read/write costs its own
  /// BiometricPrompt outside the unlock single-flight — on enroll/host
  /// setup it fires alongside (and cancels) the enrollment unlock prompt,
  /// the unpredictable second prompt. The CRL verdict is fail-open
  /// advisory anyway (mismatch forces stale, never blocks marking), so
  /// the prefs sidecar detection suffices; the secure copy is hardening
  /// not worth a prompt fight. Deleted `SecureRevocationHashStore` with
  /// this override (no callers need changing — they already pass this
  /// nullable getter straight into `RevocationCache`).
  @override
  RevocationHashStore? get revocationHashStore => null;

  static const _kProfPins = 'prox.profPins.v1';

  @override
  Future<List<Map<String, dynamic>>> readProfPin(String emailLower) async {
    final prefs = await _prefs();
    final raw = prefs.getString(_kProfPins);
    if (raw == null) return const [];
    try {
      final all = jsonDecode(raw) as Map<String, dynamic>;
      final list = all[emailLower.trim().toLowerCase()];
      if (list is! List) return const [];
      return [
        for (final e in list)
          if (e is Map) Map<String, dynamic>.from(e)
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> writeProfPin(
      String emailLower, List<Map<String, dynamic>> keys) async {
    final prefs = await _prefs();
    Map<String, dynamic> all = {};
    try {
      final raw = prefs.getString(_kProfPins);
      if (raw != null) all = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      all = {};
    }
    all[emailLower.trim().toLowerCase()] =
        [for (final e in keys) Map<String, dynamic>.from(e)];
    await prefs.setString(_kProfPins, jsonEncode(all));
  }

  static const _kStudentKeyPins = 'prox.studentKeyPins.v1';
  static const _kPendingProfVerify = 'prox.pendingProfVerify.v1';

  @override
  Future<Map<String, String>> readStudentKeyPins() async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString(_kStudentKeyPins);
      if (raw == null) return const {};
      final all = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final e in all.entries)
          if (e.value is String &&
              e.key.trim().isNotEmpty &&
              (e.value as String).trim().isNotEmpty)
            e.key.trim().toLowerCase():
                (e.value as String).trim().toLowerCase(),
      };
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<void> writeStudentKeyPins(Map<String, String> pins) async {
    try {
      final prefs = await _prefs();
      await prefs.setString(
          _kStudentKeyPins,
          jsonEncode({
            for (final e in pins.entries)
              if (e.key.trim().isNotEmpty && e.value.trim().isNotEmpty)
                e.key.trim().toLowerCase(): e.value.trim().toLowerCase(),
          }));
    } catch (_) {}
  }

  @override
  Future<Set<String>> readPendingProfVerifications() async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString(_kPendingProfVerify);
      if (raw == null) return const {};
      final list = jsonDecode(raw) as List;
      return {
        for (final e in list)
          if (e is String && e.trim().isNotEmpty) e.trim().toLowerCase(),
      };
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<void> writePendingProfVerifications(Set<String> emails) async {
    try {
      final prefs = await _prefs();
      await prefs.setString(
          _kPendingProfVerify,
          jsonEncode([
            for (final e in emails)
              if (e.trim().isNotEmpty) e.trim().toLowerCase(),
          ]));
    } catch (_) {}
  }
}

