// Auth abstraction: Google Sign-In + Firebase Auth (§3.2 step 1).
// Institute-domain (`hd`) forcing is OFF for now — see [requireDomain].
// Concrete Firebase impl is used on device; fakes drive widget/unit tests
// (tests never call Firebase.initializeApp).
library;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Signed-in account surface needed by enrollment. No face data here.
class SignedAccount {
  final String email;
  final String displayName;
  final String uid;
  const SignedAccount(
      {required this.email, required this.displayName, this.uid = ''});
}

abstract class AuthService {
  Stream<SignedAccount?> watchAccount();
  SignedAccount? get current;
  Future<SignedAccount?> signInWithGoogle();
  Future<String?> getIdToken();
  Future<void> signOut();
}

/// Maps platform sign-in failures to actionable copy. The macOS keychain
/// error has three known triggers (upstream google/GoogleSignIn-iOS#165,
/// #492 — native 7.1+/8.x regressed; we pin google_sign_in_ios 5.7.5 /
/// native 7.0.0): (1) denying the macOS "wants to use the login keychain"
/// prompt — Allow it and type the login password; (2) a stale `auth`
/// keychain item written by an older build/entitlement — delete it in
/// Keychain Access (reinstall does NOT clear the keychain); (3) a build
/// missing the keychain-access-groups entitlement.
String _friendlySignInError(String raw) {
  final low = raw.toLowerCase();
  if (low.contains('keychain')) {
    return 'Google sign-in failed (macOS keychain blocked the login). Fix: '
        'when macOS asks, ALLOW "wants to use the login keychain" and type '
        'your login password — denying it causes exactly this error. If it '
        'persists, open Keychain Access, delete the stale `auth` item for '
        'this app, and sign in again (reinstall alone never clears the '
        'keychain). Detail: $raw';
  }
  return 'Google sign-in failed: $raw';
}

class FirebaseAuthService implements AuthService {
  final FirebaseAuth _auth;
  final GoogleSignIn _gsi;
  /// False when Firebase could not initialize (e.g. Linux builds —
  /// firebase_options throws UnsupportedError). Sign-in then reports a
  /// friendly message instead of crashing; professors continue offline.
  final bool available;
  FirebaseAuthService({FirebaseAuth? auth, GoogleSignIn? gsi, this.available = true})
      : _auth = auth ?? FirebaseAuth.instance,
        _gsi = gsi ?? GoogleSignIn(scopes: const ['email']);

  SignedAccount? _map(User? u) => u?.email == null
      ? null
      : SignedAccount(
          email: u!.email!,
          displayName: u.displayName ?? u.email!,
          uid: u.uid);

  @override
  Stream<SignedAccount?> watchAccount() {
    if (!available) return Stream.value(null);
    try {
      return _auth.authStateChanges().map(_map);
    } catch (_) {
      return Stream.value(null);
    }
  }

  @override
  SignedAccount? get current {
    if (!available) return null;
    try {
      return _map(_auth.currentUser);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<SignedAccount?> signInWithGoogle() async {
    // Web: the google_sign_in plugin has no client-ID path on web (it
    // asserts on a <meta google-signin-client_id> tag), so sign-in goes
    // through Firebase Auth's Google popup instead — no extra console
    // value needed, just the Firebase web app + authorized domain.
    if (kIsWeb) {
      try {
        final userCred = await _auth.signInWithPopup(GoogleAuthProvider());
        return _map(userCred.user);
      } on FirebaseAuthException catch (e) {
        // Closing the popup = abort, same as backing out on mobile.
        if (e.code == 'popup-closed-by-user' || e.code == 'user-cancelled') {
          return null;
        }
        throw StateError(_friendlySignInError('${e.code}: ${e.message}'));
      } catch (e) {
        throw StateError(_friendlySignInError('$e'));
      }
    }
    // Desktop honesty: the official google_sign_in plugin supports
    // Android/iOS/macOS only — Windows/Linux have no implementation
    // (MissingPluginException). Report it plainly; professors continue
    // offline, students use a mobile/macOS device for enrollment.
    if (!available ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux) {
      throw StateError(
          'Google sign-in is not supported on this desktop build (Windows/Linux). '
          'Continue as Professor offline on this device, or sign in on Android, iOS, or macOS.');
    }
    GoogleSignInAccount? acct;
    try {
      acct = await _gsi.signIn();
    } catch (e) {
      throw StateError(_friendlySignInError('$e'));
    }
    if (acct == null) return null; // user aborted
    final gAuth = await acct.authentication;
    final cred = GoogleAuthProvider.credential(
      idToken: gAuth.idToken,
      accessToken: gAuth.accessToken,
    );
    final userCred = await _auth.signInWithCredential(cred);
    return _map(userCred.user);
  }

  @override
  Future<String?> getIdToken() {
    if (!available) return Future.value(null);
    try {
      return _auth.currentUser?.getIdToken() ?? Future.value();
    } catch (_) {
      return Future.value(null);
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _gsi.signOut();
    } catch (_) {}
    if (!available) return;
    try {
      await _auth.signOut();
    } catch (_) {}
  }
}

/// In-memory fake for tests and offline UI demos.
class FakeAuthService implements AuthService {
  SignedAccount? _account;
  FakeAuthService([this._account]);

  /// Pre-seed the account the fake "Google" returns.
  // ignore: use_setters_to_change_properties
  void seedAccount(SignedAccount? a) => _account = a;

  @override
  Stream<SignedAccount?> watchAccount() => Stream.value(_account);

  @override
  SignedAccount? get current => _account;

  @override
  Future<SignedAccount?> signInWithGoogle() async => _account;

  @override
  Future<String?> getIdToken() async =>
      _account == null ? null : 'fake-id-token';

  @override
  Future<void> signOut() async => _account = null;
}

final authServiceProvider = Provider<AuthService>((ref) {
  throw UnimplementedError('Override with FirebaseAuthService in main');
});

final accountProvider = StreamProvider<SignedAccount?>((ref) {
  return ref.watch(authServiceProvider).watchAccount();
});
