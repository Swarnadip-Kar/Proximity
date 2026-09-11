//
// Account shared helpers (compact menu + sub-pages).
// Owns: the label+value row, the local enrollment + move-gate reads, the
// enroll-entry push + fallback-sheet body, the per-account scoping helpers
// (`enrolledForAccount` / `storedForAccount` / linked roll+org), and the
// short-key formatter. Sections import from here; the thin page composes
// sections. Frozen copy/timing/threshold/network contracts untouched.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth.dart';
import '../../core/cloud_sync.dart';
import '../../core/device_store.dart';
import '../../core/platformx.dart';
import '../../design/tokens.dart';
import '../../mode.dart';
import '../entry/entry_flow.dart';

/// Label + value row. Values truncate (never wrap a card open); full IDs
/// use [mono] for the short-code-string face (§2.2) with soft-wrap.
class AccountFactRow extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;

  const AccountFactRow(this.label, this.value, {super.key, this.mono = false});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: ProxSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: ProxType.label(color: c.contentSecondary),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
          const SizedBox(height: ProxSpacing.xs),
          Text(
            value,
            style: mono
                ? ProxType.monoBody(color: c.contentPrimary)
                : ProxType.body(color: c.contentPrimary),
            softWrap: true,
          ),
        ],
      ),
    );
  }
}

/// Local enrollment read. Never throws (null = none on file).
Future<StoredEnrollment?> readAccountEnrollment(WidgetRef ref) async {
  try {
    return await ref.read(deviceStoreProvider).readEnrollment();
  } catch (_) {
    return null;
  }
}

/// Move status for the signed-in Gmail, or null when it cannot be
/// determined (offline / unavailable / signed out). Same online-gated,
/// never-stale read the pre-auth device screen uses — never a stale
/// verdict. Never throws.
Future<StudentGate?> moveGateForAccount(WidgetRef ref, String? email) async {
  if (email == null || email.isEmpty || !canUseFace()) return null;
  try {
    final cloud = ref.read(cloudSyncProvider);
    if (!cloud.available || !(await cloud.isOnline())) return null;
    return await entryStudentGate(ref, email);
  } catch (_) {
    return null;
  }
}

/// True when the device counts as enrolled for [acct]: the linked-identity
/// Gmail or the stored-enrollment email matches the signed-in account
/// the bare presence of any stored enrollment — drives every enroll entry
/// point on this page. Enrolled ⇒ the page shows state and offers no
/// enroll CTA; re-scan stays on the face-id sub-page only.
bool enrolledForAccount(
    SignedAccount acct, LinkedIdentity? linked, StoredEnrollment? stored) {
  final want = acct.email.trim().toLowerCase();
  if (want.isEmpty) return false;
  if (linked != null && linked.gmail.trim().toLowerCase() == want) return true;
  return stored != null && stored.email.trim().toLowerCase() == want;
}

/// The stored enrollment, but only when filed under the CURRENT signed-in
/// the device-store enrollment, so a previous account's enrollment
/// lingering in the store must never render as this account's facts.
StoredEnrollment? storedForAccount(SignedAccount acct, StoredEnrollment? e) {
  if (e == null) return null;
  return e.email.trim().toLowerCase() == acct.email.trim().toLowerCase()
      ? e
      : null;
}

/// The linked-identity roll, but only when bound to the CURRENT signed-in
/// Gmail (same stale-account rule as [storedForAccount]).
String linkedRollForAccount(SignedAccount acct, LinkedIdentity? linked) {
  if (linked == null) return '';
  return linked.gmail.trim().toLowerCase() ==
          acct.email.trim().toLowerCase()
      ? linked.roll
      : '';
}

/// The linked-identity org, but only when bound to the CURRENT signed-in
/// Gmail (same stale-account rule as [storedForAccount]).
String linkedOrgForAccount(SignedAccount acct, LinkedIdentity? linked) {
  if (linked == null) return '';
  return linked.gmail.trim().toLowerCase() ==
          acct.email.trim().toLowerCase()
      ? linked.org
      : '';
}

/// Dismisses the root setup-flow FIRST (product decision): when the
/// shell auto-pushed `SetupFlowScreen` (route name `setup-flow`) on the
/// root navigator is open during an account/mode switch, it is popped
/// before the switch proceeds — the switch must never land underneath an
/// open flow holding the previous identity. No-op when no flow is open
/// (plain tab roots, landing, widget tests). Never throws.
void dismissSetupFlowFirst(BuildContext context) {
  try {
    Navigator.of(context, rootNavigator: true).popUntil(
        (route) => route.isFirst || route.settings.name != 'setup-flow');
  } catch (_) {}
}

/// Pops the current per-tab Navigator to its root, so stale-account
/// screens pushed above it (other identity's enrollment/device/face-id
/// pages) can never survive an account/mode transition underneath.
/// Call BEFORE `entrySignOut`/`setMode`: after the sign-out the account
/// stream nulls and the tab root rebuilds, but pushed routes above would
/// still show the previous identity. No-op at a tab root. Never throws.
void popTabToRoot(BuildContext context) {
  try {
    Navigator.of(context).popUntil((route) => route.isFirst);
  } catch (_) {}
}

/// Full account/mode-transition reset: dismiss the root setup-flow first
/// (product decision), then pop the current tab stack to root. Every
/// switch/sign-out call site with a `BuildContext` runs this BEFORE
/// `entrySignOut`/`setMode(unset)` — synchronous, so no mounted guard is
/// needed here; callers still guard their own post-await provider reads.
void prepareAccountTransition(BuildContext context) {
  dismissSetupFlowFirst(context);
  popTabToRoot(context);
}

/// page, the device page, and the setup device section).
const accountNoKeyNote =
    'No student key on this device yet — enrollment creates one (device key + face, online once).';

String accountShortKey(String pkHex) {
  final h = pkHex.trim();
  if (h.isEmpty) return 'no key';
  return h.length <= 12 ? h : '${h.substring(0, 12)}…';
}
