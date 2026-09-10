//
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
import '../../routes.dart';
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

/// Pushes the standalone enrollment entry (preserved `enroll/intro` chain:
/// intro → capture → result). Same screens the setup flow composes.
void openAccountEnrollEntry(BuildContext context) {
  ProxNav.pushNamed(context, ProxRoutes.enrollIntro);
}

/// Fallback-weight sheet body for enroll / re-enroll / move entries: one
/// explanation + one outlined continue into the preserved enroll chain.
Widget accountEnrollSheetBody(
  BuildContext pageContext,
  WidgetRef ref, {
  required String body,
}) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(body, style: ProxType.body()),
      const SizedBox(height: ProxSpacing.md),
      // Outlined (secondary weight): entries stay fallback rows, never a
      // full-width primary button on the page itself.
      Builder(
        builder: (sheetContext) {
          final c = ProximityColors.of(sheetContext);
          return OutlinedButton(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(64, ProxSpacing.minTap),
              foregroundColor: c.accentBrand,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(ProxRadii.button),
              ),
            ),
            onPressed: () {
              Navigator.of(sheetContext).pop();
              openAccountEnrollEntry(pageContext);
            },
            child: const Text('Continue to enrollment'),
          );
        },
      ),
    ],
  );
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

/// page, the device page, and the setup device section).
const accountNoKeyNote =
    'No student key on this device yet — enrollment creates one (device key + face, online once).';

String accountShortKey(String pkHex) {
  final h = pkHex.trim();
  if (h.isEmpty) return 'no key';
  return h.length <= 12 ? h : '${h.substring(0, 12)}…';
}
