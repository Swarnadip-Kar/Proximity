// S02 RoleHub — the authenticated entry screen.
//
// Purpose: resume, not choose. Shows who is signed in (+ held roles),
// continues last-mode-first with one tap (zero-tap state is the resume
// button), registers the first role or adds the other role on the same
// Gmail, warns on wrong-account (enrolled ≠ signed-in), and offers switch
// account + the Device & identity screen.
//
// Absorbs the signed-in branch of screens/landing.dart (_signedInBody +
// _roleFor + register/continue/stamp/merge): same role-cache seeding
// (fresh-install cloud fallback), same claim-gate verdicts, same web
// guards (no registration, no binding gate on web records builds), same
// copy and button labels so existing flows and widget tests are
// unaffected. All auth/role/cloud decisions live in entry_flow.dart;
// this file owns only the hub UI.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_ble/ble.dart';

import '../../core/auth.dart';
import '../../core/cloud_sync.dart';
import '../../core/host_driver.dart'
    show armProfKeyPublisher, hostDriverProvider;
import '../../design/tokens.dart';
import '../../main.dart';
import '../../mode.dart';
import '../../routes.dart';
import '../../widgets/prox_motion.dart';
import '../../widgets/prox_shimmer.dart';
import '../../widgets/prox_states.dart';
import 'device_identity_screen.dart';
import '../entry/entry_flow.dart';
import 'role_sections.dart';
import 'setup_step_scope.dart';

/// Authenticated role hub. [account] comes from `accountProvider`
/// (proposed: landing router shows this when the stream is non-null).
///
/// Thin composer over the [role_sections] widgets: owns the role-future
/// cache, the busy/status state machine, and the entry_flow calls.
class RoleHubScreen extends ConsumerStatefulWidget {
  final SignedAccount account;
  const RoleHubScreen({super.key, required this.account});

  @override
  ConsumerState<RoleHubScreen> createState() => _RoleHubScreenState();
}

class _RoleHubScreenState extends ConsumerState<RoleHubScreen> {
  String _status = '';
  bool _busy = false;
  final _profNameCtrl = TextEditingController();
  bool _profNameSeeded = false;

