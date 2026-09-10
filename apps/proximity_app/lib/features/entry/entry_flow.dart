// Entry bundle shared flow: auth / role / nav decisions for the landing
// split (S01 Welcome, S02 RoleHub, S03 DeviceIdentity).
//
// Behavioral law (mirrors screens/landing.dart exactly — this file only
// relocates it so the three single-purpose screens share one
// implementation instead of triplicating security-sensitive logic):
// - one Gmail holds BOTH roles (prof multi-device, student single-device);
// - lastMode is stamped locally + on the cloud role doc, best effort;
// - student web builds skip the device binding gate and land on records;
// - offline professors stay local-only (no sign-in, no cloud);
// - sign-out clears the role cache + linked identity, so account switches
//   land on the entry screens, never someone else's home;
// - every post-await mode switch goes through [entryGoto], which is
//   mounted-guarded (the mode flip unmounts the caller mid-flight).
//
// Auth/role/nav decisions log via BleLog NAV/STATE (visible in the system
// log + `adb logcat`, same as the BLE/LAN/SEC tags).
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';

import '../../core/auth.dart';
import '../../core/cloud_sync.dart';
import '../../core/device_store.dart';
import '../../core/enrollment.dart';
import '../../core/sync_hook.dart';
import '../../mode.dart';

/// Mounted check from the calling State. Every helper that awaits and then
/// touches providers or navigates takes one — reading a provider after
/// dispose is the crash class this guards (seen on macOS).
typedef EntryMounted = bool Function();

/// Mounted-guarded mode switch. The mode flip itself unmounts the caller
/// mid-flight, so a bare `setMode` after an await is a
/// ref-read-after-dispose crash — all entry navigation goes through here.
Future<void> entryGoto(
    WidgetRef ref, EntryMounted isMounted, AppMode mode) async {
  if (!isMounted()) return;
  BleLog.log('NAV', 'entry → ${mode.name}');
  await setMode(ref, mode);
}

/// Google sign-in. Returns null when the user aborts (popup closed / back).
/// Throws StateError with actionable copy on platform failures.
Future<SignedAccount?> entrySignIn(WidgetRef ref) async {
  BleLog.log('NAV', 'entry sign-in requested');
  final acct = await ref.read(authServiceProvider).signInWithGoogle();
  if (acct == null) {
    BleLog.log('NAV', 'entry sign-in cancelled');
  } else {
    BleLog.log('NAV', 'entry sign-in ok ${acct.email.toLowerCase()}');
    // Enrolled returner, no restart: restore the startup-preseed identity
    // (same-Gmail match, fail-soft) so the Mark gate + join gate see the
    // enrollment instead of routing into setup. Never throws (helper).
    await relinkLinkedIdentity(ref, acct);
  }
  return acct;
}

/// Sign-out: auth session + role cache + linked identity + enrollment
/// draft all go, so the next launch (or the account stream) lands on
/// Welcome — never on the previous account's home, and the enroll card
/// can never rebuild from a stale preseed.
Future<void> entrySignOut(WidgetRef ref) async {
  String email = '';
  try {
    email = ref.read(authServiceProvider).current?.email.toLowerCase() ?? '';
  } catch (_) {}
  BleLog.log('NAV', 'entry sign out${email.isNotEmpty ? ' $email' : ''}');
  await ref.read(authServiceProvider).signOut();
  try {
    await ref.read(deviceStoreProvider).clearRole();
  } catch (_) {}
  // Enrollment draft holds its own cached identity (preseed/account +
  // roll + key + face): reconcile to the now-null session so a later
  // sign-in as another Gmail starts clean.
  try {
    await ref.read(enrollmentControllerProvider.notifier).refreshFromAuth();
  } catch (_) {}
  // Post-await provider touch: never throw on a dead screen.
  try {
    ref.read(linkedIdentityProvider.notifier).state = null;
  } catch (_) {}
  BleLog.log('STATE', 'entry role cache cleared; landing next');
}

