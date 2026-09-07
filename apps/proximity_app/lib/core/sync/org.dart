// Org mapping: same Google-account domain join-gate + schema-level scoping.
//
// Track 1: an org IS a lowercased email domain. gmail.com is a normal org
// (no blocklist); subdomains exact-match (mail.univ.edu != univ.edu);
// malformed addresses map to '' (legacy / unknown).
library;

import 'dart:convert';

import 'package:proximity_storage/storage.dart';

import 'roles.dart';

/// Domain of [email]: part after the LAST '@', lowercased + trimmed.
/// Normalizes googlemail.com -> gmail.com (same Google org).
/// Returns '' when malformed (no '@', empty local/domain, spaces, extra '@'
// in the domain part).
String orgOf(String email) {
  final e = email.trim().toLowerCase();
  final at = e.lastIndexOf('@');
  if (at <= 0 || at == e.length - 1) return '';
  final domain = e.substring(at + 1).trim();
  if (domain.isEmpty) return '';
  if (domain.contains(' ') || domain.contains('@')) return '';
  if (domain.startsWith('.') || domain.endsWith('.')) return '';
  if (domain == 'googlemail.com') return 'gmail.com';
  return domain;
}

/// Prefers the Google idToken `hd` claim when present (already a domain),
/// else falls back to the verified-email domain. Never user-entered: callers
/// pass only the token claim + the Firebase-verified email.
String orgFromHd(String? hd, String email) {
  final h = (hd ?? '').trim().toLowerCase();
  if (h.isNotEmpty && !h.contains('@') && !h.contains(' ')) {
    if (h == 'googlemail.com') return 'gmail.com';
    if (!h.startsWith('.') && !h.endsWith('.')) return h;
  }
  return orgOf(email);
}

/// Best-effort `hd` claim out of a Google idToken JWT (header.payload.sig).
/// Returns null when absent/undecodable — the caller falls back to [orgOf].
String? parseHdFromIdToken(String? idToken) {
  if (idToken == null || idToken.isEmpty) return null;
  try {
    final parts = idToken.split('.');
    if (parts.length < 2) return null;
    var payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
    while (payload.length % 4 != 0) {
      payload += '=';
    }
    final json =
        jsonDecode(utf8.decode(base64.decode(payload))) as Map<String, dynamic>;
    final hd = json['hd'];
    if (hd is String && hd.trim().isNotEmpty) return hd.trim();
    return null;
  } catch (_) {
    return null;
  }
}

/// Local visibility predicate for exports + manual-queue resolution.
/// Legacy docs without org ('') stay locally visible/exportable; cross-org
/// docs (both stamped, different) are hidden. Cloud queries additionally
/// filter server-side with where('org', isEqualTo: myOrg), so legacy cloud
/// docs stay invisible there until stamped.
bool inMyOrg(String sessionOrg, String myOrg) {
  if (sessionOrg.isEmpty) return true; // legacy locally visible
  if (myOrg.isEmpty) return true; // offline-skipped / unknown: local only
  return sessionOrg == myOrg;
}

/// [ClassRecord] convenience over [inMyOrg].
bool recordInMyOrg(ClassRecord record, String myOrg) =>
    inMyOrg(record.org, myOrg);

/// Preferred org for this device: account org wins, else the role-cache
/// stamp ('' = legacy/offline-skipped). Role side normalized here.
String resolveMyOrg(String? acctOrg, Map<String, String>? role) {
  final a = (acctOrg ?? '').trim().toLowerCase();
  if (a.isNotEmpty) return a;
  return roleOrg(role);
}
