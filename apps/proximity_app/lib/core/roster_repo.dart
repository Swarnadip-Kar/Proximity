// Enrolled-keys repository: Firestore `rosterKeys` / `crl` (+ fake).
//
// Identity is the Gmail account itself — no roster, no institute-ID
// matching. `rosterKeys/{lowercased-email}`: {pk, name, email, faceHash,
// modelVer, sig, updatedAt}. One device per email enforced here (reject
// when an existing doc carries a different PK) and by rules.
// `crl/{keyId}`: {pk} — revoked keys, read-only for clients.
// Face photos/templates are NEVER uploaded — only faceHash = H(embedding).
library;

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RosterKeyRecord {
  final String pkHex; // Ed25519 public key, 32B hex
  final String name; // display name imported from Gmail
  final String email;
  final String roll; // institute ID / roll no: user-entered, unverified
  final String faceHashHex; // H(enrollment embedding), 32B hex
  final String modelVer;
  final String sigHex; // Sign(SK, email||PK||name), 64B hex
  final DateTime updatedAt;
  const RosterKeyRecord({
    required this.pkHex,
    required this.name,
    required this.email,
    this.roll = '',
    required this.faceHashHex,
    required this.modelVer,
    required this.sigHex,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'pk': pkHex,
        'name': name,
        'email': email,
        'roll': roll,
        'faceHash': faceHashHex,
        'modelVer': modelVer,
        'sig': sigHex,
        'updatedAt': Timestamp.fromDate(updatedAt),
      };

  factory RosterKeyRecord.fromJson(Map<String, dynamic> j) => RosterKeyRecord(
        pkHex: j['pk'] as String,
        name: j['name'] as String? ?? '',
        email: j['email'] as String,
        roll: j['roll'] as String? ?? '',
        faceHashHex: j['faceHash'] as String,
        modelVer: j['modelVer'] as String,
        sigHex: j['sig'] as String,
        updatedAt: (j['updatedAt'] as Timestamp).toDate(),
      );

  /// Cache encoding (Firestore Timestamp is not JSON-encodable).
  Map<String, dynamic> toCacheJson() => {
        ...toJson(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory RosterKeyRecord.fromCacheJson(Map<String, dynamic> j) =>
      RosterKeyRecord(
        pkHex: j['pk'] as String,
        name: j['name'] as String? ?? '',
        email: j['email'] as String,
        roll: j['roll'] as String? ?? '',
        faceHashHex: j['faceHash'] as String,
        modelVer: j['modelVer'] as String,
        sigHex: j['sig'] as String,
        updatedAt: DateTime.parse(j['updatedAt'] as String),
      );
}

abstract class RosterRepository {
  Future<Map<String, RosterKeyRecord>> fetchKeys();
  Future<Set<String>> fetchCrl(); // revoked pk hex set
  Future<RosterKeyRecord?> fetchKey(String email);
  Future<void> uploadKey(String email, RosterKeyRecord record);

  /// Offline-first variants: network first, SharedPreferences cache
  /// fallback so a cached class works with zero connectivity. Defaults
  /// delegate to the live calls (fakes).
  Future<Map<String, RosterKeyRecord>> fetchKeysCached() => fetchKeys();
  Future<Set<String>> fetchCrlCached() => fetchCrl();
}

class FirestoreRosterRepository implements RosterRepository {
  static const _kKeysCache = 'prox.keysCache.v1';
  static const _kCrlCache = 'prox.crlCache.v1';
  final FirebaseFirestore _db;
  FirestoreRosterRepository({FirebaseFirestore? db})
      : _db = db ?? FirebaseFirestore.instance;

  static String docId(String email) => email.trim().toLowerCase();

  @override
  Future<Map<String, RosterKeyRecord>> fetchKeys() async {
    final snap = await _db.collection('rosterKeys').get();
    return {for (final d in snap.docs) d.id: RosterKeyRecord.fromJson(d.data())};
  }

  @override
  Future<Set<String>> fetchCrl() async {
    final snap = await _db.collection('crl').get();
    return {for (final d in snap.docs) (d.data()['pk'] as String).toLowerCase()};
  }

  @override
  Future<RosterKeyRecord?> fetchKey(String email) async {
    final d = await _db.collection('rosterKeys').doc(docId(email)).get();
    return d.exists ? RosterKeyRecord.fromJson(d.data()!) : null;
  }

  @override
  Future<void> uploadKey(String email, RosterKeyRecord record) =>
      _db.collection('rosterKeys').doc(docId(email)).set(record.toJson());

  @override
  Future<Map<String, RosterKeyRecord>> fetchKeysCached() async {
    try {
      final live = await fetchKeys();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kKeysCache,
          jsonEncode(live.map((k, v) => MapEntry(k, v.toCacheJson()))));
      return live;
    } catch (_) {
      return _readKeysCache();
    }
  }

  Future<Map<String, RosterKeyRecord>> _readKeysCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKeysCache);
      if (raw == null) return {};
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final e in map.entries)
          e.key: RosterKeyRecord.fromCacheJson(
              Map<String, dynamic>.from(e.value as Map))
      };
    } catch (_) {
      return {};
    }
  }

  @override
  Future<Set<String>> fetchCrlCached() async {
    try {
      final live = await fetchCrl();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kCrlCache, live.toList());
      return live;
    } catch (_) {
      try {
        final prefs = await SharedPreferences.getInstance();
        return (prefs.getStringList(_kCrlCache) ?? <String>[]).toSet();
      } catch (_) {
        return {};
      }
    }
  }
}

/// In-memory fake. Offline-capable by design.
class FakeRosterRepository implements RosterRepository {
  final Map<String, RosterKeyRecord> keys = {};
  final Set<String> revoked = {};
  FakeRosterRepository();

  @override
  Future<Map<String, RosterKeyRecord>> fetchKeys() async => Map.of(keys);

  @override
  Future<Set<String>> fetchCrl() async => Set.of(revoked);

  @override
  Future<RosterKeyRecord?> fetchKey(String email) async =>
      keys[FirestoreRosterRepository.docId(email)];

  @override
  Future<void> uploadKey(String email, RosterKeyRecord record) async {
    keys[FirestoreRosterRepository.docId(email)] = record;
  }

  @override
  Future<Map<String, RosterKeyRecord>> fetchKeysCached() async =>
      Map.of(keys);

  @override
  Future<Set<String>> fetchCrlCached() async => Set.of(revoked);
}

final rosterRepositoryProvider = Provider<RosterRepository>((ref) {
  throw UnimplementedError('Override with FirestoreRosterRepository in main');
});