/// Repopulate [linkedIdentityProvider] from the on-device enrollment when
/// it belongs to [acct] (same Gmail, case-insensitive).
///
/// Mirrors the startup preseed rule in `main.dart` (`initialLinked`, ~line
/// 168) field-by-field — `LinkedIdentity(name: stored.name,
/// gmail: stored.email, roll: stored.roll, org: stored.org)` — so a
/// re-sign-in restores exactly what a restart would have preseeded from
/// the same enrollment doc. Fail-soft throughout: a store read throw, an
/// empty store, an empty account email, or a Gmail mismatch leaves state
/// untouched (today's behavior; the setup flow handles it). No
/// heartbeat/touch call here — no network-semantics change. Never throws
/// (a post-await provider touch on a dead screen is swallowed, same as
/// [entrySignOut]'s clearing touch).
Future<void> relinkLinkedIdentity(WidgetRef ref, SignedAccount acct) async {
  try {
    StoredEnrollment? stored;
    try {
      stored = await ref.read(deviceStoreProvider).readEnrollment();
    } catch (_) {
      stored = null;
    }
    if (stored == null) return;
    final want = acct.email.toLowerCase();
    if (want.isEmpty) return;
    if (stored.email.toLowerCase() != want) return;
    final linked = LinkedIdentity(
        name: stored.name,
        gmail: stored.email,
        roll: stored.roll,
        org: stored.org);
    try {
      ref.read(linkedIdentityProvider.notifier).state = linked;
    } catch (_) {}
    BleLog.log('STATE', 'entry relink $want');
  } catch (_) {}
}

/// Offline-professor path: no sign-in, no cloud — classes stay on this
/// device only until sign-in + sync. Hidden on web (no offline hosting on
/// web records builds).
Future<void> entryContinueOfflineProf(
    WidgetRef ref, EntryMounted isMounted) async {
  BleLog.log('NAV', 'entry continue offline professor (local-only)');
  await entryGoto(ref, isMounted, AppMode.prof);
}

/// Local role cache for [acct], seeded from the cloud users doc when this
/// install has none (fresh install / signed back in after a switch).
Future<Map<String, String>?> entryRoleFor(
    WidgetRef ref, SignedAccount acct) async {
  final store = ref.read(deviceStoreProvider);
  final email = acct.email.toLowerCase();
  final uid = acct.uid.isNotEmpty ? acct.uid : email;
  Map<String, String>? cache;
  try {
    cache = await store.readRole();
  } catch (_) {}
  if (cache != null &&
      (cache['email'] ?? '').toLowerCase() == email &&
      roleSet(cache).isNotEmpty) {
    BleLog.log('STATE',
        'entry roles cache hit $email: ${roleSet(cache).join('+')} lastMode=${roleLastMode(cache)}');
    return cache;
  }
  try {
    final cloud = ref.read(cloudSyncProvider);
    if (cloud.available && await cloud.isOnline()) {
      final remote = await cloud.fetchRole(uid);
      if (remote != null && remote.roles.isNotEmpty) {
        var merged = mergeRoleCache(cache,
            email: email, uid: uid, org: acct.org);
        for (final r in remote.roles) {
          merged =
              mergeRoleCache(merged, email: email, uid: uid, addRole: r);
        }
        merged = mergeRoleCache(merged,
            email: email,
            uid: uid,
            displayName: remote.displayName,
            lastMode: remote.lastMode,
            org: remote.org.isNotEmpty ? remote.org : acct.org);
        await store.writeRole(merged);
        BleLog.log('STATE',
            'entry roles seeded from cloud $email: ${roleSet(merged).join('+')} lastMode=${roleLastMode(merged)}');
        // Owner-lazy six-month purge (no backend): the users doc itself is
        // this stale, so best-effort delete own user data (rules re-gate on
        // server time; never throws past this point — the seed above stands).
        if (stampOlderThan(
            stampMillis: remote.updatedAtMillis,
            now: DateTime.now().toUtc(),
            age: kStudentPurgeStale)) {
          try {
            await cloud.purgeExpiredSelfData(emailLower: email, uid: uid);
          } catch (_) {}
        }
        return merged;
      }
    }
  } catch (_) {}
  BleLog.log('STATE', 'entry roles miss $email (register once per account)');
  return cache;
}

