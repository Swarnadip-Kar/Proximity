// Landing: first page. Common Google sign-in for professors + students,
// skippable for professors (local-only, explained in plain language).
// Students must sign in (one enrolled device per Gmail, enforced online;
// moves to a new phone at most once a week, no reset). Shown only when no
// usable sign-in exists; signed-in users land directly
// in their last-used home. One Gmail can hold BOTH roles and switch freely
// (professor on many devices, student on exactly one — weekly move only).
// Includes wrong-account switching and Professor /
// Student registration with first-sign-in cloud merge for professors.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../main.dart';
import '../mode.dart';
import '../core/auth.dart';
import '../core/cloud_sync.dart';
import '../core/device_identity.dart';
import '../core/device_store.dart';
import '../widgets/web_banner.dart';

class LandingScreen extends ConsumerStatefulWidget {
  const LandingScreen({super.key});

  @override
  ConsumerState<LandingScreen> createState() => _LandingScreenState();
}

class _LandingScreenState extends ConsumerState<LandingScreen> {
  String _status = '';
  bool _busy = false;
  final _profNameCtrl = TextEditingController();
  bool _profNameSeeded = false;

  /// Cached role futures per account email: FutureBuilder with a fresh
  /// `future:` every build refires fetchRole/writeRole on each rebuild
  /// (was `_roleFor(acct)` inline). Cache by email so rebuilds reuse it.
  final Map<String, Future<Map<String, String>?>> _roleFutures = {};

