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

import 'sync/org.dart';

/// Signed-in account surface needed by enrollment. No face data here.
/// [org] is the Google-account domain (see orgOf): derived at sign-in from
/// the idToken `hd` claim when present, else the verified-email domain.
/// Never user-entered.
/// [photoUrl] is the Google OAuth profile photo (ordinary account metadata,
/// NOT `face_verification` output): prefer the Google-account photo, fall
/// back to the Firebase user photo; null when unavailable. Renderers treat
/// null/empty as the deterministic initials avatar.
class SignedAccount {
  final String email;
  final String displayName;
  final String uid;
  final String org;
  final String? photoUrl;
  const SignedAccount(
      {required this.email,
      required this.displayName,
      this.uid = '',
      this.org = '',
      this.photoUrl});
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

  SignedAccount? _map(User? u, {String? hd, String? photoUrl}) {
    if (u?.email == null) return null;
    final email = u!.email!;
    return SignedAccount(
      email: email,
      displayName: u.displayName ?? email,
      uid: u.uid,
      org: orgFromHd(hd, email),
      // Prefer the Google-account photo; fall back to the Firebase user
      // photo; null when neither carries one. Blank strings count as
      // absent so renderers hit the initials fallback.
      photoUrl: _pickPhoto(photoUrl, u.photoURL),
    );
  }

  /// First non-blank of the Google-account photo vs the Firebase user
  /// photo, else null. Pure helper — no caching, no persistence.
  static String? _pickPhoto(String? googlePhoto, String? firebasePhoto) {
    if (googlePhoto != null && googlePhoto.trim().isNotEmpty) {
      return googlePhoto;
    }
    if (firebasePhoto != null && firebasePhoto.trim().isNotEmpty) {
      return firebasePhoto;
    }
    return null;
  }

  /// Best-effort `hd` out of a raw Google idToken JWT (null when absent).
  static String? hdFromIdToken(String? idToken) =>
      parseHdFromIdToken(idToken);

  @override
  Stream<SignedAccount?> watchAccount() {
    if (!available) return Stream.value(null);
    try {
      return _auth.authStateChanges().map((u) => _map(u));
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
        // Prefer the verified hd claim when the token carries it; fall
        // back to the email domain (never user-entered either way).
        String? hd;
        try {
          final res = await userCred.user?.getIdTokenResult();
          final raw = res?.claims?['hd'];
          if (raw is String && raw.trim().isNotEmpty) hd = raw;
        } catch (_) {}
        return _map(userCred.user, hd: hd);
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
    // Prefer the Google idToken `hd` claim (hosted domain) when present;
    // the email domain is the fallback. Both are verified, never typed.
    // Photo: prefer the Google-account photo, fall back to the Firebase
    // user photo inside _map (null when neither carries one).
    final googlePhoto = acct.photoUrl;
    final hd = parseHdFromIdToken(gAuth.idToken);
    if (hd == null) {
      try {
        final res = await userCred.user?.getIdTokenResult();
        final raw = res?.claims?['hd'];
        if (raw is String && raw.trim().isNotEmpty) {
          return _map(userCred.user, hd: raw, photoUrl: googlePhoto);
        }
      } catch (_) {}
    }
    return _map(userCred.user, hd: hd, photoUrl: googlePhoto);
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
  FakeAuthService([SignedAccount? account])
      : _account = account == null ? null : _withOrg(account);

  /// Pre-seed the account the fake "Google" returns. An empty org derives
  /// via [orgOf] like the real service (explicit orgs pass through for
  /// cross-domain gate tests).
  // ignore: use_setters_to_change_properties
  void seedAccount(SignedAccount? a) =>
      _account = a == null ? null : _withOrg(a);

  static SignedAccount _withOrg(SignedAccount a) => a.org.isNotEmpty
      ? a
      : SignedAccount(
          email: a.email,
          displayName: a.displayName,
          uid: a.uid,
          org: orgOf(a.email),
          // photoUrl passthrough for tests: org derivation must not drop
          // the OAuth photo.
          photoUrl: a.photoUrl);

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