/// "Professor (Name) + Student" label for the identity header.
String entryHeldLabel(Map<String, String> role) {
  final set = roleSet(role);
  final parts = <String>[];
  if (set.contains('prof')) {
    final d = (role['displayName'] ?? '').trim();
    parts.add(d.isNotEmpty ? 'Professor ($d)' : 'Professor');
  }
  if (set.contains('student')) parts.add('Student');
  return parts.join(' + ');
}

/// First-sign-in professor merge: SyncEngine flush (outbox pushes +
/// pull-union converge + legacy org backfill). Best-effort — offline or
/// failures keep local data untouched. Delegates to [flushNow]: the
/// explicit params match what [readSyncProf] derives (callers stamp the
/// cache first), so the flush identity is unchanged.
Future<void> entryMergeProfCloud(
    WidgetRef ref, String uid, String email, String name,
    {String org = ''}) async {
  try {
    final res = await flushNow(ref);
    BleLog.log('STATE',
        'entry prof cloud merged (${res.pushed} pushed, ${res.remaining} remaining)');
  } catch (_) {}
}

/// Register the signed-in Gmail as professor. Merge semantics: a Gmail
/// that already holds the student role keeps it.
Future<void> entryRegisterProf(WidgetRef ref, EntryMounted isMounted,
    SignedAccount acct, String displayName) async {
  final email = acct.email.toLowerCase();
  BleLog.log('NAV', 'entry register prof $email');
  final cloud = ref.read(cloudSyncProvider);
  final store = ref.read(deviceStoreProvider);
  final uid = acct.uid.isNotEmpty ? acct.uid : email;
  final display =
      displayName.trim().isNotEmpty ? displayName.trim() : acct.displayName;
  if (!cloud.available || !(await cloud.isOnline())) {
    throw StateError(
        'You appear offline — professor registration needs internet once (to create your cloud backup). You can Continue offline below and register later.');
  }
  await cloud.setRole(RoleDoc(
      uid: uid,
      email: email,
      name: acct.displayName,
      roles: const ['prof'],
      displayName: display,
      lastMode: 'prof',
      org: acct.org));
  Map<String, String>? prev;
  try {
    prev = await store.readRole();
  } catch (_) {}
  try {
    await store.writeHostName(display);
  } catch (_) {}
  final merged = mergeRoleCache(prev,
      email: email,
      uid: uid,
      displayName: display,
      addRole: 'prof',
      lastMode: 'prof',
      org: acct.org);
  await store.writeRole(merged);
  BleLog.log('STATE',
      'entry roles now ${roleSet(merged).join('+')} lastMode=prof');
  await entryMergeProfCloud(ref, uid, acct.email, display, org: acct.org);
  await entryGoto(ref, isMounted, AppMode.prof);
}

/// Outcome of the student device-binding pre-check: the same verdict the
/// enroll claim enforces, so the entry screens refuse for exactly the
/// reasons the server refuses.
class StudentGate {
  final StudentClaimResult verdict;
  final StudentDeviceDoc? binding;
  final String installId;
  final String localPkHex;
  const StudentGate(
      {required this.verdict,
      required this.binding,
      required this.installId,
      required this.localPkHex});
}