  @override
  void dispose() {
    _profNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() fn) async {
    setState(() {
      _busy = true;
      _status = '';
    });
    try {
      await fn();
    } catch (e) {
      if (mounted) setState(() => _status = '$e'.replaceFirst('StateError: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signIn() => _run(() async {
        final acct = await ref.read(authServiceProvider).signInWithGoogle();
        if (acct == null && mounted) {
          setState(() => _status = 'Sign-in cancelled.');
        }
        // Auth state streams into accountProvider; role step renders next.
      });

  Future<void> _signOut() => _run(() async {
        await ref.read(authServiceProvider).signOut();
        try {
          await ref.read(deviceStoreProvider).clearRole();
        } catch (_) {}
        ref.read(linkedIdentityProvider.notifier).state = null;
        if (mounted) setState(() => _profNameSeeded = false);
      });

  Future<void> _continueOfflineProf() async {
    await setMode(ref, AppMode.prof);
  }

  /// Mode switch that never touches a dead element: async continuations
  /// regularly outlive this screen (the mode flip itself unmounts it
  /// mid-flight — observed as ref.read-after-dispose on macOS), so every
  /// post-await navigation goes through here instead of [setMode].
  Future<void> _goto(AppMode mode) async {
    if (!mounted) return;
    await setMode(ref, mode);
  }

  /// First-sign-in professor merge: pull cloud sessions, union with local
  /// history (newer timestamp wins per id), push local-only sessions up.
  /// Best-effort — offline or failures keep local data untouched.
  Future<void> _mergeProfCloud(String uid, String email, String name) async {
    final cloud = ref.read(cloudSyncProvider);
    final store = ref.read(deviceStoreProvider);
    if (!cloud.available) return;
    var online = false;
    try {
      online = await cloud.isOnline().timeout(const Duration(seconds: 8));
    } catch (_) {
      online = false;
    }
    if (!online) return;
    try {
      final local = await store.readHistory();
      final remote = await cloud.pullProfSessions(uid);
      final merged = mergeHistories(local, remote);
      await store.writeHistory(merged);
      final remoteIds = {for (final r in remote) r.id};
      for (final r in local) {
        if (!remoteIds.contains(r.id)) {
          try {
            await cloud.pushSession(
                profUid: uid, profEmail: email, profName: name, record: r);
          } catch (_) {}
        }
      }
      // Courses referenced by cloud sessions exist locally too.
      for (final r in merged) {
        final course = r.courseId.isNotEmpty ? r.courseId : r.classLabel;
        if (course.isNotEmpty) {
          try {
            await store.addCourse(course);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> _registerProf(SignedAccount acct) => _run(() async {
        final cloud = ref.read(cloudSyncProvider);
        final store = ref.read(deviceStoreProvider);
        final email = acct.email.toLowerCase();
        final uid = acct.uid.isNotEmpty ? acct.uid : email;
        final display = _profNameCtrl.text.trim().isNotEmpty
            ? _profNameCtrl.text.trim()
            : acct.displayName;
        if (!cloud.available || !(await cloud.isOnline())) {
          throw StateError(
              'You appear offline — professor registration needs internet once (to create your cloud backup). You can Continue offline below and register later.');
        }
        // Merge: a Gmail that already holds the student role keeps it.
        await cloud.setRole(RoleDoc(
            uid: uid,
            email: email,
            name: acct.displayName,
            roles: const ['prof'],
            displayName: display,
            lastMode: 'prof'));
        Map<String, String>? prev;
        try {
          prev = await store.readRole();
        } catch (_) {}
        try {
          await store.writeHostName(display);
        } catch (_) {}
        await store.writeRole(mergeRoleCache(prev,
            email: email,
            uid: uid,
            displayName: display,
            addRole: 'prof',
            lastMode: 'prof'));
        await _mergeProfCloud(uid, acct.email, display);
        await _goto(AppMode.prof);
      });

  Future<void> _registerStudent(SignedAccount acct) => _run(() async {
        final cloud = ref.read(cloudSyncProvider);
        final store = ref.read(deviceStoreProvider);
        final email = acct.email.toLowerCase();
        final uid = acct.uid.isNotEmpty ? acct.uid : email;
        if (!cloud.available || !(await cloud.isOnline())) {
          throw StateError(
              'Student registration needs internet (one enrolled device per Gmail is checked online). Connect and try again.');
        }
        // Early device check (same verdict the enroll claim enforces): a
        // Gmail held by another device, or an install enrolled as another
        // Gmail, refuses here with the retry date / next step.
        final installId = await getOrCreateInstallId(store);
        final binding = await cloud.fetchStudentDevice(email);
        String? installEmail;
        try {
          installEmail = await cloud.fetchInstallEmail(installId);
        } catch (_) {}
        String localPk = '';
        try {
          localPk = (await store.readEnrollment())?.pkHex ?? '';
        } catch (_) {}
        final verdict = evaluateStudentClaim(
            localPkHex: localPk,
            localInstallId: installId,
            binding: binding,
            installEmail: installEmail,
            email: email);
        if (!verdict.ok) {
          throw StateError(studentClaimMessage(verdict, binding));
        }
        // Merge: a Gmail that already holds the professor role keeps it.
        await cloud.setRole(RoleDoc(
            uid: uid,
            email: email,
            name: acct.displayName,
            roles: const ['student'],
            displayName: '',
            lastMode: 'student'));
        Map<String, String>? prev;
        try {
          prev = await store.readRole();
        } catch (_) {}
        await store.writeRole(mergeRoleCache(prev,
            email: email, uid: uid, addRole: 'student', lastMode: 'student'));
        await _goto(AppMode.student);
        // Enrollment (face + ID) happens in the student home when needed;
        // already-enrolled devices go straight to joining classes.
      });

  /// Stamps the last-used mode locally + on the cloud role doc (best
  /// effort), so relaunch and other devices default to it.
  Future<void> _stampLastMode(
      SignedAccount acct, Map<String, String> role, String which) async {
    final email = acct.email.toLowerCase();
    final uid = (role['uid'] ?? '').isNotEmpty
        ? role['uid']!
        : (acct.uid.isNotEmpty ? acct.uid : email);
    final merged = mergeRoleCache(role,
        email: email,
        uid: uid,
        displayName: role['displayName'] ?? '',
        lastMode: which);
    try {
      await ref.read(deviceStoreProvider).writeRole(merged);
    } catch (_) {}
    // Best-effort cloud stamp: never touch providers after an async gap
    // on a dead screen (ref.read-after-dispose crash class).
    if (!mounted) return;
    try {
      final cloud = ref.read(cloudSyncProvider);
      if (cloud.available && await cloud.isOnline()) {
        await cloud.setRole(RoleDoc(
            uid: uid,
            email: email,
            name: acct.displayName,
            roles: roleSet(merged).toList(),
            displayName: merged['displayName'] ?? '',
            lastMode: which));
      }
    } catch (_) {}
  }

  Future<void> _continueWithRole(
      SignedAccount acct, Map<String, String> role, String which) async {
    if (which == 'prof') {
      unawaited(_mergeProfCloud(
          (role['uid'] ?? '').isNotEmpty
              ? role['uid']!
              : acct.email.toLowerCase(),
          acct.email,
          role['displayName'] ?? acct.displayName));
      await _stampLastMode(acct, role, 'prof');
      await _goto(AppMode.prof);
    } else {
      // Web records builds hold no key and mark nothing: skip the device
      // binding gate (this install is never the enrolled device, so the
      // check would refuse legit students) and land straight on records.
      // Student registration stays native-only.
      if (kIsWeb) {
        await _stampLastMode(acct, role, 'student');
        await _goto(AppMode.student);
        return;
      }
      // Re-sign-in binding check: enrollment moved to another device?
      // Same verdict as the enroll claim; also heartbeats last-online so a
      // lost-phone story shows recency.
      await _run(() async {
        final cloud = ref.read(cloudSyncProvider);
        final store = ref.read(deviceStoreProvider);
        final email = acct.email.toLowerCase();
        if (cloud.available && await cloud.isOnline()) {
          final installId = await getOrCreateInstallId(store);
          final binding = await cloud.fetchStudentDevice(email);
          String? installEmail;
          try {
            installEmail = await cloud.fetchInstallEmail(installId);
          } catch (_) {}
          String localPk = '';
          try {
            localPk = (await store.readEnrollment())?.pkHex ?? '';
          } catch (_) {}
          final verdict = evaluateStudentClaim(
              localPkHex: localPk,
              localInstallId: installId,
              binding: binding,
              installEmail: installEmail,
              email: email);
          if (!verdict.ok) {
            throw StateError(studentClaimMessage(verdict, binding));
          }
          try {
            await cloud.touchStudentDevice(
                emailLower: email, pkHex: localPk, installId: installId);
          } catch (_) {}
        }
        await _stampLastMode(acct, role, 'student');
        await _goto(AppMode.student);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final accountAsync = ref.watch(accountProvider);
    final linked = ref.watch(linkedIdentityProvider);
    return AdaptiveScaffold(
      title: 'Proximity',
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: accountAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => _signedOutBody(null, 'Sign-in state unreadable: $e'),
              data: (acct) {
                if (acct == null) return _signedOutBody(null, '');
                return _signedInBody(acct, linked);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _signedOutBody(SignedAccount? acct, String extra) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const WebRecordsBanner(),
        Text('Campus Attendance',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        const Text(
          'One sign-in for everyone. Students must sign in — each Gmail can '
          'hold only one enrolled student device (checked online). Professors '
          'may skip: classes then stay on this device only until you sign in '
          'and sync.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          icon: const Icon(Icons.login),
          label: const Text('Sign in with Google'),
          onPressed: _busy ? null : _signIn,
        ),
        // No offline hosting on web records builds (no BLE/HTTPS there).
        if (!kIsWeb) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.present_to_all),
            label: const Text('Continue as Professor offline'),
            onPressed: _busy ? null : _continueOfflineProf,
          ),
          const SizedBox(height: 4),
          const Text(
            'Offline professors keep everything on this device. Sign in later '
            'to back up, sync across devices, and share CSVs from the cloud.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ],
        if (_status.isNotEmpty || extra.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(_status.isNotEmpty ? _status : extra,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        if (_busy) ...[
          const SizedBox(height: 12),
          const Center(child: CircularProgressIndicator()),
        ],
      ],
    );
  }

  /// Local role cache for [acct], seeded from the cloud users doc when this
  /// install has none (fresh install / signed back in after a switch).
  Future<Map<String, String>?> _roleFor(SignedAccount acct) async {
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
      return cache;
    }
    try {
      final cloud = ref.read(cloudSyncProvider);
      if (cloud.available && await cloud.isOnline()) {
        final remote = await cloud.fetchRole(uid);
        if (remote != null && remote.roles.isNotEmpty) {
          var merged =
              mergeRoleCache(cache, email: email, uid: uid);
          for (final r in remote.roles) {
            merged = mergeRoleCache(merged,
                email: email, uid: uid, addRole: r);
          }
          merged = mergeRoleCache(merged,
              email: email,
              uid: uid,
              displayName: remote.displayName,
              lastMode: remote.lastMode);
          await store.writeRole(merged);
          return merged;
        }
      }
    } catch (_) {}
    return cache;
  }

  String _heldLabel(Map<String, String> role) {
    final set = roleSet(role);
    final parts = <String>[];
    if (set.contains('prof')) {
      final d = (role['displayName'] ?? '').trim();
      parts.add(d.isNotEmpty ? 'Professor ($d)' : 'Professor');
    }
    if (set.contains('student')) parts.add('Student');
    return parts.join(' + ');
  }

  Widget _signedInBody(SignedAccount acct, LinkedIdentity? linked) {
    if (!_profNameSeeded) {
      _profNameCtrl.text = acct.displayName;
      _profNameSeeded = true;
    }
    final roleFuture = _roleFutures.putIfAbsent(
        acct.email.toLowerCase(), () => _roleFor(acct));
    return FutureBuilder<Map<String, String>?>(
      future: roleFuture,
      builder: (context, snap) {
        final role = snap.data;
        final emailOk = role != null &&
            (role['email'] ?? '').toLowerCase() ==
                acct.email.toLowerCase();
        final held = emailOk ? roleSet(role) : const <String>{};
        final hasProf = held.contains('prof');
        final hasStudent = held.contains('student');
        // Last-used mode first — relaunch and return visits default here.
        final ordered = {
          if (roleLastMode(role) == 'student' && hasStudent) 'student',
          if (roleLastMode(role) != 'student' && hasProf) 'prof',
          if (roleLastMode(role) == 'student' && hasProf) 'prof',
          if (roleLastMode(role) != 'student' && hasStudent) 'student',
        }.toList();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Signed in as ${acct.displayName}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge),
            Text(acct.email,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium),
            if (linked != null && linked.gmail.toLowerCase() != acct.email.toLowerCase()) ...[
              const SizedBox(height: 8),
              Text(
                'Note: this device is enrolled as ${linked.gmail} — different from the signed-in account. '
                'Wrong account? Switch below.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            if (snap.connectionState == ConnectionState.waiting &&
                role == null) ...[
              const Center(child: CircularProgressIndicator()),
            ] else if (!hasProf && !hasStudent) ...[
              // Web records builds register nothing (no enrollment/hosting
              // there): roles arrive from the cloud seed above, registered
              // on the native app.
              if (kIsWeb) ...[
                const WebRecordsBanner(),
                const SizedBox(height: 8),
                const Text(
                  'This sign-in holds no Proximity role yet. Register once '
                  'in the native app, then return here to view records.',
                  textAlign: TextAlign.center,
                ),
              ] else ...[
                const Text(
                  'Register this sign-in (once per account):',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _profNameCtrl,
                  decoration: const InputDecoration(
                    labelText:
                        'Professor display name (for Register as Professor)',
                    helperText: 'Gmail name is the default; shown to students.',
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  icon: const Icon(Icons.present_to_all),
                  label: const Text('Register as Professor'),
                  onPressed: _busy ? null : () => _registerProf(acct),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  icon: const Icon(Icons.school),
                  label: const Text('Register as Student'),
                  onPressed: _busy ? null : () => _registerStudent(acct),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Same Gmail can hold both roles — switch anytime. Professor '
                  'works on many devices; student enrollment lives on exactly '
                  'one device (moves to a new phone once a week).',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ] else ...[
              Text(
                'Registered as ${_heldLabel(role!)}.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              for (final which in ordered) ...[
                FilledButton.icon(
                  icon: Icon(which == 'prof'
                      ? Icons.present_to_all
                      : Icons.school),
                  label: Text(which == 'prof'
                      ? 'Continue as Professor'
                      : 'Continue as Student'),
                  onPressed: _busy
                      ? null
                      : () => _continueWithRole(acct, role, which),
                ),
                const SizedBox(height: 8),
              ],
              // No extra registration on web records builds.
              if (!kIsWeb && (!hasProf || !hasStudent)) ...[
                const Text(
                  'Add the other role on this same sign-in:',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                if (!hasProf)
                  FilledButton.icon(
                    icon: const Icon(Icons.present_to_all),
                    label: const Text('Register as Professor'),
                    onPressed: _busy ? null : () => _registerProf(acct),
                  ),
                if (!hasStudent)
                  FilledButton.icon(
                    icon: const Icon(Icons.school),
                    label: const Text('Register as Student'),
                    onPressed: _busy ? null : () => _registerStudent(acct),
                  ),
                const SizedBox(height: 4),
                const Text(
                  'Professor works on many devices; student enrollment lives '
                  'on exactly one device — it can move to a new phone once '
                  'a week (unlimited times).',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ],
              if (hasProf && !kIsWeb) ...[
                const SizedBox(height: 8),
                const Divider(),
                const Text(
                  'A student who lost their phone waits out the week for '
                  're-enrollment — meanwhile mark them manually from the '
                  'take-attendance screen (Request manual attendance or '
                  'direct entry). No reset shortcut exists by design.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ],
            const SizedBox(height: 8),
            TextButton.icon(
              icon: const Icon(Icons.switch_account),
              label: const Text('Switch account (sign out)'),
              onPressed: _busy ? null : _signOut,
            ),
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_status,
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            if (_busy) ...[
              const SizedBox(height: 8),
              const Center(child: CircularProgressIndicator()),
            ],
          ],
        );
      },
    );
  }
}