  /// Cached role futures per account email: a fresh `future:` every build
  /// refires fetchRole/writeRole on each rebuild — cache by email so
  /// rebuilds reuse it.
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
      if (mounted) {
        setState(() => _status = '$e'.replaceFirst('StateError: ', ''));
      }
      BleLog.log('STATE', 'entry hub action failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _registerProf() => _run(() async {
        await entryRegisterProf(
            ref, () => mounted, widget.account, _profNameCtrl.text);
        // Publish the lecture-key pin at registration itself (when online
        // with a key from an earlier hosting this run — fresh installs log
        // the deferral and publish at first hosting). Best-effort: never
        // throws into the hub status.
        try {
          armProfKeyPublisher(ref);
          await ref.read(hostDriverProvider).publishCurrentProfKey();
        } catch (_) {}
        _refreshRoles();
      });

  Future<void> _registerStudent() => _run(() async {
        // Captured pre-flight: post-await this state may be gone (a mode
        // flip unmounts the flow in fresh-install home).
        final scope = SetupStepScope.of(context);
        await entryRegisterStudent(ref, () => mounted, widget.account);
        _refreshRoles();
        // In-flow: step into the enrollment proper — without this the
        // stepper sits on role after a successful registration and the tap
        // looks dead (same for Continue as student below). Standalone hubs
        // have no scope (no-op); fresh-install home already switched.
        if (mounted && scope != null) {
          try {
            await scope.next();
          } catch (_) {}
        }
      });

  Future<void> _continueWithRole(Map<String, String> role, String which) =>
      _run(() async {
        final scope = SetupStepScope.of(context);
        await entryContinueWithRole(
            ref, () => mounted, widget.account, role, which);
        _refreshRoles();
        // In-flow student continue still needs enrollment (the flow only
        // opens unenrolled): step to device. Professor continues flip the
        // app home — the flow yields via its mode listener (shell path
        // pops to the revealed shell; fresh-install home already
        // switched), so no step here.
        if (mounted && which == 'student' && scope != null) {
          try {
            await scope.next();
          } catch (_) {}
        }
      });

  /// Re-read roles after a successful hub action: the cached future would
  /// otherwise keep showing the pre-action UI (Register buttons after a
  /// successful registration), making every action look dead although the
  /// backend + mode already moved.
  void _refreshRoles() {
    if (!mounted) return;
    _roleFutures.remove(widget.account.email.toLowerCase());
    setState(() {});
  }

  Future<void> _signOut() => _run(() => entrySignOut(ref, () => mounted));

  void _openDeviceIdentity() {
    BleLog.log('NAV', 'entry open device & identity');
    Navigator.of(context).push(
      MaterialPageRoute(
        settings: const RouteSettings(name: ProxRoutes.device),
        builder: (_) => const DeviceIdentityScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final acct = widget.account;
    if (!_profNameSeeded) {
      _profNameCtrl.text = acct.displayName;
      _profNameSeeded = true;
    }
    final linked = ref.watch(linkedIdentityProvider);
    final roleFuture = _roleFutures.putIfAbsent(
        acct.email.toLowerCase(), () => entryRoleFor(ref, acct));
    return AdaptiveScaffold(
      title: 'Proximity',
      // Edge-to-edge landing: resume/register actions clear the system nav
      // bar via live viewPadding (SafeArea bottom-only, mirroring
      // _ShellEdgeBody). Zero hardcoded insets; no-op on desktop/Web.
      body: SafeArea(
        top: false,
        left: false,
        right: false,
        bottom: true,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: FutureBuilder<Map<String, String>?>(
                future: roleFuture,
                builder: (context, snap) {
                final role = snap.data;
                final emailOk = role != null &&
                    (role['email'] ?? '').toLowerCase() ==
                        acct.email.toLowerCase();
                final held = emailOk ? roleSet(role) : const <String>{};
                final hasProf = held.contains('prof');
                final hasStudent = held.contains('student');
                // Last-used mode first — relaunch and return visits
                // default here.
                final ordered = {
                  if (roleLastMode(role) == 'student' && hasStudent) 'student',
                  if (roleLastMode(role) != 'student' && hasProf) 'prof',
                  if (roleLastMode(role) == 'student' && hasProf) 'prof',
                  if (roleLastMode(role) != 'student' && hasStudent) 'student',
                }.toList();
                return ProxStaggered(
                  children: [
                    ProxIdentityHeader(
                        displayName: acct.displayName,
                        email: acct.email,
                        heldLabel: emailOk ? entryHeldLabel(role) : '',
                        photoUrl: acct.photoUrl),
                    if (linked != null &&
                        linked.gmail.toLowerCase() !=
                            acct.email.toLowerCase()) ...[
                      const SizedBox(height: ProxSpacing.sm),
                      ProxErrorNote(
                        'Note: this device is enrolled as ${linked.gmail} — different from the signed-in account. '
                        'Wrong account? Switch below.',
                      ),
                    ],
                    const SizedBox(height: ProxSpacing.lg),
                    if (snap.connectionState == ConnectionState.waiting &&
                        role == null) ...[
                      const ProxShimmerHost(
                        child: Column(
                          children: [
                            ProxShimmerRow(),
                            SizedBox(height: ProxSpacing.sm),
                            ProxShimmerRow(),
                          ],
                        ),
                      ),
                    ] else if (!hasProf && !hasStudent) ...[
                      RoleRegisterSection(
                        profNameCtrl: _profNameCtrl,
                        busy: _busy,
                        onRegisterProf: _registerProf,
                        onRegisterStudent: _registerStudent,
                      ),
                    ] else ...[
                      // `role` is non-null on this branch (`held` is empty
                      // when it is null, which takes the branch above); the
                      // fallback keeps the read null-safe (never `!` on
                      // session/identity state).
                      RoleResumeSection(
                        role: role ?? const <String, String>{},
                        ordered: ordered,
                        lastMode: roleLastMode(role),
                        busy: _busy,
                        onContinue: _continueWithRole,
                      ),
                      RoleAddRoleSection(
                        hasProf: hasProf,
                        hasStudent: hasStudent,
                        busy: _busy,
                        onRegisterProf: _registerProf,
                        onRegisterStudent: _registerStudent,
                      ),
                    ],
                    RoleFooterSection(
                      busy: _busy,
                      status: _status,
                      onDeviceIdentity: _openDeviceIdentity,
                      onSignOut: _signOut,
                    ),
                  ],
                );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