/// Fetches this install's identity + the Gmail binding and evaluates the
/// claim. Caller must have established online + cloud availability (the
/// gate reads the server); throws only on unexpected failures, which
/// callers treat as "unknown — stay put".
Future<StudentGate> entryStudentGate(WidgetRef ref, String email) async {
  final lower = email.toLowerCase();
  final cloud = ref.read(cloudSyncProvider);
  final store = ref.read(deviceStoreProvider);
  final installId = await getOrCreateInstallId(store);
  final binding = await cloud.fetchStudentDevice(lower);
  // Scoped install-read denial (verdict-by-evidence, same rule as the
  // enroll pre-claim): a denied install-doc read after a clean own-doc
  // read proves the install holds another Gmail — the rules deny
  // cross-org install reads while a missing own doc reads clean. A bare
  // null here used to misread that as "free to enroll"; an
  // installConflict verdict refuses with the friendly copy instead.
  // Other install-read failures stay null ("unknown", as before).
  String? installEmail;
  var installDenied = false;
  try {
    installEmail = await cloud.fetchInstallEmail(installId);
  } on StateError catch (e) {
    if (isRulesDenialMessage(e.message)) installDenied = true;
  } catch (_) {}
  String localPk = '';
  try {
    localPk = (await store.readEnrollment())?.pkHex ?? '';
  } catch (_) {}
  final probed = evaluateStudentClaim(
      localPkHex: localPk,
      localInstallId: installId,
      binding: binding,
      installEmail: installEmail,
      email: lower);
  final verdict = installDenied && probed.ok
      ? const StudentClaimResult(StudentClaim.installConflict)
      : probed;
  BleLog.log('STATE', 'entry claim gate $lower → ${verdict.claim.name}');
  // Owner-lazy six-month purge (no backend): a binding this stale is
  // already purge-eligible, so best-effort delete own user data now (rules
  // re-gate every delete on server time). Zero extra reads on the live
  // path: the binding fetched above is the pre-check.
  if (binding != null &&
      stampOlderThan(
          stampMillis: binding.lastSeenAtMillis,
          now: DateTime.now().toUtc(),
          age: kStudentPurgeStale)) {
    try {
      String uid = '';
      try {
        uid = ref.read(authServiceProvider).current?.uid ?? '';
      } catch (_) {}
      await cloud.purgeExpiredSelfData(emailLower: lower, uid: uid);
    } catch (_) {}
  }
  return StudentGate(
      verdict: verdict,
      binding: binding,
      installId: installId,
      localPkHex: localPk);
}

/// Register the signed-in Gmail as student. Merge semantics: a Gmail that
/// already holds the professor role keeps it. Enrollment (face + ID)
/// happens in the student home when needed.
Future<void> entryRegisterStudent(
    WidgetRef ref, EntryMounted isMounted, SignedAccount acct) async {
  final email = acct.email.toLowerCase();
  BleLog.log('NAV', 'entry register student $email');
  final cloud = ref.read(cloudSyncProvider);
  final store = ref.read(deviceStoreProvider);
  final uid = acct.uid.isNotEmpty ? acct.uid : email;
  if (!cloud.available || !(await cloud.isOnline())) {
    throw StateError(
        'Student registration needs internet (one enrolled device per Gmail is checked online). Connect and try again.');
  }
  // Early device check (same verdict the enroll claim enforces): a Gmail
  // held by another device, or an install enrolled as another Gmail,
  // refuses here with the retry date / next step.
  final gate = await entryStudentGate(ref, email);
  if (!gate.verdict.ok) {
    throw StateError(studentClaimMessage(gate.verdict, gate.binding));
  }
  await cloud.setRole(RoleDoc(
      uid: uid,
      email: email,
      name: acct.displayName,
      roles: const ['student'],
      displayName: '',
      lastMode: 'student',
      org: acct.org));
  Map<String, String>? prev;
  try {
    prev = await store.readRole();
  } catch (_) {}
  final merged = mergeRoleCache(prev,
      email: email,
      uid: uid,
      addRole: 'student',
      lastMode: 'student',
      org: acct.org);
  await store.writeRole(merged);
  BleLog.log('STATE',
      'entry roles now ${roleSet(merged).join('+')} lastMode=student');
  await entryGoto(ref, isMounted, AppMode.student);
}

