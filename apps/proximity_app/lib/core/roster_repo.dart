// Enrolled-keys repository: Firestore `rosterKeys` / `crl` (+ fake).
//
// Identity is the Gmail account itself — no roster, no institute-ID
// matching. `rosterKeys/{lowercased-email}`: {pk, name, email, faceHash,
// modelVer, sig, updatedAt}. One device per email enforced here (reject
// when an existing doc carries a different PK) and by rules.
// `crl/{keyId}`: {pk} — revoked keys, read-only for clients.
// Face photos/templates are NEVER uploaded — only faceHash = H(embedding).
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
}

abstract class RosterRepository {
  Future<Map<String, RosterKeyRecord>> fetchKeys();
  Future<Set<String>> fetchCrl(); // revoked pk hex set
  Future<RosterKeyRecord?> fetchKey(String email);
  Future<void> uploadKey(String email, RosterKeyRecord record);
}

class FirestoreRosterRepository implements RosterRepository {
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
}

final rosterRepositoryProvider = Provider<RosterRepository>((ref) {
  throw UnimplementedError('Override with FirestoreRosterRepository in main');
});
