// Role cache: professor/student role record + local cache helpers.
library;

/// Professor and/or student role record. One doc per Firebase uid — the same
/// Gmail can hold BOTH roles (professor on many devices, student on one).
/// [roles] is the full set; [lastMode] ('prof'|'student'|'') is the last
/// used mode and drives the landing default + relaunch routing.
class RoleDoc {
  final String uid;
  final String email;
  final String name;
  final List<String> roles; // subset of ['prof', 'student']
  final String displayName;
  final String lastMode;
  final String org; // Google-account domain (see orgOf), '' = legacy
  /// Last cloud touch (UTC epoch ms, 0 = pre-timestamp legacy — never
  /// "stale" by itself; drives the owner-lazy six-month purge gate).
  final int updatedAtMillis;
  RoleDoc(
      {required this.uid,
      required this.email,
      required this.name,
      this.roles = const <String>[],
      this.displayName = '',
      this.lastMode = '',
      this.org = '',
      this.updatedAtMillis = 0});
}

/// Local role-cache helpers. Cache shape (see DeviceStore.readRole):
/// {roles: 'prof,student', lastMode: 'prof'|'student', email, uid,
///  displayName, org}. Fresh-only: the single-key 'role' entry is gone —
/// a cache without 'roles' holds nothing (re-register).

/// Parses held roles from a cache map ('roles' CSV only).
Set<String> roleSet(Map<String, String>? role) {
  if (role == null) return const {};
  final out = <String>{};
  for (final part in (role['roles'] ?? '').split(',')) {
    final r = part.trim();
    if (r == 'prof' || r == 'student') out.add(r);
  }
  return out;
}

/// True when the cached role belongs to [email] and holds [which].
bool roleHas(Map<String, String>? role, String which, {String? email}) {
  if (role == null) return false;
  if (email != null &&
      (role['email'] ?? '').toLowerCase() != email.toLowerCase()) {
    return false;
  }
  return roleSet(role).contains(which);
}

/// Last used mode from cache ('prof'|'student'|'').
String roleLastMode(Map<String, String>? role) {  if (role == null) return '';
  final m = (role['lastMode'] ?? '').trim();
  if (m == 'prof' || m == 'student') return m;
  final set = roleSet(role);
  if (set.length == 1) return set.first;
  return '';
}

/// Org stamped on the role cache ('' = legacy), defensively normalized —
/// the cache is written lowercased at sign-in.
String roleOrg(Map<String, String>? role) =>
    (role?['org'] ?? '').trim().toLowerCase();

/// Merges a registration/continue event into a role-cache map.
Map<String, String> mergeRoleCache(Map<String, String>? existing,
    {required String email,
    required String uid,
    String displayName = '',
    String? addRole,
    String? lastMode,
    String? org}) {
  final set = {...roleSet(existing)};
  if (addRole == 'prof') {
    set.add('prof');
  } else if (addRole == 'student') {
    set.add('student');
  }
  final prev = existing ?? const <String, String>{};
  final mode = (lastMode == 'prof' || lastMode == 'student')
      ? lastMode!
      : (prev['lastMode'] ?? '');
  final ordered = [
    if (set.contains('prof')) 'prof',
    if (set.contains('student')) 'student'
  ];
  // Org persists from sign-in (never user-entered): an explicit non-empty
  // value wins, else the previous cache entry survives ('' stays unset).
  final nextOrg = (org != null && org.isNotEmpty)
      ? org
      : (prev['org'] ?? existing?['org'] ?? '');
  return {
    'roles': ordered.join(','),
    'lastMode': mode,
    'email': email.toLowerCase(),
    'uid': uid,
    'displayName': displayName,
    'org': nextOrg,
  };
}