/// Stamps the last-used mode locally + on the cloud role doc (best
/// effort), so relaunch and other devices default to it.
Future<void> entryStampLastMode(WidgetRef ref, EntryMounted isMounted,
    SignedAccount acct, Map<String, String> role, String which) async {
  final email = acct.email.toLowerCase();
  final uid = (role['uid'] ?? '').isNotEmpty
      ? role['uid']!
      : (acct.uid.isNotEmpty ? acct.uid : email);
  final org = acct.org.isNotEmpty ? acct.org : (role['org'] ?? '');
  final merged = mergeRoleCache(role,
      email: email,
      uid: uid,
      displayName: role['displayName'] ?? '',
      lastMode: which,
      org: org);
  try {
    await ref.read(deviceStoreProvider).writeRole(merged);
  } catch (_) {}
  BleLog.log('STATE', 'entry lastMode=$which $email');
  // Best-effort cloud stamp: never touch providers after an async gap on
  // a dead screen (ref.read-after-dispose crash class).
  if (!isMounted()) return;
  try {
    final cloud = ref.read(cloudSyncProvider);
    if (cloud.available && await cloud.isOnline()) {
      await cloud.setRole(RoleDoc(
          uid: uid,
          email: email,
          name: acct.displayName,
          roles: roleSet(merged).toList(),
          displayName: merged['displayName'] ?? '',
          lastMode: which,
          org: org));
    }
  } catch (_) {}
}

/// Continue into a held role. Returns a plain message when the continue
/// itself must run under the caller's busy wrapper (student re-sign-in
/// binding check); prof continues directly.
Future<void> entryContinueWithRole(WidgetRef ref, EntryMounted isMounted,
    SignedAccount acct, Map<String, String> role, String which) async {
  BleLog.log(
      'NAV', 'entry continue $which ${acct.email.toLowerCase()}');
  // Silent-pickup path (no fresh sign-in ran): restore the
  // startup-preseed identity before branching so the Mark/join gates see
  // the enrollment. Mounted-guarded per this file's law; never throws
  // (helper).
  if (isMounted()) {
    await relinkLinkedIdentity(ref, acct);
  }
  if (which == 'prof') {
    unawaited(entryMergeProfCloud(
        ref,
        (role['uid'] ?? '').isNotEmpty
            ? role['uid']!
            : acct.email.toLowerCase(),
        acct.email,
        role['displayName'] ?? acct.displayName,
        org: acct.org.isNotEmpty ? acct.org : (role['org'] ?? '')));
    await entryStampLastMode(ref, isMounted, acct, role, 'prof');
    await entryGoto(ref, isMounted, AppMode.prof);
    return;
  }
  // Web records builds hold no key and mark nothing: skip the device
  // binding gate (this install is never the enrolled device, so the check
  // would refuse legit students) and land straight on records. Student
  // registration stays native-only.
  if (kIsWeb) {
    BleLog.log('STATE', 'entry web records: binding gate skipped');
    await entryStampLastMode(ref, isMounted, acct, role, 'student');
    await entryGoto(ref, isMounted, AppMode.student);
    return;
  }
  // Re-sign-in binding check: enrollment moved to another device? Same
  // verdict as the enroll claim; also heartbeats last-online so a
  // lost-phone story shows recency.
  final cloud = ref.read(cloudSyncProvider);
  final email = acct.email.toLowerCase();
  if (cloud.available && await cloud.isOnline()) {
    final gate = await entryStudentGate(ref, email);
    if (!gate.verdict.ok) {
      BleLog.log('STATE', 'entry continue refused: ${gate.verdict.claim.name}');
      throw StateError(studentClaimMessage(gate.verdict, gate.binding));
    }
    try {
      await cloud.touchStudentDevice(
          emailLower: email,
          pkHex: gate.localPkHex,
          installId: gate.installId);
    } catch (_) {}
  }
  await entryStampLastMode(ref, isMounted, acct, role, 'student');
  await entryGoto(ref, isMounted, AppMode.student);
}
