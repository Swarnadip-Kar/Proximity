// Auth abstraction: Google Sign-In + Firebase Auth (§3.2 step 1).
// Institute-domain (`hd`) forcing is OFF for now — see [requireDomain].
// Concrete Firebase impl is used on device; fakes drive widget/unit tests
// (tests never call Firebase.initializeApp).
library;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Signed-in account surface needed by enrollment. No face data here.
class SignedAccount {
  final String email;
  final String displayName;
  const SignedAccount({required this.email, required this.displayName});
}

abstract class AuthService {
  Stream<SignedAccount?> watchAccount();
  SignedAccount? get current;
  Future<SignedAccount?> signInWithGoogle();
  Future<String?> getIdToken();
  Future<void> signOut();
}

class FirebaseAuthService implements AuthService {
  final FirebaseAuth _auth;
  final GoogleSignIn _gsi;
  FirebaseAuthService({FirebaseAuth? auth, GoogleSignIn? gsi})
      : _auth = auth ?? FirebaseAuth.instance,
        _gsi = gsi ?? GoogleSignIn(scopes: const ['email']);

  SignedAccount? _map(User? u) => u?.email == null
      ? null
      : SignedAccount(
          email: u!.email!, displayName: u.displayName ?? u.email!);

  @override
  Stream<SignedAccount?> watchAccount() => _auth.authStateChanges().map(_map);

  @override
  SignedAccount? get current => _map(_auth.currentUser);

  @override
  Future<SignedAccount?> signInWithGoogle() async {
    final acct = await _gsi.signIn();
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
  Future<String?> getIdToken() =>
      _auth.currentUser?.getIdToken() ?? Future.value();

  @override
  Future<void> signOut() async {
    await _gsi.signOut();
    await _auth.signOut();
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
