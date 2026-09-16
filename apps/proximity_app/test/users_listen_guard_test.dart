import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/sync/firestore_sync.dart';

// Regression guard for the Android startup crash:
// `Listen for Query(target=Query(users order by __name__)) failed:
// PERMISSION_DENIED`.
//
// firestore.rules intentionally sets `allow list: if false` on `users` —
// the boundary is the point. The only allowed users reads are owner
// single-doc gets (users/<uid>). Any collection-wide users query/listen
// (limit/where/orderBy/snapshots, including the old isOnline
// `.collection('users').limit(1).get(server)` probe) denies on device,
// even though FakeCloudSync tests never see it.
//
// This test fails before the fix (isOnline holds a collection list) and
// passes after (every users access is a doc get).
void main() {
  String readLib(String rel) {
    // flutter test runs with cwd = apps/proximity_app.
    const candidates = [
      'lib/core/sync/firestore_sync.dart',
      'apps/proximity_app/lib/core/sync/firestore_sync.dart',
    ];
    for (final c in candidates) {
      final f = File(c);
      if (f.existsSync()) return f.readAsStringSync();
    }
    // Fallback: resolve relative to this test file.
    final here = File(Platform.script.toFilePath()).parent;
    final f = File(
        '${here.path}/../lib/core/sync/firestore_sync.dart');
    return f.readAsStringSync();
  }

  String readRules() {
    const candidates = [
      'firestore.rules',
      'apps/proximity_app/firestore.rules',
    ];
    for (final c in candidates) {
      final f = File(c);
      if (f.existsSync()) return f.readAsStringSync();
    }
    final here = File(Platform.script.toFilePath()).parent;
    return File('${here.path}/../firestore.rules').readAsStringSync();
  }

  test('no collection-wide users listen/query in FirestoreCloudSync', () {
    final src = readLib('lib/core/sync/firestore_sync.dart');
    // Strip line comments: the fix comment names the old shape in prose.
    final code = src.replaceAll(RegExp(r'//.*'), '');
    // Every `collection('users')` must chain straight into `.doc(` —
    // any limit/where/orderBy/snapshots/get-without-doc is a list, which
    // `allow list: if false` denies (startup PERMISSION_DENIED).
    final collUse =
        RegExp(r'''\.collection\(\s*['"]users['"]\s*\)\s*\.\s*([A-Za-z_]+)''');
    final offenders = <String>[];
    for (final m in collUse.allMatches(code)) {
      final next = m.group(1);
      if (next != 'doc') offenders.add('collection(users).$next');
    }
    expect(offenders, isEmpty,
        reason:
            'collection-wide users query would LISTEN-deny (allow list: if false): $offenders');
    // Belt-and-braces: the old probe shape must be gone from CODE.
    expect(code.contains('.limit(1)'), isFalse,
        reason: 'isOnline must not issue a users limit(1) list query');
    expect(code.contains('snapshots('), isFalse,
        reason: 'no realtime users collection listen allowed');
    expect(code.contains('snapshotsInSync'), isFalse);
  });

  test('rules keep the users list boundary (allow list: if false)', () {
    final rules = readRules();
    expect(rules.contains('allow list: if false'), isTrue,
        reason: 'the fix must not loosen users list rules');
  });

  test('isOnline short-circuits without Firestore when signed out', () async {
    // No Firebase in unit tests: the signed-out path must return before
    // touching Firestore (otherwise it would issue the denied list query).
    final offline = FirestoreCloudSync(available: false);
    expect(await offline.isOnline(), isFalse);
    final signedOut =
        FirestoreCloudSync(available: true, currentUid: () => null);
    expect(await signedOut.isOnline(), isFalse);
    final emptyUid =
        FirestoreCloudSync(available: true, currentUid: () => '');
    expect(await emptyUid.isOnline(), isFalse);
  });
}
