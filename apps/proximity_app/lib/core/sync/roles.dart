// Role cache: professor/student role record + local cache helpers.
// Split out of core/cloud_sync.dart (M6 sync refactor) — bodies verbatim.
library;

/// Professor and/or student role record. One doc per Firebase uid — the same
/// Gmail can hold BOTH roles (professor on many devices, student on one).
/// [role] is the legacy single-role constructor param (maps to roles:[role]);
/// new code passes [roles]. [lastMode] ('prof'|'student'|'') is the last used
/// mode and drives the landing default + relaunch routing.
class RoleDoc {
  final String uid;
  final String email;
  final String name;
  final List<String> roles; // subset of ['prof', 'student']
  final String displayName;
  final String lastMode;
  final String org; // Google-account domain (see orgOf), '' = legacy
  RoleDoc(
      {required this.uid,
      required this.email,
      required this.name,
      List<String>? roles,
      String? role,
      this.displayName = '',
      this.lastMode = '',
      this.org = ''})
      : roles = roles ??
            (role != null && role.isNotEmpty ? [role] : const <String>[]);

  /// Legacy single-role read (first role, or ''). New code uses [roles].
  String get role => roles.isEmpty ? '' : roles.first;
  bool get isProf => roles.contains('prof');
  bool get isStudent => roles.contains('student');
}

/// Local role-cache helpers. Cache shape (see DeviceStore.readRole):
/// {roles: 'prof,student', lastMode: 'prof'|'student', email, uid,
///  displayName} plus a legacy mirror 'role' (= lastMode or first role).

/// Parses held roles from a cache map (legacy single 'role' supported).
Set<String> roleSet(Map<String, String>? role) {
  if (role == null) return const {};
  final out = <String>{};
  for (final part in (role['roles'] ?? '').split(',')) {
    final r = part.trim();
    if (r == 'prof' || r == 'student') out.add(r);
  }
  final legacy = (role['role'] ?? '').trim();
  if (legacy == 'prof' || legacy == 'student') out.add(legacy);
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

/// Org stamped on the role cache (Google-account domain, '' = legacy).
/// Normalized (trimmed + lowercased): the cache is written lowercased at
/// sign-in, this only defends against legacy/foreign entries. Track 6:
/// was `(role?['org'] ?? '').trim().toLowerCase()` inline at 5+ call
/// sites (host/take/manual-add/export/flagged).
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
  final primary = mode.isNotEmpty
      ? mode
      : (ordered.isNotEmpty ? ordered.first : '');
  // Org persists from sign-in (never user-entered): an explicit non-empty
  // value wins, else the previous cache entry survives (legacy '' stays).
  final nextOrg = (org != null && org.isNotEmpty)
      ? org
      : (prev['org'] ?? existing?['org'] ?? '');
  return {
    'roles': ordered.join(','),
    'role': primary, // legacy mirror
    'lastMode': mode,
    'email': email.toLowerCase(),
    'uid': uid,
    'displayName': displayName,
    'org': nextOrg,
  };
}
